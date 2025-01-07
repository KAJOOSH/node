#!/bin/bash

default_tag="v24.11.30"
read -p "Please enter the tag (default: $default_tag): " tag

if [ -z "$tag" ]; then
    tag="$default_tag"
fi

echo "Please select the operating system:"
echo "1) linux-64"
echo "2) linux-arm64"
read -p "Enter the number corresponding to your choice: " os_choice

case $os_choice in
    1)
        os="linux-64"
        url="https://github.com/XTLS/Xray-core/releases/download/$tag/Xray-linux-64.zip"
        filename="Xray-linux-64.zip"
        ;;
    2)
        os="linux-arm64"
        url="https://github.com/XTLS/Xray-core/releases/download/$tag/Xray-linux-arm64-v8a.zip"
        filename="Xray-linux-arm64-v8a.zip"
        ;;
    *)
        echo "Error: Invalid choice. Please run the script again and select a valid option."
        exit 1
        ;;
esac

echo "Tag: $tag"
echo "Operating System: $os"
echo "Downloading from: $url"

cd /var/lib/marzban/xray-core

sudo wget "$url"

sudo unzip -o "$filename"

sudo rm "$filename"

cd ~/Marzban-node

sudo docker compose down && sudo docker compose up -d

sudo echo -e $'\e[32mMarzban Node is Up and Running successfully.\e[0m'
