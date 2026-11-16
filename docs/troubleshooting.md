# Troubleshooting

Start with `sudo fastnet status` on the server. It shows what's running and what isn't.

## Installing

**`systemd is required`**: the server must boot with systemd. On WSL2, add `[boot]` / `systemd=true` to `/etc/wsl.conf` and run `wsl --shutdown`.

**`the generated config is invalid`**: the installer prints Headscale's error, and your previous config is kept in `/etc/headscale/config.yaml.bak`. Usually caused by a bad `--host` or `--base-domain` value.

**`headscale is not answering`**: run `journalctl -u headscale -n 50`. The most common cause is another program, often a web server, already using port 443. Stop it, or install with `--port 8443` and forward that port instead.

**`certbot failed`** (browser terminal):
- `dig +short <domain>` must print the server's public IP. New DNS records can take a few minutes to appear.
- Port `80/tcp` must reach the server from the internet: check the router forward or the cloud firewall.
- Nothing else may be using port 80 (`sudo ss -lntp | grep ':80 '`).

## Joining a device

**`could not join` / the invite hangs**:
- From the device, `curl -v https://<public IP>` should connect. If it times out, port 443 isn't reaching the server.
- The key is single use and expires after 1 hour. Create a new one with `sudo fastnet add <name>` (remove the old device first if it partly joined: `sudo fastnet rm <name>`).

**`a device named X already exists`**: run `sudo fastnet rm X` first, or pick another name.

**Certificate errors (`x509`, `unknown authority`)**: the device doesn't trust your certificate authority. The Linux invite installs it for you. On phones and graphical apps, install it by hand (`sudo fastnet ca` shows how). If an Android app still refuses it, reinstall the server with a DNS name and `--tls letsencrypt`.

**Joined, but devices can't reach each other**: run `tailscale status` and `tailscale ping <device>`. "via DERP" means traffic goes through your server's relay. That works, just slower; open `41641/udp` and `3478/udp` to get direct connections.

## Browser terminal

**The page doesn't load**:
- Check port `9090/tcp` is forwarded or allowed, and run `sudo systemctl status cockpit.socket`.
- Use `https://` and include `:9090` in the address.

**"Wrong user name or password" with the right password**:
- The user has no one-time code yet: run `sudo fastnet 2fa <user>`.
- `root` can never sign in here. Use your normal user, then `sudo` inside.
- Your IP may be banned after 5 wrong passwords: `sudo fail2ban-client status fastnet-cockpit` shows banned IPs, and `sudo fail2ban-client set fastnet-cockpit unbanip <ip>` lifts a ban.

**The code is always wrong**: the phone's clock must be right; turn on automatic time. The server's clock must be right too (`timedatectl`). After 3 wrong codes, wait 30 seconds.

**The terminal disconnects**: the page signs out after 15 minutes idle. Run your work inside `tmux new -A -s work`, and the same command reattaches.

**Certificate expired**: certbot renews automatically (`systemctl list-timers | grep certbot`). To test renewal: `sudo certbot renew --dry-run`.

## Still stuck

Open an issue at https://github.com/Adxell/fastnet/issues with:
- the output of `sudo fastnet status`;
- the last lines of `journalctl -u headscale` (and `-u cockpit` for the browser terminal);
- your OS version.

Remove keys and IP addresses you don't want public first.
