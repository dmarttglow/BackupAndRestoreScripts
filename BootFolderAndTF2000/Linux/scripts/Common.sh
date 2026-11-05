# shellcheck shell=bash
# =============================================================================
#  Shared helpers for New-UpdatePackage.sh and Install-UpdatePackage.sh.
#  Source only. Requires bash 4.3+, GNU coreutils/findutils, util-linux,
#  rsync and systemd.
# =============================================================================

shopt -s extglob
set -o pipefail

LOG_FILE=''
PROGRESS_LAST_DRAW=0
SPINNER_FRAMES=('|' '/' '-' '\')
CONSOLE_WIDTH=$(tput cols 2>/dev/null || echo 80)
(( CONSOLE_WIDTH >= 21 )) || CONSOLE_WIDTH=80
NO_EXCLUDES=()
AUTO_MOUNTED=()
ADS_READY=0

ADS_STATE_NAMES=([0]=Invalid [1]=Idle [2]=Reset [3]=Init [4]=Start [5]=Run [6]=Stop [7]=SaveCfg
    [8]=LoadCfg [9]=PowerFailure [10]=PowerGood [11]=Error [12]=Shutdown [13]=Suspend [14]=Resume
    [15]=Config [16]=Reconfig [17]=Stopping [18]=Incompatible [19]=Exception)

# fd 3 is the console: log lines still reach it from inside $(...).
exec 3>&1

# -----------------------------------------------------------------------------
#  Logging / console progress
# -----------------------------------------------------------------------------

# True at most 4x per second while fd 3 is a terminal. Use as:
#   progress_due && progress_line "..."
progress_due() {
    [[ -t 3 ]] || return 1
    local now=${EPOCHREALTIME/[.,]/}   # microseconds (bash 5); falls back to whole seconds
    [[ -n $now ]] || now=$(( SECONDS * 1000000 ))
    (( now - PROGRESS_LAST_DRAW >= 250000 )) || return 1
    PROGRESS_LAST_DRAW=$now
}

# Draws a single status line that is overwritten in place on the console, so
# long steps visibly keep moving. Console only - never written to the log.
progress_line() {
    [[ -t 3 ]] || return 0
    local spin=${SPINNER_FRAMES[(PROGRESS_LAST_DRAW / 250000) % 4]}
    local line="  $spin $1"
    printf '\r%-*s' $(( CONSOLE_WIDTH - 1 )) "${line:0:CONSOLE_WIDTH-1}" >&3
}

clear_progress() {
    [[ -t 3 ]] || return 0
    printf '\r%*s\r' $(( CONSOLE_WIDTH - 1 )) '' >&3
}

# Seconds -> mm:ss or h:mm:ss
format_elapsed() {
    local s=$1
    if (( s >= 3600 )); then printf '%d:%02d:%02d' $(( s / 3600 )) $(( s % 3600 / 60 )) $(( s % 60 ))
    else printf '%02d:%02d' $(( s / 60 )) $(( s % 60 )); fi
}

# Bytes -> "12.3" (MB)
format_mb() { awk -v b="$1" 'BEGIN { printf "%.1f", b / 1048576 }'; }

_log() {
    local level=$1 color line
    shift
    printf -v line '[%(%Y-%m-%d %H:%M:%S)T] [%-5s] %s' -1 "$level" "$*"
    if [[ -t 3 ]]; then
        case $level in
            STEP) color=36 ;; OK) color=32 ;; WARN) color=33 ;; ERROR) color=31 ;; *) color=37 ;;
        esac
        clear_progress
        printf '\e[%sm%s\e[0m\n' "$color" "$line" >&3
    else
        printf '%s\n' "$line" >&3
    fi
    if [[ -n $LOG_FILE ]]; then printf '%s\n' "$line" >> "$LOG_FILE" 2>/dev/null; fi
    return 0
}
log()       { _log INFO "$@"; }
log_step()  { _log STEP "$@"; }
log_ok()    { _log OK "$@"; }
log_warn()  { _log WARN "$@"; }
log_error() { _log ERROR "$@"; }

start_log() {
    mkdir -p -- "$(dirname -- "$1")" && LOG_FILE=$1
}

assert_prerequisites() {
    if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
        log_error "bash 4.3 or newer is required (found $BASH_VERSION)."; return 1
    fi
    if (( EUID != 0 )); then
        log_error 'This script must run as root (sudo, or as root when started from the PLC).'; return 1
    fi
    local c missing=()
    for c in rsync sha256sum find sort awk df flock lsblk mount umount systemctl timeout tar gzip; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    if (( ${#missing[@]} )); then
        log_error "Required commands not found: ${missing[*]} (e.g. apt install rsync)."; return 1
    fi
}

# -----------------------------------------------------------------------------
#  Configuration
# -----------------------------------------------------------------------------

import_update_config() {
    local path=$1 n
    [[ -f $path ]] || { log_error "Config file not found: $path"; return 1; }
    # shellcheck source=../Config.sh
    source "$path" || { log_error "Config file '$path' could not be read."; return 1; }
    (( ${#PACKAGE_ITEMS[@]} )) || { log_error "Config file '$path' does not define PACKAGE_ITEMS."; return 1; }
    : "${PACKAGE_FOLDER_NAME:=TwinCAT_Update}" "${LOCAL_BACKUP_ROOT:=/var/lib/TwinCAT_UpdateBackups}"
    : "${BACKUPS_TO_KEEP:=5}" "${REBOOT_AFTER_APPLY:=1}" "${REBOOT_DELAY_SECONDS:=10}"
    : "${ADS_STATE_TIMEOUT_SEC:=30}" "${SERVICE_STOP_TIMEOUT_SEC:=60}" "${HMI_SERVICE_NAME:=TcHmiSrv}"
    for n in "${PACKAGE_ITEMS[@]}"; do
        [[ $n =~ ^[A-Za-z][A-Za-z0-9_]*$ ]] || {
            log_error "Package item name '$n' may only contain letters, digits and '_'."; return 1; }
        declare -ga "${n}_CANDIDATES" "${n}_EXCLUDE_FILES" "${n}_EXCLUDE_DIRS"
        if [[ $n == Boot && ${PRESERVE_PERSISTENT_DATA:-1} == 1 ]]; then
            _add_bootdata_excludes "${n}_EXCLUDE_FILES"
        fi
    done
}

_add_bootdata_excludes() { local -n _abx=$1; _abx+=('*.bootdata' '*.bootdata-old'); }

# Prints the elements of the array named $2 joined with $1.
join_array() {
    local -n _ja=$2
    local out='' v
    for v in "${_ja[@]}"; do out+="${out:+$1}$v"; done
    printf '%s' "$out"
}

# Sets the array named $1 to the non-empty, unique elements of the arrays named $2, $3, ...
union_arrays() {
    local -n _ua_to=$1
    local v result=() all=()
    local -A seen=()
    shift
    while (( $# )); do _append_array all "$1"; shift; done
    for v in "${all[@]}"; do
        [[ -n $v && -z ${seen[$v]} ]] || continue
        seen[$v]=1
        result+=("$v")
    done
    _ua_to=("${result[@]}")
}
_append_array() { local -n _aa_to=$1 _aa_from=$2; _aa_to+=("${_aa_from[@]}"); }

# Sets RESOLVED_DIR to the first existing candidate folder of an item. Warns if several exist.
resolve_item_folder() {
    local -n _rif_cands="${1}_CANDIDATES"
    local c p existing=()
    for c in "${_rif_cands[@]}"; do
        [[ -n $c && -d $c ]] || continue
        p=$(readlink -f -- "$c")
        [[ " ${existing[*]} " == *" $p "* ]] || existing+=("$p")
    done
    if (( ${#existing[@]} > 1 )); then
        log_warn "[$1] several candidate folders exist: ${existing[*]}. Using the first: ${existing[0]}"
    fi
    RESOLVED_DIR=${existing[0]:-}
    [[ -n $RESOLVED_DIR ]]
}

# -----------------------------------------------------------------------------
#  USB drives
# -----------------------------------------------------------------------------

# Mounts hot-plugged partitions that have a file system but no mount point
# (when AUTO_MOUNT_USB=1). They are remembered in AUTO_MOUNTED.
mount_usb_drives() {
    [[ ${AUTO_MOUNT_USB:-0} == 1 ]] || return 0
    local line name hp fstype type mp dir
    while IFS= read -r line; do
        [[ $line =~ NAME=\"([^\"]*)\"\ HOTPLUG=\"([^\"]*)\"\ FSTYPE=\"([^\"]*)\"\ TYPE=\"([^\"]*)\"\ MOUNTPOINT=\"([^\"]*)\" ]] || continue
        name=${BASH_REMATCH[1]} hp=${BASH_REMATCH[2]} fstype=${BASH_REMATCH[3]} type=${BASH_REMATCH[4]} mp=${BASH_REMATCH[5]}
        [[ $hp == 1 && -n $fstype && -z $mp && $type =~ ^(part|disk)$ && $fstype != swap ]] || continue
        dir="/run/twincat-update/usb-${name##*/}"
        mkdir -p -- "$dir" || continue
        if mount -- "$name" "$dir" 2>/dev/null; then
            AUTO_MOUNTED+=("$dir")
            log "Mounted $name ($fstype) at $dir"
        else
            rmdir -- "$dir" 2>/dev/null
        fi
    done < <(lsblk -Ppno NAME,HOTPLUG,FSTYPE,TYPE,MOUNTPOINT 2>/dev/null)
}

unmount_usb_drives() {
    local dir
    sync
    for dir in "${AUTO_MOUNTED[@]}"; do
        if umount -- "$dir" 2>/dev/null; then rmdir -- "$dir" 2>/dev/null
        else log_warn "Could not unmount $dir"; fi
    done
    AUTO_MOUNTED=()
}

# Prints the mount points of mounted hot-plugged (USB) drives, one per line.
usb_mount_points() {
    local hp mp
    while read -r hp mp; do
        [[ $hp == 1 && -n $mp ]] || continue
        printf '%b\n' "$mp"   # lsblk -r escapes spaces as \x20
    done < <(lsblk -rno HOTPLUG,MOUNTPOINT 2>/dev/null) | sort -u
}

# Free bytes on the file system holding $1.
free_bytes() { df -Pk -- "$1" 2>/dev/null | awk 'NR == 2 { printf "%.0f", $4 * 1024 }'; }

# -----------------------------------------------------------------------------
#  Files: inventory, hashing, copying, verification
# -----------------------------------------------------------------------------

# Lists regular files under Root with find -printf FORMAT (default: relative
# path, NUL-terminated), honoring the exclusion arrays named XF and XD.
list_files() {   # root xf_array_name xd_array_name [format]
    local root=$1 fmt=${4:-'%P\0'} p
    local -n _lf_xf=$2 _lf_xd=$3
    [[ -d $root ]] || return 0
    local expr=()
    if (( ${#_lf_xd[@]} )); then
        expr+=( '(' -type d '(' )
        for p in "${_lf_xd[@]}"; do expr+=( -name "$p" -o ); done
        unset 'expr[${#expr[@]}-1]'
        expr+=( ')' -prune ')' -o )
    fi
    expr+=( -type f )
    for p in "${_lf_xf[@]}"; do expr+=( ! -name "$p" ); done
    find "$root" -mindepth 1 "${expr[@]}" -printf "$fmt"
}

# Sets INV_COUNT and INV_BYTES for the files under Root (same arguments as list_files).
folder_inventory() {
    [[ -t 3 ]] && progress_line "Scanning $1 ..."
    read -r INV_COUNT INV_BYTES < <(list_files "$1" "$2" "$3" '%s\n' |
        awk '{ n++; s += $1 } END { printf "%d %.0f\n", n, s }')
    clear_progress
}

# Hashes the files under Root into OUT in sha256sum format (paths relative to Root).
hash_folder() {   # root xf_array_name xd_array_name out activity
    local root=$1 out=$4 activity=$5 i=0 t0=$SECONDS line
    folder_inventory "$root" "$2" "$3"
    local total=$INV_COUNT
    while IFS= read -r line; do
        printf '%s\n' "$line"
        (( ++i ))
        progress_due && progress_line "$activity: $i/$total files ($(( total ? 100 * i / total : 100 ))%)  $(format_elapsed $(( SECONDS - t0 )))"
    done < <(cd -- "$root" && list_files . "$2" "$3" | LC_ALL=C sort -z | xargs -0r sha256sum --) > "$out"
    clear_progress
    [[ -f $out ]] && (( i == total )) || { log_error "Hashing '$root' failed ($i of $total files hashed)."; return 1; }
}

# Checks the files under Root against a sha256sum list. Sets VERIFY_PROBLEMS.
verify_folder() {   # root sha_file activity
    local root=$1 sums activity=$3 line i=0 total t0=$SECONDS
    VERIFY_PROBLEMS=()
    sums=$(readlink -f -- "$2") && [[ -f $sums ]] || { VERIFY_PROBLEMS=("checksum list missing: $2"); return 0; }
    total=$(wc -l < "$sums")
    while IFS= read -r line; do
        case $line in
            *': OK') ;;
            *': FAILED open or read') VERIFY_PROBLEMS+=("missing: ${line%: FAILED open or read}") ;;
            *': FAILED') VERIFY_PROBLEMS+=("content differs: ${line%: FAILED}") ;;
            *) continue ;;
        esac
        (( ++i ))
        progress_due && progress_line "$activity: $i/$total files ($(( total ? 100 * i / total : 100 ))%)  $(format_elapsed $(( SECONDS - t0 )))"
    done < <(cd -- "$root" 2>/dev/null && sha256sum -c -- "$sums" 2>/dev/null)
    clear_progress
    (( i == total )) || VERIFY_PROBLEMS+=("only $i of $total files could be checked in '$root'")
}

# Copies Source into Destination with rsync, always rewriting every file.
#   --mirror  also delete files in Destination that are not in Source
#             (excluded files are neither copied nor deleted)
#   --mode package  data + timestamps only, symlinks skipped (USB sticks are usually FAT/exFAT)
#   --mode backup   exact copy: permissions, owners, symlinks
#   --mode install  data + timestamps; files get the owner of the Destination folder
copy_folder() {
    local mirror=0 mode=backup src dst xf=NO_EXCLUDES xd=NO_EXCLUDES logpath label='Copying'
    while (( $# )); do
        case $1 in
            --mirror) mirror=1 ;;
            --mode) mode=$2; shift ;;
            --exclude-files) xf=$2; shift ;;
            --exclude-dirs) xd=$2; shift ;;
            --log) logpath=$2; shift ;;
            --label) label=$2; shift ;;
            *) if [[ -z $src ]]; then src=$1; else dst=$1; fi ;;
        esac
        shift
    done
    local -n _cf_xf=$xf _cf_xd=$xd
    local args=(--ignore-times --log-file="$logpath") p
    case $mode in
        package) args+=(-rt) ;;
        backup)  args+=(-aH) ;;
        install) args+=(-rt -og "--chown=$(stat -c %u:%g -- "$dst" 2>/dev/null || echo 0:0)") ;;
    esac
    (( mirror )) && args+=(--delete)
    for p in "${_cf_xf[@]}"; do args+=("--exclude=$p"); done
    for p in "${_cf_xd[@]}"; do args+=("--exclude=$p/"); done

    mkdir -p -- "$dst" || { log_error "Could not create '$dst'."; return 1; }
    local t0=$SECONDS code
    # Run in the background so the console can show that the copy is still going.
    rsync "${args[@]}" -- "$src/" "$dst/" >/dev/null 2>>"$logpath" &
    local pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        progress_line "$label ...  $(format_elapsed $(( SECONDS - t0 ))) elapsed"
        sleep 0.25
    done
    wait "$pid"; code=$?
    clear_progress
    if (( code == 24 )); then
        log_warn "rsync: some source files vanished during the copy (exit code 24)"
    elif (( code != 0 )); then
        log_error "rsync failed (exit code $code) copying '$src' -> '$dst'. See $logpath"; return 1
    fi
    log "rsync finished in $(format_elapsed $(( SECONDS - t0 ))) (exit code $code)"
}

# Copies each entry (ENTRY_NAMES, ENTRY_PATH[name]) into <Destination>/<name>,
# hashes the copy into <Destination>/<name>.sha256 and writes manifest.txt.
# With use_excludes=1 the arrays XF_<name> / XD_<name> are honored.
# Sets SNAP_COUNT[name] / SNAP_BYTES[name].
new_folder_snapshot() {   # destination purpose copy_mode use_excludes
    local dest=$1 purpose=$2 mode=$3 use_x=$4 name target xf xd
    declare -gA SNAP_COUNT=() SNAP_BYTES=()
    mkdir -p -- "$dest" || { log_error "Could not create '$dest'."; return 1; }
    local body=''
    for name in "${ENTRY_NAMES[@]}"; do
        target="$dest/$name"
        if (( use_x )); then xf="XF_$name" xd="XD_$name"; else xf=NO_EXCLUDES xd=NO_EXCLUDES; fi
        log_step "[$name] copying '${ENTRY_PATH[$name]}' -> '$target'"
        copy_folder "${ENTRY_PATH[$name]}" "$target" --mode "$mode" --exclude-files "$xf" --exclude-dirs "$xd" \
            --log "$dest/rsync.log" --label "Copying [$name]" || return 1

        folder_inventory "${ENTRY_PATH[$name]}" "$xf" "$xd"
        local src_count=$INV_COUNT
        hash_folder "$target" "$xf" "$xd" "$dest/$name.sha256" "Hashing [$name]" || return 1
        folder_inventory "$target" "$xf" "$xd"
        if (( INV_COUNT != src_count )); then
            log_error "[$name] file count mismatch after copy: source has $src_count, copy has $INV_COUNT."; return 1
        fi
        log_ok "[$name] $INV_COUNT files, $(format_mb "$INV_BYTES") MB copied and hashed"
        SNAP_COUNT[$name]=$INV_COUNT
        SNAP_BYTES[$name]=$INV_BYTES

        body+="Item=$name"$'\n'
        body+="$name.Description=$(_item_description "$name")"$'\n'
        body+="$name.SourcePath=${ENTRY_PATH[$name]}"$'\n'
        _manifest_list "$name.ExcludeFile" "$xf"
        _manifest_list "$name.ExcludeDir" "$xd"
        body+="$name.FileCount=$INV_COUNT"$'\n'
        body+="$name.TotalBytes=$INV_BYTES"$'\n'
    done

    get_twincat_info
    # manifest.txt is written LAST: its presence marks the snapshot as complete.
    {
        echo 'FormatVersion=1'
        echo "Purpose=$purpose"
        printf 'CreatedLocal=%(%Y-%m-%d %H:%M:%S)T\n' -1
        echo "ComputerName=$(uname -n)"
        echo "TwinCATVersion=$TC_VERSION"
        echo "AmsNetId=$TC_AMS_NET_ID"
        printf '%s' "$body"
    } > "$dest/manifest.txt" || { log_error "Could not write $dest/manifest.txt"; return 1; }
}

_item_description() { local -n _id="${1}_DESCRIPTION"; printf '%s' "${_id:-$1}"; }
# Appends one "key=value" line per array element to the caller's $body.
_manifest_list() { local -n _ml=$2; local v; for v in "${_ml[@]}"; do body+="$1=$v"$'\n'; done; }

# Reads <Folder>/manifest.txt into MANIFEST (key -> value) and MANIFEST_ITEMS.
# Repeated keys (ExcludeFile / ExcludeDir) are joined with newlines.
# -----------------------------------------------------------------------------
#  Archive (the package travels on the USB stick as a single .tar.gz file)
# -----------------------------------------------------------------------------

# Runs a command in the background while showing a progress line.
_run_with_progress() {   # label command...
    local label=$1 t0=$SECONDS pid code
    shift
    "$@" &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        progress_line "$label ...  $(format_elapsed $(( SECONDS - t0 ))) elapsed"
        sleep 0.25
    done
    wait "$pid"; code=$?
    clear_progress
    return $code
}

# Packs everything under folder into archive (overwritten).
compress_folder() {   # folder archive
    local t0=$SECONDS
    rm -f -- "$2"
    _run_with_progress 'Compressing' tar -czf "$2" --numeric-owner --owner=0 --group=0 -C "$1" . 2>>"${LOG_FILE:-/dev/null}" ||
        { log_error "tar failed creating '$2'."; return 1; }
    log "Compressed in $(format_elapsed $(( SECONDS - t0 ))): $(format_mb "$(du -sb -- "$1" | cut -f1)") MB -> $(format_mb "$(stat -c %s -- "$2")") MB"
}

# Prints the total uncompressed size of the files in an archive.
archive_content_size() { tar -tvzf "$1" 2>/dev/null | awk '{ s += $3 } END { printf "%.0f\n", s }'; }

# Extracts archive into destination (created; must not exist yet). GNU tar
# refuses member names with '..' or a leading '/'.
extract_archive() {   # archive destination
    local t0=$SECONDS
    mkdir -p -- "$2" || { log_error "Could not create '$2'."; return 1; }
    _run_with_progress 'Extracting' tar -xzf "$1" -C "$2" --no-same-owner --no-same-permissions 2>>"${LOG_FILE:-/dev/null}" ||
        { log_error "tar failed extracting '$1' (archive damaged?)."; return 1; }
    log "Extracted in $(format_elapsed $(( SECONDS - t0 )))"
}

read_manifest() {
    local file="$1/manifest.txt" line k v
    [[ -f $file ]] || { log_error "No manifest.txt in '$1' (incomplete or not a package)."; return 1; }
    declare -gA MANIFEST=()
    MANIFEST_ITEMS=()
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        [[ $line == *=* ]] || continue
        k=${line%%=*} v=${line#*=}
        case $k in
            Item)
                [[ $v =~ ^[A-Za-z][A-Za-z0-9_]*$ ]] || { log_error "manifest.txt in '$1' has an invalid item name '$v'."; return 1; }
                MANIFEST_ITEMS+=("$v") ;;
            *.ExcludeFile|*.ExcludeDir) MANIFEST[$k]+="$v"$'\n' ;;
            *) MANIFEST[$k]=$v ;;
        esac
    done < "$file"
    (( ${#MANIFEST_ITEMS[@]} )) || { log_error "manifest.txt in '$1' lists no items."; return 1; }
}

# Fills the array named $1 with the newline-joined manifest value of key $2.
manifest_array() { local -n _ma=$1; mapfile -t _ma < <(printf '%s' "${MANIFEST[$2]}"); }

# -----------------------------------------------------------------------------
#  TwinCAT info + versions
# -----------------------------------------------------------------------------

# "1:3.1.4026.12-1" / "3, 1, 4026, 27" -> "3.1.4026.12" / "3.1.4026.27"
format_version() {
    local v=${1//[[:space:]]/}
    v=${v//,/.}
    [[ $v =~ ^[0-9]+:(.*)$ ]] && v=${BASH_REMATCH[1]}
    [[ $v =~ ^[0-9.]* ]] && v=${BASH_REMATCH[0]}
    v=${v##+(.)}; v=${v%%+(.)}
    printf '%s' "$v"
}

# Installed version of the first of the given packages that is installed (dpkg, rpm or pkg).
package_version() {
    local p v
    for p in "$@"; do
        v=''
        if command -v dpkg-query >/dev/null 2>&1; then
            v=$(dpkg-query -W -f='${db:Status-Status}|${Version}' -- "$p" 2>/dev/null)
            [[ $v == installed\|* ]] && v=${v#*|} || v=''
        elif command -v rpm >/dev/null 2>&1; then
            v=$(rpm -q --qf '%{VERSION}' -- "$p" 2>/dev/null) || v=''
        elif command -v pkg >/dev/null 2>&1; then
            v=$(pkg query %v "$p" 2>/dev/null) || v=''
        fi
        if [[ -n $v ]]; then format_version "$v"; return 0; fi
    done
}

# Sets TC_VERSION (installed XAR package) and TC_AMS_NET_ID (from TcRegistry.xml).
get_twincat_info() {
    TC_VERSION=$(package_version "${XAR_PACKAGES[@]}")
    TC_AMS_NET_ID=''
    local f hex
    for f in /etc/TwinCAT/3.1/TcRegistry.xml /usr/local/etc/TwinCAT/3.1/TcRegistry.xml; do
        [[ -f $f ]] || continue
        hex=$(grep -o 'Name="AmsNetId"[^>]*>[0-9A-Fa-f]\{12\}<' "$f" 2>/dev/null | head -n1 | grep -o '[0-9A-Fa-f]\{12\}<')
        hex=${hex%<}
        if [[ ${#hex} -eq 12 ]]; then
            TC_AMS_NET_ID=$(printf '%d.%d.%d.%d.%d.%d' "0x${hex:0:2}" "0x${hex:2:2}" "0x${hex:4:2}" "0x${hex:6:2}" "0x${hex:8:2}" "0x${hex:10:2}")
            break
        fi
    done
    : "${TC_VERSION:=(unknown)}" "${TC_AMS_NET_ID:=(unknown)}"
}

# Installed TwinCAT runtime (XAR) and TF2000 HMI Server versions, into the
# associative array named $1. VERSION_KEYS holds the key order.
VERSION_KEYS=(TwinCAT_XAR TF2000_HMI_Server)
get_installed_versions() {
    local -n _giv=$1
    _giv[TwinCAT_XAR]=$(package_version "${XAR_PACKAGES[@]}")
    _giv[TF2000_HMI_Server]=$(package_version "${HMI_PACKAGES[@]}")
}

write_version_file() {   # path versions_assoc_name
    local -n _wvf=$2
    local k
    {
        echo "ComputerName=$(uname -n)"
        printf 'CreatedLocal=%(%Y-%m-%d %H:%M:%S)T\n' -1
        for k in "${VERSION_KEYS[@]}"; do echo "Version.$k=${_wvf[$k]}"; done
    } > "$1"
}

# Reads the Version.* entries of a versions.txt into the associative array named $2.
read_version_file() {   # path versions_assoc_name
    local -n _rvf=$2
    local line found=0
    [[ -f $1 ]] || { log_error "Version file not found: $1"; return 1; }
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        [[ $line == Version.*=* ]] || continue
        line=${line#Version.}
        _rvf[${line%%=*}]=${line#*=}
        found=1
    done < "$1"
    (( found )) || { log_error "Version file '$1' has no Version entries."; return 1; }
}

# Compares expected (package) versions with actual (this machine). Sets VERSION_PROBLEMS.
compare_versions() {   # expected_assoc_name actual_assoc_name
    local -n _cv_want=$1 _cv_have=$2
    local name want have
    VERSION_PROBLEMS=()
    for name in "${!_cv_want[@]}"; do
        want=$(format_version "${_cv_want[$name]}")
        have=$(format_version "${_cv_have[$name]}")
        if [[ -z $want ]]; then VERSION_PROBLEMS+=("$name: not recorded in the package")
        elif [[ -z $have ]]; then VERSION_PROBLEMS+=("$name: package has $want but the installed version could not be read on this machine")
        elif [[ $want != "$have" ]]; then VERSION_PROBLEMS+=("$name: package $want, this machine $have"); fi
    done
}

# -----------------------------------------------------------------------------
#  ADS state control (through ADS_TOOL, e.g. Beckhoff adstool)
# -----------------------------------------------------------------------------

# Sets TC_STATE to the TwinCAT system state name (Run, Config, ...).
get_twincat_state() {
    local out
    out=$(timeout 10 "${ADS_TOOL[@]}" state 2>/dev/null) || return 1
    [[ $out =~ ([0-9]+) ]] || return 1
    local n=$(( 10#${BASH_REMATCH[1]} ))
    TC_STATE=${ADS_STATE_NAMES[n]:-$n}
}

initialize_ads() {
    (( ADS_READY )) && return 0
    if ! command -v -- "${ADS_TOOL[0]}" >/dev/null 2>&1; then
        log_error "ADS tool '${ADS_TOOL[0]}' not found. Set ADS_TOOL in Config.sh."; return 1
    fi
    if ! get_twincat_state; then
        log_error "Could not read the TwinCAT state with '${ADS_TOOL[*]} state'. Check TwinCAT is installed and its system service is running."
        return 1
    fi
    log "ADS: using '${ADS_TOOL[*]}' (TwinCAT state: $TC_STATE)"
    ADS_READY=1
}

# Puts TwinCAT into Config or Run mode and waits until it gets there.
set_twincat_mode() {   # Config|Run timeout_sec
    local mode=$1 timeout=${2:-30} req out t0 last_error='' requests
    initialize_ads || return 1
    get_twincat_state || TC_STATE=unreachable
    [[ $TC_STATE == "$mode" ]] && { log "TwinCAT already in $mode mode"; return 0; }
    log_step "Switching TwinCAT from $TC_STATE to $mode mode (ADS)..."

    # System service state requests: Config <- Reconfig (16), Run <- Reset (2).
    # The second entry is only a fallback in case the first is rejected.
    if [[ $mode == Config ]]; then requests=(16 15); else requests=(2 5); fi
    for req in "${requests[@]}"; do
        if ! out=$(timeout 10 "${ADS_TOOL[@]}" state "$req" 2>&1); then
            last_error=$out
            log "ADS request '${ADS_STATE_NAMES[req]}' not accepted: $out"
        fi
        t0=$SECONDS
        while (( SECONDS - t0 < timeout )); do
            sleep 0.25
            get_twincat_state || TC_STATE=unreachable   # ADS drops briefly while switching
            if [[ $TC_STATE == "$mode" ]]; then
                log_ok "TwinCAT is in $mode mode (took $(format_elapsed $(( SECONDS - t0 ))))"; return 0
            fi
            progress_due && progress_line "Waiting for TwinCAT $mode mode ...  state: $TC_STATE  $(( SECONDS - t0 ))/$timeout s"
        done
    done
    clear_progress
    log_error "TwinCAT did not reach $mode mode within the timeout (state: $TC_STATE). $last_error"
    return 1
}

# -----------------------------------------------------------------------------
#  systemd services
# -----------------------------------------------------------------------------

# Waits for a unit to be active (Want=active) or stopped (Want=inactive).
wait_service_state() {   # name active|inactive timeout_sec
    local name=$1 want=$2 timeout=$3 now t0=$SECONDS
    while true; do
        now=$(systemctl is-active -- "$name" 2>/dev/null)
        [[ $want == inactive && $now == failed ]] && now=inactive
        if [[ $now == "$want" ]]; then clear_progress; return 0; fi
        if (( SECONDS - t0 >= timeout )); then clear_progress; return 1; fi
        progress_due && progress_line "Waiting for service '$name' to be $want ...  now: $now  $(( SECONDS - t0 ))/$timeout s"
        sleep 0.25
    done
}

# Stops a service (and its running dependent services). Sets SERVICES_TO_START
# to the services to start again later.
stop_service_with_timeout() {   # name timeout_sec
    local name=$1 timeout=${2:-60}
    SERVICES_TO_START=()
    if [[ $(systemctl show -p LoadState --value -- "$name" 2>/dev/null) != loaded ]]; then
        log_warn "Service '$name' is not installed - skipping"; return 0
    fi
    if ! systemctl is-active --quiet -- "$name"; then log "Service '$name' already stopped"; return 0; fi

    local u
    SERVICES_TO_START=("$name")
    while read -r u; do
        [[ $u == *.service ]] && systemctl is-active --quiet -- "$u" && SERVICES_TO_START+=("$u")
    done < <(systemctl list-dependencies --reverse --plain --no-legend -- "$name" 2>/dev/null | tail -n +2 | awk '{ print $1 }')

    log_step "Stopping service '$name'..."
    systemctl stop --no-block -- "$name" || { log_error "Could not stop service '$name'."; return 1; }
    if ! wait_service_state "$name" inactive "$timeout"; then
        log_warn "Service '$name' did not stop within $timeout s - killing it"
        systemctl kill --signal=SIGKILL -- "$name" 2>/dev/null
        wait_service_state "$name" inactive 15 || { log_error "Service '$name' could not be stopped."; return 1; }
    fi
    log_ok "Service '$name' stopped"
}

start_service_safe() {   # name timeout_sec
    local name=$1 timeout=${2:-60}
    if ! systemctl is-active --quiet -- "$name"; then
        log_step "Starting service '$name'..."
        if ! systemctl start --no-block -- "$name" || ! wait_service_state "$name" active "$timeout"; then
            log_warn "Could not start service '$name' within $timeout s"; return 1
        fi
    fi
    log_ok "Service '$name' running"
}
