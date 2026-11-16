# Test server image: Debian + the checksum-pinned headscale .deb, installed the same way
# server/install.sh does it. Used only by tests/e2e.sh.
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl openssl jq iproute2 bsdextrautils \
 && rm -rf /var/lib/apt/lists/*
COPY lib /tmp/lib
RUN bash -c 'set -e; source /tmp/lib/common.sh; a=$(detect_arch); sha=HEADSCALE_SHA256_$a; \
  download_verified "https://github.com/juanfont/headscale/releases/download/v${HEADSCALE_VERSION}/headscale_${HEADSCALE_VERSION}_linux_${a}.deb" "${!sha}" /tmp/hs.deb; \
  dpkg -i /tmp/hs.deb >/dev/null 2>&1 || true; test -x /usr/bin/headscale; rm -rf /tmp/hs.deb /tmp/lib'
