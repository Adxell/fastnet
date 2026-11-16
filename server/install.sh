#!/usr/bin/env bash
# Install fastnet on your server: a self-hosted, open-source private network (Headscale +
# the open-source Tailscale client) that your laptop, PCs and phone join directly.
#
#   sudo ./server/install.sh --host <public IP or DNS name> [options]
#
# Options:
#   --host H          address devices use to reach this server (required)
#   --port N          HTTPS port for headscale (default 443)
#   --tls MODE        own-ca (default, no outside service) | letsencrypt (needs a DNS name and port 80)
#   --email E         contact email for Let's Encrypt (letsencrypt only)
#   --public-ip IP    public IPv4 for the relay when --host is a DNS name
#   --base-domain D   MagicDNS suffix (default fastnet.internal)
#   --name N          this server's device name on the network (default: hostname)
#   --no-join         do not install the client on this server / do not join it
#   --no-firewall     do not open ports in ufw
#   --web-terminal D  also serve a browser terminal at https://D:9090 (D = DNS name of this
#                     server); sign-in is Linux user + password + one-time code (2FA).
#                     Uses Let's Encrypt for D, so port 80/tcp must reach this server.
#   --web-port N      port for the browser terminal (default 9090)
# Re-running is safe: it keeps the CA, the database and joined devices.
set -Eeuo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO/lib/common.sh"
source "$REPO/lib/certs.sh"
source "$REPO/lib/config.sh"
source "$REPO/lib/webterm.sh"
trap 'echo "[fastnet] ERROR: step failed at server/install.sh line $LINENO: $BASH_COMMAND" >&2' ERR

HOST="" PORT=443 TLS_MODE=own-ca ACME_EMAIL="" PUBLIC_IP="" BASE_DOMAIN=fastnet.internal
NAME="$(hostname -s | tr '[:upper:]_' '[:lower:]-')" JOIN=1 FIREWALL=1 WEB_DOMAIN="" WEB_PORT=9090
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST=$2; shift ;;
    --port) PORT=$2; shift ;;
    --tls) TLS_MODE=$2; shift ;;
    --email) ACME_EMAIL=$2; shift ;;
    --public-ip) PUBLIC_IP=$2; shift ;;
    --base-domain) BASE_DOMAIN=$2; shift ;;
    --name) NAME=$2; shift ;;
    --no-join) JOIN=0 ;;
    --no-firewall) FIREWALL=0 ;;
    --web-terminal) WEB_DOMAIN=$2; shift ;;
    --web-port) WEB_PORT=$2; shift ;;
    -h | --help) sed -n '2,24p' "$0"; exit 0 ;;
    *) die "unknown option $1 (see --help)" ;;
  esac
  shift
done

need_root
[ -n "$HOST" ] || die "--host is required: the public IP or DNS name of this server"
[[ $PORT =~ ^[0-9]+$ ]] || die "--port must be a number"
case "$TLS_MODE" in own-ca | letsencrypt) ;; *) die "--tls must be own-ca or letsencrypt" ;; esac
[ "$TLS_MODE" = letsencrypt ] && is_ipv4 "$HOST" && die "letsencrypt needs a DNS name, not an IP; use --tls own-ca"
# a re-run without --web-terminal keeps the browser terminal that is already set up
if [ -z "$WEB_DOMAIN" ] && [ -f /etc/fastnet/fastnet.env ]; then
  WEB_DOMAIN=$(sed -n 's/^WEB_DOMAIN=//p' /etc/fastnet/fastnet.env)
  WEB_PORT=$(sed -n 's/^WEB_PORT=//p' /etc/fastnet/fastnet.env); WEB_PORT=${WEB_PORT:-9090}
  KEEP_WEB=1
fi
if [ -n "$WEB_DOMAIN" ]; then
  is_ipv4 "$WEB_DOMAIN" && die "--web-terminal needs a DNS name (browsers need a real certificate for it), not an IP"
  [[ $WEB_PORT =~ ^[0-9]+$ ]] || die "--web-port must be a number"
  case "$WEB_PORT" in "$PORT" | 9098 | 50443) die "--web-port $WEB_PORT is used by headscale; pick another (e.g. 9443)" ;; esac
fi
valid_name "$NAME" || die "--name must be lowercase letters, digits and dashes"
has_systemd || die "systemd is required"
command -v apt-get >/dev/null || die "this installer supports Debian/Ubuntu (headscale ships .deb packages)"
for tool in curl openssl jq; do command -v "$tool" >/dev/null || apt-get install -y -qq "$tool" >/dev/null; done

ETC=/etc/fastnet
ARCH=$(detect_arch)

# ---- 1. headscale package (checksum-pinned)
if [ "$(headscale version 2>/dev/null | head -n1)" != "v$HEADSCALE_VERSION" ]; then
  log "installing headscale $HEADSCALE_VERSION"
  tmp=$(mktemp -d)
  sha="HEADSCALE_SHA256_$ARCH"
  download_verified "https://github.com/juanfont/headscale/releases/download/v${HEADSCALE_VERSION}/headscale_${HEADSCALE_VERSION}_linux_${ARCH}.deb" "${!sha}" "$tmp/headscale.deb"
  apt-get install -y -qq "$tmp/headscale.deb" >/dev/null
  rm -rf "$tmp"
else
  log "headscale $HEADSCALE_VERSION already installed"
fi

# ---- 2. fastnet itself, so `fastnet` works from anywhere on the server
if [ "$REPO" != /opt/fastnet ]; then
  rm -rf /opt/fastnet.new && cp -a "$REPO" /opt/fastnet.new && rm -rf /opt/fastnet && mv /opt/fastnet.new /opt/fastnet
fi
ln -sf /opt/fastnet/bin/fastnet /usr/local/bin/fastnet
mkdir -p "$ETC" && chmod 700 "$ETC"
cat > "$ETC/fastnet.env" <<EOF
HOST=$HOST
PORT=$PORT
TLS_MODE=$TLS_MODE
BASE_DOMAIN=$BASE_DOMAIN
SERVER_NAME=$NAME
WEB_DOMAIN=$WEB_DOMAIN
WEB_PORT=$WEB_PORT
EOF

# ---- 3. TLS
if [ "$TLS_MODE" = own-ca ]; then
  make_ca "$ETC/ca"
  make_server_cert "$ETC/ca" /etc/headscale/tls "$HOST"
  chown -R root:headscale /etc/headscale/tls && chmod 750 /etc/headscale/tls
  log "TLS: own CA, fingerprint $(ca_fingerprint "$ETC/ca/ca.crt")"
fi

# ---- 4. config (old one kept as config.yaml.bak), validated before restart
[ -f /etc/headscale/config.yaml ] && cp /etc/headscale/config.yaml /etc/headscale/config.yaml.bak
HOST=$HOST PORT=$PORT TLS_MODE=$TLS_MODE ACME_EMAIL=$ACME_EMAIL PUBLIC_IP=$PUBLIC_IP BASE_DOMAIN=$BASE_DOMAIN \
  render_config > /etc/headscale/config.yaml.new
chown root:headscale /etc/headscale/config.yaml.new && chmod 640 /etc/headscale/config.yaml.new
mv /etc/headscale/config.yaml.new /etc/headscale/config.yaml
runuser -u headscale -- headscale configtest >/dev/null 2>&1 || {
  runuser -u headscale -- headscale configtest || true
  die "the generated config is invalid (see above); previous config is in /etc/headscale/config.yaml.bak"
}

systemctl enable headscale >/dev/null 2>&1
systemctl restart headscale
for _ in $(seq 1 30); do curl -fsk "https://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break; sleep 1; done
curl -fsk "https://127.0.0.1:$PORT/health" >/dev/null || die "headscale is not answering (journalctl -u headscale)"
log "headscale is running on port $PORT"

# ---- 5. the owner account all your devices belong to
headscale users list -o json-line | jq -e '.[]? | select(.name == "me")' >/dev/null || headscale users create me >/dev/null

# ---- 6. firewall
if [ "$FIREWALL" = 1 ] && command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow "$PORT/tcp" comment "fastnet control+relay" >/dev/null
  ufw allow 3478/udp comment "fastnet STUN" >/dev/null
  ufw allow 41641/udp comment "fastnet direct WireGuard" >/dev/null
  [ "$TLS_MODE" = letsencrypt ] && ufw allow 80/tcp comment "fastnet ACME" >/dev/null
  log "ufw: opened $PORT/tcp, 3478/udp, 41641/udp"
  if [ -n "$WEB_DOMAIN" ]; then
    ufw allow "$WEB_PORT/tcp" comment "fastnet browser terminal" >/dev/null
    ufw allow 80/tcp comment "fastnet ACME" >/dev/null
    log "ufw: opened $WEB_PORT/tcp and 80/tcp (browser terminal + its certificate)"
  fi
fi

# ---- 7. join this server to its own network
if [ "$JOIN" = 1 ]; then
  [ "$TLS_MODE" = own-ca ] && trust_ca "$ETC/ca/ca.crt"
  install_tailscale
  # own-ca: join over 127.0.0.1 (in the certificate) to avoid NAT hairpinning on the public IP.
  join_url="https://127.0.0.1:$PORT"
  [ "$TLS_MODE" = letsencrypt ] && join_url="https://$HOST$([ "$PORT" = 443 ] || echo ":$PORT")"
  if tailscale ip -4 >/dev/null 2>&1; then
    log "this server is already on the network as $(tailscale ip -4)"
  else
    key=$(/opt/fastnet/bin/fastnet _key)
    tailscale up --login-server "$join_url" --auth-key "$key" --hostname "$NAME" --accept-dns=false
  fi
  SERVER_IP=$(tailscale ip -4)
fi

# ---- 8. browser terminal (optional)
if [ -n "$WEB_DOMAIN" ] && [ -z "${KEEP_WEB:-}" ]; then
  webterm_setup "$WEB_DOMAIN" "$WEB_PORT" "$ACME_EMAIL" "$TLS_MODE"
  owner=${SUDO_USER:-}
  if [ -n "$owner" ] && [ "$owner" != root ] && [ ! -f "$(getent passwd "$owner" | cut -d: -f6)/.google_authenticator" ]; then
    if [ -t 0 ] && [ -t 1 ]; then
      log "setting up the one-time code for $owner"
      webterm_enroll "$owner"
    else
      log "run 'sudo fastnet 2fa $owner' to set up your one-time code before signing in"
    fi
  fi
fi

cat <<EOF

fastnet is ready.
  Control server : https://$HOST$([ "$PORT" = 443 ] || echo ":$PORT")  ($TLS_MODE)
  This server    : ${SERVER_IP:-not joined}  (${NAME}.${BASE_DOMAIN})

Make sure these reach this machine (router port forwards / cloud firewall):
  $PORT/tcp, 3478/udp, 41641/udp$([ "$TLS_MODE" = letsencrypt ] || [ -n "$WEB_DOMAIN" ] && echo ", 80/tcp")$([ -n "$WEB_DOMAIN" ] && echo ", $WEB_PORT/tcp")
$([ -n "$WEB_DOMAIN" ] && printf '\nBrowser terminal: https://%s:%s  (user + password + one-time code; add users with: sudo fastnet 2fa <user>)\n' "$WEB_DOMAIN" "$WEB_PORT")

Next: add a device with   sudo fastnet add laptop
EOF
