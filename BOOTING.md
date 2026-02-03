# Persistent Linux Firewall

In this document we are going to build a triple-layered defense:

- a persistent firewall(initial boot)
- a systemd service (post-service restore)
- a cron canary (continuous monitoring every 5 min)

In this way, we do not have to rely on packages such as `UFW`, `netfilter-persistent` nor `nftables`. Our method is rather safe, because there are few surprises (no strange flushing of tables). Even if you are locked out, a `crontab` will restore the tables properly.

### Why?

Some services, like Tailscale and fail2ban, can flush or overwrite iptables rules on startup or reinstallment which leads to empy iptables. Quite risky! On our system, 
Tailscale clears iptables during its initialization before it reads its own `nf=off` preference - there is no way to prevent this.

The solution is a custom systemd program that runs after boot, and makes sure that the iptables rules are restored, regardless of the programs running before it.

`netfilter-persistent` restores rules -> 

`tailscaled` starts and flushes them -> 

`iptables-restore-onboot` restores them again.

However, sometimes `netfilter-persistent save` doesn't always work properly especially with `nftables` (not recommended), and might flush your tables!

### Proceed

```
# Disable it
sudo systemctl stop nftables
sudo systemctl disable nftables

# Switch to REAL iptables (not the nftables wrapper)
sudo update-alternatives --set iptables /usr/sbin/iptables-legacy
sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy

# Flush nftables completely
sudo nft flush ruleset

# Reload your iptables rules
sudo iptables-restore < /etc/iptables/rules.v4

iptables --version
# Should say "legacy" now

# Disables netfilter-persistent, which can flush your iptables!
sudo systemctl disable netfilter-persistent
sudo systemctl mask netfilter-persistent
sudo apt remove netfilter-persistent iptables-persistent
```

And start using regular `iptables` again.

Create:

`sudo nano /usr/local/bin/firewall`

Paste:

```
#!/bin/bash
iptables-save > /etc/iptables/rules.v4
ip6tables-save > /etc/iptables/rules.v6
echo "Rules saved!"
```

Then:

`sudo chmod +x /usr/local/bin/firewall`

Use It:

```
# When you change rules, save with:
sudo firewall
```

## Saving rules

Whenever you change your iptables rules, save them:

`sudo firewall`

or:

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

# Check if fail2ban is running and restart it to recreate its chains
if systemctl is-active --quiet fail2ban; then
   systemctl restart fail2ban
fi
```

> NOTE: $(seq 1 60); = 5 minutes. Shorter: 15 instead of 60. = 90 seconds. Still, tailscale can be very slow. 5 minutes is safety.

`chmod +x /usr/local/sbin/iptables-restore-onboot.sh`

## The systemd service

`nano /etc/systemd/system/iptables-restore-onboot.service`

```ini
[Unit]
Description=Restore iptables rules after boot
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/iptables-restore-onboot.sh
TimeoutStartSec=60
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

The `After=network.target` is what guarantees this runs last.

Drawback is, it might wait for 30-60 seconds for full reboot. You might have to tweak the TimeoutStartSec, to see whether tailscale boots fast or not. Tailscale can be slow to boot. So 60 seconds is safe.

## Enable it

```bash
sudo systemctl daemon-reload
sudo systemctl enable iptables-restore-onboot.service
sudo systemctl start iptables-restore-onboot.service (might be slow!)
```


# Self-healing crontab

A self-healing crontab is very useful, this gives an extra layer of protection. Although rare, systemd can fail. You might be locked out, or something else causes an issue, like kernel ordering of executing is mixed up or deferred.

To mitigate this we can create a crontab that runs every 5 minutes, regardless of what is going on, and heals the firewall when it detects it was flushed.

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

# Check if fail2ban is running and restart it to recreate its chains
if systemctl is-active --quiet fail2ban; then
   systemctl restart fail2ban
fi
```

Then:

`sudo chmod +x /usr/local/sbin/check-iptables.sh`

Then:

`sudo crontab -e`

Then add:

`*/5 * * * * /usr/local/sbin/check-iptables.sh`

---