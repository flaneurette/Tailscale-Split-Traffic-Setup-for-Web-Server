#!/bin/bash
set -euo pipefail

# ===================================================================
# Tailscale Selective Routing Setup
# ===================================================================
# NOTE: Run this on the PUBLIC server, NOT the exit node
# Move to /root/ or /usr/local/bin/
# Make executable: chmod +x create-routing.sh
# Run: sudo ./create-routing.sh
# ===================================================================

echo "=== Tailscale Selective Routing Setup ==="
echo "WARNING: This will replace UFW with iptables-persistent"
read -p "Continue? (yes/no): " confirm
[[ "$confirm" != "yes" ]] && { echo "Aborted."; exit 1; }

# -----------------------------
# 1. Update & install curl
# -----------------------------
apt-get update
apt-get install -y curl

# -----------------------------
# 2. Snapshot existing firewall
# -----------------------------
echo "[1/10] Creating firewall snapshots..."
mkdir -p /root/firewall-backup
iptables-save > /root/firewall-backup/iptables.ufw.snapshot
ip6tables-save > /root/firewall-backup/ip6tables.ufw.snapshot
iptables-save -t mangle > /root/firewall-backup/iptables.mangle.snapshot
ip6tables-save -t mangle > /root/firewall-backup/ip6tables.mangle.snapshot
ufw status verbose > /root/firewall-backup/ufw.rules.snapshot 2>/dev/null || true
echo "Snapshots saved in /root/firewall-backup/"

# -----------------------------
# 3. Install Tailscale if missing
# -----------------------------
echo "[2/10] Installing Tailscale..."
if ! command -v tailscale >/dev/null; then
  curl -fsSL https://tailscale.com/install.sh | sh
else
  echo "Tailscale already installed"
fi

# -----------------------------
# 4. Start Tailscale
# -----------------------------
echo "[3/10] Bringing Tailscale up..."
tailscale up --accept-routes=false --advertise-exit-node=false || true

# Wait for interface AND DERP connectivity
echo "Waiting for tailscale0 and DERP connectivity..."
for i in $(seq 1 30); do
    if ip link show tailscale0 >/dev/null 2>&1; then
        STATUS=$(tailscale status --json 2>/dev/null || echo "")
        if [[ $STATUS == *"100."* ]]; then
            echo "Tailscale online"
            break
        fi
    fi
    sleep 1
    [[ $i -eq 30 ]] && { echo "ERROR: Tailscale not online"; exit 1; }
done

# -----------------------------
# 5. Install iptables persistence (removes UFW)
# -----------------------------
echo "[4/10] Installing iptables-persistent..."
export DEBIAN_FRONTEND=noninteractive
apt-get install -y netfilter-persistent iptables-persistent

# -----------------------------
# 6. Restore previous firewall
# -----------------------------
restore_if_exists() {
    local file="$1"
    local cmd="$2"
    if [[ -s "$file" ]]; then
        if [[ "$cmd" == "ip6tables-restore" ]]; then
            if sysctl -n net.ipv6.conf.all.disable_ipv6 | grep -q 1; then
                echo "IPv6 disabled, skipping $file"
                return
            fi
        fi
        echo "Restoring $file..."
        $cmd < "$file" || echo "WARNING: $file restore failed, continuing"
    else
        echo "Skipping $file, missing or empty"
    fi
}

echo "[5/10] Restoring firewall..."
restore_if_exists /root/firewall-backup/iptables.ufw.snapshot iptables-restore
restore_if_exists /root/firewall-backup/ip6tables.ufw.snapshot ip6tables-restore
restore_if_exists /root/firewall-backup/iptables.mangle.snapshot iptables-restore
restore_if_exists /root/firewall-backup/ip6tables.mangle.snapshot ip6tables-restore

# -----------------------------
# 7. Ensure Tailscale routing table
# -----------------------------
echo "[6/10] Ensuring routing table..."
if ! grep -q '^200 tailscale$' /etc/iproute2/rt_tables; then
  echo '200 tailscale' >> /etc/iproute2/rt_tables
  echo "Added tailscale routing table"
else
  echo "Routing table already exists"
fi

# -----------------------------
# 8. Add mangle rules (idempotent)
# -----------------------------
echo "[7/10] Adding packet marking rules..."
# Exclude Tailscale traffic first
if ! iptables -t mangle -C OUTPUT -o tailscale0 -j RETURN 2>/dev/null; then
    iptables -t mangle -I OUTPUT 1 -o tailscale0 -j RETURN
    echo "Added exclusion for tailscale0"
fi

# Function to mark ports
add_mark() {
  if ! iptables -t mangle -C OUTPUT "$@" -j MARK --set-mark 200 2>/dev/null; then
      iptables -t mangle -A OUTPUT "$@" -j MARK --set-mark 200
      echo "Added rule: $*"
  else
      echo "Rule exists: $*"
  fi
}

# Mark selective traffic
add_mark -p tcp --dport 80
add_mark -p tcp --dport 443
# add_mark -p tcp --dport 22
# add_mark -p tcp --dport 53
# add_mark -p udp --dport 53

# -----------------------------
# 9. Policy routing
# -----------------------------
echo "[8/10] Configuring policy routing..."
ip rule del fwmark 200 table tailscale 2>/dev/null || true
ip route flush table tailscale 2>/dev/null || true
ip route add default dev tailscale0 table tailscale
ip rule add fwmark 200 table tailscale priority 100

# -----------------------------
# 10. Persist firewall
# -----------------------------
echo "[9/10] Saving iptables..."
netfilter-persistent save

# -----------------------------
# 11. Systemd service
# -----------------------------

echo "[10/10] Installing systemd service..."
SERVICE_FILE=/etc/systemd/system/tailscale-routing.service

cat >"$SERVICE_FILE" <<'EOF'
[Unit]
Description=Tailscale selective routing
After=network-online.target tailscaled.service
Wants=network-online.target
Requires=tailscaled.service

[Service]
Type=oneshot
RemainAfterExit=yes

# Wait for tailscale0 interface
ExecStartPre=/bin/sh -c 'for i in $(seq 1 30); do ip link show tailscale0 >/dev/null 2>&1 && break || sleep 1; done'

# Clean up old rules (ignore errors)
ExecStartPre=-/usr/sbin/ip rule del fwmark 200 table tailscale
ExecStartPre=-/usr/sbin/ip route flush table tailscale

# Add policy routing safely
ExecStart=/usr/sbin/ip route add default dev tailscale0 table tailscale || true
ExecStart=/usr/sbin/ip rule add fwmark 200 table tailscale priority 100 || true

# Cleanup on stop
ExecStop=/usr/sbin/ip rule del fwmark 200 table tailscale || true
ExecStop=/usr/sbin/ip route flush table tailscale || true

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd and enable/start service
systemctl daemon-reload
systemctl enable tailscale-routing.service
systemctl start tailscale-routing.service

systemctl restart tailscaled
tailscale up --accept-routes=false --advertise-exit-node=false

# -----------------------------
# Done
# -----------------------------
echo
echo "=== SETUP COMPLETE ==="
echo
echo "Exit node IP:"
echo "----------------------"
IP=$(curl -s icanhazip.com || echo "ERROR")
echo "Exit node IP: $IP"
echo
echo "Tailscale status:"
echo "----------------------"
tailscale status
echo
echo "Routing rules:"
echo "----------------------"
ip rule show | grep -E "(tailscale|200)"
echo
echo "Routing table:"
echo "----------------------"
ip route show table tailscale
echo
echo "Packet marking rules:"
echo "----------------------"
iptables -t mangle -L OUTPUT -n -v --line-numbers | grep "MARK" || true
echo
echo "Verify:"
echo "----------------------"
echo "  curl -4 ifconfig.me"
echo "  traceroute -n 8.8.8.8"
echo
echo "Emergency rollback:"
echo "----------------------"
echo "  systemctl stop tailscale-routing.service"
echo "  systemctl disable tailscale-routing.service"
echo "  iptables-restore < /root/firewall-backup/iptables.ufw.snapshot"
echo "  ip rule del fwmark 200 table tailscale"
echo "  ip route flush table tailscale"
