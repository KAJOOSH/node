#!/bin/bash

# ==========================================
# 🎨 Color definitions
# ==========================================
Color_Off='\033[0m'
Red='\033[0;31m'
Green='\033[0;32m'
Yellow='\033[0;33m'
Blue='\033[0;34m'
Cyan='\033[0;36m'
White='\033[0;37m'

# ==========================================
# 🪵 Logging functions
# ==========================================
log_info()    { echo -e "${Blue}[INFO]${Color_Off} $(date '+%H:%M:%S') - $*"; }
log_warn()    { echo -e "${Yellow}[WARN]${Color_Off} $(date '+%H:%M:%S') - $*"; }
log_error()   { echo -e "${Red}[ERROR]${Color_Off} $(date '+%H:%M:%S') - $*"; }
log_success() { echo -e "${Green}[OK]${Color_Off} $(date '+%H:%M:%S') - $*"; }

# ==========================================
# ⚙️ Command runner with error handling
# ==========================================
run_cmd() {
    local cmd="$*"
    log_info "Running: ${Cyan}${cmd}${Color_Off}"
    eval "$cmd"
    local status=$?
    if [ $status -ne 0 ]; then
        log_error "Command failed with exit code $status: ${cmd}"
        return $status
    else
        log_success "Command executed successfully."
    fi
}

# ==========================================
# 🧠 Choose install mode
# ==========================================
echo -e "${Yellow}Do you want to use noninteractive mode with -y for apt commands? (y/n): ${Color_Off}"
read -r use_auto

if [[ "$use_auto" =~ ^[Yy]$ ]]; then
    APT_PREFIX="DEBIAN_FRONTEND=noninteractive"
    APT_YES="-y"
    log_info "Noninteractive mode enabled."
else
    APT_PREFIX=""
    APT_YES=""
    log_info "Interactive mode enabled."
fi

# ==========================================
# 🔐 Ask about security setup
# ==========================================
echo -e "${Yellow}Do you want to apply UFW security configurations (recommended)? (y/n): ${Color_Off}"
read -r setup_security

# ==========================================
# 🌐 Ask about Speedtest installation
# ==========================================
echo -e "${Yellow}Do you want to install Ookla Speedtest CLI? (y/n): ${Color_Off}"
read -r install_speedtest_choice

# ==========================================
# 🧱 Function: Check & Install UFW
# ==========================================
ensure_ufw_installed() {
    if ! command -v ufw &>/dev/null; then
        log_warn "UFW is not installed. Installing..."
        run_cmd "sudo apt update"
        run_cmd "sudo $APT_PREFIX apt install ufw $APT_YES"
        if command -v ufw &>/dev/null; then
            log_success "UFW successfully installed."
        else
            log_error "Failed to install UFW."
        fi
    else
        log_success "UFW is already installed."
    fi
}

# ==========================================
# 🔒 Function: Configure UFW and firewall rules
# ==========================================
configure_security() {
    ensure_ufw_installed
    log_info "Applying UFW firewall rules..."
    run_cmd "sudo ufw allow from 91.107.178.21"
    run_cmd "sudo ufw allow 22"
    run_cmd "sudo ufw allow 80"
    run_cmd "sudo ufw allow 443"
    run_cmd "sudo ufw allow 5555"
    run_cmd "sudo ufw --force enable"
    log_success "UFW security rules applied successfully."
}

# ==========================================
# 🐳 Function: Install Docker if missing
# ==========================================
install_docker() {
    if ! command -v docker &>/dev/null; then
        log_warn "Docker not found. Installing Docker and dependencies..."
        run_cmd "sudo apt update"
        run_cmd "sudo $APT_PREFIX apt upgrade $APT_YES"
        run_cmd "sudo $APT_PREFIX apt install curl socat git wget unzip $APT_YES"
        run_cmd "sudo curl -fsSL https://get.docker.com | sh"
        log_success "Docker installation completed."
    else
        log_success "Docker already installed."
    fi
}

# ==========================================
# ⚡ Function: Install Speedtest CLI (Ubuntu 24.04+)
# ==========================================
install_speedtest() {
    local ubuntu_version
    ubuntu_version="$(lsb_release -rs 2>/dev/null || echo 0)"

    if ! dpkg --compare-versions "$ubuntu_version" ge 24.04; then
        log_warn "Ubuntu version ($ubuntu_version) is below 24.04. Skipping Speedtest installation."
        return
    fi

    log_info "Installing Ookla Speedtest CLI for Ubuntu $ubuntu_version..."
    run_cmd "sudo $APT_PREFIX apt-get install curl $APT_YES"
    run_cmd "curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | sudo bash"

    if [ -f /etc/apt/sources.list.d/ookla_speedtest-cli.list ]; then
        run_cmd "sudo sed -i 's/noble/jammy/g' /etc/apt/sources.list.d/ookla_speedtest-cli.list"
    else
        log_warn "Ookla repo list file not found at /etc/apt/sources.list.d/ookla_speedtest-cli.list"
    fi

    run_cmd "sudo apt-get update"
    run_cmd "sudo $APT_PREFIX apt-get install speedtest $APT_YES"

    if command -v speedtest &>/dev/null; then
        log_success "Speedtest CLI installed successfully."
    else
        log_error "Speedtest CLI installation failed."
    fi
}

# ==========================================
# 🚀 Function: Setup Marzban Node
# ==========================================
setup_marzban_node() {
    log_info "Cloning Marzban-node repository..."
    run_cmd "sudo git clone https://github.com/Gozargah/Marzban-node"

    log_info "Setting up assets..."
    run_cmd "sudo mkdir -p /var/lib/marzban/assets/"
    run_cmd "sudo wget -O /var/lib/marzban/assets/geosite.dat https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat"
    run_cmd "sudo wget -O /var/lib/marzban/assets/geoip.dat https://github.com/v2fly/geoip/releases/latest/download/geoip.dat"
    run_cmd "sudo wget -O /var/lib/marzban/assets/iran.dat https://github.com/bootmortis/iran-hosted-domains/releases/latest/download/iran.dat"

    log_info "Downloading SSL client certificate..."
    run_cmd "sudo mkdir -p /var/lib/marzban-node/"
    run_cmd "sudo wget -O /var/lib/marzban-node/ssl_client_cert.pem https://github.com/KAJOOSH/node/raw/refs/heads/main/certificate/ssl_client_cert.pem"

    log_info "Downloading and extracting Xray-core..."
    run_cmd "sudo mkdir -p /var/lib/marzban/xray-core && cd /var/lib/marzban/xray-core"
    run_cmd "sudo wget https://github.com/XTLS/Xray-core/releases/download/v25.6.8/Xray-linux-64.zip"
    run_cmd "sudo unzip -o Xray-linux-64.zip"
    run_cmd "sudo rm Xray-linux-64.zip"

    log_info "Generating docker-compose.yml..."
    sudo bash -c 'cat > ~/Marzban-node/docker-compose.yml <<EOF
services:
  marzban-node:
    image: gozargah/marzban-node:latest
    restart: always
    network_mode: host
    environment:
      SSL_CERT_FILE: "/var/lib/marzban-node/ssl_cert.pem"
      SSL_KEY_FILE: "/var/lib/marzban-node/ssl_key.pem"
      SSL_CLIENT_CERT_FILE: "/var/lib/marzban-node/ssl_client_cert.pem"
      XRAY_EXECUTABLE_PATH: "/var/lib/marzban/xray-core/xray"
      SERVICE_PROTOCOL: "rest"
    volumes:
      - /var/lib/marzban-node:/var/lib/marzban-node
      - /var/lib/marzban/assets:/usr/local/share/xray
      - /var/lib/marzban:/var/lib/marzban
EOF'

    log_info "Starting Docker Compose..."
    cd ~/Marzban-node || exit
    run_cmd "sudo docker compose down"
    run_cmd "sudo docker compose up -d"

    log_success "Marzban Node setup complete."
}

# ==========================================
# 🧩 Main Execution Flow
# ==========================================
install_docker

if [[ "$setup_security" =~ ^[Yy]$ ]]; then
    configure_security
else
    log_warn "Security configuration skipped by user."
fi

if [[ "$install_speedtest_choice" =~ ^[Yy]$ ]]; then
    install_speedtest
else
    log_warn "Speedtest installation skipped by user."
fi

setup_marzban_node

sleep 5

ip=$(curl -s https://api.ipify.org)
if [[ -n "$ip" ]]; then
    log_success "IP Address: $ip"
else
    log_warn "Could not retrieve external IP."
fi

sudo cat /var/lib/marzban-node/ssl_cert.pem || log_warn "SSL cert not found."

log_success "🎉 Marzban Node is Up and Running successfully."
