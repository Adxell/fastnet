# Browser terminal: Cockpit (open source, LGPL) on its own port, signing in with a Linux
# username + password + a one-time code from an authenticator app (pam_google_authenticator).
# Certificate from Let's Encrypt (certbot), so any browser trusts it. Password guessers are
# banned by fail2ban. Sourced by server/install.sh, bin/fastnet and tests/webterm.sh.

WEBTERM_PAM=${WEBTERM_PAM:-/etc/pam.d/cockpit}
WEBTERM_PACKAGES="cockpit-ws cockpit-system cockpit-bridge libpam-google-authenticator fail2ban python3-systemd nftables certbot qrencode tmux"

webterm_packages() {
  log "installing Cockpit, 2FA module, fail2ban, certbot"
  # --no-install-recommends: no PackageKit/NetworkManager/etc., only the web shell and terminal
  # shellcheck disable=SC2086
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends $WEBTERM_PACKAGES >/dev/null
}

# Require a one-time code right after the password. No "nullok": a user who has not run
# `fastnet 2fa <user>` cannot sign in at all.
webterm_pam() {
  local f=${1:-$WEBTERM_PAM}
  [ -f "$f" ] || die "$f not found (is cockpit-ws installed?)"
  if grep -q '^auth.*pam_google_authenticator.so' "$f"; then return 0; fi
  grep -qE '^auth\s+substack\s+common-auth' "$f" || die "unexpected $f layout: no 'auth substack common-auth' line"
  sed -i -E '/^auth\s+substack\s+common-auth/a auth       required     pam_google_authenticator.so  # fastnet: one-time code' "$f"
  grep -q '^auth.*pam_google_authenticator.so' "$f" || die "could not add 2FA to $f"
}

webterm_cockpit_conf() {  # webterm_cockpit_conf DOMAIN PORT
  local domain=$1 port=$2
  mkdir -p /etc/cockpit /etc/systemd/system/cockpit.socket.d
  cat > /etc/cockpit/cockpit.conf <<EOF
# written by fastnet
[WebService]
Origins = https://$domain:$port
LoginTitle = fastnet
# no "connect to another host" box on the login page
LoginTo = false

[Session]
IdleTimeout = 15
EOF
  cat > /etc/systemd/system/cockpit.socket.d/fastnet.conf <<EOF
[Socket]
ListenStream=
ListenStream=$port
EOF
}

# Bans an IP for 1 hour after 5 wrong passwords in 10 minutes. Wrong one-time codes carry
# no IP in the log; the 2FA module limits those to 3 tries per 30 s per account.
webterm_fail2ban() {  # webterm_fail2ban PORT
  local port=$1
  cat > /etc/fail2ban/filter.d/fastnet-cockpit.conf <<'EOF'
[Definition]
failregex = pam_unix\(cockpit:auth\): authentication failure;.* rhost=(?:::ffff:)?<HOST>(?:\s|$)
ignoreregex =
EOF
  cat > /etc/fail2ban/jail.d/fastnet-cockpit.conf <<EOF
# written by fastnet
[fastnet-cockpit]
enabled   = true
filter    = fastnet-cockpit
backend   = systemd
banaction = nftables-multiport
port      = $port
maxretry  = 5
findtime  = 10m
bantime   = 1h

# Debian 12 enables the sshd jail on a log file that does not exist; read the journal instead
[sshd]
backend   = systemd
EOF
}

webterm_cert() {  # webterm_cert DOMAIN EMAIL TLS_MODE
  local domain=$1 email=$2 tls_mode=$3 contact hooks=()
  if [ -n "$email" ]; then contact=(-m "$email"); else contact=(--register-unsafely-without-email); fi
  # headscale's own Let's Encrypt client holds port 80; free it for the few seconds certbot needs
  [ "$tls_mode" = letsencrypt ] && hooks=(--pre-hook "systemctl stop headscale" --post-hook "systemctl start headscale")
  log "getting a Let's Encrypt certificate for $domain (port 80 must reach this server)"
  certbot certonly --standalone --preferred-challenges http -d "$domain" "${contact[@]}" \
    --agree-tos -n --keep-until-expiring "${hooks[@]}" \
    --deploy-hook /opt/fastnet/lib/webterm-deploy-hook.sh >/dev/null ||
    die "certbot failed: check that $domain points to this server and port 80/tcp is open"
  # the deploy hook runs only when a certificate is issued; install the current one every time
  RENEWED_LINEAGE=/etc/letsencrypt/live/$domain /opt/fastnet/lib/webterm-deploy-hook.sh
}

webterm_setup() {  # webterm_setup DOMAIN PORT EMAIL TLS_MODE
  local domain=$1 port=$2 email=$3 tls_mode=$4
  webterm_packages
  webterm_pam
  webterm_cockpit_conf "$domain" "$port"
  webterm_fail2ban "$port"
  webterm_cert "$domain" "$email" "$tls_mode"
  systemctl daemon-reload
  systemctl enable fail2ban >/dev/null 2>&1 || true
  if ! systemctl restart fail2ban; then
    journalctl -u fail2ban -n 15 --no-pager >&2 || true
    die "fail2ban did not start (see above, or: journalctl -u fail2ban)"
  fi
  systemctl enable cockpit.socket >/dev/null 2>&1 || true
  if ! systemctl restart cockpit.socket; then
    journalctl -u cockpit.socket -n 15 --no-pager >&2 || true
    ss -lntp 2>/dev/null | grep ":$port " >&2 || true
    die "Cockpit could not listen on port $port (see above; another program may use it: try --web-port 9443)"
  fi
  systemctl try-restart cockpit.service || true
  sleep 1
  fail2ban-client status fastnet-cockpit >/dev/null 2>&1 || die "fail2ban jail did not start (journalctl -u fail2ban)"
  curl -fs --max-time 10 -o /dev/null --resolve "$domain:$port:127.0.0.1" "https://$domain:$port/" ||
    die "Cockpit is not answering on https://$domain:$port (journalctl -u cockpit)"
  log "browser terminal is running on https://$domain:$port"
}

# Enrol (or re-enrol) USER for the one-time code. Shows a QR code for the authenticator app.
webterm_enroll() {  # webterm_enroll USER
  local user=$1 status
  getent passwd "$user" >/dev/null || die "no Linux user named $user"
  [ "$user" != root ] || die "root cannot sign in to the browser terminal; use your normal user"
  status=$(passwd -S "$user" | awk '{print $2}')
  if [ "$status" != P ]; then
    echo "$user has no password yet; set one (it is the first step of the browser sign-in):"
    passwd "$user"
  fi
  # --quiet: its own output includes a google.com chart link carrying the secret; draw the QR locally
  runuser -u "$user" -- google-authenticator --time-based --disallow-reuse --force --no-confirm --quiet \
    --rate-limit=3 --rate-time=30 --window-size=3 --qr-mode=NONE
  local file secret uri
  file="$(getent passwd "$user" | cut -d: -f6)/.google_authenticator"
  secret=$(head -n1 "$file")
  uri="otpauth://totp/fastnet:$user@$(hostname -s)?secret=$secret&issuer=fastnet"
  echo
  echo "One-time code for $user. Scan with an authenticator app (Aegis and FreeOTP are open source):"
  qrencode -t ansiutf8 "$uri"
  echo "Or type this key into the app: $secret"
  echo
  echo "Emergency codes (each signs you in once if you lose the phone; keep them safe, offline):"
  grep -E '^[0-9]{8}$' "$file" | paste -sd' ' | sed 's/^/  /'
}
