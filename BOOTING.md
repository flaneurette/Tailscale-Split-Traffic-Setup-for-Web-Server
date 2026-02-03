# Booting the server

Sometimes, and most likely, tailscale can flush your iptables. Which is annoying.

After setting up tailscale on the `exit node`, run this:

`sudo systemctl disable tailscaled`

`tailscale up --netfilter-mode=off --advertise-exit-node`

On the `public server`, run this:

`tailscale up --accept-routes=false --advertise-exit-node=false --exit-node-allow-lan-access --netfilter-mode=off --exit-node=<EXIT.NODE.IP.HERE>`

From then on, manage the tailscale firewall rules yourself.

# Persistent firewall

Some services, like Tailscale and fail2ban, can flush or overwrite iptables rules on startup. On this system, Tailscale clears iptables during its initialization before it reads its own `nf=off` preference - there is no way to prevent this. The solution is a systemd service that restores your rules *after* Tailscale has started.

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
iptables-restore < /etc/iptables/rules.v4
ip6tables-restore < /etc/iptables/rules.v6
```

`chmod +x /usr/local/sbin/iptables-restore-onboot.sh`:

## The systemd service

`/etc/systemd/system/iptables-restore-onboot.service`:

```ini
[Unit]
Description=Restore iptables rules after Tailscale
After=network.target tailscaled.service
Wants=network.target tailscaled.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/iptables-restore-onboot.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

The `After=tailscaled.service` is what guarantees this runs last.

## Enable it

```bash
sudo systemctl enable iptables-restore-onboot
sudo systemctl daemon-reload
```



