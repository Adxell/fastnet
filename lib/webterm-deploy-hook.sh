#!/usr/bin/env bash
# certbot deploy hook: hand a new Let's Encrypt certificate to Cockpit.
# certbot sets RENEWED_LINEAGE=/etc/letsencrypt/live/<domain>.
set -euo pipefail
[ -n "${RENEWED_LINEAGE:-}" ] || { echo "RENEWED_LINEAGE not set" >&2; exit 1; }
dir=/etc/cockpit/ws-certs.d
mkdir -p "$dir"
# Cockpit uses the alphabetically last .cert file, so 90-* wins over its self-signed 0-*
install -m 644 -o root -g root "$RENEWED_LINEAGE/fullchain.pem" "$dir/90-fastnet.cert"
install -m 600 -o root -g root "$RENEWED_LINEAGE/privkey.pem" "$dir/90-fastnet.key"
if [ -d /run/systemd/system ]; then systemctl try-restart cockpit.service 2>/dev/null || true; fi
