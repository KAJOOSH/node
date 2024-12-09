
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

DEST_DIR="/usr/local/block-all-except-iran"
V4_FILE="$DEST_DIR/iran_v4.zone"
V6_FILE="$DEST_DIR/iran_v6.zone"

iptables -F
iptables -X
ip6tables -F
ip6tables -X

iptables -P INPUT DROP
ip6tables -P INPUT DROP

iptables -A INPUT -i lo -j ACCEPT
ip6tables -A INPUT -i lo -j ACCEPT

iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
ip6tables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -s 91.107.178.21 -j ACCEPT

if [ -f "$V4_FILE" ]; then
    echo -e "${Yellow}Applying IPv4 rules...${Color_Off}"
    for IP in $(cat "$V4_FILE"); do
        iptables -A INPUT -s $IP -j ACCEPT
    done
else
    echo -e "${Red} $V4_FILE not found!${Color_Off}"
fi

if [ -f "$V6_FILE" ]; then
    echo -e "${Yellow}Applying IPv6 rules...${Color_Off}"
    for IP in $(cat "$V6_FILE"); do
        ip6tables -A INPUT -s $IP -j ACCEPT
    done
else
    echo -e "${Red} $V6_FILE not found!${Color_Off}"
fi

iptables-save > /etc/iptables/rules.v4
ip6tables-save > /etc/iptables/rules.v6

echo -e "${Green}Rules applied successfully for both IPv4 and IPv6.${Color_Off}"
