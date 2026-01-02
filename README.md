# Using Tailscale split traffic tunnels.

One powerful feature of Tailscale is the exit node function. If you have a public webserver, you can route all outbound traffic (like `apt updates`, `curl`, or `wget` requests) through another machine on your Tailscale network, such as a home server or other cheap VPS. This means your server's requests appear to come from your home IP or other VPS IP, instead of the public server VPS IP.

```
┌─────────────────────┐
│  Public Web Server  │  (Your main VPS - $10-20/mo)
│  - Web services     │
│  - Email (direct)   │  Email uses public IP (ports 25, 587, 993)
│  - Public facing    │
└──────────┬──────────┘
           │
           │ Tailscale encrypted tunnel route all outbound traffic, not inbound (web) traffic.
           │ (HTTP/HTTPS/SSH/DNS/apt traffic)
           │
           ▼
┌─────────────────────┐
│  Exit Node VPS      │  (Cheap throwaway VPS - $1-5/mo - or home server)
│  - 1-2 CPU cores    │
│  - 512MB-1GB RAM    │  Minimal specs needed, extremely hardened: only tailscale running, nothing else.
│  - 10-20GB storage  │
│  - Tailscale only   │
│  - DNS filtering    │
└──────────┬──────────┘
           │
           ▼
      Internet
```

## Requirements:

- Your public webserver (Linux)
- A cheap low key VPS with dedicated IP (few specs, use the cheapest you can get: 1 or 2 cores, 1-4GB RAM.) i.e. https://lowendbox.com
- OR: A small home server, instead of the cheap VPS.
  
## Benefits

- Public IP protection: Your public server's IP is never exposed when downloading packages or making external requests. This reduces your attack surface, reduces MITM attacks, ISP downtimes, and makes it harder for malicious actors to profile your server's behavior.

- Traffic encryption beyond the server: Even if someone is monitoring the network at the data center, places wiretaps (rare), sniff network traffic (even rarer, but a risk), they only see encrypted Tailscale traffic. The actual destinations and content of your requests are hidden.

- Custom DNS filtering: Route traffic through a home network with advanced DNS blocklists (e.g., Pi-hole, AdGuard Home, or NextDNS at the router level). This prevents your server from connecting to known malware domains, botnet C&C servers, or newly registered domains often used in attacks.
  
- Decoy IP address: If your server is compromised and connects to a botnet C&C server or phone-home endpoint, the attacker receives your home or other VPS IP instead of your server's IP. This renders ISP-level attacks against your server useless, as they would target the wrong infrastructure. The attacker cannot DDoS your server or use your server IP for further attacks since they don't actually have it.

- Email compatibility: By excluding email ports from the tunnel, your mail server maintains proper SPF, DKIM, and reverse DNS records, ensuring email deliverability isn't affected.

- Reduce "phone-home" calls: If your server or any installed software were compromised, DNS filtering and traffic monitoring can help block or detect unauthorized communication attempts.

- Lessen attack surface: If software is rooted, changed, compromised or hijacked at installations or updates, your IP remains a mystery as to whom requested updates. If that software makes outbound requests, your IP is also not visible, but the decoy is presented to the attacker. Rendering such attack completely useless.

## How Tailscale exit nodes work

When you configure a device as an exit node:
- It advertises itself to your Tailscale network (tailnet)
- Other devices in your tailnet can route their internet traffic through it
- All traffic is encrypted end-to-end using WireGuard
- Only authenticated devices in your tailnet can use it - there's no public access

## Setup guide

### 1. Set up the home server (exit node)

```bash
# Install Tailscale
curl -fsSL https://tailscale.com/install.sh | sh

# Start Tailscale and authenticate
sudo tailscale up

# Advertise this machine as an exit node
sudo tailscale up --advertise-exit-node

# Enable IP forwarding (required for exit node)
echo 'net.ipv4.ip_forward = 1' | sudo tee -a /etc/sysctl.d/99-tailscale.conf
echo 'net.ipv6.conf.all.forwarding = 1' | sudo tee -a /etc/sysctl.d/99-tailscale.conf
sudo sysctl -p /etc/sysctl.d/99-tailscale.conf
```

Important: After running `--advertise-exit-node`, you must approve this in the Tailscale admin console:
1. Go to https://login.tailscale.com/admin/machines
2. Find your home server
3. Click the three dots menu
4. Enable "Use as exit node"

### 2. Configure the PUBLIC webserver

Configure the public webserver (with split tunneling)

> Move `undo-routing.sh` to the server. This is used to undo all routing tables for tailscale, in case of emergency or error.

Edit `create-routing.sh`, or leave as is. This is where we configure selective routing. We'll route ports 80, 443, 22, and 53 through Tailscale, but keep email ports (25, 465, 587, 993, 995) direct.

> Be sure to set a backup IP address for SSH access: `SAFE_SSH_IP="your.backup.ssh.ip"` REQUIRED!
> This could also be the public server IP address.
> By default, the script also adds your curent SSH client IP, to prevent lockouts.

NOTE: Run this on the PUBLIC server, NOT the exit node
- Move `create-routing.sh` to /root/ or /usr/local/bin/
- Make executable: `chmod +x create-routing.sh`
- Run: `sudo ./create-routing.sh`

During installation of tailscale, you are being shown a URI. Use: `Ctrl+Shift+C` to open that URI in your browser, then you need to accept the device in the tailscale admin.
If it fails, run the script for a second time. It will usually run and fix things properly.

### Then you MUST do this:

`systemctl restart tailscaled`

`sudo systemctl enable tailscale-routing.service`

`tailscale up --accept-routes=false --advertise-exit-node=false --exit-node-allow-lan-access --exit-node=<EXIT.NODE.IP.HERE>`

To survive reboots. Remember to replace the EXIT NODE IP with the VPS exit node (not your public webserver IP)

If not working:

`sudo tailscale up --reset`

`sudo ./undo-routing.sh`

And try again. Remember, a small error doesn't mean it didn't work. Simply check if the connections are routed:

`curl -s icanhazip.com ` -> should show your exit node IP.

## How the split tunneling works

Here's what happens with the configuration:

    Traffic to ports 80, 443, 22, 53:
        Marked with fwmark 200 by iptables
        Routed through the tailscale routing table
        Goes through the Tailscale exit node
        Appears to come from your home IP

    Traffic to ports 25, 465, 587, 993, 995 (email):
        Not marked by iptables
        Uses the default main routing table
        Goes directly through your server's public IP
        Maintains proper email reputation and SPF/DKIM

    All other traffic:
        Not marked by iptables
        Uses the default main routing table
        Goes directly through your server's public IP

## Security best practices

### 1. Use Tailscale ACLs (access control lists)

Restrict which devices can use your exit node. In the Tailscale admin console, go to Access Controls and add something like this (consult tailscale documentation if uncertain):

```json
{
  "acls": [
    {
      "action": "accept",
      "src": ["webserver@yourdomain.com"],
      "dst": ["home-server:*"]
    }
  ],
  "nodeAttrs": [
    {
      "target": ["home-server"],
      "attr": ["exit-node"]
    }
  ]
}
```

This ensures only your webserver can use the home server as an exit node.

### 2. Harden the home exit node

```bash
# Only accept traffic on the Tailscale interface
sudo iptables -A INPUT -i tailscale0 -j ACCEPT
sudo iptables -A FORWARD -i tailscale0 -j ACCEPT
sudo iptables -A FORWARD -o tailscale0 -j ACCEPT

# Allow established connections and loopback
sudo iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
sudo iptables -A INPUT -i lo -j ACCEPT

# Allow SSH from your local network (adjust as needed)
sudo iptables -A INPUT -s 192.168.1.0/24 -p tcp --dport 22 -j ACCEPT

# Drop everything else
sudo iptables -A INPUT -j DROP

# Save rules
sudo apt install iptables-persistent
sudo netfilter-persistent save
```

### 3. Don't advertise subnet routes (unless needed)

Only advertise as an exit node. Do not expose your home LAN unless you specifically need it:

```bash
# Good (exit node only):
sudo tailscale up --advertise-exit-node

# Avoid this unless you need home LAN access:
sudo tailscale up --advertise-exit-node --advertise-routes=192.168.1.0/24
```

### 4. Enable two-factor authentication

On your Tailscale account:
1. Go to https://login.tailscale.com/admin/settings/keys
2. Enable 2FA
3. Enable device authorization (require manual approval for new devices)
4. Set key expiry (e.g., 180 days)

### 5. Monitor traffic

On the home server, monitor unusual activity:

```bash
# Watch active connections
sudo watch -n 2 'ss -tunap | grep tailscale'

# Monitor bandwidth usage
sudo iftop -i tailscale0

# Or
sudo apt install vnstat -y
sudo vnstat

# Check Tailscale logs
sudo journalctl -u tailscale -f
```

### 6. Separate network segment (advanced)

For maximum security, run your exit node on a separate VLAN or in a DMZ, isolated from your personal devices.

## What attackers cannot do

Your home exit node is not a public VPN. Here's what's impossible:

- Scan your home IP for open VPN ports (there are none)
- Guess credentials or brute force access
- Use your IP as a proxy without authentication
- Discover it via Shodan, Nmap, or other scanning tools
- DDoS through your exit node
- Access it from outside your Tailscale network

### Why?

Three layers of protection:

1. Identity-based authentication: Every device needs a valid node key tied to your account. Unknown devices are rejected before any networking occurs.

2. Mandatory WireGuard encryption: All traffic is encrypted end-to-end. Even if someone intercepts the connection, they see only encrypted noise.

3. ACLs: You explicitly control which devices can use the exit node and what they can access.

### Realistic threat model

Your exit node could only be abused if:

- Someone compromises your Tailscale account (mitigated by 2FA)
- Someone steals a trusted device (revoke access immediately)
- You accidentally approve an unauthorized device (enable manual approval)
- You misconfigure ACLs (review regularly)

All of these are administrative attacks, not network-level exploits.

## Advanced: split tunneling

If you want only specific traffic to use the exit node (not everything), you can configure split tunneling:

```bash
# On the webserver, don't use --exit-node globally
sudo tailscale up

# Instead, route specific commands through the exit node using network namespaces
# Create a namespace
sudo ip netns add vpn

# Move tailscale interface to namespace
sudo ip link set tailscale0 netns vpn

# Run specific commands in that namespace
sudo ip netns exec vpn curl ifconfig.me
sudo ip netns exec vpn apt update
```

Note: This is complex and may break Tailscale's automatic configuration. The simple global exit node approach is recommended for most use cases.

## Disabling the exit node

### On the webserver (stop using the exit node):

```bash
sudo tailscale up --exit-node=
```

### On the home server (stop advertising as an exit node):

```bash
sudo tailscale up
```

You may also need to disable it in the admin console.

## Troubleshooting

### Exit node not working

```bash
# Check Tailscale status
sudo tailscale status

# Check IP forwarding is enabled
sysctl net.ipv4.ip_forward
sysctl net.ipv6.conf.all.forwarding

# Verify exit node is approved in admin console
# https://login.tailscale.com/admin/machines

# Check firewall isn't blocking
sudo iptables -L -n -v
```

### DNS not using home server

```bash
# Ensure you used --accept-dns
sudo tailscale up --exit-node=<HomeServer> --accept-dns

# Check DNS configuration
resolvectl status
# or
cat /etc/resolv.conf
```

### Performance issues

```bash
# Check latency to exit node
ping $(tailscale ip home-server)

# Test bandwidth
iperf3 -s  # on home server
iperf3 -c $(tailscale ip home-server)  # on webserver
```

## Comparison to commercial VPNs

Your home exit node is more secure than commercial VPN services because:

- No shared users or infrastructure
- No public access point
- Identity-based networking (not password-based)
- End-to-end encryption you control
- Fine-grained policy control via ACLs
- No logging by third parties
- No exit node IP shared with potentially malicious users

You're not opening your home to the internet. You're creating a private, authenticated, encrypted tunnel between devices you own.

## Summary

Tailscale exit nodes provide a simple, secure way to route your server's outbound traffic through a trusted machine. The setup is straightforward, the security model is robust, and you gain significant benefits in terms of privacy, monitoring, and control.

Key takeaway: You're not exposing your home network. Only authenticated devices in your Tailscale network can use the exit node, and all traffic is encrypted end-to-end.
