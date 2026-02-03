# Persistent firewall

Some services, like Tailscale and fail2ban, can flush or overwrite iptables rules on startup or reinstallment. On this system, Tailscale clears iptables during its initialization before it reads its own `nf=off` preference - there is no way to prevent this. The solution is a systemd service that restores your rules *after* Tailscale has started.

The solution is a custom systemd program that runs after boot, and makes sure that the iptables rules are restored, regardless of the programs running before it.

The boot order is: `netfilter-persistent` restores rules -> `tailscaled` starts and flushes them -> `iptables-restore-onboot` restores them again.

## Saving rules

Whenever you change your iptables rules, save them:

```bash
sudo netfilter-persistent save
```

This writes your current rules to `/etc/iptables/rules.v4` and `/etc/iptables/rules.v6`.

## The restore script

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
sudo systemctl enable iptables-restore-onboot
sudo systemctl daemon-reload
```



