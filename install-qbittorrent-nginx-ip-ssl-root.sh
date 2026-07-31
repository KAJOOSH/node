#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# =====================================================================
# qBittorrent-nox + Nginx + Trusted Let's Encrypt IP SSL for Ubuntu
# =====================================================================
#
# This script is idempotent and can be run more than once.
#
# qBittorrent:
#   - Reuses the existing qbittorrent-root.service when it is installed.
#   - Starts the existing service if it is installed but stopped.
#   - Installs or repairs qBittorrent only when required.
#
# Nginx:
#   - Installs Nginx only when it is missing.
#   - Publishes the completed qBittorrent download directory.
#   - Serves the same files over both HTTP port 80 and HTTPS port 443.
#   - Keeps HTTP active; it does not redirect port 80 to HTTPS.
#
# SSL:
#   - Obtains a publicly trusted certificate directly for a public IPv4.
#   - No domain name is required.
#   - Uses Let's Encrypt's required "shortlived" certificate profile.
#   - Uses Certbot 5.4 or newer from the official Snap package.
#   - Configures automatic renewal and automatic Nginx reload.
#
# Requirements:
#   - A stable, globally routable public IPv4 address.
#   - TCP port 80 reachable from the public Internet.
#   - TCP port 443 reachable from the public Internet.
#   - If the server is behind NAT, forward ports 80 and 443 to this host
#     and run with BIND_ADDRESS=0.0.0.0.
#   - Cloud-provider firewalls must also allow TCP 80 and TCP 443.
#
# Run:
#   sudo -i
#   chmod +x install-qbittorrent-nginx-ip-ssl-root.sh
#   ./install-qbittorrent-nginx-ip-ssl-root.sh
#
# Optional environment variables:
#
#   PUBLIC_IP=203.0.113.10
#       Public IPv4 to place in the certificate.
#       When omitted, the script tries to detect it automatically.
#
#   BIND_ADDRESS=203.0.113.10
#       Local address on which Nginx listens.
#       Auto-detected by default. Use 0.0.0.0 behind NAT.
#
#   LETSENCRYPT_EMAIL=admin@example.com
#       Optional Let's Encrypt account email.
#       When omitted, registration is performed without an email address.
#
#   LETSENCRYPT_STAGING=0
#       Set to 1 only for testing. Staging certificates are not trusted.
#       Default 0 obtains a publicly trusted production certificate.
#
#   WEBUI_PORT=8080
#   TORRENT_PORT=49160
#   BASE_DIR=/srv/qbittorrent
#   DOWNLOAD_DIR=/srv/qbittorrent/downloads
#   INCOMPLETE_DIR=/srv/qbittorrent/incomplete
#   WEBUI_USER=admin
#   WEBUI_PASSWORD='YourStrongPassword'
#
# Example for a server behind NAT:
#
#   PUBLIC_IP=198.51.100.20 \
#   BIND_ADDRESS=0.0.0.0 \
#   LETSENCRYPT_EMAIL=admin@example.com \
#   ./install-qbittorrent-nginx-ip-ssl-root.sh
#
# Security notes:
#   - qBittorrent runs as root because this was explicitly requested.
#   - Download listing has no authentication by default.
#   - Anyone who can reach ports 80 or 443 can list and download files.
# =====================================================================

WEBUI_PORT="${WEBUI_PORT:-8080}"
TORRENT_PORT="${TORRENT_PORT:-49160}"

BASE_DIR="${BASE_DIR:-/srv/qbittorrent}"

DOWNLOAD_DIR_WAS_SET=0
INCOMPLETE_DIR_WAS_SET=0

if [[ -n "${DOWNLOAD_DIR+x}" ]]; then
    DOWNLOAD_DIR_WAS_SET=1
fi

if [[ -n "${INCOMPLETE_DIR+x}" ]]; then
    INCOMPLETE_DIR_WAS_SET=1
fi

DOWNLOAD_DIR="${DOWNLOAD_DIR:-${BASE_DIR}/downloads}"
INCOMPLETE_DIR="${INCOMPLETE_DIR:-${BASE_DIR}/incomplete}"

WEBUI_USER="${WEBUI_USER:-admin}"
WEBUI_PASSWORD="${WEBUI_PASSWORD:-}"

PUBLIC_IP="${PUBLIC_IP:-}"
BIND_ADDRESS="${BIND_ADDRESS:-}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
LETSENCRYPT_STAGING="${LETSENCRYPT_STAGING:-0}"

QBT_SERVICE_NAME="qbittorrent-root"
QBT_SERVICE_FILE="/etc/systemd/system/${QBT_SERVICE_NAME}.service"
QBT_CONFIG_DIR="/root/.config/qBittorrent"
QBT_CONFIG_FILE="${QBT_CONFIG_DIR}/qBittorrent.conf"
QBT_CREDENTIAL_FILE="/root/qbittorrent-credentials.txt"

NGINX_SITE_NAME="qbittorrent-downloads"
NGINX_SITE_AVAILABLE="/etc/nginx/sites-available/${NGINX_SITE_NAME}.conf"
NGINX_SITE_ENABLED="/etc/nginx/sites-enabled/${NGINX_SITE_NAME}.conf"
NGINX_ACCESS_LOG="/var/log/nginx/${NGINX_SITE_NAME}.access.log"
NGINX_ERROR_LOG="/var/log/nginx/${NGINX_SITE_NAME}.error.log"

ACME_WEBROOT="/var/www/qbittorrent-acme"
LETSENCRYPT_HOOK_DIR="/etc/letsencrypt/renewal-hooks/deploy"
LETSENCRYPT_RELOAD_HOOK="${LETSENCRYPT_HOOK_DIR}/reload-nginx.sh"

FALLBACK_RENEW_SERVICE="/etc/systemd/system/qbittorrent-ip-cert-renew.service"
FALLBACK_RENEW_TIMER="/etc/systemd/system/qbittorrent-ip-cert-renew.timer"

DOWNLOAD_INFO_FILE="/root/qbittorrent-download-info.txt"
SSL_INFO_FILE="/root/qbittorrent-ip-ssl-info.txt"

API_URL="http://127.0.0.1:${WEBUI_PORT}"
LOCAL_HOST="localhost:${WEBUI_PORT}"

CERTBOT_BIN="/snap/bin/certbot"
CERT_NAME=""
CERT_LIVE_DIR=""
CERT_FULLCHAIN=""
CERT_PRIVATE_KEY=""
CERT_CERT=""
CERT_CHAIN=""

COOKIE_FILE=""
QBT_ACTION="reused"
QBT_VERSION="unknown"
QBT_DISPLAY_USER=""
QBT_DISPLAY_PASSWORD=""
UFW_STATUS="Inactive or not installed"
CERTBOT_VERSION="unknown"
CERTIFICATE_STATUS="unknown"
RENEWAL_SCHEDULER="unknown"

cleanup() {
    if [[ -n "${COOKIE_FILE:-}" && -f "${COOKIE_FILE}" ]]; then
        rm -f "${COOKIE_FILE}"
    fi
}

show_error() {
    local exit_code=$?
    local line_number="$1"

    echo
    echo "================================================================"
    echo "The script failed"
    echo "Line: ${line_number}"
    echo "Exit code: ${exit_code}"
    echo "================================================================"

    if systemctl list-unit-files 2>/dev/null |
        grep -q "^${QBT_SERVICE_NAME}.service"; then
        echo
        echo "Recent qBittorrent service logs:"
        journalctl -u "${QBT_SERVICE_NAME}.service" -n 50 --no-pager || true
    fi

    if command -v nginx >/dev/null 2>&1; then
        echo
        echo "Nginx configuration test:"
        nginx -t || true

        echo
        echo "Recent Nginx service logs:"
        journalctl -u nginx.service -n 60 --no-pager || true
    fi

    if [[ -x "${CERTBOT_BIN}" ]]; then
        echo
        echo "Recent Certbot log:"
        tail -n 60 /var/log/letsencrypt/letsencrypt.log 2>/dev/null || true
    fi

    exit "${exit_code}"
}

trap cleanup EXIT
trap 'show_error "$LINENO"' ERR

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "This script must be run as root."
        echo
        echo "Run:"
        echo "  sudo -i"
        echo "  ./install-qbittorrent-nginx-ip-ssl-root.sh"
        exit 1
    fi
}

validate_port() {
    local port="$1"
    local name="$2"

    if ! [[ "${port}" =~ ^[0-9]+$ ]] ||
        (( port < 1 || port > 65535 )); then
        echo "Invalid ${name}: ${port}"
        exit 1
    fi
}

validate_boolean() {
    local value="$1"
    local name="$2"

    if [[ "${value}" != "0" && "${value}" != "1" ]]; then
        echo "${name} must be either 0 or 1."
        exit 1
    fi
}

is_valid_ipv4() {
    python3 - "$1" <<'PY'
import ipaddress
import sys

try:
    address = ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)

raise SystemExit(0 if address.version == 4 else 1)
PY
}

is_public_ipv4() {
    python3 - "$1" <<'PY'
import ipaddress
import sys

try:
    address = ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)

raise SystemExit(0 if address.version == 4 and address.is_global else 1)
PY
}

package_is_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null |
        grep -q "install ok installed"
}

install_missing_apt_packages() {
    local packages=(
        qbittorrent-nox
        curl
        jq
        openssl
        ca-certificates
        nginx
        snapd
        python3
        iproute2
    )

    local missing=()
    local package

    for package in "${packages[@]}"; do
        if ! package_is_installed "${package}"; then
            missing+=("${package}")
        fi
    done

    if (( ${#missing[@]} == 0 )); then
        echo "All required Ubuntu packages are already installed."
        return
    fi

    echo
    echo "Updating Ubuntu package lists..."
    apt-get update

    echo
    echo "Installing missing Ubuntu packages:"
    printf '  %s\n' "${missing[@]}"

    apt-get install -y "${missing[@]}"
}

detect_public_ipv4() {
    local endpoint
    local detected=""

    if [[ -n "${PUBLIC_IP}" ]]; then
        if ! is_public_ipv4 "${PUBLIC_IP}"; then
            echo "PUBLIC_IP is not a globally routable public IPv4:"
            echo "  ${PUBLIC_IP}"
            exit 1
        fi

        return
    fi

    echo
    echo "Detecting the server's public IPv4 address..."

    for endpoint in \
        "https://api.ipify.org" \
        "https://ipv4.icanhazip.com" \
        "https://ifconfig.co/ip"; do

        detected="$(
            curl \
                -4 \
                --silent \
                --show-error \
                --fail \
                --max-time 10 \
                "${endpoint}" 2>/dev/null |
            tr -d '[:space:]' ||
            true
        )"

        if [[ -n "${detected}" ]] && is_public_ipv4 "${detected}"; then
            PUBLIC_IP="${detected}"
            break
        fi
    done

    if [[ -z "${PUBLIC_IP}" ]]; then
        echo "A public IPv4 address could not be detected."
        echo
        echo "Run the script again with:"
        echo "  PUBLIC_IP=YOUR.PUBLIC.IP.ADDRESS ./install-qbittorrent-nginx-ip-ssl-root.sh"
        exit 1
    fi

    echo "Detected public IPv4: ${PUBLIC_IP}"
}

detect_bind_address() {
    if [[ -n "${BIND_ADDRESS}" ]]; then
        if [[ "${BIND_ADDRESS}" != "0.0.0.0" ]] &&
            ! is_valid_ipv4 "${BIND_ADDRESS}"; then
            echo "BIND_ADDRESS is invalid:"
            echo "  ${BIND_ADDRESS}"
            exit 1
        fi

        return
    fi

    if ip -4 -o address show |
        awk '{print $4}' |
        cut -d/ -f1 |
        grep -Fxq "${PUBLIC_IP}"; then
        BIND_ADDRESS="${PUBLIC_IP}"
    else
        BIND_ADDRESS="0.0.0.0"

        echo
        echo "The public IPv4 is not directly assigned to a local interface."
        echo "Nginx will listen on 0.0.0.0."
        echo
        echo "This is valid only when NAT forwards public TCP ports 80 and 443"
        echo "to this Ubuntu server."
    fi
}

initialize_certificate_paths() {
    local safe_ip

    safe_ip="${PUBLIC_IP//./-}"
    CERT_NAME="qbittorrent-ip-${safe_ip}"
    CERT_LIVE_DIR="/etc/letsencrypt/live/${CERT_NAME}"
    CERT_FULLCHAIN="${CERT_LIVE_DIR}/fullchain.pem"
    CERT_PRIVATE_KEY="${CERT_LIVE_DIR}/privkey.pem"
    CERT_CERT="${CERT_LIVE_DIR}/cert.pem"
    CERT_CHAIN="${CERT_LIVE_DIR}/chain.pem"
}

read_existing_download_paths() {
    local existing_download_dir=""
    local existing_incomplete_dir=""

    if [[ ! -f "${QBT_CREDENTIAL_FILE}" ]]; then
        return
    fi

    if [[ "${DOWNLOAD_DIR_WAS_SET}" -eq 0 ]]; then
        existing_download_dir="$(
            awk '
                /^Download Directory:$/ {
                    if (getline > 0) {
                        print
                        exit
                    }
                }
            ' "${QBT_CREDENTIAL_FILE}"
        )"

        if [[ -n "${existing_download_dir}" ]]; then
            DOWNLOAD_DIR="${existing_download_dir}"
        fi
    fi

    if [[ "${INCOMPLETE_DIR_WAS_SET}" -eq 0 ]]; then
        existing_incomplete_dir="$(
            awk '
                /^Incomplete Download Directory:$/ {
                    if (getline > 0) {
                        print
                        exit
                    }
                }
            ' "${QBT_CREDENTIAL_FILE}"
        )"

        if [[ -n "${existing_incomplete_dir}" ]]; then
            INCOMPLETE_DIR="${existing_incomplete_dir}"
        fi
    fi
}

read_existing_qbittorrent_credentials() {
    if [[ ! -f "${QBT_CREDENTIAL_FILE}" ]]; then
        return
    fi

    QBT_DISPLAY_USER="$(
        awk -F': ' '/^Username: / {print $2; exit}' \
            "${QBT_CREDENTIAL_FILE}"
    )"

    QBT_DISPLAY_PASSWORD="$(
        awk -F': ' '/^Password: / {print $2; exit}' \
            "${QBT_CREDENTIAL_FILE}"
    )"
}

wait_for_qbittorrent_webui() {
    local ready=0

    for _ in $(seq 1 60); do
        if ! systemctl is-active --quiet "${QBT_SERVICE_NAME}.service"; then
            echo "The qBittorrent service stopped unexpectedly."
            journalctl -u "${QBT_SERVICE_NAME}.service" -n 100 --no-pager
            exit 1
        fi

        if curl \
            --silent \
            --fail \
            --max-time 2 \
            -H "Host: ${LOCAL_HOST}" \
            "${API_URL}/" \
            >/dev/null 2>&1; then
            ready=1
            break
        fi

        sleep 1
    done

    if [[ "${ready}" -ne 1 ]]; then
        echo "The qBittorrent Web UI did not start on port ${WEBUI_PORT}."
        journalctl -u "${QBT_SERVICE_NAME}.service" -n 100 --no-pager
        exit 1
    fi
}

get_qbittorrent_version() {
    local version

    version="$(
        qbittorrent-nox --version 2>/dev/null |
        grep -oE '[0-9]+(\.[0-9]+){2,3}' |
        head -n 1 ||
        true
    )"

    if [[ -z "${version}" ]]; then
        version="unknown"
    fi

    printf '%s' "${version}"
}

get_initial_qbittorrent_password() {
    local version="$1"
    local password=""

    if [[ "${version}" != "unknown" ]] &&
        dpkg --compare-versions "${version}" ge "4.6.1"; then
        for _ in $(seq 1 30); do
            password="$(
                journalctl \
                    -u "${QBT_SERVICE_NAME}.service" \
                    --since "10 minutes ago" \
                    --no-pager \
                    -o cat |
                sed -nE \
                    's/^.*A temporary password is provided for this session:[[:space:]]*([^[:space:]]+).*$/\1/p' |
                tail -n 1
            )"

            if [[ -n "${password}" ]]; then
                break
            fi

            sleep 1
        done
    else
        password="adminadmin"
    fi

    printf '%s' "${password}"
}

qbt_api_login() {
    local username="$1"
    local password="$2"

    curl \
        --silent \
        --show-error \
        --cookie-jar "${COOKIE_FILE}" \
        --cookie "${COOKIE_FILE}" \
        -H "Host: ${LOCAL_HOST}" \
        -H "Referer: http://${LOCAL_HOST}/" \
        --data-urlencode "username=${username}" \
        --data-urlencode "password=${password}" \
        "${API_URL}/api/v2/auth/login"
}

qbittorrent_is_ready() {
    command -v qbittorrent-nox >/dev/null 2>&1 &&
        systemctl cat "${QBT_SERVICE_NAME}.service" >/dev/null 2>&1 &&
        systemctl is-active --quiet "${QBT_SERVICE_NAME}.service"
}

try_start_existing_qbittorrent() {
    if ! command -v qbittorrent-nox >/dev/null 2>&1; then
        return 1
    fi

    if ! systemctl cat "${QBT_SERVICE_NAME}.service" >/dev/null 2>&1; then
        return 1
    fi

    if systemctl is-active --quiet "${QBT_SERVICE_NAME}.service"; then
        return 0
    fi

    echo
    echo "An existing qBittorrent service was found but is not running."
    echo "Trying to start it without changing its configuration..."

    systemctl start "${QBT_SERVICE_NAME}.service" || return 1
    sleep 2

    systemctl is-active --quiet "${QBT_SERVICE_NAME}.service"
}

configure_qbittorrent() {
    local legal_argument=""
    local initial_password=""
    local login_response=""
    local preferences_json=""
    local settings_status=""
    local verify_response=""
    local backup_file=""

    QBT_ACTION="installed or repaired"

    echo
    echo "Configuring qBittorrent..."

    if [[ -z "${WEBUI_PASSWORD}" ]]; then
        WEBUI_PASSWORD="$(openssl rand -hex 18)"
    fi

    systemctl stop "${QBT_SERVICE_NAME}.service" 2>/dev/null || true

    pkill -TERM -u 0 -x qbittorrent-nox 2>/dev/null || true
    pkill -TERM -u 0 -x qbittorrent 2>/dev/null || true
    sleep 2
    pkill -KILL -u 0 -x qbittorrent-nox 2>/dev/null || true
    pkill -KILL -u 0 -x qbittorrent 2>/dev/null || true

    install -d -o root -g root -m 0755 "${BASE_DIR}"
    install -d -o root -g root -m 0755 "${DOWNLOAD_DIR}"
    install -d -o root -g root -m 0755 "${INCOMPLETE_DIR}"
    install -d -o root -g root -m 0700 "${QBT_CONFIG_DIR}"

    if [[ -f "${QBT_CONFIG_FILE}" ]]; then
        backup_file="${QBT_CONFIG_FILE}.bak.$(date +%Y%m%d-%H%M%S)"

        echo "Backing up the existing qBittorrent configuration:"
        echo "  ${backup_file}"

        cp -a "${QBT_CONFIG_FILE}" "${backup_file}"

        sed -i -E \
            '/^WebUI\\(Password_PBKDF2|Password_ha1|Password|Username)=/d' \
            "${QBT_CONFIG_FILE}"
    fi

    if qbittorrent-nox --help 2>&1 |
        grep -q -- "--confirm-legal-notice"; then
        legal_argument=" --confirm-legal-notice"
    fi

    cat > "${QBT_SERVICE_FILE}" <<EOF
[Unit]
Description=qBittorrent-nox Root Service
Documentation=https://github.com/qbittorrent/qBittorrent
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
Group=root

Environment=HOME=/root
Environment=LANG=C.UTF-8
Environment=LC_ALL=C.UTF-8

WorkingDirectory=/root
UMask=0022

ExecStart=/usr/bin/qbittorrent-nox --webui-port=${WEBUI_PORT}${legal_argument}

Restart=on-failure
RestartSec=5
TimeoutStopSec=30
KillSignal=SIGINT

LimitNOFILE=65536

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    chmod 0644 "${QBT_SERVICE_FILE}"

    systemctl daemon-reload
    systemctl enable "${QBT_SERVICE_NAME}.service"
    systemctl restart "${QBT_SERVICE_NAME}.service"

    wait_for_qbittorrent_webui

    QBT_VERSION="$(get_qbittorrent_version)"
    initial_password="$(get_initial_qbittorrent_password "${QBT_VERSION}")"

    if [[ -z "${initial_password}" ]]; then
        echo "The initial qBittorrent Web UI password could not be found."
        journalctl -u "${QBT_SERVICE_NAME}.service" -n 100 --no-pager
        exit 1
    fi

    COOKIE_FILE="$(mktemp)"

    login_response="$(qbt_api_login "${WEBUI_USER}" "${initial_password}")"

    if [[ "${login_response}" != "Ok." ]]; then
        echo "Initial qBittorrent API login failed."
        echo "API response: ${login_response}"
        echo "Username: ${WEBUI_USER}"
        echo "Initial password: ${initial_password}"
        exit 1
    fi

    preferences_json="$(
        jq -n \
            --arg webui_address "*" \
            --arg webui_username "${WEBUI_USER}" \
            --arg webui_password "${WEBUI_PASSWORD}" \
            --arg save_path "${DOWNLOAD_DIR}" \
            --arg temp_path "${INCOMPLETE_DIR}" \
            --argjson webui_port "${WEBUI_PORT}" \
            --argjson torrent_port "${TORRENT_PORT}" \
            '{
                web_ui_address: $webui_address,
                web_ui_port: $webui_port,
                web_ui_username: $webui_username,
                web_ui_password: $webui_password,
                web_ui_domain_list: "*",

                save_path: $save_path,
                temp_path_enabled: true,
                temp_path: $temp_path,

                listen_port: $torrent_port,
                random_port: false,

                dht: true,
                pex: true,
                lsd: true,
                upnp: true
            }'
    )"

    settings_status="$(
        curl \
            --silent \
            --show-error \
            --cookie "${COOKIE_FILE}" \
            -H "Host: ${LOCAL_HOST}" \
            -H "Referer: http://${LOCAL_HOST}/" \
            --output /dev/null \
            --write-out "%{http_code}" \
            --data-urlencode "json=${preferences_json}" \
            "${API_URL}/api/v2/app/setPreferences"
    )"

    if [[ "${settings_status}" != "200" ]]; then
        echo "Saving qBittorrent preferences failed."
        echo "HTTP status: ${settings_status}"
        exit 1
    fi

    rm -f "${COOKIE_FILE}"
    COOKIE_FILE="$(mktemp)"
    sleep 1

    verify_response="$(qbt_api_login "${WEBUI_USER}" "${WEBUI_PASSWORD}")"

    if [[ "${verify_response}" != "Ok." ]]; then
        echo "The permanent Web UI password could not be verified."
        echo "API response: ${verify_response}"
        exit 1
    fi

    systemctl restart "${QBT_SERVICE_NAME}.service"
    sleep 2

    if ! systemctl is-active --quiet "${QBT_SERVICE_NAME}.service"; then
        echo "qBittorrent did not start after the final restart."
        journalctl -u "${QBT_SERVICE_NAME}.service" -n 100 --no-pager
        exit 1
    fi

    QBT_DISPLAY_USER="${WEBUI_USER}"
    QBT_DISPLAY_PASSWORD="${WEBUI_PASSWORD}"

    cat > "${QBT_CREDENTIAL_FILE}" <<EOF
qBittorrent Web UI Credentials
========================================

URL: http://${PUBLIC_IP}:${WEBUI_PORT}
Local URL: http://127.0.0.1:${WEBUI_PORT}

Username: ${WEBUI_USER}
Password: ${WEBUI_PASSWORD}

Service: ${QBT_SERVICE_NAME}.service
qBittorrent Version: ${QBT_VERSION}

Download Directory:
${DOWNLOAD_DIR}

Incomplete Download Directory:
${INCOMPLETE_DIR}

Torrent Port:
${TORRENT_PORT}/TCP
${TORRENT_PORT}/UDP
EOF

    chmod 0600 "${QBT_CREDENTIAL_FILE}"
}

install_certbot_snap() {
    local parsed_version=""

    echo
    echo "Installing or updating the official Certbot Snap..."

    systemctl enable --now snapd.socket

    if systemctl list-unit-files 2>/dev/null |
        grep -q '^snapd.service'; then
        systemctl start snapd.service || true
    fi

    timeout 180 snap wait system seed.loaded >/dev/null 2>&1 || true

    if ! snap list core >/dev/null 2>&1; then
        snap install core
    else
        snap refresh core >/dev/null 2>&1 || true
    fi

    if ! snap list certbot >/dev/null 2>&1; then
        snap install --classic certbot
    else
        snap refresh certbot >/dev/null 2>&1 || true
    fi

    if [[ ! -x "${CERTBOT_BIN}" ]]; then
        echo "The Certbot Snap executable was not found:"
        echo "  ${CERTBOT_BIN}"
        exit 1
    fi

    CERTBOT_VERSION="$(
        "${CERTBOT_BIN}" --version 2>/dev/null |
        grep -oE '[0-9]+(\.[0-9]+){1,3}' |
        head -n 1 ||
        true
    )"

    if [[ -z "${CERTBOT_VERSION}" ]]; then
        echo "The installed Certbot version could not be detected."
        exit 1
    fi

    parsed_version="${CERTBOT_VERSION}"

    if ! dpkg --compare-versions "${parsed_version}" ge "5.4"; then
        echo "Certbot 5.4 or newer is required for IP certificates with webroot."
        echo "Installed version: ${CERTBOT_VERSION}"
        exit 1
    fi

    echo "Certbot version: ${CERTBOT_VERSION}"
}

prepare_directories() {
    install -d -o root -g root -m 0755 "${BASE_DIR}"
    install -d -o root -g root -m 0755 "${DOWNLOAD_DIR}"
    install -d -o root -g root -m 0755 "${INCOMPLETE_DIR}"
    install -d -o root -g root -m 0755 "${ACME_WEBROOT}"
    install -d -o root -g root -m 0755 \
        "${ACME_WEBROOT}/.well-known/acme-challenge"

    chmod 0755 "${BASE_DIR}" 2>/dev/null || true
    chmod 0755 "${DOWNLOAD_DIR}"
    chmod 0755 "${ACME_WEBROOT}"
}

write_nginx_common_server_body() {
    cat <<EOF
    server_name ${PUBLIC_IP};

    root "${DOWNLOAD_DIR}";
    charset utf-8;

    access_log ${NGINX_ACCESS_LOG};
    error_log ${NGINX_ERROR_LOG};

    sendfile on;
    tcp_nopush on;

    autoindex on;
    autoindex_exact_size off;
    autoindex_localtime on;

    location ^~ /.well-known/acme-challenge/ {
        root "${ACME_WEBROOT}";
        default_type text/plain;
        allow all;
        try_files \$uri =404;
    }

    location / {
        limit_except GET HEAD {
            deny all;
        }

        try_files \$uri \$uri/ =404;
    }

    location ~ /\. {
        deny all;
    }

    add_header X-Content-Type-Options "nosniff" always;
EOF
}

write_nginx_http_only_config() {
    local http_listen=""

    if [[ "${BIND_ADDRESS}" == "0.0.0.0" ]]; then
        http_listen="listen 80;"
    else
        http_listen="listen ${BIND_ADDRESS}:80;"
    fi

    echo
    echo "Writing the temporary HTTP-only Nginx configuration..."

    {
        echo "server {"
        echo "    ${http_listen}"
        write_nginx_common_server_body
        echo "}"
    } > "${NGINX_SITE_AVAILABLE}"

    ln -sfn "${NGINX_SITE_AVAILABLE}" "${NGINX_SITE_ENABLED}"

    nginx -t
    systemctl enable nginx.service
    systemctl restart nginx.service

    if ! systemctl is-active --quiet nginx.service; then
        echo "Nginx failed to start."
        journalctl -u nginx.service -n 100 --no-pager
        exit 1
    fi
}

write_nginx_https_config() {
    local http_listen=""
    local https_listen=""

    if [[ "${BIND_ADDRESS}" == "0.0.0.0" ]]; then
        http_listen="listen 80;"
        https_listen="listen 443 ssl http2 default_server;"
    else
        http_listen="listen ${BIND_ADDRESS}:80;"
        https_listen="listen ${BIND_ADDRESS}:443 ssl http2;"
    fi

    echo
    echo "Writing the final HTTP and HTTPS Nginx configuration..."

    cat > "${NGINX_SITE_AVAILABLE}" <<EOF
server {
    ${http_listen}
EOF

    write_nginx_common_server_body >> "${NGINX_SITE_AVAILABLE}"

    cat >> "${NGINX_SITE_AVAILABLE}" <<EOF
}

server {
    ${https_listen}

    server_name ${PUBLIC_IP};

    root "${DOWNLOAD_DIR}";
    charset utf-8;

    access_log ${NGINX_ACCESS_LOG};
    error_log ${NGINX_ERROR_LOG};

    ssl_certificate "${CERT_FULLCHAIN}";
    ssl_certificate_key "${CERT_PRIVATE_KEY}";

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:QBT_SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    sendfile on;
    tcp_nopush on;

    autoindex on;
    autoindex_exact_size off;
    autoindex_localtime on;

    location / {
        limit_except GET HEAD {
            deny all;
        }

        try_files \$uri \$uri/ =404;
    }

    location ~ /\. {
        deny all;
    }

    add_header X-Content-Type-Options "nosniff" always;
}
EOF

    ln -sfn "${NGINX_SITE_AVAILABLE}" "${NGINX_SITE_ENABLED}"

    nginx -t
    systemctl enable nginx.service
    systemctl reload nginx.service

    if ! systemctl is-active --quiet nginx.service; then
        echo "Nginx is not active after applying HTTPS."
        journalctl -u nginx.service -n 100 --no-pager
        exit 1
    fi
}

configure_ufw_before_certificate() {
    if ! command -v ufw >/dev/null 2>&1; then
        UFW_STATUS="Not installed"
        return
    fi

    if ! ufw status 2>/dev/null | grep -q "^Status: active"; then
        UFW_STATUS="Inactive"
        return
    fi

    ufw allow 80/tcp >/dev/null
    ufw allow 443/tcp >/dev/null
    ufw allow "${TORRENT_PORT}/tcp" >/dev/null
    ufw allow "${TORRENT_PORT}/udp" >/dev/null

    UFW_STATUS="Active; TCP 80, TCP 443, and torrent ports were opened"
}

certificate_files_exist() {
    [[ -s "${CERT_FULLCHAIN}" && -s "${CERT_PRIVATE_KEY}" ]]
}

certificate_matches_public_ip() {
    if ! certificate_files_exist; then
        return 1
    fi

    openssl x509 \
        -in "${CERT_CERT}" \
        -noout \
        -ext subjectAltName 2>/dev/null |
        grep -Fq "IP Address:${PUBLIC_IP}"
}

certificate_is_currently_valid() {
    certificate_files_exist &&
        openssl x509 \
            -in "${CERT_CERT}" \
            -noout \
            -checkend 3600 >/dev/null 2>&1
}

obtain_or_reuse_ip_certificate() {
    local certbot_arguments=(
        certonly
        --non-interactive
        --agree-tos
        --preferred-profile
        shortlived
        --webroot
        --webroot-path
        "${ACME_WEBROOT}"
        --ip-address
        "${PUBLIC_IP}"
        --cert-name
        "${CERT_NAME}"
        --keep-until-expiring
    )

    if [[ -n "${LETSENCRYPT_EMAIL}" ]]; then
        certbot_arguments+=(
            --email
            "${LETSENCRYPT_EMAIL}"
        )
    else
        certbot_arguments+=(
            --register-unsafely-without-email
        )
    fi

    if [[ "${LETSENCRYPT_STAGING}" == "1" ]]; then
        certbot_arguments+=(--staging)
        CERTIFICATE_STATUS="staging certificate"
    else
        CERTIFICATE_STATUS="publicly trusted production certificate"
    fi

    echo
    echo "Requesting or reusing the Let's Encrypt IP certificate..."
    echo "Certificate IP: ${PUBLIC_IP}"
    echo "Certificate name: ${CERT_NAME}"

    "${CERTBOT_BIN}" "${certbot_arguments[@]}"

    if ! certificate_files_exist; then
        echo "Certbot completed, but the certificate files were not found:"
        echo "  ${CERT_FULLCHAIN}"
        echo "  ${CERT_PRIVATE_KEY}"
        exit 1
    fi

    if ! certificate_matches_public_ip; then
        echo "The issued certificate does not contain the expected IP SAN:"
        echo "  ${PUBLIC_IP}"
        exit 1
    fi

    if ! certificate_is_currently_valid; then
        echo "The issued certificate is not currently valid."
        exit 1
    fi
}

verify_certificate_chain() {
    if [[ "${LETSENCRYPT_STAGING}" == "1" ]]; then
        echo
        echo "Skipping public trust verification because staging mode is enabled."
        return
    fi

    echo
    echo "Verifying the certificate chain against the Ubuntu trust store..."

    openssl verify \
        -CAfile /etc/ssl/certs/ca-certificates.crt \
        -untrusted "${CERT_CHAIN}" \
        "${CERT_CERT}"
}

configure_automatic_renewal() {
    install -d -o root -g root -m 0755 "${LETSENCRYPT_HOOK_DIR}"

    cat > "${LETSENCRYPT_RELOAD_HOOK}" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

/usr/sbin/nginx -t
/usr/bin/systemctl reload nginx.service
EOF

    chmod 0755 "${LETSENCRYPT_RELOAD_HOOK}"

    if systemctl list-unit-files 2>/dev/null |
        grep -q '^snap\.certbot\.renew\.timer'; then

        systemctl enable --now snap.certbot.renew.timer
        RENEWAL_SCHEDULER="snap.certbot.renew.timer"
        return
    fi

    cat > "${FALLBACK_RENEW_SERVICE}" <<EOF
[Unit]
Description=Renew Let's Encrypt IP certificate for qBittorrent downloads
After=network-online.target nginx.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${CERTBOT_BIN} renew --quiet
EOF

    cat > "${FALLBACK_RENEW_TIMER}" <<'EOF'
[Unit]
Description=Run qBittorrent IP certificate renewal twice daily

[Timer]
OnCalendar=*-*-* 00,12:17:00
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF

    chmod 0644 "${FALLBACK_RENEW_SERVICE}" "${FALLBACK_RENEW_TIMER}"

    systemctl daemon-reload
    systemctl enable --now qbittorrent-ip-cert-renew.timer

    RENEWAL_SCHEDULER="qbittorrent-ip-cert-renew.timer"
}

verify_http_and_https_locally() {
    local test_connect_address="127.0.0.1"

    if [[ "${BIND_ADDRESS}" != "0.0.0.0" ]]; then
        test_connect_address="${BIND_ADDRESS}"
    fi

    echo
    echo "Testing the HTTP endpoint locally..."

    curl \
        --silent \
        --show-error \
        --fail \
        --max-time 10 \
        -H "Host: ${PUBLIC_IP}" \
        "http://${test_connect_address}/" \
        >/dev/null

    echo "HTTP local test passed."

    if [[ "${LETSENCRYPT_STAGING}" == "1" ]]; then
        echo
        echo "Testing the HTTPS endpoint with staging trust verification disabled..."

        curl \
            --insecure \
            --silent \
            --show-error \
            --fail \
            --max-time 10 \
            --connect-to "${PUBLIC_IP}:443:${test_connect_address}:443" \
            "https://${PUBLIC_IP}/" \
            >/dev/null
    else
        echo
        echo "Testing the trusted HTTPS endpoint locally..."

        curl \
            --silent \
            --show-error \
            --fail \
            --max-time 10 \
            --connect-to "${PUBLIC_IP}:443:${test_connect_address}:443" \
            "https://${PUBLIC_IP}/" \
            >/dev/null
    fi

    echo "HTTPS local test passed."
}

write_information_files() {
    local not_before=""
    local not_after=""
    local fingerprint=""

    not_before="$(
        openssl x509 \
            -in "${CERT_CERT}" \
            -noout \
            -startdate |
        cut -d= -f2-
    )"

    not_after="$(
        openssl x509 \
            -in "${CERT_CERT}" \
            -noout \
            -enddate |
        cut -d= -f2-
    )"

    fingerprint="$(
        openssl x509 \
            -in "${CERT_CERT}" \
            -noout \
            -fingerprint \
            -sha256 |
        cut -d= -f2-
    )"

    cat > "${DOWNLOAD_INFO_FILE}" <<EOF
qBittorrent Direct Download Information
========================================

HTTP URL:
http://${PUBLIC_IP}/

HTTPS URL:
https://${PUBLIC_IP}/

Published Directory:
${DOWNLOAD_DIR}

Nginx Site:
${NGINX_SITE_AVAILABLE}

Nginx Service:
nginx.service

Authentication:
None

UFW:
${UFW_STATUS}

Security Warning:
Anyone who can reach TCP port 80 or TCP port 443 can list and
download files from ${DOWNLOAD_DIR}.
EOF

    chmod 0600 "${DOWNLOAD_INFO_FILE}"

    cat > "${SSL_INFO_FILE}" <<EOF
qBittorrent Let's Encrypt IP SSL Information
=============================================

Certificate IP:
${PUBLIC_IP}

Certificate Status:
${CERTIFICATE_STATUS}

Certificate Name:
${CERT_NAME}

Certificate Directory:
${CERT_LIVE_DIR}

Full Chain:
${CERT_FULLCHAIN}

Private Key:
${CERT_PRIVATE_KEY}

Not Before:
${not_before}

Not After:
${not_after}

SHA-256 Fingerprint:
${fingerprint}

Certbot Version:
${CERTBOT_VERSION}

Renewal Scheduler:
${RENEWAL_SCHEDULER}

Nginx Reload Hook:
${LETSENCRYPT_RELOAD_HOOK}

HTTP URL:
http://${PUBLIC_IP}/

HTTPS URL:
https://${PUBLIC_IP}/
EOF

    chmod 0600 "${SSL_INFO_FILE}"
}

print_summary() {
    local expiration=""

    expiration="$(
        openssl x509 \
            -in "${CERT_CERT}" \
            -noout \
            -enddate |
        cut -d= -f2-
    )"

    echo
    echo "================================================================"
    echo "Installation and SSL configuration completed successfully"
    echo "================================================================"
    echo
    echo "qBittorrent:"
    echo "  Action: ${QBT_ACTION}"
    echo "  Version: ${QBT_VERSION}"
    echo "  Service: ${QBT_SERVICE_NAME}.service"
    echo "  Status: $(systemctl is-active "${QBT_SERVICE_NAME}.service")"
    echo "  Web UI: http://${PUBLIC_IP}:${WEBUI_PORT}"

    if [[ -n "${QBT_DISPLAY_USER}" ]]; then
        echo "  Username: ${QBT_DISPLAY_USER}"
    fi

    if [[ -n "${QBT_DISPLAY_PASSWORD}" ]]; then
        echo "  Password: ${QBT_DISPLAY_PASSWORD}"
    else
        echo "  Password: unchanged"
        echo "  Credentials file: ${QBT_CREDENTIAL_FILE}"
    fi

    echo
    echo "Direct downloads:"
    echo "  HTTP:  http://${PUBLIC_IP}/"
    echo "  HTTPS: https://${PUBLIC_IP}/"
    echo "  Directory: ${DOWNLOAD_DIR}"
    echo "  Authentication: none"

    echo
    echo "SSL certificate:"
    echo "  Status: ${CERTIFICATE_STATUS}"
    echo "  IP SAN: ${PUBLIC_IP}"
    echo "  Expires: ${expiration}"
    echo "  Certbot: ${CERTBOT_VERSION}"
    echo "  Renewal: ${RENEWAL_SCHEDULER}"

    echo
    echo "Nginx:"
    echo "  Service: nginx.service"
    echo "  Status: $(systemctl is-active nginx.service)"
    echo "  Bind address: ${BIND_ADDRESS}"
    echo "  HTTP port: 80"
    echo "  HTTPS port: 443"
    echo "  Configuration: ${NGINX_SITE_AVAILABLE}"

    echo
    echo "Information files:"
    echo "  ${QBT_CREDENTIAL_FILE}"
    echo "  ${DOWNLOAD_INFO_FILE}"
    echo "  ${SSL_INFO_FILE}"

    echo
    echo "UFW:"
    echo "  ${UFW_STATUS}"

    echo
    echo "================================================================"
    echo "Important:"
    echo "TCP port 80 must remain publicly reachable for automatic renewal."
    echo "The public IPv4 must remain assigned to or forwarded to this server."
    echo "================================================================"
}

require_root

validate_port "${WEBUI_PORT}" "Web UI port"
validate_port "${TORRENT_PORT}" "torrent port"
validate_boolean "${LETSENCRYPT_STAGING}" "LETSENCRYPT_STAGING"

export DEBIAN_FRONTEND=noninteractive

read_existing_download_paths
install_missing_apt_packages

detect_public_ipv4
detect_bind_address
initialize_certificate_paths

if qbittorrent_is_ready; then
    echo
    echo "qBittorrent is already installed and running."
    echo "The existing qBittorrent installation will not be changed."
    QBT_ACTION="reused"
elif try_start_existing_qbittorrent; then
    echo
    echo "The existing qBittorrent service started successfully."
    echo "Its configuration will not be changed."
    QBT_ACTION="reused and started"
else
    configure_qbittorrent
fi

QBT_VERSION="$(get_qbittorrent_version)"
read_existing_qbittorrent_credentials

prepare_directories
configure_ufw_before_certificate
install_certbot_snap

# When a usable certificate already exists, keep HTTPS online while
# Certbot checks whether renewal is required. Otherwise, start with HTTP.
if certificate_matches_public_ip && certificate_is_currently_valid; then
    write_nginx_https_config
else
    write_nginx_http_only_config
fi

obtain_or_reuse_ip_certificate
verify_certificate_chain
write_nginx_https_config
configure_automatic_renewal
verify_http_and_https_locally
write_information_files
print_summary
