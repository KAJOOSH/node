
#!/bin/bash

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

# اعمال قوانین برای IPv4
if [ -f "$V4_FILE" ]; then
    echo "Applying IPv4 rules..."
    for IP in $(cat "$V4_FILE"); do
        iptables -A INPUT -s $IP -j ACCEPT
    done
else
    echo "$V4_FILE not found!"
fi

# اعمال قوانین برای IPv6
if [ -f "$V6_FILE" ]; then
    echo "Applying IPv6 rules..."
    for IP in $(cat "$V6_FILE"); do
        ip6tables -A INPUT -s $IP -j ACCEPT
    done
else
    echo "$V6_FILE not found!"
fi

iptables-save > /etc/iptables/rules.v4
ip6tables-save > /etc/iptables/rules.v6

iptables -A INPUT -s 91.107.178.21 -j ACCEPT

echo "Rules applied successfully for both IPv4 and IPv6."
