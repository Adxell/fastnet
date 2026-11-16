# Getting started with fastnet

This guide takes you from a bare server to:
- your laptop and PCs on a private network with the server;
- a terminal on the server that you can open from any browser, including your phone.

It takes about 20 minutes. You don't need to know Headscale or Tailscale.

## What you will have

```
 your laptop / PC ── private network (WireGuard, encrypted) ──┐
                                                               ├── your server
 any browser / phone ── https://myserver.example.com:9090 ────┘     (fastnet + browser terminal)
```

- **Private network.** Every device you add gets an address like `100.64.0.2` and a name like `laptop.fastnet.internal`. Devices talk to the server directly and encrypted. No outside company runs any part of it.
- **Browser terminal (optional).** A shell on the server from any browser. Sign-in takes a username, a password and a 6-digit code from your phone.

## 1. What you need

| | Details |
| --- | --- |
| A server | Debian 12+ or Ubuntu 22.04+, amd64 or arm64, with systemd. A home machine, a mini PC or a cloud VM all work. 1 CPU and 1 GB RAM is enough for fastnet itself. |
| A way to reach it | A **public IP** on the server, or a router where you can **forward ports** to it. |
| A user with `sudo` | Not root. You will sign in to the browser terminal with this user. |
| A domain name | Only for the browser terminal. Any domain you own, or a free dynamic-DNS name (DuckDNS, deSEC, No-IP...). |
| An authenticator app | Only for the browser terminal. Aegis (Android) or FreeOTP (Android/iOS) are open source; any TOTP app works. |

### Find your public IP

On the server:
```sh
curl -4 https://ifconfig.co
```

If the server is at home, this is your router's IP. Home IPs can change; a dynamic-DNS name follows it for you.

### Point your domain at the server (browser terminal only)

At your DNS provider, create an **A record** such as `myserver.example.com → <public IP>`. Check that it works from any machine:
```sh
dig +short myserver.example.com      # must print your public IP
```

### Open the ports

If the server is behind a home router, forward these ports to the server's local IP. On a cloud VM, allow them in the provider's firewall or security group.

| Port | Needed for |
| --- | --- |
| `443/tcp` | the network: sign-in and relay |
| `3478/udp` | the network: finding direct paths |
| `41641/udp` | the network: direct encrypted traffic |
| `80/tcp` | browser terminal: getting its certificate |
| `9090/tcp` | browser terminal |

The installer opens them in `ufw` if `ufw` is active. Router and cloud firewalls you must do yourself.

## 2. Install on the server

```sh
sudo apt-get install -y git
git clone https://github.com/Adxell/fastnet.git
cd fastnet
```

Network only:
```sh
sudo ./server/install.sh --host <public IP>
```

Network + browser terminal:
```sh
sudo ./server/install.sh --host <public IP> --web-terminal myserver.example.com --email you@example.com
```

`--email` is optional; Let's Encrypt uses it only to warn you if a certificate is about to expire.

What happens:
1. It installs Headscale (checksum-verified), creates your own certificate authority, writes the config and starts the service.
2. It joins the server itself to the network and prints its address, for example `100.64.0.1`.
3. With `--web-terminal`, it also installs Cockpit, gets a certificate for your domain and turns on the one-time code and fail2ban.
4. If your user has no password yet, it asks you to set one. Then it shows a **QR code**: scan it with your authenticator app. It also shows **emergency codes**: write them down somewhere safe and offline.

When it finishes, check:
```sh
sudo fastnet status
```
Every line should look healthy (`active`, `ok`, a certificate date).

## 3. Add your laptop or PC (Linux)

On the **server**:
```sh
sudo fastnet add laptop
```

This creates an invite file at `~/fastnet-invites/laptop.sh`. It works **once** and expires in **1 hour** (`--expire 24h` for longer).

On the **laptop**:
```sh
scp you@<public IP>:fastnet-invites/laptop.sh .
sudo bash laptop.sh
rm laptop.sh
```

The script trusts your certificate authority, installs the open-source Tailscale client and joins. Then check:
```sh
tailscale status                       # lists the server and your other devices
ping 100.64.0.1                        # the server's fastnet address
ssh you@<server-name>.fastnet.internal
```

**Windows** (open-source route): use WSL2 with systemd turned on (`/etc/wsl.conf`: `[boot]` then `systemd=true`, then run `wsl --shutdown`) and follow the Linux steps inside WSL.
**macOS**: `brew install tailscale`, start it with `sudo brew services start tailscale`, then run the invite.
**Tailscale's graphical apps**: see "Phone, Windows, macOS app" in the [README](../README.md#add-devices).

## 4. Use the browser terminal

1. Open `https://myserver.example.com:9090` in any browser.
2. Enter your Linux username and password.
3. Enter the 6-digit code from your authenticator app.
4. Click **Terminal** in the left menu.

Tips:
- **Keep work running.** Run `tmux new -A -s work` first. Closing the tab or losing the signal won't stop what's running, and the same command reattaches later, from the browser or from your PC over `ssh`.
- **Idle timeout.** The page signs out after 15 minutes idle. tmux keeps your programs running.
- **Add another person:** create their Linux user (`sudo adduser maria`), then run `sudo fastnet 2fa maria` and let them scan the QR code. They can't sign in until they've done this.
- **Lost phone:** sign in with an emergency code, or run `sudo fastnet 2fa <you>` over SSH to get a new QR code. That also invalidates the old one.

## 5. Everyday commands (on the server)

| Command | What it does |
| --- | --- |
| `sudo fastnet add <name>` | invite a new device |
| `sudo fastnet ls` | devices, addresses, online, last seen |
| `sudo fastnet rm <name>` | remove a device right away (lost or sold laptop) |
| `sudo fastnet status` | health, certificates, browser terminal, banned IPs |
| `sudo fastnet 2fa <user>` | set up or reset a user's one-time code |
| `sudo fastnet backup /root` | archive everything: keep it private, it contains your keys |

## 6. Lock the server down (recommended)

Once SSH over fastnet works, keep SSH and anything else private off the public internet:
```sh
sudo ufw default deny incoming
sudo ufw allow 443/tcp && sudo ufw allow 3478/udp && sudo ufw allow 41641/udp
sudo ufw allow 80/tcp && sudo ufw allow 9090/tcp     # browser terminal
sudo ufw allow in on tailscale0                       # everything from your own devices
sudo ufw enable
```
Test `ssh you@<server-name>.fastnet.internal` from a joined device **before** you close the public SSH port. If you're locked out, use the browser terminal or the server's console.

## Next steps

- Something not working: [troubleshooting.md](troubleshooting.md).
- How it is protected and what it does not protect against: [SECURITY.md](../SECURITY.md).
- Running Claude Code agents on this server: [fastfish fleet](https://github.com/Adxell/fastfish/tree/main/fleet).

## Uninstall

On the server:
```sh
sudo tailscale down; sudo systemctl disable --now tailscaled headscale
sudo systemctl disable --now cockpit.socket fail2ban 2>/dev/null
sudo apt-get remove --purge -y headscale cockpit-ws cockpit-system cockpit-bridge libpam-google-authenticator fail2ban certbot
sudo rm -rf /etc/fastnet /etc/headscale /var/lib/headscale /opt/fastnet /usr/local/bin/fastnet \
  /etc/systemd/system/cockpit.socket.d/fastnet.conf /etc/cockpit/cockpit.conf /etc/cockpit/ws-certs.d/90-fastnet.*
```
On each Linux device:
```sh
sudo tailscale logout; sudo systemctl disable --now tailscaled
sudo rm -f /usr/bin/tailscale /usr/sbin/tailscaled /etc/systemd/system/tailscaled.service \
  /usr/local/share/ca-certificates/fastnet-ca.crt && sudo update-ca-certificates
```
