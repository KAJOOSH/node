#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

# ==========================================================
# Marzban Node Professional Installer
# Version: 3.0.1
# Target: Ubuntu (systemd-based VPS / VM / bare metal)
# ==========================================================

readonly SCRIPT_VERSION="3.0.1"
readonly XRAY_VERSION="${XRAY_VERSION:-26.3.27}"
readonly TRUSTED_IP="${TRUSTED_IP:-91.107.178.21}"
readonly SERVICE_PORT="${SERVICE_PORT:-62050}"
readonly XRAY_API_PORT="${XRAY_API_PORT:-62051}"
readonly PUBLIC_TCP_PORTS="${PUBLIC_TCP_PORTS:-80 443 5555}"
readonly MARZBAN_NODE_DIR="${MARZBAN_NODE_DIR:-${HOME}/Marzban-node}"
readonly MARZBAN_DATA_DIR="${MARZBAN_DATA_DIR:-/var/lib/marzban}"
readonly MARZBAN_NODE_DATA_DIR="${MARZBAN_NODE_DATA_DIR:-/var/lib/marzban-node}"
readonly XRAY_DIR="${MARZBAN_DATA_DIR}/xray-core"
readonly ASSETS_DIR="${MARZBAN_DATA_DIR}/assets"
readonly CLIENT_CERT_URL="${CLIENT_CERT_URL:-https://github.com/KAJOOSH/node/raw/refs/heads/main/certificate/ssl_client_cert.pem}"
readonly CLIENT_CERT_FILE="${MARZBAN_NODE_DATA_DIR}/ssl_client_cert.pem"
readonly NODE_CERT_FILE="${MARZBAN_NODE_DATA_DIR}/ssl_cert.pem"
readonly NODE_KEY_FILE="${MARZBAN_NODE_DATA_DIR}/ssl_key.pem"
readonly IPV6_SYSCTL_FILE="/etc/sysctl.d/99-marzban-node-disable-ipv6.conf"
readonly UFW_DEFAULT_FILE="/etc/default/ufw"
readonly APT_LOCK_WAIT_SECONDS="${APT_LOCK_WAIT_SECONDS:-900}"
readonly APT_RETRY_DELAY_SECONDS="${APT_RETRY_DELAY_SECONDS:-5}"

# ==========================================================
# Colors / logging
# ==========================================================
if [[ -t 1 ]]; then
    C_RESET='\033[0m'
    C_RED='\033[0;31m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'
    C_BLUE='\033[0;34m'
    C_CYAN='\033[0;36m'
    C_BOLD='\033[1m'
else
    C_RESET=''
    C_RED=''
    C_GREEN=''
    C_YELLOW=''
    C_BLUE=''
    C_CYAN=''
    C_BOLD=''
fi

log_info()    { printf '%b[INFO]%b %s - %s\n' "$C_BLUE" "$C_RESET" "$(date '+%H:%M:%S')" "$*"; }
log_warn()    { printf '%b[WARN]%b %s - %s\n' "$C_YELLOW" "$C_RESET" "$(date '+%H:%M:%S')" "$*"; }
log_error()   { printf '%b[ERROR]%b %s - %s\n' "$C_RED" "$C_RESET" "$(date '+%H:%M:%S')" "$*" >&2; }
log_success() { printf '%b[OK]%b %s - %s\n' "$C_GREEN" "$C_RESET" "$(date '+%H:%M:%S')" "$*"; }

print_header() {
    printf '\n%bMarzban Node Professional Installer v%s%b\n' "$C_BOLD" "$SCRIPT_VERSION" "$C_RESET"
    printf '%s\n\n' '------------------------------------------------------------'
}

cleanup_files=()
cleanup() {
    local item
    for item in "${cleanup_files[@]:-}"; do
        [[ -e "$item" ]] && rm -rf -- "$item" || true
    done
}
trap cleanup EXIT
trap 'rc=$?; log_error "Unexpected failure at line $LINENO (exit $rc): $BASH_COMMAND"; exit "$rc"' ERR

quote_cmd() {
    local arg
    printf '%b' "$C_CYAN"
    for arg in "$@"; do
        printf '%q ' "$arg"
    done
    printf '%b\n' "$C_RESET"
}

run_cmd() {
    log_info "Running command:"
    quote_cmd "$@"
    "$@"
    log_success "Command completed."
}

die() {
    log_error "$*"
    exit 1
}

ask_yes_no() {
    local prompt="$1"
    local answer

    while true; do
        printf '%b%s (y/n): %b' "$C_YELLOW" "$prompt" "$C_RESET"
        if ! IFS= read -r answer; then
            die "Input stream closed while waiting for an answer."
        fi
        case "$answer" in
            [Yy]) return 0 ;;
            [Nn]) return 1 ;;
            *) log_warn "Please enter y or n." ;;
        esac
    done
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# ==========================================================
# Privilege handling
# ==========================================================
if (( EUID == 0 )); then
    SUDO=()
else
    command_exists sudo || die "sudo is required when the script is not run as root."
    SUDO=(sudo)
    run_cmd "${SUDO[@]}" -v
fi

# ==========================================================
# OS / architecture validation
# ==========================================================
[[ -r /etc/os-release ]] || die "/etc/os-release not found. Unsupported operating system."
# shellcheck disable=SC1091
source /etc/os-release

[[ "${ID:-}" == "ubuntu" ]] || die "This installer supports Ubuntu only. Detected: ${PRETTY_NAME:-unknown}."
command_exists systemctl || die "systemd/systemctl is required by this installer."

[[ "$SERVICE_PORT" =~ ^[0-9]+$ ]] || die "SERVICE_PORT must be numeric."
(( SERVICE_PORT >= 1 && SERVICE_PORT <= 65535 )) || die "SERVICE_PORT is out of range: $SERVICE_PORT"
[[ "$XRAY_API_PORT" =~ ^[0-9]+$ ]] || die "XRAY_API_PORT must be numeric."
(( XRAY_API_PORT >= 1 && XRAY_API_PORT <= 65535 )) || die "XRAY_API_PORT is out of range: $XRAY_API_PORT"

case "$(uname -m)" in
    x86_64|amd64)
        XRAY_ARCHIVE="Xray-linux-64.zip"
        ;;
    aarch64|arm64)
        XRAY_ARCHIVE="Xray-linux-arm64-v8a.zip"
        ;;
    *)
        die "Unsupported CPU architecture: $(uname -m)"
        ;;
esac
readonly XRAY_ARCHIVE

# ==========================================================
# User choices
# ==========================================================
AUTO_MODE=false
SETUP_SECURITY=false
INSTALL_SPEEDTEST=false
DISABLE_IPV6=false

collect_choices() {
    if ask_yes_no "Use fully noninteractive APT mode and automatically accept package-manager defaults?"; then
        AUTO_MODE=true
        log_info "Noninteractive APT mode enabled."
    else
        log_info "Interactive APT mode enabled."
    fi

    if ask_yes_no "Apply UFW security configuration?"; then
        SETUP_SECURITY=true
    fi

    if ask_yes_no "Disable IPv6 system-wide if IPv6 is available?"; then
        DISABLE_IPV6=true
    fi

    if ask_yes_no "Install Ookla Speedtest CLI?"; then
        INSTALL_SPEEDTEST=true
    fi
}

# ==========================================================
# APT helpers
# ==========================================================
apt_env=()
apt_yes=()
apt_dpkg_opts=(-o DPkg::Lock::Timeout=600)
APT_UPDATED=false

prepare_apt_mode() {
    if [[ "$AUTO_MODE" == true ]]; then
        apt_env=(
            env
            DEBIAN_FRONTEND=noninteractive
            NEEDRESTART_MODE=a
            APT_LISTCHANGES_FRONTEND=none
            UCF_FORCE_CONFFOLD=1
        )
        apt_yes=(-y)
        apt_dpkg_opts+=(
            -o Dpkg::Options::=--force-confdef
            -o Dpkg::Options::=--force-confold
        )
    fi
}

package_manager_process() {
    # This is only an early warning/wait optimization. The authoritative
    # check remains the apt-get retry loop below because APT uses kernel
    # advisory locks and another process can start between checks.
    ps -eo pid=,comm=,args= 2>/dev/null | awk -v self="$$" -v parent="$PPID" '
        {
            pid=$1; comm=$2;
            if (pid == self || pid == parent) next;
            if (comm == "apt" || comm == "apt-get" || comm == "dpkg" ||
                comm == "dpkg-deb" || comm == "unattended-upgr" ||
                comm == "unattended-upgrade") {
                print;
                exit;
            }
        }
    '
}

wait_for_package_manager_idle() {
    local started now elapsed busy_line last_report=-1
    started="$(date +%s)"

    while busy_line="$(package_manager_process)" && [[ -n "$busy_line" ]]; do
        now="$(date +%s)"
        elapsed=$(( now - started ))

        if (( elapsed >= APT_LOCK_WAIT_SECONDS )); then
            log_error "Timed out after ${APT_LOCK_WAIT_SECONDS}s waiting for another package-manager process."
            log_error "Still active: $busy_line"
            return 1
        fi

        # Report immediately, then roughly every 30 seconds instead of
        # flooding the console every retry interval.
        if (( last_report < 0 || elapsed - last_report >= 30 )); then
            log_warn "Another package-manager process is active; waiting instead of removing lock files."
            log_warn "Active process: $busy_line"
            log_info "APT wait: ${elapsed}s / ${APT_LOCK_WAIT_SECONDS}s"
            last_report=$elapsed
        fi

        sleep "$APT_RETRY_DELAY_SECONDS"
    done
}

apt_lock_error() {
    grep -Eqi \
        'Could not get lock|Unable to lock directory|Unable to acquire the dpkg frontend lock|Could not open lock file|is held by process|another process using it' \
        <<<"$1"
}

dpkg_interrupted_error() {
    grep -Eqi \
        'dpkg was interrupted|you must manually run.*dpkg --configure -a' \
        <<<"$1"
}

repair_interrupted_dpkg() {
    local output rc

    log_warn "dpkg reports an interrupted previous operation; attempting safe recovery with dpkg --configure -a."
    wait_for_package_manager_idle || return 1

    if output="$("${SUDO[@]}" "${apt_env[@]}" dpkg --configure -a 2>&1)"; then
        [[ -n "$output" ]] && printf '%s\n' "$output"
        log_success "Interrupted dpkg state recovered."
        return 0
    else
        rc=$?
        [[ -n "$output" ]] && printf '%s\n' "$output" >&2
        log_error "dpkg recovery failed with exit code $rc."
        return "$rc"
    fi
}

apt_exec() {
    local started now elapsed output rc
    local recovered_dpkg=false
    started="$(date +%s)"

    wait_for_package_manager_idle || return 1

    while true; do
        log_info "Running APT command:"
        quote_cmd "${SUDO[@]}" "${apt_env[@]}" apt-get "${apt_dpkg_opts[@]}" "$@"

        # Keep the apt invocation inside an if-condition so set -e/ERR does
        # not terminate the whole installer before we can classify/retry it.
        if output="$("${SUDO[@]}" "${apt_env[@]}" apt-get "${apt_dpkg_opts[@]}" "$@" 2>&1)"; then
            [[ -n "$output" ]] && printf '%s\n' "$output"
            log_success "APT command completed."
            return 0
        else
            rc=$?
        fi

        now="$(date +%s)"
        elapsed=$(( now - started ))

        if apt_lock_error "$output"; then
            if (( elapsed >= APT_LOCK_WAIT_SECONDS )); then
                [[ -n "$output" ]] && printf '%s\n' "$output" >&2
                log_error "APT lock remained busy for ${APT_LOCK_WAIT_SECONDS}s; giving up safely."
                log_error "Do NOT delete /var/lib/apt/*/lock or /var/lib/dpkg/lock files manually."
                return "$rc"
            fi

            # Print only the useful lock-holder lines where possible.
            log_warn "APT is currently locked by another process. Retrying automatically in ${APT_RETRY_DELAY_SECONDS}s..."
            grep -Ei 'Could not get lock|Unable to lock directory|is held by process' <<<"$output" | head -n 3 >&2 || true
            sleep "$APT_RETRY_DELAY_SECONDS"
            continue
        fi

        if [[ "$recovered_dpkg" == false ]] && dpkg_interrupted_error "$output"; then
            [[ -n "$output" ]] && printf '%s\n' "$output" >&2
            repair_interrupted_dpkg || return "$rc"
            recovered_dpkg=true
            continue
        fi

        [[ -n "$output" ]] && printf '%s\n' "$output" >&2
        log_error "APT command failed with exit code $rc."
        return "$rc"
    done
}

apt_update() {
    if [[ "$APT_UPDATED" == true ]]; then
        return 0
    fi

    apt_exec update
    APT_UPDATED=true
}

apt_install() {
    apt_update
    apt_exec install "${apt_yes[@]}" "$@"
}

apt_remove() {
    apt_update
    apt_exec remove "${apt_yes[@]}" "$@"
}

# ==========================================================
# Download helpers
# ==========================================================
download_atomic() {
    local url="$1"
    local destination="$2"
    local mode="${3:-0644}"
    local tmp

    tmp="$(mktemp)"
    cleanup_files+=("$tmp")

    run_cmd curl \
        --fail \
        --location \
        --silent \
        --show-error \
        --retry 5 \
        --retry-delay 2 \
        --connect-timeout 15 \
        --max-time 300 \
        --output "$tmp" \
        "$url"

    [[ -s "$tmp" ]] || die "Downloaded file is empty: $url"
    run_cmd "${SUDO[@]}" install -D -m "$mode" "$tmp" "$destination"
    rm -f -- "$tmp"
}

# ==========================================================
# Base dependencies
# ==========================================================
install_base_dependencies() {
    log_info "Installing/checking base dependencies..."
    apt_install \
        ca-certificates \
        curl \
        gnupg \
        iproute2 \
        lsb-release \
        openssl \
        procps \
        unzip \
        wget
    log_success "Base dependencies are ready."
}

# ==========================================================
# IPv6 management
# ==========================================================
ipv6_kernel_available() {
    [[ -d /proc/sys/net/ipv6 ]] || return 1
    [[ -e /proc/sys/net/ipv6/conf/all/disable_ipv6 ]] || return 1
    return 0
}

ipv6_has_addresses() {
    command_exists ip || return 1
    ip -6 -o addr show 2>/dev/null | grep -q ' inet6 '
}

has_non_loopback_ipv4() {
    command_exists ip || return 1
    ip -4 -o addr show scope global 2>/dev/null | grep -q ' inet '
}

current_ssh_uses_ipv6() {
    local remote_ip=""
    [[ -n "${SSH_CONNECTION:-}" ]] || return 1
    remote_ip="${SSH_CONNECTION%% *}"
    [[ "$remote_ip" == *:* ]]
}

write_ipv6_sysctl_policy() {
    local tmp
    tmp="$(mktemp)"
    cleanup_files+=("$tmp")

    cat > "$tmp" <<'EOF'
# Managed by Marzban Node installer.
# Disable IPv6 globally. The 'all' setting applies to existing interfaces,
# while 'default' ensures interfaces created later inherit the disabled state.
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

    run_cmd "${SUDO[@]}" install -D -m 0644 "$tmp" "$IPV6_SYSCTL_FILE"
}

apply_ipv6_runtime_policy() {
    # Use direct keys instead of blindly failing the whole `sysctl --system`
    # because some virtualized VPS providers expose IPv6 sysctls read-only.
    local failed=false

    if ! "${SUDO[@]}" sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1; then
        failed=true
    fi
    if ! "${SUDO[@]}" sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1; then
        failed=true
    fi
    if ! "${SUDO[@]}" sysctl -w net.ipv6.conf.lo.disable_ipv6=1 >/dev/null 2>&1; then
        failed=true
    fi

    if [[ "$failed" == true ]]; then
        return 1
    fi

    return 0
}

configure_ufw_ipv6_flag() {
    [[ -f "$UFW_DEFAULT_FILE" ]] || return 0

    if grep -qE '^IPV6=' "$UFW_DEFAULT_FILE"; then
        run_cmd "${SUDO[@]}" sed -i 's/^IPV6=.*/IPV6=no/' "$UFW_DEFAULT_FILE"
    else
        printf '%s\n' 'IPV6=no' | "${SUDO[@]}" tee -a "$UFW_DEFAULT_FILE" >/dev/null
    fi
}

verify_ipv6_disabled() {
    local value

    ipv6_kernel_available || return 0

    value="$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || printf '0')"
    [[ "$value" == "1" ]] || return 1

    if ip -6 -o addr show 2>/dev/null | grep -q ' inet6 '; then
        return 1
    fi

    return 0
}

disable_ipv6_systemwide() {
    if [[ "$DISABLE_IPV6" != true ]]; then
        log_info "IPv6 configuration left unchanged by user choice."
        return 0
    fi

    if ! ipv6_kernel_available; then
        log_success "IPv6 is not available in this kernel; nothing to disable."
        return 0
    fi

    if current_ssh_uses_ipv6; then
        log_warn "The current SSH session is using IPv6. Disabling IPv6 now could disconnect and lock you out."
        log_warn "IPv6 was NOT disabled for safety. Reconnect using IPv4 and run the installer again."
        DISABLE_IPV6=false
        return 0
    fi

    if ! has_non_loopback_ipv4; then
        log_warn "No non-loopback IPv4 address was detected. This server may be IPv6-only."
        log_warn "IPv6 was NOT disabled to avoid making the server unreachable."
        DISABLE_IPV6=false
        return 0
    fi

    if ipv6_has_addresses; then
        log_info "IPv6 addresses detected. Applying system-wide IPv6 disable policy..."
    else
        log_info "IPv6 kernel support exists. Applying persistent disable policy even though no active IPv6 address was detected."
    fi

    write_ipv6_sysctl_policy

    if ! apply_ipv6_runtime_policy; then
        log_warn "This environment does not allow changing one or more IPv6 sysctls at runtime."
        log_warn "Removing the persistent policy so the next reboot cannot unexpectedly change connectivity."
        run_cmd "${SUDO[@]}" rm -f "$IPV6_SYSCTL_FILE"
        DISABLE_IPV6=false
        return 0
    fi

    configure_ufw_ipv6_flag

    if verify_ipv6_disabled; then
        log_success "IPv6 is disabled system-wide and the setting is persistent across reboot."
    else
        log_warn "IPv6 sysctls were written, but IPv6 still appears active on at least one interface."
        log_warn "The host/provider may enforce IPv6 settings outside the guest OS."
    fi
}

reassert_ipv6_policy() {
    [[ "$DISABLE_IPV6" == true ]] || return 0
    ipv6_kernel_available || return 0

    if ! apply_ipv6_runtime_policy; then
        log_warn "Could not re-apply IPv6 policy after a service/network change."
        return 0
    fi

    if verify_ipv6_disabled; then
        log_success "IPv6 disable policy remains active on current and newly-created interfaces."
    else
        log_warn "IPv6 became active on an interface despite the policy; provider-level networking may be overriding it."
    fi
}

# ==========================================================
# UFW firewall
# ==========================================================
ufw_is_active() {
    command_exists ufw && "${SUDO[@]}" ufw status 2>/dev/null | grep -q '^Status: active'
}

ensure_ufw_installed() {
    if ! command_exists ufw; then
        log_warn "UFW is not installed. Installing it..."
        apt_install ufw
    else
        log_success "UFW is already installed."
    fi
}

detect_ssh_port() {
    local port=""

    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        # SSH_CONNECTION: client_ip client_port server_ip server_port
        port="$(awk '{print $4}' <<<"$SSH_CONNECTION" 2>/dev/null || true)"
    fi

    if [[ ! "$port" =~ ^[0-9]+$ ]] && command_exists sshd; then
        port="$("${SUDO[@]}" sshd -T 2>/dev/null | awk '$1 == "port" {print $2; exit}' || true)"
    fi

    [[ "$port" =~ ^[0-9]+$ ]] || port=22
    printf '%s\n' "$port"
}

valid_ipv4_or_ipv6() {
    local value="$1"
    [[ "$value" =~ ^[0-9A-Fa-f:.]+$ ]]
}

configure_security() {
    local ssh_port
    local port

    ensure_ufw_installed
    ssh_port="$(detect_ssh_port)"

    if [[ "$DISABLE_IPV6" == true ]]; then
        configure_ufw_ipv6_flag
    fi

    log_info "Applying UFW rules using least-privilege defaults..."
    run_cmd "${SUDO[@]}" ufw default deny incoming
    run_cmd "${SUDO[@]}" ufw default allow outgoing

    # Prevent accidental SSH lockout, including custom SSH ports.
    run_cmd "${SUDO[@]}" ufw allow "${ssh_port}/tcp" comment 'SSH'

    # Preserve the public ports requested by the original installer.
    # Parse explicitly because the script intentionally uses a strict global IFS.
    local -a public_ports=()
    local old_ifs="$IFS"
    IFS=' ,;' read -r -a public_ports <<< "$PUBLIC_TCP_PORTS"
    IFS="$old_ifs"
    for port in "${public_ports[@]}"; do
        [[ -n "$port" ]] || continue
        [[ "$port" =~ ^[0-9]+$ ]] || die "Invalid TCP port in PUBLIC_TCP_PORTS: $port"
        (( port >= 1 && port <= 65535 )) || die "TCP port out of range in PUBLIC_TCP_PORTS: $port"
        [[ "$port" == "$ssh_port" ]] && continue
        run_cmd "${SUDO[@]}" ufw allow "${port}/tcp"
    done

    # Marzban Node REST must be reachable by the trusted panel, but does not
    # need to be exposed to the whole Internet. Remove the broad legacy rule
    # created by older revisions of this installer, if present.
    valid_ipv4_or_ipv6 "$TRUSTED_IP" || die "TRUSTED_IP contains invalid characters: $TRUSTED_IP"
    if "${SUDO[@]}" ufw --force delete allow from "$TRUSTED_IP" >/dev/null 2>&1; then
        log_info "Removed legacy unrestricted UFW allow rule for $TRUSTED_IP."
    fi
    run_cmd "${SUDO[@]}" ufw allow from "$TRUSTED_IP" to any port "$SERVICE_PORT" proto tcp comment 'Marzban Panel -> Node'

    run_cmd "${SUDO[@]}" ufw --force enable
    run_cmd "${SUDO[@]}" ufw reload

    ufw_is_active || die "UFW was enabled but does not report an active state."
    log_success "UFW is enabled. SSH port $ssh_port is allowed and Node port $SERVICE_PORT is restricted to $TRUSTED_IP."
}

disable_security_if_present() {
    if ! command_exists ufw; then
        log_info "UFW is not installed; nothing to disable."
        return 0
    fi

    if ufw_is_active; then
        log_warn "UFW is active. Disabling it because firewall setup was declined..."
        run_cmd "${SUDO[@]}" ufw --force disable
        log_success "UFW has been disabled."
    else
        log_info "UFW is installed but already inactive."
    fi
}

# ==========================================================
# Docker
# ==========================================================
docker_compose_available() {
    command_exists docker && docker compose version >/dev/null 2>&1
}

ensure_docker_service() {
    # A working daemon is enough; this also supports non-standard installations
    # where Docker is not managed by docker.service.
    if "${SUDO[@]}" docker info >/dev/null 2>&1; then
        return 0
    fi

    if "${SUDO[@]}" systemctl cat docker.service >/dev/null 2>&1; then
        if ! "${SUDO[@]}" systemctl is-enabled docker >/dev/null 2>&1; then
            run_cmd "${SUDO[@]}" systemctl enable docker
        fi
        if ! "${SUDO[@]}" systemctl is-active docker >/dev/null 2>&1; then
            run_cmd "${SUDO[@]}" systemctl start docker
        fi
    fi

    "${SUDO[@]}" docker info >/dev/null 2>&1 || die "Docker is installed, but its daemon is not responding."
}

install_docker() {
    if docker_compose_available; then
        log_success "Docker and Docker Compose are already installed."
        ensure_docker_service
        return 0
    fi

    log_warn "Docker or Docker Compose plugin is missing. Installing Docker using Docker's official convenience installer..."

    local installer
    installer="$(mktemp)"
    cleanup_files+=("$installer")

    run_cmd curl \
        --fail \
        --location \
        --silent \
        --show-error \
        --retry 5 \
        --connect-timeout 15 \
        --max-time 300 \
        --output "$installer" \
        https://get.docker.com

    [[ -s "$installer" ]] || die "Docker installer download was empty."

    if [[ "$AUTO_MODE" == true ]]; then
        run_cmd "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive sh "$installer"
    else
        run_cmd "${SUDO[@]}" sh "$installer"
    fi

    command_exists docker || die "Docker installation failed: docker command not found."
    docker compose version >/dev/null 2>&1 || die "Docker Compose plugin is unavailable after Docker installation."

    ensure_docker_service
    log_success "Docker and Docker Compose are ready."
}

# ==========================================================
# Ookla Speedtest CLI
# ==========================================================
install_speedtest() {
    if command_exists speedtest; then
        log_success "Ookla Speedtest CLI is already installed."
        return 0
    fi

    log_info "Installing official Ookla Speedtest CLI repository and package..."

    # The Python distro package conflicts with Ookla's native `speedtest` package.
    if dpkg-query -W -f='${Status}' speedtest-cli 2>/dev/null | grep -q 'ok installed'; then
        log_warn "Removing conflicting Ubuntu speedtest-cli package first."
        apt_remove speedtest-cli
    fi

    local repo_script
    repo_script="$(mktemp)"
    cleanup_files+=("$repo_script")

    run_cmd curl \
        --fail \
        --location \
        --silent \
        --show-error \
        --retry 5 \
        --connect-timeout 15 \
        --max-time 180 \
        --output "$repo_script" \
        https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh

    [[ -s "$repo_script" ]] || die "Ookla repository installer download was empty."

    if [[ "$AUTO_MODE" == true ]]; then
        run_cmd "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive bash "$repo_script"
    else
        run_cmd "${SUDO[@]}" bash "$repo_script"
    fi

    # Repository setup changed apt metadata.
    APT_UPDATED=false
    apt_install speedtest

    command_exists speedtest || die "Ookla Speedtest CLI installation failed."
    log_success "Ookla Speedtest CLI installed successfully."
}

# ==========================================================
# Marzban directories / old install compatibility
# ==========================================================
prepare_directories() {
    log_info "Preparing Marzban Node directories..."
    run_cmd "${SUDO[@]}" mkdir -p \
        "$MARZBAN_NODE_DIR" \
        "$MARZBAN_NODE_DATA_DIR" \
        "$MARZBAN_DATA_DIR" \
        "$XRAY_DIR" \
        "$ASSETS_DIR"

    # Cert directory must not be world-writable.
    run_cmd "${SUDO[@]}" chmod 0755 "$MARZBAN_NODE_DATA_DIR"
    log_success "Directories are ready."
}

# ==========================================================
# Xray assets
# ==========================================================
install_assets() {
    log_info "Installing/updating Xray assets atomically..."

    download_atomic \
        "https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat" \
        "$ASSETS_DIR/geosite.dat" \
        0644

    download_atomic \
        "https://github.com/v2fly/geoip/releases/latest/download/geoip.dat" \
        "$ASSETS_DIR/geoip.dat" \
        0644

    download_atomic \
        "https://github.com/bootmortis/iran-hosted-domains/releases/latest/download/iran.dat" \
        "$ASSETS_DIR/iran.dat" \
        0644

    [[ -s "$ASSETS_DIR/geosite.dat" ]] || die "geosite.dat is missing after installation."
    [[ -s "$ASSETS_DIR/geoip.dat" ]] || die "geoip.dat is missing after installation."
    [[ -s "$ASSETS_DIR/iran.dat" ]] || die "iran.dat is missing after installation."

    log_success "Xray assets are ready."
}

# ==========================================================
# SSL client certificate from Marzban panel
# ==========================================================
validate_x509_certificate() {
    local file="$1"
    "${SUDO[@]}" openssl x509 -in "$file" -noout >/dev/null 2>&1
}

certificate_not_expired() {
    local file="$1"
    "${SUDO[@]}" openssl x509 -in "$file" -noout -checkend 0 >/dev/null 2>&1
}

install_client_certificate() {
    log_info "Downloading Marzban panel client certificate..."
    download_atomic "$CLIENT_CERT_URL" "$CLIENT_CERT_FILE" 0644

    validate_x509_certificate "$CLIENT_CERT_FILE" || die "Downloaded ssl_client_cert.pem is not a valid X.509 PEM certificate."
    certificate_not_expired "$CLIENT_CERT_FILE" || die "Downloaded ssl_client_cert.pem is expired or not currently valid."

    log_success "ssl_client_cert.pem installed and validated."
}

# ==========================================================
# Xray Core
# ==========================================================
installed_xray_version() {
    local binary="$XRAY_DIR/xray"
    [[ -x "$binary" ]] || return 0
    "$binary" version 2>/dev/null | awk 'NR == 1 {gsub(/^v/, "", $2); print $2}' || true
}

install_xray_core() {
    local current_version
    local zip_tmp
    local extract_dir
    local installed_version

    current_version="$(installed_xray_version)"
    if [[ "$current_version" == "$XRAY_VERSION" ]]; then
        log_success "Xray-core $XRAY_VERSION is already installed."
        return 0
    fi

    log_info "Installing Xray-core v$XRAY_VERSION for $(uname -m)..."

    zip_tmp="$(mktemp --suffix=.zip)"
    extract_dir="$(mktemp -d)"
    cleanup_files+=("$zip_tmp" "$extract_dir")

    run_cmd curl \
        --fail \
        --location \
        --silent \
        --show-error \
        --retry 5 \
        --retry-delay 2 \
        --connect-timeout 15 \
        --max-time 300 \
        --output "$zip_tmp" \
        "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/${XRAY_ARCHIVE}"

    run_cmd unzip -q -o "$zip_tmp" xray -d "$extract_dir"
    [[ -s "$extract_dir/xray" ]] || die "Xray archive did not contain the xray executable."

    run_cmd "${SUDO[@]}" install -m 0755 "$extract_dir/xray" "$XRAY_DIR/xray"

    installed_version="$(installed_xray_version)"
    [[ "$installed_version" == "$XRAY_VERSION" ]] || die "Xray validation failed. Expected $XRAY_VERSION, got ${installed_version:-unknown}."

    log_success "Xray-core $installed_version installed successfully."
}

# ==========================================================
# Docker Compose
# ==========================================================
generate_compose() {
    local compose_file="$MARZBAN_NODE_DIR/docker-compose.yml"
    local tmp
    local timestamp

    log_info "Generating Docker Compose configuration..."
    tmp="$(mktemp)"
    cleanup_files+=("$tmp")

    cat > "$tmp" <<YAML
services:
  marzban-node:
    image: gozargah/marzban-node:latest
    restart: unless-stopped
    network_mode: host
    environment:
      SSL_CERT_FILE: "/var/lib/marzban-node/ssl_cert.pem"
      SSL_KEY_FILE: "/var/lib/marzban-node/ssl_key.pem"
      SSL_CLIENT_CERT_FILE: "/var/lib/marzban-node/ssl_client_cert.pem"
      SERVICE_PROTOCOL: "rest"
      SERVICE_PORT: "${SERVICE_PORT}"
      XRAY_EXECUTABLE_PATH: "/var/lib/marzban/xray-core/xray"
      XRAY_ASSETS_PATH: "/usr/local/share/xray"
      XRAY_API_PORT: "${XRAY_API_PORT}"
    volumes:
      - /var/lib/marzban-node:/var/lib/marzban-node
      - /var/lib/marzban/assets:/usr/local/share/xray:ro
      - /var/lib/marzban:/var/lib/marzban
YAML

    if [[ -f "$compose_file" ]]; then
        timestamp="$(date '+%Y%m%d-%H%M%S')"
        run_cmd "${SUDO[@]}" cp -a "$compose_file" "${compose_file}.bak.${timestamp}"
        log_info "Previous Compose file backed up as ${compose_file}.bak.${timestamp}"
    fi

    run_cmd "${SUDO[@]}" install -D -m 0644 "$tmp" "$compose_file"

    "${SUDO[@]}" docker compose -f "$compose_file" config >/dev/null \
        || die "Generated docker-compose.yml failed Docker Compose validation."

    log_success "Docker Compose configuration is valid."
}

compose() {
    "${SUDO[@]}" docker compose -f "$MARZBAN_NODE_DIR/docker-compose.yml" "$@"
}

container_id() {
    compose ps -q marzban-node 2>/dev/null | head -n1
}

container_is_running() {
    local cid
    cid="$(container_id)"
    [[ -n "$cid" ]] || return 1
    [[ "$("${SUDO[@]}" docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null || true)" == "true" ]]
}

service_port_is_listening() {
    ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:|\\])${SERVICE_PORT}$"
}

node_logs_indicate_ready() {
    compose logs --no-color --tail=120 marzban-node 2>/dev/null \
        | grep -Eq "Node service running on :${SERVICE_PORT}|Uvicorn running on https://[^ ]*:${SERVICE_PORT}"
}

# ==========================================================
# Generated node certificate validation
# ==========================================================
node_cert_files_exist() {
    [[ -s "$NODE_CERT_FILE" && -s "$NODE_KEY_FILE" ]]
}

validate_node_certificate_pair() {
    local cert_hash
    local key_hash

    node_cert_files_exist || return 1

    "${SUDO[@]}" openssl x509 -in "$NODE_CERT_FILE" -noout >/dev/null 2>&1 || return 1
    "${SUDO[@]}" openssl pkey -in "$NODE_KEY_FILE" -noout >/dev/null 2>&1 || return 1
    "${SUDO[@]}" openssl x509 -in "$NODE_CERT_FILE" -noout -checkend 0 >/dev/null 2>&1 || return 1

    cert_hash="$({ "${SUDO[@]}" openssl x509 -in "$NODE_CERT_FILE" -pubkey -noout 2>/dev/null \
        | openssl pkey -pubin -outform DER 2>/dev/null \
        | sha256sum; } | awk '{print $1}')"

    key_hash="$({ "${SUDO[@]}" openssl pkey -in "$NODE_KEY_FILE" -pubout -outform DER 2>/dev/null \
        | sha256sum; } | awk '{print $1}')"

    [[ -n "$cert_hash" && "$cert_hash" == "$key_hash" ]]
}

secure_generated_node_files() {
    [[ -f "$NODE_CERT_FILE" ]] && "${SUDO[@]}" chmod 0644 "$NODE_CERT_FILE" || true
    [[ -f "$NODE_KEY_FILE" ]] && "${SUDO[@]}" chmod 0600 "$NODE_KEY_FILE" || true
}

prepare_existing_node_server_certificate() {
    local timestamp

    if [[ ! -e "$NODE_CERT_FILE" && ! -e "$NODE_KEY_FILE" ]]; then
        log_info "No existing node server certificate/key found; Marzban Node will generate them on first startup."
        return 0
    fi

    if node_cert_files_exist && validate_node_certificate_pair; then
        secure_generated_node_files
        log_success "Existing ssl_cert.pem/ssl_key.pem are valid and matched; preserving them to keep panel trust stable."
        return 0
    fi

    timestamp="$(date '+%Y%m%d-%H%M%S')"
    log_warn "Existing node certificate/key are missing, invalid, expired, or mismatched."

    if [[ -e "$NODE_CERT_FILE" ]]; then
        run_cmd "${SUDO[@]}" mv "$NODE_CERT_FILE" "${NODE_CERT_FILE}.invalid.${timestamp}"
    fi
    if [[ -e "$NODE_KEY_FILE" ]]; then
        run_cmd "${SUDO[@]}" mv "$NODE_KEY_FILE" "${NODE_KEY_FILE}.invalid.${timestamp}"
    fi

    log_warn "Invalid certificate material was backed up. Marzban Node will generate a fresh certificate/key pair."
    log_warn "If this node already exists in the panel, update the panel with the new node certificate shown at the end."
}

print_node_failure_diagnostics() {
    log_error "Marzban Node failed readiness checks."
    printf '\n'
    log_info "Docker Compose status:"
    compose ps || true
    printf '\n'
    log_info "Recent Marzban Node logs:"
    compose logs --tail=150 marzban-node || true
    printf '\n'
    log_info "Listening TCP ports around Marzban Node:"
    "${SUDO[@]}" ss -ltnp 2>/dev/null | grep -E ":(${SERVICE_PORT}|${XRAY_API_PORT})\\b" || true
}

wait_for_node_ready() {
    local timeout_seconds="${NODE_READY_TIMEOUT:-90}"
    local elapsed=0

    log_info "Waiting for Marzban Node, generated SSL certificate/key, and REST port ${SERVICE_PORT}..."

    while (( elapsed < timeout_seconds )); do
        if container_is_running \
            && node_cert_files_exist \
            && validate_node_certificate_pair \
            && service_port_is_listening \
            && node_logs_indicate_ready; then

            # Avoid a false success when the container is briefly alive in a restart loop.
            sleep 3
            if container_is_running && service_port_is_listening && node_logs_indicate_ready; then
                secure_generated_node_files
                log_success "Marzban Node passed all readiness checks."
                log_success "ssl_cert.pem and ssl_key.pem are available, valid, and cryptographically matched."
                return 0
            fi
        fi

        sleep 2
        elapsed=$((elapsed + 2))
    done

    print_node_failure_diagnostics
    die "Marzban Node did not become healthy within ${timeout_seconds} seconds."
}

start_marzban_node() {
    log_info "Pulling the current Marzban Node image..."
    run_cmd compose pull marzban-node

    log_info "Starting/recreating Marzban Node..."
    run_cmd compose up -d --remove-orphans --force-recreate marzban-node

    wait_for_node_ready
}

# ==========================================================
# Final verification / report
# ==========================================================
public_ipv4() {
    curl -4fsS --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || true
}

public_ipv6() {
    curl -6fsS --connect-timeout 5 --max-time 10 https://api64.ipify.org 2>/dev/null || true
}

show_summary() {
    local ipv4
    local ipv6
    local xray_version

    ipv4="$(public_ipv4)"
    ipv6="$(public_ipv6)"
    xray_version="$(installed_xray_version)"

    printf '\n'
    printf '%s\n' '============================================================'
    log_success "Marzban Node installation completed successfully."
    log_info "Installer version: $SCRIPT_VERSION"
    log_info "Marzban Node directory: $MARZBAN_NODE_DIR"
    log_info "REST service port: $SERVICE_PORT"
    log_info "Xray API port: $XRAY_API_PORT"
    log_info "Xray-core version: ${xray_version:-unknown}"

    if [[ -n "$ipv4" ]]; then
        log_success "Public IPv4: $ipv4"
    else
        log_warn "Could not determine public IPv4 using api.ipify.org."
    fi

    if [[ "$DISABLE_IPV6" == true ]]; then
        if verify_ipv6_disabled; then
            log_success "IPv6 status: disabled system-wide (persistent)."
        else
            log_warn "IPv6 was requested disabled but final verification was inconclusive."
        fi
    elif [[ -n "$ipv6" ]]; then
        log_info "Public IPv6: $ipv6"
    else
        log_info "Public IPv6: unavailable/not detected."
    fi

    if ufw_is_active; then
        log_success "UFW status: active."
    else
        log_info "UFW status: inactive/not installed."
    fi

    log_success "Node SSL certificate is present and matches its private key."
    printf '\n%bNode certificate (paste this into the Marzban panel when required):%b\n' "$C_BOLD" "$C_RESET"
    "${SUDO[@]}" cat "$NODE_CERT_FILE"

    printf '\n'
    log_info "Docker Compose status:"
    compose ps
    printf '%s\n' '============================================================'
}

# ==========================================================
# Main
# ==========================================================
main() {
    print_header
    collect_choices
    prepare_apt_mode

    install_base_dependencies
    prepare_directories

    # Apply before Docker/network-created interfaces; `default` also covers
    # interfaces that may be created later.
    disable_ipv6_systemwide

    install_docker
    reassert_ipv6_policy

    if [[ "$SETUP_SECURITY" == true ]]; then
        configure_security
    else
        disable_security_if_present
    fi

    if [[ "$INSTALL_SPEEDTEST" == true ]]; then
        install_speedtest
    else
        log_info "Speedtest installation skipped."
    fi

    install_assets
    install_client_certificate
    install_xray_core
    prepare_existing_node_server_certificate
    generate_compose
    start_marzban_node

    # Docker and Xray can create interfaces after the first IPv6 pass.
    reassert_ipv6_policy

    show_summary
}

main "$@"
