#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly INSTALLER_VERSION="2.4.1"
readonly XRAY_VERSION="${XRAY_VERSION:-26.3.27}"
readonly TRUSTED_IP="${TRUSTED_IP:-91.107.178.21}"
readonly MARZBAN_NODE_DIR="${MARZBAN_NODE_DIR:-${HOME}/Marzban-node}"
readonly MARZBAN_DATA_DIR="${MARZBAN_DATA_DIR:-/var/lib/marzban}"
readonly MARZBAN_NODE_DATA_DIR="${MARZBAN_NODE_DATA_DIR:-/var/lib/marzban-node}"
readonly XRAY_DIR="${MARZBAN_DATA_DIR}/xray-core"
readonly ASSETS_DIR="${MARZBAN_DATA_DIR}/assets"
readonly CLIENT_CERT_URL="https://github.com/KAJOOSH/node/raw/refs/heads/main/certificate/ssl_client_cert.pem"
readonly CLIENT_CERT_FILE="${MARZBAN_NODE_DATA_DIR}/ssl_client_cert.pem"
readonly STATE_DIR="${INSTALLER_STATE_DIR:-/var/lib/marzban-node-installer}"
readonly STATE_FILE="${STATE_DIR}/completed.stages"
readonly SETTINGS_FILE="${STATE_DIR}/settings.conf"
readonly LAST_ERROR_FILE="${STATE_DIR}/last-error.txt"
readonly LOG_DIR="${STATE_DIR}/logs"
readonly RUN_LOCK_FILE="${INSTALLER_RUN_LOCK_FILE:-/run/lock/marzban-node-installer.lock}"
readonly OS_RELEASE_FILE="${INSTALLER_OS_RELEASE_FILE:-/etc/os-release}"
readonly APT_LOCK_TIMEOUT="${APT_LOCK_TIMEOUT:-1800}"
readonly APT_LOCK_POLL="${APT_LOCK_POLL:-3}"
readonly APT_RETRIES="${APT_RETRIES:-3}"
readonly UI_LOG_LINES="${UI_LOG_LINES:-12}"

CURRENT_STAGE_KEY=""
CURRENT_STAGE_TITLE="Pre-flight"
CURRENT_STAGE_NUMBER=0
TOTAL_STAGES=0
COMPLETED_COUNT=0
STAGE_PROGRESS=0
CURRENT_ACTION="Preparing installer"
PROGRESS_DETAIL=""
RUN_STARTED_AT="$(date +%s)"
STAGE_STARTED_AT="$(date +%s)"
RUN_LOG=""
LAST_COMMAND_LOG=""
LAST_COMMAND_TEXT=""
LAST_COMMAND_RC=0
ACTIVE_OUTPUT_FILE=""
STATE_READY=false
UI_ACTIVE=false
ERROR_REPORTED=false
STATUS_ONLY=false
RESTART_REQUESTED=false
AUTO_MODE=true
SETUP_SECURITY=false
INSTALL_SPEEDTEST=true
DOCKER_REPO_FORCE_IPV4=false
SPINNER_INDEX=0
cleanup_files=()

if [[ -t 1 ]]; then
    C_RESET='\033[0m'
    C_RED='\033[0;31m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'
    C_CYAN='\033[0;36m'
    C_MAGENTA='\033[0;35m'
    C_BOLD='\033[1m'
    C_DIM='\033[2m'
else
    C_RESET=''
    C_RED=''
    C_GREEN=''
    C_YELLOW=''
    C_CYAN=''
    C_MAGENTA=''
    C_BOLD=''
    C_DIM=''
fi

format_duration() {
    local total="${1:-0}" h m s
    if (( total < 0 )); then total=0; fi
    h=$(( total / 3600 ))
    m=$(( (total % 3600) / 60 ))
    s=$(( total % 60 ))
    if (( h > 0 )); then
        printf '%02d:%02d:%02d' "$h" "$m" "$s"
    else
        printf '%02d:%02d' "$m" "$s"
    fi
}

terminal_width() {
    local cols=100
    if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
        cols="$(tput cols 2>/dev/null || printf '100')"
    fi
    if [[ ! "$cols" =~ ^[0-9]+$ ]]; then cols=100; fi
    if (( cols < 78 )); then cols=78; fi
    if (( cols > 140 )); then cols=140; fi
    printf '%d' "$cols"
}

terminal_height() {
    local rows=30
    if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
        rows="$(tput lines 2>/dev/null || printf '30')"
    fi
    if [[ ! "$rows" =~ ^[0-9]+$ ]]; then rows=30; fi
    if (( rows < 24 )); then rows=24; fi
    printf '%d' "$rows"
}

repeat_char() {
    local char="$1" count="$2" out
    printf -v out '%*s' "$count" ''
    out="${out// /$char}"
    printf '%s' "$out"
}

truncate_line() {
    local text="$1" width="$2"
    text="${text//$'\r'/}"
    text="${text//$'\t'/ }"
    if (( ${#text} > width )); then
        printf '%s…' "${text:0:width-1}"
    else
        printf '%s' "$text"
    fi
}

progress_percent() {
    local value=0
    if (( TOTAL_STAGES > 0 )); then
        if (( CURRENT_STAGE_NUMBER <= 0 )); then
            value=$(( COMPLETED_COUNT * 100 / TOTAL_STAGES ))
        else
            value=$(( ((CURRENT_STAGE_NUMBER - 1) * 100 + STAGE_PROGRESS) / TOTAL_STAGES ))
        fi
    fi
    if (( value < 0 )); then value=0; fi
    if (( value > 100 )); then value=100; fi
    printf '%d' "$value"
}

make_progress_bar() {
    local percent="$1" width="$2" filled empty left right
    filled=$(( percent * width / 100 ))
    empty=$(( width - filled ))
    printf -v left '%*s' "$filled" ''
    printf -v right '%*s' "$empty" ''
    left="${left// /#}"
    right="${right// /-}"
    printf '%s%s' "$left" "$right"
}

internal_log() {
    local level="$1"
    shift
    [[ -n "${RUN_LOG:-}" ]] || return 0
    printf '[%s] %s - %s\n' "$level" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$RUN_LOG" 2>/dev/null || true
}

log_info() { internal_log INFO "$*"; }
log_warn() { internal_log WARN "$*"; }
log_success() { internal_log OK "$*"; }

ui_init() {
    [[ -t 1 ]] || return 0
    UI_ACTIVE=true
    printf '\033[?1049h\033[?25l\033[2J\033[H'
}

ui_shutdown() {
    if [[ "$UI_ACTIVE" == true ]]; then
        printf '\033[?25h\033[?1049l' || true
        UI_ACTIVE=false
    fi
}

ui_log_source() {
    if [[ -n "${ACTIVE_OUTPUT_FILE:-}" && -f "$ACTIVE_OUTPUT_FILE" ]]; then
        printf '%s' "$ACTIVE_OUTPUT_FILE"
    else
        printf '%s' "${RUN_LOG:-}"
    fi
}

stage_is_marked() {
    local key="$1"
    grep -Fxq -- "$key" "$STATE_FILE" 2>/dev/null
}

ui_refresh() {
    local status="${1:-RUNNING}" now elapsed stage_elapsed pct width rows inner bar_width bar spinner frames='|/-\\'
    local source log_lines line i j task_col marker1 marker2 text1 text2 start_pad
    now="$(date +%s)"
    elapsed=$(( now - RUN_STARTED_AT ))
    stage_elapsed=$(( now - STAGE_STARTED_AT ))
    pct="$(progress_percent)"
    if [[ ! -t 1 || "$UI_ACTIVE" != true ]]; then
        case "$status" in
            DONE|FAILED|COMPLETE) printf '[%3d%%] %-8s %s\n' "$pct" "$status" "$CURRENT_STAGE_TITLE" ;;
        esac
        return 0
    fi
    width="$(terminal_width)"
    rows="$(terminal_height)"
    inner=$(( width - 4 ))
    bar_width=$(( width - 34 ))
    if (( bar_width < 20 )); then bar_width=20; fi
    bar="$(make_progress_bar "$pct" "$bar_width")"
    spinner="${frames:SPINNER_INDEX%4:1}"
    SPINNER_INDEX=$(( SPINNER_INDEX + 1 ))
    log_lines=$(( rows - 18 ))
    if (( log_lines < 5 )); then log_lines=5; fi
    if (( log_lines > UI_LOG_LINES )); then log_lines="$UI_LOG_LINES"; fi
    printf '\033[H'
    printf '%b+%s+%b\n' "$C_CYAN" "$(repeat_char '-' "$((width-2))")" "$C_RESET"
    printf '%b|%b %b%-*s%b %b|%b\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$((inner-1))" "Marzban Node Installer v${INSTALLER_VERSION}" "$C_RESET" "$C_CYAN" "$C_RESET"
    printf '%b+%s+%b\n' "$C_CYAN" "$(repeat_char '-' "$((width-2))")" "$C_RESET"
    printf '%b|%b Overall  %b[%s]%b %3d%% %s  Elapsed %-8s%b|%b\n' "$C_CYAN" "$C_RESET" "$C_MAGENTA" "$bar" "$C_RESET" "$pct" "$spinner" "$(format_duration "$elapsed")" "$C_CYAN" "$C_RESET"
    printf '%b|%b Stage    %02d/%02d  %-*s%b|%b\n' "$C_CYAN" "$C_RESET" "$CURRENT_STAGE_NUMBER" "$TOTAL_STAGES" "$((inner-16))" "$(truncate_line "$CURRENT_STAGE_TITLE" "$((inner-16))")" "$C_CYAN" "$C_RESET"
    printf '%b|%b Action   %-*s%b|%b\n' "$C_CYAN" "$C_RESET" "$((inner-9))" "$(truncate_line "$CURRENT_ACTION" "$((inner-9))")" "$C_CYAN" "$C_RESET"
    printf '%b|%b Status   %-10s Stage %-8s %-*s%b|%b\n' "$C_CYAN" "$C_RESET" "$status" "$(format_duration "$stage_elapsed")" "$((inner-32))" "$(truncate_line "${PROGRESS_DETAIL:-}" "$((inner-32))")" "$C_CYAN" "$C_RESET"
    printf '%b+%s+%b\n' "$C_CYAN" "$(repeat_char '-' "$((width-2))")" "$C_RESET"
    task_col=$(( (inner - 3) / 2 ))
    for (( i=0; i<5; i++ )); do
        j=$(( i + 5 ))
        if stage_is_marked "${STAGE_KEYS[$i]}" 2>/dev/null; then marker1="${C_GREEN}✓${C_RESET}"; elif (( i + 1 == CURRENT_STAGE_NUMBER )); then marker1="${C_YELLOW}▶${C_RESET}"; else marker1="${C_DIM}○${C_RESET}"; fi
        text1="$(printf '%02d. %s' "$((i+1))" "${STAGE_TITLES[$i]}")"
        if (( j < TOTAL_STAGES )); then
            if stage_is_marked "${STAGE_KEYS[$j]}" 2>/dev/null; then marker2="${C_GREEN}✓${C_RESET}"; elif (( j + 1 == CURRENT_STAGE_NUMBER )); then marker2="${C_YELLOW}▶${C_RESET}"; else marker2="${C_DIM}○${C_RESET}"; fi
            text2="$(printf '%02d. %s' "$((j+1))" "${STAGE_TITLES[$j]}")"
        else
            marker2=' '
            text2=''
        fi
        printf '%b|%b %b %-*s | %b %-*s%b|%b\n' "$C_CYAN" "$C_RESET" "$marker1" "$((task_col-3))" "$(truncate_line "$text1" "$((task_col-3))")" "$marker2" "$((task_col-3))" "$(truncate_line "$text2" "$((task_col-3))")" "$C_CYAN" "$C_RESET"
    done
    printf '%b+%s+%b\n' "$C_CYAN" "$(repeat_char '-' "$((width-2))")" "$C_RESET"
    printf '%b|%b %bLive log%b%-*s%b|%b\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET" "$((inner-9))" '' "$C_CYAN" "$C_RESET"
    source="$(ui_log_source)"
    __ui_lines=()
    if [[ -n "$source" && -f "$source" ]]; then
        mapfile -t __ui_lines < <(tail -n "$log_lines" "$source" 2>/dev/null || true)
    fi
    start_pad=$(( log_lines - ${#__ui_lines[@]} ))
    for (( i=0; i<start_pad; i++ )); do
        printf '%b|%b %-*s %b|%b\n' "$C_CYAN" "$C_RESET" "$((inner-1))" '' "$C_CYAN" "$C_RESET"
    done
    for line in "${__ui_lines[@]:-}"; do
        printf '%b|%b %-*s %b|%b\n' "$C_CYAN" "$C_RESET" "$((inner-1))" "$(truncate_line "$line" "$((inner-1))")" "$C_CYAN" "$C_RESET"
    done
    printf '%b+%s+%b' "$C_CYAN" "$(repeat_char '-' "$((width-2))")" "$C_RESET"
}

set_stage_progress() {
    local value="${1:-0}"
    if (( value < 0 )); then value=0; fi
    if (( value > 100 )); then value=100; fi
    STAGE_PROGRESS="$value"
    ui_refresh RUNNING
}

set_progress_detail() {
    PROGRESS_DETAIL="${1:-}"
}

quote_command_string() {
    local arg out=''
    for arg in "$@"; do
        printf -v arg '%q' "$arg"
        out+="${arg} "
    done
    printf '%s' "${out% }"
}

cleanup() {
    local f
    ui_shutdown || true
    for f in "${cleanup_files[@]:-}"; do
        [[ -e "$f" ]] && rm -rf -- "$f" || true
    done
}

trap cleanup EXIT

save_last_error() {
    local message="$1" tmp
    [[ "$STATE_READY" == true ]] || return 0
    tmp="$(mktemp)"
    cleanup_files+=("$tmp")
    {
        printf 'time=%s\n' "$(date -Is)"
        printf 'installer_version=%s\n' "$INSTALLER_VERSION"
        printf 'stage=%s\n' "${CURRENT_STAGE_KEY:-preflight}"
        printf 'stage_number=%s/%s\n' "${CURRENT_STAGE_NUMBER:-0}" "${TOTAL_STAGES:-0}"
        printf 'stage_title=%s\n' "$CURRENT_STAGE_TITLE"
        printf 'exit_code=%s\n' "${LAST_COMMAND_RC:-1}"
        printf 'message=%s\n' "$message"
        [[ -n "${LAST_COMMAND_TEXT:-}" ]] && printf 'command=%s\n' "$LAST_COMMAND_TEXT"
        [[ -n "${RUN_LOG:-}" ]] && printf 'run_log=%s\n' "$RUN_LOG"
        if [[ -n "${LAST_COMMAND_LOG:-}" && -s "$LAST_COMMAND_LOG" ]]; then
            printf '\ncommand_output_tail:\n'
            tail -n 80 "$LAST_COMMAND_LOG" || true
        fi
    } > "$tmp"
    "${SUDO[@]}" install -m 0644 "$tmp" "$LAST_ERROR_FILE" >/dev/null 2>&1 || true
}

print_failure_report() {
    local message="$1" rc="${2:-1}"
    ui_shutdown || true
    printf '\n%b============================================================%b\n' "$C_RED" "$C_RESET" >&2
    printf '%bINSTALLATION FAILED%b\n' "$C_BOLD$C_RED" "$C_RESET" >&2
    printf '%b============================================================%b\n' "$C_RED" "$C_RESET" >&2
    printf 'Stage: %s/%s - %s\n' "$CURRENT_STAGE_NUMBER" "$TOTAL_STAGES" "$CURRENT_STAGE_TITLE" >&2
    printf 'Exit code: %s\n' "$rc" >&2
    printf 'Reason: %s\n' "$message" >&2
    if [[ -n "${LAST_COMMAND_TEXT:-}" ]]; then
        printf 'Command: %s\n' "$LAST_COMMAND_TEXT" >&2
    fi
    if [[ -n "${LAST_COMMAND_LOG:-}" && -s "$LAST_COMMAND_LOG" ]]; then
        printf '\n%bLast command output:%b\n' "$C_YELLOW" "$C_RESET" >&2
        tail -n 80 "$LAST_COMMAND_LOG" >&2 || true
    fi
    if [[ -n "${RUN_LOG:-}" ]]; then
        printf '\nFull log: %s\n' "$RUN_LOG" >&2
    fi
    if [[ "$STATE_READY" == true ]]; then
        printf 'Last error: %s\n' "$LAST_ERROR_FILE" >&2
        printf 'Resume: bash %q\n' "$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")" >&2
    fi
    printf '%b============================================================%b\n\n' "$C_RED" "$C_RESET" >&2
}

fatal() {
    local message="$*" rc="${LAST_COMMAND_RC:-1}"
    if (( rc == 0 )); then rc=1; fi
    save_last_error "$message"
    print_failure_report "$message" "$rc"
    ERROR_REPORTED=true
    trap - ERR
    exit "$rc"
}

on_error() {
    local rc="$1" line="$2" command="$3" failed_command message
    if [[ "$ERROR_REPORTED" == true ]]; then exit "$rc"; fi
    ERROR_REPORTED=true
    trap - ERR
    set +e
    LAST_COMMAND_RC="$rc"
    failed_command="${LAST_COMMAND_TEXT:-$command}"
    message="Stage ${CURRENT_STAGE_NUMBER:-0}/${TOTAL_STAGES:-0} failed at line ${line}: ${failed_command}"
    save_last_error "$message"
    print_failure_report "$message" "$rc"
    exit "$rc"
}

trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

run_cmd() {
    local rc pid tmp command_text
    tmp="$(mktemp)"
    cleanup_files+=("$tmp")
    command_text="$(quote_command_string "$@")"
    LAST_COMMAND_TEXT="$command_text"
    LAST_COMMAND_RC=0
    LAST_COMMAND_LOG=""
    CURRENT_ACTION="$command_text"
    ACTIVE_OUTPUT_FILE="$tmp"
    internal_log CMD "$command_text"
    "$@" >"$tmp" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        ui_refresh RUNNING || true
        sleep 0.4
    done
    if wait "$pid"; then rc=0; else rc=$?; fi
    if [[ -n "${RUN_LOG:-}" ]]; then
        {
            printf '\n[COMMAND] %s\n' "$command_text"
            cat "$tmp"
        } >> "$RUN_LOG" 2>/dev/null || true
    fi
    if (( rc == 0 )); then
        ACTIVE_OUTPUT_FILE=""
        LAST_COMMAND_TEXT=""
        LAST_COMMAND_LOG=""
        LAST_COMMAND_RC=0
        rm -f -- "$tmp"
        ui_refresh RUNNING || true
        return 0
    fi
    LAST_COMMAND_RC="$rc"
    LAST_COMMAND_LOG="$tmp"
    ACTIVE_OUTPUT_FILE="$tmp"
    internal_log ERROR "Command failed with exit $rc: $command_text"
    ui_refresh FAILED || true
    return "$rc"
}

usage() {
    cat <<EOF_USAGE
Marzban Node Installer v${INSTALLER_VERSION}
Usage:
  bash $0
  bash $0 --restart
  bash $0 --status
  bash $0 --help
EOF_USAGE
}

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --restart) RESTART_REQUESTED=true ;;
            --status) STATUS_ONLY=true ;;
            --help|-h) usage; exit 0 ;;
            *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
        esac
        shift
    done
}

parse_args "$@"

if (( EUID == 0 )); then
    SUDO=()
else
    command -v sudo >/dev/null 2>&1 || { printf 'sudo is required.\n' >&2; exit 1; }
    SUDO=(sudo)
    "${SUDO[@]}" -v
fi

command -v flock >/dev/null 2>&1 || { printf 'flock is required.\n' >&2; exit 1; }
"${SUDO[@]}" touch "$RUN_LOCK_FILE"
"${SUDO[@]}" chmod 0644 "$RUN_LOCK_FILE"
exec 9<"$RUN_LOCK_FILE"
if ! flock -n 9; then
    printf 'Another copy of this installer is already running.\n' >&2
    exit 1
fi

[[ -r "$OS_RELEASE_FILE" ]] || { printf '%s not found.\n' "$OS_RELEASE_FILE" >&2; exit 1; }
source "$OS_RELEASE_FILE"
[[ "${ID:-}" == ubuntu ]] || { printf 'Ubuntu is required. Detected: %s\n' "${PRETTY_NAME:-unknown}" >&2; exit 1; }
case "$(uname -m)" in
    x86_64|amd64) XRAY_ARCHIVE="Xray-linux-64.zip" ;;
    aarch64|arm64) XRAY_ARCHIVE="Xray-linux-arm64-v8a.zip" ;;
    *) printf 'Unsupported CPU architecture: %s\n' "$(uname -m)" >&2; exit 1 ;;
esac
[[ "$APT_LOCK_TIMEOUT" =~ ^[0-9]+$ ]] || { printf 'APT_LOCK_TIMEOUT must be an integer.\n' >&2; exit 1; }
[[ "$APT_LOCK_POLL" =~ ^[1-9][0-9]*$ ]] || { printf 'APT_LOCK_POLL must be positive.\n' >&2; exit 1; }
[[ "$APT_RETRIES" =~ ^[1-9][0-9]*$ ]] || { printf 'APT_RETRIES must be positive.\n' >&2; exit 1; }

init_state_storage() {
    "${SUDO[@]}" mkdir -p "$STATE_DIR" "$LOG_DIR"
    "${SUDO[@]}" touch "$STATE_FILE"
    "${SUDO[@]}" chmod 0755 "$STATE_DIR" "$LOG_DIR"
    "${SUDO[@]}" chmod 0644 "$STATE_FILE"
    RUN_LOG="$LOG_DIR/run-$(date '+%Y%m%d-%H%M%S')-$$.log"
    "${SUDO[@]}" touch "$RUN_LOG"
    if (( EUID != 0 )); then
        "${SUDO[@]}" chown "$(id -u):$(id -g)" "$RUN_LOG"
    fi
    chmod 0600 "$RUN_LOG" 2>/dev/null || "${SUDO[@]}" chmod 0600 "$RUN_LOG"
    STATE_READY=true
    internal_log INFO "Marzban Node Installer v$INSTALLER_VERSION"
}

mark_stage_done() {
    local key="$1"
    if stage_is_marked "$key"; then return 0; fi
    printf '%s\n' "$key" | "${SUDO[@]}" tee -a "$STATE_FILE" >/dev/null
}

rewrite_state_prefix() {
    local keep_count="$1" tmp i
    tmp="$(mktemp)"
    cleanup_files+=("$tmp")
    : > "$tmp"
    for (( i=0; i<keep_count; i++ )); do
        if stage_is_marked "${STAGE_KEYS[$i]}"; then
            printf '%s\n' "${STAGE_KEYS[$i]}" >> "$tmp"
        fi
    done
    "${SUDO[@]}" install -m 0644 "$tmp" "$STATE_FILE"
}

save_settings() {
    local tmp
    tmp="$(mktemp)"
    cleanup_files+=("$tmp")
    {
        printf 'INSTALLER_VERSION=%s\n' "$INSTALLER_VERSION"
        printf 'AUTO_MODE=%s\n' "$AUTO_MODE"
        printf 'SETUP_SECURITY=%s\n' "$SETUP_SECURITY"
        printf 'INSTALL_SPEEDTEST=%s\n' "$INSTALL_SPEEDTEST"
    } > "$tmp"
    "${SUDO[@]}" install -m 0644 "$tmp" "$SETTINGS_FILE"
}

clear_installer_state() {
    "${SUDO[@]}" rm -f -- "$STATE_FILE" "$SETTINGS_FILE" "$LAST_ERROR_FILE"
    "${SUDO[@]}" touch "$STATE_FILE"
    "${SUDO[@]}" chmod 0644 "$STATE_FILE"
}

init_state_storage
if [[ "$RESTART_REQUESTED" == true ]]; then clear_installer_state; fi
AUTO_MODE=true
SETUP_SECURITY=false
INSTALL_SPEEDTEST=true
save_settings

apt_env=(env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a UCF_FORCE_CONFFOLD=1)
apt_yes=(-y)
apt_dpkg_opts=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

get_package_manager_lock_holders() {
    local locks=(/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock) lock
    if command -v fuser >/dev/null 2>&1; then
        {
            for lock in "${locks[@]}"; do
                [[ -e "$lock" ]] || continue
                "${SUDO[@]}" fuser "$lock" 2>/dev/null || true
            done
        } | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -nu || true
    else
        "${SUDO[@]}" ps -eo pid=,comm=,args= | awk -v self="$$" '{ pid=$1; comm=$2; if (pid == self || comm == "awk" || comm == "ps" || comm == "sudo") next; if (comm ~ /^(apt|apt-get|dpkg|dpkg-deb|unattended-upgr|packagekitd)$/ || $0 ~ /[\/]usr[\/]lib[\/]apt[\/]apt\.systemd\.daily/ || $0 ~ /[\/]usr[\/]bin[\/]unattended-upgrade/) print pid; }' | sort -nu || true
    fi
}

wait_for_package_manager() {
    local start now elapsed holders holder_text
    start="$(date +%s)"
    while true; do
        holders="$(get_package_manager_lock_holders)"
        if [[ -z "$holders" ]]; then
            set_progress_detail ""
            return 0
        fi
        now="$(date +%s)"
        elapsed=$(( now - start ))
        holder_text="$(printf '%s' "$holders" | tr '\n' ',' | sed 's/,$//')"
        if (( elapsed >= APT_LOCK_TIMEOUT )); then
            LAST_COMMAND_TEXT="Waiting for apt/dpkg lock held by PID(s): $holder_text"
            LAST_COMMAND_RC=1
            return 1
        fi
        set_progress_detail "Waiting for APT lock: PID ${holder_text}, ${elapsed}s"
        CURRENT_ACTION="Waiting for apt/dpkg"
        ui_refresh WAITING || true
        sleep "$APT_LOCK_POLL"
    done
}

repair_dpkg_if_needed() {
    local audit
    audit="$("${SUDO[@]}" dpkg --audit 2>&1 || true)"
    [[ -n "$audit" ]] || return 0
    wait_for_package_manager
    run_cmd "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a UCF_FORCE_CONFFOLD=1 dpkg --force-confdef --force-confold --configure -a
}

apt_exec() {
    local attempt rc=1
    for (( attempt=1; attempt<=APT_RETRIES; attempt++ )); do
        wait_for_package_manager || return 1
        if run_cmd "${SUDO[@]}" "${apt_env[@]}" apt-get -o "DPkg::Lock::Timeout=${APT_LOCK_TIMEOUT}" -o Acquire::Retries=4 "$@"; then
            return 0
        else
            rc=$?
        fi
        if (( attempt < APT_RETRIES )); then
            sleep 2
            wait_for_package_manager || return 1
            repair_dpkg_if_needed || true
        fi
    done
    return "$rc"
}

apt_update() { apt_exec update; }
apt_install() { apt_exec install "${apt_yes[@]}" "${apt_dpkg_opts[@]}" "$@"; }
apt_remove() { apt_exec remove "${apt_yes[@]}" "${apt_dpkg_opts[@]}" "$@"; }

download_atomic() {
    local url="$1" destination="$2" mode="${3:-0644}" tmp
    tmp="$(mktemp)"
    cleanup_files+=("$tmp")
    run_cmd curl -fsSL --retry 4 --retry-delay 2 --connect-timeout 15 --max-time 300 -o "$tmp" "$url"
    [[ -s "$tmp" ]] || fatal "Downloaded file is empty: $url"
    run_cmd "${SUDO[@]}" install -m "$mode" "$tmp" "$destination"
    rm -f -- "$tmp"
}

BASE_PACKAGES=(ca-certificates curl git wget unzip gnupg lsb-release)

install_base_dependencies() {
    CURRENT_ACTION="Updating Ubuntu package index"; set_stage_progress 15
    apt_update
    CURRENT_ACTION="Installing base packages"; set_stage_progress 55
    apt_install "${BASE_PACKAGES[@]}"
    set_stage_progress 88
}

verify_base_dependencies() {
    local pkg
    for pkg in "${BASE_PACKAGES[@]}"; do
        dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'ok installed' || return 1
    done
    return 0
}

verify_docker() {
    command -v docker >/dev/null 2>&1 || return 1
    "${SUDO[@]}" docker compose version >/dev/null 2>&1 || return 1
    "${SUDO[@]}" docker info >/dev/null 2>&1 || return 1
    return 0
}

wait_for_docker() {
    local attempt
    for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        if verify_docker; then return 0; fi
        CURRENT_ACTION="Waiting for Docker daemon (${attempt}/15)"
        ui_refresh WAITING || true
        sleep 1
    done
    return 1
}

installed_packages_from_list() {
    local pkg
    for pkg in "$@"; do
        if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'ok installed'; then
            printf '%s\n' "$pkg"
        fi
    done
}

remove_docker_distro_conflicts() {
    local candidates=(docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc) installed=()
    mapfile -t installed < <(installed_packages_from_list "${candidates[@]}")
    if (( ${#installed[@]} > 0 )); then
        CURRENT_ACTION="Removing Ubuntu Docker packages that conflict with Docker CE"; set_stage_progress 38
        apt_remove "${installed[@]}"
    fi
}

remove_docker_ce_conflicts() {
    local candidates=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras) installed=()
    mapfile -t installed < <(installed_packages_from_list "${candidates[@]}")
    if (( ${#installed[@]} > 0 )); then
        CURRENT_ACTION="Removing Docker CE packages before Ubuntu fallback"; set_stage_progress 42
        apt_remove "${installed[@]}"
    fi
}

clear_docker_official_repository() {
    run_cmd "${SUDO[@]}" rm -f /etc/apt/sources.list.d/docker.sources /etc/apt/sources.list.d/docker.list
}

enable_ubuntu_universe_if_needed() {
    if apt-cache show docker.io >/dev/null 2>&1 && apt-cache show docker-compose-v2 >/dev/null 2>&1; then
        return 0
    fi
    CURRENT_ACTION="Enabling Ubuntu universe repository"; set_stage_progress 52
    if ! command -v add-apt-repository >/dev/null 2>&1; then
        apt_install software-properties-common
    fi
    run_cmd "${SUDO[@]}" add-apt-repository -y universe
    apt_update
    apt-cache show docker.io >/dev/null 2>&1 || fatal "Ubuntu package docker.io is not available for this release."
    apt-cache show docker-compose-v2 >/dev/null 2>&1 || fatal "Ubuntu package docker-compose-v2 is not available for this release."
}

install_docker_from_ubuntu() {
    CURRENT_ACTION="Switching to Ubuntu Docker packages"; set_stage_progress 40
    clear_docker_official_repository
    remove_docker_ce_conflicts
    CURRENT_ACTION="Refreshing Ubuntu package index"; set_stage_progress 48
    apt_update
    enable_ubuntu_universe_if_needed
    CURRENT_ACTION="Installing Docker and Compose from Ubuntu"; set_stage_progress 68
    apt_install docker.io docker-compose-v2
    CURRENT_ACTION="Enabling Docker service"; set_stage_progress 86
    run_cmd "${SUDO[@]}" systemctl enable --now docker
    CURRENT_ACTION="Verifying Ubuntu Docker packages"; set_stage_progress 92
    wait_for_docker || fatal "Ubuntu Docker packages were installed, but Docker or Compose is not usable."
    log_success "Docker Engine and Docker Compose are ready from Ubuntu repositories."
}

docker_repo_apt_update() {
    if [[ "$DOCKER_REPO_FORCE_IPV4" == true ]]; then
        apt_exec -o Acquire::ForceIPv4=true update
    else
        apt_update
    fi
}

docker_repo_apt_install() {
    if [[ "$DOCKER_REPO_FORCE_IPV4" == true ]]; then
        apt_exec -o Acquire::ForceIPv4=true install "${apt_yes[@]}" "${apt_dpkg_opts[@]}" "$@"
    else
        apt_install "$@"
    fi
}

install_docker_from_official_repo() {
    local codename="$1" arch="$2" key_tmp="$3" source_tmp="$4"
    CURRENT_ACTION="Preparing official Docker APT repository"; set_stage_progress 36
    remove_docker_distro_conflicts
    run_cmd "${SUDO[@]}" install -m 0755 -d /etc/apt/keyrings
    run_cmd "${SUDO[@]}" install -m 0644 "$key_tmp" /etc/apt/keyrings/docker.asc
    cat > "$source_tmp" <<EOF_DOCKER_SOURCE
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${codename}
Components: stable
Architectures: ${arch}
Signed-By: /etc/apt/keyrings/docker.asc
EOF_DOCKER_SOURCE
    run_cmd "${SUDO[@]}" install -m 0644 "$source_tmp" /etc/apt/sources.list.d/docker.sources
    CURRENT_ACTION="Refreshing Docker package index"; set_stage_progress 52
    if ! docker_repo_apt_update; then
        log_warn "Official Docker APT repository is not reachable. Falling back to Ubuntu packages."
        install_docker_from_ubuntu
        return 0
    fi
    CURRENT_ACTION="Installing Docker Engine and Compose plugin"; set_stage_progress 68
    if ! docker_repo_apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
        log_warn "Docker CE package installation failed. Falling back to Ubuntu packages."
        install_docker_from_ubuntu
        return 0
    fi
    CURRENT_ACTION="Enabling Docker service"; set_stage_progress 86
    run_cmd "${SUDO[@]}" systemctl enable --now docker
    CURRENT_ACTION="Verifying Docker daemon and Compose"; set_stage_progress 92
    if ! wait_for_docker; then
        log_warn "Docker CE verification failed. Falling back to Ubuntu packages."
        install_docker_from_ubuntu
        return 0
    fi
    log_success "Docker Engine and Docker Compose are ready from Docker's official repository."
}

install_docker() {
    local codename arch key_tmp source_tmp docker_key_url
    if verify_docker; then
        log_success "Docker Engine and Compose are already ready."
        return 0
    fi
    codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    [[ -n "$codename" ]] || fatal "Ubuntu codename could not be detected from /etc/os-release."
    arch="$(dpkg --print-architecture)"
    docker_key_url="${DOCKER_GPG_URL:-https://download.docker.com/linux/ubuntu/gpg}"
    key_tmp="$(mktemp)"
    source_tmp="$(mktemp)"
    cleanup_files+=("$key_tmp" "$source_tmp")
    CURRENT_ACTION="Checking official Docker repository access"; set_stage_progress 20
    DOCKER_REPO_FORCE_IPV4=false
    if run_cmd curl -fsSL --retry 2 --retry-delay 2 --connect-timeout 12 --max-time 60 "$docker_key_url" -o "$key_tmp"; then
        :
    else
        log_warn "Default route to Docker failed. Retrying over IPv4."
        : > "$key_tmp"
        CURRENT_ACTION="Retrying Docker repository over IPv4"; set_stage_progress 26
        if run_cmd curl -4 -fsSL --retry 2 --retry-delay 2 --connect-timeout 12 --max-time 60 "$docker_key_url" -o "$key_tmp"; then
            DOCKER_REPO_FORCE_IPV4=true
            log_warn "Docker repository works over IPv4; forcing IPv4 for Docker APT operations."
        fi
    fi
    if [[ -s "$key_tmp" ]] && grep -q -- 'BEGIN PGP PUBLIC KEY BLOCK' "$key_tmp"; then
        install_docker_from_official_repo "$codename" "$arch" "$key_tmp" "$source_tmp"
        return 0
    fi
    log_warn "Official Docker repository is blocked, unreachable, or returned an invalid key. Falling back to Ubuntu packages."
    LAST_COMMAND_TEXT=""
    LAST_COMMAND_LOG=""
    LAST_COMMAND_RC=0
    ACTIVE_OUTPUT_FILE=""
    install_docker_from_ubuntu
}

ufw_is_active() {
    command -v ufw >/dev/null 2>&1 && "${SUDO[@]}" ufw status 2>/dev/null | grep -q '^Status: active'
}

configure_security() {
    if ! command -v ufw >/dev/null 2>&1; then apt_install ufw; fi
    run_cmd "${SUDO[@]}" ufw default deny incoming
    run_cmd "${SUDO[@]}" ufw default allow outgoing
    run_cmd "${SUDO[@]}" ufw allow from "$TRUSTED_IP"
    run_cmd "${SUDO[@]}" ufw allow 22/tcp
    run_cmd "${SUDO[@]}" ufw allow 80/tcp
    run_cmd "${SUDO[@]}" ufw allow 443/tcp
    run_cmd "${SUDO[@]}" ufw allow 5555/tcp
    run_cmd "${SUDO[@]}" ufw --force enable
}

disable_security_if_present() {
    if command -v ufw >/dev/null 2>&1 && ufw_is_active; then run_cmd "${SUDO[@]}" ufw --force disable; fi
}

apply_security_choice() {
    CURRENT_ACTION="Applying firewall policy"; set_stage_progress 35
    if [[ "$SETUP_SECURITY" == true ]]; then configure_security; else disable_security_if_present; fi
    set_stage_progress 90
}

verify_security_choice() {
    if [[ "$SETUP_SECURITY" == true ]]; then ufw_is_active; else return 0; fi
}

speedtest_supported_by_policy() {
    dpkg --compare-versions "${VERSION_ID:-0}" ge 24.04
}

install_speedtest() {
    local key_tmp
    CURRENT_ACTION="Checking Ookla Speedtest"; set_stage_progress 15
    if [[ "$INSTALL_SPEEDTEST" != true ]]; then return 0; fi
    if command -v speedtest >/dev/null 2>&1; then return 0; fi
    if ! speedtest_supported_by_policy; then return 0; fi
    if dpkg-query -W -f='${Status}' speedtest-cli 2>/dev/null | grep -q 'ok installed'; then apt_remove speedtest-cli; fi
    apt_install ca-certificates curl gnupg apt-transport-https
    key_tmp="$(mktemp)"
    cleanup_files+=("$key_tmp")
    CURRENT_ACTION="Configuring Ookla repository"; set_stage_progress 50
    run_cmd curl -fsSL --retry 4 --retry-delay 2 --connect-timeout 15 --max-time 180 https://packagecloud.io/ookla/speedtest-cli/gpgkey -o "$key_tmp"
    run_cmd "${SUDO[@]}" gpg --batch --yes --dearmor -o /usr/share/keyrings/ookla-speedtest-archive-keyring.gpg "$key_tmp"
    printf '%s\n' 'deb [signed-by=/usr/share/keyrings/ookla-speedtest-archive-keyring.gpg] https://packagecloud.io/ookla/speedtest-cli/ubuntu/ jammy main' | "${SUDO[@]}" tee /etc/apt/sources.list.d/ookla_speedtest-cli.list >/dev/null
    CURRENT_ACTION="Installing Ookla Speedtest"; set_stage_progress 75
    apt_update
    apt_install speedtest
    set_stage_progress 92
}

verify_speedtest() {
    [[ "$INSTALL_SPEEDTEST" != true ]] && return 0
    speedtest_supported_by_policy || return 0
    command -v speedtest >/dev/null 2>&1
}

prepare_marzban_repo() {
    CURRENT_ACTION="Preparing Marzban Node repository"; set_stage_progress 25
    if [[ -d "$MARZBAN_NODE_DIR/.git" ]]; then
        run_cmd git -C "$MARZBAN_NODE_DIR" fetch --prune origin
        run_cmd git -C "$MARZBAN_NODE_DIR" pull --ff-only
    elif [[ -e "$MARZBAN_NODE_DIR" ]]; then
        log_warn "$MARZBAN_NODE_DIR exists and is not a Git repository."
    else
        run_cmd git clone --depth 1 https://github.com/Gozargah/Marzban-node "$MARZBAN_NODE_DIR"
    fi
    set_stage_progress 90
}

verify_marzban_repo() { [[ -d "$MARZBAN_NODE_DIR" ]]; }

install_assets() {
    CURRENT_ACTION="Preparing Xray assets"; set_stage_progress 15
    run_cmd "${SUDO[@]}" mkdir -p "$ASSETS_DIR"
    download_atomic https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat "$ASSETS_DIR/geosite.dat"
    CURRENT_ACTION="Downloading GeoIP"; set_stage_progress 45
    download_atomic https://github.com/v2fly/geoip/releases/latest/download/geoip.dat "$ASSETS_DIR/geoip.dat"
    CURRENT_ACTION="Downloading Iran routing data"; set_stage_progress 70
    download_atomic https://github.com/bootmortis/iran-hosted-domains/releases/latest/download/iran.dat "$ASSETS_DIR/iran.dat"
    set_stage_progress 92
}

verify_assets() {
    "${SUDO[@]}" test -s "$ASSETS_DIR/geosite.dat" && "${SUDO[@]}" test -s "$ASSETS_DIR/geoip.dat" && "${SUDO[@]}" test -s "$ASSETS_DIR/iran.dat"
}

install_client_certificate() {
    CURRENT_ACTION="Installing SSL client certificate"; set_stage_progress 30
    run_cmd "${SUDO[@]}" mkdir -p "$MARZBAN_NODE_DATA_DIR"
    download_atomic "$CLIENT_CERT_URL" "$CLIENT_CERT_FILE" 0644
    CURRENT_ACTION="Validating SSL client certificate"; set_stage_progress 78
    "${SUDO[@]}" grep -q -- 'BEGIN CERTIFICATE' "$CLIENT_CERT_FILE" || fatal "Downloaded SSL client certificate is not a PEM certificate."
    set_stage_progress 92
}

verify_client_certificate() {
    "${SUDO[@]}" test -s "$CLIENT_CERT_FILE" && "${SUDO[@]}" grep -q -- 'BEGIN CERTIFICATE' "$CLIENT_CERT_FILE"
}

get_installed_xray_version() {
    local xray_bin="$XRAY_DIR/xray"
    [[ -x "$xray_bin" ]] || return 1
    "$xray_bin" version 2>/dev/null | awk 'NR==1 {print $2}'
}

install_xray_core() {
    local current_version zip_tmp extract_dir xray_bin installed_version
    xray_bin="$XRAY_DIR/xray"
    current_version="$(get_installed_xray_version || true)"
    if [[ "$current_version" == "$XRAY_VERSION" || "$current_version" == "v$XRAY_VERSION" ]]; then return 0; fi
    zip_tmp="$(mktemp --suffix=.zip)"
    extract_dir="$(mktemp -d)"
    cleanup_files+=("$zip_tmp" "$extract_dir")
    CURRENT_ACTION="Downloading Xray-core v$XRAY_VERSION"; set_stage_progress 20
    run_cmd curl -fsSL --retry 4 --retry-delay 2 --connect-timeout 15 --max-time 300 -o "$zip_tmp" "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/${XRAY_ARCHIVE}"
    CURRENT_ACTION="Extracting Xray-core"; set_stage_progress 55
    run_cmd unzip -q -o "$zip_tmp" xray -d "$extract_dir"
    [[ -s "$extract_dir/xray" ]] || fatal "Xray archive does not contain the xray executable."
    run_cmd "${SUDO[@]}" mkdir -p "$XRAY_DIR"
    run_cmd "${SUDO[@]}" install -m 0755 "$extract_dir/xray" "$xray_bin"
    installed_version="$(get_installed_xray_version || true)"
    [[ -n "$installed_version" ]] || fatal "Installed Xray executable could not be validated."
    set_stage_progress 92
}

verify_xray_core() {
    local current_version
    current_version="$(get_installed_xray_version || true)"
    [[ "$current_version" == "$XRAY_VERSION" || "$current_version" == "v$XRAY_VERSION" ]]
}

generate_compose() {
    local compose_file="$MARZBAN_NODE_DIR/docker-compose.yml" tmp
    CURRENT_ACTION="Generating Docker Compose configuration"; set_stage_progress 25
    mkdir -p "$MARZBAN_NODE_DIR"
    tmp="$(mktemp)"
    cleanup_files+=("$tmp")
    cat > "$tmp" <<'YAML'
services:
  marzban-node:
    image: gozargah/marzban-node:latest
    restart: unless-stopped
    network_mode: host
    environment:
      SSL_CERT_FILE: "/var/lib/marzban-node/ssl_cert.pem"
      SSL_KEY_FILE: "/var/lib/marzban-node/ssl_key.pem"
      SSL_CLIENT_CERT_FILE: "/var/lib/marzban-node/ssl_client_cert.pem"
      XRAY_EXECUTABLE_PATH: "/var/lib/marzban/xray-core/xray"
      XRAY_ASSETS_PATH: "/usr/local/share/xray"
      SERVICE_PROTOCOL: "rest"
    volumes:
      - /var/lib/marzban-node:/var/lib/marzban-node
      - /var/lib/marzban/assets:/usr/local/share/xray:ro
      - /var/lib/marzban:/var/lib/marzban
YAML
    CURRENT_ACTION="Validating Compose configuration"; set_stage_progress 60
    run_cmd "${SUDO[@]}" docker compose -f "$tmp" config -q
    if [[ -f "$compose_file" ]] && ! cmp -s "$tmp" "$compose_file"; then cp -a "$compose_file" "${compose_file}.bak"; fi
    install -m 0644 "$tmp" "$compose_file"
    run_cmd "${SUDO[@]}" docker compose -f "$compose_file" config -q
    set_stage_progress 92
}

verify_compose() {
    local compose_file="$MARZBAN_NODE_DIR/docker-compose.yml"
    [[ -s "$compose_file" ]] && "${SUDO[@]}" docker compose -f "$compose_file" config -q >/dev/null 2>&1
}

verify_marzban_node_running() {
    local compose_file="$MARZBAN_NODE_DIR/docker-compose.yml"
    [[ -s "$compose_file" ]] || return 1
    "${SUDO[@]}" docker compose -f "$compose_file" ps --status running --services 2>/dev/null | grep -qx marzban-node
}

start_marzban_node() {
    local compose_file="$MARZBAN_NODE_DIR/docker-compose.yml" attempt node_log_tmp
    CURRENT_ACTION="Pulling Marzban Node image"; set_stage_progress 18
    run_cmd "${SUDO[@]}" docker compose -f "$compose_file" pull
    CURRENT_ACTION="Starting Marzban Node"; set_stage_progress 58
    run_cmd "${SUDO[@]}" docker compose -f "$compose_file" up -d --remove-orphans
    CURRENT_ACTION="Waiting for Marzban Node"; set_stage_progress 82
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        if verify_marzban_node_running; then return 0; fi
        sleep 2
    done
    node_log_tmp="$(mktemp)"
    cleanup_files+=("$node_log_tmp")
    "${SUDO[@]}" docker compose -f "$compose_file" logs --tail=100 marzban-node > "$node_log_tmp" 2>&1 || true
    LAST_COMMAND_LOG="$node_log_tmp"
    LAST_COMMAND_TEXT="docker compose logs marzban-node"
    LAST_COMMAND_RC=1
    fatal "Marzban Node container did not remain in running state."
}

STAGE_KEYS=(base_dependencies docker security speedtest repository assets client_certificate xray_core compose marzban_node)
STAGE_TITLES=("Base packages / APT" "Docker + Compose" "UFW security" "Ookla Speedtest" "Marzban Node repository" "Xray geo assets" "SSL client certificate" "Xray-core" "Docker Compose file" "Start Marzban Node")
STAGE_RUNNERS=(install_base_dependencies install_docker apply_security_choice install_speedtest prepare_marzban_repo install_assets install_client_certificate install_xray_core generate_compose start_marzban_node)
STAGE_VERIFIERS=(verify_base_dependencies verify_docker verify_security_choice verify_speedtest verify_marzban_repo verify_assets verify_client_certificate verify_xray_core verify_compose verify_marzban_node_running)
TOTAL_STAGES="${#STAGE_KEYS[@]}"

reconcile_checkpoints() {
    local i key verifier gap=false
    for (( i=0; i<TOTAL_STAGES; i++ )); do
        key="${STAGE_KEYS[$i]}"
        verifier="${STAGE_VERIFIERS[$i]}"
        if stage_is_marked "$key"; then
            if [[ "$gap" == true ]] || ! "$verifier"; then
                rewrite_state_prefix "$i"
                break
            fi
        else
            gap=true
        fi
    done
}

count_completed_stages() {
    local i count=0
    for (( i=0; i<TOTAL_STAGES; i++ )); do
        if stage_is_marked "${STAGE_KEYS[$i]}"; then count=$(( count + 1 )); fi
    done
    printf '%d' "$count"
}

show_status() {
    local i key title verifier status
    printf '\nMarzban Node Installer v%s\n\n' "$INSTALLER_VERSION"
    for (( i=0; i<TOTAL_STAGES; i++ )); do
        key="${STAGE_KEYS[$i]}"; title="${STAGE_TITLES[$i]}"; verifier="${STAGE_VERIFIERS[$i]}"
        if stage_is_marked "$key"; then if "$verifier"; then status=DONE; else status=STALE; fi; else status=PENDING; fi
        printf '[%02d/%02d] %-8s %s\n' "$((i+1))" "$TOTAL_STAGES" "$status" "$title"
    done
    if [[ -s "$LAST_ERROR_FILE" ]]; then printf '\nLast recorded error:\n'; cat "$LAST_ERROR_FILE"; fi
}

run_stage() {
    local index="$1" key title runner verifier
    key="${STAGE_KEYS[$index]}"; title="${STAGE_TITLES[$index]}"; runner="${STAGE_RUNNERS[$index]}"; verifier="${STAGE_VERIFIERS[$index]}"
    CURRENT_STAGE_KEY="$key"
    CURRENT_STAGE_TITLE="$title"
    CURRENT_STAGE_NUMBER=$(( index + 1 ))
    STAGE_STARTED_AT="$(date +%s)"
    STAGE_PROGRESS=10
    CURRENT_ACTION="Starting: $title"
    set_progress_detail "Step ${CURRENT_STAGE_NUMBER}/${TOTAL_STAGES}"
    if stage_is_marked "$key"; then
        STAGE_PROGRESS=100
        CURRENT_ACTION="Already completed and verified"
        ui_refresh DONE
        return 0
    fi
    ui_refresh RUNNING
    "$runner"
    STAGE_PROGRESS=92
    CURRENT_ACTION="Verifying: $title"
    ui_refresh VERIFYING
    if ! "$verifier"; then
        LAST_COMMAND_TEXT="Post-stage verification: $title"
        LAST_COMMAND_RC=1
        fatal "Post-stage verification failed: $title"
    fi
    mark_stage_done "$key"
    COMPLETED_COUNT=$(( COMPLETED_COUNT + 1 ))
    "${SUDO[@]}" rm -f -- "$LAST_ERROR_FILE" >/dev/null 2>&1 || true
    STAGE_PROGRESS=100
    CURRENT_ACTION="Completed: $title"
    set_progress_detail ""
    ui_refresh DONE
}

show_summary() {
    local ip=''
    CURRENT_STAGE_TITLE="Installation complete"
    CURRENT_STAGE_NUMBER="$TOTAL_STAGES"
    STAGE_PROGRESS=100
    CURRENT_ACTION="Marzban Node is installed and running"
    set_progress_detail "All ${TOTAL_STAGES} steps completed"
    ui_refresh COMPLETE
    ip="$(curl -4fsS --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || true)"
    ui_shutdown
    printf '\nInstallation completed successfully.\n'
    [[ -n "$ip" ]] && printf 'Public IPv4: %s\n' "$ip"
    printf 'Log file: %s\n' "$RUN_LOG"
}

main() {
    if [[ "$STATUS_ONLY" == true ]]; then
        show_status
        return 0
    fi
    reconcile_checkpoints
    COMPLETED_COUNT="$(count_completed_stages)"
    CURRENT_STAGE_NUMBER=$(( COMPLETED_COUNT + 1 ))
    if (( CURRENT_STAGE_NUMBER > TOTAL_STAGES )); then CURRENT_STAGE_NUMBER="$TOTAL_STAGES"; fi
    STAGE_PROGRESS=10
    CURRENT_STAGE_TITLE="Preparing installation"
    CURRENT_ACTION="Automatic mode: Speedtest=ON, UFW=OFF"
    set_progress_detail "Errors remain visible after dashboard closes"
    ui_init
    ui_refresh READY
    local i
    for (( i=0; i<TOTAL_STAGES; i++ )); do run_stage "$i"; done
    show_summary
}

main "$@"
