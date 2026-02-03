# Persistent firewall

Some services, like Tailscale and fail2ban, can flush or overwrite iptables rules on startup or reinstallment. On this system, Tailscale clears iptables during its initialization before it reads its own `nf=off` preference - there is no way to prevent this. The solution is a systemd service that restores your rules *after* Tailscale has started.

The solution is a custom systemd program that runs after boot, and makes sure that the iptables rules are restored, regardless of the programs running before it.

The boot order is: 

`netfilter-persistent` restores rules -> 

`tailscaled` starts and flushes them -> 

`iptables-restore-onboot` restores them again.

## Saving rules

Whenever you change your iptables rules, save them:

```bash
sudo iptables-save > /etc/iptables/rules.v4
sudo ip6tables-save > /etc/iptables/rules.v6
```

This writes your current rules to `/etc/iptables/rules.v4` and `/etc/iptables/rules.v6`.

## The restore script

Example for `tailscale`. Replace your `service` if you want to check another one.

`nano /usr/local/sbin/iptables-restore-onboot.sh`

Paste:

```bash
#!/bin/bash
# Wait for tailscaled to start, timeout after 5 minutes
for i in $(seq 1 60); do
    if systemctl is-active --quiet tailscaled; then
        sleep 5  # Give it a moment to finish flushing
        break
    fi
    sleep 5
done

# Restore regardless of whether tailscaled started or not
iptables-restore < /etc/iptables/rules.v4
ip6tables-restore < /etc/iptables/rules.v6
```

`chmod +x /usr/local/sbin/iptables-restore-onboot.sh`

## The systemd service

`nano /etc/systemd/system/iptables-restore-onboot.service`

```ini
[Unit]
Description=Restore iptables rules after boot
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/iptables-restore-onboot.sh
TimeoutStartSec=30
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

The `After=network.target` is what guarantees this runs last.

## Enable it

```bash
sudo systemctl daemon-reload
sudo systemctl enable iptables-restore-onboot.service
sudo systemctl start iptables-restore-onboot.service
```

# Self-healing crontab

Run this first:

```
sudo iptables -I INPUT 2 -s 203.0.113.99 -m comment --comment "CANARY-ADMIN" -j DROP
```

The above adds a “dummy rule” as a canary to check whether your iptables have been wiped or not.

> Note: 203.0.113.0/24 and 2001:db8::/32 are TEST-NET ranges - they're reserved and will never be routed on the internet, so they're perfect for canaries.


```
sudo iptables-save > /etc/iptables/rules.v4
sudo ip6tables-save > /etc/iptables/rules.v6
```

Then:

`nano /usr/local/sbin/check-iptables.sh`

Paste:

```
#!/bin/bash
# Check if the dummy rule exists

LOG=/var/log/iptables-check.log

restore_needed=0

# Check for top canary (catches early flush)
if ! iptables -C INPUT -s 203.0.113.99 -m comment --comment "CANARY-ADMIN" -j DROP &>/dev/null; then
    echo "$(date): IPv4 top canary missing" >> "$LOG"
    restore_needed=1
fi

if [ $restore_needed -eq 1 ]; then
    echo "$(date): Canary missing - restoring iptables..." >> "$LOG"
    
    [ -f /etc/iptables/rules.v4 ] && iptables-restore < /etc/iptables/rules.v4
    [ -f /etc/iptables/rules.v6 ] && ip6tables-restore < /etc/iptables/rules.v6
    
    echo "$(date): Rules restored successfully" >> "$LOG"
fi
```

Then:

`sudo chmod +x /usr/local/sbin/check-iptables.sh`

Then:

`sudo crontab -e`

Then add:

`*/5 * * * * /usr/local/sbin/check-iptables.sh`

---