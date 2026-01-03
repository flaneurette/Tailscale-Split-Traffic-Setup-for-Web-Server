#!/bin/bash
set -eo pipefail

# Exit Node Health Monitor
# Combines ping checks + Tailscale status + internet connectivity tests
# Run this script 12 times per day via cron
# sudo crontab -e
# 0 */2 * * * /root/check-exit-node.sh

# ============================================================================
# CONFIGURATION
# ============================================================================

EXIT_NODE_IP="100.xx.xx.xx" # Exit node IP, required!
EXIT_NODE_HOSTNAME="your-exit-node-name"  # Get this from: tailscale status
ALERT_EMAIL="info@example.org" # Your e-mail for reports.

PING_DIR="/var/log/exit-node"
FAIL_LOG="$PING_DIR/fail-log.txt"
CURRENT_DATE_FILE="$PING_DIR/current-check.txt"
CONSECUTIVE_LOG="$PING_DIR/consecutive.txt"
SCRIPT_LOG="$PING_DIR/monitor.log"

# Ping settings
PING_TIMES="10"
PACKET_LOSS_THRESHOLD="70"

# Failure thresholds
CONSECUTIVE_REQUIRED="2"       # Must fail twice in a row
DAILY_FAILURE_THRESHOLD="4"    # Trigger after 4 real failures per day

# ============================================================================
# INITIALIZATION
# ============================================================================

mkdir -p "$PING_DIR"

# Only create files if they don't exist
[ ! -f "$SCRIPT_LOG" ] && echo "Monitor started" > "$SCRIPT_LOG"
[ ! -f "$CURRENT_DATE_FILE" ] && touch "$CURRENT_DATE_FILE"

# Initialize counters only if file doesn't exist or doesn't have proper format
if [ ! -f "$FAIL_LOG" ] || ! grep -q "FAIL_COUNT=" "$FAIL_LOG" 2>/dev/null; then
    echo "FAIL_COUNT=0" > "$FAIL_LOG"
fi

if [ ! -f "$CONSECUTIVE_LOG" ]; then
    echo "0" > "$CONSECUTIVE_LOG"
fi

echo "Monitor started" > "$SCRIPT_LOG"

# ============================================================================
# FUNCTIONS
# ============================================================================

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$SCRIPT_LOG"
}

send_alert() {
    echo -e "$2" | mail -s "$1" "$ALERT_EMAIL"
    log_message "Alert sent: $1"
}

get_fail_count() {
    grep -oP "FAIL_COUNT=\K[0-9]+" "$FAIL_LOG" 2>/dev/null || echo 0
}

set_fail_count() {
    echo "FAIL_COUNT=$1" > "$FAIL_LOG"
}

get_consecutive() {
    cat "$CONSECUTIVE_LOG" 2>/dev/null || echo 0
}

set_consecutive() {
    echo "$1" > "$CONSECUTIVE_LOG"
}

# ============================================================================
# HEALTH CHECK FUNCTIONS
# ============================================================================

check_ping() {
    log_message "--- Ping Check ---"
    log_message "Pinging $EXIT_NODE_IP with $PING_TIMES packets..."
    
    set +e
    ping_result=$(ping "$EXIT_NODE_IP" -c "$PING_TIMES" -4 -w 30 -W 20 2>&1)
    ping_exit_code=$?
    set -e
    
    packet_loss=$(echo "$ping_result" | grep -oP '\d+(?=% packet loss)' || echo 100)
    
    log_message "Ping exit code: $ping_exit_code, Packet loss: ${packet_loss}%"
    
    if [ "$ping_exit_code" -eq 0 ] && [ "$packet_loss" -le "$PACKET_LOSS_THRESHOLD" ]; then
        log_message "  PASS: Ping ${packet_loss}% loss (threshold: ${PACKET_LOSS_THRESHOLD}%)"
        return 0
    else
        log_message "  FAIL: Ping ${packet_loss}% loss (threshold: ${PACKET_LOSS_THRESHOLD}%)"
        return 1
    fi
}

check_tailscale_daemon() {
    log_message "--- Tailscale Daemon Check ---"
    
    if systemctl is-active --quiet tailscaled; then
        if tailscale status >/dev/null 2>&1; then
            log_message "  PASS: Tailscale daemon running and responsive"
            return 0
        else
            log_message "  FAIL: Tailscale daemon running but not responsive"
            return 1
        fi
    else
        log_message "  FAIL: Tailscale daemon not running"
        return 1
    fi
}

check_peer_status() {
    log_message "--- Peer Status Check ---"
    
    if ! tailscale status >/dev/null 2>&1; then
        log_message "  FAIL: Cannot get Tailscale status (Tailscale may be stopped)"
        return 1
    fi
    
    peer_online=$(tailscale status --json 2>/dev/null | jq -r ".Peer[] | select(.HostName==\"$EXIT_NODE_HOSTNAME\") | .Online" 2>/dev/null || echo "false")
    
    if [ "$peer_online" = "true" ]; then
        log_message "  PASS: Exit node peer online in tailnet"
        peer_addr=$(tailscale status --json 2>/dev/null | jq -r ".Peer[] | select(.HostName==\"$EXIT_NODE_HOSTNAME\") | .CurAddr" 2>/dev/null || echo "unknown")
        log_message "  INFO: Peer address: $peer_addr"
        return 0
    else
        log_message "  FAIL: Exit node peer offline or not found in tailnet"
        return 1
    fi
}

check_exit_node_active() {
    log_message "--- Exit Node Active Check ---"
    
    if ! tailscale status >/dev/null 2>&1; then
        log_message "  FAIL: Cannot get Tailscale status (Tailscale may be stopped)"
        return 1
    fi
    
    exit_active=$(tailscale status --json 2>/dev/null | jq -r '.ExitNodeStatus.Online // false' 2>/dev/null || echo "false")
    
    if [ "$exit_active" = "true" ]; then
        log_message "  PASS: Exit node actively routing traffic"
        exit_id=$(tailscale status --json 2>/dev/null | jq -r '.ExitNodeStatus.ID // "unknown"' 2>/dev/null || echo "unknown")
        log_message "  INFO: Exit node ID: $exit_id"
        return 0
    else
        log_message "  FAIL: Exit node not actively routing traffic"
        return 1
    fi
}

check_internet_connectivity() {
    log_message "--- Internet Connectivity Check ---"
    
    local test_urls=(
        "https://www.cloudflare.com/cdn-cgi/trace"
        "https://www.google.com"
        "https://1.1.1.1"
    )
    
    local success=0
    for url in "${test_urls[@]}"; do
        if curl -s --max-time 10 "$url" > /dev/null 2>&1; then
            log_message "  PASS: Can reach: $url"
            success=1
            break
        else
            log_message "  FAIL: Cannot reach: $url"
        fi
    done
    
    if [ $success -eq 1 ]; then
        log_message "  PASS: Internet connectivity working"
        return 0
    else
        log_message "  FAIL: All internet connectivity tests failed"
        return 1
    fi
}

perform_comprehensive_health_check() {
    log_message "========================================="
    log_message "COMPREHENSIVE HEALTH CHECK"
    log_message "========================================="
    
    local checks_passed=0
    local checks_total=5
    local check_results=()
    
    if check_ping; then
        ((checks_passed++))
        check_results+=("PASS")
    else
        check_results+=("FAIL")
    fi
    
    if check_tailscale_daemon; then
        ((checks_passed++))
        check_results+=("PASS")
    else
        check_results+=("FAIL")
    fi
    
    if check_peer_status; then
        ((checks_passed++))
        check_results+=("PASS")
    else
        check_results+=("FAIL")
    fi
    
    if check_exit_node_active; then
        ((checks_passed++))
        check_results+=("PASS")
    else
        check_results+=("FAIL")
    fi
    
    if check_internet_connectivity; then
        ((checks_passed++))
        check_results+=("PASS")
    else
        check_results+=("FAIL")
    fi
    
    log_message "========================================="
    log_message "SUMMARY: $checks_passed/$checks_total checks passed"
    log_message "  1. Ping:               ${check_results[0]}"
    log_message "  2. Tailscale daemon:   ${check_results[1]}"
    log_message "  3. Peer status:        ${check_results[2]}"
    log_message "  4. Exit node active:   ${check_results[3]}"
    log_message "  5. Internet:           ${check_results[4]}"
    log_message "========================================="
    
    if [ $checks_passed -ge 4 ]; then
        log_message "RESULT: EXIT NODE HEALTHY (${checks_passed}/${checks_total} passed)"
        return 0
    elif [ "${check_results[0]}" = "PASS" ] && [ "${check_results[4]}" = "PASS" ]; then
        log_message "RESULT: EXIT NODE HEALTHY (core checks passed: ping + internet)"
        return 0
    else
        log_message "RESULT: EXIT NODE UNHEALTHY (only ${checks_passed}/${checks_total} passed)"
        return 1
    fi
}

# ============================================================================
# MAIN LOGIC
# ============================================================================

log_message ""
log_message "========================================="
log_message "EXIT NODE MONITOR STARTED"
log_message "========================================="

# Daily reset check
CURRENT_DATE=$(date +%d/%m/%Y)
LAST_DATE=$(cat "$CURRENT_DATE_FILE" 2>/dev/null || echo "")
if [ "$LAST_DATE" != "$CURRENT_DATE" ]; then
    log_message "New day detected: $CURRENT_DATE (was: $LAST_DATE)"
    set_fail_count 0
    set_consecutive 0
    echo "$CURRENT_DATE" > "$CURRENT_DATE_FILE"
fi

# Get counters
fail_count=$(get_fail_count)
consecutive=$(get_consecutive)

log_message "Current counters:"
log_message "  - Daily failures: $fail_count/$DAILY_FAILURE_THRESHOLD"
log_message "  - Consecutive failures: $consecutive/$CONSECUTIVE_REQUIRED"

# Exit if already disabled today
if [ "$fail_count" -ge "$DAILY_FAILURE_THRESHOLD" ]; then
    log_message "Exit node already considered dead today. Skipping check."
    log_message "========================================="
    exit 0
fi

# Perform comprehensive health check
if perform_comprehensive_health_check; then
    # SUCCESS - All good
    set_consecutive 0
    log_message ""
    log_message "Exit node is operational. Resetting consecutive counter."
    
else
    # FAILURE - Something is wrong
    consecutive=$((consecutive + 1))
    set_consecutive "$consecutive"
    
    log_message ""
    log_message "WARNING: Health check failed"
    log_message "Consecutive failures: $consecutive/$CONSECUTIVE_REQUIRED"
    
    # Check if we've hit consecutive threshold
    if [ "$consecutive" -ge "$CONSECUTIVE_REQUIRED" ]; then
        # This is a REAL failure
        fail_count=$((fail_count + 1))
        set_fail_count "$fail_count"
        
        log_message ""
        log_message "REAL FAILURE RECORDED"
        log_message "Daily failure count: $fail_count/$DAILY_FAILURE_THRESHOLD"
        
        # Check if we've reached daily threshold
        if [ "$fail_count" -ge "$DAILY_FAILURE_THRESHOLD" ]; then
            log_message ""
            log_message "========================================"
            log_message "THRESHOLD REACHED - TAKING ACTION"
            log_message "========================================"
            
            # Prepare detailed alert
            ALERT_BODY="CRITICAL: Exit Node Failure Detected

Exit Node Information:
- Hostname: $EXIT_NODE_HOSTNAME
- IP: $EXIT_NODE_IP
- Date: $CURRENT_DATE
- Time: $(date '+%H:%M:%S')

Failure Statistics:
- Daily failures: $fail_count/$DAILY_FAILURE_THRESHOLD
- Consecutive failures: $consecutive

Health Check Results:
See detailed log at: $SCRIPT_LOG

Action Taken:
Tailscale has been automatically disabled to allow system updates.

REQUIRED ACTIONS:
1. SSH to exit node and check status
2. Verify Tailscale daemon is running: systemctl status tailscaled
3. Check exit node system resources and network
4. Review exit node logs: journalctl -u tailscaled -n 50
5. Re-enable Tailscale on this machine after resolving:
----------------------------------------------------------
sudo systemctl restart tailscaled
sudo tailscale up --accept-routes=false --advertise-exit-node=false --exit-node-allow-lan-access --exit-node=$EXIT_NODE_IP
tailscale status
----------------------------------------------------------

Timeline:
This machine has been checking every ~2 hours.
$fail_count failures occurred over the course of today.

DO NOT ignore this alert - production updates may be blocked."

            # Send alert
            send_alert "CRITICAL: Exit Node Dead - Tailscale Disabled" "$ALERT_BODY"
            
            # Disable Tailscale
            log_message ""
            log_message "Disabling Tailscale..."
            if sudo tailscale down; then
                log_message "Tailscale successfully disabled"
            else
                log_message "ERROR: Failed to disable Tailscale"
            fi
            
        else
            log_message "Daily threshold not yet reached. Continuing monitoring."
        fi
        
    else
        log_message "Waiting for consecutive failures before counting as real failure."
        log_message "Need $((CONSECUTIVE_REQUIRED - consecutive)) more consecutive failure(s)."
    fi
fi

log_message ""
log_message "========================================="
log_message "EXIT NODE MONITOR COMPLETED"
log_message "========================================="
log_message ""

exit 0
