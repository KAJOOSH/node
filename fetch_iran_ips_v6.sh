#!/bin/bash
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

URLS=(
    "https://www.ipdeny.com/ipv6/ipaddresses/blocks/ir.zone"
    "https://raw.githubusercontent.com/ipverse/rir-ip/refs/heads/master/country/ir/ipv6-aggregated.txt"
    "https://raw.githubusercontent.com/herrbischoff/country-ip-blocks/refs/heads/master/ipv6/ir.cidr"
)

DEST_DIR="/usr/local/block-all-except-iran"

if [ ! -d "$DEST_DIR" ]; then
    mkdir -p "$DEST_DIR"
    echo -e "${Green}Directory $DEST_DIR created.${Color_Off}"
else
    echo -e "${Yellow}Directory $DEST_DIR already exists.${Color_Off}"
fi

OUTPUT_FILE="$DEST_DIR/iran_v6.zone"

> $OUTPUT_FILE

echo -e "${Yellow}Downloading IP lists from multiple sources...${Color_Off}"
for URL in "${URLS[@]}"; do
    echo -e "${Yellow}Fetching from $URL...${Color_Off}"
    wget -q -O - "$URL" >> $OUTPUT_FILE
    echo "" >> $OUTPUT_FILE
done

echo -e "${Green} Removing empty lines and comments...${Color_Off}"
sed -i '/^$/d' $OUTPUT_FILE
sed -i '/^#/d' $OUTPUT_FILE

echo -e "${Green} Removing duplicate entries...${Color_Off}"
sort -u $OUTPUT_FILE -o $OUTPUT_FILE

echo -e "IP list saved to ${Green} $OUTPUT_FILE ${Color_Off}"
echo -e "Total unique IP ranges: ${Green} $(wc -l < $OUTPUT_FILE) ${Color_Off}"
