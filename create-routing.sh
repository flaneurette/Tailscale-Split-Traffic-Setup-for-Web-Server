#!/bin/bash
set -euo pipefail

# ===================================================================
# Tailscale Selective Routing Setup (Improved)
# ===================================================================
# NOTE: Run this on the PUBLIC server, NOT the exit node
# Move to /root/ or /usr/local/bin/
# Make executable: chmod +x create-routing.sh
# Run: sudo ./create-routing.sh
# ===================================================================

# Configuration
LOG_FILE="/var/log/tailscale-routing-setup.log"
BACKUP_DIR="/root/firewall-backup"
ROUTING_TABLE_ID=200
ROUTING_TABLE_NAME="tailscale"
SAFE_SSH_IP="your.backup.ssh.ip"
BYPASS_MARK=100  # Mark for traffic that should NOT use Tailscale

# -----------------------------
# Setup logging and error handling
# -----------------------------
exec > >(tee -a "$LOG_FILE") 2>&1
echo "=== Setup started at $(date) ==="

cleanup_on_error() {
    echo "ERROR: Setup failed at step $CURRENT_STEP, might not be serious. Remember to manually start the device with: tailscale up --accept-routes=false --advertise-exit-node=false --exit-node-allow-lan-access --exit-node=<EXIT.NODE.IP.HERE>"
    echo "--------------------------------------------------------------------------"
    echo "If error is serious, run: tailscale up --reset"
    echo "Then run: undo-routing.sh, and try again."
    echo "--------------------------------------------------------------------------"
    echo "Check logs in $LOG_FILE"
    echo "Manual rollback: iptables-restore < $BACKUP_DIR/iptables.ufw.snapshot"
    exit 1
}

trap cleanup_on_error ERR

# -----------------------------
# Root check
# -----------------------------
if [[ $EUID -ne 0 ]]; then
   echo "ERROR: This script must be run as root"
   exit 1
fi

# -----------------------------
# Confirmation
# -----------------------------
echo "=== Tailscale Selective Routing Setup ==="
echo "WARNING: This will replace UFW with iptables-persistent"
echo "A backup will be created in $BACKUP_DIR"
read -p "Continue? (yes/no): " confirm
[[ "$confirm" != "yes" ]] && { echo "Aborted."; exit 1; }

# -----------------------------
# Helper function to wait for apt locks
# -----------------------------
wait_for_apt() {
    echo "Waiting for apt locks to be released..."
    local max_wait=300  # 5 minutes max
    local waited=0
    
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
          fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
          fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
        
        if [[ $waited -ge $max_wait ]]; then
            echo "ERROR: Timeout waiting for apt locks after ${max_wait}s"
            echo "Another package manager is running. Please wait for it to finish or run:"
            echo "  ps aux | grep -i apt"
            echo "  sudo kill <process_id>"
            exit 1
        fi
        
        echo "  Waiting for apt to become available... (${waited}s elapsed)"
        sleep 5
        waited=$((waited + 5))
    done
    
    if [[ $waited -gt 0 ]]; then
        echo "Apt is now available"
    fi
}

# -----------------------------
# 1. Update & install dependencies
# -----------------------------
CURRENT_STEP="1/11: Installing dependencies"
echo "[$CURRENT_STEP]"

wait_for_apt
apt-get update
wait_for_apt
apt-get install -y curl iproute2 iptables

# -----------------------------
# 2. Snapshot existing firewall
# -----------------------------
CURRENT_STEP="2/11: Creating firewall snapshots"
echo "[$CURRENT_STEP]"
mkdir -p "$BACKUP_DIR"
iptables-save > "$BACKUP_DIR/iptables.ufw.snapshot"
ip6tables-save > "$BACKUP_DIR/ip6tables.ufw.snapshot"
iptables-save -t mangle > "$BACKUP_DIR/iptables.mangle.snapshot"
ip6tables-save -t mangle > "$BACKUP_DIR/ip6tables.mangle.snapshot"
ufw status verbose > "$BACKUP_DIR/ufw.rules.snapshot" 2>/dev/null || true
ip rule save > "$BACKUP_DIR/ip.rules.snapshot" 2>/dev/null || true
echo "Snapshots saved in $BACKUP_DIR"

# -----------------------------
# 3. Install Tailscale if missing
# -----------------------------
CURRENT_STEP="3/11: Installing Tailscale"
echo "[$CURRENT_STEP]"
if ! command -v tailscale >/dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
    echo "Tailscale installed"
else
    echo "Tailscale already installed"
fi

# -----------------------------
# 4. Start Tailscale
# -----------------------------
CURRENT_STEP="4/11: Bringing "
echo "[$CURRENT_STEP]"
tailscale up --accept-routes=false --advertise-exit-node=false || true

# Wait for interface AND DERP connectivity
echo "Waiting for tailscale0 interface and network connectivity..."
for i in $(seq 1 60); do
    if ip link show tailscale0 >/dev/null 2>&1; then
        if tailscale status --json 2>/dev/null | grep -q "100\."; then
            echo "Tailscale online"
            break
        fi
    fi
    sleep 1
    if [[ $i -eq 60 ]]; then
        echo "ERROR: Tailscale failed to come online after 60 seconds"
        exit 1
    fi
done

# Verify we're connected to a Tailscale network
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")
if [[ -z "$TAILSCALE_IP" ]]; then
    echo "ERROR: No Tailscale IP assigned. Are you authenticated?"
    exit 1
fi
echo "Tailscale IP: $TAILSCALE_IP"

# -----------------------------
# 5. Install iptables persistence (removes UFW)
# -----------------------------
CURRENT_STEP="5/11: Installing iptables-persistent"
echo "[$CURRENT_STEP]"
export DEBIAN_FRONTEND=noninteractive
wait_for_apt
apt-get install -y netfilter-persistent iptables-persistent
echo "iptables-persistent installed"

# -----------------------------
# 6. Restore previous firewall rules
# -----------------------------
CURRENT_STEP="6/11: Restoring firewall rules"
echo "[$CURRENT_STEP]"

restore_if_exists() {
    local file="$1"
    local cmd="$2"
    
    if [[ ! -s "$file" ]]; then
        echo "Skipping $file (missing or empty)"
        return
    fi
    
    if [[ "$cmd" == "ip6tables-restore" ]]; then
        if sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null | grep -q 1; then
            echo "IPv6 disabled, skipping $file"
            return
        fi
    fi
    
    echo "Restoring $file..."
    if $cmd < "$file"; then
        echo "Restored $file"
    else
        echo "WARNING: $file restore had issues, continuing anyway"
    fi
}

restore_if_exists "$BACKUP_DIR/iptables.ufw.snapshot" iptables-restore
restore_if_exists "$BACKUP_DIR/ip6tables.ufw.snapshot" ip6tables-restore
restore_if_exists "$BACKUP_DIR/iptables.mangle.snapshot" "iptables-restore -T mangle"
restore_if_exists "$BACKUP_DIR/ip6tables.mangle.snapshot" "ip6tables-restore -T mangle"

# -----------------------------
# 7. Ensure Tailscale routing table
# -----------------------------
CURRENT_STEP="7/11: Configuring routing table"
echo "[$CURRENT_STEP]"
if ! grep -q "^$ROUTING_TABLE_ID $ROUTING_TABLE_NAME\$" /etc/iproute2/rt_tables; then
    echo "$ROUTING_TABLE_ID $ROUTING_TABLE_NAME" >> /etc/iproute2/rt_tables
    echo "Added $ROUTING_TABLE_NAME routing table"
else
    echo "Routing table already exists"
fi

# -----------------------------
# 8. Add mangle rules for packet marking
# -----------------------------
CURRENT_STEP="8/11: Adding packet marking rules"
echo "[$CURRENT_STEP]"

# Function to add bypass rules (mark 100 = use main table, NOT Tailscale)
add_bypass() {
    local table="$1"
    shift
    
    if ! $table -t mangle -C OUTPUT "$@" -j MARK --set-mark $BYPASS_MARK 2>/dev/null; then
        $table -t mangle -A OUTPUT "$@" -j MARK --set-mark $BYPASS_MARK
        echo "Added bypass: $table $*"
    else
        echo "Bypass exists: $table $*"
    fi
}

# Function to add marking rules (idempotent)
add_mark() {
    local table="$1"
    shift
    
    if ! $table -t mangle -C OUTPUT "$@" -j MARK --set-mark $ROUTING_TABLE_ID 2>/dev/null; then
        $table -t mangle -A OUTPUT "$@" -j MARK --set-mark $ROUTING_TABLE_ID
        echo "Added rule: $table $*"
    else
        echo "Rule exists: $table $*"
    fi
}

# Exclude Tailscale interface traffic (prevent routing loops)
if ! iptables -t mangle -C OUTPUT -o tailscale0 -j RETURN 2>/dev/null; then
    iptables -t mangle -I OUTPUT 1 -o tailscale0 -j RETURN
    echo "Added exclusion for tailscale0"
else
    echo "Exclusion rule exists for tailscale0"
fi

# CRITICAL: Exclude Tailscale CGNAT range (100.64.0.0/10)
# This prevents routing Tailscale's own coordination traffic through itself
if ! iptables -t mangle -C OUTPUT -d 100.64.0.0/10 -j RETURN 2>/dev/null; then
    iptables -t mangle -I OUTPUT 2 -d 100.64.0.0/10 -j RETURN
    echo "Added exclusion for Tailscale CGNAT range"
else
    echo "Exclusion rule exists for Tailscale CGNAT range"
fi

# Exclude traffic from the tailscale daemon itself
if ! iptables -t mangle -C OUTPUT -m owner --uid-owner tailscale -j RETURN 2>/dev/null; then
    iptables -t mangle -I OUTPUT 3 -m owner --uid-owner tailscale -j RETURN 2>/dev/null || \
        echo "Could not add UID-based exclusion (tailscale user may not exist)"
fi

# Mark selective traffic for IPv4
add_mark iptables -p tcp --dport 80
add_mark iptables -p tcp --dport 443

# DNS ROUTING WARNING: Routing DNS through Tailscale can cause issues
add_mark iptables -p tcp --dport 53
add_mark iptables -p udp --dport 53

# SECURITY WARNING: Uncomment SSH carefully!
# Routing SSH through Tailscale can lock you out if Tailscale fails
# Only enable if you have console access or another connection method
# add_mark iptables -p tcp --dport 22

echo "Excluding SSH"
echo "-------------------"

# Get your IP
MY_IP=$(echo $SSH_CLIENT | awk '{print $1}')

# Protect SSH return path (only if rules don't exist)
if ! iptables -t mangle -C OUTPUT -p tcp --sport 22 -d "$MY_IP" -j MARK --set-mark 100 2>/dev/null; then
    iptables -t mangle -I OUTPUT 1 -p tcp --sport 22 -d "$MY_IP" -j MARK --set-mark 100
fi

if ! iptables -t mangle -C OUTPUT -p tcp --sport 22 -d "$SAFE_SSH_IP" -j MARK --set-mark 100 2>/dev/null; then
    iptables -t mangle -I OUTPUT 1 -p tcp --sport 22 -d "$SAFE_SSH_IP" -j MARK --set-mark 100
fi

# Add IP rule (only if it doesn't exist)
if ! ip rule show | grep -q "fwmark 0x64.*main"; then
    ip rule add fwmark 100 table main priority 50
fi

echo "Excluding mailports"
echo "-------------------"

# SMTP ports (both directions)
add_bypass iptables -p tcp --dport 25     # SMTP outbound
add_bypass iptables -p tcp --sport 25     # SMTP inbound
add_bypass iptables -p tcp --dport 465    # SMTPS outbound
add_bypass iptables -p tcp --sport 465    # SMTPS inbound
add_bypass iptables -p tcp --dport 587    # Submission outbound
add_bypass iptables -p tcp --sport 587    # Submission inbound

# IMAP ports
add_bypass iptables -p tcp --dport 143    # IMAP outbound
add_bypass iptables -p tcp --sport 143    # IMAP inbound
add_bypass iptables -p tcp --dport 993    # IMAPS outbound
add_bypass iptables -p tcp --sport 993    # IMAPS inbound

# POP3 ports
add_bypass iptables -p tcp --dport 110    # POP3 outbound
add_bypass iptables -p tcp --sport 110    # POP3 inbound
add_bypass iptables -p tcp --dport 995    # POP3S outbound
add_bypass iptables -p tcp --sport 995    # POP3S inbound

echo "IPv6"
echo "-------------------"

# Handle IPv6 if enabled
if ! sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null | grep -q 1; then
    echo "Configuring IPv6 mangle rules..."
    
    if ! ip6tables -t mangle -C OUTPUT -o tailscale0 -j RETURN 2>/dev/null; then
        ip6tables -t mangle -I OUTPUT 1 -o tailscale0 -j RETURN
        echo "Added IPv6 exclusion for tailscale0"
    fi
    
    # Exclude Tailscale IPv6 range
    if ! ip6tables -t mangle -C OUTPUT -d fd7a:115c:a1e0::/48 -j RETURN 2>/dev/null; then
        ip6tables -t mangle -I OUTPUT 2 -d fd7a:115c:a1e0::/48 -j RETURN
        echo "Added IPv6 exclusion for Tailscale range"
    fi
    
add_mark ip6tables -p tcp --dport 80
add_mark ip6tables -p tcp --dport 443
add_mark ip6tables -p tcp --dport 53
add_mark ip6tables -p udp --dport 53

echo "Exclusing mailports IPv6"
echo "-------------------"

# E-mail
add_bypass ip6tables -p tcp --sport 25
add_bypass ip6tables -p tcp --dport 465
add_bypass ip6tables -p tcp --sport 465
add_bypass ip6tables -p tcp --dport 587
add_bypass ip6tables -p tcp --sport 587
add_bypass ip6tables -p tcp --dport 993
add_bypass ip6tables -p tcp --sport 993
add_bypass ip6tables -p tcp --dport 995
add_bypass ip6tables -p tcp --sport 995
add_bypass ip6tables -p tcp --dport 143
add_bypass ip6tables -p tcp --sport 143
add_bypass ip6tables -p tcp --dport 110
add_bypass ip6tables -p tcp --sport 110

else
    echo "IPv6 disabled, skipping IPv6 rules"
fi

# -----------------------------
# 9. Configure policy routing
# -----------------------------
CURRENT_STEP="9/11: Configuring policy routing"
echo "[$CURRENT_STEP]"

# Clean up any existing rules
ip rule del fwmark $ROUTING_TABLE_ID table $ROUTING_TABLE_NAME 2>/dev/null || true
ip route flush table $ROUTING_TABLE_NAME 2>/dev/null || true

# Add new routing rules
echo "Adding route: default dev tailscale0 table $ROUTING_TABLE_NAME"
if ip route add default dev tailscale0 table $ROUTING_TABLE_NAME 2>&1; then
    echo "Route added"
else
    echo "Route add had warnings (may already exist)"
fi

echo "Adding rule: fwmark $ROUTING_TABLE_ID table $ROUTING_TABLE_NAME priority 100"
if ip rule add fwmark $ROUTING_TABLE_ID table $ROUTING_TABLE_NAME priority 100 2>&1; then
    echo "Rule added"
else
    echo "Rule add had warnings (may already exist)"
fi

# Validate rules were added (check multiple formats)
echo "Validating routing configuration..."
ip rule show > /tmp/ip_rules_debug.txt
ip route show table $ROUTING_TABLE_NAME > /tmp/ip_routes_debug.txt

echo "Current ip rules:"
cat /tmp/ip_rules_debug.txt

echo ""
echo "Current routes in table $ROUTING_TABLE_NAME:"
cat /tmp/ip_routes_debug.txt

# Check for the rule in various formats (fwmark can be shown as hex or decimal)
if ip rule show | grep -E "(fwmark 0xc8|fwmark 0x$ROUTING_TABLE_ID|fwmark $ROUTING_TABLE_ID)" | grep -q "$ROUTING_TABLE_NAME"; then
    echo "Policy routing rule found"
elif ip rule show | grep -q "lookup $ROUTING_TABLE_NAME"; then
    echo "Policy routing rule found (alternate format)"
else
    echo "ERROR: Policy routing rule not found"
    echo "Expected to find: fwmark $ROUTING_TABLE_ID (0xc8) lookup $ROUTING_TABLE_NAME"
    exit 1
fi

if ip route show table $ROUTING_TABLE_NAME | grep -q "default dev tailscale0"; then
    echo "Tailscale route found"
else
    echo "ERROR: Tailscale route not found in table $ROUTING_TABLE_NAME"
    exit 1
fi

echo "Policy routing configured successfully"

# -----------------------------
# 10. Persist firewall rules
# -----------------------------
CURRENT_STEP="10/11: Saving iptables rules"
echo "[$CURRENT_STEP]"
netfilter-persistent save
echo "iptables rules persisted"

# -----------------------------
# 11. Create systemd service
# -----------------------------
CURRENT_STEP="11/11: Installing systemd service"
echo "[$CURRENT_STEP]"

SERVICE_FILE=/etc/systemd/system/tailscale-routing.service
cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=Tailscale selective routing
After=network-online.target tailscaled.service
Wants=network-online.target
Requires=tailscaled.service

[Service]
Type=oneshot
RemainAfterExit=yes

# Wait for tailscale0 interface and connectivity
ExecStartPre=/bin/sh -c 'for i in \$(seq 1 60); do \
    ip link show tailscale0 >/dev/null 2>&1 && \
    tailscale status --json 2>/dev/null | grep -q "100\\\\." && \
    break || sleep 1; \
done'

# Clean up old rules (ignore errors)
ExecStartPre=-/usr/sbin/ip rule del fwmark $ROUTING_TABLE_ID table $ROUTING_TABLE_NAME
ExecStartPre=-/usr/sbin/ip route flush table $ROUTING_TABLE_NAME

# Add policy routing
ExecStart=/usr/sbin/ip route add default dev tailscale0 table $ROUTING_TABLE_NAME
ExecStart=/usr/sbin/ip rule add fwmark $ROUTING_TABLE_ID table $ROUTING_TABLE_NAME priority 100

# Cleanup on stop
ExecStop=/usr/sbin/ip rule del fwmark $ROUTING_TABLE_ID table $ROUTING_TABLE_NAME
ExecStop=/usr/sbin/ip route flush table $ROUTING_TABLE_NAME

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable tailscale-routing.service
systemctl start tailscale-routing.service
echo "Systemd service installed and started"

# Restart Tailscale to ensure clean state
systemctl restart tailscaled
sleep 2
# tailscale up --accept-routes=false --advertise-exit-node=false

# -----------------------------
# Testing and verification
# -----------------------------
echo ""
echo "=== TESTING ROUTING ==="
echo ""

# Get the interface name (usually eth0, but could be different)
DEFAULT_IFACE=$(ip route | grep default | head -n1 | awk '{print $5}')

echo "Testing IP addresses..."
echo "----------------------"

# Test regular interface IP
REGULAR_IP=$(timeout 10 curl -4 --silent --interface "$DEFAULT_IFACE" ifconfig.me 2>/dev/null || echo "FAILED")
echo "Regular interface ($DEFAULT_IFACE) IP: $REGULAR_IP"

# Test routed traffic (should go through Tailscale for port 443)
sleep 2
ROUTED_IP=$(timeout 10 curl -4 --silent ifconfig.me 2>/dev/null || echo "FAILED")
echo "Routed traffic IP: $ROUTED_IP"

echo ""
if [[ "$REGULAR_IP" != "$ROUTED_IP" ]] && [[ "$ROUTED_IP" != "FAILED" ]] && [[ "$REGULAR_IP" != "FAILED" ]]; then
    echo "SUCCESS: Routing appears to be working correctly!"
    echo "  Traffic on port 443 is being routed through Tailscale"
else
    echo "WARNING: Routing may not be working as expected"
    echo "  This could be normal if your Tailscale exit node has the same public IP"
    echo "  Or if the test failed to connect properly. Follow the final step in the README!"
fi

# -----------------------------
# Display status
# -----------------------------
echo ""
echo "=== SETUP COMPLETE ==="
echo ""
echo "Configuration Summary:"
echo "----------------------"
echo "Tailscale IP: $TAILSCALE_IP"
echo "Public IP (via Tailscale): $ROUTED_IP"
echo ""

echo "Tailscale Status:"
echo "----------------------"
tailscale status
echo ""

echo "Active Routing Rules:"
echo "----------------------"
ip rule show | grep -E "($ROUTING_TABLE_NAME|$ROUTING_TABLE_ID)" || echo "No routing rules found (ERROR)"
echo ""

echo "Routing Table ($ROUTING_TABLE_NAME):"
echo "----------------------"
ip route show table $ROUTING_TABLE_NAME
echo ""

echo "Packet Marking Rules:"
echo "----------------------"
iptables -t mangle -L OUTPUT -n -v --line-numbers | head -20
echo ""

echo "Manual Verification Commands:"
echo "----------------------"
echo "  curl -4 ifconfig.me          # Should show Tailscale exit IP"
echo "  curl -4 --interface $DEFAULT_IFACE ifconfig.me  # Shows regular IP"
echo "  traceroute -n 8.8.8.8        # Should show Tailscale route"
echo "  ip route get 8.8.8.8         # Shows which route is used"
echo ""

echo "Service Management:"
echo "----------------------"
echo "  systemctl status tailscale-routing.service"
echo "  systemctl restart tailscale-routing.service"
echo "  journalctl -u tailscale-routing.service -f"
echo ""

echo "Emergency Rollback:"
echo "----------------------"
echo "  systemctl stop tailscale-routing.service"
echo "  systemctl disable tailscale-routing.service"
echo "  iptables-restore < $BACKUP_DIR/iptables.ufw.snapshot"
echo "  ip6tables-restore < $BACKUP_DIR/ip6tables.ufw.snapshot"
echo "  ip rule del fwmark $ROUTING_TABLE_ID table $ROUTING_TABLE_NAME"
echo "  ip route flush table $ROUTING_TABLE_NAME"
echo ""

echo "Logs saved to: $LOG_FILE"
echo "Backups saved to: $BACKUP_DIR"
echo ""
echo "=== Setup completed successfully at $(date) ==="
