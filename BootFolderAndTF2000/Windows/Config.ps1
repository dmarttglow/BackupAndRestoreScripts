# =============================================================================
#  TwinCAT update package - configuration
#  Shared by Create-UpdatePackage.bat (bench) and Apply-Update.bat (machine).
#  This file is dot-sourced PowerShell: keep the variable names, edit the values.
# =============================================================================

$Settings = @{
    # Name of the package on the USB stick: <name>.zip at the root of the stick.
    PackageFolderName        = 'TwinCAT_Update'

    # Local folder on the machine IPC where the OLD Boot/HMI folders are saved
    # before being replaced, plus the update logs. Must be on a local disk.
    LocalBackupRoot          = 'C:\TwinCAT_UpdateBackups'

    # How many old-version backups to keep on the machine (oldest are deleted).
    BackupsToKeep            = 5

    # Keep the machine's own PLC persistent data (*.bootdata) instead of
    # overwriting it with the bench's values. See README before changing.
    PreservePersistentData   = $true

    # $false (default): at the end of Apply-Update, switch TwinCAT back to Run mode and
    # start the HMI Server again - no controller restart.
    # $true: restart the whole controller instead (also after a rollback).
    RebootAfterApply         = $false
    # If TwinCAT does not reach Run mode or the HMI Server does not start again (after
    # retries), restart the controller so both start from scratch.
    RebootIfStartFails       = $true
    RebootDelaySeconds       = 10

    # Timeouts (seconds)
    AdsStateTimeoutSec       = 30
    ServiceStopTimeoutSec    = 60
    # How long a starting service may stay "Start Pending" (the HMI Server can take a
    # while to load its project after an update).
    ServiceStartTimeoutSec   = 180

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
