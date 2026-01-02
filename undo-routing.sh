#!/bin/bash

# This script can be used in emergency, when the homeserver or second VPS experiences extreme downtime, or problems.
# Move the scrip to /root/ or /usr/local/bin/
# Make it executable: chmod +x ./undo-routing.sh
# Run in case of emergency on public webserver: sudo ./undo-routing.sh

set -e

echo "Removing ip rule for fwmark 200..."
sudo ip rule del fwmark 200 table tailscale 2>/dev/null || true

echo "Removing iptables mangle OUTPUT rules..."

sudo iptables -t mangle -D OUTPUT -p tcp --dport 80  -j MARK --set-mark 200 2>/dev/null || true
sudo iptables -t mangle -D OUTPUT -p tcp --dport 443 -j MARK --set-mark 200 2>/dev/null || true
sudo iptables -t mangle -D OUTPUT -p tcp --dport 22  -j MARK --set-mark 200 2>/dev/null || true
sudo iptables -t mangle -D OUTPUT -p tcp --dport 53  -j MARK --set-mark 200 2>/dev/null || true
sudo iptables -t mangle -D OUTPUT -p udp --dport 53  -j MARK --set-mark 200 2>/dev/null || true

sudo netfilter-persistent save

echo "Done. Routing restored to normal."
