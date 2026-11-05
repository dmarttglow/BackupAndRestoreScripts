<#
.SYNOPSIS
    MACHINE IPC (optional): full-screen "system is being updated - do not power off"
    screen with live progress, shown while Apply-Update runs.

.DESCRIPTION
    Shows UpdateScreen.html, which displays the progress Apply-Update writes to
    <LocalBackupRoot>\update_progress.json / .js. Two ways:

    TF1200 UI Client (used when the UI Client is running in this session): as soon as
    an update starts, the UI Client is restarted on the status page, using a copy of
    its own configuration in which only startUrl is changed (the real config file is
    never modified). The page then updates itself. When the update ends without a
    reboot, the page goes back to the UI Client's normal start page (the HMI). After a
    reboot the UI Client starts with its normal configuration anyway.

    PowerShell window (fallback when no UI Client is running): a WPF kiosk window
    (borderless, maximised, topmost) that renders the page in a WebBrowser control.

    The update never depends on this screen: Apply-Update only writes the progress
    file. This script only reads it, and closing or crashing it changes nothing.

    It must run in the logged-on user's desktop session. When the PLC starts
    Apply-Update it runs as SYSTEM in session 0, where windows are invisible, so the
    screen is started through the scheduled task that Install-UpdateScreen.bat
    creates (Apply-Update.bat triggers it). See the README.

    The screen:
      - waits up to -WaitForStartSec for an update to start, then closes if none does
      - cannot be closed with Alt+F4 while the update runs
        (maintenance: Ctrl+Shift+F12 always closes it)
      - shows the result: success (closes by itself), failed / rolled back
        (Close button, closes by itself), rollback failed (stays until closed)
      - stays up through the reboot countdown

.PARAMETER Mode
    Auto (default): the TF1200 UI Client if it is running in this session, otherwise the
    PowerShell window. HmiClient / Window: force one of them.

.PARAMETER Windowed
    PowerShell window only: normal resizable window instead of full-screen kiosk (for testing).

.PARAMETER Demo
    Show simulated progress instead of reading the progress file (preview the screen).
    -DemoResult picks how the simulated update ends.

.PARAMETER CloseAfterSec
    Close after this many seconds whatever the state (for testing). 0 = never.
#>
[CmdletBinding()]
param(
    [string]$ProgressFile,
    [string]$ConfigPath,
    [ValidateSet('Auto', 'HmiClient', 'Window')][string]$Mode = 'Auto',
    [int]$WaitForStartSec = 90,
    [switch]$Windowed,
    [switch]$Demo,
    [ValidateSet('Success', 'Failed', 'RolledBack', 'StartFailed', 'RollbackFailed')][string]$DemoResult = 'Success',
    [int]$CloseAfterSec = 0
)

$ErrorActionPreference = 'Stop'

# --- Seconds the result stays on screen before closing by itself (-1 = never) ---
$AutoCloseSec = @{ Success = 15; Failed = 120; RolledBack = 120; StartFailed = 120; RollbackFailed = -1 }
$StaleCloseSec = 600   # no progress for this long while "running": offer the Close button

# --- Single instance per session ---------------------------------------------------
$mutex = New-Object Threading.Mutex($false, 'Local\TwinCAT_UpdateScreen')
$owned = $false
try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { exit 0 }

try {
    if (-not $ProgressFile) {
        if (-not $ConfigPath) { $ConfigPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Config.ps1' }
        $Settings = $null
        . $ConfigPath
        $ProgressFile = Join-Path $Settings.LocalBackupRoot 'update_progress.json'
    }
    $htmlPath = Join-Path $PSScriptRoot 'UpdateScreen.html'
    $html = [IO.File]::ReadAllText($htmlPath)

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

    $script:uiStart = [DateTime]::UtcNow
    $script:allowClose = $false
    $script:pageReady = $false
    $script:finalRunId = $null
    $script:installerGoneAt = $null
    $script:finalSeenAt = $null
    $script:lastJson = $null

    # Errors go to %TEMP%\TwinCAT_UpdateScreen.log (each distinct message once); the screen keeps going.
    $script:errorsSeen = @{}
    function Write-ScreenError($err) {
        $msg = "$($err.Exception.Message) @ $($err.InvocationInfo.ScriptLineNumber)"
        if ($script:errorsSeen.ContainsKey($msg)) { return }
        $script:errorsSeen[$msg] = 1
        try { Add-Content -LiteralPath (Join-Path $env:TEMP 'TwinCAT_UpdateScreen.log') -Value "[$(Get-Date -Format s)] $msg" } catch { }
    }

    function ConvertTo-UtcDate($v) {
        if ($null -eq $v -or $v -eq '') { return $null }
        if ($v -is [DateTime]) { return $v.ToUniversalTime() }
        [DateTime]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
    }

    function Read-ProgressFile {
        try {
            $fs = [IO.File]::Open($ProgressFile, 'Open', 'Read', ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            try { $text = (New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)).ReadToEnd() } finally { $fs.Dispose() }
            $text | ConvertFrom-Json
        } catch { $null }   # missing, or being replaced right now: try again next tick
    }

    # Simulated progress for -Demo.
    function Get-DemoProgress {
        $t = ([DateTime]::UtcNow - $script:uiStart).TotalSeconds
        $steps = @(
            @('check', 'Looking for the update package', 0, 3), @('unpack', 'Unpacking the update package', 3, 20),
            @('verify', 'Verifying the update package', 20, 35), @('stop', 'Stopping TwinCAT and the HMI Server', 35, 40),
            @('backup', 'Backing up the current version', 40, 60), @('install', 'Installing the new version', 60, 75),
            @('verifyinstall', 'Verifying the installed files', 75, 97), @('restart', 'Starting TwinCAT and the HMI Server', 97, 99))
        $per = 3.0
        $failAt = switch ($DemoResult) { 'Failed' { 2 } 'RolledBack' { 6 } 'RollbackFailed' { 6 } default { 99 } }
        $p = [ordered]@{ RunId = 'demo'; ComputerName = $env:COMPUTERNAME; State = 'Running'; StepKey = ''; Step = ''; Detail = ''
            Percent = 0; ErrorText = ''; RebootAtUtc = $null; StartedUtc = $script:uiStart.ToString('o'); UpdatedUtc = [DateTime]::UtcNow.ToString('o') }
        $i = [int][Math]::Floor($t / $per)
        $last = [Math]::Min($steps.Count, $failAt)
        if ($i -lt $last) {
            $st = $steps[$i]; $f = ($t - $i * $per) / $per
            $p.StepKey = $st[0]; $p.Step = $st[1]; $p.Percent = [int]($st[2] + ($st[3] - $st[2]) * $f)
            $p.Detail = '{0}: {1}/240 files ({2}%)' -f $st[1], [int](240 * $f), [int](100 * $f)
            return [pscustomobject]$p
        }
        $done = $last * $per
        if ($DemoResult -in 'RolledBack', 'RollbackFailed' -and $t -lt $done + 4) {
            $p.StepKey = 'rollback'; $p.Step = 'Update failed - restoring the previous version'; $p.Percent = 80
            $p.Detail = 'Rolling back [Boot] ...  00:0{0} elapsed' -f [int]($t - $done)
            return [pscustomobject]$p
        }
        $st = $steps[[Math]::Min($last, $steps.Count) - 1]
        $p.StepKey = if ($DemoResult -in 'RolledBack', 'RollbackFailed') { 'rollback' } else { $st[0] }
        $p.Step = $st[1]; $p.State = $DemoResult
        $p.Percent = if ($DemoResult -eq 'Success') { 100 } else { $st[3] }
        switch ($DemoResult) {
            'Failed'         { $p.ErrorText = 'Installed versions do not match the package (1 mismatch(es)). Nothing was changed.' }
            'RolledBack'     { $p.ErrorText = 'Update failed; previous version restored.' }
            'RollbackFailed' { $p.ErrorText = 'Update failed and rollback failed. Restore manually from C:\TwinCAT_UpdateBackups\20261105_101500_before_update' }
            'StartFailed'    { $p.ErrorText = 'The update was installed, but TwinCAT or the HMI Server did not start again. Restarting the controller.' }
        }
        if ($DemoResult -eq 'StartFailed') { $p.RebootAtUtc = $script:uiStart.AddSeconds($done + 15).ToString('o') }
        [pscustomobject]$p
    }

    # What the page shows: the progress file plus timing the page cannot work out itself.
    function Get-ViewModel {
        $now = [DateTime]::UtcNow
        $vm = [ordered]@{
            Phase = 'waiting'; State = 'Running'; StepKey = ''; Step = ''; Detail = ''; Percent = 0; ErrorText = ''
            ComputerName = $env:COMPUTERNAME; ElapsedSec = [int]($now - $script:uiStart).TotalSeconds
            StaleSec = 0; RebootInSec = $null; AutoCloseInSec = $null; CanClose = $false
        }
        $p = if ($Demo) { Get-DemoProgress } else { Read-ProgressFile }

        # Only an update that started around or after this screen counts (not the result of an old one).
        $started = $null
        if ($p) { try { $started = ConvertTo-UtcDate $p.StartedUtc } catch { } }
        if (-not $p -or -not $started -or $started -lt $script:uiStart.AddSeconds(-60)) {
            if ($vm.ElapsedSec -ge $WaitForStartSec) { $vm.AutoCloseInSec = 0 }
            return $vm
        }

        foreach ($k in 'State', 'StepKey', 'Step', 'Detail', 'Percent', 'ErrorText', 'ComputerName') {
            if ($null -ne $p.$k) { $vm[$k] = $p.$k }
        }
        $vm.ElapsedSec = [int]($now - $started).TotalSeconds
        $updated = $null
        try { $updated = ConvertTo-UtcDate $p.UpdatedUtc } catch { }

        if ($p.State -eq 'Running') {
            $vm.Phase = 'running'
            $script:finalRunId = $null
            if ($updated) { $vm.StaleSec = [Math]::Max(0, [int]($now - $updated).TotalSeconds) }
            if ($vm.StaleSec -ge $StaleCloseSec) { $vm.CanClose = $true }
            # Safety net: the update process has ended without its result reaching the file
            # (killed, or the last write was lost) - go back to the HMI instead of waiting.
            if (-not $Demo -and $p.Pid) {
                if (Get-Process -Id ([int]$p.Pid) -ErrorAction SilentlyContinue) { $script:installerGoneAt = $null }
                elseif (-not $script:installerGoneAt) { $script:installerGoneAt = $now }
                elseif (($now - $script:installerGoneAt).TotalSeconds -ge 10) { $vm.AutoCloseInSec = 0 }
            }
            return $vm
        }

        $vm.Phase = 'final'
        if ($script:finalRunId -ne $p.RunId) { $script:finalRunId = $p.RunId; $script:finalSeenAt = $now }
        $rebootAt = $null
        try { $rebootAt = ConvertTo-UtcDate $p.RebootAtUtc } catch { }
        if ($rebootAt -and $now -lt $rebootAt.AddSeconds(90)) {
            # Reboot pending: no Close button, the controller is about to restart.
            $vm.RebootInSec = [Math]::Max(0, [int][Math]::Ceiling(($rebootAt - $now).TotalSeconds))
            return $vm
        }
        # Result without reboot (or the reboot was cancelled).
        $vm.CanClose = $true
        $wait = $AutoCloseSec[[string]$p.State]
        if ($null -eq $wait) { $wait = 120 }
        $since = if ($rebootAt -and $rebootAt -gt $script:finalSeenAt) { $rebootAt.AddSeconds(90) } else { $script:finalSeenAt }
        if ($wait -ge 0) { $vm.AutoCloseInSec = [Math]::Max(0, $wait - [int]($now - $since).TotalSeconds) }
        $vm
    }

    # =============================================================================
    #  TF1200 UI Client
    # =============================================================================
    $clientWork = Join-Path $env:TEMP 'TwinCAT_UpdateScreen'
    $clientConfig = Join-Path $clientWork 'TF1200-config.json'   # copy with startUrl = status page
    $clientOriginal = Join-Path $clientWork 'original.json'      # how the UI Client was running before

    function Get-ClientProcesses {
        $sid = (Get-Process -Id $PID).SessionId
        @(Get-CimInstance Win32_Process -Filter "Name='TF1200-UI-Client.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.SessionId -eq $sid })
    }

    # The running UI Client in this session: exe, arguments and config file. $null if none.
    function Get-HmiClient {
        $main = @(Get-ClientProcesses | Where-Object { [string]$_.CommandLine -notmatch '\s--type=' })   # not the Chromium helper processes
        if ($main.Count -eq 0) { return $null }
        $cl = [string]$main[0].CommandLine
        $arguments = if ($cl -match '^\s*("[^"]*"|\S+)\s*(.*)$') { $Matches[2] } else { '' }
        $cfg = if ($cl -match '--config-path=(?:"([^"]+)"|(\S+))') { if ($Matches[1]) { $Matches[1] } else { $Matches[2] } }
               else { Join-Path $env:APPDATA 'Beckhoff\TF1200-UI-Client\config.json' }
        $exe = $main[0].ExecutablePath
        if (-not $exe) {
            $exe = @("${env:ProgramFiles(x86)}\Beckhoff\TwinCAT\Functions\TF1200-UI-Client\TF1200-UI-Client.exe",
                     "${env:ProgramFiles(x86)}\Beckhoff\TcUiClient\TF1200-UI-Client.exe",
                     "$env:ProgramFiles\Beckhoff\TwinCAT\Functions\TF1200-UI-Client\TF1200-UI-Client.exe",
                     "$env:ProgramFiles\Beckhoff\TcUiClient\TF1200-UI-Client.exe") | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
        }
        [pscustomobject]@{ Exe = $exe; Arguments = $arguments; ConfigPath = [Environment]::ExpandEnvironmentVariables($cfg) }
    }

    # startUrl may be a URL or a local path, with environment variables (the UI Client allows both).
    function ConvertTo-PageUrl([string]$u) {
        $u = [Environment]::ExpandEnvironmentVariables($u)
        if ($u -match '^[A-Za-z][A-Za-z0-9+.-]+:' -and $u -notmatch '^file:') { return $u }
        ([Uri]$u).AbsoluteUri
    }

    function Stop-HmiClient {
        $procs = Get-ClientProcesses
        foreach ($p in $procs) { try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop } catch { } }
        $until = [DateTime]::UtcNow.AddSeconds(10)
        while ((Get-ClientProcesses).Count -and [DateTime]::UtcNow -lt $until) { Start-Sleep -Milliseconds 200 }
    }

    function Start-HmiClient($exe, [string]$arguments) {
        if ($arguments) { Start-Process -FilePath $exe -ArgumentList $arguments -WorkingDirectory (Split-Path -Parent $exe) }
        else { Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe) }
        $until = [DateTime]::UtcNow.AddSeconds(20)
        while ([DateTime]::UtcNow -lt $until) {
            Start-Sleep -Milliseconds 500
            if (Get-HmiClient) { return $true }
        }
        $false
    }

    function Show-InHmiClient($client) {
        # Already showing (or was showing) the status page: use the configuration saved back then.
        if ([IO.Path]::GetFullPath($client.ConfigPath) -eq [IO.Path]::GetFullPath($clientConfig) -and (Test-Path -LiteralPath $clientOriginal)) {
            $client = Get-Content -LiteralPath $clientOriginal -Raw | ConvertFrom-Json
        }
        if (-not $client.Exe) { throw 'TF1200-UI-Client.exe not found.' }

        # Switch only once an update has really started, so the HMI stays up if nothing happens.
        if (-not $Demo) {
            while ($true) {
                $p = Read-ProgressFile
                $started = $null
                if ($p) { try { $started = ConvertTo-UtcDate $p.StartedUtc } catch { } }
                if ($started -and $started -ge $script:uiStart.AddSeconds(-60)) { break }
                if (([DateTime]::UtcNow - $script:uiStart).TotalSeconds -ge $WaitForStartSec) { return }
                Start-Sleep -Milliseconds 500
            }
        }

        New-Item -ItemType Directory -Path $clientWork -Force | Out-Null
        $utf8 = New-Object Text.UTF8Encoding $false   # no BOM: the UI Client cannot parse a config with one
        $page = Join-Path $clientWork 'UpdateScreen.html'
        Copy-Item -LiteralPath $htmlPath -Destination $page -Force
        $progressJs = if ($Demo) { Join-Path $clientWork 'demo_progress.js' } else { [IO.Path]::ChangeExtension($ProgressFile, '.js') }

        $cfg = [IO.File]::ReadAllText($client.ConfigPath) | ConvertFrom-Json
        $screenCfg = [ordered]@{
            progressScript  = ([Uri]$progressJs).AbsoluteUri
            returnUrl       = ConvertTo-PageUrl ([string]$cfg.startUrl)
            notBeforeUtc    = $script:uiStart.AddSeconds(-60).ToString('o')
            waitForStartSec = $WaitForStartSec
            staleCloseSec   = $StaleCloseSec
            autoCloseSec    = $AutoCloseSec
            computerName    = $env:COMPUTERNAME
            helperReturnsToHmi = $true
        }
        [IO.File]::WriteAllText((Join-Path $clientWork 'update_screen_config.js'), "window.UPDATE_SCREEN_CONFIG = $($screenCfg | ConvertTo-Json -Compress);", $utf8)
        $cfg.startUrl = ([Uri]$page).AbsoluteUri
        [IO.File]::WriteAllText($clientConfig, ($cfg | ConvertTo-Json -Depth 20), $utf8)
        [IO.File]::WriteAllText($clientOriginal, ($client | ConvertTo-Json), $utf8)

        Stop-HmiClient
        if (-not (Start-HmiClient $client.Exe "--config-path=`"$clientConfig`"")) {
            # Never leave the machine without its HMI: start the UI Client the way it was.
            [void](Start-HmiClient $client.Exe $client.Arguments)
            throw 'The TF1200 UI Client did not start with the status page; restarted it normally.'
        }

        # Follow the update (same rules as the page). When the page would close, take the UI
        # Client back to the HMI: wait until the HMI Server answers, then restart the UI Client
        # with its normal configuration, so its own retry settings apply from then on.
        $giveUpAt = [DateTime]::UtcNow.AddHours(4)
        while ([DateTime]::UtcNow -lt $giveUpAt) {
            if ($Demo) { [IO.File]::WriteAllText($progressJs, "updateProgress($(Get-DemoProgress | ConvertTo-Json -Compress));", $utf8) }
            $vm = Get-ViewModel
            if ($null -ne $vm.AutoCloseInSec -and $vm.AutoCloseInSec -le 0) { break }
            Start-Sleep -Milliseconds 500
        }
        Wait-HmiReachable $screenCfg.returnUrl 120
        Stop-HmiClient
        if (-not (Start-HmiClient $client.Exe $client.Arguments)) { throw 'The TF1200 UI Client did not start again with its normal configuration.' }
    }

    # Waits until the HMI web server accepts connections (http/https start pages only).
    function Wait-HmiReachable([string]$url, [int]$timeoutSec) {
        $u = $null
        try { $u = [Uri]$url } catch { return }
        if ($u.Scheme -notin 'http', 'https') { return }
        $until = [DateTime]::UtcNow.AddSeconds($timeoutSec)
        while ([DateTime]::UtcNow -lt $until) {
            $tcp = New-Object Net.Sockets.TcpClient
            try {
                $ar = $tcp.BeginConnect($u.Host, $u.Port, $null, $null)
                if ($ar.AsyncWaitHandle.WaitOne(2000) -and $tcp.Connected) { Start-Sleep -Seconds 3; return }   # 3 s: let the server finish starting
            } catch { } finally { $tcp.Close() }
            Start-Sleep -Seconds 2
        }
    }

    if ($Mode -ne 'Window') {
        $client = Get-HmiClient
        if ($client) { Show-InHmiClient $client; return }
        if ($Mode -eq 'HmiClient') { throw 'No TF1200 UI Client is running in this session.' }
    }

    # =============================================================================
    #  PowerShell window (fallback)
    # =============================================================================
    $window = New-Object Windows.Window
    $window.Title = 'System update'
    $window.Background = [Windows.Media.Brushes]::Black
    if ($Windowed) {
        $window.Width = 1280; $window.Height = 800
        $window.WindowStartupLocation = 'CenterScreen'
    } else {
        $window.WindowStyle = 'None'
        $window.ResizeMode = 'NoResize'
        $window.WindowState = 'Maximized'
        $window.Topmost = $true
        $window.ShowInTaskbar = $false
    }

    $browser = New-Object Windows.Controls.WebBrowser
    $window.Content = $browser

    $browser.Add_Navigated({
        # Never show IE script-error dialogs on the kiosk.
        try {
            $ax = [Windows.Controls.WebBrowser].GetField('_axIWebBrowser2', 'Instance,NonPublic').GetValue($browser)
            if ($ax) { [void]$ax.GetType().InvokeMember('Silent', 'SetProperty', $null, $ax, @($true)) }
        } catch { }
    })
    $browser.Add_LoadCompleted({ $script:pageReady = $true })
    $browser.Add_Navigating({
        param($sender, $e)
        if ($e.Uri -and $e.Uri.Host -eq 'updatescreen.close') {
            $e.Cancel = $true
            $script:allowClose = $true
            $window.Close()
        }
    })

    $window.Add_Closing({
        param($sender, $e)
        if (-not $script:allowClose) { $e.Cancel = $true }
    })
    $window.Add_KeyDown({
        param($sender, $e)
        $mods = [Windows.Input.Keyboard]::Modifiers
        if ($e.Key -eq 'F12' -and ($mods -band 'Control') -and ($mods -band 'Shift')) {
            $script:allowClose = $true
            $window.Close()
        }
    })

    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(500)
    $script:tick = 0
    $timer.Add_Tick({
        $script:tick++
        try {
            $vm = Get-ViewModel
            if ($CloseAfterSec -gt 0 -and ([DateTime]::UtcNow - $script:uiStart).TotalSeconds -ge $CloseAfterSec) { $vm.AutoCloseInSec = 0 }
            if ($null -ne $vm.AutoCloseInSec -and $vm.AutoCloseInSec -le 0) {
                $timer.Stop()
                $script:allowClose = $true
                $window.Close()
                return
            }
            if ($script:pageReady) {
                # [string]: a PSObject-wrapped string reaches the page as a COM object, not a JS string.
                $json = [string]($vm | ConvertTo-Json -Compress)
                if ($json -ne $script:lastJson) {
                    $script:lastJson = $json
                    [void]$browser.InvokeScript('updateStatus', [object[]]@($json))
                }
            }
            # Stay in front of the HMI browser (which may also be a kiosk window).
            if (-not $Windowed -and ($script:tick % 10) -eq 0 -and -not $window.IsActive) {
                $window.Topmost = $false; $window.Topmost = $true; [void]$window.Activate()
            }
        } catch { Write-ScreenError $_ }
    })

    $window.Add_ContentRendered({ $timer.Start() })
    $browser.NavigateToString($html)
    [void]$window.ShowDialog()
}
finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
