# fastnet

Your own private network between your server, your computers and your phone: self-hosted, open source, and with no outside company in the middle.

fastnet installs and configures [Headscale](https://github.com/juanfont/headscale), an open-source coordination server, on your server. Your devices join with the open-source [Tailscale client](https://github.com/tailscale/tailscale). Traffic is end-to-end encrypted with WireGuard and goes **directly** between your devices and the server.

| Piece | Runs on | License |
| --- | --- | --- |
| Headscale (sign-in, device list, key exchange) | your server | BSD-3 |
| Relay + STUN (built into Headscale, for when a direct path fails) | your server | BSD-3 |
| Certificate authority (fastnet makes its own, no Let's Encrypt needed) | your server | OpenSSL |
| `tailscale` / `tailscaled` client | each device | BSD-3 |
| fastnet scripts | your server + devices | Apache-2.0 |
| Browser terminal, optional: [Cockpit](https://cockpit-project.org) + one-time codes (pam_google_authenticator) + fail2ban | your server | LGPL-2.1 / Apache-2.0 / GPL-2 |

What fastnet turns off so nothing leaves your network:
- **Tailscale's relay servers**: clients get a relay map that contains only your server (`derp.urls: []`).
- **Headscale update checks** (`disable_check_updates: true`).
- **Client log uploads**: `tailscaled` always runs with `--no-logs-no-support`.
- **Public certificate authorities**: by default TLS uses your own CA (`--tls own-ca`).

The only outside downloads are the pinned Headscale and Tailscale packages during installation. Both are checked against SHA-256 hashes stored in `lib/common.sh`.

## Requirements

- A Debian 12+ or Ubuntu 22.04+ server with systemd, on amd64 or arm64.
- Devices must be able to reach it directly: a public IP, or ports forwarded on your router:

  | Port | Why |
  | --- | --- |
  | `443/tcp` (or `--port`) | control server + relay |
  | `3478/udp` | STUN, so devices find direct paths |
  | `41641/udp` | direct WireGuard to the server |
  | `80/tcp` | only with `--tls letsencrypt` or `--web-terminal` |
  | `9090/tcp` (or `--web-port`) | only with `--web-terminal` |

## Install on the server

```sh
git clone <this repo> && cd fastnet
sudo ./server/install.sh --host 203.0.113.7          # your public IP or DNS name
```

This installs Headscale and creates your CA and certificate. It writes and validates the config, starts the service, opens the ports in `ufw` if it is active, and joins the server to its own network. Re-running it is safe: devices, keys and the CA are kept.

Options: `--port`, `--tls own-ca|letsencrypt`, `--email`, `--public-ip`, `--base-domain` (default `fastnet.internal`), `--name`, `--no-join`, `--no-firewall`, `--web-terminal <domain>`, `--web-port`.

## Browser terminal (work from any browser, nothing to install)

Open `https://<your-domain>:9090` on any computer or phone, sign in, click **Terminal**, and you have a shell on the server.

```sh
sudo ./server/install.sh --host 203.0.113.7 --web-terminal myserver.example.com --email you@example.com
```

You need a DNS name that points to the server (any domain or a free dynamic-DNS name), and ports `80/tcp` and `9090/tcp` must reach it.

Sign-in has three steps:
1. your Linux **username**;
2. your Linux **password**;
3. a **one-time code** from an authenticator app on your phone (Aegis and FreeOTP are open source).

The installer sets up the code for the user who ran `sudo`. To add another user or reset a lost phone, run `sudo fastnet 2fa <user>` (over SSH). It shows a QR code for the app and emergency codes.

What protects it:
- **No code, no entry.** A user without a one-time code set up cannot sign in, and `root` can never sign in here; use `sudo` inside.
- **Lockouts.** Five wrong passwords in 10 minutes ban that IP for 1 hour (fail2ban). Wrong codes are limited to 3 tries per 30 seconds per account.
- **A real certificate.** The address uses a Let's Encrypt certificate, so every browser trusts it. certbot renews it automatically. This is the one place fastnet uses a public certificate authority, because browsers on computers you don't control won't trust your own CA.
- **Idle timeout.** Sessions sign out after 15 minutes idle. Run long work inside tmux so it survives.

Same session in the browser and on your PC: run `tmux new -A -s work` in either place. Start something in the browser, then from your PC run `ssh you@<server>.fastnet.internal` and `tmux new -A -s work` to carry on exactly where you were, and the other way around.

## Add devices

On the server:

```sh
sudo fastnet add laptop
```

It prints the steps for that device. The invite key is **single use** and **expires in 1 hour** (`--expire 24h` to change).

**Linux** (also WSL2 with systemd enabled): copy the invite script and run it.

```sh
scp you@203.0.113.7:fastnet-invites/laptop.sh .
sudo bash laptop.sh
```

The script trusts your CA, installs the pinned open-source client (checksum-verified, logs disabled) and joins.

**Phone:** nothing to install if you use the browser terminal above. To put the phone itself on the network instead:

**Phone, Windows, macOS app:** install the Tailscale app, run `sudo fastnet ca` and install that CA on the device, choose "alternate/custom server" with your server URL, and sign in with the printed key. If `qrencode` is installed on the server, the key is also shown as a QR code.

> The Tailscale apps for Android and Linux are open source. The graphical apps for iOS, macOS and Windows are not; only their networking core is. For a fully open-source macOS client, use `brew install tailscale` (the CLI build). Android apps may ignore CAs installed by the user. If the Android app cannot connect with your own CA, give the server a DNS name and use `--tls letsencrypt`.

## Everyday commands (server)

```sh
sudo fastnet ls            # devices, IPs, online, last seen
sudo fastnet rm phone      # remove a lost device immediately
sudo fastnet status        # service, health, certificate expiry, ports
sudo fastnet ca            # CA certificate + fingerprint for installing on phones
sudo fastnet renew-cert    # new server certificate (valid 825 days) from your CA
sudo fastnet backup /root  # database, config and CA in one archive (keep it private)
sudo fastnet 2fa alice     # set up / reset alice's one-time code for the browser terminal
```

On any device: `tailscale status` shows the others, and each device is reachable at its `100.64.x.y` address or `<name>.fastnet.internal`.

## Using it with fastfish fleet

Control your Kubernetes agents from anywhere over this network:

1. Install k3s with the server's network address in its certificate:
   `curl -sfL https://get.k3s.io | sh -s - --tls-san $(tailscale ip -4) --tls-san <server-name>.fastnet.internal`
2. On each client, set the kubeconfig `server:` to `https://<server fastnet IP>:6443`.
3. Keep the Kubernetes API private (next section).

## Lock down the server

Your server has a public IP, so expose only what fastnet needs and keep everything else, such as SSH and the Kubernetes API, on the private network. With `ufw`:

```sh
sudo ufw default deny incoming
sudo ufw allow 443/tcp && sudo ufw allow 3478/udp && sudo ufw allow 41641/udp
sudo ufw allow 80/tcp && sudo ufw allow 9090/tcp   # only if you use the browser terminal
sudo ufw allow in on tailscale0            # everything from your own devices
sudo ufw allow 22/tcp                      # keep until you've confirmed SSH over fastnet works, then remove
sudo ufw enable
```

## How it is put together

```
lib/common.sh      pinned versions + checksums, verified downloads, client install, CA trust
lib/certs.sh       your CA and the server certificate
lib/config.sh      the headscale config (own relay only, no update checks, no log upload)
lib/webterm.sh     browser terminal: Cockpit, 2FA in PAM, fail2ban, certbot
server/install.sh  server installer
bin/fastnet        device management on the server
client/join.sh     device side; `fastnet add` packs it with lib/common.sh and a key into one invite
tests/e2e.sh       Docker test: real server + two real clients
tests/webterm.sh   Docker test: real Cockpit sign-in with password + one-time code
```

## Testing

```sh
tests/e2e.sh
```

It builds a server from the pinned Headscale package with your own CA and the generated config, then starts two real Tailscale clients. It checks that:
- the clients join with keys from `fastnet add` and reach each other;
- the clients receive only your relay, never Tailscale's;
- a client that doesn't trust the CA is refused;
- `fastnet ls`, `fastnet rm` and device-name validation work.

```sh
tests/webterm.sh
```

It installs the browser-terminal packages and applies the PAM, Cockpit and fail2ban config with the real functions. Then it signs in to a real Cockpit with password + one-time code, and checks that a wrong password, a wrong code, a user without a code and `root` are all refused. It also checks that the fail2ban filter matches real failed sign-ins and that the certificate hook installs the certificate.

Not covered by the Docker tests, because they need systemd and a public DNS name: `server/install.sh` itself, certbot issuing a certificate, and fail2ban actually banning an IP. Try them on a fresh VM before relying on them.

## Upgrading

Change `HEADSCALE_VERSION` / `TAILSCALE_VERSION` and their SHA-256 values in `lib/common.sh`, using `checksums.txt` from the Headscale release and `pkgs.tailscale.com/stable/<file>.sha256`. Run `tests/e2e.sh`, then re-run `server/install.sh` on the server. Read Headscale's changelog first, because its config format changes between versions.

## License

Apache-2.0
