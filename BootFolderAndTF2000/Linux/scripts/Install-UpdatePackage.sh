#!/usr/bin/env bash
# =============================================================================
#  MACHINE IPC: applies a TwinCAT update package (Boot folder + HMI Server data)
#  from a USB stick. Designed to run unattended, e.g. started by the PLC
#  (NT_StartProcess) from an HMI button.
#
#  Nothing on the machine is touched until the package has been fully validated.
#  1. Finds <USB>/TwinCAT_Update/manifest.txt on the mounted (or auto-mounted) drives.
#  2. Checks the TwinCAT XAR and TF2000 HMI Server versions recorded in the package
#     (versions.txt) exactly match this machine, and verifies every file in the
#     package against its SHA-256 hash.
#  3. Switches TwinCAT to Config mode via ADS and stops the HMI Server service.
#  4. Backs up the current Boot + HMI folders to <LOCAL_BACKUP_ROOT>/<timestamp>_before_update.
#  5. Mirrors the package folders into place and verifies every file.
#  6. On any failure in 4-5: rolls back automatically from the backup.
#  7. Reboots the controller.
#
#  Exit codes: 0 = updated, 1 = failed before anything was changed,
#              2 = failed and rolled back, 3 = failed AND rollback failed (manual fix needed),
#              4 = another update is already running.
#
#  Result is also written to <LOCAL_BACKUP_ROOT>/last_update_status.txt and a copy of
#  the log is written to the USB stick (TwinCAT_Update/Logs).
#
#  Options:
#    --package-path <dir>      Full path of the package folder. Default: search the USB drives.
#    --config <file>           Use a different config file instead of Config.sh.
#    --no-reboot               Do not reboot; restart the HMI Server and put TwinCAT back
#                              into Run mode instead.
#    --allow-version-mismatch  Apply even if the XAR / TF2000 versions in the package differ
#                              from this machine (manual use only - the mismatch is still logged).
# =============================================================================

SCRIPT_DIR=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
# shellcheck source=Common.sh
source "$SCRIPT_DIR/Common.sh"

PACKAGE_PATH=''
CONFIG_PATH="$(dirname -- "$SCRIPT_DIR")/Config.sh"
NO_REBOOT=0
ALLOW_VERSION_MISMATCH=0

while (( $# )); do
    case $1 in
        --package-path) PACKAGE_PATH=$2; shift ;;
        --package-path=*) PACKAGE_PATH=${1#*=} ;;
        --config) CONFIG_PATH=$2; shift ;;
        --config=*) CONFIG_PATH=${1#*=} ;;
        --no-reboot) NO_REBOOT=1 ;;
        --allow-version-mismatch) ALLOW_VERSION_MISMATCH=1 ;;
        -h|--help) sed -n '3,31p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown argument: $1 (see --help)" >&2; exit 1 ;;
    esac
    shift
done

# Sets PKG to the single package folder found on the USB drives.
find_update_package() {
    mount_usb_drives
    local roots=() r p found=()
    local -A seen=()
    mapfile -t roots < <(usb_mount_points)
    roots+=(/media/* /media/*/* /run/media/*/* /mnt /mnt/*)
    for r in "${roots[@]}"; do
        p="$r/$PACKAGE_FOLDER_NAME"
        [[ -f $p/manifest.txt ]] || continue
        p=$(readlink -f -- "$p")
        [[ -n ${seen[$p]} ]] && continue
        seen[$p]=1
        found+=("$p")
    done
    if (( ${#found[@]} == 0 )); then
        log_error "No update package found (looked for <USB>/$PACKAGE_FOLDER_NAME/manifest.txt on the USB drives, /media, /run/media and /mnt)."
        return 1
    fi
    if (( ${#found[@]} > 1 )); then
        log_error "Several update packages found: $(join_array ', ' found). Remove all but one, or pass --package-path."
        return 1
    fi
    PKG=${found[0]}
}

write_status() {   # status detail
    mkdir -p -- "$LOCAL_BACKUP_ROOT" 2>/dev/null
    {
        echo "Status:  $1"
        printf 'Time:    %(%Y-%m-%d %H:%M:%S)T\n' -1
        echo "Detail:  $2"
        echo "Log:     $LOG_FILE"
    } > "$LOCAL_BACKUP_ROOT/last_update_status.txt" 2>/dev/null
}

remove_old_backups() {
    (( BACKUPS_TO_KEEP >= 1 )) || return 0
    local old=() d
    mapfile -t old < <(find "$LOCAL_BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended \
        -regex '.*/[0-9]{8}_[0-9]{6}_before_update' -printf '%f\n' | sort -r | tail -n +$(( BACKUPS_TO_KEEP + 1 )))
    for d in "${old[@]}"; do
        log "Removing old backup $LOCAL_BACKUP_ROOT/$d"
        rm -rf -- "${LOCAL_BACKUP_ROOT:?}/$d"
    done
}

log_problems() {   # item_name  (first 20 of VERIFY_PROBLEMS)
    local p
    for p in "${VERIFY_PROBLEMS[@]:0:20}"; do log_error "  [$1] $p"; done
}

# Mirrors the package folders into place and verifies them. Returns 1 on failure.
apply_package() {
    local name
    for name in "${PLAN[@]}"; do
        log_step "[$name] replacing ${TARGET[$name]}"
        MACHINE_TOUCHED=1
        copy_folder --mirror "$PKG/$name" "${TARGET[$name]}" --mode install \
            --exclude-files "XF_$name" --exclude-dirs "XD_$name" \
            --log "$BACKUP_DIR/apply-rsync.log" --label "Installing [$name]" || return 1
    done
    log_step 'Verifying installed files (SHA-256)...'
    for name in "${PLAN[@]}"; do
        verify_folder "${TARGET[$name]}" "$PKG/$name.sha256" "Verifying installed [$name]"
        if (( ${#VERIFY_PROBLEMS[@]} )); then
            log_problems "$name"
            log_error "Verification failed for '$name' (${#VERIFY_PROBLEMS[@]} problem(s))."
            return 1
        fi
        log_ok "[$name] installed and verified"
    done
}

# Restores every item from the backup. Returns 1 if any item could not be restored.
rollback() {
    local name rc=0
    log_step "ROLLING BACK from $BACKUP_DIR"
    for name in "${PLAN[@]}"; do
        if copy_folder --mirror "$BACKUP_DIR/$name" "${TARGET[$name]}" --mode backup \
            --log "$BACKUP_DIR/rollback-rsync.log" --label "Rolling back [$name]"; then
            verify_folder "${TARGET[$name]}" "$BACKUP_DIR/$name.sha256" "Verifying rollback [$name]"
            if (( ${#VERIFY_PROBLEMS[@]} == 0 )); then log_ok "[$name] rolled back"; continue; fi
            log_error "[$name] ROLLBACK FAILED: ${#VERIFY_PROBLEMS[@]} file(s) differ after rollback"
        else
            log_error "[$name] ROLLBACK FAILED: copy failed"
        fi
        rc=1
    done
    return $rc
}

schedule_reboot() {
    local delay=$(( REBOOT_DELAY_SECONDS > 0 ? REBOOT_DELAY_SECONDS : 1 )) s fallback=0
    local unit=twincat-update-reboot
    log_step "Rebooting in $delay s..."
    systemctl stop "$unit.timer" 2>/dev/null
    systemctl reset-failed "$unit.timer" "$unit.service" 2>/dev/null
    # A systemd timer reboots even if this script is killed during the countdown.
    if ! systemd-run --quiet --unit="$unit" --on-active="${delay}s" --timer-property=AccuracySec=1s \
        "$(command -v systemctl)" reboot 2>/dev/null; then
        log_warn 'Could not schedule the reboot with systemd-run - rebooting after the countdown instead.'
        fallback=1
    fi
    for (( s = delay; s > 0; s-- )); do
        progress_line "$STATUS_TEXT - controller restarts in $s s  (cancel: systemctl stop $unit.timer)"
        sleep 1
    done
    clear_progress
    (( fallback )) && systemctl reboot
}

EXIT_CODE=1
STAMP=$(printf '%(%Y%m%d_%H%M%S)T' -1)
MACHINE_TOUCHED=0    # 1 once the target folders may have been modified
STOPPED=0            # 1 once TwinCAT/HMI were stopped
CONFIG_LOADED=0
RESTART_SERVICES=()
PKG=''

fail() {
    (( $# )) && log_error "$*"
    exit "$EXIT_CODE"
}

finish() {
    trap '' INT TERM
    trap - EXIT
    local svc usb_log
    (( EXIT_CODE == 1 && MACHINE_TOUCHED )) && EXIT_CODE=3   # failed while copying, outside the rollback
    case $EXIT_CODE in
        0) STATUS_TEXT='SUCCESS' ;;
        1) STATUS_TEXT='FAILED - nothing changed' ;;
        2) STATUS_TEXT='FAILED - previous version restored' ;;
        3) STATUS_TEXT='FAILED - ROLLBACK FAILED, manual repair needed' ;;
        *) STATUS_TEXT="EXIT $EXIT_CODE" ;;
    esac
    if (( CONFIG_LOADED )); then
        write_status "$STATUS_TEXT" "Package: $PKG"
        local reboot=0
        if (( STOPPED )); then
            if (( EXIT_CODE == 3 )); then
                log_error 'Machine left stopped (Config mode) because the rollback failed. NOT rebooting.'
            elif (( REBOOT_AFTER_APPLY && ! NO_REBOOT )); then
                reboot=1
            else
                for svc in "${RESTART_SERVICES[@]}"; do start_service_safe "$svc" "$SERVICE_STOP_TIMEOUT_SEC"; done
                set_twincat_mode Run "$ADS_STATE_TIMEOUT_SEC" || log_error 'Could not switch TwinCAT to Run mode.'
            fi
        fi
        log "Result: $STATUS_TEXT (exit code $EXIT_CODE)"

        # Copy the log onto the USB stick so the result can be checked on the bench.
        if [[ -n $PKG && -n $LOG_FILE && -d $PKG ]]; then
            usb_log="$PKG/Logs/$(uname -n)_${STAMP}_${STATUS_TEXT//+([^A-Za-z])/_}.log"
            { mkdir -p -- "$PKG/Logs" && cp -f -- "$LOG_FILE" "$usb_log"; } 2>/dev/null ||
                log_warn "Could not copy log to USB: $usb_log"
        fi
        unmount_usb_drives
        (( reboot )) && schedule_reboot
    else
        unmount_usb_drives
    fi
    exit "$EXIT_CODE"
}

# --- Single instance (double button press, etc.) ----------------------------
# The lock is released automatically when this process ends, even if it is killed.
if ! { exec {LOCK_FD}>/run/lock/twincat-apply-update.lock; } 2>/dev/null; then
    echo 'Cannot create /run/lock/twincat-apply-update.lock (run as root).' >&2; exit 1
fi
flock -n "$LOCK_FD" || { echo 'Another update is already running.'; exit 4; }

trap finish EXIT
trap 'log_error "Interrupted."; exit "$EXIT_CODE"' INT TERM

assert_prerequisites || fail
import_update_config "$CONFIG_PATH" || fail
CONFIG_LOADED=1
start_log "$LOCAL_BACKUP_ROOT/Logs/Apply_$STAMP.log" || fail "Could not create the log folder in $LOCAL_BACKUP_ROOT"
log_step '=== Apply TwinCAT update package ==='
log "Running as $(id -un) on $(uname -n)"
write_status RUNNING 'Update in progress'

# =========================================================================
#  PHASE 1 - validate. Nothing on the machine is changed in this phase.
# =========================================================================
if [[ -n $PACKAGE_PATH ]]; then PKG=$(readlink -f -- "$PACKAGE_PATH"); else find_update_package || fail; fi
read_manifest "$PKG" || fail
log "Package: $PKG"
log "  created ${MANIFEST[CreatedLocal]} on ${MANIFEST[ComputerName]}, TwinCAT ${MANIFEST[TwinCATVersion]}"
[[ ${MANIFEST[Purpose]} == UpdatePackage ]] || fail "'$PKG' is not an update package (purpose: ${MANIFEST[Purpose]})."

# Versions must match exactly: XAR and TF2000 on this machine vs. the bench that built the package.
declare -A PKG_VERSIONS=() LOCAL_VERSIONS=()
read_version_file "$PKG/versions.txt" PKG_VERSIONS || fail
get_installed_versions LOCAL_VERSIONS
for k in "${!PKG_VERSIONS[@]}"; do
    log "$(printf 'Version %-18s package %-14s this machine %s' "$k" "${PKG_VERSIONS[$k]}" "${LOCAL_VERSIONS[$k]:-(unknown)}")"
done
compare_versions PKG_VERSIONS LOCAL_VERSIONS
if (( ${#VERSION_PROBLEMS[@]} )); then
    for p in "${VERSION_PROBLEMS[@]}"; do log_error "  VERSION MISMATCH - $p"; done
    (( ALLOW_VERSION_MISMATCH )) ||
        fail "Installed versions do not match the package (${#VERSION_PROBLEMS[@]} mismatch(es)). Nothing was changed."
    log_warn '--allow-version-mismatch given: continuing despite the version mismatch.'
else
    log_ok 'Installed XAR and TF2000 versions match the package'
fi
get_twincat_info
log "This machine: AMS Net ID $TC_AMS_NET_ID"

# Map package items -> target folders on this machine.
PLAN=()
declare -A TARGET=()
for name in "${MANIFEST_ITEMS[@]}"; do
    if [[ " ${PACKAGE_ITEMS[*]} " != *" $name "* ]]; then log_warn "[$name] not in Config.sh - skipping"; continue; fi
    resolve_item_folder "$name" ||
        fail "[$name] target folder not found on this machine. Checked: $(join_array ' | ' "${name}_CANDIDATES")"
    # Union of exclusions: never delete on the machine anything the package did not capture.
    declare -a "XF_$name" "XD_$name"
    manifest_array PKG_XF "$name.ExcludeFile"
    manifest_array PKG_XD "$name.ExcludeDir"
    union_arrays "XF_$name" "${name}_EXCLUDE_FILES" PKG_XF
    union_arrays "XD_$name" "${name}_EXCLUDE_DIRS" PKG_XD
    log "[$name] ${MANIFEST[$name.FileCount]} files -> $RESOLVED_DIR"
    xf_text=$(join_array ', ' "XF_$name")
    [[ -n $xf_text ]] && log "[$name] kept on machine (not replaced): $xf_text"
    PLAN+=("$name")
    TARGET[$name]=$RESOLVED_DIR
done
for name in "${PACKAGE_ITEMS[@]}"; do
    required="${name}_REQUIRED"
    if [[ ${!required:-0} == 1 && " ${PLAN[*]} " != *" $name "* ]]; then
        fail "Package does not contain required item '$name'."
    fi
done

log_step 'Verifying package integrity (SHA-256)...'
for name in "${PLAN[@]}"; do
    listed=$(wc -l < "$PKG/$name.sha256" 2>/dev/null)
    [[ ${listed:-x} == "${MANIFEST[$name.FileCount]}" ]] ||
        fail "Package is corrupt or incomplete ('$name.sha256' lists ${listed:-no} files, manifest says ${MANIFEST[$name.FileCount]})."
    verify_folder "$PKG/$name" "$PKG/$name.sha256" "Checking package [$name]"
    if (( ${#VERIFY_PROBLEMS[@]} )); then
        log_problems "$name"
        fail "Package is corrupt or incomplete (${#VERIFY_PROBLEMS[@]} problem(s) in '$name')."
    fi
    log_ok "[$name] package verified"
done

needed=0
for name in "${PLAN[@]}"; do
    folder_inventory "${TARGET[$name]}" NO_EXCLUDES NO_EXCLUDES
    (( needed += INV_BYTES ))
done
free=$(free_bytes "$LOCAL_BACKUP_ROOT")
(( ${free:-0} >= needed * 11 / 10 + 50 * 1048576 )) ||
    fail "Not enough free space for the local backup ($(format_mb "$needed") MB needed)."
initialize_ads || fail   # fail now (before stopping anything) if ADS is not available
log_ok 'Validation passed.'

# =========================================================================
#  PHASE 2 - stop, back up, replace, verify
# =========================================================================
STOPPED=1
set_twincat_mode Config "$ADS_STATE_TIMEOUT_SEC" || fail
stop_service_with_timeout "$HMI_SERVICE_NAME" "$SERVICE_STOP_TIMEOUT_SEC"
rc=$?
RESTART_SERVICES=("${SERVICES_TO_START[@]}")
(( rc == 0 )) || fail

BACKUP_DIR="$LOCAL_BACKUP_ROOT/${STAMP}_before_update"
log_step "Backing up current version to $BACKUP_DIR"
ENTRY_NAMES=("${PLAN[@]}")
declare -A ENTRY_PATH=()
for name in "${PLAN[@]}"; do ENTRY_PATH[$name]=${TARGET[$name]}; done
new_folder_snapshot "$BACKUP_DIR" PreUpdateBackup backup 0 || fail
write_version_file "$BACKUP_DIR/versions.txt" LOCAL_VERSIONS

if ! apply_package; then
    log_error 'Update failed.'
    if rollback; then
        EXIT_CODE=2
        fail 'Update failed; previous version restored.'
    fi
    EXIT_CODE=3
    fail "Update failed and rollback failed. Restore manually from $BACKUP_DIR"
fi

EXIT_CODE=0
log_ok "UPDATE SUCCESSFUL. Previous version saved in $BACKUP_DIR"
remove_old_backups
