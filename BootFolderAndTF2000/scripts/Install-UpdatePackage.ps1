<#
.SYNOPSIS
    MACHINE IPC: applies a TwinCAT update package (Boot folder + HMI Server data) from a USB stick.
    Designed to run unattended, e.g. started by the PLC (NT_StartProcess) from an HMI button.

.DESCRIPTION
    Nothing on the machine is touched until the package has been fully validated.
    1. Finds <drive>:\TwinCAT_Update\manifest.json on the attached drives.
    2. Checks the TwinCAT XAR and TF2000 HMI Server versions recorded in the package
       (versions.json) exactly match this machine, and verifies every file in the
       package against its SHA-256 hash.
    3. Switches TwinCAT to Config mode via ADS and stops the HMI Server service.
    4. Backs up the current Boot + HMI folders to C:\TwinCAT_UpdateBackups\<timestamp>.
    5. Mirrors the package folders into place and verifies every file.
    6. On any failure in 4-5: rolls back automatically from the backup.
    7. Reboots the controller.

    Exit codes: 0 = updated, 1 = failed before anything was changed,
                2 = failed and rolled back, 3 = failed AND rollback failed (manual fix needed),
                4 = another update is already running.

    Result is also written to <LocalBackupRoot>\last_update_status.txt and a copy of the
    log is written to the USB stick (TwinCAT_Update\Logs).

.PARAMETER PackagePath
    Full path of the package folder. Default: search all drives for \TwinCAT_Update.

.PARAMETER NoReboot
    Do not reboot; restart the HMI Server and put TwinCAT back into Run mode instead.

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

function Find-UpdatePackage {
    param([string]$FolderName)
    $found = @(foreach ($d in [IO.DriveInfo]::GetDrives()) {
        if (-not $d.IsReady -or $d.DriveType -notin 'Removable', 'Fixed') { continue }
        $p = Join-Path $d.RootDirectory.FullName $FolderName
        if (Test-Path -LiteralPath (Join-Path $p 'manifest.json') -PathType Leaf) { $p }
    })
    if ($found.Count -eq 0) { throw "No update package found (looked for <drive>:\$FolderName\manifest.json on all drives)." }
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

$exitCode = 1
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$machineTouched = $false     # true once the target folders may have been modified
$stopped = $false            # true once TwinCAT/HMI were stopped
$servicesToStart = @()
$mutex = $null
$S = $null
$pkg = $null

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

    # =========================================================================
    #  PHASE 1 - validate. Nothing on the machine is changed in this phase.
    # =========================================================================
    $pkg = if ($PackagePath) { Get-NormalizedPath $PackagePath } else { Find-UpdatePackage $S.PackageFolderName }
    $manifest = Read-Manifest $pkg
    Write-Log "Package: $pkg"
    Write-Log "  created $($manifest.CreatedLocal) on $($manifest.ComputerName), TwinCAT $($manifest.TwinCATVersion)"
    if ($manifest.Purpose -ne 'UpdatePackage') { throw "'$pkg' is not an update package (purpose: $($manifest.Purpose))." }

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

    Write-Log -Level STEP 'Verifying package integrity (SHA-256)...'
    foreach ($p in $plan) {
        $problems = @(Compare-FolderToManifest -Root (Join-Path $pkg $p.Name) -ManifestItem $p.Manifest)
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
    Set-TwinCATMode -Mode Config -TimeoutSec $S.AdsStateTimeoutSec
    $servicesToStart = @(Stop-ServiceWithTimeout -Name $S.HmiServiceName -TimeoutSec $S.ServiceStopTimeoutSec)

    $backupDir = Join-Path $S.LocalBackupRoot "${stamp}_before_update"
    Write-Log -Level STEP "Backing up current version to $backupDir"
    $backupEntries = foreach ($p in $plan) {
        [pscustomobject]@{ Name = $p.Name; Description = $p.Description; SourcePath = $p.Target; ExcludeFiles = @(); ExcludeDirs = @() }
    }
    $backupManifest = New-FolderSnapshot -Entries @($backupEntries) -Destination $backupDir -Purpose 'PreUpdateBackup'
    Write-VersionFile -Path (Join-Path $backupDir 'versions.json') -Versions $localVersions

    try {
        foreach ($p in $plan) {
            Write-Log -Level STEP "[$($p.Name)] replacing $($p.Target)"
            $machineTouched = $true
            Invoke-Robocopy -Source (Join-Path $pkg $p.Name) -Destination $p.Target -Mirror `
                -ExcludeFiles $p.ExcludeFiles -ExcludeDirs $p.ExcludeDirs -LogPath (Join-Path $backupDir 'apply-robocopy.log')
        }
        Write-Log -Level STEP 'Verifying installed files (SHA-256)...'
        foreach ($p in $plan) {
            $problems = @(Compare-FolderToManifest -Root $p.Target -ManifestItem $p.Manifest)
            if ($problems.Count) {
                $problems | Select-Object -First 20 | ForEach-Object { Write-Log -Level ERROR "  [$($p.Name)] $_" }
                throw "Verification failed for '$($p.Name)' ($($problems.Count) problem(s))."
            }
            Write-Log -Level OK "[$($p.Name)] installed and verified"
        }
    }
    catch {
        Write-Log -Level ERROR "Update failed: $($_.Exception.Message)"
        Write-Log -Level STEP "ROLLING BACK from $backupDir"
        $rollbackOk = $true
        foreach ($bi in $backupManifest.Items) {
            $p = $plan | Where-Object { $_.Name -eq $bi.Name }
            try {
                Invoke-Robocopy -Source (Join-Path $backupDir $bi.Name) -Destination $p.Target -Mirror -LogPath (Join-Path $backupDir 'rollback-robocopy.log')
                $problems = @(Compare-FolderToManifest -Root $p.Target -ManifestItem $bi)
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
    Write-Log -Level ERROR $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Log -Level ERROR ($_.ScriptStackTrace -replace '\r?\n', ' <- ') }
}
finally {
    $statusText = switch ($exitCode) {
        0 { 'SUCCESS' } 1 { 'FAILED - nothing changed' } 2 { 'FAILED - previous version restored' }
        3 { 'FAILED - ROLLBACK FAILED, manual repair needed' } default { "EXIT $exitCode" }
    }
    if ($S) {
        Write-Status $S.LocalBackupRoot $statusText "Package: $pkg"

        # Copy the log onto the USB stick so the result can be checked on the bench.
        if ($pkg -and $script:LogFile -and (Test-Path -LiteralPath $pkg)) {
            try {
                $usbLogs = Join-Path $pkg 'Logs'
                New-Item -ItemType Directory -Path $usbLogs -Force | Out-Null
                Copy-Item -LiteralPath $script:LogFile -Destination (Join-Path $usbLogs "$($env:COMPUTERNAME)_$stamp`_$($statusText -replace '[^A-Za-z]+', '_').log") -Force
            } catch { Write-Log -Level WARN "Could not copy log to USB: $($_.Exception.Message)" }
        }

        if ($stopped) {
            if ($exitCode -eq 3) {
                Write-Log -Level ERROR 'Machine left stopped (Config mode) because the rollback failed. NOT rebooting.'
            } elseif ($S.RebootAfterApply -and -not $NoReboot) {
                Write-Log -Level STEP "Rebooting in $($S.RebootDelaySeconds) s..."
                & shutdown.exe /r /f /t $S.RebootDelaySeconds /d p:4:1 /c "TwinCAT update: $statusText"
            } else {
                foreach ($svc in $servicesToStart) { [void](Start-ServiceSafe -Name $svc -TimeoutSec $S.ServiceStopTimeoutSec) }
                try { Set-TwinCATMode -Mode Run -TimeoutSec $S.AdsStateTimeoutSec }
                catch { Write-Log -Level ERROR "Could not switch TwinCAT to Run mode: $($_.Exception.Message)" }
            }
        }
        Write-Log "Result: $statusText (exit code $exitCode)"
    }
    Close-Ads
    if ($mutex) { $mutex.ReleaseMutex(); $mutex.Dispose() }
}
exit $exitCode
