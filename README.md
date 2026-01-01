# Using Tailscale exit nodes for secure server traffic

One neat way of using Tailscale is the exit node function. If we have a public webserver, we can make sure that any traffic the server requests—such as updates, `curl`, or `wget` requests—are routed through another IP, such as your home IP. 

## Benefits

1. On-site protection: No one in the vicinity of the server can tap or tamper with the wire or upstream connection. If they did, they would have to decrypt the Tailscale stream. This prevents tampering on-site, which can be a concern in specific data centers or targeted attacks.

2. Home server routing: We could host a small server at home that runs 24/7 and routes that traffic for your public server. This ensures that the server's traffic is encrypted and anonymized.

3. Public IP protection: Our public server's IP is never exposed when downloading or updating things. This reduces attack surfaces and the ability for malicious actors to profile the server.

4. Custom DNS filtering: We could use advanced DNS blocklists from home (e.g., routed through NextDNS), preventing our server from connecting to maliciously labeled IP addresses. This reduces "phone-home" calls if the server were compromised.

5. Real-time monitoring: Routing through home gives more control over the server's outgoing traffic in real time, allowing for quick blocking if needed (e.g., in case of server compromise, botnet assignment, or takeover).

## Tailscale setup example

### On the home server (exit node)

```bash
# Install Tailscale
curl -fsSL https://tailscale.com/install.sh | sh

# Authenticate and advertise as exit node
sudo tailscale up --advertise-exit-node
```

### On the public webserver

```bash
# Install Tailscale
curl -fsSL https://tailscale.com/install.sh | sh

# Connect to Tailscale and use the home server as exit node
sudo tailscale up --exit-node=<HomeServerIPorNodeName>
```

### Verifying traffic

```bash
# Check public IP to ensure traffic is going through home server
curl icanhazip.com

# Check Tailscale status
tailscale status
```

### Disabling exit node on webserver

```bash
# Reset to direct connection (no exit node)
sudo tailscale up --reset
```

## Security considerations

- Preventing abuse of home server: Only authorized devices on your Tailscale network should use your home server as an exit node. Tailscale's authentication ensures that random outsiders cannot connect.
- Restrict allowed routes and ports: Configure your home server to only allow the traffic you want to proxy. For example, allow only HTTP (80), HTTPS (443), and SSH (22) from your public server:
```bash
sudo iptables -A INPUT -p tcp -m multiport --dports 22,80,443 -s <PublicServerIP> -j ACCEPT
sudo iptables -A INPUT -j DROP
```
- Monitor traffic: Keep an eye on unusual traffic patterns from your home server to detect misconfigurations or potential misuse.
- Use ACLs: Tailscale ACLs can restrict which devices can use the exit node and what subnets or ports they can access, adding an extra layer of control.
- Separate home network: Ideally, the exit-node home server runs on a network segment separate from your personal devices to reduce risk.

```


```markdown
# Tailscale Exit Node: Safety and Best Practices

## 1. The most important point (reassurance first)

Tailscale exit nodes are NOT public VPNs.

Even if:

- your home server is online 24/7  
- it advertises itself as an exit node  

Only authenticated devices in your Tailscale tailnet can even see it, let alone route traffic through it.

There is:

- no open port  
- no "connect by IP"  
- no anonymous access  
- no scanning possible from the internet  

An attacker on the public internet cannot discover or use your exit node.

---

## 2. Why nobody else can connect (under the hood)

Tailscale enforces three layers of protection:

1. Identity-based authentication  

- Every device has a node key  
- Keys are tied to your account / domain  
- Unknown devices are rejected before networking even starts  
- This happens before any packets flow

2. WireGuard encryption (mandatory)  

- All traffic is encrypted end‑to‑end  
- No shared secrets  
- No "password VPN"  
- Even if someone MITMs the line:  
  - they see encrypted noise  
  - they cannot inject packets

3. ACLs (Access Control Lists)  

- You can explicitly say:  
  "Only these devices may use this exit node"  
- Even devices in your own tailnet can be blocked

---

## 3. Locking down the exit node properly (recommended)

### Step 1: Restrict exit node usage via ACLs

In the Tailscale Admin Console → Access Controls


What this does:

- Only your Windows/Linux PC can use the exit node  
- The exit node cannot be abused by other devices  
- No accidental sharing later  
- This is the strongest control you can apply

---

## 4. Prevent lateral abuse even inside the tailnet

On the home server, add a firewall rule:

```bash
# Allow only Tailscale interface
iptables -A INPUT -i tailscale0 -j ACCEPT
iptables -A INPUT -j DROP
```

Now:

- Even if someone somehow got shell access elsewhere  
- They still cannot talk to your home server unless it's over Tailscale

---

## 5. Prevent your home server from becoming a relay

Make sure you do NOT enable subnet routing unless you need it:

```bash
tailscale up --advertise-exit-node
```

Avoid `--advertise-routes=192.168.0.0/24` unless intentional

This prevents:

- Accidental LAN exposure  
- Acting as a bridge into your home network

---

## 6. What attackers cannot do

Attackers cannot:

- Scan your home IP for "open VPN"  
- Guess credentials  
- Abuse your bandwidth  
- Use your IP as a proxy  
- DDoS through your exit node  
- Discover it via Shodan, Nmap, etc.  

There is no listening service exposed.

---

## 7. Realistic threat model (honest)

The only ways your home exit node could be abused are:

- Someone compromises your Tailscale account  
- Someone steals a trusted device  
- You accidentally approve a new device  
- You misconfigure ACLs  

All of these are administrative, not network-level attacks.

Enable:

- 2FA on Tailscale  
- Device approval  
- Key expiry (already visible in your status output)

---

## 8. Bottom line (important)

Your home exit node is safer than a commercial VPN endpoint.

Because:

- No shared users  
- No public access  
- Identity-based networking  
- End‑to-end encryption  
- Fine‑grained policy control  

You're not opening your home to the internet.  
You're creating a private, authenticated tunnel.
