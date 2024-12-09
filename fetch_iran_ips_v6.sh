#!/bin/bash

URLS=(
    "https://www.ipdeny.com/ipv6/ipaddresses/blocks/ir.zone"
    "https://raw.githubusercontent.com/ipverse/rir-ip/refs/heads/master/country/ir/ipv6-aggregated.txt"
    "https://raw.githubusercontent.com/herrbischoff/country-ip-blocks/refs/heads/master/ipv6/ir.cidr"
)

DEST_DIR="/usr/local/block-all-except-iran"

if [ ! -d "$DEST_DIR" ]; then
    mkdir -p "$DEST_DIR"
    echo "Directory $DEST_DIR created."
else
    echo "Directory $DEST_DIR already exists."
fi

OUTPUT_FILE="$DEST_DIR/iran_v6.zone"

> $OUTPUT_FILE

echo "Downloading IP lists from multiple sources..."
for URL in "${URLS[@]}"; do
    echo "Fetching from $URL..."
    wget -q -O - "$URL" >> $OUTPUT_FILE
    echo "" >> $OUTPUT_FILE
done

echo "Removing empty lines and comments..."
sed -i '/^$/d' $OUTPUT_FILE
sed -i '/^#/d' $OUTPUT_FILE

echo "Removing duplicate entries..."
sort -u $OUTPUT_FILE -o $OUTPUT_FILE

echo "IP list saved to $OUTPUT_FILE"
echo "Total unique IP ranges: $(wc -l < $OUTPUT_FILE)"
