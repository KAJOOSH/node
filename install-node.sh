#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ==========================================
# Marzban Node Installer - Resumable Edition
# ==========================================

readonly INSTALLER_VERSION="2.0.0"
readonly XRAY_VERSION="${XRAY_VERSION:-26.3.27}"
readonly TRUSTED_IP="${TRUSTED_IP:-91.107.178.21}"
readonly MARZBAN_NODE_DIR="${MARZBAN_NODE_DIR:-${HOME}/Marzban-node}"
readonly MARZBAN_DATA_DIR="/var/lib/marzban"
readonly MARZBAN_NODE_DATA_DIR="/var/lib/marzban-node"
readonly XRAY_DIR="${MARZBAN_DATA_DIR}/xray-core"
readonly ASSETS_DIR="${MARZBAN_DATA_DIR}/assets"
readonly CLIENT_CERT_URL="https://github.com/KAJOOSH/node/raw/refs/heads/main/certificate/ssl_client_cert.pem"
readonly CLIENT_CERT_FILE="${MARZBAN_NODE_DATA_DIR}/ssl_client_cert.pem"

readonly STATE_DIR="${INSTALLER_STATE_DIR:-/var/lib/marzban-node-installer}"
readonly STATE_FILE="${STATE_DIR}/completed.stages"
readonly SETTINGS_FILE="${STATE_DIR}/settings.conf"
readonly LAST_ERROR_FILE="${STATE_DIR}/last-error.txt"
readonly RUN_LOCK_FILE="/run/lock/marzban-node-installer.lock"

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
STATUS_ONLY=false

# ==========================================
# Colors and logging
# ==========================================
if [[ -t 1 ]]; then
    C_RESET='\033[0m'
    C_RED='\033[0;31m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'
    C_BLUE='\033[0;34m'
    C_CYAN='\033[0;36m'
    C_MAGENTA='\033[0;35m'
    C_DIM='\033[2m'
else
    C_RESET=''
    C_RED=''
    C_GREEN=''
    C_YELLOW=''
    C_BLUE=''
    C_CYAN=''
    C_MAGENTA=''
    C_DIM=''
fi

log_info()    { printf '%b[INFO]%b %s - %s\n' "$C_BLUE" "$C_RESET" "$(date '+%H:%M:%S')" "$*"; }
log_warn()    { printf '%b[WARN]%b %s - %s\n' "$C_YELLOW" "$C_RESET" "$(date '+%H:%M:%S')" "$*"; }
log_error()   { printf '%b[ERROR]%b %s - %s\n' "$C_RED" "$C_RESET" "$(date '+%H:%M:%S')" "$*" >&2; }
log_success() { printf '%b[OK]%b %s - %s\n' "$C_GREEN" "$C_RESET" "$(date '+%H:%M:%S')" "$*"; }

cleanup_files=()
cleanup() {
    local f
    for f in "${cleanup_files[@]:-}"; do
        [[ -e "$f" ]] && rm -rf -- "$f" || true
    done
}
trap cleanup EXIT

quote_cmd() {
    local arg
    printf '%b' "$C_CYAN"
    for arg in "$@"; do
        printf '%q ' "$arg"
    done
    printf '%b\n' "$C_RESET"
}

render_progress() {
    local completed="${1:-0}"
    local status="${2:-READY}"
    local label="${3:-$CURRENT_STAGE_TITLE}"
    local width=34
    local percent=0
    local filled=0
    local empty=0
    local fill_bar=""
    local empty_bar=""

    if (( TOTAL_STAGES > 0 )); then
        percent=$(( completed * 100 / TOTAL_STAGES ))
    fi
    (( percent > 100 )) && percent=100

    filled=$(( percent * width / 100 ))
    empty=$(( width - filled ))
    (( filled > 0 )) && printf -v fill_bar '%*s' "$filled" ''
    (( empty > 0 )) && printf -v empty_bar '%*s' "$empty" ''
    fill_bar="${fill_bar// /#}"
    empty_bar="${empty_bar// /-}"

    printf '%b[%s%s]%b %3d%%  %b%-8s%b  %s\n' \
        "$C_MAGENTA" "$fill_bar" "$empty_bar" "$C_RESET" \
        "$percent" "$C_DIM" "$status" "$C_RESET" "$label"
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
    } > "$tmp"
    "${SUDO[@]}" install -m 0644 "$tmp" "$LAST_ERROR_FILE" >/dev/null 2>&1 || true
}

resume_hint() {
    if [[ "$STATE_READY" == true ]]; then
        log_info "Completed stages are saved in: $STATE_FILE"
        log_info "Run the same installer command again; it will resume from the first incomplete stage."
    fi
}

fatal() {
    local message="$*"
    save_last_error "$message"
    log_error "$message"
    if (( TOTAL_STAGES > 0 )); then
        render_progress "$COMPLETED_COUNT" "FAILED" "$CURRENT_STAGE_TITLE"
    fi
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

    local message="Unexpected error (exit $rc) at line $line while running: $command"
    save_last_error "$message"
    log_error "Stage ${CURRENT_STAGE_NUMBER:-0}/${TOTAL_STAGES:-0} failed: $CURRENT_STAGE_TITLE"
    log_error "$message"
    if (( TOTAL_STAGES > 0 )); then
        render_progress "$COMPLETED_COUNT" "FAILED" "$CURRENT_STAGE_TITLE"
    fi
    resume_hint
    exit "$rc"
}
trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

run_cmd() {
    local rc
    log_info "Running command:"
    quote_cmd "$@"

    if "$@"; then
        log_success "Command completed."
        return 0
    else
        rc=$?
        log_error "Command failed with exit code $rc."
        return "$rc"
    fi
}

ask_yes_no() {
    local prompt="$1"
    local answer
    while true; do
        printf '%b%s (y/n): %b' "$C_YELLOW" "$prompt" "$C_RESET"
        read -r answer
        case "$answer" in
            [Yy]) return 0 ;;
            [Nn]) return 1 ;;
            *) log_warn "Please enter y or n." ;;
        esac
    done
}

usage() {
    cat <<EOF_USAGE
Marzban Node Installer v${INSTALLER_VERSION}

Usage:
  $0              Resume normally (default)
  $0 --restart    Clear installer checkpoints/settings and start the workflow again
  $0 --status     Show saved stage status and exit
  $0 --help       Show this help

Environment overrides:
  APT_LOCK_TIMEOUT=1800   Maximum seconds to wait for apt/dpkg locks
  APT_LOCK_POLL=3         Lock polling interval in seconds
  APT_RETRIES=3           Number of apt command attempts
  XRAY_VERSION=26.3.27    Xray-core version
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
[[ -r /etc/os-release ]] || fatal "/etc/os-release not found. Unsupported operating system."
# shellcheck disable=SC1091
source /etc/os-release
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
    run_cmd "${SUDO[@]}" mkdir -p "$STATE_DIR"
    run_cmd "${SUDO[@]}" touch "$STATE_FILE"
    run_cmd "${SUDO[@]}" chmod 0755 "$STATE_DIR"
    run_cmd "${SUDO[@]}" chmod 0644 "$STATE_FILE"
    STATE_READY=true
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

    local saved_auto saved_security saved_speedtest
    saved_auto="$(read_saved_bool AUTO_MODE || true)"
    saved_security="$(read_saved_bool SETUP_SECURITY || true)"
    saved_speedtest="$(read_saved_bool INSTALL_SPEEDTEST || true)"

    [[ -n "$saved_auto" && -n "$saved_security" && -n "$saved_speedtest" ]] || return 1

    AUTO_MODE="$saved_auto"
    SETUP_SECURITY="$saved_security"
    INSTALL_SPEEDTEST="$saved_speedtest"
    return 0
}

load_or_ask_settings() {
    if load_saved_settings; then
        log_info "Resuming with saved installer choices. Use --restart to choose again."
        return 0
    fi

    AUTO_MODE=false
    SETUP_SECURITY=false
    INSTALL_SPEEDTEST=false

    if ask_yes_no "Use fully noninteractive mode and automatically accept package-manager defaults?"; then
        AUTO_MODE=true
        log_info "Fully noninteractive APT mode enabled."
    else
        log_info "Interactive APT mode enabled."
    fi

    if ask_yes_no "Apply UFW security configuration?"; then
        SETUP_SECURITY=true
    fi

    if ask_yes_no "Install Ookla Speedtest CLI?"; then
        INSTALL_SPEEDTEST=true
    fi

    save_settings
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
    local start now elapsed holders last_notice=-999
    start="$(date +%s)"

    while true; do
        holders="$(get_package_manager_lock_holders)"
        if [[ -z "$holders" ]]; then
            if (( last_notice >= 0 )); then
                [[ -t 1 ]] && printf '\n'
                log_success "APT/dpkg lock is free; continuing."
            fi
            return 0
        fi

        now="$(date +%s)"
        elapsed=$(( now - start ))

        if (( elapsed >= APT_LOCK_TIMEOUT )); then
            [[ -t 1 ]] && printf '\n'
            log_error "Timed out after ${APT_LOCK_TIMEOUT}s waiting for apt/dpkg. The lock was NOT removed or forced."
            log_error "Current package-manager process(es):"
            show_lock_holder_details "$holders"
            return 1
        fi

        if [[ -t 1 ]]; then
            printf '\r%b[WAIT]%b apt/dpkg is busy (PID: %s) - %ds/%ds' \
                "$C_YELLOW" "$C_RESET" "$(printf '%s' "$holders" | tr '\n' ',' | sed 's/,$//')" \
                "$elapsed" "$APT_LOCK_TIMEOUT"
            last_notice=$elapsed
        elif (( elapsed - last_notice >= 15 )); then
            log_warn "apt/dpkg is busy; waiting safely (${elapsed}s/${APT_LOCK_TIMEOUT}s). PID(s): $(printf '%s' "$holders" | tr '\n' ' ')"
            last_notice=$elapsed
        fi

        sleep "$APT_LOCK_POLL"
    done
}

repair_dpkg_if_needed() {
    local audit
    audit="$("${SUDO[@]}" dpkg --audit 2>&1 || true)"
    [[ -n "$audit" ]] || return 0

    log_warn "dpkg reports unfinished package configuration; attempting a safe 'dpkg --configure -a'."
    printf '%s\n' "$audit"

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

    log_error "APT command failed after ${APT_RETRIES} attempt(s)."
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

    run_cmd curl -fL --retry 4 --retry-delay 2 --connect-timeout 15 --max-time 180 -o "$tmp" "$url"
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
    apt_update
    apt_install "${BASE_PACKAGES[@]}"
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
    installer="$(mktemp)"
    cleanup_files+=("$installer")
    run_cmd curl -fsSL --retry 4 --retry-delay 2 --connect-timeout 15 --max-time 180 https://get.docker.com -o "$installer"

    # Docker's installer may call apt internally, so wait for unattended-upgrades first.
    wait_for_package_manager
    if [[ "$AUTO_MODE" == true ]]; then
        run_cmd "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive sh "$installer"
    else
        run_cmd "${SUDO[@]}" sh "$installer"
    fi

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

    apt_install ca-certificates curl gnupg apt-transport-https

    local key_tmp
    key_tmp="$(mktemp)"
    cleanup_files+=("$key_tmp")
    run_cmd curl -fsSL --retry 4 --retry-delay 2 --connect-timeout 15 --max-time 180 \
        https://packagecloud.io/ookla/speedtest-cli/gpgkey -o "$key_tmp"
    run_cmd "${SUDO[@]}" gpg --batch --yes --dearmor -o /usr/share/keyrings/ookla-speedtest-archive-keyring.gpg "$key_tmp"

    printf '%s\n' 'deb [signed-by=/usr/share/keyrings/ookla-speedtest-archive-keyring.gpg] https://packagecloud.io/ookla/speedtest-cli/ubuntu/ jammy main' \
        | "${SUDO[@]}" tee /etc/apt/sources.list.d/ookla_speedtest-cli.list >/dev/null

    apt_update
    apt_install speedtest

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
    run_cmd "${SUDO[@]}" mkdir -p "$ASSETS_DIR"

    download_atomic \
        "https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat" \
        "$ASSETS_DIR/geosite.dat"

    download_atomic \
        "https://github.com/v2fly/geoip/releases/latest/download/geoip.dat" \
        "$ASSETS_DIR/geoip.dat"

    download_atomic \
        "https://github.com/bootmortis/iran-hosted-domains/releases/latest/download/iran.dat" \
        "$ASSETS_DIR/iran.dat"

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
    run_cmd "${SUDO[@]}" mkdir -p "$MARZBAN_NODE_DATA_DIR"
    download_atomic "$CLIENT_CERT_URL" "$CLIENT_CERT_FILE" 0644

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

    local zip_tmp extract_dir
    zip_tmp="$(mktemp --suffix=.zip)"
    extract_dir="$(mktemp -d)"
    cleanup_files+=("$zip_tmp" "$extract_dir")

    run_cmd curl -fL --retry 4 --retry-delay 2 --connect-timeout 15 --max-time 300 \
        -o "$zip_tmp" \
        "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/${XRAY_ARCHIVE}"

    run_cmd unzip -q -o "$zip_tmp" xray -d "$extract_dir"
    [[ -s "$extract_dir/xray" ]] || fatal "Xray archive did not contain a valid xray executable."

    run_cmd "${SUDO[@]}" mkdir -p "$XRAY_DIR"
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
    run_cmd "${SUDO[@]}" docker compose -f "$compose_file" pull

    log_info "Starting Marzban Node..."
    run_cmd "${SUDO[@]}" docker compose -f "$compose_file" up -d --remove-orphans

    local attempt
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        if verify_marzban_node_running; then
            log_success "Marzban Node container is running."
            return 0
        fi
        sleep 2
    done

    log_error "Marzban Node did not reach running state. Recent logs:"
    "${SUDO[@]}" docker compose -f "$compose_file" logs --tail=80 marzban-node || true
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

    printf '\n%b===== Step %02d/%02d: %s =====%b\n' \
        "$C_CYAN" "$CURRENT_STAGE_NUMBER" "$TOTAL_STAGES" "$title" "$C_RESET"

    if stage_is_marked "$key"; then
        log_success "Checkpoint verified; this step is already complete."
        render_progress "$COMPLETED_COUNT" "DONE" "$title"
        return 0
    fi

    render_progress "$COMPLETED_COUNT" "RUNNING" "$title"
    "$runner"

    if ! "$verifier"; then
        fatal "Step completed without a command error, but post-step verification failed: $title"
    fi

    mark_stage_done "$key"
    COMPLETED_COUNT=$(( COMPLETED_COUNT + 1 ))
    "${SUDO[@]}" rm -f -- "$LAST_ERROR_FILE" >/dev/null 2>&1 || true
    render_progress "$COMPLETED_COUNT" "DONE" "$title"
    log_success "Step $CURRENT_STAGE_NUMBER/$TOTAL_STAGES completed and checkpointed."
}

# ==========================================
# Final report
# ==========================================
show_summary() {
    local ip=""
    ip="$(curl -4fsS --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || true)"

    printf '\n'
    render_progress "$TOTAL_STAGES" "COMPLETE" "Marzban Node installation"
    log_success "Marzban Node installation completed successfully."
    [[ -n "$ip" ]] && log_success "Public IPv4: $ip" || log_warn "Could not determine public IPv4."

    if "${SUDO[@]}" test -f "$MARZBAN_NODE_DATA_DIR/ssl_cert.pem"; then
        log_info "Node SSL certificate:"
        "${SUDO[@]}" cat "$MARZBAN_NODE_DATA_DIR/ssl_cert.pem"
    else
        log_warn "Node ssl_cert.pem has not been generated yet. Check container logs if it remains missing."
    fi

    printf '\n'
    "${SUDO[@]}" docker compose -f "$MARZBAN_NODE_DIR/docker-compose.yml" ps
    printf '\n'
    log_info "Resume/checkpoint state: $STATE_FILE"
    log_info "Status command: $0 --status"
    log_info "Restart workflow: $0 --restart"
}

# ==========================================
# Main
# ==========================================
main() {
    log_info "Marzban Node Installer v$INSTALLER_VERSION"
    log_info "APT lock policy: wait up to ${APT_LOCK_TIMEOUT}s; never delete dpkg/apt lock files."

    if [[ "$STATUS_ONLY" == true ]]; then
        if ! load_saved_settings; then
            AUTO_MODE=false
            SETUP_SECURITY=false
            INSTALL_SPEEDTEST=false
            log_warn "No saved installer choices were found; status is based on checkpoint presence and safe defaults."
        fi
        configure_apt_mode
        show_status
        return 0
    fi

    load_or_ask_settings
    configure_apt_mode

    reconcile_checkpoints
    COMPLETED_COUNT="$(count_completed_stages)"

    if (( COMPLETED_COUNT > 0 )); then
        log_info "Resume detected: $COMPLETED_COUNT/$TOTAL_STAGES stage(s) already completed and verified."
    fi
    render_progress "$COMPLETED_COUNT" "READY" "Installer progress"

    local i
    for (( i=0; i<TOTAL_STAGES; i++ )); do
        run_stage "$i"
    done

    CURRENT_STAGE_KEY="summary"
    CURRENT_STAGE_TITLE="Final report"
    CURRENT_STAGE_NUMBER="$TOTAL_STAGES"
    show_summary
}

main
