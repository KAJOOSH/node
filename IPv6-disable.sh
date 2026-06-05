#!/bin/bash

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Please run as root."
    exit 1
fi

SYSCTL_FILE="/etc/sysctl.d/99-disable-ipv6.conf"

echo "Configuring sysctl..."

cat > "$SYSCTL_FILE" <<'EOF'
# Disable IPv6 globally

net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

echo "Applying sysctl settings..."
sysctl --system > /dev/null

echo "Configuring GRUB..."

if ! grep -q "ipv6.disable=1" /etc/default/grub; then
    sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/"$/ ipv6.disable=1"/' /etc/default/grub
fi

echo "Updating grub..."
update-grub

echo
echo "========================================="
echo "IPv6 disable configuration completed."
echo "========================================="
echo
echo "Current sysctl status:"
echo -n "all.disable_ipv6     = "
cat /proc/sys/net/ipv6/conf/all/disable_ipv6

echo -n "default.disable_ipv6 = "
cat /proc/sys/net/ipv6/conf/default/disable_ipv6

echo -n "lo.disable_ipv6      = "
cat /proc/sys/net/ipv6/conf/lo/disable_ipv6

echo
echo "A reboot is required to fully apply:"
echo "    ipv6.disable=1"
echo
echo "After reboot, verify with:"
echo "    ip -6 addr"
echo "    cat /proc/cmdline"
echo
