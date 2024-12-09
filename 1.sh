#!/bin/bash

if ! command -v docker &> /dev/null
then
    	sudo apt update
	sudo apt-get update; sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y; sudo DEBIAN_FRONTEND=noninteractive  apt-get install curl socat git -y
	sudo DEBIAN_FRONTEND=noninteractive apt install wget unzip -y
 	sudo curl -fsSL https://get.docker.com | sh
  	sudo DEBIAN_FRONTEND=noninteractive apt install iptables-persistent -y
	#sudo ufw enable -y
	#sudo ufw allow 62050
	#sudo ufw allow 62051
	#sudo ufw allow 22
	#sudo ufw allow 80
 	#sudo ufw allow 443
	#sudo ufw allow from 91.107.178.21
fi

sudo git clone https://github.com/Gozargah/Marzban-node

sudo mkdir -p /var/lib/marzban/assets/
sudo wget -O /var/lib/marzban/assets/geosite.dat https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat
sudo wget -O /var/lib/marzban/assets/geoip.dat https://github.com/v2fly/geoip/releases/latest/download/geoip.dat
sudo wget -O /var/lib/marzban/assets/iran.dat https://github.com/bootmortis/iran-hosted-domains/releases/latest/download/iran.dat

mkdir -p /var/lib/marzban/xray-core && cd /var/lib/marzban/xray-core
sudo wget https://github.com/XTLS/Xray-core/releases/download/v24.11.30/Xray-linux-64.zip
sudo unzip Xray-linux-64.zip;
sudo rm Xray-linux-64.zip;

cd ~/Marzban-node

sudo echo "services:
  marzban-node:
    # build: .
    image: gozargah/marzban-node:v0.3.3
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

DEST_DIR="/usr/local/block-all-except-iran"

mkdir -p "$DEST_DIR"
cd "$DEST_DIR"

FETCH_IPV4_SCRIPT_URL="https://raw.githubusercontent.com/KAJOOSH/node/refs/heads/main/fetch_iran_ips_v4.sh"
FETCH_IPV6_SCRIPT_URL="https://raw.githubusercontent.com/KAJOOSH/node/refs/heads/main/fetch_iran_ips_v6.sh"
BLOCK_SCRIPT_URL="https://raw.githubusercontent.com/KAJOOSH/node/refs/heads/main/block_all_except_iran.sh"

FETCH_IPV4_SCRIPT="$DEST_DIR/fetch_iran_ips_v4.sh"
FETCH_IPV6_SCRIPT="$DEST_DIR/fetch_iran_ips_v6.sh"
BLOCK_SCRIPT="$DEST_DIR/block_all_except_iran.sh"

echo "Downloading scripts from GitHub..."
wget -q -O "$FETCH_IPV4_SCRIPT" "$FETCH_IPV4_SCRIPT_URL"
wget -q -O "$FETCH_IPV6_SCRIPT" "$FETCH_IPV6_SCRIPT_URL"
wget -q -O "$BLOCK_SCRIPT" "$BLOCK_SCRIPT_URL"

chmod +x "$FETCH_IPV4_SCRIPT"
chmod +x "$FETCH_IPV6_SCRIPT"
chmod +x "$BLOCK_SCRIPT"

echo "Running the fetched scripts..."
bash "$FETCH_IPV4_SCRIPT"
bash "$FETCH_IPV6_SCRIPT"
bash "$BLOCK_SCRIPT"

echo "Setting up cron job..."
CRON_JOB="0 0 * * * $FETCH_IPV4_SCRIPT && $FETCH_IPV6_SCRIPT && $BLOCK_SCRIPT >> /var/log/block_all_except_iran.log 2>&1"

(crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -

echo "Setup completed. Cron job installed and scripts executed."

