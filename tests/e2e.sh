#!/usr/bin/env bash
# End-to-end test in Docker: a fastnet server (pinned headscale + own CA + generated config)
# and two real Tailscale clients that join with `fastnet add` keys and ping each other.
# Also checks that clients are handed only the self-hosted relay, never Tailscale's.
#
#   tests/e2e.sh          (needs docker; pulls debian:bookworm-slim and tailscale/tailscale)
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO/lib/common.sh"
NET=fastnet-e2e
TS_IMAGE="tailscale/tailscale:v$TAILSCALE_VERSION"
WORK=""
pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; docker logs fastnet-e2e-hs 2>&1 | tail -20; exit 1; }

cleanup() {
  docker rm -f fastnet-e2e-hs fastnet-e2e-c1 fastnet-e2e-c2 >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  [ -n "$WORK" ] && rm -rf -- "$WORK"
  return 0
}
trap cleanup EXIT
cleanup
WORK=$(mktemp -d)

log "building test server image"
docker build -q -t fastnet-test -f "$REPO/tests/Dockerfile" "$REPO" >/dev/null
docker pull -q "$TS_IMAGE" >/dev/null
docker network create "$NET" >/dev/null

log "starting server"
docker run -d --name fastnet-e2e-hs --network "$NET" -v "$REPO:/opt/fastnet:ro" fastnet-test sleep infinity >/dev/null
docker exec fastnet-e2e-hs bash -c '
  set -e
  source /opt/fastnet/lib/common.sh; source /opt/fastnet/lib/certs.sh; source /opt/fastnet/lib/config.sh
  mkdir -p /etc/fastnet /var/lib/headscale /var/run/headscale
  make_ca /etc/fastnet/ca
  make_server_cert /etc/fastnet/ca /etc/headscale/tls fastnet-e2e-hs
  HOST=fastnet-e2e-hs PORT=8443 render_config > /etc/headscale/config.yaml
  headscale configtest >/dev/null 2>&1
  ! grep -q ":9090" /etc/headscale/config.yaml  # 9090 belongs to the browser terminal
  printf "HOST=fastnet-e2e-hs\nPORT=8443\nTLS_MODE=own-ca\nBASE_DOMAIN=fastnet.internal\nSERVER_NAME=srv\n" > /etc/fastnet/fastnet.env
  (headscale serve >/var/log/headscale.log 2>&1 &)
  for i in $(seq 30); do curl -fs --cacert /etc/fastnet/ca/ca.crt https://fastnet-e2e-hs:8443/health >/dev/null && break; sleep 1; done
  headscale users create me >/dev/null' || fail "server setup"
pass "server: pinned headscale, own CA, generated config passes configtest, TLS verifies against the CA"

join() {  # join NAME — uses `fastnet add` on the server, then a real tailscale client
  local name=$1 key
  docker exec -e FASTNET_INVITES=/root/invites fastnet-e2e-hs /opt/fastnet/bin/fastnet add "$name" >/dev/null || fail "fastnet add $name"
  docker exec fastnet-e2e-hs bash -n "/root/invites/$name.sh" || fail "invite for $name is not valid bash"
  key=$(docker exec fastnet-e2e-hs bash -c "eval \"\$(grep ^AUTH_KEY= /root/invites/$name.sh)\"; echo \$AUTH_KEY")
  docker exec fastnet-e2e-hs bash -c "eval \"\$(grep ^CA_PEM= /root/invites/$name.sh)\"; printf '%s\n' \"\$CA_PEM\"" > "$WORK/ca-$name.pem"
  docker run -d --name "fastnet-e2e-$name" --network "$NET" --entrypoint sh \
    -v "$WORK/ca-$name.pem:/fastnet-ca.crt:ro" -e SSL_CERT_FILE=/fastnet-ca.crt \
    "$TS_IMAGE" -c 'tailscaled --tun=userspace-networking --no-logs-no-support --state=mem: >/tmp/d.log 2>&1 & sleep infinity' >/dev/null
  sleep 2
  docker exec "fastnet-e2e-$name" tailscale up --login-server https://fastnet-e2e-hs:8443 --auth-key "$key" --hostname "$name" --timeout 60s \
    || fail "$name could not join"
}

log "joining two clients"
join c1
join c2
pass "two clients joined with single-use keys from 'fastnet add', trusting only the embedded CA"

docker exec fastnet-e2e-c1 tailscale ping -c 5 --until-direct=false c2 >/dev/null || fail "c1 cannot reach c2"
pass "c1 reaches c2 over the network"

derp=$(docker exec fastnet-e2e-c1 tailscale debug derp-map 2>/dev/null)
echo "$derp" | grep -q '"RegionID": 999' || fail "self-hosted relay missing from DERP map"
if echo "$derp" | grep -qi 'tailscale.com'; then fail "client was given Tailscale's relays"; fi
pass "DERP map contains only the self-hosted relay (no tailscale.com servers)"

key_reuse=$(docker exec fastnet-e2e-hs bash -c 'eval "$(grep ^AUTH_KEY= /root/invites/c1.sh)"; echo $AUTH_KEY')
docker run --rm --network "$NET" --entrypoint sh -e SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt "$TS_IMAGE" \
  -c "tailscaled --tun=userspace-networking --no-logs-no-support --state=mem: >/dev/null 2>&1 & sleep 2; tailscale up --login-server https://fastnet-e2e-hs:8443 --auth-key $key_reuse --timeout 15s" >/dev/null 2>&1 \
  && fail "a client without the CA (or with a used key) was accepted"
pass "a client that does not trust the CA and reuses a spent key is refused"

out=$(docker exec fastnet-e2e-hs /opt/fastnet/bin/fastnet ls)
echo "$out" | grep -q "^c1 .*yes" && echo "$out" | grep -q "^c2 .*yes" || { echo "$out"; fail "fastnet ls does not show both clients online"; }
pass "fastnet ls lists both clients online"

docker exec fastnet-e2e-hs /opt/fastnet/bin/fastnet add c1 >/dev/null 2>&1 && fail "duplicate device name accepted"
docker exec fastnet-e2e-hs /opt/fastnet/bin/fastnet add 'Bad_Name' >/dev/null 2>&1 && fail "invalid device name accepted"
pass "duplicate and invalid device names are rejected"

docker exec fastnet-e2e-hs /opt/fastnet/bin/fastnet rm c2 2>/dev/null || fail "fastnet rm"
docker exec fastnet-e2e-hs /opt/fastnet/bin/fastnet ls | grep -q "^c2 " && fail "c2 still listed after rm"
pass "fastnet rm removes a device"

echo "all e2e checks passed"
