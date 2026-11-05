# =============================================================================
#  TwinCAT update package - configuration (Linux)
#  Shared by Create-UpdatePackage.sh (bench) and Apply-Update.sh (machine).
#  This file is sourced bash: keep the variable names, edit the values.
# =============================================================================

# Name of the package on the USB stick: <name>.tar.gz at the root of the stick.
PACKAGE_FOLDER_NAME='TwinCAT_Update'

# Local folder on the machine IPC where the OLD Boot/HMI folders are saved
# before being replaced, plus the update logs. Must be on a local disk.
LOCAL_BACKUP_ROOT='/var/lib/TwinCAT_UpdateBackups'

# How many old-version backups to keep on the machine (oldest are deleted).
BACKUPS_TO_KEEP=5

# Keep the machine's own PLC persistent data (*.bootdata) instead of
# overwriting it with the bench's values. See README before changing.
PRESERVE_PERSISTENT_DATA=1

# Reboot the machine at the end of Apply-Update (also after a rollback).
REBOOT_AFTER_APPLY=1
REBOOT_DELAY_SECONDS=10

# Timeouts (seconds)
ADS_STATE_TIMEOUT_SEC=30
SERVICE_STOP_TIMEOUT_SEC=60

# systemd service name of the TwinCAT HMI Server (TF2000).
HMI_SERVICE_NAME='TcHmiSrv'

# Command used to read / write the TwinCAT system state over ADS. The scripts
# append "state" (read) or "state <number>" (write). Port 10000 is the
# TwinCAT system service. Test it first:  adstool 127.0.0.1 --port=10000 state
ADS_TOOL=(adstool 127.0.0.1 --port=10000)

# Packages whose installed version is recorded on the bench and must match
# exactly on the machine. The first one that is installed is used.
# List the real names with:  dpkg -l | grep -i -e tc31 -e tf2000
XAR_PACKAGES=(tc31-xar-um)
HMI_PACKAGES=(tf2000-hmi-server)

# Mount USB partitions that are plugged in but not mounted (headless IPCs
# usually do not auto-mount). They are unmounted again at the end.
AUTO_MOUNT_USB=1

# Folders that make up the package. For each item, <Name>_CANDIDATES are
# checked in order and the FIRST existing folder is used (logged, so you can
# confirm). Item names may only contain letters, digits and '_'.
PACKAGE_ITEMS=(Boot HMI)

Boot_DESCRIPTION='TwinCAT 3 Boot folder'
Boot_REQUIRED=1
Boot_CANDIDATES=(
    '/etc/TwinCAT/3.1/Boot'              # Beckhoff RT Linux
    '/usr/local/etc/TwinCAT/3.1/Boot'    # TwinCAT/BSD layout
)
Boot_EXCLUDE_FILES=()   # wildcards on file names, e.g. '*.log'
Boot_EXCLUDE_DIRS=()    # wildcards on folder names

HMI_DESCRIPTION='TwinCAT HMI Server (TF2000) data folder'
HMI_REQUIRED=1
HMI_CANDIDATES=(
    '/var/lib/TcHmiSrv'
    '/etc/TwinCAT/Functions/TF2000-HMI-Server'
)
HMI_EXCLUDE_FILES=()
HMI_EXCLUDE_DIRS=()
