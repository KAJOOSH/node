#!/bin/bash

# Reset
Color_Off='\033[0m'       # Text Reset
# Regular Colors
Black='\033[0;30m'        # Black
Red='\033[0;31m'          # Red
Green='\033[0;32m'        # Green
Yellow='\033[0;33m'       # Yellow
Blue='\033[0;34m'         # Blue
Purple='\033[0;35m'       # Purple
Cyan='\033[0;36m'         # Cyan
White='\033[0;37m'        # White

if ! command -v docker &> /dev/null
then
    sudo apt update
	sudo apt-get install -y curl
 	curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | sudo bash
  	sudo sed -i 's/noble/jammy/g' /etc/apt/sources.list.d/ookla_speedtest-cli.list
   	sudo apt-get update
	sudo apt-get install -y speedtest
	sudo apt-get update; sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y; sudo DEBIAN_FRONTEND=noninteractive  apt-get install curl socat git -y
	sudo DEBIAN_FRONTEND=noninteractive apt install wget unzip -y
 	sudo curl -fsSL https://get.docker.com | sh
  
  	 # sudo ufw allow from 91.107.178.21 to any port 62050 proto tcp
    	 # sudo ufw allow from 91.107.178.21 to any port 62051 proto tcp
      	 sudo ufw allow from 91.107.178.21
	 # sudo ufw allow 62050
	 # sudo ufw allow 62051
	 sudo ufw allow 22
	 sudo ufw allow 80
 	 sudo ufw allow 443
   	 sudo ufw allow 5555
  	 sudo ufw --force enable
fi

sudo git clone https://github.com/Gozargah/Marzban-node

sudo mkdir -p /var/lib/marzban/assets/
sudo wget -O /var/lib/marzban/assets/geosite.dat https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat
sudo wget -O /var/lib/marzban/assets/geoip.dat https://github.com/v2fly/geoip/releases/latest/download/geoip.dat
sudo wget -O /var/lib/marzban/assets/iran.dat https://github.com/bootmortis/iran-hosted-domains/releases/latest/download/iran.dat

sudo mkdir -p /var/lib/marzban-node/
sudo wget -O /var/lib/marzban-node/ssl_client_cert.pem https://github.com/KAJOOSH/node/raw/refs/heads/main/certificate/ssl_client_cert.pem

mkdir -p /var/lib/marzban/xray-core && cd /var/lib/marzban/xray-core
sudo wget https://github.com/XTLS/Xray-core/releases/download/v25.6.8/Xray-linux-64.zip
sudo unzip Xray-linux-64.zip;
sudo rm Xray-linux-64.zip;

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
      SSL_CLIENT_CERT_FILE: "/var/lib/marzban-node/ssl_client_cert.pem"
      XRAY_EXECUTABLE_PATH: "/var/lib/marzban/xray-core/xray"
      SERVICE_PROTOCOL: "rest"
    volumes:
      - /var/lib/marzban-node:/var/lib/marzban-node
      - /var/lib/marzban/assets:/usr/local/share/xray
      - /var/lib/marzban:/var/lib/marzban" > docker-compose.yml

sudo docker compose down && sudo docker compose up -d

sleep 10;

ip=$(curl -s https://api.ipify.org)
sudo cat /var/lib/marzban-node/ssl_cert.pem
sudo echo -e "${Green}IP: $ip ${Color_Off}"
sudo echo -e "${Green}Marzban Node is Up and Running successfully.${Color_Off}"
