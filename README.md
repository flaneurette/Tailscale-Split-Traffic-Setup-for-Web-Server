# Using Tailscale exit nodes for secure server traffic

One powerful feature of Tailscale is the exit node function. If you have a public webserver, you can route all outbound traffic (like `apt updates`, `curl`, or `wget` requests) through another machine on your Tailscale network, such as a home server. This means your server's requests appear to come from your home IP instead of the VPS IP.

## Benefits

- Public IP protection: Your public server's IP is never exposed when downloading packages or making external requests. This reduces your attack surface and makes it harder for malicious actors to profile your server's behavior.

- Traffic encryption beyond the server: Even if someone is monitoring the network at your data center, they only see encrypted Tailscale traffic. The actual destinations and content of your requests are hidden.

- Custom DNS filtering: Route traffic through a home network with advanced DNS blocklists (e.g., Pi-hole, AdGuard Home, or NextDNS at the router level). This prevents your server from connecting to known malware domains, botnet C&C servers, or newly registered domains often used in attacks.

- Centralized monitoring: By routing through your home network, you gain visibility into your server's outbound connections. You can detect unusual patterns and quickly block suspicious traffic if your server is compromised.

- Reduce "phone-home" calls: If your server or any installed software were compromised, DNS filtering and traffic monitoring can help block or detect unauthorized communication attempts.

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

### 2. Configure the public webserver

```bash
# Install Tailscale
curl -fsSL https://tailscale.com/install.sh | sh

# Connect to Tailscale and use the home server as exit node
sudo tailscale up --exit-node=<HomeServerName> --accept-dns

# Replace <HomeServerName> with either:
# - The machine name (e.g., home-server)
# - The Tailscale IP (e.g., 100.x.x.x)
```

### 3. Verify it's working

```bash
# Check your public IP (should show your home IP)
curl ifconfig.me
# or
curl icanhazip.com

# Verify Tailscale status and exit node
tailscale status

# Should show something like:
# 100.x.x.x   home-server   user@      linux   active; exit node; ...

# Test DNS resolution (should use home DNS if configured)
nslookup google.com

# Check routing
ip route show table all | grep tailscale
```

## Security best practices

### 1. Use Tailscale ACLs (access control lists)

Restrict which devices can use your exit node. In the Tailscale admin console, go to Access Controls and add:

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
