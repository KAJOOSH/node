#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ==========================================
# Marzban Node Installer
# ==========================================

readonly XRAY_VERSION="${XRAY_VERSION:-26.3.27}"
readonly TRUSTED_IP="${TRUSTED_IP:-91.107.178.21}"
readonly MARZBAN_NODE_DIR="${MARZBAN_NODE_DIR:-${HOME}/Marzban-node}"
readonly MARZBAN_DATA_DIR="/var/lib/marzban"
readonly MARZBAN_NODE_DATA_DIR="/var/lib/marzban-node"
readonly XRAY_DIR="${MARZBAN_DATA_DIR}/xray-core"
readonly ASSETS_DIR="${MARZBAN_DATA_DIR}/assets"
readonly CLIENT_CERT_URL="https://github.com/KAJOOSH/node/raw/refs/heads/main/certificate/ssl_client_cert.pem"
readonly CLIENT_CERT_FILE="${MARZBAN_NODE_DATA_DIR}/ssl_client_cert.pem"

# ==========================================
# Colors
# ==========================================
if [[ -t 1 ]]; then
    C_RESET='\033[0m'
    C_RED='\033[0;31m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'
    C_BLUE='\033[0;34m'
    C_CYAN='\033[0;36m'
else
    C_RESET=''
    C_RED=''
    C_GREEN=''
    C_YELLOW=''
    C_BLUE=''
    C_CYAN=''
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
trap 'log_error "Unexpected error at line $LINENO while running: $BASH_COMMAND"' ERR

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
        read -r answer
        case "$answer" in
            [Yy]) return 0 ;;
            [Nn]) return 1 ;;
            *) log_warn "Please enter y or n." ;;
        esac
    done
}

# ==========================================
# Privilege handling
# ==========================================
if (( EUID == 0 )); then
    SUDO=()
else
    command -v sudo >/dev/null 2>&1 || die "sudo is required when the script is not run as root."
    SUDO=(sudo)
    run_cmd "${SUDO[@]}" -v
fi

# ==========================================
# OS checks
# ==========================================
[[ -r /etc/os-release ]] || die "/etc/os-release not found. Unsupported operating system."
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "This installer currently supports Ubuntu only. Detected: ${PRETTY_NAME:-unknown}."

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

# ==========================================
# Installation mode
# ==========================================
AUTO_MODE=false
if ask_yes_no "Use fully noninteractive mode and automatically accept package-manager defaults?"; then
    AUTO_MODE=true
    log_info "Fully noninteractive APT mode enabled."
else
    log_info "Interactive APT mode enabled."
fi

if ask_yes_no "Apply UFW security configuration?"; then
    SETUP_SECURITY=true
else
    SETUP_SECURITY=false
fi

if ask_yes_no "Install Ookla Speedtest CLI?"; then
    INSTALL_SPEEDTEST=true
else
    INSTALL_SPEEDTEST=false
fi

# ==========================================
# APT helpers
# ==========================================
apt_env=()
apt_yes=()
apt_dpkg_opts=()

if [[ "$AUTO_MODE" == true ]]; then
    apt_env=(env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a UCF_FORCE_CONFFOLD=1)
    apt_yes=(-y)
    apt_dpkg_opts=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
fi

apt_update() {
    run_cmd "${SUDO[@]}" "${apt_env[@]}" apt-get update
}

apt_install() {
    run_cmd "${SUDO[@]}" "${apt_env[@]}" apt-get install "${apt_yes[@]}" "${apt_dpkg_opts[@]}" "$@"
}

apt_remove() {
    run_cmd "${SUDO[@]}" "${apt_env[@]}" apt-get remove "${apt_yes[@]}" "${apt_dpkg_opts[@]}" "$@"
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
    [[ -s "$tmp" ]] || die "Downloaded file is empty: $url"

    run_cmd "${SUDO[@]}" install -m "$mode" "$tmp" "$destination"
    rm -f -- "$tmp"
}

# ==========================================
# Base dependencies
# ==========================================
install_base_dependencies() {
    log_info "Installing required base packages..."
    apt_update
    apt_install ca-certificates curl git wget unzip gnupg lsb-release
}

# ==========================================
# UFW
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

    ufw_is_active || die "UFW was enabled but does not report an active state."
    log_success "UFW is enabled and security rules are active."
}

disable_security_if_present() {
    if ! command -v ufw >/dev/null 2>&1; then
        log_info "UFW is not installed; nothing to disable."
        return
    fi

    if ufw_is_active; then
        log_warn "UFW exists and is active. Disabling it because security setup was declined..."
        run_cmd "${SUDO[@]}" ufw --force disable
        log_success "UFW has been disabled."
    else
        log_info "UFW is installed but already inactive."
    fi
}

# ==========================================
# Docker
# ==========================================
install_docker() {
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        log_success "Docker and Docker Compose are already installed."
        return
    fi

    log_warn "Docker/Compose not found or incomplete. Installing Docker..."

    local installer
    installer="$(mktemp)"
    cleanup_files+=("$installer")
    run_cmd curl -fsSL --retry 4 --connect-timeout 15 https://get.docker.com -o "$installer"

    if [[ "$AUTO_MODE" == true ]]; then
        run_cmd "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive sh "$installer"
    else
        run_cmd "${SUDO[@]}" sh "$installer"
    fi

    run_cmd "${SUDO[@]}" systemctl enable --now docker
    command -v docker >/dev/null 2>&1 || die "Docker installation failed."
    "${SUDO[@]}" docker compose version >/dev/null 2>&1 || die "Docker Compose plugin is unavailable after installation."
    log_success "Docker and Docker Compose are ready."
}

# ==========================================
# Ookla Speedtest
# ==========================================
install_speedtest() {
    if command -v speedtest >/dev/null 2>&1; then
        log_success "Ookla Speedtest CLI is already installed."
        return
    fi

    local ubuntu_version="${VERSION_ID:-0}"
    if ! dpkg --compare-versions "$ubuntu_version" ge 24.04; then
        log_warn "Ubuntu $ubuntu_version is below 24.04; Speedtest installation was skipped by policy."
        return
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
    run_cmd curl -fsSL --retry 4 --connect-timeout 15 https://packagecloud.io/ookla/speedtest-cli/gpgkey -o "$key_tmp"
    run_cmd "${SUDO[@]}" gpg --batch --yes --dearmor -o /usr/share/keyrings/ookla-speedtest-archive-keyring.gpg "$key_tmp"

    printf '%s\n' 'deb [signed-by=/usr/share/keyrings/ookla-speedtest-archive-keyring.gpg] https://packagecloud.io/ookla/speedtest-cli/ubuntu/ jammy main' \
        | "${SUDO[@]}" tee /etc/apt/sources.list.d/ookla_speedtest-cli.list >/dev/null

    apt_update
    apt_install speedtest

    command -v speedtest >/dev/null 2>&1 || die "Speedtest CLI installation failed."
    log_success "Ookla Speedtest CLI installed successfully."
}

# ==========================================
# Marzban Node repository
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

# ==========================================
# Xray assets
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

# ==========================================
# SSL client certificate
# ==========================================
install_client_certificate() {
    log_info "Installing SSL client certificate..."
    run_cmd "${SUDO[@]}" mkdir -p "$MARZBAN_NODE_DATA_DIR"
    download_atomic "$CLIENT_CERT_URL" "$CLIENT_CERT_FILE" 0644

    if ! "${SUDO[@]}" grep -q -- 'BEGIN CERTIFICATE' "$CLIENT_CERT_FILE"; then
        die "Downloaded SSL client certificate does not look like a PEM certificate."
    fi

    log_success "SSL client certificate installed."
}

# ==========================================
# Xray Core
# ==========================================
install_xray_core() {
    local current_version=""
    local xray_bin="$XRAY_DIR/xray"

    if [[ -x "$xray_bin" ]]; then
        current_version="$($xray_bin version 2>/dev/null | awk 'NR==1 {print $2}' || true)"
    fi

    if [[ "$current_version" == "$XRAY_VERSION" || "$current_version" == "v$XRAY_VERSION" ]]; then
        log_success "Xray-core $XRAY_VERSION is already installed."
        return
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
    [[ -s "$extract_dir/xray" ]] || die "Xray archive did not contain a valid xray executable."

    run_cmd "${SUDO[@]}" mkdir -p "$XRAY_DIR"
    run_cmd "${SUDO[@]}" install -m 0755 "$extract_dir/xray" "$xray_bin"

    local installed_version
    installed_version="$($xray_bin version 2>/dev/null | awk 'NR==1 {print $2}' || true)"
    [[ -n "$installed_version" ]] || die "Installed Xray executable could not be validated."

    log_success "Xray-core installed: $installed_version"
}

# ==========================================
# Docker Compose
# ==========================================
generate_compose() {
    local compose_file="$MARZBAN_NODE_DIR/docker-compose.yml"

    log_info "Generating docker-compose.yml..."
    mkdir -p "$MARZBAN_NODE_DIR"

    if [[ -f "$compose_file" ]]; then
        cp -a "$compose_file" "${compose_file}.bak"
        log_info "Existing compose file backed up to ${compose_file}.bak"
    fi

    cat > "$compose_file" <<'YAML'
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

    run_cmd "${SUDO[@]}" docker compose -f "$compose_file" config -q
    log_success "docker-compose.yml is valid."
}

start_marzban_node() {
    local compose_file="$MARZBAN_NODE_DIR/docker-compose.yml"

    log_info "Pulling the latest Marzban Node image..."
    run_cmd "${SUDO[@]}" docker compose -f "$compose_file" pull

    log_info "Starting Marzban Node..."
    run_cmd "${SUDO[@]}" docker compose -f "$compose_file" up -d --remove-orphans

    local attempt
    for attempt in 1 2 3 4 5; do
        if "${SUDO[@]}" docker compose -f "$compose_file" ps --status running --services 2>/dev/null | grep -qx 'marzban-node'; then
            log_success "Marzban Node container is running."
            return
        fi
        sleep 2
    done

    log_error "Marzban Node did not reach running state. Recent logs:"
    "${SUDO[@]}" docker compose -f "$compose_file" logs --tail=80 marzban-node || true
    die "Marzban Node failed to start correctly."
}

# ==========================================
# Final report
# ==========================================
show_summary() {
    local ip=""
    ip="$(curl -4fsS --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || true)"

    printf '\n'
    log_success "Marzban Node installation completed successfully."
    [[ -n "$ip" ]] && log_success "Public IPv4: $ip" || log_warn "Could not determine public IPv4."

    if [[ -f "$MARZBAN_NODE_DATA_DIR/ssl_cert.pem" ]]; then
        log_info "Node SSL certificate:"
        "${SUDO[@]}" cat "$MARZBAN_NODE_DATA_DIR/ssl_cert.pem"
    else
        log_warn "Node ssl_cert.pem has not been generated yet. Check container logs if it remains missing."
    fi

    printf '\n'
    "${SUDO[@]}" docker compose -f "$MARZBAN_NODE_DIR/docker-compose.yml" ps
}

# ==========================================
# Main
# ==========================================
main() {
    install_base_dependencies
    install_docker

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

    prepare_marzban_repo
    install_assets
    install_client_certificate
    install_xray_core
    generate_compose
    start_marzban_node
    show_summary
}

main "$@"
