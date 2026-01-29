# Server Hostname Privacy

Sometimes, tailscale might edit your Postfix configuration to add a tail address as hostname. Such as: `tailv12345.ts.net`. This is a privacy risk, can lead to exposure of the tailscale tail address, which we want to avoid to gain maximum privacy.

Edit:

`sudo nano /etc/postfix/main.cf`

Change the hostname back to what you want it to show:

`myhostname = myserver`

Then:

`sudo systemctl restart postfix`

### Verify:

`telnet <your-server-ip> 25`

You should now see something like:

`220 myserver ESMTP Postfix`

Also check: `hostname` or `hostname -f` to be sure nothing leaks.

---

### Extra precautions

If you want maximum privacy:

1. Bind Postfix to only the public IP:

`inet_interfaces = 127.0.0.1, <your-public-ip>`

This prevents Tailscale's internal hostname from leaking if Tailscale changes it again.

2. Explicitly set `smtpd_banner` in `main.cf`:

`smtpd_banner = $myhostname ESMTP`

---

### Risks

If the tailscale address is exposed, it could be used in finegrained attacks such as:

- Spammer relays

- Social engineering tailscale/admin

- Spoofing

- General intel.

---

### Advanced hostname fix.

It is wise to not to expose a **bucket id**, or a **server id** in the hostname, as attackers could use this to social engineer your ISP with that specific bucket or server ID address.

Check your current hostname

```
hostname
hostname -f
hostnamectl status
```

You could see something like this which could expose a unique ID:

```
superserver-12345
```

That info can be used to social engineer your host/ISP, because a unique ID is now known.

---

#### Set a new hostname (temporary)

`sudo hostnamectl set-hostname MyServerName`

This immediately changes the hostname for the running system.

If you run `hostname` again, it will show it.

---

#### Make it fully persistent

`hostnamectl` is persistent across reboots, so step 2 is usually enough.

But you can double-check in `/etc/hostname`:

`cat /etc/hostname`

It should now show:

`MyServerName`

If not, edit it manually:

`sudo nano /etc/hostname`

Replace the content with your new hostname, e.g., `MyServerName`.

Save and exit.

---

#### Update `/etc/hosts`

You should also update `/etc/hosts` so the new hostname resolves locally:

`sudo nano /etc/hosts`

Look for a line like:

`127.0.1.1 superserver-12345`

Change it to:

`127.0.1.1 MyServerName`

Save and exit.

---

#### Restart services

Some services read the hostname at start, so restart Postfix and any other services:

```
sudo systemctl restart postfix
sudo systemctl restart ssh
```

You can also reboot the server if you want everything fully consistent:

`sudo reboot`

---
