# Quick checks

Quick oneliners if something fails or is missing.

## 1. Allow SSH from Tailscale interface

```bash
iptables -A INPUT -i tailscale0 -p tcp --dport 22 -j ACCEPT
```

That’s usually enough.

This rule says:

* incoming packets
* on interface `tailscale0`
* TCP
* destination port 22 (SSH)
* accept them

---

## 2. Make sure ESTABLISHED traffic is allowed (important)

If you don’t already have this (most setups do):

```bash
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
```

Without this, SSH may connect but behave oddly.

---

## 3. (Optional but recommended) Drop SSH elsewhere

Only if: ALLOW -> DROP. 

Not if: DROP -> ALLOW.

Check first with: `iptables -L -n` (look at first ro to determine ORDER)

If you want SSH **only via Tailscale**, make sure you do **not** have a broad SSH allow rule earlier, and then explicitly drop it:

```bash
iptables -A INPUT -p tcp --dport 22 -j DROP
```

Order (sometimes, depending on iptables layout) matters:

* `ACCEPT tailscale0 :22`
* then `DROP :22`

**Only do this if your current tables are dropping AFTER, instead of BEFORE (which should be!)**

---

## 4. Check rule order

List with line numbers:

```bash
iptables -L INPUT -n -v --line-numbers
```

If the DROP rule is *above* the Tailscale rule, it (sometimes) won’t work.
If needed, insert instead of append:

```bash
iptables -I INPUT 1 -i tailscale0 -p tcp --dport 22 -j ACCEPT
```

---

## 5. Verify traffic is actually using tailscale0

On the server:

```bash
ip a show tailscale0
```

And when connected from your client:

```bash
ss -tn sport = :22
```

or watch live:

```bash
tcpdump -i tailscale0 port 22
```

---

## 6. Persistence (important)

Depending on your distro:

### Debian / Ubuntu

```bash
apt install iptables-persistent
iptables-save > /etc/iptables/rules.v4
netfilter-persistent save
```

### Or manually on reboot

Put rules in a script or systemd unit.

---

### Quick sanity check

From your Tailscale client:

```bash
ssh user@100.x.y.z
```

---

## 1. Enable IP forwarding on the server (mandatory)

### Temporarily (until reboot)

```bash
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1
```

### Persistently

Edit `/etc/sysctl.conf` (or a file in `/etc/sysctl.d/`):

```conf
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
```

Apply:

```bash
sysctl -p
```

---

## 2. Advertise the exit node via Tailscale

Run **on the server**:

```bash
tailscale up --advertise-exit-node
```

That’s it on the server side.

If Tailscale is already up with other flags (subnets, auth, etc.), re-run with **all flags included**, for example:

```bash
tailscale up \
  --advertise-exit-node \
  --ssh=false
```

(Tailscale replaces flags, it doesn’t merge them.)

---

## 3. Approve the exit node (admin console)

Go to:

```
https://login.tailscale.com/admin/machines
```

* Find your server
* Toggle **“Use as exit node”**

Until this is approved, clients won’t see it.

---

## 4. Firewall / iptables requirements (important)

For an exit node you may also need **forwarding + NAT**.

### Allow forwarding from tailscale0

```bash
iptables -A FORWARD -i tailscale0 -j ACCEPT
iptables -A FORWARD -o tailscale0 -j ACCEPT
```

### Enable NAT (MASQUERADE)

Replace `eth0` if your WAN interface is different:

```bash
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
```

Without NAT, exit node traffic may not work.

---

## 5. Persist iptables rules


```bash
iptables-save > /etc/iptables/rules.v4
netfilter-persistent save
```


---

## 6. Use it from a client

On a client machine:

```bash
tailscale up --exit-node=<server-name-or-100.x>
```

Or via GUI:

* Select **Use exit node**
* Pick your server

Verify:

```bash
curl ifconfig.me
```

It should show your **server’s public IP**.

---

## 7. Sanity checks if something doesn’t work

On server:

```bash
tailscale status
```

Look for:

```
exit node: yes
```

Check forwarding:

```bash
sysctl net.ipv4.ip_forward
```

Watch traffic:

```bash
tcpdump -i tailscale0
```

---

### Summary 

* `tailscale0` = trusted internal interface
* SSH allowed on `tailscale0`
* Exit node = forwarding + NAT + admin approval
* Tailscale handles encryption & routing, **you handle firewall reality**
