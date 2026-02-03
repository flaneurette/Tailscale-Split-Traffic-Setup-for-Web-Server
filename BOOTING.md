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
sudo netfilter-persistent save
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
TimeoutStartSec=360
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
sudo iptables -A INPUT -m comment --comment "DUMMY-CHECK" -j DROP
sudo ip6tables -A INPUT -m comment --comment "DUMMY-CHECK" -j DROP
```

The above adds a “dummy rule” as a canary to check whether your iptables have been wiped or not.

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
if ! iptables -C INPUT -m comment --comment "DUMMY-CHECK" -j DROP &>/dev/null; then
    echo "$(date): Dummy rule missing, restoring iptables..."
    iptables-restore < /etc/iptables/rules.v4
    ip6tables-restore < /etc/iptables/rules.v6
fi
```

Then:

`sudo chmod +x /usr/local/sbin/check-iptables.sh`

Then:

`sudo crontab -e`

Then:

`*/5 * * * * /usr/local/sbin/check-iptables.sh`

---

