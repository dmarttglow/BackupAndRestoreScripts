# =============================================================================
#  Shared helpers for New-UpdatePackage.ps1 and Install-UpdatePackage.ps1.
#  Dot-source only. Requires Windows PowerShell 3.0+ (5.1 recommended).
# =============================================================================

$script:LogFile = $null
$script:AdsClient = $null
$script:AdsAssembly = $null
$script:ProgressShown = $false
$script:ProgressLastDraw = [DateTime]::MinValue
$script:SpinnerFrames = '|', '/', '-', '\'

$AdsSystemServicePort = 10000

# -----------------------------------------------------------------------------
#  Logging / console progress
# -----------------------------------------------------------------------------

# Draws a single status line that is overwritten in place on the console, so
# long steps visibly keep moving. Console only - never written to the log.
# Redraws at most 4x per second unless -Force. Silently does nothing without a console.
function Write-ProgressLine {
    param([Parameter(Mandatory = $true)][string]$Text, [switch]$Force, [int]$Percent = -1)
    Update-ProgressDetail -Detail $Text -Percent $Percent
    $now = [DateTime]::UtcNow
    if (-not $Force -and ($now - $script:ProgressLastDraw).TotalMilliseconds -lt 250) { return }
    $script:ProgressLastDraw = $now
    try {
        $spin = $script:SpinnerFrames[[int](([long]($now.Ticks / 2500000)) % 4)]
        $width = [Math]::Max(20, [Console]::WindowWidth - 1)
        $line = "  $spin $Text"
        if ($line.Length -gt $width) { $line = $line.Substring(0, $width) }
        [Console]::Write("`r" + $line.PadRight($width))
        $script:ProgressShown = $true
    } catch { }
}

# -----------------------------------------------------------------------------
#  Progress file for the optional status screen (UpdateScreen\)
#  Nothing here needs the screen: until Start-ProgressFile is called these
#  functions do nothing, and any error writing the file is ignored.
# -----------------------------------------------------------------------------

$script:ProgressFile = $null
$script:ProgressState = $null
$script:ProgressLastWrite = [DateTime]::MinValue

function Start-ProgressFile {
    param([Parameter(Mandatory = $true)][string]$Path, [string]$RunId)
    $script:ProgressFile = $Path
    $script:ProgressState = [ordered]@{
        RunId        = $RunId
        Pid          = $PID       # the status helper returns to the HMI if this process has ended
        ComputerName = $env:COMPUTERNAME
        State        = 'Running'   # Running, Success, Failed, RolledBack, RollbackFailed
        StepKey      = ''
        Step         = 'Preparing update'
        Detail       = ''
        Percent      = 0
        StepStart    = 0
        StepEnd      = 0
        ErrorText    = ''
        RebootAtUtc  = $null
        StartedUtc   = [DateTime]::UtcNow.ToString('o')
        UpdatedUtc   = $null
    }
    Save-ProgressFile -Force
}

# Starts a step that covers Start..End of the overall progress (0-100).
function Set-ProgressStep {
    param([string]$Key, [string]$Text, [int]$Start, [int]$End)
    $s = $script:ProgressState
    if (-not $s) { return }
    $s.StepKey = $Key; $s.Step = $Text; $s.Detail = ''
    $s.StepStart = $Start; $s.StepEnd = $End; $s.Percent = $Start
    Save-ProgressFile -Force
}

# Percent is within the current step (0-100), or -1 if unknown.
function Update-ProgressDetail {
    param([string]$Detail, [int]$Percent = -1)
    $s = $script:ProgressState
    if (-not $s) { return }
    $s.Detail = $Detail
    if ($Percent -ge 0) {
        # A step can hash several folders one after another: never move the bar backwards.
        $p = [int]($s.StepStart + ($s.StepEnd - $s.StepStart) * [Math]::Min(100, $Percent) / 100)
        if ($p -gt $s.Percent) { $s.Percent = $p }
    }
    Save-ProgressFile
}

function Set-ProgressResult {
    param([string]$State, [string]$ErrorText, [int]$RebootInSec = -1)
    $s = $script:ProgressState
    if (-not $s) { return }
    $s.State = $State
    $s.Detail = ''
    if ($ErrorText) { $s.ErrorText = $ErrorText }
    if ($State -eq 'Success') { $s.Percent = 100 }
    if ($RebootInSec -ge 0) { $s.RebootAtUtc = [DateTime]::UtcNow.AddSeconds($RebootInSec).ToString('o') }
    Save-ProgressFile -Force
}

# Writes the state at most once per second (always with -Force), twice:
#   update_progress.json  read by the PowerShell status window
#   update_progress.js    "updateProgress({...});" - loaded as a <script> by the status page in
#                         the TF1200 UI Client (a file:// page in Chromium cannot read JSON files)
function Save-ProgressFile {
    param([switch]$Force)
    if (-not $script:ProgressFile -or -not $script:ProgressState) { return }
    $now = [DateTime]::UtcNow
    if (-not $Force -and ($now - $script:ProgressLastWrite).TotalMilliseconds -lt 1000) { return }
    $script:ProgressLastWrite = $now
    try {
        $script:ProgressState.UpdatedUtc = $now.ToString('o')
        $json = $script:ProgressState | ConvertTo-Json -Compress
        # Step changes and the result (-Force) must arrive; a lost detail update is replaced a second later.
        $tries = if ($Force) { 60 } else { 3 }
        Write-FileAtomic $script:ProgressFile $json -Tries $tries
        Write-FileAtomic ([IO.Path]::ChangeExtension($script:ProgressFile, '.js')) "updateProgress($json);" -Tries $tries
    } catch { if ($Force) { Write-Log -Level WARN "Could not write the status screen file: $($_.Exception.Message)" } }
}

# Writes via a .tmp file so a reader never sees a half-written file. The status helper and
# the page in the UI Client read these files twice a second: while one has the file open,
# replacing it can fail (on older Windows a deleted file keeps its name until the reader closes
# it), so it is retried for ~3 s and, as a last resort, overwritten in place. Losing a write
# here (e.g. the final result) leaves the status screen stuck on the last step.
function Write-FileAtomic {
    param([string]$Path, [string]$Text, [int]$Tries = 60)
    $utf8 = New-Object Text.UTF8Encoding $false
    $tmp = "$Path.tmp"
    for ($try = 1; $try -le $Tries; $try++) {
        try {
            [IO.File]::WriteAllText($tmp, $Text, $utf8)
            if ([IO.File]::Exists($Path)) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) } else { [IO.File]::Move($tmp, $Path) }
            return
        } catch { Start-Sleep -Milliseconds 50 }
    }
    $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Create, [IO.FileAccess]::Write, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try { $b = $utf8.GetBytes($Text); $fs.Write($b, 0, $b.Length) } finally { $fs.Dispose() }
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}

function Clear-ProgressLine {
    if (-not $script:ProgressShown) { return }
    try { [Console]::Write("`r" + (' ' * [Math]::Max(20, [Console]::WindowWidth - 1)) + "`r") } catch { }
    $script:ProgressShown = $false
}

function Format-Elapsed {
    param([Parameter(Mandatory = $true)][Diagnostics.Stopwatch]$Stopwatch)
    $t = $Stopwatch.Elapsed
    if ($t.TotalHours -ge 1) { '{0}:{1:mm}:{1:ss}' -f [int][Math]::Floor($t.TotalHours), $t } else { '{0:mm}:{0:ss}' -f $t }
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'STEP', 'OK', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    Clear-ProgressLine
    $line = '[{0}] [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $color = switch ($Level) {
        'STEP'  { 'Cyan' }
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        default { 'Gray' }
    }
    try { Write-Host $line -ForegroundColor $color } catch { }
    if ($script:LogFile) {
        try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } catch { }
    }
}

function Start-Log {
    param([Parameter(Mandatory = $true)][string]$Path)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $script:LogFile = $Path
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Prerequisites {
    if ($PSVersionTable.PSVersion.Major -lt 3) {
        throw "PowerShell 3.0 or newer is required (found $($PSVersionTable.PSVersion))."
    }
    if (-not (Test-IsAdmin)) {
        throw 'This script must run as Administrator (or as SYSTEM when started from the PLC).'
    }
    if (-not (Get-Command robocopy.exe -ErrorAction SilentlyContinue)) {
        throw 'robocopy.exe was not found on this system.'
    }
}

# -----------------------------------------------------------------------------
#  Configuration
# -----------------------------------------------------------------------------

function Import-UpdateConfig {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Config file not found: $Path" }
    $Settings = $null
    $PackageItems = $null
    . $Path
    if (-not $Settings) { throw "Config file '$Path' does not define `$Settings." }
    if (-not $PackageItems) { throw "Config file '$Path' does not define `$PackageItems." }
    # Settings added in later versions: defaults for Config.ps1 files from before.
    if (-not $Settings.ServiceStartTimeoutSec) { $Settings.ServiceStartTimeoutSec = 180 }
    if ($null -eq $Settings.RebootIfStartFails) { $Settings.RebootIfStartFails = $true }

    $items = foreach ($i in $PackageItems) {
        if (-not $i.Name) { throw 'A package item in the config has no Name.' }
        if ($i.Name -notmatch '^[A-Za-z0-9_-]+$') { throw "Package item name '$($i.Name)' may only contain letters, digits, '_' and '-'." }
        $excludeFiles = @($i.ExcludeFiles | Where-Object { $_ })
        if ($i.Name -eq 'Boot' -and $Settings.PreservePersistentData) {
            $excludeFiles += '*.bootdata', '*.bootdata-old'
        }
        [pscustomobject]@{
            Name         = [string]$i.Name
            Description  = [string]$i.Description
            Required     = [bool]$i.Required
            Candidates   = @($i.Candidates | Where-Object { $_ })
            ExcludeFiles = $excludeFiles
            ExcludeDirs  = @($i.ExcludeDirs | Where-Object { $_ })
        }
    }
    [pscustomobject]@{ Settings = $Settings; Items = @($items) }
}

function Get-NormalizedPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.Length -gt 3) { $full = $full.TrimEnd('\') }
    $full
}

# First existing candidate folder, or $null. Warns if several exist.
function Resolve-ItemFolder {
    param([Parameter(Mandatory = $true)]$Item)
    $existing = @($Item.Candidates |
        Where-Object { Test-Path -LiteralPath $_ -PathType Container } |
        ForEach-Object { Get-NormalizedPath $_ } |
        Select-Object -Unique)
    if ($existing.Count -gt 1) {
        Write-Log -Level WARN "[$($Item.Name)] several candidate folders exist: $($existing -join ' | '). Using the first: $($existing[0])"
    }
    if ($existing.Count -ge 1) { return $existing[0] }
    $null
}

# -----------------------------------------------------------------------------
#  Files: inventory, hashing, copying, verification
# -----------------------------------------------------------------------------

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try { [BitConverter]::ToString($sha.ComputeHash($fs)).Replace('-', '') }
        finally { $fs.Dispose() }
    }
    finally { $sha.Dispose() }
}

function Test-PathExcluded {
    param([string]$RelativePath, [string[]]$ExcludeFiles, [string[]]$ExcludeDirs)
    $parts = $RelativePath -split '\\'
    foreach ($p in $ExcludeFiles) { if ($parts[-1] -like $p) { return $true } }
    if ($parts.Count -gt 1 -and $ExcludeDirs) {
        foreach ($d in $parts[0..($parts.Count - 2)]) {
            foreach ($p in $ExcludeDirs) { if ($d -like $p) { return $true } }
        }
    }
    $false
}

# Lists files under Root (relative path, size, optional SHA-256), honoring exclusions.
function Get-FolderInventory {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string[]]$ExcludeFiles = @(),
        [string[]]$ExcludeDirs = @(),
        [switch]$NoHash,
        [string]$Activity = 'Hashing'
    )
    $rootFull = Get-NormalizedPath $Root
    if (-not (Test-Path -LiteralPath $rootFull -PathType Container)) { return @() }
    Write-ProgressLine -Force "Scanning $rootFull ..."
    $files = @(Get-ChildItem -LiteralPath $rootFull -Recurse -Force -File -ErrorAction Stop | Where-Object {
        -not (Test-PathExcluded -RelativePath $_.FullName.Substring($rootFull.Length).TrimStart('\') -ExcludeFiles $ExcludeFiles -ExcludeDirs $ExcludeDirs)
    })
    $totalBytes = [long]0
    foreach ($f in $files) { $totalBytes += $f.Length }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $doneBytes = [long]0
    $i = 0
    $result = foreach ($f in $files) {
        $i++
        if (-not $NoHash) {
            $pct = if ($totalBytes) { [int](100 * $doneBytes / $totalBytes) } else { 100 }
            Write-ProgressLine ("{0}: {1}/{2} files, {3:N1}/{4:N1} MB ({5}%)  {6}" -f $Activity, $i, $files.Count, ($doneBytes / 1MB), ($totalBytes / 1MB), $pct, (Format-Elapsed $sw)) -Percent $pct
        }
        [pscustomobject][ordered]@{
            Path   = $f.FullName.Substring($rootFull.Length).TrimStart('\')
            Size   = $f.Length
            Sha256 = $(if ($NoHash) { $null } else { Get-FileSha256 $f.FullName })
        }
        $doneBytes += $f.Length
    }
    Clear-ProgressLine
    @($result | Sort-Object Path)
}

# Quotes arguments for Start-Process (a trailing backslash would escape the closing quote).
function Join-ProcessArguments {
    param([string[]]$Arguments)
    ($Arguments | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '(\\+)$', '$1$1' -replace '"', '\"') + '"' } else { $_ }
    }) -join ' '
}

function Invoke-Robocopy {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [switch]$Mirror,
        [string[]]$ExcludeFiles = @(),
        [string[]]$ExcludeDirs = @(),
        [Parameter(Mandatory = $true)][string]$LogPath,
        [string]$Label = 'Copying'
    )
    # /IS /IT: always copy, even files that look identical (size + timestamp).
    # /XJ: never follow junctions. Excluded files are neither copied nor purged.
    $rcArgs = @((Get-NormalizedPath $Source), (Get-NormalizedPath $Destination))
    $rcArgs += $(if ($Mirror) { '/MIR' } else { '/E' })
    $rcArgs += '/COPY:DAT', '/DCOPY:T', '/IS', '/IT', '/XJ', '/R:3', '/W:2', '/NP', "/UNILOG+:$LogPath"
    if ($ExcludeFiles.Count) { $rcArgs += '/XF'; $rcArgs += $ExcludeFiles }
    if ($ExcludeDirs.Count) { $rcArgs += '/XD'; $rcArgs += $ExcludeDirs }

    # Run as a child process so the console can show that the copy is still going.
    # Its own console output (just a "Log File :" line with /UNILOG) is discarded.
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $rcOut = [IO.Path]::GetTempFileName()
    try {
        $p = Start-Process -FilePath robocopy.exe -ArgumentList (Join-ProcessArguments $rcArgs) -NoNewWindow -PassThru -RedirectStandardOutput $rcOut
        $null = $p.Handle   # without this, ExitCode is empty after the process ends
        while (-not $p.WaitForExit(250)) {
            Write-ProgressLine "$Label ...  $(Format-Elapsed $sw) elapsed"
        }
        $p.WaitForExit()
    } finally {
        Clear-ProgressLine
        Remove-Item -LiteralPath $rcOut -Force -ErrorAction SilentlyContinue
    }
    $code = $p.ExitCode
    if ($code -ge 8) { throw "robocopy failed (exit code $code) copying '$Source' -> '$Destination'. See $LogPath" }
    Write-Log "robocopy finished in $(Format-Elapsed $sw) (exit code $code)"
}

# Copies each entry's SourcePath into <Destination>\<Name>, then hashes the copy
# and writes manifest.json. Returns the manifest.
function New-FolderSnapshot {
    param(
        [Parameter(Mandatory = $true)][object[]]$Entries,   # Name, Description, SourcePath, ExcludeFiles, ExcludeDirs
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Purpose
    )
    if (-not (Test-Path -LiteralPath $Destination)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }
    $rcLog = Join-Path $Destination 'robocopy.log'

    $manifestItems = foreach ($e in $Entries) {
        $target = Join-Path $Destination $e.Name
        Write-Log -Level STEP "[$($e.Name)] copying '$($e.SourcePath)' -> '$target'"
        Invoke-Robocopy -Source $e.SourcePath -Destination $target -ExcludeFiles $e.ExcludeFiles -ExcludeDirs $e.ExcludeDirs -LogPath $rcLog -Label "Copying [$($e.Name)]"
        if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }

        $srcCount = @(Get-FolderInventory -Root $e.SourcePath -ExcludeFiles $e.ExcludeFiles -ExcludeDirs $e.ExcludeDirs -NoHash).Count
        $files = @(Get-FolderInventory -Root $target -ExcludeFiles $e.ExcludeFiles -ExcludeDirs $e.ExcludeDirs -Activity "Hashing [$($e.Name)]")
        if ($files.Count -ne $srcCount) {
            throw "[$($e.Name)] file count mismatch after copy: source has $srcCount, copy has $($files.Count)."
        }
        $bytes = [long]0
        foreach ($f in $files) { $bytes += $f.Size }
        Write-Log -Level OK ("[{0}] {1} files, {2:N1} MB copied and hashed" -f $e.Name, $files.Count, ($bytes / 1MB))

        [ordered]@{
            Name         = $e.Name
            Description  = $e.Description
            SourcePath   = $e.SourcePath
            ExcludeFiles = @($e.ExcludeFiles)
            ExcludeDirs  = @($e.ExcludeDirs)
            FileCount    = $files.Count
            TotalBytes   = $bytes
            Files        = $files
        }
    }

    $tc = Get-TwinCATInfo
    $manifest = [ordered]@{
        FormatVersion  = 1
        Purpose        = $Purpose
        CreatedLocal   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        ComputerName   = $env:COMPUTERNAME
        TwinCATVersion = $tc.Version
        AmsNetId       = $tc.AmsNetId
        Items          = @($manifestItems)
    }
    # manifest.json is written LAST: its presence marks the snapshot as complete.
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $Destination 'manifest.json') -Encoding UTF8
    $manifest
}

# -----------------------------------------------------------------------------
#  Zip archive (the package travels on the USB stick as a single .zip file)
# -----------------------------------------------------------------------------

function Initialize-Zip {
    try {
        Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    } catch {
        throw 'Zip support (System.IO.Compression, .NET Framework 4.5 or newer) is not available on this system.'
    }
}

# Packs everything under Folder into ZipPath (overwritten). Empty folders are kept.
function Compress-Folder {
    param([Parameter(Mandatory = $true)][string]$Folder, [Parameter(Mandatory = $true)][string]$ZipPath)
    Initialize-Zip
    $root = Get-NormalizedPath $Folder
    if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
    $files = @(Get-ChildItem -LiteralPath $root -Recurse -Force -File)
    $dirs = @(Get-ChildItem -LiteralPath $root -Recurse -Force -Directory)
    $totalBytes = [long]0
    foreach ($f in $files) { $totalBytes += $f.Length }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $doneBytes = [long]0
    $i = 0
    $zip = [IO.Compression.ZipFile]::Open($ZipPath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($d in $dirs) {
            [void]$zip.CreateEntry($d.FullName.Substring($root.Length).TrimStart('\').Replace('\', '/') + '/')
        }
        foreach ($f in $files) {
            $i++
            $pct = if ($totalBytes) { [int](100 * $doneBytes / $totalBytes) } else { 100 }
            Write-ProgressLine ("Zipping: {0}/{1} files, {2:N1}/{3:N1} MB ({4}%)  {5}" -f $i, $files.Count, ($doneBytes / 1MB), ($totalBytes / 1MB), $pct, (Format-Elapsed $sw)) -Percent $pct
            $name = $f.FullName.Substring($root.Length).TrimStart('\').Replace('\', '/')
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.FullName, $name, [IO.Compression.CompressionLevel]::Optimal)
            $doneBytes += $f.Length
        }
    } finally {
        $zip.Dispose()
        Clear-ProgressLine
    }
    Write-Log ("Zipped {0} files in {1}: {2:N1} MB -> {3:N1} MB" -f $files.Count, (Format-Elapsed $sw), ($totalBytes / 1MB), ((Get-Item -LiteralPath $ZipPath).Length / 1MB))
}

# Total uncompressed size of all entries in a zip file.
function Get-ZipContentSize {
    param([Parameter(Mandatory = $true)][string]$ZipPath)
    Initialize-Zip
    $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $bytes = [long]0
        foreach ($e in $zip.Entries) { $bytes += $e.Length }
        $bytes
    } finally { $zip.Dispose() }
}

# Extracts ZipPath into Destination (which must not exist yet). Refuses entries
# that would land outside Destination.
function Expand-ZipFile {
    param([Parameter(Mandatory = $true)][string]$ZipPath, [Parameter(Mandatory = $true)][string]$Destination)
    Initialize-Zip
    $root = Get-NormalizedPath $Destination
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entries = @($zip.Entries)
        $totalBytes = [long]0
        foreach ($e in $entries) { $totalBytes += $e.Length }
        $doneBytes = [long]0
        $i = 0
        foreach ($e in $entries) {
            $i++
            $pct = if ($totalBytes) { [int](100 * $doneBytes / $totalBytes) } else { 100 }
            Write-ProgressLine ("Unzipping: {0}/{1} entries, {2:N1}/{3:N1} MB ({4}%)  {5}" -f $i, $entries.Count, ($doneBytes / 1MB), ($totalBytes / 1MB), $pct, (Format-Elapsed $sw)) -Percent $pct
            $rel = $e.FullName.Replace('/', '\')
            $target = [IO.Path]::GetFullPath((Join-Path $root $rel))
            if (-not $target.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw "Zip entry '$($e.FullName)' points outside the extraction folder."
            }
            if ($rel.EndsWith('\')) {
                New-Item -ItemType Directory -Path $target -Force | Out-Null
                continue
            }
            $dir = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
            $doneBytes += $e.Length
        }
    } finally {
        $zip.Dispose()
        Clear-ProgressLine
    }
    Write-Log ("Unzipped {0} entries ({1:N1} MB) in {2}" -f $entries.Count, ($totalBytes / 1MB), (Format-Elapsed $sw))
}

function Read-Manifest {
    param([Parameter(Mandatory = $true)][string]$Folder)
    $path = Join-Path $Folder 'manifest.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "No manifest.json in '$Folder' (incomplete or not a package)." }
    $m = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $m.Items) { throw "manifest.json in '$Folder' lists no items." }
    $m
}

# Compares the files under Root with a manifest item. Returns a list of problems.
function Compare-FolderToManifest {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)]$ManifestItem,
        [string]$Activity = 'Verifying'
    )
    $problems = New-Object System.Collections.Generic.List[string]
    $files = @($ManifestItem.Files | Where-Object { $_ })
    $totalBytes = [long]0
    foreach ($f in $files) { $totalBytes += [long]$f.Size }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $doneBytes = [long]0
    $i = 0
    foreach ($f in $files) {
        $i++
        $pct = if ($totalBytes) { [int](100 * $doneBytes / $totalBytes) } else { 100 }
        Write-ProgressLine ("{0}: {1}/{2} files, {3:N1}/{4:N1} MB ({5}%)  {6}" -f $Activity, $i, $files.Count, ($doneBytes / 1MB), ($totalBytes / 1MB), $pct, (Format-Elapsed $sw)) -Percent $pct
        $doneBytes += [long]$f.Size
        $p = Join-Path $Root $f.Path
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { $problems.Add("missing: $($f.Path)"); continue }
        if ((Get-FileSha256 $p) -ne $f.Sha256) { $problems.Add("content differs: $($f.Path)") }
    }
    Clear-ProgressLine
    $problems.ToArray()   # callers wrap in @() to get a count
}

# -----------------------------------------------------------------------------
#  TwinCAT info + ADS state control
# -----------------------------------------------------------------------------

function Get-TwinCATInfo {
    $info = [ordered]@{ Version = $null; AmsNetId = $null }
    foreach ($key in 'HKLM:\SOFTWARE\WOW6432Node\Beckhoff\TwinCAT3\System', 'HKLM:\SOFTWARE\Beckhoff\TwinCAT3\System') {
        try {
            $p = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
            if (-not $info.Version -and $p.PSObject.Properties['TcVersion']) { $info.Version = [string]$p.TcVersion }   # e.g. 3.1.4026.27
            if (-not $info.AmsNetId -and $p.PSObject.Properties['AmsNetId'] -and $p.AmsNetId -is [byte[]] -and $p.AmsNetId.Length -eq 6) {
                $info.AmsNetId = $p.AmsNetId -join '.'
            }
        } catch { }
    }
    if (-not $info.Version) {
        # Fallback: ProductVersion of the system service exe (its FileVersion is NOT the TwinCAT build).
        try {
            $svc = Get-WmiObject -Class Win32_Service -Filter "Name='TcSysSrv'" -ErrorAction Stop
            if ($svc -and $svc.PathName) {
                $exe = if ($svc.PathName -match '^"([^"]+)"') { $Matches[1] } else { ($svc.PathName -split '\s+')[0] }
                if (Test-Path -LiteralPath $exe) { $info.Version = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion }
            }
        } catch { }
    }
    [pscustomobject]$info
}

# "3, 1, 4026, 27" / "3.1.4026.27 (abc)" -> "3.1.4026.27"
function Format-Version {
    param([string]$Version)
    if (-not $Version) { return $null }
    $v = (($Version -replace '\s', '' -replace ',', '.') -replace '[^0-9.].*$', '').Trim('.')
    if ($v) { $v } else { $null }
}

# ProductVersion of the exe a Windows service runs, or $null.
function Get-ServiceExeVersion {
    param([Parameter(Mandatory = $true)][string]$Name)
    try {
        $svc = Get-WmiObject -Class Win32_Service -Filter "Name='$Name'" -ErrorAction Stop
        if (-not $svc -or -not $svc.PathName) { return $null }
        $exe = if ($svc.PathName -match '^"([^"]+)"') { $Matches[1] } else { ($svc.PathName -split '\s+')[0] }
        if (-not (Test-Path -LiteralPath $exe)) { return $null }
        $vi = (Get-Item -LiteralPath $exe).VersionInfo
        $v = Format-Version $vi.ProductVersion
        if (-not $v) { $v = Format-Version $vi.FileVersion }
        $v
    } catch { $null }
}

# Installed TwinCAT runtime (XAR) and TF2000 HMI Server versions.
#  XAR:    registry TcVersion (fallback: TcSysSrv exe ProductVersion)
#  TF2000: ProductVersion of the exe the HMI Server service actually runs
function Get-InstalledVersions {
    param([Parameter(Mandatory = $true)][string]$HmiServiceName)
    [ordered]@{
        TwinCAT_XAR       = Format-Version (Get-TwinCATInfo).Version
        TF2000_HMI_Server = Get-ServiceExeVersion $HmiServiceName
    }
}

function Write-VersionFile {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Versions)
    [ordered]@{
        ComputerName = $env:COMPUTERNAME
        CreatedLocal = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Versions     = $Versions
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Path -Encoding UTF8
}

# Returns the Versions table from a versions.json as a hashtable.
function Read-VersionFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Version file not found: $Path" }
    $data = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $data.Versions) { throw "Version file '$Path' has no Versions section." }
    $table = [ordered]@{}
    foreach ($p in $data.Versions.PSObject.Properties) { $table[$p.Name] = [string]$p.Value }
    $table
}

# Compares expected (package) versions with actual (this machine). Returns mismatches.
function Compare-Versions {
    param([Parameter(Mandatory = $true)]$Expected, [Parameter(Mandatory = $true)]$Actual)
    $problems = New-Object System.Collections.Generic.List[string]
    foreach ($name in @($Expected.Keys)) {
        $want = Format-Version $Expected[$name]
        $have = Format-Version $Actual[$name]
        if (-not $want) { $problems.Add("${name}: not recorded in the package") }
        elseif (-not $have) { $problems.Add("${name}: package has $want but the installed version could not be read on this machine") }
        elseif ($want -ne $have) { $problems.Add("${name}: package $want, this machine $have") }
    }
    $problems.ToArray()
}

# Connects to the local TwinCAT system service through the .NET ADS API
# (TwinCAT.Ads.dll). Tries the copy bundled next to Config.ps1 first (v4.x,
# self-contained), then the GAC, and only if neither works searches the TwinCAT
# install folders: v4.x copies (TcAdsClient) first, then newer ones
# (v6+/AdsClient, which may fail if their dependency DLLs are not alongside).
function Initialize-Ads {
    if ($script:AdsClient) { return }

    $bundled = Join-Path (Split-Path -Parent $PSScriptRoot) 'TwinCAT.Ads.dll'
    $quick = @(@($bundled) | Where-Object { Test-Path -LiteralPath $_ }) + @('GAC')
    if (Connect-AdsFrom $quick) { return }

    $roots = @($env:TWINCAT3DIR, 'C:\TwinCAT', "${env:ProgramFiles(x86)}\Beckhoff\TwinCAT", "$env:ProgramFiles\Beckhoff") |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $files = @(foreach ($r in $roots) {
        Get-ChildItem -LiteralPath $r -Recurse -Filter 'TwinCAT.Ads.dll' -ErrorAction SilentlyContinue |
            ForEach-Object { Write-ProgressLine "Looking for TwinCAT.Ads.dll in $r ...  $(Format-Elapsed $sw)"; $_ }
        Write-ProgressLine -Force "Looking for TwinCAT.Ads.dll in $r ...  $(Format-Elapsed $sw)"
    })
    Clear-ProgressLine
    $seen = @{}
    $dlls = @($files |
        ForEach-Object {
            $v = $null; try { $v = [version]($_.VersionInfo.FileVersion -replace '[^0-9.].*$', '') } catch { }
            if ($v) { [pscustomobject]@{ Path = $_.FullName; Version = $v } }
        } |
        Sort-Object @{ Expression = { $_.Version.Major -ne 4 } }, @{ Expression = { $_.Version }; Descending = $true } |
        Where-Object { if ($seen.ContainsKey("$($_.Version)")) { $false } else { $seen["$($_.Version)"] = 1; $true } } |
        ForEach-Object { $_.Path } |
        Where-Object { $_ -ne $bundled })

    if (Connect-AdsFrom $dlls) { return }
    throw ("No usable TwinCAT.Ads.dll found (tried $bundled, the GAC and $($roots -join ', ')), " +
           'or the local ADS router did not answer. Check TwinCAT is installed and its system service is running.')
}

# Tries each source ('GAC' or a DLL path) in order; on the first one that loads
# and gets an answer from the local ADS router, stores the client and returns $true.
function Connect-AdsFrom([string[]]$Sources) {
    foreach ($source in $Sources) {
        $client = $null
        try {
            $asm = if ($source -eq 'GAC') { [Reflection.Assembly]::LoadWithPartialName('TwinCAT.Ads') } else { [Reflection.Assembly]::LoadFrom($source) }
            if (-not $asm) { continue }
            $type = $asm.GetType('TwinCAT.Ads.TcAdsClient')
            if (-not $type) { $type = $asm.GetType('TwinCAT.Ads.AdsClient') }
            if (-not $type) { continue }
            $client = [Activator]::CreateInstance($type)
            $client.Connect([int]$AdsSystemServicePort)
            [void]$client.ReadState()   # proves the local ADS router answers
            $script:AdsClient = $client
            $script:AdsAssembly = $asm
            Write-Log "ADS: using TwinCAT.Ads $($asm.GetName().Version) ($source)"
            return $true
        } catch {
            Write-Log "ADS: TwinCAT.Ads from $source not usable: $($_.Exception.Message)"
            if ($client) { try { $client.Dispose() } catch { } }
        }
    }
    $false
}

function Get-TwinCATState {
    Initialize-Ads
    [string]$script:AdsClient.ReadState().AdsState
}

# Puts TwinCAT into Config or Run mode and waits until it gets there.
function Set-TwinCATMode {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Config', 'Run')][string]$Mode,
        [int]$TimeoutSec = 30
    )
    Initialize-Ads
    $current = Get-TwinCATState
    if ($current -eq $Mode) { Write-Log "TwinCAT already in $Mode mode"; return }
    Write-Log -Level STEP "Switching TwinCAT from $current to $Mode mode (ADS)..."

    # System service state requests: Config <- Reconfig, Run <- Reset.
    # The second entry is only a fallback in case the first is rejected.
    $requests = if ($Mode -eq 'Config') { 'Reconfig', 'Config' } else { 'Reset', 'Run' }
    $stateType = $script:AdsAssembly.GetType('TwinCAT.Ads.AdsState')
    $infoType = $script:AdsAssembly.GetType('TwinCAT.Ads.StateInfo')
    $lastError = $null
    foreach ($req in $requests) {
        try {
            $si = [Activator]::CreateInstance($infoType, @([Enum]::Parse($stateType, $req), [int16]0))
            $script:AdsClient.WriteControl($si)
        } catch {
            $lastError = $_.Exception.Message
            Write-Log "ADS request '$req' not accepted: $lastError"
        }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        do {
            Start-Sleep -Milliseconds 250
            try { $current = Get-TwinCATState } catch { $current = 'unreachable' }   # ADS drops briefly while switching
            if ($current -eq $Mode) { Write-Log -Level OK "TwinCAT is in $Mode mode (took $(Format-Elapsed $sw))"; return }
            Write-ProgressLine ("Waiting for TwinCAT {0} mode ...  state: {1}  {2:N0}/{3} s" -f $Mode, $current, $sw.Elapsed.TotalSeconds, $TimeoutSec)
        } while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec)
    }
    Clear-ProgressLine
    throw "TwinCAT did not reach $Mode mode within the timeout (state: $current). $lastError"
}

function Close-Ads {
    if ($script:AdsClient) { try { $script:AdsClient.Dispose() } catch { } }
    $script:AdsClient = $null
    $script:AdsAssembly = $null
}

# -----------------------------------------------------------------------------
#  Windows services
# -----------------------------------------------------------------------------

# Waits for a service to reach a status, showing progress. Returns $true if it got there.
function Wait-ServiceStatus {
    param([Parameter(Mandatory = $true)][ServiceProcess.ServiceController]$Service, [string]$Status, [int]$TimeoutSec)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $Service.Refresh()
        if ("$($Service.Status)" -eq $Status) { Clear-ProgressLine; return $true }
        if ($sw.Elapsed.TotalSeconds -ge $TimeoutSec) { Clear-ProgressLine; return $false }
        Write-ProgressLine ("Waiting for service '{0}' to be {1} ...  now: {2}  {3:N0}/{4} s" -f $Service.Name, $Status, $Service.Status, $sw.Elapsed.TotalSeconds, $TimeoutSec)
        Start-Sleep -Milliseconds 250
    }
}

# Stops a service (and its running dependents). Returns names to start again later.
function Stop-ServiceWithTimeout {
    param([Parameter(Mandatory = $true)][string]$Name, [int]$TimeoutSec = 60)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { Write-Log -Level WARN "Service '$Name' is not installed - skipping"; return @() }
    if ($svc.Status -eq 'Stopped') { Write-Log "Service '$Name' already stopped"; return @() }

    $restart = @($Name) + @($svc.DependentServices | Where-Object { $_.Status -ne 'Stopped' } | ForEach-Object { $_.Name })
    Write-Log -Level STEP "Stopping service '$Name' ($($svc.DisplayName))..."
    $svc.Stop()
    if (-not (Wait-ServiceStatus -Service $svc -Status 'Stopped' -TimeoutSec $TimeoutSec)) {
        # Last resort: kill the service process.
        $wmi = Get-WmiObject -Class Win32_Service -Filter "Name='$Name'"
        if (-not $wmi -or -not $wmi.ProcessId) { throw "Service '$Name' did not stop within $TimeoutSec s." }
        Write-Log -Level WARN "Service '$Name' did not stop within $TimeoutSec s - killing PID $($wmi.ProcessId)"
        Stop-Process -Id $wmi.ProcessId -Force -ErrorAction SilentlyContinue
        if (-not (Wait-ServiceStatus -Service $svc -Status 'Stopped' -TimeoutSec 15)) { throw "Service '$Name' could not be stopped." }
    }
    Write-Log -Level OK "Service '$Name' stopped"
    $restart
}

# Starts a service and waits until it is Running. A service that is already starting
# (Start Pending, e.g. started by Windows or by an earlier attempt) is waited for, not
# started again: ServiceController.Start() throws for a service in that state.
function Start-ServiceSafe {
    param([Parameter(Mandatory = $true)][string]$Name, [int]$TimeoutSec = 180)
    try {
        $svc = Get-Service -Name $Name -ErrorAction Stop
        $svc.Refresh()
        if ("$($svc.Status)" -eq 'StopPending') {
            Write-Log "Service '$Name' is still stopping - waiting before starting it"
            [void](Wait-ServiceStatus -Service $svc -Status 'Stopped' -TimeoutSec $TimeoutSec)
        }
        switch ("$($svc.Status)") {
            'Running'      { }
            'StartPending' { Write-Log -Level STEP "Service '$Name' is already starting (Start Pending) - waiting up to $TimeoutSec s..." }
            default {
                Write-Log -Level STEP "Starting service '$Name'..."
                try { $svc.Start() }
                catch {
                    # It may have started in the meantime; only a real failure is an error.
                    $svc.Refresh()
                    if ("$($svc.Status)" -notin 'StartPending', 'Running') { throw }
                }
            }
        }
        if (-not (Wait-ServiceStatus -Service $svc -Status 'Running' -TimeoutSec $TimeoutSec)) {
            throw "still '$($svc.Status)' after $TimeoutSec s"
        }
        Write-Log -Level OK "Service '$Name' running"
        $true
    } catch {
        $msg = $_.Exception.Message
        if ($_.Exception.InnerException) { $msg += " ($($_.Exception.InnerException.Message))" }
        Write-Log -Level WARN "Could not start service '$Name': $msg"
        $false
    }
}
