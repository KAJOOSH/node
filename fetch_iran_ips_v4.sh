#!/bin/bash

URLS=(
    "https://www.ipdeny.com/ipblocks/data/countries/ir.zone"
    "hhttps://raw.githubusercontent.com/ipverse/rir-ip/refs/heads/master/country/ir/ipv4-aggregated.txt"
    "https://raw.githubusercontent.com/herrbischoff/country-ip-blocks/master/ipv4/ir.cidr"
)

OUTPUT_FILE="iran_v4.zone"

> $OUTPUT_FILE

echo "Downloading IP lists from multiple sources..."
for URL in "${URLS[@]}"; do
    echo "Fetching from $URL..."
    wget -q -O - "$URL" >> $OUTPUT_FILE
    echo "" >> $OUTPUT_FILE
done

echo "Removing duplicate entries..."
sort -u $OUTPUT_FILE -o $OUTPUT_FILE

echo "IP list saved to $OUTPUT_FILE"
echo "Total unique IP ranges: $(wc -l < $OUTPUT_FILE)"
