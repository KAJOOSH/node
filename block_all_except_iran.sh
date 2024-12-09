
#!/bin/bash

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

if [ -f iran_v4.zone ]; then
    for IP in $(cat iran_v4.zone); do
        iptables -A INPUT -s $IP -j ACCEPT
    done
fi


if [ -f iran_v6.zone ]; then
    for IP in $(cat iran_v6.zone); do
        ip6tables -A INPUT -s $IP -j ACCEPT
    done
fi

iptables-save > /etc/iptables/rules.v4
ip6tables-save > /etc/iptables/rules.v6

echo "Rules applied successfully for both IPv4 and IPv6."
