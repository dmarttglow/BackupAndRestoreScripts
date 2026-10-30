# =============================================================================
#  TwinCAT update package - configuration
#  Shared by Create-UpdatePackage.bat (bench) and Apply-Update.bat (machine).
#  This file is dot-sourced PowerShell: keep the variable names, edit the values.
# =============================================================================

$Settings = @{
    # Name of the package folder at the root of the USB stick.
    PackageFolderName        = 'TwinCAT_Update'

    # Local folder on the machine IPC where the OLD Boot/HMI folders are saved
    # before being replaced, plus the update logs. Must be on a local disk.
    LocalBackupRoot          = 'C:\TwinCAT_UpdateBackups'

    # How many old-version backups to keep on the machine (oldest are deleted).
    BackupsToKeep            = 5

    # Refuse to apply a package built on a different TwinCAT build
    # (e.g. 4024.x bench -> 4026.x machine). Strongly recommended.
    RequireSameTwinCATBuild  = $true

    # Keep the machine's own PLC persistent data (*.bootdata) instead of
    # overwriting it with the bench's values. See README before changing.
    PreservePersistentData   = $true

    # Reboot the machine at the end of Apply-Update (also after a rollback).
    RebootAfterApply         = $true
    RebootDelaySeconds       = 10

    # Timeouts (seconds)
    AdsStateTimeoutSec       = 30
    ServiceStopTimeoutSec    = 60

    # Windows service name of the TwinCAT HMI Server (TF2000).
    HmiServiceName           = 'TcHmiSrv'
}

# Folders that make up the package. For each item, Candidates are checked in
# order and the FIRST existing folder is used (logged, so you can confirm).
$PackageItems = @(
    @{
        Name         = 'Boot'
        Description  = 'TwinCAT 3 Boot folder'
        Required     = $true
        Candidates   = @(
            "$env:ProgramData\Beckhoff\TwinCAT\3.1\Boot"   # TwinCAT 3.1.4026 and newer
            'C:\TwinCAT\3.1\Boot'                           # TwinCAT 3.1.4024 and older
        )
        ExcludeFiles = @()   # wildcards on file names, e.g. '*.log'
        ExcludeDirs  = @()   # wildcards on folder names
    }
    @{
        Name         = 'HMI'
        Description  = 'TwinCAT HMI Server (TF2000) data folder'
        Required     = $true
        Candidates   = @(
            "$env:ProgramData\Beckhoff\TF2000 TwinCAT 3 HMI Server"   # TF2000 1.10 and newer
            'C:\TwinCAT\Functions\TF2000-HMI-Server\service'          # older TF2000 versions
        )
        ExcludeFiles = @()
        ExcludeDirs  = @()
    }
)
