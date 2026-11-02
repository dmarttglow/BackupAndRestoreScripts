#!/usr/bin/env bash
# =============================================================================
#  BENCH SYSTEM: builds a TwinCAT update package (Boot folder + HMI Server data)
#  on a USB stick.
#
#  1. Switches TwinCAT to Config mode via ADS and stops the TwinCAT HMI Server service.
#  2. Copies the Boot folder and HMI Server folder into <USB>/TwinCAT_Update.partial,
#     hashes every file (SHA-256) and writes manifest.txt.
#  3. Renames the folder to <USB>/TwinCAT_Update (the previous package is kept as
#     TwinCAT_Update_previous).
#  4. Restarts the HMI Server and puts TwinCAT back into Run mode if it was running.
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

fail() {
    (( $# )) && log_error "$*"
    log_error 'Package NOT created. Any incomplete copy is left as *.partial and will never be used.'
    exit 1
}

finish() {
    trap '' INT TERM
    trap - EXIT
    local svc
    if (( ! LEAVE_STOPPED )); then
        for svc in "${RESTART_SERVICES[@]}"; do start_service_safe "$svc" "$SERVICE_STOP_TIMEOUT_SEC"; done
        if (( TC_WAS_RUNNING )); then
            set_twincat_mode Run "$ADS_STATE_TIMEOUT_SEC" || { log_warn 'Could not return TwinCAT to Run mode.'; EXIT_CODE=1; }
        fi
    elif (( ADS_USED )); then
        log_warn '--leave-stopped given: TwinCAT left in Config mode, HMI Server left stopped.'
    fi
    LOG_FILE=''
    unmount_usb_drives
    exit "$EXIT_CODE"
}
trap finish EXIT
trap 'log_error "Interrupted."; exit 1' INT TERM

assert_prerequisites || fail
import_update_config "$CONFIG_PATH" || fail

resolve_package_destination || fail
PKG_FINAL="$DEST_ROOT/$PACKAGE_FOLDER_NAME"
PKG_TEMP="$PKG_FINAL.partial"
PKG_PREV="${PKG_FINAL}_previous"

rm -rf -- "$PKG_TEMP" && mkdir -p -- "$PKG_TEMP" || fail "Could not create '$PKG_TEMP'."
start_log "$PKG_TEMP/create.log"

log_step '=== Create TwinCAT update package (bench) ==='
log "Running as $(id -un) on $(uname -n)"
get_twincat_info
log "TwinCAT version: $TC_VERSION   AMS Net ID: $TC_AMS_NET_ID"
log "Package folder:  $PKG_FINAL"

# --- Record installed versions (checked by Apply-Update on the machine) -------
declare -A VERSIONS=()
get_installed_versions VERSIONS
for k in "${VERSION_KEYS[@]}"; do
    [[ -n ${VERSIONS[$k]} ]] || fail "Could not read the installed $k version on this bench system (check XAR_PACKAGES / HMI_PACKAGES in Config.sh)."
    log "$(printf 'Version %-18s %s' "$k" "${VERSIONS[$k]}")"
done
write_version_file "$PKG_TEMP/versions.txt" VERSIONS || fail "Could not write $PKG_TEMP/versions.txt"

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
free=$(free_bytes "$PKG_TEMP")
log "Package size: $(format_mb "$needed") MB, free on destination: $(format_mb "${free:-0}") MB"
(( ${free:-0} >= needed * 11 / 10 + 10 * 1048576 )) || fail 'Not enough free space on the destination drive.'

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
new_folder_snapshot "$PKG_TEMP" UpdatePackage package 1 || fail

# --- Publish: .partial -> final (keep one previous package) -------------------
if [[ -e $PKG_FINAL ]]; then
    { rm -rf -- "$PKG_PREV" && mv -- "$PKG_FINAL" "$PKG_PREV"; } || fail "Could not move the old package to '$PKG_PREV'."
    log "Previous package kept as $PKG_PREV"
fi
mv -- "$PKG_TEMP" "$PKG_FINAL" || fail "Could not rename '$PKG_TEMP' to '$PKG_FINAL'."
LOG_FILE="$PKG_FINAL/create.log"

for name in "${ENTRY_NAMES[@]}"; do
    log_ok "$(printf '  %-6s %6d files  %10s MB' "$name" "${SNAP_COUNT[$name]}" "$(format_mb "${SNAP_BYTES[$name]}")")"
done
sync
log_ok "Package created: $PKG_FINAL"
EXIT_CODE=0
