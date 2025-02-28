#!/bin/bash
DEST_DIR="/usr/local/block-all-except-iran"

mkdir -p "$DEST_DIR"
cd "$DEST_DIR"

FETCH_IPV4_SCRIPT_URL="https://raw.githubusercontent.com/KAJOOSH/node/refs/heads/main/fetch_iran_ips_v4.sh"
FETCH_IPV6_SCRIPT_URL="https://raw.githubusercontent.com/KAJOOSH/node/refs/heads/main/fetch_iran_ips_v6.sh"
BLOCK_SCRIPT_URL="https://raw.githubusercontent.com/KAJOOSH/node/refs/heads/main/block_all_except_iran.sh"

FETCH_IPV4_SCRIPT="$DEST_DIR/fetch_iran_ips_v4.sh"
FETCH_IPV6_SCRIPT="$DEST_DIR/fetch_iran_ips_v6.sh"
BLOCK_SCRIPT="$DEST_DIR/block_all_except_iran.sh"

echo -e "${Yellow}Downloading scripts from GitHub...${Color_Off}"
wget -q -O "$FETCH_IPV4_SCRIPT" "$FETCH_IPV4_SCRIPT_URL"
wget -q -O "$FETCH_IPV6_SCRIPT" "$FETCH_IPV6_SCRIPT_URL"
wget -q -O "$BLOCK_SCRIPT" "$BLOCK_SCRIPT_URL"

chmod +x "$FETCH_IPV4_SCRIPT"
chmod +x "$FETCH_IPV6_SCRIPT"
chmod +x "$BLOCK_SCRIPT"

echo -e "${Yellow}Running the fetched scripts...${Color_Off}"
bash "$FETCH_IPV4_SCRIPT"
bash "$FETCH_IPV6_SCRIPT"
bash "$BLOCK_SCRIPT"

echo -e "${Yellow}Setting up cron job...${Color_Off}"
CRON_JOB="0 0 * * * $FETCH_IPV4_SCRIPT && $FETCH_IPV6_SCRIPT && $BLOCK_SCRIPT >> /var/log/block_all_except_iran.log 2>&1"

(crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -

echo -e "${Green}Cron job installed and scripts executed.${Color_Off}"
