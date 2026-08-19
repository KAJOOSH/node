#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ==========================================
# Marzban Node Installer - Resumable Edition
# ==========================================

readonly INSTALLER_VERSION="2.2.0"
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
readonly RUN_LOCK_FILE="${INSTALLER_RUN_LOCK_FILE:-/run/lock/marzban-node-installer.lock}"
readonly OS_RELEASE_FILE="${INSTALLER_OS_RELEASE_FILE:-/etc/os-release}"
readonly LOG_DIR="${STATE_DIR}/logs"

readonly APT_LOCK_TIMEOUT="${APT_LOCK_TIMEOUT:-1800}"
readonly APT_LOCK_POLL="${APT_LOCK_POLL:-3}"
readonly APT_RETRIES="${APT_RETRIES:-3}"

CURRENT_STAGE_KEY=""
CURRENT_STAGE_TITLE="Pre-flight"
CURRENT_STAGE_NUMBER=0
TOTAL_STAGES=0
COMPLETED_COUNT=0
STATE_READY=false
ERROR_REPORTED=false
RESTART_REQUESTED=false
RUN_LOG=""
LAST_COMMAND_LOG=""
LAST_COMMAND_TEXT=""
PROGRESS_DETAIL=""
SPINNER_INDEX=0
STATUS_ONLY=false
STAGE_PROGRESS=0
CURRENT_ACTION="Preparing installer"
ACTIVE_OUTPUT_FILE=""
UI_ACTIVE=false
UI_LOG_LINES="${UI_LOG_LINES:-14}"
RUN_STARTED_AT="$(date +%s)"
STAGE_STARTED_AT="$(date +%s)"

# ==========================================
# Terminal dashboard / logging UI
# ==========================================
if [[ -t 1 ]]; then
    C_RESET='\033[0m'
    C_RED='\033[0;31m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'
    C_BLUE='\033[0;34m'
    C_CYAN='\033[0;36m'
    C_MAGENTA='\033[0;35m'
    C_BOLD='\033[1m'
    C_DIM='\033[2m'
else
    C_RESET=''
    C_RED=''
    C_GREEN=''
    C_YELLOW=''
    C_BLUE=''
    C_CYAN=''
    C_MAGENTA=''
    C_BOLD=''
    C_DIM=''
fi

internal_log() {
    local level="$1"
    shift
    [[ -n "${RUN_LOG:-}" ]] || return 0
    printf '[%s] %s - %s\n' "$level" "$(date '+%H:%M:%S')" "$*" >> "$RUN_LOG" 2>/dev/null || true
}

log_info()    { internal_log INFO "$*"; }
log_warn()    { internal_log WARN "$*"; }
log_success() { internal_log OK "$*"; }

format_duration() {
    local total="${1:-0}"
    local h m s
    (( total < 0 )) && total=0
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
    [[ "$cols" =~ ^[0-9]+$ ]] || cols=100
    (( cols < 72 )) && cols=72
    (( cols > 140 )) && cols=140
    printf '%d' "$cols"
}

terminal_height() {
    local rows=30
    if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
        rows="$(tput lines 2>/dev/null || printf '30')"
    fi
    [[ "$rows" =~ ^[0-9]+$ ]] || rows=30
    (( rows < 24 )) && rows=24
    printf '%d' "$rows"
}

repeat_char() {
    local char="$1" count="$2" out=""
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
    local stage_no="${CURRENT_STAGE_NUMBER:-0}"
    local stage_pct="${STAGE_PROGRESS:-0}"
    local value=0
    if (( TOTAL_STAGES > 0 )); then
        if (( stage_no <= 0 )); then
            value=$(( COMPLETED_COUNT * 100 / TOTAL_STAGES ))
        else
            value=$(( ((stage_no - 1) * 100 + stage_pct) / TOTAL_STAGES ))
        fi
    fi
    (( value < 0 )) && value=0
    (( value > 100 )) && value=100
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

ui_init() {
    [[ -t 1 ]] || return 0
    UI_ACTIVE=true
    # Alternate screen + hide cursor. Restored on exit/error.
    printf '\033[?1049h\033[?25l\033[2J\033[H'
}

ui_shutdown() {
    [[ "$UI_ACTIVE" == true ]] || return 0
    printf '\033[?25h\033[?1049l'
    UI_ACTIVE=false
}

ui_log_source() {
    if [[ -n "${ACTIVE_OUTPUT_FILE:-}" && -f "$ACTIVE_OUTPUT_FILE" ]]; then
        printf '%s' "$ACTIVE_OUTPUT_FILE"
    else
        printf '%s' "${RUN_LOG:-}"
    fi
}

ui_refresh() {
    local status="${1:-RUNNING}"
    local now elapsed stage_elapsed pct width rows inner bar_width bar source
    local spinner frames='|/-\\' line i j marker1 marker2 text1 text2
    local task_col task_text log_lines start_pad

    now="$(date +%s)"
    elapsed=$(( now - RUN_STARTED_AT ))
    stage_elapsed=$(( now - STAGE_STARTED_AT ))
    pct="$(progress_percent)"

    if [[ ! -t 1 ]]; then
        case "$status" in
            READY|DONE|FAILED|COMPLETE)
                printf '[%3d%%] %-9s %s\n' "$pct" "$status" "$CURRENT_STAGE_TITLE"
                ;;
        esac
        return 0
    fi

    width="$(terminal_width)"
    rows="$(terminal_height)"
    inner=$(( width - 4 ))
    bar_width=$(( width - 31 ))
    (( bar_width < 20 )) && bar_width=20
    bar="$(make_progress_bar "$pct" "$bar_width")"
    spinner="${frames:SPINNER_INDEX%4:1}"
    SPINNER_INDEX=$(( SPINNER_INDEX + 1 ))

    # 5 task rows + dashboard chrome. Adapt logs to terminal height.
    log_lines=$(( rows - 18 ))
    (( log_lines < 5 )) && log_lines=5
    (( log_lines > UI_LOG_LINES )) && log_lines="$UI_LOG_LINES"

    printf '\033[H\033[2J'
    printf '%b+%s+%b\n' "$C_CYAN" "$(repeat_char '-' "$((width-2))")" "$C_RESET"
    printf '%b|%b %b%-*s%b %b|%b\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$((inner-1))" "Marzban Node Installer v${INSTALLER_VERSION}" "$C_RESET" "$C_CYAN" "$C_RESET"
    printf '%b+%s+%b\n' "$C_CYAN" "$(repeat_char '-' "$((width-2))")" "$C_RESET"
    printf '%b|%b Overall  %b[%s]%b %3d%%  %s  Elapsed %-8s %*s%b|%b\n' \
        "$C_CYAN" "$C_RESET" "$C_MAGENTA" "$bar" "$C_RESET" "$pct" "$spinner" "$(format_duration "$elapsed")" \
        1 '' "$C_CYAN" "$C_RESET"
    printf '%b|%b Stage    %02d/%02d  %-*s%b|%b\n' "$C_CYAN" "$C_RESET" \
        "${CURRENT_STAGE_NUMBER:-0}" "$TOTAL_STAGES" "$((inner-16))" "$(truncate_line "$CURRENT_STAGE_TITLE" "$((inner-16))")" "$C_CYAN" "$C_RESET"
    printf '%b|%b Action   %-*s%b|%b\n' "$C_CYAN" "$C_RESET" "$((inner-9))" "$(truncate_line "$CURRENT_ACTION" "$((inner-9))")" "$C_CYAN" "$C_RESET"
    printf '%b|%b Status   %-10s  Stage %-8s  %-*s%b|%b\n' "$C_CYAN" "$C_RESET" "$status" "$(format_duration "$stage_elapsed")" \
        "$((inner-33))" "$(truncate_line "${PROGRESS_DETAIL:-}" "$((inner-33))")" "$C_CYAN" "$C_RESET"
    printf '%b+%s+%b\n' "$C_CYAN" "$(repeat_char '-' "$((width-2))")" "$C_RESET"
    printf '%b|%b %bTasks%b%-*s%b|%b\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET" "$((inner-6))" '' "$C_CYAN" "$C_RESET"

    task_col=$(( (inner - 3) / 2 ))
    for (( i=0; i<5; i++ )); do
        j=$(( i + 5 ))

        if stage_is_marked "${STAGE_KEYS[$i]}" 2>/dev/null; then marker1="${C_GREEN}✓${C_RESET}"
        elif (( i + 1 == CURRENT_STAGE_NUMBER )); then marker1="${C_YELLOW}▶${C_RESET}"
        else marker1="${C_DIM}○${C_RESET}"; fi
        text1="$(printf '%02d. %s' "$((i+1))" "${STAGE_TITLES[$i]}")"

        if (( j < TOTAL_STAGES )); then
            if stage_is_marked "${STAGE_KEYS[$j]}" 2>/dev/null; then marker2="${C_GREEN}✓${C_RESET}"
            elif (( j + 1 == CURRENT_STAGE_NUMBER )); then marker2="${C_YELLOW}▶${C_RESET}"
            else marker2="${C_DIM}○${C_RESET}"; fi
            text2="$(printf '%02d. %s' "$((j+1))" "${STAGE_TITLES[$j]}")"
        else
            marker2=' '
            text2=''
        fi

        printf '%b|%b %b %-*s | %b %-*s%b|%b\n' \
            "$C_CYAN" "$C_RESET" "$marker1" "$((task_col-3))" "$(truncate_line "$text1" "$((task_col-3))")" \
            "$marker2" "$((task_col-3))" "$(truncate_line "$text2" "$((task_col-3))")" "$C_CYAN" "$C_RESET"
    done

    printf '%b+%s+%b\n' "$C_CYAN" "$(repeat_char '-' "$((width-2))")" "$C_RESET"
    printf '%b|%b %bLive log — latest output%b%-*s%b|%b\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET" "$((inner-26))" '' "$C_CYAN" "$C_RESET"

    source="$(ui_log_source)"
    if [[ -n "$source" && -f "$source" ]]; then
        mapfile -t __ui_lines < <(tail -n "$log_lines" "$source" 2>/dev/null || true)
    else
        __ui_lines=()
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

clear_progress_line() { :; }

log_error() {
    internal_log ERROR "$*"
    if [[ -t 1 && "$UI_ACTIVE" == true ]]; then
        ui_refresh "FAILED"
    else
        printf '%b[ERROR]%b %s\n' "$C_RED" "$C_RESET" "$*" >&2
    fi
}

cleanup_files=()
cleanup() {
    local f
    ui_shutdown || true
    for f in "${cleanup_files[@]:-}"; do
        [[ -e "$f" ]] && rm -rf -- "$f" || true
    done
}
trap cleanup EXIT

quote_command_string() {
    local arg out=""
    for arg in "$@"; do
        printf -v arg '%q' "$arg"
        out+="${arg} "
    done
    printf '%s' "${out% }"
}

set_progress_detail() {
    PROGRESS_DETAIL="${1:-}"
}

set_stage_progress() {
    local value="${1:-0}"
    (( value < 0 )) && value=0
    (( value > 100 )) && value=100
    STAGE_PROGRESS="$value"
    ui_refresh "RUNNING"
}

render_progress() {
    local _completed="${1:-0}"
    local status="${2:-RUNNING}"
    local label="${3:-$CURRENT_STAGE_TITLE}"
    CURRENT_STAGE_TITLE="$label"
    ui_refresh "$status"
}

finish_progress_line() { return 0; }

show_last_command_error() {
    local max_lines="${1:-24}"
    [[ -n "${LAST_COMMAND_LOG:-}" && -s "$LAST_COMMAND_LOG" ]] || return 0
    if [[ -t 1 && "$UI_ACTIVE" == true ]]; then
        ACTIVE_OUTPUT_FILE="$LAST_COMMAND_LOG"
        ui_refresh "FAILED"
    else
        printf '%b--- command error output (last %s lines) ---%b\n' "$C_RED" "$max_lines" "$C_RESET" >&2
        tail -n "$max_lines" "$LAST_COMMAND_LOG" >&2 || true
        printf '%b--------------------------------------------%b\n' "$C_RED" "$C_RESET" >&2
    fi
}

save_last_error() {
    local message="$1"
    [[ "$STATE_READY" == true ]] || return 0

    local tmp
    tmp="$(mktemp)"
    cleanup_files+=("$tmp")
    {
        printf 'time=%s\n' "$(date -Is)"
        printf 'installer_version=%s\n' "$INSTALLER_VERSION"
        printf 'stage=%s\n' "${CURRENT_STAGE_KEY:-preflight}"
        printf 'stage_title=%s\n' "$CURRENT_STAGE_TITLE"
        printf 'message=%s\n' "$message"
        [[ -n "${RUN_LOG:-}" ]] && printf 'run_log=%s\n' "$RUN_LOG"
        if [[ -n "${LAST_COMMAND_LOG:-}" && -s "$LAST_COMMAND_LOG" ]]; then
            printf '\ncommand_output_tail:\n'
            tail -n 40 "$LAST_COMMAND_LOG" || true
        fi
    } > "$tmp"
    "${SUDO[@]}" install -m 0644 "$tmp" "$LAST_ERROR_FILE" >/dev/null 2>&1 || true
}

resume_hint() {
    [[ "$STATE_READY" == true ]] || return 0
    local script_path
    script_path="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
    printf '%bResume:%b bash %q\n' "$C_YELLOW" "$C_RESET" "$script_path" >&2
    [[ -n "${RUN_LOG:-}" ]] && printf '%bFull log:%b %s\n' "$C_YELLOW" "$C_RESET" "$RUN_LOG" >&2
}

fatal() {
    local message="$*"
    save_last_error "$message"
    set_progress_detail ""
    if (( TOTAL_STAGES > 0 )); then
        render_progress "$COMPLETED_COUNT" "FAILED" "$CURRENT_STAGE_TITLE"
        finish_progress_line
    fi
    log_error "$message"
    show_last_command_error
    resume_hint
    exit 1
}

on_error() {
    local rc="$1"
    local line="$2"
    local command="$3"

    [[ "$ERROR_REPORTED" == false ]] || exit "$rc"
    ERROR_REPORTED=true
    trap - ERR
    set +e

    local failed_command="${LAST_COMMAND_TEXT:-$command}"
    local message="Stage ${CURRENT_STAGE_NUMBER:-0}/${TOTAL_STAGES:-0} failed (exit $rc): $failed_command"
    save_last_error "$message"
    set_progress_detail ""
    if (( TOTAL_STAGES > 0 )); then
        render_progress "$COMPLETED_COUNT" "FAILED" "$CURRENT_STAGE_TITLE"
        finish_progress_line
    fi
    log_error "$message"
    show_last_command_error
    resume_hint
    exit "$rc"
}
trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

run_cmd() {
    local rc pid cmd_tmp command_text
    cmd_tmp="$(mktemp)"
    cleanup_files+=("$cmd_tmp")
    command_text="$(quote_command_string "$@")"
    LAST_COMMAND_TEXT="$command_text"
    CURRENT_ACTION="$command_text"
    internal_log CMD "$command_text"
    ACTIVE_OUTPUT_FILE="$cmd_tmp"

    # Command output is captured, while the dashboard tails it live.
    "$@" >"$cmd_tmp" 2>&1 &
    pid=$!

    while kill -0 "$pid" 2>/dev/null; do
        if [[ "$UI_ACTIVE" == true ]]; then
            ui_refresh "RUNNING"
        fi
        sleep 0.50
    done

    if wait "$pid"; then
        rc=0
    else
        rc=$?
    fi

    if [[ -n "${RUN_LOG:-}" ]]; then
        {
            printf '\n[COMMAND] %s\n' "$command_text"
            cat "$cmd_tmp"
        } >> "$RUN_LOG" 2>/dev/null || true
    fi

    if (( rc == 0 )); then
        ACTIVE_OUTPUT_FILE=""
        LAST_COMMAND_LOG=""
        LAST_COMMAND_TEXT=""
        internal_log OK "Command completed: $command_text"
        [[ "$UI_ACTIVE" == true ]] && ui_refresh "RUNNING"
        rm -f -- "$cmd_tmp"
        return 0
    fi

    LAST_COMMAND_LOG="$cmd_tmp"
    ACTIVE_OUTPUT_FILE="$cmd_tmp"
    internal_log ERROR "Command failed (exit $rc): $command_text"
    [[ "$UI_ACTIVE" == true ]] && ui_refresh "FAILED"
    return "$rc"
}

ask_yes_no() {
    local prompt="$1"
    local answer
    while true; do
        clear_progress_line
        printf '%b%s (y/n): %b' "$C_YELLOW" "$prompt" "$C_RESET"
        read -r answer
        case "$answer" in
            [Yy]) return 0 ;;
            [Nn]) return 1 ;;
            *) printf '%bPlease enter y or n.%b\n' "$C_RED" "$C_RESET" ;;
        esac
    done
}

usage() {
    cat <<EOF_USAGE
Marzban Node Installer v${INSTALLER_VERSION}

Usage:
  bash $0              Resume normally (default)
  bash $0 --restart    Clear installer checkpoints/settings and start workflow again
  bash $0 --status     Show saved stage status and exit
  bash $0 --help       Show this help

Normal installation is quiet: subprocess output is written to an internal log.
Interactive questions are disabled. The terminal shows a live dashboard with progress, tasks and logs.
EOF_USAGE
}

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --restart)
                RESTART_REQUESTED=true
                ;;
            --status)
                STATUS_ONLY=true
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage >&2
                exit 2
                ;;
        esac
        shift
    done
}

parse_args "$@"

# ==========================================
# Privilege handling
# ==========================================
if (( EUID == 0 )); then
    SUDO=()
else
    command -v sudo >/dev/null 2>&1 || fatal "sudo is required when the script is not run as root."
    SUDO=(sudo)
    run_cmd "${SUDO[@]}" -v
fi

# Prevent two copies of this installer from running simultaneously.
command -v flock >/dev/null 2>&1 || fatal "flock is required (normally provided by util-linux)."
# Create the lock as root when needed, then open it read-only so the script also
# works when launched by a normal user through sudo.
run_cmd "${SUDO[@]}" touch "$RUN_LOCK_FILE"
run_cmd "${SUDO[@]}" chmod 0644 "$RUN_LOCK_FILE"
exec 9<"$RUN_LOCK_FILE"
if ! flock -n 9; then
    fatal "Another copy of this installer is already running."
fi

# ==========================================
# OS checks
# ==========================================
[[ -r "$OS_RELEASE_FILE" ]] || fatal "$OS_RELEASE_FILE not found. Unsupported operating system."
# shellcheck disable=SC1091
source "$OS_RELEASE_FILE"
[[ "${ID:-}" == "ubuntu" ]] || fatal "This installer currently supports Ubuntu only. Detected: ${PRETTY_NAME:-unknown}."

case "$(uname -m)" in
    x86_64|amd64)
        XRAY_ARCHIVE="Xray-linux-64.zip"
        ;;
    aarch64|arm64)
        XRAY_ARCHIVE="Xray-linux-arm64-v8a.zip"
        ;;
    *)
        fatal "Unsupported CPU architecture: $(uname -m)"
        ;;
esac

[[ "$APT_LOCK_TIMEOUT" =~ ^[0-9]+$ ]] || fatal "APT_LOCK_TIMEOUT must be a non-negative integer."
[[ "$APT_LOCK_POLL" =~ ^[1-9][0-9]*$ ]] || fatal "APT_LOCK_POLL must be a positive integer."
[[ "$APT_RETRIES" =~ ^[1-9][0-9]*$ ]] || fatal "APT_RETRIES must be a positive integer."

# ==========================================
# Persistent state / resume support
# ==========================================
init_state_storage() {
    "${SUDO[@]}" mkdir -p "$STATE_DIR" "$LOG_DIR" >/dev/null 2>&1
    "${SUDO[@]}" touch "$STATE_FILE" >/dev/null 2>&1
    "${SUDO[@]}" chmod 0755 "$STATE_DIR" "$LOG_DIR" >/dev/null 2>&1
    "${SUDO[@]}" chmod 0644 "$STATE_FILE" >/dev/null 2>&1
    RUN_LOG="$LOG_DIR/run-$(date '+%Y%m%d-%H%M%S')-$$.log"
    "${SUDO[@]}" touch "$RUN_LOG" >/dev/null 2>&1
    "${SUDO[@]}" chmod 0600 "$RUN_LOG" >/dev/null 2>&1
    STATE_READY=true
    internal_log INFO "Marzban Node Installer v$INSTALLER_VERSION"
}

clear_installer_state() {
    log_warn "Restart requested: clearing installer checkpoints and saved choices only."
    "${SUDO[@]}" rm -f -- "$STATE_FILE" "$SETTINGS_FILE" "$LAST_ERROR_FILE"
    "${SUDO[@]}" touch "$STATE_FILE"
    "${SUDO[@]}" chmod 0644 "$STATE_FILE"
    log_success "Installer state cleared. Existing installed software/data was not removed."
}

stage_is_marked() {
    local key="$1"
    grep -Fxq -- "$key" "$STATE_FILE" 2>/dev/null
}

mark_stage_done() {
    local key="$1"
    stage_is_marked "$key" && return 0
    printf '%s\n' "$key" | "${SUDO[@]}" tee -a "$STATE_FILE" >/dev/null
}

rewrite_state_prefix() {
    local keep_count="$1"
    local tmp i
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

read_saved_bool() {
    local key="$1"
    local value
    value="$(awk -F= -v k="$key" '$1 == k {print $2; exit}' "$SETTINGS_FILE" 2>/dev/null || true)"
    case "$value" in
        true|false) printf '%s' "$value" ;;
        *) return 1 ;;
    esac
}

load_saved_settings() {
    [[ -r "$SETTINGS_FILE" ]] || return 1

    local saved_security saved_speedtest
    saved_security="$(read_saved_bool SETUP_SECURITY || true)"
    saved_speedtest="$(read_saved_bool INSTALL_SPEEDTEST || true)"

    [[ -n "$saved_security" && -n "$saved_speedtest" ]] || return 1

    # Quiet/background execution must never stop on a hidden package prompt.
    AUTO_MODE=true
    SETUP_SECURITY="$saved_security"
    INSTALL_SPEEDTEST="$saved_speedtest"
    return 0
}

load_or_ask_settings() {
    # Fixed unattended policy requested by the operator.
    # Never ask questions: Speedtest is enabled, UFW setup is disabled.
    AUTO_MODE=true
    SETUP_SECURITY=false
    INSTALL_SPEEDTEST=true
    save_settings
    log_info "Automatic defaults: Speedtest=enabled, UFW setup=disabled, APT=noninteractive."
}

init_state_storage
if [[ "$RESTART_REQUESTED" == true ]]; then
    clear_installer_state
fi

# ==========================================
# APT helpers - lock-safe and retryable
# ==========================================
apt_env=()
apt_yes=()
apt_dpkg_opts=()

configure_apt_mode() {
    apt_env=()
    apt_yes=()
    apt_dpkg_opts=()

    if [[ "$AUTO_MODE" == true ]]; then
        apt_env=(env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a UCF_FORCE_CONFFOLD=1)
        apt_yes=(-y)
        apt_dpkg_opts=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
    fi
}

get_package_manager_lock_holders() {
    local locks=(
        /var/lib/dpkg/lock-frontend
        /var/lib/dpkg/lock
        /var/lib/apt/lists/lock
        /var/cache/apt/archives/lock
    )
    local lock

    if command -v fuser >/dev/null 2>&1; then
        {
            for lock in "${locks[@]}"; do
                [[ -e "$lock" ]] || continue
                "${SUDO[@]}" fuser "$lock" 2>/dev/null || true
            done
        } | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -nu || true
        return 0
    fi

    # Fallback when fuser is unavailable: detect common apt/dpkg processes.
    "${SUDO[@]}" ps -eo pid=,comm=,args= | awk -v self="$$" '
        {
            pid=$1; comm=$2;
            if (pid == self || comm == "awk" || comm == "ps" || comm == "sudo") next;
            if (comm ~ /^(apt|apt-get|dpkg|dpkg-deb|unattended-upgr|packagekitd)$/ ||
                $0 ~ /[\/]usr[\/]lib[\/]apt[\/]apt\.systemd\.daily/ ||
                $0 ~ /[\/]usr[\/]bin[\/]unattended-upgrade/) {
                print pid;
            }
        }
    ' | sort -nu || true
}

show_lock_holder_details() {
    local holders="$1"
    local pid_csv
    [[ -n "$holders" ]] || return 0
    pid_csv="$(printf '%s\n' "$holders" | paste -sd, -)"
    [[ -n "$pid_csv" ]] || return 0
    "${SUDO[@]}" ps -p "$pid_csv" -o pid=,comm=,etime=,args= 2>/dev/null || true
}

wait_for_package_manager() {
    local start now elapsed holders last_holder_text=""
    start="$(date +%s)"

    while true; do
        holders="$(get_package_manager_lock_holders)"
        if [[ -z "$holders" ]]; then
            set_progress_detail ""
            return 0
        fi

        now="$(date +%s)"
        elapsed=$(( now - start ))
        last_holder_text="$(printf '%s' "$holders" | tr '\n' ',' | sed 's/,$//')"

        if (( elapsed >= APT_LOCK_TIMEOUT )); then
            set_progress_detail ""
            internal_log ERROR "Timed out waiting for apt/dpkg lock. PID(s): $last_holder_text"
            show_lock_holder_details "$holders" >> "${RUN_LOG:-/dev/null}" 2>&1 || true
            LAST_COMMAND_LOG="${RUN_LOG:-}"
            return 1
        fi

        set_progress_detail "Waiting for APT lock (PID: ${last_holder_text}, ${elapsed}s)"
        CURRENT_ACTION="Waiting safely for apt/dpkg lock held by PID(s): ${last_holder_text}"
        ui_refresh "WAITING"
        sleep "$APT_LOCK_POLL"
    done
}
repair_dpkg_if_needed() {
    local audit
    audit="$("${SUDO[@]}" dpkg --audit 2>&1 || true)"
    [[ -n "$audit" ]] || return 0

    log_warn "dpkg reports unfinished package configuration; attempting a safe dpkg --configure -a."
    [[ -n "${RUN_LOG:-}" ]] && printf '%s\n' "$audit" >> "$RUN_LOG"

    wait_for_package_manager || return 1
    if [[ "$AUTO_MODE" == true ]]; then
        run_cmd "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a UCF_FORCE_CONFFOLD=1 \
            dpkg --force-confdef --force-confold --configure -a
    else
        run_cmd "${SUDO[@]}" dpkg --configure -a
    fi
}

apt_exec() {
    local attempt rc=1

    for (( attempt=1; attempt<=APT_RETRIES; attempt++ )); do
        wait_for_package_manager || return 1

        log_info "APT attempt ${attempt}/${APT_RETRIES}."
        if run_cmd "${SUDO[@]}" "${apt_env[@]}" apt-get \
            -o "DPkg::Lock::Timeout=${APT_LOCK_TIMEOUT}" \
            -o "Acquire::Retries=4" \
            "$@"; then
            return 0
        else
            rc=$?
        fi

        if (( attempt < APT_RETRIES )); then
            log_warn "APT command failed (exit $rc). It will be retried after checking package-manager state."
            sleep 3
            wait_for_package_manager || return 1
            repair_dpkg_if_needed || log_warn "dpkg repair attempt did not complete; APT will still be retried."
        fi
    done

    internal_log ERROR "APT command failed after ${APT_RETRIES} attempt(s)."
    return "$rc"
}

apt_update() {
    apt_exec update
}

apt_install() {
    apt_exec install "${apt_yes[@]}" "${apt_dpkg_opts[@]}" "$@"
}

apt_remove() {
    apt_exec remove "${apt_yes[@]}" "${apt_dpkg_opts[@]}" "$@"
}

# ==========================================
# Download helpers
# ==========================================
download_atomic() {
    local url="$1"
    local destination="$2"
    local mode="${3:-0644}"
    local tmp

    tmp="$(mktemp)"
    cleanup_files+=("$tmp")

    run_cmd curl -fsSL --retry 4 --retry-delay 2 --connect-timeout 15 --max-time 180 -o "$tmp" "$url"
    [[ -s "$tmp" ]] || fatal "Downloaded file is empty: $url"

    run_cmd "${SUDO[@]}" install -m "$mode" "$tmp" "$destination"
    rm -f -- "$tmp"
}

# ==========================================
# Stage 1 - Base dependencies
# ==========================================
BASE_PACKAGES=(ca-certificates curl git wget unzip gnupg lsb-release)

install_base_dependencies() {
    log_info "Installing required base packages..."
    CURRENT_ACTION="Updating Ubuntu package index"; set_stage_progress 15
    apt_update
    CURRENT_ACTION="Installing required base packages"; set_stage_progress 55
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

# ==========================================
# Stage 2 - Docker
# ==========================================
install_docker() {
    if command -v docker >/dev/null 2>&1 && "${SUDO[@]}" docker compose version >/dev/null 2>&1; then
        log_success "Docker and Docker Compose are already installed."
        return 0
    fi

    log_warn "Docker/Compose not found or incomplete. Installing Docker..."

    local installer
    CURRENT_ACTION="Downloading Docker installer"; set_stage_progress 18
    installer="$(mktemp)"
    cleanup_files+=("$installer")
    run_cmd curl -fsSL --retry 4 --retry-delay 2 --connect-timeout 15 --max-time 180 https://get.docker.com -o "$installer"

    # Docker's installer may call apt internally, so wait for unattended-upgrades first.
    CURRENT_ACTION="Waiting for package manager before Docker"; set_stage_progress 35
    wait_for_package_manager
    CURRENT_ACTION="Installing Docker Engine and Compose"; set_stage_progress 50
    if [[ "$AUTO_MODE" == true ]]; then
        run_cmd "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive sh "$installer"
    else
        run_cmd "${SUDO[@]}" sh "$installer"
    fi

    CURRENT_ACTION="Enabling Docker service"; set_stage_progress 82
    run_cmd "${SUDO[@]}" systemctl enable --now docker
    verify_docker || fatal "Docker installation completed but Docker Compose is unavailable."
    log_success "Docker and Docker Compose are ready."
}

verify_docker() {
    command -v docker >/dev/null 2>&1 && "${SUDO[@]}" docker compose version >/dev/null 2>&1
}

# ==========================================
# Stage 3 - UFW
# ==========================================
ufw_is_active() {
    command -v ufw >/dev/null 2>&1 && "${SUDO[@]}" ufw status 2>/dev/null | grep -q '^Status: active'
}

ensure_ufw_installed() {
    if ! command -v ufw >/dev/null 2>&1; then
        log_warn "UFW is not installed. Installing it..."
        apt_update
        apt_install ufw
    else
        log_success "UFW is already installed."
    fi
}

configure_security() {
    ensure_ufw_installed

    log_info "Applying UFW rules..."
    run_cmd "${SUDO[@]}" ufw default deny incoming
    run_cmd "${SUDO[@]}" ufw default allow outgoing
    run_cmd "${SUDO[@]}" ufw allow from "$TRUSTED_IP"
    run_cmd "${SUDO[@]}" ufw allow 22/tcp
    run_cmd "${SUDO[@]}" ufw allow 80/tcp
    run_cmd "${SUDO[@]}" ufw allow 443/tcp
    run_cmd "${SUDO[@]}" ufw allow 5555/tcp
    run_cmd "${SUDO[@]}" ufw --force enable

    ufw_is_active || fatal "UFW was enabled but does not report an active state."
    log_success "UFW is enabled and security rules are active."
}

disable_security_if_present() {
    if ! command -v ufw >/dev/null 2>&1; then
        log_info "UFW is not installed; nothing to disable."
        return 0
    fi

    if ufw_is_active; then
        log_warn "UFW exists and is active. Disabling it because security setup was declined..."
        run_cmd "${SUDO[@]}" ufw --force disable
        log_success "UFW has been disabled."
    else
        log_info "UFW is installed but already inactive."
    fi
}

apply_security_choice() {
    CURRENT_ACTION="Applying firewall policy (UFW setup disabled)"; set_stage_progress 35
    if [[ "$SETUP_SECURITY" == true ]]; then
        configure_security
    else
        disable_security_if_present
    fi
}

verify_security_choice() {
    if [[ "$SETUP_SECURITY" == true ]]; then
        ufw_is_active
    else
        # Once the user declined UFW and this stage was checkpointed, do not
        # invalidate the checkpoint merely because UFW was enabled later by
        # an administrator. This avoids unexpectedly disabling a later policy.
        return 0
    fi
}

# ==========================================
# Stage 4 - Ookla Speedtest
# ==========================================
speedtest_supported_by_policy() {
    local ubuntu_version="${VERSION_ID:-0}"
    dpkg --compare-versions "$ubuntu_version" ge 24.04
}

install_speedtest() {
    CURRENT_ACTION="Checking Ookla Speedtest installation"; set_stage_progress 15
    if [[ "$INSTALL_SPEEDTEST" != true ]]; then
        log_info "Speedtest installation skipped by user choice."
        return 0
    fi

    if command -v speedtest >/dev/null 2>&1; then
        log_success "Ookla Speedtest CLI is already installed."
        return 0
    fi

    local ubuntu_version="${VERSION_ID:-0}"
    if ! speedtest_supported_by_policy; then
        log_warn "Ubuntu $ubuntu_version is below 24.04; Speedtest installation was skipped by policy."
        return 0
    fi

    log_info "Installing official Ookla Speedtest CLI..."

    if dpkg-query -W -f='${Status}' speedtest-cli 2>/dev/null | grep -q 'ok installed'; then
        log_warn "The distro 'speedtest-cli' package conflicts with Ookla's 'speedtest' package. Removing it first."
        apt_remove speedtest-cli
    fi

    CURRENT_ACTION="Installing Speedtest prerequisites"; set_stage_progress 30
    apt_install ca-certificates curl gnupg apt-transport-https

    CURRENT_ACTION="Configuring official Ookla repository"; set_stage_progress 50
    local key_tmp
    key_tmp="$(mktemp)"
    cleanup_files+=("$key_tmp")
    run_cmd curl -fsSL --retry 4 --retry-delay 2 --connect-timeout 15 --max-time 180 \
        https://packagecloud.io/ookla/speedtest-cli/gpgkey -o "$key_tmp"
    run_cmd "${SUDO[@]}" gpg --batch --yes --dearmor -o /usr/share/keyrings/ookla-speedtest-archive-keyring.gpg "$key_tmp"

    printf '%s\n' 'deb [signed-by=/usr/share/keyrings/ookla-speedtest-archive-keyring.gpg] https://packagecloud.io/ookla/speedtest-cli/ubuntu/ jammy main' \
        | "${SUDO[@]}" tee /etc/apt/sources.list.d/ookla_speedtest-cli.list >/dev/null

    CURRENT_ACTION="Refreshing package index for Ookla"; set_stage_progress 68
    apt_update
    CURRENT_ACTION="Installing Ookla Speedtest CLI"; set_stage_progress 82
    apt_install speedtest
    set_stage_progress 92

    command -v speedtest >/dev/null 2>&1 || fatal "Speedtest CLI installation failed."
    log_success "Ookla Speedtest CLI installed successfully."
}

verify_speedtest() {
    [[ "$INSTALL_SPEEDTEST" != true ]] && return 0
    speedtest_supported_by_policy || return 0
    command -v speedtest >/dev/null 2>&1
}

# ==========================================
# Stage 5 - Marzban Node repository
# ==========================================
prepare_marzban_repo() {
    CURRENT_ACTION="Preparing Marzban Node source repository"; set_stage_progress 25
    if [[ -d "$MARZBAN_NODE_DIR/.git" ]]; then
        log_info "Marzban-node repository already exists. Updating it..."
        run_cmd git -C "$MARZBAN_NODE_DIR" fetch --prune origin
        run_cmd git -C "$MARZBAN_NODE_DIR" pull --ff-only
    elif [[ -e "$MARZBAN_NODE_DIR" ]]; then
        log_warn "$MARZBAN_NODE_DIR exists but is not a Git repository. Keeping the directory and continuing."
    else
        log_info "Cloning Marzban-node repository..."
        run_cmd git clone --depth 1 https://github.com/Gozargah/Marzban-node "$MARZBAN_NODE_DIR"
    fi
}

verify_marzban_repo() {
    [[ -d "$MARZBAN_NODE_DIR" ]]
}

# ==========================================
# Stage 6 - Xray assets
# ==========================================
install_assets() {
    log_info "Installing/updating Xray assets..."
    CURRENT_ACTION="Preparing Xray geo assets directory"; set_stage_progress 15
    run_cmd "${SUDO[@]}" mkdir -p "$ASSETS_DIR"

    download_atomic \
        "https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat" \
        "$ASSETS_DIR/geosite.dat"
    CURRENT_ACTION="Downloading GeoIP database"; set_stage_progress 42

    download_atomic \
        "https://github.com/v2fly/geoip/releases/latest/download/geoip.dat" \
        "$ASSETS_DIR/geoip.dat"
    CURRENT_ACTION="Downloading Iran routing database"; set_stage_progress 68

    download_atomic \
        "https://github.com/bootmortis/iran-hosted-domains/releases/latest/download/iran.dat" \
        "$ASSETS_DIR/iran.dat"
    set_stage_progress 90

    log_success "Xray assets are ready."
}

verify_assets() {
    "${SUDO[@]}" test -s "$ASSETS_DIR/geosite.dat" &&
        "${SUDO[@]}" test -s "$ASSETS_DIR/geoip.dat" &&
        "${SUDO[@]}" test -s "$ASSETS_DIR/iran.dat"
}

# ==========================================
# Stage 7 - SSL client certificate
# ==========================================
install_client_certificate() {
    log_info "Installing SSL client certificate..."
    CURRENT_ACTION="Downloading Marzban Node client certificate"; set_stage_progress 30
    run_cmd "${SUDO[@]}" mkdir -p "$MARZBAN_NODE_DATA_DIR"
    download_atomic "$CLIENT_CERT_URL" "$CLIENT_CERT_FILE" 0644
    CURRENT_ACTION="Validating client certificate"; set_stage_progress 78

    "${SUDO[@]}" grep -q -- 'BEGIN CERTIFICATE' "$CLIENT_CERT_FILE" || \
        fatal "Downloaded SSL client certificate does not look like a PEM certificate."

    log_success "SSL client certificate installed."
}

verify_client_certificate() {
    "${SUDO[@]}" test -s "$CLIENT_CERT_FILE" &&
        "${SUDO[@]}" grep -q -- 'BEGIN CERTIFICATE' "$CLIENT_CERT_FILE"
}

# ==========================================
# Stage 8 - Xray Core
# ==========================================
get_installed_xray_version() {
    local xray_bin="$XRAY_DIR/xray"
    [[ -x "$xray_bin" ]] || return 1
    "$xray_bin" version 2>/dev/null | awk 'NR==1 {print $2}'
}

install_xray_core() {
    local current_version=""
    local xray_bin="$XRAY_DIR/xray"

    current_version="$(get_installed_xray_version || true)"
    if [[ "$current_version" == "$XRAY_VERSION" || "$current_version" == "v$XRAY_VERSION" ]]; then
        log_success "Xray-core $XRAY_VERSION is already installed."
        return 0
    fi

    log_info "Installing Xray-core v$XRAY_VERSION for $(uname -m)..."
    CURRENT_ACTION="Downloading Xray-core v$XRAY_VERSION"; set_stage_progress 20

    local zip_tmp extract_dir
    zip_tmp="$(mktemp --suffix=.zip)"
    extract_dir="$(mktemp -d)"
    cleanup_files+=("$zip_tmp" "$extract_dir")

    run_cmd curl -fsSL --retry 4 --retry-delay 2 --connect-timeout 15 --max-time 300 \
        -o "$zip_tmp" \
        "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/${XRAY_ARCHIVE}"

    CURRENT_ACTION="Extracting Xray-core"; set_stage_progress 58
    run_cmd unzip -q -o "$zip_tmp" xray -d "$extract_dir"
    [[ -s "$extract_dir/xray" ]] || fatal "Xray archive did not contain a valid xray executable."

    run_cmd "${SUDO[@]}" mkdir -p "$XRAY_DIR"
    CURRENT_ACTION="Installing Xray-core executable"; set_stage_progress 78
    run_cmd "${SUDO[@]}" install -m 0755 "$extract_dir/xray" "$xray_bin"

    local installed_version
    installed_version="$(get_installed_xray_version || true)"
    [[ -n "$installed_version" ]] || fatal "Installed Xray executable could not be validated."

    log_success "Xray-core installed: $installed_version"
}

verify_xray_core() {
    local current_version
    current_version="$(get_installed_xray_version || true)"
    [[ "$current_version" == "$XRAY_VERSION" || "$current_version" == "v$XRAY_VERSION" ]]
}

# ==========================================
# Stage 9 - Docker Compose
# ==========================================
generate_compose() {
    CURRENT_ACTION="Generating Docker Compose configuration"; set_stage_progress 25
    local compose_file="$MARZBAN_NODE_DIR/docker-compose.yml"
    local tmp

    log_info "Generating docker-compose.yml..."
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

    # Validate the generated file before replacing the active compose file.
    CURRENT_ACTION="Validating generated Compose configuration"; set_stage_progress 60
    run_cmd "${SUDO[@]}" docker compose -f "$tmp" config -q

    if [[ -f "$compose_file" ]] && ! cmp -s "$tmp" "$compose_file"; then
        cp -a "$compose_file" "${compose_file}.bak"
        log_info "Existing compose file backed up to ${compose_file}.bak"
    fi

    install -m 0644 "$tmp" "$compose_file"
    run_cmd "${SUDO[@]}" docker compose -f "$compose_file" config -q
    log_success "docker-compose.yml is valid."
}

verify_compose() {
    local compose_file="$MARZBAN_NODE_DIR/docker-compose.yml"
    [[ -s "$compose_file" ]] && "${SUDO[@]}" docker compose -f "$compose_file" config -q >/dev/null 2>&1
}

# ==========================================
# Stage 10 - Start Marzban Node
# ==========================================
start_marzban_node() {
    local compose_file="$MARZBAN_NODE_DIR/docker-compose.yml"

    log_info "Pulling the latest Marzban Node image..."
    CURRENT_ACTION="Pulling latest Marzban Node image"; set_stage_progress 18
    run_cmd "${SUDO[@]}" docker compose -f "$compose_file" pull

    log_info "Starting Marzban Node..."
    CURRENT_ACTION="Starting Marzban Node container"; set_stage_progress 58
    run_cmd "${SUDO[@]}" docker compose -f "$compose_file" up -d --remove-orphans

    CURRENT_ACTION="Waiting for Marzban Node health"; set_stage_progress 82
    local attempt
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        if verify_marzban_node_running; then
            log_success "Marzban Node container is running."
            return 0
        fi
        sleep 2
    done

    local node_log_tmp
    node_log_tmp="$(mktemp)"
    cleanup_files+=("$node_log_tmp")
    "${SUDO[@]}" docker compose -f "$compose_file" logs --tail=80 marzban-node >"$node_log_tmp" 2>&1 || true
    [[ -n "${RUN_LOG:-}" ]] && cat "$node_log_tmp" >> "$RUN_LOG" 2>/dev/null || true
    LAST_COMMAND_LOG="$node_log_tmp"
    fatal "Marzban Node failed to start correctly."
}

verify_marzban_node_running() {
    local compose_file="$MARZBAN_NODE_DIR/docker-compose.yml"
    [[ -s "$compose_file" ]] || return 1
    "${SUDO[@]}" docker compose -f "$compose_file" ps --status running --services 2>/dev/null | grep -qx 'marzban-node'
}

# ==========================================
# Stage registry / checkpoint engine
# ==========================================
STAGE_KEYS=(
    base_dependencies
    docker
    security
    speedtest
    repository
    assets
    client_certificate
    xray_core
    compose
    marzban_node
)

STAGE_TITLES=(
    "Base packages / APT"
    "Docker + Compose"
    "UFW security"
    "Ookla Speedtest"
    "Marzban Node repository"
    "Xray geo assets"
    "SSL client certificate"
    "Xray-core"
    "Docker Compose file"
    "Start Marzban Node"
)

STAGE_RUNNERS=(
    install_base_dependencies
    install_docker
    apply_security_choice
    install_speedtest
    prepare_marzban_repo
    install_assets
    install_client_certificate
    install_xray_core
    generate_compose
    start_marzban_node
)

STAGE_VERIFIERS=(
    verify_base_dependencies
    verify_docker
    verify_security_choice
    verify_speedtest
    verify_marzban_repo
    verify_assets
    verify_client_certificate
    verify_xray_core
    verify_compose
    verify_marzban_node_running
)

TOTAL_STAGES="${#STAGE_KEYS[@]}"

reconcile_checkpoints() {
    local i key verifier gap=false

    # Checkpoints must form a valid prefix. If a completed stage no longer
    # verifies, that stage and every dependent stage after it are invalidated.
    for (( i=0; i<TOTAL_STAGES; i++ )); do
        key="${STAGE_KEYS[$i]}"
        verifier="${STAGE_VERIFIERS[$i]}"

        if stage_is_marked "$key"; then
            if [[ "$gap" == true ]]; then
                log_warn "Non-contiguous checkpoint state detected. Resuming from step $((i + 1))."
                rewrite_state_prefix "$i"
                break
            fi

            if ! "$verifier"; then
                log_warn "Saved checkpoint for step $((i + 1)) no longer verifies: ${STAGE_TITLES[$i]}"
                log_warn "This step and all following dependent steps will run again."
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
        stage_is_marked "${STAGE_KEYS[$i]}" && count=$(( count + 1 ))
    done
    printf '%d' "$count"
}

show_status() {
    local i key title verifier status
    printf '\nMarzban Node Installer v%s\n' "$INSTALLER_VERSION"
    printf 'State directory: %s\n\n' "$STATE_DIR"

    for (( i=0; i<TOTAL_STAGES; i++ )); do
        key="${STAGE_KEYS[$i]}"
        title="${STAGE_TITLES[$i]}"
        verifier="${STAGE_VERIFIERS[$i]}"

        if stage_is_marked "$key"; then
            if "$verifier"; then
                status="DONE"
            else
                status="STALE"
            fi
        else
            status="PENDING"
        fi
        printf '[%02d/%02d] %-8s %s\n' "$((i + 1))" "$TOTAL_STAGES" "$status" "$title"
    done

    if [[ -s "$LAST_ERROR_FILE" ]]; then
        printf '\nLast recorded error:\n'
        cat "$LAST_ERROR_FILE"
    fi
}

run_stage() {
    local index="$1"
    local key="${STAGE_KEYS[$index]}"
    local title="${STAGE_TITLES[$index]}"
    local runner="${STAGE_RUNNERS[$index]}"
    local verifier="${STAGE_VERIFIERS[$index]}"

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
        ui_refresh "DONE"
        return 0
    fi

    ui_refresh "RUNNING"
    "$runner"
    STAGE_PROGRESS=90
    CURRENT_ACTION="Verifying: $title"
    ui_refresh "VERIFYING"

    if ! "$verifier"; then
        fatal "Post-step verification failed: $title"
    fi

    mark_stage_done "$key"
    COMPLETED_COUNT=$(( COMPLETED_COUNT + 1 ))
    "${SUDO[@]}" rm -f -- "$LAST_ERROR_FILE" >/dev/null 2>&1 || true
    STAGE_PROGRESS=100
    CURRENT_ACTION="Completed: $title"
    ui_refresh "DONE"
}

# ==========================================
# Final report
# ==========================================
show_summary() {
    CURRENT_STAGE_KEY="summary"
    CURRENT_STAGE_TITLE="Installation complete"
    CURRENT_STAGE_NUMBER="$TOTAL_STAGES"
    STAGE_PROGRESS=100
    CURRENT_ACTION="Marzban Node is installed and running"
    set_progress_detail "All ${TOTAL_STAGES} steps completed"
    ui_refresh "COMPLETE"
    internal_log OK "Marzban Node installation completed successfully."

    local ip=""
    ip="$(curl -4fsS --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || true)"
    [[ -n "$ip" ]] && internal_log INFO "Public IPv4: $ip"

    if "${SUDO[@]}" test -f "$MARZBAN_NODE_DATA_DIR/ssl_cert.pem"; then
        internal_log INFO "Node ssl_cert.pem exists."
    else
        internal_log WARN "Node ssl_cert.pem has not been generated yet."
    fi

    if [[ -t 1 ]]; then
        ui_refresh "COMPLETE"
        printf '\n'
        sleep 1
        ui_shutdown
    fi
    printf 'Installation completed successfully.\n'
    [[ -n "$ip" ]] && printf 'Public IPv4: %s\n' "$ip"
    printf 'Log file: %s\n' "$RUN_LOG"
}

# ==========================================
# Main
# ==========================================
main() {
    log_info "APT lock policy: wait up to ${APT_LOCK_TIMEOUT}s; never delete dpkg/apt lock files."

    if [[ "$STATUS_ONLY" == true ]]; then
        AUTO_MODE=true
        SETUP_SECURITY=false
        INSTALL_SPEEDTEST=true
        configure_apt_mode
        show_status
        return 0
    fi

    load_or_ask_settings
    configure_apt_mode

    reconcile_checkpoints
    COMPLETED_COUNT="$(count_completed_stages)"
    CURRENT_STAGE_NUMBER=$(( COMPLETED_COUNT + 1 ))
    (( CURRENT_STAGE_NUMBER > TOTAL_STAGES )) && CURRENT_STAGE_NUMBER="$TOTAL_STAGES"
    STAGE_PROGRESS=10
    CURRENT_STAGE_TITLE="Preparing installation"
    CURRENT_ACTION="Automatic mode: Speedtest=ON, UFW=OFF"
    set_progress_detail "No interactive questions"
    ui_init
    ui_refresh "READY"

    local i
    for (( i=0; i<TOTAL_STAGES; i++ )); do
        run_stage "$i"
    done

    show_summary
}

main "$@"
