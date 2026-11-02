#!/usr/bin/env bash
# ============================================================================
#  BENCH SYSTEM - create TwinCAT update package on the USB stick.
#  Stops TwinCAT (ADS -> Config) + HMI Server, copies Boot + HMI folders to
#  <USB>/TwinCAT_Update, then restarts them.
#  Optional arguments are passed to scripts/New-UpdatePackage.sh, e.g.
#      ./Create-UpdatePackage.sh --destination /media/usb
# ============================================================================

SELF=$(readlink -f -- "${BASH_SOURCE[0]}")

if (( EUID != 0 )); then
    echo 'Requesting root rights...'
    exec sudo -- bash "$SELF" "$@"
fi

bash "$(dirname -- "$SELF")/scripts/New-UpdatePackage.sh" "$@"
RC=$?

echo
if (( RC == 0 )); then
    echo '==== Update package created successfully ===='
else
    echo "==== FAILED - exit code $RC - see messages above ===="
fi
if [[ -z $NOPAUSE && -t 0 ]]; then read -rp 'Press Enter to continue...'; fi
exit $RC
