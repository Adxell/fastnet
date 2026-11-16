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
  | `80/tcp` | only with `--tls letsencrypt` |

## Install on the server

```sh
git clone <this repo> && cd fastnet
sudo ./server/install.sh --host 203.0.113.7          # your public IP or DNS name
```

This installs Headscale and creates your CA and certificate. It writes and validates the config, starts the service, opens the ports in `ufw` if it is active, and joins the server to its own network. Re-running it is safe: devices, keys and the CA are kept.

Options: `--port`, `--tls own-ca|letsencrypt`, `--email`, `--public-ip`, `--base-domain` (default `fastnet.internal`), `--name`, `--no-join`, `--no-firewall`.

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
sudo ufw allow in on tailscale0            # everything from your own devices
sudo ufw allow 22/tcp                      # keep until you've confirmed SSH over fastnet works, then remove
sudo ufw enable
```

## How it is put together

```
lib/common.sh      pinned versions + checksums, verified downloads, client install, CA trust
lib/certs.sh       your CA and the server certificate
lib/config.sh      the headscale config (own relay only, no update checks, no log upload)
server/install.sh  server installer
bin/fastnet        device management on the server
client/join.sh     device side; `fastnet add` packs it with lib/common.sh and a key into one invite
tests/e2e.sh       Docker test: real server + two real clients
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

`server/install.sh` itself runs systemd and apt, so it is not covered by the Docker test. Try it on a fresh VM before relying on it.

## Upgrading

Change `HEADSCALE_VERSION` / `TAILSCALE_VERSION` and their SHA-256 values in `lib/common.sh`, using `checksums.txt` from the Headscale release and `pkgs.tailscale.com/stable/<file>.sha256`. Run `tests/e2e.sh`, then re-run `server/install.sh` on the server. Read Headscale's changelog first, because its config format changes between versions.

## License

Apache-2.0
