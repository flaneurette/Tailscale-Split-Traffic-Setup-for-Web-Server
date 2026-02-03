# Booting the server

Sometimes, and most likely, tailscale can flush your iptables. Which is annoying.

After setting up tailscale on the `exit node`, run this:

`tailscale up --netfilter-mode=off --advertise-exit-node`

On the `public server`, run this:

`tailscale up --accept-routes=false --advertise-exit-node=false --exit-node-allow-lan-access --netfilter-mode=off --exit-node=<EXIT.NODE.IP.HERE>`

From then on, manage the tailscale firewall rules yourself.

This will prevent tailscale from resetting your firewall after a boot.



