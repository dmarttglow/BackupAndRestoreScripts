<#
.SYNOPSIS
    BENCH SYSTEM: builds a TwinCAT update package (Boot folder + HMI Server data) on a USB stick.

.DESCRIPTION
    1. Switches TwinCAT to Config mode via ADS and stops the TwinCAT HMI Server service.
    2. Copies the Boot folder and HMI Server folder into a local build folder (%TEMP%),
       hashes every file (SHA-256) and writes manifest.json.
    3. Restarts the HMI Server and puts TwinCAT back into Run mode if it was running.
    4. Zips the build folder to a single file, <USB>\TwinCAT_Update.zip (written as .partial
       first; the previous package is kept as TwinCAT_Update_previous.zip). The bench log is
       written next to it as TwinCAT_Update_create.log.

.PARAMETER Destination
    Drive or folder in which to create the package zip (e.g. E:\).
    Default: the removable drive this script runs from, or the only removable drive present.

.PARAMETER NoStop
    Do not stop TwinCAT / the HMI Server before copying (not recommended).

.PARAMETER LeaveStopped
    Leave TwinCAT in Config mode and the HMI Server stopped afterwards.
#>
[CmdletBinding()]
param(
    [string]$Destination,
    [string]$ConfigPath,
    [switch]$NoStop,
    [switch]$LeaveStopped
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')
if (-not $ConfigPath) { $ConfigPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Config.ps1' }

function Resolve-PackageDestination {
    param([string]$Requested)
    if ($Requested) {
        if (-not (Test-Path -LiteralPath $Requested -PathType Container)) { throw "Destination '$Requested' does not exist." }
        return (Get-NormalizedPath $Requested)
    }
    $removable = @([IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady -and $_.DriveType -eq 'Removable' })
    $ownDrive = [IO.Path]::GetPathRoot($PSScriptRoot)
    $own = $removable | Where-Object { $_.RootDirectory.FullName -eq $ownDrive }
    if ($own) { return $own.RootDirectory.FullName }
    if ($removable.Count -eq 1) { return $removable[0].RootDirectory.FullName }
    if ($removable.Count -eq 0) { throw 'No USB stick found. Insert one or pass -Destination.' }
    throw "Several removable drives found ($(($removable | ForEach-Object { $_.Name }) -join ', ')). Pass -Destination to choose one."
}

# Restarts what was stopped. Does its work once: right after the copy, or in finally on failure.
function Restore-BenchState {
    if ($LeaveStopped) {
        if ($script:adsUsed) { Write-Log -Level WARN '-LeaveStopped given: TwinCAT left in Config mode, HMI Server left stopped.' }
        $script:adsUsed = $false
        return
    }
    foreach ($svc in $script:servicesToStart) { [void](Start-ServiceSafe -Name $svc -TimeoutSec $S.ServiceStopTimeoutSec) }
    $script:servicesToStart = @()
    if ($script:tcWasRunning) {
        $script:tcWasRunning = $false
        try { Set-TwinCATMode -Mode Run -TimeoutSec $S.AdsStateTimeoutSec }
        catch { Write-Log -Level WARN "Could not return TwinCAT to Run mode: $($_.Exception.Message)"; $script:restoreFailed = $true }
    }
}

$exitCode = 1
$tcWasRunning = $false
$servicesToStart = @()
$adsUsed = $false
$restoreFailed = $false
$buildDir = $null

try {
    Assert-Prerequisites
    $config = Import-UpdateConfig -Path $ConfigPath
    $S = $config.Settings

    Initialize-Zip
    $destRoot = Resolve-PackageDestination $Destination
    # The package is a single zip at the root of the stick, with its log next to it.
    $pkgName = $S.PackageFolderName
    $zipFinal = Join-Path $destRoot "$pkgName.zip"
    $zipTemp = "$zipFinal.partial"
    $zipPrev = Join-Path $destRoot "${pkgName}_previous.zip"
    $logFinal = Join-Path $destRoot "${pkgName}_create.log"
    $logPrev = Join-Path $destRoot "${pkgName}_create_previous.log"
    $logTemp = Join-Path $destRoot "${pkgName}_create.partial.log"

    # A <name> package folder from an older version of this tool would also be picked up by
    # Apply-Update: move it out of the way as <name>_old.
    $oldDir = Join-Path $destRoot $pkgName
    $oldMoved = $null
    if (Test-Path -LiteralPath $oldDir -PathType Container) {
        $oldMoved = "${oldDir}_old"
        if (Test-Path -LiteralPath $oldMoved) { Remove-Item -LiteralPath $oldMoved -Recurse -Force }
        Rename-Item -LiteralPath $oldDir -NewName (Split-Path -Leaf $oldMoved)
    }
    if (Test-Path -LiteralPath $logTemp) { Remove-Item -LiteralPath $logTemp -Force }
    Start-Log $logTemp

    Write-Log -Level STEP '=== Create TwinCAT update package (bench) ==='
    Write-Log "Running as $([Security.Principal.WindowsIdentity]::GetCurrent().Name) on $env:COMPUTERNAME"
    if ($oldMoved) { Write-Log -Level WARN "Package folder from an older version moved to $oldMoved (can be deleted)" }
    $tc = Get-TwinCATInfo
    Write-Log "TwinCAT version: $($tc.Version)   AMS Net ID: $($tc.AmsNetId)"
    Write-Log "Package file:    $zipFinal"

    $buildDir = Join-Path ([IO.Path]::GetTempPath()) "$($S.PackageFolderName)_build"
    if (Test-Path -LiteralPath $buildDir) { Remove-Item -LiteralPath $buildDir -Recurse -Force }
    New-Item -ItemType Directory -Path $buildDir -Force | Out-Null
    Write-Log "Build folder:    $buildDir"

    # --- Record installed versions (checked by Apply-Update on the machine) -------
    $versions = Get-InstalledVersions -HmiServiceName $S.HmiServiceName
    foreach ($k in $versions.Keys) {
        if (-not $versions[$k]) { throw "Could not read the installed $k version on this bench system." }
        Write-Log "Version $($k.PadRight(18)) $($versions[$k])"
    }
    Write-VersionFile -Path (Join-Path $buildDir 'versions.json') -Versions $versions

    # --- Resolve source folders -------------------------------------------------
    $entries = foreach ($item in $config.Items) {
        $src = Resolve-ItemFolder $item
        if (-not $src) {
            $msg = "[$($item.Name)] no folder found. Checked: $($item.Candidates -join ' | ')"
            if ($item.Required) { throw $msg }
            Write-Log -Level WARN "$msg - skipping"
            continue
        }
        Write-Log "[$($item.Name)] source: $src"
        if ($item.ExcludeFiles.Count) { Write-Log "[$($item.Name)] excluded files: $($item.ExcludeFiles -join ', ')" }
        [pscustomobject]@{
            Name = $item.Name; Description = $item.Description; SourcePath = $src
            ExcludeFiles = $item.ExcludeFiles; ExcludeDirs = $item.ExcludeDirs
        }
    }
    $entries = @($entries)
    if ($entries.Count -eq 0) { throw 'Nothing to package.' }

    # --- Free space check -------------------------------------------------------
    $needed = [long]0
    foreach ($e in $entries) {
        foreach ($f in Get-FolderInventory -Root $e.SourcePath -ExcludeFiles $e.ExcludeFiles -ExcludeDirs $e.ExcludeDirs -NoHash) { $needed += $f.Size }
    }
    # The zip is never much bigger than the files, so the same margin covers both drives.
    $free = (New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($zipTemp))).AvailableFreeSpace
    $freeBuild = (New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($buildDir))).AvailableFreeSpace
    Write-Log ("Package size: {0:N1} MB, free on destination: {1:N1} MB, free for build folder: {2:N1} MB" -f ($needed / 1MB), ($free / 1MB), ($freeBuild / 1MB))
    if ($free -lt ($needed * 1.1 + 10MB)) { throw 'Not enough free space on the destination drive.' }
    if ($freeBuild -lt ($needed * 1.1 + 10MB)) { throw "Not enough free space for the build folder $buildDir." }

    # --- Stop TwinCAT runtime + HMI Server ---------------------------------------
    if ($NoStop) {
        Write-Log -Level WARN '-NoStop given: copying while TwinCAT and the HMI Server are running.'
    } else {
        $adsUsed = $true
        $tcWasRunning = (Get-TwinCATState) -eq 'Run'
        Set-TwinCATMode -Mode Config -TimeoutSec $S.AdsStateTimeoutSec
        $servicesToStart = @(Stop-ServiceWithTimeout -Name $S.HmiServiceName -TimeoutSec $S.ServiceStopTimeoutSec)
    }

    # --- Copy + hash ------------------------------------------------------------
    $manifest = New-FolderSnapshot -Entries $entries -Destination $buildDir -Purpose 'UpdatePackage'
    Restore-BenchState   # copy done: TwinCAT and the HMI Server can run again while zipping

    # --- Zip onto the stick -------------------------------------------------------
    Write-Log -Level STEP "Zipping package to $zipTemp"
    Compress-Folder -Folder $buildDir -ZipPath $zipTemp

    # --- Publish: .partial -> final (keep one previous package) -------------------
    if (Test-Path -LiteralPath $zipFinal) {
        if (Test-Path -LiteralPath $zipPrev) { Remove-Item -LiteralPath $zipPrev -Force }
        Rename-Item -LiteralPath $zipFinal -NewName (Split-Path -Leaf $zipPrev)
        Write-Log "Previous package kept as $zipPrev"
    }
    Rename-Item -LiteralPath $zipTemp -NewName (Split-Path -Leaf $zipFinal)
    if (Test-Path -LiteralPath $logFinal) { Move-Item -LiteralPath $logFinal -Destination $logPrev -Force }
    Move-Item -LiteralPath $logTemp -Destination $logFinal -Force
    $script:LogFile = $logFinal

    foreach ($i in $manifest.Items) { Write-Log -Level OK ("  {0,-6} {1,6} files  {2,10:N1} MB" -f $i.Name, $i.FileCount, ($i.TotalBytes / 1MB)) }
    Write-Log -Level OK "Package created: $zipFinal"
    $exitCode = 0
}
catch {
    Write-Log -Level ERROR $_.Exception.Message
    Write-Log -Level ERROR ($_.ScriptStackTrace -replace '\r?\n', ' <- ')
    Write-Log -Level ERROR 'Package NOT created. Any incomplete zip is left as *.partial and will never be used.'
}
finally {
    if ($S) { Restore-BenchState }
    if ($restoreFailed) { $exitCode = 1 }
    if ($buildDir -and (Test-Path -LiteralPath $buildDir)) { Remove-Item -LiteralPath $buildDir -Recurse -Force -ErrorAction SilentlyContinue }
    Close-Ads
}
exit $exitCode
