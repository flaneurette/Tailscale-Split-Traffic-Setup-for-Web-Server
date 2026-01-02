#!/bin/bash
set -euo pipefail

# NOTE: RUN THIS ON THE PUBLIC WEBSERVER, NOT HOME/VPS EXIT NODE
# Move the scrip to /root/ or /usr/local/bin/
# Make it executable: chmod +x ./create-routing.sh
# Run: sudo ./create-routing.sh

# Script assumes: tailscaled.service, but could be: tailscale.service in some cases (without the d). Manually edit this script to change!

echo "=== Tailscale Selective Routing Setup ==="
echo "WARNING: This will replace UFW with iptables-persistent"
read -p "Continue? (yes/no): " confirm
[[ "$confirm" != "yes" ]] && { echo "Aborted."; exit 1; }

# Update first
apt-get update
apt-get install curl

### 1. Snapshot existing firewall (UFW still active)
echo "[1/10] Creating firewall snapshots..."
mkdir -p /root/firewall-backup
iptables-save > /root/firewall-backup/iptables.ufw.snapshot
ip6tables-save > /root/firewall-backup/ip6tables.ufw.snapshot
iptables-save -t mangle > /root/firewall-backup/iptables.mangle.snapshot
ip6tables-save -t mangle > /root/firewall-backup/ip6tables.mangle.snapshot
ufw status verbose > /root/firewall-backup/ufw.rules.snapshot 2>/dev/null || true
echo "Snapshots saved in /root/firewall-backup/"

### 2. Install Tailscale
echo "[2/10] Installing Tailscale..."
if ! command -v tailscale >/dev/null; then
  curl -fsSL https://tailscale.com/install.sh | sh
else
  echo "Tailscale already installed"
fi

echo "[3/10] Bringing Tailscale up (no exit node)..."
if ! tailscale status >/dev/null 2>&1; then
  tailscale up --accept-routes=false --advertise-exit-node=false
fi

# Wait for Tailscale interface
echo "Waiting for tailscale0 interface..."
for i in {1..30}; do
  if ip link show tailscale0 >/dev/null 2>&1; then
    echo "tailscale0 is ready"
    break
  fi
  sleep 1
  [[ $i -eq 30 ]] && { echo "ERROR: tailscale0 not found"; exit 1; }
done

### 4. Install iptables persistence (removes UFW)
echo "[4/10] Installing iptables-persistent (UFW will be removed)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y netfilter-persistent iptables-persistent

### 5. Restore firewall exactly as it was
echo "[5/10] Restoring firewall snapshot..."
iptables-restore < /root/firewall-backup/iptables.ufw.snapshot || true
ip6tables-restore < /root/firewall-backup/ip6tables.ufw.snapshot || true

# Verify restoration
echo "Verifying restored rules..."
iptables -L -n | head -20

### 6. Create routing table safely
echo "[6/10] Ensuring Tailscale routing table exists..."
if ! grep -q '^200 tailscale$' /etc/iproute2/rt_tables; then
  echo '200 tailscale' >> /etc/iproute2/rt_tables
  echo "Added tailscale routing table"
else
  echo "Routing table already exists"
fi

### 7. Add selective packet marking (idempotent)
echo "[7/10] Adding packet marking rules..."

# Function to add marking rules safely
add_mark() {
  if ! iptables -t mangle -C OUTPUT "$@" -j MARK --set-mark 200 2>/dev/null; then
    iptables -t mangle -A OUTPUT "$@" -j MARK --set-mark 200
    echo "Added rule: $*"
  else
    echo "Rule exists: $*"
  fi
}

# Mark packets for routing through Tailscale
add_mark -p tcp --dport 80
add_mark -p tcp --dport 443
add_mark -p tcp --dport 22
add_mark -p tcp --dport 53
add_mark -p udp --dport 53

# Important: Don't route Tailscale's own traffic through itself
echo "Adding Tailscale exclusion rule..."
if ! iptables -t mangle -C OUTPUT -o tailscale0 -j RETURN 2>/dev/null; then
  iptables -t mangle -I OUTPUT 1 -o tailscale0 -j RETURN
fi

### 8. Policy routing
echo "[8/10] Configuring policy routing..."

# Delete existing rules/routes to avoid duplicates
ip rule del fwmark 200 table tailscale 2>/dev/null || true
ip route flush table tailscale 2>/dev/null || true

# Add new routes
ip route add default dev tailscale0 table tailscale
ip rule add fwmark 200 table tailscale priority 100

# Verify routing
echo "Current routing rules:"
ip rule show | grep -E "(tailscale|200)"

### 9. Persist iptables rules
echo "[9/10] Saving firewall rules..."
netfilter-persistent save

### 10. Install systemd service
echo "[10/10] Installing systemd service..."
cat >/etc/systemd/system/tailscale-routing.service <<'EOF'
[Unit]
Description=Tailscale selective routing
After=network-online.target tailscaled.service
Wants=network-online.target
Requires=tailscaled.service

[Service]
Type=oneshot
RemainAfterExit=yes

# Wait for interface
ExecStartPre=/bin/sh -c 'for i in $(seq 1 30); do ip link show tailscale0 >/dev/null 2>&1 && break || sleep 1; done'

# Clean existing rules
ExecStartPre=-/usr/sbin/ip rule del fwmark 200 table tailscale
ExecStartPre=-/usr/sbin/ip route flush table tailscale

# Add routing rules
ExecStart=/usr/sbin/ip route add default dev tailscale0 table tailscale
ExecStart=/usr/sbin/ip rule add fwmark 200 table tailscale priority 100

# Cleanup on stop
ExecStop=/usr/sbin/ip rule del fwmark 200 table tailscale
ExecStop=/usr/sbin/ip route flush table tailscale

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable tailscale-routing.service
systemctl start tailscale-routing.service

echo
echo "=== SETUP COMPLETE ==="
echo
echo "Exit node IP (check if it uses your other server IP):"
echo "----------------------"
curl icanhazip.com
echo
echo "Tailscale status:"
echo "----------------------"
tailscale status
echo
echo "Current configuration:"
echo "----------------------"
ip rule show
echo
echo "Tailscale routing table:"
echo "----------------------"
ip route show table tailscale
echo
echo "Packet marking rules:"
echo "----------------------"
iptables -t mangle -L OUTPUT -n -v --line-numbers | grep "MARK"
echo
echo "Verify with:"
echo "----------------------"
echo "  curl -4 ifconfig.me  # Should show Tailscale exit IP"
echo "  traceroute -n 8.8.8.8  # Should go through Tailscale"
echo
echo "Emergency rollback:"
echo "----------------------"
echo "  systemctl stop tailscale-routing.service"
echo "  systemctl disable tailscale-routing.service"
echo "  iptables-restore < /root/firewall-backup/iptables.ufw.snapshot"
echo "  ip rule del fwmark 200 table tailscale"
echo "  ip route flush table tailscale"
