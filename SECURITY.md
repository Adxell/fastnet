# Security

## What fastnet protects

| Part | Protection |
| --- | --- |
| Traffic between devices | WireGuard encryption, end to end. The server's relay only forwards encrypted packets. |
| Joining the network | Single-use keys that expire after 1 hour, and TLS checked against your own certificate authority. A device without your CA, or with a used key, is refused. |
| Outside services | None at runtime: no Tailscale relays, no update checks, no client log uploads. Downloads at install time are checked against pinned SHA-256 hashes. |
| Browser terminal | Linux password **and** a one-time code (TOTP) for every sign-in. Users without a code set up and `root` are refused. 5 wrong passwords ban the IP for 1 hour; wrong codes are limited to 3 per 30 seconds. Let's Encrypt certificate. Idle sessions sign out after 15 minutes. |

## What it does not protect against

- **A compromised server.** The server holds the network's keys, your CA private key and the browser terminal. Keep it updated (`unattended-upgrades`) and back it up privately.
- **Anyone who has both your password and your phone.** Keep the emergency codes offline.
- **Invite files in transit.** An invite is a working key for one hour. Copy it with `scp`, run it, delete it. Don't send it by chat or email.
- **The browser terminal is public.** It's protected by 2FA and banning, but it's still a login page on the internet. If you only need it from your own devices, remove the public `9090/tcp` rule and open `https://<server fastnet IP>:9090` over the private network instead. The browser will warn that the certificate is for your domain, not that address.
- **Closed-source apps.** The Tailscale apps for iOS, macOS and Windows aren't open source (Android and the Linux/CLI clients are).

## Recommended

- Turn on the firewall steps in [docs/getting-started.md](docs/getting-started.md#6-lock-the-server-down-recommended).
- Remove lost devices right away: `sudo fastnet rm <name>`.
- Use a strong, unique password for every user who can sign in.
- Store `fastnet backup` archives encrypted and offline: they contain your CA key.

## Reporting a vulnerability

Please don't open a public issue. Use GitHub's **private vulnerability reporting** on this repository (Security tab → "Report a vulnerability").
