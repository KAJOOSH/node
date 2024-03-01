#!/bin/bash

if ! command -v docker &> /dev/null
then
    	sudo apt update
	sudo apt-get update; sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y; sudo DEBIAN_FRONTEND=noninteractive  apt-get install curl socat git -y
	sudo DEBIAN_FRONTEND=noninteractive apt install wget unzip -y
 	sudo curl -fsSL https://get.docker.com | sh
	sudo ufw disable
fi

sudo git clone https://github.com/Gozargah/Marzban-node

sudo mkdir -p /var/lib/marzban/assets/
sudo wget -O /var/lib/marzban/assets/geosite.dat https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat
sudo wget -O /var/lib/marzban/assets/geoip.dat https://github.com/v2fly/geoip/releases/latest/download/geoip.dat
sudo wget -O /var/lib/marzban/assets/iran.dat https://github.com/bootmortis/iran-hosted-domains/releases/latest/download/iran.dat

mkdir -p /var/lib/marzban/xray-core && cd /var/lib/marzban/xray-core

# Download Xray latest

RELEASE_TAG="latest"

if [[ "$1" ]]; then
    RELEASE_TAG="$1"
fi

check_if_running_as_root() {
    # If you want to run as another user, please modify $EUID to be owned by this user
    if [[ "$EUID" -ne '0' ]]; then
        echo "error: You must run this script as root!"
        exit 1
    fi
}

identify_the_operating_system_and_architecture() {
    if [[ "$(uname)" == 'Linux' ]]; then
        case "$(uname -m)" in
            'i386' | 'i686')
                ARCH='32'
            ;;
            'amd64' | 'x86_64')
                ARCH='64'
            ;;
            'armv5tel')
                ARCH='arm32-v5'
            ;;
            'armv6l')
                ARCH='arm32-v6'
                grep Features /proc/cpuinfo | grep -qw 'vfp' || ARCH='arm32-v5'
            ;;
            'armv7' | 'armv7l')
                ARCH='arm32-v7a'
                grep Features /proc/cpuinfo | grep -qw 'vfp' || ARCH='arm32-v5'
            ;;
            'armv8' | 'aarch64')
                ARCH='arm64-v8a'
            ;;
            'mips')
                ARCH='mips32'
            ;;
            'mipsle')
                ARCH='mips32le'
            ;;
            'mips64')
                ARCH='mips64'
                lscpu | grep -q "Little Endian" && ARCH='mips64le'
            ;;
            'mips64le')
                ARCH='mips64le'
            ;;
            'ppc64')
                ARCH='ppc64'
            ;;
            'ppc64le')
                ARCH='ppc64le'
            ;;
            'riscv64')
                ARCH='riscv64'
            ;;
            's390x')
                ARCH='s390x'
            ;;
            *)
                echo "error: The architecture is not supported."
                exit 1
            ;;
        esac
    else
        echo "error: This operating system is not supported."
        exit 1
    fi
}

download_xray() {
    if [[ "$RELEASE_TAG" == "latest" ]]; then
        DOWNLOAD_LINK="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-$ARCH.zip"
    else
        DOWNLOAD_LINK="https://github.com/XTLS/Xray-core/releases/download/$RELEASE_TAG/Xray-linux-$ARCH.zip"
    fi
    
    echo "Downloading Xray archive: $DOWNLOAD_LINK"
    if ! curl -RL -H 'Cache-Control: no-cache' -o "$ZIP_FILE" "$DOWNLOAD_LINK"; then
        echo 'error: Download failed! Please check your network or try again.'
        return 1
    fi
}

extract_xray() {
    if ! unzip -q "$ZIP_FILE" -d "$TMP_DIRECTORY"; then
        echo 'error: Xray decompression failed.'
        "rm" -rf "$TMP_DIRECTORY"
        echo "removed: $TMP_DIRECTORY"
        exit 1
    fi
    echo "Extracted Xray archive to $TMP_DIRECTORY"
}

place_xray() {
    install -m 755 "${TMP_DIRECTORY}/xray" "/var/lib/marzban/xray-core"
    install -d "/var/lib/marzban/xray-core/"
    install -m 644 "${TMP_DIRECTORY}/geoip.dat" "/var/lib/marzban/xray-core/geoip.dat"
    install -m 644 "${TMP_DIRECTORY}/geosite.dat" "/var/lib/marzban/xray-core/geosite.dat"
    echo "Xray files installed"
}

check_if_running_as_root
identify_the_operating_system_and_architecture

TMP_DIRECTORY="$(mktemp -d)"
ZIP_FILE="${TMP_DIRECTORY}/Xray-linux-$ARCH.zip"

download_xray
extract_xray
place_xray

"rm" -rf "$TMP_DIRECTORY"

cd ~/Marzban-node

sudo echo "services:
  marzban-node:
    # build: .
    image: gozargah/marzban-node:latest
    restart: always
    network_mode: host

    environment:
      SSL_CERT_FILE: "/var/lib/marzban-node/ssl_cert.pem"
      SSL_KEY_FILE: "/var/lib/marzban-node/ssl_key.pem"
      # SSL_CLIENT_CERT_FILE: "/var/lib/marzban-node/ssl_client_cert.pem"
      XRAY_EXECUTABLE_PATH: "/var/lib/marzban/xray-core/xray"
    volumes:
      - /var/lib/marzban-node:/var/lib/marzban-node
      - /var/lib/marzban/assets:/usr/local/share/xray
      - /var/lib/marzban:/var/lib/marzban" > docker-compose.yml

sudo docker compose down && sudo docker compose up -d

sleep 10;

sudo cat /var/lib/marzban-node/ssl_cert.pem

sudo echo -e $'\e[32mMarzban Node is Up and Running successfully.\e[0m'
