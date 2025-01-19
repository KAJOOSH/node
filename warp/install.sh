#!/bin/bash

curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | sudo gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/cloudflare-client.list

sudo apt-get update && sudo DEBIAN_FRONTEND=noninteractive apt-get install cloudflare-warp -y

echo "y" | sudo warp-cli mode proxy

DEST_DIR="/var/lib/cloudflare-warp"

cd "$DEST_DIR"

FETCH_CONF_URL="https://raw.githubusercontent.com/KAJOOSH/node/refs/heads/main/warp/conf.json"
FETCH_REG_URL="https://raw.githubusercontent.com/KAJOOSH/node/refs/heads/main/warp/reg.json"
FETCH_SETTINGS_URL="https://raw.githubusercontent.com/KAJOOSH/node/refs/heads/main/warp/settings.json"

FETCH_CONF_FILE="$DEST_DIR/conf.json"
FETCH_REG_FILE="$DEST_DIR/reg.json"
FETCH_SETTINGS_FILE="$DEST_DIR/settings.json"

wget -q -O "$FETCH_CONF_FILE" "$FETCH_CONF_URL"
wget -q -O "$FETCH_REG_FILE" "$FETCH_REG_URL"
wget -q -O "$FETCH_SETTINGS_FILE" "$FETCH_SETTINGS_URL"

sudo systemctl restart warp-svc

sleep 5;

warp-cli connect

warp-cli status

warp-cli registration show
