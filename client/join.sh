#!/usr/bin/env bash
# Device side of a fastnet invite. You do not run this file directly: `fastnet add <device>`
# on the server combines it with lib/common.sh and the device's one-time key into
# <device>.sh, which you run on the device with sudo.
#
# Expects: SERVER_URL AUTH_KEY DEVICE_NAME CA_PEM (empty with Let's Encrypt)
# ---- invite body
need_root

if [ -n "$CA_PEM" ]; then
  ca_file=$(mktemp)
  printf '%s\n' "$CA_PEM" > "$ca_file"
  trust_ca "$ca_file"
  rm -f "$ca_file"
fi

case "$(uname -s)" in
  Linux)
    install_tailscale ;;
  Darwin)
    command -v tailscale >/dev/null ||
      die "install the open-source client first: brew install tailscale && sudo brew services start tailscale"
    log "note: on macOS, start tailscaled with --no-logs-no-support to keep logs off Tailscale's servers" ;;
  *) die "this invite supports Linux and macOS; on Windows/phones use the app (see 'fastnet add' output)" ;;
esac

log "joining $SERVER_URL as $DEVICE_NAME"
tailscale up --login-server "$SERVER_URL" --auth-key "$AUTH_KEY" --hostname "$DEVICE_NAME" --reset

cat <<EOF

Joined. This device is $(tailscale ip -4) on your network.
  tailscale status          see your other devices
  ping <server-name>        MagicDNS names work once DNS is accepted
The key in this file was single use; you can delete it now.
EOF
