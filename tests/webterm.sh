#!/usr/bin/env bash
# Docker test for the browser terminal (lib/webterm.sh): installs the packages, applies the
# PAM, Cockpit and fail2ban config with the real functions, then signs in to a real Cockpit
# through its HTTP login protocol with password + one-time code.
# Not covered (needs systemd + a public DNS name): certbot issuance, systemd units, nftables bans.
#
#   tests/webterm.sh          (needs docker; pulls debian:bookworm-slim)
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
C=fastnet-webterm
pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; exit 1; }
cleanup() { docker rm -f "$C" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

docker run -d --name "$C" -v "$REPO:/opt/fastnet:ro" debian:bookworm-slim sleep infinity >/dev/null
inside() { docker exec "$C" bash -c "source /opt/fastnet/lib/common.sh; source /opt/fastnet/lib/webterm.sh; $1"; }

echo "installing packages (takes a minute)"
inside 'apt-get update -qq && webterm_packages && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends curl oathtool rsyslog >/dev/null' ||
  fail "package install"
pass "packages install with --no-install-recommends"

inside 'webterm_pam && webterm_pam && [ "$(grep -c pam_google_authenticator /etc/pam.d/cockpit)" = 1 ] &&
    awk "/common-auth/{a=NR} /pam_google_authenticator/{g=NR} END{exit !(g==a+1)}" /etc/pam.d/cockpit' ||
  fail "PAM config"
pass "PAM: one-time code required right after the password, and re-running does not duplicate it"

inside 'useradd -m -s /bin/bash alice && echo "alice:S3cret-pass" | chpasswd
    useradd -m -s /bin/bash bob && echo "bob:S3cret-pass" | chpasswd
    webterm_enroll alice >/tmp/enroll.out 2>&1 && test -s /home/alice/.google_authenticator &&
    [ "$(stat -c %U /home/alice/.google_authenticator)" = alice ]' || { inside 'cat /tmp/enroll.out'; fail "enroll"; }
inside 'webterm_enroll root' >/dev/null 2>&1 && fail "root enrolment accepted"
pass "fastnet 2fa: enrols a user (secret owned by the user), refuses root"

inside 'webterm_cockpit_conf term.example.com 9090 && webterm_fail2ban 9090 && fail2ban-client -t >/dev/null 2>&1' ||
  { inside 'fail2ban-client -t'; fail "cockpit/fail2ban config"; }
inside 'grep -q "LoginTo = false" /etc/cockpit/cockpit.conf && grep -q "^ListenStream=9090" /etc/systemd/system/cockpit.socket.d/fastnet.conf' ||
  fail "cockpit config content"
pass "Cockpit config and fail2ban jail pass fail2ban's config test"

inside 'rsyslogd 2>/dev/null; (/usr/lib/cockpit/cockpit-ws --no-tls --port 9090 >/tmp/ws.log 2>&1 &); sleep 2'
login() {  # login USER PASS CODE -> final HTTP status of Cockpit's login
  inside "h=\$(curl -s -D - -o /dev/null -u '$1:$2' http://127.0.0.1:9090/cockpit/login | tr -d '\r')
      id=\$(echo \"\$h\" | sed -n 's/^WWW-Authenticate: X-Conversation \([^ ]*\) .*/\1/p')
      [ -n \"\$id\" ] || { echo \"\$h\" | head -1 | cut -d' ' -f2; exit; }
      curl -s -o /dev/null -w '%{http_code}' -H \"Authorization: X-Conversation \$id \$(printf %s '$3' | base64)\" http://127.0.0.1:9090/cockpit/login"
}
code() { inside "oathtool --totp -b \$(head -1 /home/alice/.google_authenticator)"; }

[ "$(login alice S3cret-pass "$(code)")" = 200 ] || fail "alice with password + code was refused"
pass "sign-in with password + one-time code works"
[ "$(login alice wrong-pass "$(code)")" = 401 ] || fail "wrong password accepted"
[ "$(login alice S3cret-pass 000000)" = 401 ] || fail "wrong code accepted"
[ "$(login bob S3cret-pass 000000)" = 401 ] || fail "user without 2FA set up got in"
[ "$(login root anything 000000)" = 401 ] || fail "root got in"
pass "refused: wrong password, wrong code, a user without 2FA, root"

inside 'fail2ban-regex /var/log/auth.log /etc/fail2ban/filter.d/fastnet-cockpit.conf' | grep -qE 'Failregex: [1-9]' ||
  fail "fail2ban filter does not match Cockpit's failed logins"
pass "fail2ban filter matches the real failed-password log lines"

inside 'mkdir -p /tmp/le && cd /tmp/le && openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj /CN=t \
      -keyout privkey.pem -out fullchain.pem -days 1 2>/dev/null
    RENEWED_LINEAGE=/tmp/le /opt/fastnet/lib/webterm-deploy-hook.sh
    cmp -s /tmp/le/fullchain.pem /etc/cockpit/ws-certs.d/90-fastnet.cert &&
    [ "$(stat -c %a /etc/cockpit/ws-certs.d/90-fastnet.key)" = 600 ] &&
    [ "$(ls /etc/cockpit/ws-certs.d/*.cert | sort | tail -1)" = /etc/cockpit/ws-certs.d/90-fastnet.cert ]' ||
  fail "deploy hook"
pass "certbot deploy hook installs the certificate where Cockpit picks it, key mode 600"

echo "all browser-terminal checks passed"
