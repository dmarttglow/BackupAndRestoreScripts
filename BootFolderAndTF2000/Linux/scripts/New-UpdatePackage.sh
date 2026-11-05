#!/usr/bin/env bash
# =============================================================================
#  BENCH SYSTEM: builds a TwinCAT update package (Boot folder + HMI Server data)
#  on a USB stick.
#
#  1. Switches TwinCAT to Config mode via ADS and stops the TwinCAT HMI Server service.
#  2. Copies the Boot folder and HMI Server folder into a local build folder
#     (/var/tmp), hashes every file (SHA-256) and writes manifest.txt.
#  3. Restarts the HMI Server and puts TwinCAT back into Run mode if it was running.
#  4. Compresses the build folder to <USB>/TwinCAT_Update/TwinCAT_Update.tar.gz (written
#     as .partial first; the previous package is kept as TwinCAT_Update_previous.tar.gz).
#
#  Options:
#    --destination <dir>  Mount point or folder in which to create the package folder.
#                         Default: the USB drive this script runs from, or the only USB drive present.
#    --config <file>      Use a different config file instead of Config.sh.
#    --no-stop            Do not stop TwinCAT / the HMI Server before copying (not recommended).
#    --leave-stopped      Leave TwinCAT in Config mode and the HMI Server stopped afterwards.
# =============================================================================

SCRIPT_DIR=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
# shellcheck source=Common.sh
source "$SCRIPT_DIR/Common.sh"

DESTINATION=''
CONFIG_PATH="$(dirname -- "$SCRIPT_DIR")/Config.sh"
NO_STOP=0
LEAVE_STOPPED=0

while (( $# )); do
    case $1 in
        --destination) DESTINATION=$2; shift ;;
        --destination=*) DESTINATION=${1#*=} ;;
        --config) CONFIG_PATH=$2; shift ;;
        --config=*) CONFIG_PATH=${1#*=} ;;
        --no-stop) NO_STOP=1 ;;
        --leave-stopped) LEAVE_STOPPED=1 ;;
        -h|--help) sed -n '3,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown argument: $1 (see --help)" >&2; exit 1 ;;
    esac
    shift
done

# Sets DEST_ROOT.
resolve_package_destination() {
    if [[ -n $DESTINATION ]]; then
        [[ -d $DESTINATION ]] || { log_error "Destination '$DESTINATION' does not exist."; return 1; }
        DEST_ROOT=$(readlink -f -- "$DESTINATION")
        return 0
    fi
    mount_usb_drives
    local mounts=() m own=''
    mapfile -t mounts < <(usb_mount_points)
    for m in "${mounts[@]}"; do [[ $SCRIPT_DIR == "$m"/* ]] && own=$m; done
    if [[ -n $own ]]; then DEST_ROOT=$own
    elif (( ${#mounts[@]} == 1 )); then DEST_ROOT=${mounts[0]}
    elif (( ${#mounts[@]} == 0 )); then log_error 'No USB stick found. Insert one or pass --destination.'; return 1
    else log_error "Several USB drives found ($(join_array ', ' mounts)). Pass --destination to choose one."; return 1
    fi
}

EXIT_CODE=1
TC_WAS_RUNNING=0
RESTART_SERVICES=()
ADS_USED=0

RESTORE_FAILED=0
BUILD_DIR=''

fail() {
    (( $# )) && log_error "$*"
    log_error 'Package NOT created. Any incomplete archive is left as *.partial and will never be used.'
    exit 1
}

# Restarts what was stopped. Does its work once: right after the copy, or in finish on failure.
restore_bench_state() {
    local svc
    if (( LEAVE_STOPPED )); then
        (( ADS_USED )) && log_warn '--leave-stopped given: TwinCAT left in Config mode, HMI Server left stopped.'
        ADS_USED=0
        return 0
    fi
    for svc in "${RESTART_SERVICES[@]}"; do start_service_safe "$svc" "$SERVICE_STOP_TIMEOUT_SEC"; done
    RESTART_SERVICES=()
    if (( TC_WAS_RUNNING )); then
        TC_WAS_RUNNING=0
        set_twincat_mode Run "$ADS_STATE_TIMEOUT_SEC" || { log_warn 'Could not return TwinCAT to Run mode.'; RESTORE_FAILED=1; }
    fi
}

finish() {
    trap '' INT TERM
    trap - EXIT
    restore_bench_state
    (( RESTORE_FAILED )) && EXIT_CODE=1
    [[ -n $BUILD_DIR ]] && rm -rf -- "$BUILD_DIR"
    LOG_FILE=''
    unmount_usb_drives
    exit "$EXIT_CODE"
}
trap finish EXIT
trap 'log_error "Interrupted."; exit 1' INT TERM

assert_prerequisites || fail
import_update_config "$CONFIG_PATH" || fail

resolve_package_destination || fail
PKG_DIR="$DEST_ROOT/$PACKAGE_FOLDER_NAME"
ARCHIVE_FINAL="$PKG_DIR/$PACKAGE_FOLDER_NAME.tar.gz"
ARCHIVE_TEMP="$ARCHIVE_FINAL.partial"
ARCHIVE_PREV="$PKG_DIR/${PACKAGE_FOLDER_NAME}_previous.tar.gz"
LOG_FINAL="$PKG_DIR/create.log"
LOG_TEMP="$PKG_DIR/create.partial.log"

# An uncompressed package from an older version of this tool: keep it as <folder>_previous.
OLD_STYLE=0
if [[ -f $PKG_DIR/manifest.txt ]]; then
    OLD_STYLE=1
    { rm -rf -- "${PKG_DIR}_previous" && mv -- "$PKG_DIR" "${PKG_DIR}_previous"; } ||
        fail "Could not move the old package to '${PKG_DIR}_previous'."
fi
mkdir -p -- "$PKG_DIR" && rm -f -- "$LOG_TEMP" || fail "Could not create '$PKG_DIR'."
start_log "$LOG_TEMP"

log_step '=== Create TwinCAT update package (bench) ==='
log "Running as $(id -un) on $(uname -n)"
(( OLD_STYLE )) && log "Uncompressed package from an older version moved to ${PKG_DIR}_previous"
get_twincat_info
log "TwinCAT version: $TC_VERSION   AMS Net ID: $TC_AMS_NET_ID"
log "Package file:    $ARCHIVE_FINAL"

BUILD_DIR="/var/tmp/${PACKAGE_FOLDER_NAME}_build"
rm -rf -- "$BUILD_DIR" && mkdir -p -- "$BUILD_DIR" || fail "Could not create '$BUILD_DIR'."
log "Build folder:    $BUILD_DIR"

# --- Record installed versions (checked by Apply-Update on the machine) -------
declare -A VERSIONS=()
get_installed_versions VERSIONS
for k in "${VERSION_KEYS[@]}"; do
    [[ -n ${VERSIONS[$k]} ]] || fail "Could not read the installed $k version on this bench system (check XAR_PACKAGES / HMI_PACKAGES in Config.sh)."
    log "$(printf 'Version %-18s %s' "$k" "${VERSIONS[$k]}")"
done
write_version_file "$BUILD_DIR/versions.txt" VERSIONS || fail "Could not write $BUILD_DIR/versions.txt"

# --- Resolve source folders -------------------------------------------------
ENTRY_NAMES=()
declare -A ENTRY_PATH=()
for name in "${PACKAGE_ITEMS[@]}"; do
    if ! resolve_item_folder "$name"; then
        msg="[$name] no folder found. Checked: $(join_array ' | ' "${name}_CANDIDATES")"
        required="${name}_REQUIRED"
        [[ ${!required:-0} == 1 ]] && fail "$msg"
        log_warn "$msg - skipping"
        continue
    fi
    log "[$name] source: $RESOLVED_DIR"
    declare -a "XF_$name" "XD_$name"
    union_arrays "XF_$name" "${name}_EXCLUDE_FILES"
    union_arrays "XD_$name" "${name}_EXCLUDE_DIRS"
    xf_text=$(join_array ', ' "XF_$name")
    [[ -n $xf_text ]] && log "[$name] excluded files: $xf_text"
    ENTRY_NAMES+=("$name")
    ENTRY_PATH[$name]=$RESOLVED_DIR
done
(( ${#ENTRY_NAMES[@]} )) || fail 'Nothing to package.'

# --- Free space check -------------------------------------------------------
needed=0
for name in "${ENTRY_NAMES[@]}"; do
    folder_inventory "${ENTRY_PATH[$name]}" "XF_$name" "XD_$name"
    (( needed += INV_BYTES ))
done
# The archive is never much bigger than the files, so the same margin covers both drives.
free=$(free_bytes "$PKG_DIR")
free_build=$(free_bytes "$BUILD_DIR")
log "Package size: $(format_mb "$needed") MB, free on destination: $(format_mb "${free:-0}") MB, free for build folder: $(format_mb "${free_build:-0}") MB"
(( ${free:-0} >= needed * 11 / 10 + 10 * 1048576 )) || fail 'Not enough free space on the destination drive.'
(( ${free_build:-0} >= needed * 11 / 10 + 10 * 1048576 )) || fail "Not enough free space for the build folder $BUILD_DIR."

# --- Stop TwinCAT runtime + HMI Server ---------------------------------------
if (( NO_STOP )); then
    log_warn '--no-stop given: copying while TwinCAT and the HMI Server are running.'
else
    ADS_USED=1
    initialize_ads || fail
    [[ $TC_STATE == Run ]] && TC_WAS_RUNNING=1
    set_twincat_mode Config "$ADS_STATE_TIMEOUT_SEC" || fail
    stop_service_with_timeout "$HMI_SERVICE_NAME" "$SERVICE_STOP_TIMEOUT_SEC"
    rc=$?
    RESTART_SERVICES=("${SERVICES_TO_START[@]}")
    (( rc == 0 )) || fail
fi

# --- Copy + hash ------------------------------------------------------------
new_folder_snapshot "$BUILD_DIR" UpdatePackage package 1 || fail
restore_bench_state   # copy done: TwinCAT and the HMI Server can run again while compressing

# --- Compress onto the stick ---------------------------------------------------
log_step "Compressing package to $ARCHIVE_TEMP"
compress_folder "$BUILD_DIR" "$ARCHIVE_TEMP" || fail

# --- Publish: .partial -> final (keep one previous package) -------------------
if [[ -e $ARCHIVE_FINAL ]]; then
    mv -f -- "$ARCHIVE_FINAL" "$ARCHIVE_PREV" || fail "Could not move the old package to '$ARCHIVE_PREV'."
    log "Previous package kept as $ARCHIVE_PREV"
fi
mv -- "$ARCHIVE_TEMP" "$ARCHIVE_FINAL" || fail "Could not rename '$ARCHIVE_TEMP' to '$ARCHIVE_FINAL'."
[[ -e $LOG_FINAL ]] && mv -f -- "$LOG_FINAL" "$PKG_DIR/create_previous.log"
mv -f -- "$LOG_TEMP" "$LOG_FINAL" && LOG_FILE=$LOG_FINAL

for name in "${ENTRY_NAMES[@]}"; do
    log_ok "$(printf '  %-6s %6d files  %10s MB' "$name" "${SNAP_COUNT[$name]}" "$(format_mb "${SNAP_BYTES[$name]}")")"
done
sync
log_ok "Package created: $PKG_FINAL"
EXIT_CODE=0
