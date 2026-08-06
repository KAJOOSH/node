#!/usr/bin/env bash
#
# Cloudflare WARP MASQUE Docker Installer
#
# This script:
#   - Installs Docker Engine and Docker Compose on Ubuntu
#   - Disables the host WARP service to protect the host route and SSH session
#   - Runs Cloudflare WARP in an isolated Docker container
#   - Forces the WARP tunnel protocol to MASQUE
#   - Enables full-tunnel mode only inside the container
#   - Exposes a local SOCKS5 proxy on 127.0.0.1:40000
#   - Optionally applies a WARP+ Unlimited license
#   - Verifies WARP connectivity and long-lived SOCKS connections
#
# Important:
#   - The Docker image used by this script is community-maintained, not an
#     official Cloudflare image.
#   - The WARP+ license key is entered interactively, is hidden while typing,
#     and is not written to this script or the Docker Compose file.
#
# Usage:
#   chmod +x install-warp-masque-docker.sh
#   sudo ./install-warp-masque-docker.sh
#

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

INSTALL_DIR="/opt/warp-masque"
CONTAINER_NAME="warp-masque"
HOST_SOCKS_ADDRESS="127.0.0.1"
HOST_SOCKS_PORT="40000"
CONTAINER_SOCKS_PORT="1080"
WARP_IMAGE="caomingjun/warp:latest"

# ---------------------------------------------------------------------------
# Error handling
# ---------------------------------------------------------------------------

on_error() {
    local exit_code=$?
    local line_number=${1:-unknown}

    echo
    echo "ERROR: Installation failed at line ${line_number}."
    echo "Exit code: ${exit_code}"

    if command -v docker >/dev/null 2>&1; then
        echo
        echo "Recent container logs:"
        docker logs --tail 100 "${CONTAINER_NAME}" 2>/dev/null || true
    fi

    exit "${exit_code}"
}

trap 'on_error "$LINENO"' ERR

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

log() {
    echo
    echo "==> $*"
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "ERROR: Run this script as root."
        echo "Example: sudo ./install-warp-masque-docker.sh"
        exit 1
    fi
}

confirm_yes_no() {
    local prompt="$1"
    local default_answer="${2:-no}"
    local answer

    while true; do
        if [[ "${default_answer}" == "yes" ]]; then
            read -r -p "${prompt} [Y/n]: " answer
            answer="${answer:-y}"
        else
            read -r -p "${prompt} [y/N]: " answer
            answer="${answer:-n}"
        fi

        case "${answer,,}" in
            y|yes)
                return 0
                ;;
            n|no)
                return 1
                ;;
            *)
                echo "Please answer yes or no."
                ;;
        esac
    done
}

wait_for_warp_cli() {
    local max_attempts=60
    local attempt

    for attempt in $(seq 1 "${max_attempts}"); do
        if docker exec "${CONTAINER_NAME}" \
            warp-cli --accept-tos status >/dev/null 2>&1; then
            return 0
        fi

        sleep 2
    done

    return 1
}

wait_for_warp_connection() {
    local max_attempts=60
    local attempt
    local status_output

    for attempt in $(seq 1 "${max_attempts}"); do
        status_output="$(
            docker exec "${CONTAINER_NAME}" \
                warp-cli --accept-tos status 2>/dev/null || true
        )"

        if grep -q "Status update: Connected" <<< "${status_output}"; then
            return 0
        fi

        sleep 2
    done

    return 1
}

configure_docker_repository() {
    install -m 0755 -d /etc/apt/keyrings

    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc

    chmod a+r /etc/apt/keyrings/docker.asc

    cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    apt-get update
}

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------

require_root

if [[ ! -f /etc/os-release ]]; then
    echo "ERROR: Unable to detect the operating system."
    exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release

if [[ "${ID:-}" != "ubuntu" ]]; then
    echo "ERROR: This installer currently supports Ubuntu only."
    echo "Detected operating system: ${PRETTY_NAME:-unknown}"
    exit 1
fi

echo "============================================================"
echo " Cloudflare WARP MASQUE Docker Installer"
echo "============================================================"
echo
echo "Operating system: ${PRETTY_NAME}"
echo "Container:        ${CONTAINER_NAME}"
echo "SOCKS5 endpoint:  ${HOST_SOCKS_ADDRESS}:${HOST_SOCKS_PORT}"
echo "Install path:     ${INSTALL_DIR}"

# ---------------------------------------------------------------------------
# Ask whether a WARP+ Unlimited license should be applied
# ---------------------------------------------------------------------------

HAS_LICENSE="no"
WARP_LICENSE=""

echo
if confirm_yes_no "Do you have a WARP+ Unlimited license key?" "no"; then
    HAS_LICENSE="yes"

    while [[ -z "${WARP_LICENSE}" ]]; do
        read -r -s -p "Enter your WARP+ Unlimited license key: " WARP_LICENSE
        echo

        if [[ -z "${WARP_LICENSE}" ]]; then
            echo "The license key cannot be empty."
        fi
    done
else
    echo "Continuing with the standard free WARP account."
fi

# ---------------------------------------------------------------------------
# Install system dependencies
# ---------------------------------------------------------------------------

log "Installing system dependencies"

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    iproute2

# ---------------------------------------------------------------------------
# Install Docker Engine and Docker Compose
# ---------------------------------------------------------------------------

if ! command -v docker >/dev/null 2>&1; then
    log "Installing Docker Engine from the official Docker repository"

    configure_docker_repository

    apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin
else
    log "Docker is already installed"
fi

if ! docker compose version >/dev/null 2>&1; then
    log "Installing the Docker Compose plugin"

    configure_docker_repository
    apt-get install -y docker-compose-plugin
fi

systemctl enable --now docker

echo
docker --version
docker compose version

# ---------------------------------------------------------------------------
# Disable the host WARP service
# ---------------------------------------------------------------------------
#
# Full-tunnel WARP must not run directly on the host because it may replace
# the host default route and interrupt SSH. Full-tunnel mode is enabled only
# inside the isolated container network namespace.
# ---------------------------------------------------------------------------

log "Disabling any WARP service running directly on the host"

if command -v warp-cli >/dev/null 2>&1; then
    warp-cli disconnect >/dev/null 2>&1 || true
fi

if systemctl list-unit-files --type=service 2>/dev/null \
    | grep -q '^warp-svc\.service'; then
    systemctl disable --now warp-svc.service >/dev/null 2>&1 || true
fi

if systemctl list-unit-files --type=service 2>/dev/null \
    | grep -q '^cloudflare-warp\.service'; then
    systemctl disable --now cloudflare-warp.service >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# Prepare the installation directory
# ---------------------------------------------------------------------------

log "Preparing the installation directory"

mkdir -p "${INSTALL_DIR}/data"
chmod 700 "${INSTALL_DIR}/data"

cd "${INSTALL_DIR}"

# ---------------------------------------------------------------------------
# Stop an existing deployment before checking the SOCKS port
# ---------------------------------------------------------------------------

if [[ -f "${INSTALL_DIR}/compose.yaml" ]]; then
    docker compose down >/dev/null 2>&1 || true
fi

if docker container inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# Verify that the selected local SOCKS port is available
# ---------------------------------------------------------------------------

if ss -lntH "sport = :${HOST_SOCKS_PORT}" | grep -q .; then
    echo
    echo "ERROR: TCP port ${HOST_SOCKS_PORT} is already in use."
    ss -lntp "sport = :${HOST_SOCKS_PORT}" || true
    exit 1
fi

# ---------------------------------------------------------------------------
# Create the Docker Compose configuration
# ---------------------------------------------------------------------------
#
# The SOCKS5 proxy is bound only to 127.0.0.1 on the host. It is therefore
# available to local services such as Xray, but it is not exposed publicly.
#
# Persistent WARP registration data is stored under:
#   /opt/warp-masque/data
# ---------------------------------------------------------------------------

log "Creating the Docker Compose configuration"

cat > compose.yaml <<YAML
services:
  warp-masque:
    image: ${WARP_IMAGE}
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped

    ports:
      - "${HOST_SOCKS_ADDRESS}:${HOST_SOCKS_PORT}:${CONTAINER_SOCKS_PORT}/tcp"

    environment:
      WARP_SLEEP: "5"
      GOST_ARGS: "-L :${CONTAINER_SOCKS_PORT}"
      BETA_FIX_HOST_CONNECTIVITY: "1"

    cap_add:
      - NET_ADMIN
      - MKNOD
      - AUDIT_WRITE

    device_cgroup_rules:
      - "c 10:200 rwm"

    sysctls:
      net.ipv6.conf.all.disable_ipv6: "0"
      net.ipv4.conf.all.src_valid_mark: "1"

    volumes:
      - "./data:/var/lib/cloudflare-warp"

    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
YAML

chmod 600 compose.yaml

# ---------------------------------------------------------------------------
# Pull and start the container
# ---------------------------------------------------------------------------

log "Pulling the WARP container image"

docker compose pull

log "Starting the WARP container"

docker compose up -d

# ---------------------------------------------------------------------------
# Wait for warp-cli to become available
# ---------------------------------------------------------------------------

log "Waiting for the WARP service inside the container"

if ! wait_for_warp_cli; then
    echo "ERROR: The WARP service did not become ready."
    docker logs --tail 200 "${CONTAINER_NAME}" || true
    exit 1
fi

# ---------------------------------------------------------------------------
# Create a WARP consumer registration when needed
# ---------------------------------------------------------------------------

if ! docker exec "${CONTAINER_NAME}" \
    warp-cli --accept-tos registration show >/dev/null 2>&1; then

    log "Creating a new WARP registration"

    docker exec "${CONTAINER_NAME}" \
        warp-cli --accept-tos registration new
fi

# ---------------------------------------------------------------------------
# Disconnect before changing registration and tunnel settings
# ---------------------------------------------------------------------------

docker exec "${CONTAINER_NAME}" \
    warp-cli --accept-tos disconnect >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Apply the optional WARP+ Unlimited license
# ---------------------------------------------------------------------------

if [[ "${HAS_LICENSE}" == "yes" ]]; then
    log "Applying the WARP+ Unlimited license"

    docker exec "${CONTAINER_NAME}" \
        warp-cli --accept-tos registration license "${WARP_LICENSE}"

    unset WARP_LICENSE
else
    log "Skipping WARP+ license activation"
fi

# ---------------------------------------------------------------------------
# Force MASQUE as the WARP tunnel protocol
# ---------------------------------------------------------------------------

log "Setting the WARP tunnel protocol to MASQUE"

docker exec "${CONTAINER_NAME}" \
    warp-cli --accept-tos tunnel protocol set MASQUE

# ---------------------------------------------------------------------------
# Enable full-tunnel mode inside the container only
# ---------------------------------------------------------------------------
#
# This command changes routes only inside the container. It does not modify
# the host default route and therefore does not affect the host SSH session.
# ---------------------------------------------------------------------------

log "Enabling full WARP tunnel inside the container"

docker exec "${CONTAINER_NAME}" \
    warp-cli --accept-tos mode warp+doh

# ---------------------------------------------------------------------------
# Connect to Cloudflare WARP
# ---------------------------------------------------------------------------

log "Connecting to Cloudflare WARP"

docker exec "${CONTAINER_NAME}" \
    warp-cli --accept-tos connect

if ! wait_for_warp_connection; then
    echo "ERROR: WARP did not reach the Connected state."
    docker exec "${CONTAINER_NAME}" \
        warp-cli --accept-tos status || true
    docker logs --tail 200 "${CONTAINER_NAME}" || true
    exit 1
fi

# ---------------------------------------------------------------------------
# Display account, connection, mode, and protocol information
# ---------------------------------------------------------------------------

log "Displaying WARP registration information"

docker exec "${CONTAINER_NAME}" \
    warp-cli --accept-tos registration show

log "Displaying WARP connection status"

docker exec "${CONTAINER_NAME}" \
    warp-cli --accept-tos status

log "Displaying WARP mode and tunnel protocol"

docker exec "${CONTAINER_NAME}" \
    warp-cli --accept-tos settings \
    | grep -Ei 'Mode:|WARP tunnel protocol:' || true

# ---------------------------------------------------------------------------
# Verify SOCKS5 traffic through WARP
# ---------------------------------------------------------------------------

log "Testing the local SOCKS5 proxy through Cloudflare WARP"

TRACE_OUTPUT="$(
    curl \
        --silent \
        --show-error \
        --max-time 30 \
        --socks5-hostname "${HOST_SOCKS_ADDRESS}:${HOST_SOCKS_PORT}" \
        https://www.cloudflare.com/cdn-cgi/trace
)"

echo "${TRACE_OUTPUT}" | grep -E '^(ip|colo|warp)=' || true

if ! grep -qE '^warp=(on|plus)$' <<< "${TRACE_OUTPUT}"; then
    echo "ERROR: SOCKS5 traffic is not passing through WARP."
    docker logs --tail 200 "${CONTAINER_NAME}" || true
    exit 1
fi

# ---------------------------------------------------------------------------
# Verify a connection lasting longer than 10 seconds
# ---------------------------------------------------------------------------
#
# The download is deliberately rate-limited. This confirms that the SOCKS5
# endpoint is not using Cloudflare's Local Proxy mode with its separate
# short-request limitation.
# ---------------------------------------------------------------------------

log "Testing a SOCKS5 connection lasting longer than 10 seconds"

START_TIME="$(date +%s)"

curl \
    --silent \
    --show-error \
    --socks5-hostname "${HOST_SOCKS_ADDRESS}:${HOST_SOCKS_PORT}" \
    --limit-rate 64K \
    --max-time 45 \
    "https://speed.cloudflare.com/__down?bytes=1048576" \
    --output /dev/null

END_TIME="$(date +%s)"
ELAPSED_TIME="$((END_TIME - START_TIME))"

echo "Long connection test completed successfully."
echo "Elapsed time: ${ELAPSED_TIME} seconds"

# ---------------------------------------------------------------------------
# Display final container state
# ---------------------------------------------------------------------------

log "Displaying the final Docker container state"

docker ps \
    --filter "name=^/${CONTAINER_NAME}$" \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

# ---------------------------------------------------------------------------
# Print the Xray outbound configuration and management commands
# ---------------------------------------------------------------------------

echo
echo "============================================================"
echo " Installation completed successfully"
echo "============================================================"
echo
echo "SOCKS5 address:    ${HOST_SOCKS_ADDRESS}"
echo "SOCKS5 port:       ${HOST_SOCKS_PORT}"
echo "Tunnel protocol:   MASQUE"
echo "WARP tunnel mode:  Full tunnel inside Docker"
echo "Persistent data:   ${INSTALL_DIR}/data"
echo "License applied:   ${HAS_LICENSE}"
echo
echo "Xray outbound example:"
echo

cat <<JSON
{
  "tag": "warp4",
  "protocol": "socks",
  "settings": {
    "servers": [
      {
        "address": "${HOST_SOCKS_ADDRESS}",
        "port": ${HOST_SOCKS_PORT}
      }
    ]
  }
}
JSON

echo
echo "Useful management commands:"
echo
echo "  cd ${INSTALL_DIR} && docker compose ps"
echo "  cd ${INSTALL_DIR} && docker compose logs --tail 100"
echo "  cd ${INSTALL_DIR} && docker compose restart"
echo "  cd ${INSTALL_DIR} && docker compose pull && docker compose up -d"
echo "  docker exec ${CONTAINER_NAME} warp-cli status"
echo "  docker exec ${CONTAINER_NAME} warp-cli registration show"
echo "  docker exec ${CONTAINER_NAME} warp-cli settings | grep -Ei 'Mode:|protocol'"
echo
