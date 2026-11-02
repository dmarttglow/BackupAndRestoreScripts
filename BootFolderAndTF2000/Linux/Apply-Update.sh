#!/usr/bin/env bash
# ============================================================================
#  MACHINE IPC - apply the TwinCAT update package from the USB stick.
#  Unattended: intended to be started by the PLC (NT_StartProcess) from an
#  HMI button. Validates the package, stops TwinCAT (ADS -> Config) + HMI
#  Server, backs up the old version, replaces Boot + HMI folders, verifies,
#  rolls back on failure, then reboots.
#
#  Result: /var/lib/TwinCAT_UpdateBackups/last_update_status.txt
#  Exit codes: 0 ok, 1 failed (nothing changed), 2 failed (rolled back),
#              3 failed + rollback failed, 4 already running
# ============================================================================

SELF=$(readlink -f -- "${BASH_SOURCE[0]}")

# When started by the PLC this runs as root already.
# When started by a user, elevate first.
if (( EUID != 0 )); then
    exec sudo -- bash "$SELF" "$@"
fi

exec bash "$(dirname -- "$SELF")/scripts/Install-UpdatePackage.sh" "$@"
