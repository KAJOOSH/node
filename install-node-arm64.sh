#!/bin/bash

if ! command -v docker &> /dev/null
then
    	sudo apt update
	sudo apt-get update; sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y; sudo DEBIAN_FRONTEND=noninteractive  apt-get install curl socat git -y
	sudo DEBIAN_FRONTEND=noninteractive apt install wget unzip -y
 	sudo curl -fsSL https://get.docker.com | sh
	sudo ufw enable -y
	sudo ufw allow 62050
	sudo ufw allow 62051
	sudo ufw allow 22
	sudo ufw allow 80
 	sudo ufw allow 443
	sudo ufw allow from 91.107.178.21
fi

sudo git clone https://github.com/Gozargah/Marzban-node

sudo mkdir -p /var/lib/marzban/assets/
sudo wget -O /var/lib/marzban/assets/geosite.dat https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat
sudo wget -O /var/lib/marzban/assets/geoip.dat https://github.com/v2fly/geoip/releases/latest/download/geoip.dat
sudo wget -O /var/lib/marzban/assets/iran.dat https://github.com/bootmortis/iran-hosted-domains/releases/latest/download/iran.dat

sudo mkdir -p /var/lib/marzban-node/
sudo wget -O /var/lib/marzban-node/ssl_client_cert.pem https://github.com/KAJOOSH/node/raw/refs/heads/main/certificate/ssl_client_cert.pem

mkdir -p /var/lib/marzban/xray-core && cd /var/lib/marzban/xray-core
sudo wget https://github.com/XTLS/Xray-core/releases/download/v1.8.24/Xray-linux-arm64-v8a.zip
sudo unzip Xray-linux-arm64-v8a.zip;
sudo rm Xray-linux-arm64-v8a.zip;

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

sudo cat /var/lib/marzban-node/ssl_cert.pem

sudo echo -e $'\e[32mMarzban Node is Up and Running successfully.\e[0m'
