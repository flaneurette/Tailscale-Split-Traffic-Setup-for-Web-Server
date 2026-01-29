# Privacy

Sometimes, tailscale might edit your Postfix configuration to add a tail address as hostname. This is a privacy risk, can lead to exposure of the tailscle tail address. It is something to avoid.

Edit:

sudo nano /etc/postfix/main.cf

Change the hostname back to what you want it to show:

`myhostname = myserver`

Then:

`sudo systemctl restart postfix`

### Verify:

`telnet <your-server-ip> 25`

You should now see something like:

`220 myserver ESMTP Postfix`