<#
.SYNOPSIS
    MACHINE IPC: applies a TwinCAT update package (Boot folder + HMI Server data) from a USB stick.
    Designed to run unattended, e.g. started by the PLC (NT_StartProcess) from an HMI button.

.DESCRIPTION
    Nothing on the machine is touched until the package has been fully validated.
    1. Finds <drive>:\TwinCAT_Update.zip on the attached drives and unzips
       it to <LocalBackupRoot>\Staging (deleted again at the end).
    2. Checks the TwinCAT XAR and TF2000 HMI Server versions recorded in the package
       (versions.json) exactly match this machine, and verifies every file in the
       package against its SHA-256 hash.
    3. Switches TwinCAT to Config mode via ADS and stops the HMI Server service.
    4. Backs up the current Boot + HMI folders to C:\TwinCAT_UpdateBackups\<timestamp>.
    5. Mirrors the package folders into place and verifies every file.
    6. On any failure in 4-5: rolls back automatically from the backup.
    7. Switches TwinCAT back to Run mode and starts the HMI Server again (no controller
       restart, unless RebootAfterApply = $true in Config.ps1). If either does not come
       back, restarts the controller (RebootIfStartFails = $true).

    Exit codes: 0 = updated, 1 = failed before anything was changed,
                2 = failed and rolled back, 3 = failed AND rollback failed (manual fix needed),
                4 = another update is already running,
                5 = updated, but TwinCAT or the HMI Server did not start again
                    (the controller is restarted, see RebootIfStartFails).

    Result is also written to <LocalBackupRoot>\last_update_status.txt and a copy of the
    log is written to the USB stick (TwinCAT_Update_Logs, next to the zip).

.PARAMETER PackagePath
    Full path of the package zip, or of the folder that contains it.
    Default: search all drives for \TwinCAT_Update.zip (and the older \TwinCAT_Update\ folder).
    An unzipped package folder from an older version of this tool also works.

.PARAMETER NoReboot
    Do not reboot even if RebootAfterApply = $true (the default is already no reboot).

.PARAMETER AllowVersionMismatch
    Apply even if the XAR / TF2000 versions in the package differ from this machine
    (manual use only - the mismatch is still logged).
#>
[CmdletBinding()]
param(
    [string]$PackagePath,
    [string]$ConfigPath,
    [switch]$NoReboot,
    [switch]$AllowVersionMismatch
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not $ConfigPath) { $ConfigPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Config.ps1' }

# Returns the package found in Folder: <Name>.zip in it, or Folder itself if it is an unzipped
# package (manifest.json). Older versions of this tool used a <Name> folder holding <Name>.zip,
# or an unzipped <Name> folder: both are still found. Returns $null if there is none.
function Get-PackageInFolder {
    param([string]$Folder, [string]$Name)
    $zip = Join-Path $Folder "$Name.zip"
    if (Test-Path -LiteralPath $zip -PathType Leaf) { return $zip }
    if (Test-Path -LiteralPath (Join-Path $Folder 'manifest.json') -PathType Leaf) { return $Folder }
    $null
}

function Find-UpdatePackage {
    param([string]$Name)
    $found = @(foreach ($d in [IO.DriveInfo]::GetDrives()) {
        if (-not $d.IsReady -or $d.DriveType -notin 'Removable', 'Fixed') { continue }
        $root = $d.RootDirectory.FullName
        Get-PackageInFolder $root $Name                                # current: <drive>:\<Name>.zip
        $old = Join-Path $root $Name
        if (Test-Path -LiteralPath $old -PathType Container) { Get-PackageInFolder $old $Name }   # older layouts
    })
    $found = @($found | Where-Object { $_ })
    if ($found.Count -eq 0) { throw "No update package found (looked for <drive>:\$Name.zip on all drives)." }
    if ($found.Count -gt 1) { throw "Several update packages found: $($found -join ', '). Remove all but one, or pass -PackagePath." }
    $found[0]
}

function Write-Status {
    param([string]$Root, [string]$Status, [string]$Detail)
    try {
        if (-not (Test-Path -LiteralPath $Root)) { New-Item -ItemType Directory -Path $Root -Force | Out-Null }
        @("Status:  $Status", "Time:    $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')", "Detail:  $Detail", "Log:     $script:LogFile") |
            Set-Content -LiteralPath (Join-Path $Root 'last_update_status.txt') -Encoding UTF8
    } catch { }
}

function Remove-OldBackups {
    param([string]$Root, [int]$Keep)
    if ($Keep -lt 1) { return }
    $old = @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d{8}_\d{6}_before_update$' } |
        Sort-Object Name -Descending | Select-Object -Skip $Keep)
    foreach ($o in $old) {
        Write-Log "Removing old backup $($o.FullName)"
        Remove-Item -LiteralPath $o.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Brings the machine back after the update (or a rollback): TwinCAT into Run mode first, so
# the HMI Server finds the PLC straight away, then the HMI Server and any services stopped
# with it. Each is retried once. Returns $true only if TwinCAT is in Run mode and every
# service is running.
function Start-MachineAgain {
    param([string[]]$Services)
    Set-ProgressStep restart 'Starting TwinCAT and the HMI Server' 97 99
    $ok = $true
    $runTimeout = [Math]::Max(60, [int]$S.AdsStateTimeoutSec)   # Config -> Run restarts the runtime: allow for big projects

    $tcOk = $false
    for ($try = 1; $try -le 2 -and -not $tcOk; $try++) {
        try { Set-TwinCATMode -Mode Run -TimeoutSec $runTimeout; $tcOk = $true }
        catch { Write-Log -Level WARN "TwinCAT Run mode, attempt $try of 2: $($_.Exception.Message)" }
    }
    if (-not $tcOk) {
        Write-Log -Level ERROR 'TwinCAT did not go back to Run mode. Check the TwinCAT error list / licences on this machine.'
        $ok = $false
    }

    # Always the HMI Server, even if it was not running before the update.
    $names = @(@($Services) + @($S.HmiServiceName) | Where-Object { $_ } | Select-Object -Unique)
    foreach ($name in $names) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if (-not $svc) { Write-Log -Level WARN "Service '$name' is not installed - not started"; continue }
        if ("$($svc.StartType)" -eq 'Disabled') { Write-Log -Level WARN "Service '$name' is disabled - not started"; continue }
        $started = Start-ServiceSafe -Name $name -TimeoutSec $S.ServiceStartTimeoutSec
        if (-not $started) {
            Start-Sleep -Seconds 5
            $started = Start-ServiceSafe -Name $name -TimeoutSec $S.ServiceStartTimeoutSec
        }
        if (-not $started) { Write-Log -Level ERROR "Service '$name' did not start."; $ok = $false }
    }
    $ok
}

# Full restart of the controller (shutdown /r: never a Fast Startup / hybrid boot; /f: apps are
# closed without asking). Returns $true once a restart is scheduled or started, $false if
# Windows refused, so the caller can bring TwinCAT and the HMI back up instead.
function Restart-Controller {
    param([int]$DelaySec, [string]$Reason, [string]$ProgressState, [string]$ErrorText)
    $DelaySec = [Math]::Max(1, $DelaySec)
    Write-Log -Level STEP "Restarting the controller in $DelaySec s..."
    # shutdown.exe is run through cmd /c: it writes its messages to stderr, which Windows
    # PowerShell turns into a terminating error under $ErrorActionPreference = 'Stop'.
    try {
        [void](& cmd.exe /c 'shutdown.exe /a >nul 2>&1')   # replace a restart that is already pending (e.g. Windows Update)
        $out = & cmd.exe /c "shutdown.exe /r /f /t $DelaySec /d p:4:1 /c `"$Reason`" 2>&1"
        $rc = $LASTEXITCODE
    } catch { $out = $_.Exception.Message; $rc = -1 }

    if ($rc -eq 0) {
        Set-ProgressResult -State $ProgressState -ErrorText $ErrorText -RebootInSec $DelaySec
        Write-Log -Level OK 'Restart scheduled.'
        for ($sec = $DelaySec; $sec -gt 0; $sec--) {
            Write-ProgressLine -Force "$Reason - controller restarts in $sec s  (cancel: shutdown /a)"
            Start-Sleep -Seconds 1
        }
        Clear-ProgressLine
        return $true
    }
    Write-Log -Level WARN "shutdown.exe could not schedule the restart (exit code $rc): $out"
    try {
        Restart-Computer -Force -ErrorAction Stop
        Set-ProgressResult -State $ProgressState -ErrorText $ErrorText -RebootInSec 0
        Write-Log -Level OK 'Restart started (Restart-Computer -Force).'
        return $true
    } catch {
        Write-Log -Level ERROR "RESTART FAILED: $($_.Exception.Message). Starting TwinCAT and the HMI Server again instead - restart the controller by hand."
        return $false
    }
}

$exitCode = 1
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$machineTouched = $false     # true once the target folders may have been modified
$stopped = $false            # true once TwinCAT/HMI were stopped
$servicesToStart = @()
$mutex = $null
$S = $null
$pkg = $null
$pkgSource = $null
$usbDir = $null
$stagingDir = $null
$errorText = ''

try {
    # --- Single instance (double button press, etc.) ----------------------------
    $mutex = New-Object Threading.Mutex($false, 'Global\TwinCAT_Apply_Update')
    $acquired = $false
    try { $acquired = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired = $true }   # previous run was killed
    if (-not $acquired) { $mutex = $null; Write-Host 'Another update is already running.'; exit 4 }

    Assert-Prerequisites
    $config = Import-UpdateConfig -Path $ConfigPath
    $S = $config.Settings
    Start-Log (Join-Path $S.LocalBackupRoot "Logs\Apply_$stamp.log")
    Write-Log -Level STEP '=== Apply TwinCAT update package ==='
    Write-Log "Running as $([Security.Principal.WindowsIdentity]::GetCurrent().Name) on $env:COMPUTERNAME"
    Write-Status $S.LocalBackupRoot 'RUNNING' 'Update in progress'
    # Read by the optional status screen (UpdateScreen\). The update does not depend on it.
    Start-ProgressFile -Path (Join-Path $S.LocalBackupRoot 'update_progress.json') -RunId $stamp
    Set-ProgressStep check 'Looking for the update package' 0 3

    # =========================================================================
    #  PHASE 1 - validate. Nothing on the machine is changed in this phase.
    # =========================================================================
    # $pkgSource: the zip (or old-format unzipped folder) the update comes from.
    # $usbDir: folder on the stick the machine log is copied back to.
    # $pkg: unzipped package (manifest.json, Boot, HMI) that is verified and installed.
    if ($PackagePath -and (Test-Path -LiteralPath $PackagePath -PathType Leaf)) {
        $pkgSource = Get-NormalizedPath $PackagePath
    } elseif ($PackagePath) {
        $pkgSource = Get-PackageInFolder (Get-NormalizedPath $PackagePath) $S.PackageFolderName
        if (-not $pkgSource) { throw "No update package in '$PackagePath' (expected $($S.PackageFolderName).zip or manifest.json)." }
    } else {
        $pkgSource = Find-UpdatePackage $S.PackageFolderName
    }
    if (Test-Path -LiteralPath $pkgSource -PathType Leaf) {
        $usbDir = Join-Path (Split-Path -Parent $pkgSource) "$($S.PackageFolderName)_Logs"
    } else {
        $usbDir = Join-Path $pkgSource 'Logs'
    }
    Write-Log "Package: $pkgSource"

    if (Test-Path -LiteralPath $pkgSource -PathType Leaf) {
        $stagingDir = Join-Path $S.LocalBackupRoot 'Staging'
        if (Test-Path -LiteralPath $stagingDir) { Remove-Item -LiteralPath $stagingDir -Recurse -Force }
        $unzipBytes = Get-ZipContentSize $pkgSource
        $stagingFree = (New-Object IO.DriveInfo ([IO.Path]::GetPathRoot((Get-NormalizedPath $S.LocalBackupRoot)))).AvailableFreeSpace
        if ($stagingFree -lt ($unzipBytes * 1.1 + 50MB)) {
            throw ("Not enough free space to unzip the package ({0:N1} MB needed in {1})." -f ($unzipBytes / 1MB), $S.LocalBackupRoot)
        }
        Set-ProgressStep unpack 'Unpacking the update package' 3 20
        Write-Log -Level STEP "Unzipping package to $stagingDir"
        Expand-ZipFile -ZipPath $pkgSource -Destination $stagingDir
        $pkg = $stagingDir
    } else {
        Write-Log -Level WARN 'Package is an unzipped folder (older format) - using it directly.'
        $pkg = $pkgSource
    }

    $manifest = Read-Manifest $pkg
    Write-Log "  created $($manifest.CreatedLocal) on $($manifest.ComputerName), TwinCAT $($manifest.TwinCATVersion)"
    if ($manifest.Purpose -ne 'UpdatePackage') { throw "'$pkg' is not an update package (purpose: $($manifest.Purpose))." }

    Set-ProgressStep check 'Checking versions and package contents' 20 22

    # Versions must match exactly: XAR and TF2000 on this machine vs. the bench that built the package.
    $pkgVersions = Read-VersionFile (Join-Path $pkg 'versions.json')
    $localVersions = Get-InstalledVersions -HmiServiceName $S.HmiServiceName
    foreach ($k in $pkgVersions.Keys) {
        Write-Log ("Version {0} package {1,-14} this machine {2}" -f $k.PadRight(18), $pkgVersions[$k], $(if ($localVersions[$k]) { $localVersions[$k] } else { '(unknown)' }))
    }
    $mismatches = @(Compare-Versions -Expected $pkgVersions -Actual $localVersions)
    if ($mismatches.Count) {
        $mismatches | ForEach-Object { Write-Log -Level ERROR "  VERSION MISMATCH - $_" }
        if (-not $AllowVersionMismatch) {
            throw "Installed versions do not match the package ($($mismatches.Count) mismatch(es)). Nothing was changed."
        }
        Write-Log -Level WARN '-AllowVersionMismatch given: continuing despite the version mismatch.'
    } else {
        Write-Log -Level OK 'Installed XAR and TF2000 versions match the package'
    }
    Write-Log "This machine: AMS Net ID $((Get-TwinCATInfo).AmsNetId)"

    # Map package items -> target folders on this machine.
    $plan = foreach ($mi in $manifest.Items) {
        $ci = $config.Items | Where-Object { $_.Name -eq $mi.Name } | Select-Object -First 1
        if (-not $ci) { Write-Log -Level WARN "[$($mi.Name)] not in Config.ps1 - skipping"; continue }
        $target = Resolve-ItemFolder $ci
        if (-not $target) { throw "[$($mi.Name)] target folder not found on this machine. Checked: $($ci.Candidates -join ' | ')" }
        # Union of exclusions: never delete on the machine anything the package did not capture.
        $xf = @(@($ci.ExcludeFiles) + @($mi.ExcludeFiles) | Where-Object { $_ } | Select-Object -Unique)
        $xd = @(@($ci.ExcludeDirs) + @($mi.ExcludeDirs) | Where-Object { $_ } | Select-Object -Unique)
        Write-Log "[$($mi.Name)] $($mi.FileCount) files -> $target"
        if ($xf.Count) { Write-Log "[$($mi.Name)] kept on machine (not replaced): $($xf -join ', ')" }
        [pscustomobject]@{ Name = $mi.Name; Description = $ci.Description; Target = $target; Manifest = $mi; ExcludeFiles = $xf; ExcludeDirs = $xd }
    }
    $plan = @($plan)
    foreach ($ci in $config.Items | Where-Object { $_.Required }) {
        if (-not ($plan | Where-Object { $_.Name -eq $ci.Name })) { throw "Package does not contain required item '$($ci.Name)'." }
    }

    Set-ProgressStep verify 'Verifying the update package' 22 35
    Write-Log -Level STEP 'Verifying package integrity (SHA-256)...'
    foreach ($p in $plan) {
        $problems = @(Compare-FolderToManifest -Root (Join-Path $pkg $p.Name) -ManifestItem $p.Manifest -Activity "Checking package [$($p.Name)]")
        if ($problems.Count) {
            $problems | Select-Object -First 20 | ForEach-Object { Write-Log -Level ERROR "  [$($p.Name)] $_" }
            throw "Package is corrupt or incomplete ($($problems.Count) problem(s) in '$($p.Name)')."
        }
        Write-Log -Level OK "[$($p.Name)] package verified"
    }

    $needed = [long]0
    foreach ($p in $plan) { foreach ($f in Get-FolderInventory -Root $p.Target -NoHash) { $needed += $f.Size } }
    $backupDrive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot((Get-NormalizedPath $S.LocalBackupRoot)))
    if ($backupDrive.AvailableFreeSpace -lt ($needed * 1.1 + 50MB)) {
        throw ("Not enough free space for the local backup ({0:N1} MB needed)." -f ($needed / 1MB))
    }
    Initialize-Ads   # fail now (before stopping anything) if ADS is not available
    Write-Log -Level OK 'Validation passed.'

    # =========================================================================
    #  PHASE 2 - stop, back up, replace, verify
    # =========================================================================
    $stopped = $true
    Set-ProgressStep stop 'Stopping TwinCAT and the HMI Server' 35 40
    Set-TwinCATMode -Mode Config -TimeoutSec $S.AdsStateTimeoutSec
    $servicesToStart = @(Stop-ServiceWithTimeout -Name $S.HmiServiceName -TimeoutSec $S.ServiceStopTimeoutSec)

    $backupDir = Join-Path $S.LocalBackupRoot "${stamp}_before_update"
    Set-ProgressStep backup 'Backing up the current version' 40 60
    Write-Log -Level STEP "Backing up current version to $backupDir"
    $backupEntries = foreach ($p in $plan) {
        [pscustomobject]@{ Name = $p.Name; Description = $p.Description; SourcePath = $p.Target; ExcludeFiles = @(); ExcludeDirs = @() }
    }
    $backupManifest = New-FolderSnapshot -Entries @($backupEntries) -Destination $backupDir -Purpose 'PreUpdateBackup'
    Write-VersionFile -Path (Join-Path $backupDir 'versions.json') -Versions $localVersions

    try {
        Set-ProgressStep install 'Installing the new version' 60 75
        foreach ($p in $plan) {
            Write-Log -Level STEP "[$($p.Name)] replacing $($p.Target)"
            $machineTouched = $true
            Invoke-Robocopy -Source (Join-Path $pkg $p.Name) -Destination $p.Target -Mirror -Label "Installing [$($p.Name)]" `
                -ExcludeFiles $p.ExcludeFiles -ExcludeDirs $p.ExcludeDirs -LogPath (Join-Path $backupDir 'apply-robocopy.log')
        }
        Set-ProgressStep verifyinstall 'Verifying the installed files' 75 97
        Write-Log -Level STEP 'Verifying installed files (SHA-256)...'
        foreach ($p in $plan) {
            $problems = @(Compare-FolderToManifest -Root $p.Target -ManifestItem $p.Manifest -Activity "Verifying installed [$($p.Name)]")
            if ($problems.Count) {
                $problems | Select-Object -First 20 | ForEach-Object { Write-Log -Level ERROR "  [$($p.Name)] $_" }
                throw "Verification failed for '$($p.Name)' ($($problems.Count) problem(s))."
            }
            Write-Log -Level OK "[$($p.Name)] installed and verified"
        }
    }
    catch {
        Write-Log -Level ERROR "Update failed: $($_.Exception.Message)"
        Set-ProgressStep rollback 'Update failed - restoring the previous version' 60 97
        Write-Log -Level STEP "ROLLING BACK from $backupDir"
        $rollbackOk = $true
        foreach ($bi in $backupManifest.Items) {
            $p = $plan | Where-Object { $_.Name -eq $bi.Name }
            try {
                Invoke-Robocopy -Source (Join-Path $backupDir $bi.Name) -Destination $p.Target -Mirror -Label "Rolling back [$($bi.Name)]" -LogPath (Join-Path $backupDir 'rollback-robocopy.log')
                $problems = @(Compare-FolderToManifest -Root $p.Target -ManifestItem $bi -Activity "Verifying rollback [$($bi.Name)]")
                if ($problems.Count) { throw "$($problems.Count) file(s) differ after rollback" }
                Write-Log -Level OK "[$($bi.Name)] rolled back"
            } catch {
                $rollbackOk = $false
                Write-Log -Level ERROR "[$($bi.Name)] ROLLBACK FAILED: $($_.Exception.Message)"
            }
        }
        if (-not $rollbackOk) {
            $exitCode = 3
            throw "Update failed and rollback failed. Restore manually from $backupDir"
        }
        $exitCode = 2
        throw 'Update failed; previous version restored.'
    }

    $exitCode = 0
    Write-Log -Level OK "UPDATE SUCCESSFUL. Previous version saved in $backupDir"
    Remove-OldBackups -Root $S.LocalBackupRoot -Keep $S.BackupsToKeep
}
catch {
    if ($exitCode -eq 0) { $exitCode = 1 }
    if ($exitCode -eq 1 -and $machineTouched) { $exitCode = 3 }   # failed while copying, outside the rollback block
    $errorText = $_.Exception.Message
    Write-Log -Level ERROR $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Log -Level ERROR ($_.ScriptStackTrace -replace '\r?\n', ' <- ') }
}
finally {
    $rebootWanted = $false
    $startFailed = $false
    if ($S -and $stopped) {
        if ($exitCode -eq 3) {
            Write-Log -Level ERROR 'Machine left stopped (Config mode) because the rollback failed.'
        } elseif ($S.RebootAfterApply -and -not $NoReboot) {
            $rebootWanted = $true
        } else {
            # Normal case: start TwinCAT (Run mode) and the HMI Server again, no controller restart.
            if (-not (Start-MachineAgain -Services $servicesToStart)) {
                # They did not come back: restart the whole controller, which starts both from scratch.
                $startFailed = $true
                $rebootWanted = $S.RebootIfStartFails -and -not $NoReboot
                if ($exitCode -eq 0) {
                    $exitCode = 5
                    $errorText = if ($rebootWanted) { 'The update was installed, but TwinCAT or the HMI Server did not start again. Restarting the controller.' }
                                 else { 'The update was installed, but TwinCAT or the HMI Server did not start again. Restart the controller.' }
                }
                Write-Log -Level ERROR ('TwinCAT or the HMI Server did not start again. ' +
                    $(if ($rebootWanted) { 'Restarting the controller.' } else { 'Not restarting the controller (RebootIfStartFails off or -NoReboot) - restart it by hand.' }))
            }
        }
    }
    $statusText = switch ($exitCode) {
        0 { 'SUCCESS' } 1 { 'FAILED - nothing changed' } 2 { 'FAILED - previous version restored' }
        3 { 'FAILED - ROLLBACK FAILED, manual repair needed' }
        5 { if ($rebootWanted) { 'UPDATED - TwinCAT or the HMI did not start, controller restarted' } else { 'UPDATED - but TwinCAT or the HMI did not start again' } }
        default { "EXIT $exitCode" }
    }
    if ($S) {
        Write-Status $S.LocalBackupRoot $statusText "Package: $pkgSource"
        Write-Log "Result: $statusText (exit code $exitCode)"

        if ($stagingDir -and (Test-Path -LiteralPath $stagingDir)) {
            Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        # Copy the log onto the USB stick so the result can be checked on the bench.
        if ($usbDir -and $script:LogFile -and (Test-Path -LiteralPath (Split-Path -Parent $usbDir))) {
            try {
                $usbLogs = $usbDir
                New-Item -ItemType Directory -Path $usbLogs -Force | Out-Null
                Copy-Item -LiteralPath $script:LogFile -Destination (Join-Path $usbLogs "$($env:COMPUTERNAME)_$stamp`_$($statusText -replace '[^A-Za-z]+', '_').log") -Force
            } catch { Write-Log -Level WARN "Could not copy log to USB: $($_.Exception.Message)" }
        }

        $progressState = switch ($exitCode) { 0 { 'Success' } 2 { 'RolledBack' } 3 { 'RollbackFailed' } 5 { 'StartFailed' } default { 'Failed' } }
        $rebooting = $false
        if ($rebootWanted) {   # RebootAfterApply = $true, or TwinCAT / the HMI Server did not start again
            $rebooting = Restart-Controller -DelaySec $S.RebootDelaySeconds -Reason "TwinCAT update: $statusText" -ProgressState $progressState -ErrorText $errorText
            if (-not $rebooting -and -not $startFailed) { [void](Start-MachineAgain -Services $servicesToStart) }
            if (-not $rebooting -and $startFailed) {
                $errorText = 'The update was installed, but TwinCAT or the HMI Server did not start again, and the controller could not be restarted. Restart it by hand.'
                $statusText = 'UPDATED - TwinCAT or the HMI did not start, RESTART FAILED - restart by hand'
                Write-Status $S.LocalBackupRoot $statusText "Package: $pkgSource"
                Write-Log -Level ERROR "Result: $statusText (exit code $exitCode)"
            }
        }
        if (-not $rebooting) { Set-ProgressResult -State $progressState -ErrorText $errorText }
    }
    Close-Ads
    if ($mutex) { $mutex.ReleaseMutex(); $mutex.Dispose() }
}
exit $exitCode
