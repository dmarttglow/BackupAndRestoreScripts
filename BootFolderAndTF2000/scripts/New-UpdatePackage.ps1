<#
.SYNOPSIS
    BENCH SYSTEM: builds a TwinCAT update package (Boot folder + HMI Server data) on a USB stick.

.DESCRIPTION
    1. Switches TwinCAT to Config mode via ADS and stops the TwinCAT HMI Server service.
    2. Copies the Boot folder and HMI Server folder into <USB>\TwinCAT_Update.partial,
       hashes every file (SHA-256) and writes manifest.json.
    3. Renames the folder to <USB>\TwinCAT_Update (the previous package is kept as
       TwinCAT_Update_previous).
    4. Restarts the HMI Server and puts TwinCAT back into Run mode if it was running.

.PARAMETER Destination
    Drive or folder in which to create the package folder (e.g. E:\).
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

$exitCode = 1
$tcWasRunning = $false
$servicesToStart = @()
$adsUsed = $false

try {
    Assert-Prerequisites
    $config = Import-UpdateConfig -Path $ConfigPath
    $S = $config.Settings

    $destRoot = Resolve-PackageDestination $Destination
    $pkgFinal = Join-Path $destRoot $S.PackageFolderName
    $pkgTemp = "$pkgFinal.partial"
    $pkgPrev = "$($pkgFinal)_previous"

    if (Test-Path -LiteralPath $pkgTemp) { Remove-Item -LiteralPath $pkgTemp -Recurse -Force }
    New-Item -ItemType Directory -Path $pkgTemp -Force | Out-Null
    Start-Log (Join-Path $pkgTemp 'create.log')

    Write-Log -Level STEP '=== Create TwinCAT update package (bench) ==='
    Write-Log "Running as $([Security.Principal.WindowsIdentity]::GetCurrent().Name) on $env:COMPUTERNAME"
    $tc = Get-TwinCATInfo
    Write-Log "TwinCAT version: $($tc.Version)   AMS Net ID: $($tc.AmsNetId)"
    Write-Log "Package folder:  $pkgFinal"

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
    $free = (New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($pkgTemp))).AvailableFreeSpace
    Write-Log ("Package size: {0:N1} MB, free on destination: {1:N1} MB" -f ($needed / 1MB), ($free / 1MB))
    if ($free -lt ($needed * 1.1 + 10MB)) { throw 'Not enough free space on the destination drive.' }

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
    $manifest = New-FolderSnapshot -Entries $entries -Destination $pkgTemp -Purpose 'UpdatePackage'

    # --- Publish: .partial -> final (keep one previous package) -------------------
    if (Test-Path -LiteralPath $pkgFinal) {
        if (Test-Path -LiteralPath $pkgPrev) { Remove-Item -LiteralPath $pkgPrev -Recurse -Force }
        Rename-Item -LiteralPath $pkgFinal -NewName (Split-Path -Leaf $pkgPrev)
        Write-Log "Previous package kept as $pkgPrev"
    }
    Rename-Item -LiteralPath $pkgTemp -NewName (Split-Path -Leaf $pkgFinal)
    $script:LogFile = Join-Path $pkgFinal 'create.log'

    foreach ($i in $manifest.Items) { Write-Log -Level OK ("  {0,-6} {1,6} files  {2,10:N1} MB" -f $i.Name, $i.FileCount, ($i.TotalBytes / 1MB)) }
    Write-Log -Level OK "Package created: $pkgFinal"
    $exitCode = 0
}
catch {
    Write-Log -Level ERROR $_.Exception.Message
    Write-Log -Level ERROR ($_.ScriptStackTrace -replace '\r?\n', ' <- ')
    Write-Log -Level ERROR 'Package NOT created. Any incomplete copy is left as *.partial and will never be used.'
}
finally {
    if (-not $LeaveStopped) {
        foreach ($svc in $servicesToStart) { [void](Start-ServiceSafe -Name $svc -TimeoutSec $S.ServiceStopTimeoutSec) }
        if ($tcWasRunning) {
            try { Set-TwinCATMode -Mode Run -TimeoutSec $S.AdsStateTimeoutSec }
            catch { Write-Log -Level WARN "Could not return TwinCAT to Run mode: $($_.Exception.Message)"; $exitCode = 1 }
        }
    } elseif ($adsUsed) {
        Write-Log -Level WARN '-LeaveStopped given: TwinCAT left in Config mode, HMI Server left stopped.'
    }
    Close-Ads
}
exit $exitCode
