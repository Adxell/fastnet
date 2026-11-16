# shellcheck shell=bash
# Shared helpers for fastnet. Sourced by server/install.sh, bin/fastnet and embedded
# into every device invite, so it must stay self-contained (bash + coreutils + curl).

# ---- pinned versions and checksums (update together; see README "Upgrading")
HEADSCALE_VERSION=0.29.7
HEADSCALE_SHA256_amd64=d230c5fc8db06cf1868f4ec0077b89e5e2ccf3b22a3259efa6d080db2d5f921c
HEADSCALE_SHA256_arm64=a68f258a2a13a87321671f8cc613500986ffc40d0d2eacfdbf0b890b8b94227e
TAILSCALE_VERSION=1.104.7
TAILSCALE_SHA256_amd64=e56693ff74a64f2591b7e819c280635a100aae1ddfb0ef058fcd052b7cd8d16c
TAILSCALE_SHA256_arm64=d6bed2720310b328b861f943d7b4016c5358a9bad60575eb51e8143b79068484

log() { printf '[fastnet] %s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

need_root() { [ "$(id -u)" = 0 ] || die "run this as root (sudo)"; }

detect_arch() {
  case "$(uname -m)" in
    x86_64 | amd64) echo amd64 ;;
    aarch64 | arm64) echo arm64 ;;
    *) die "unsupported CPU architecture $(uname -m) (amd64 and arm64 are supported)" ;;
  esac
}

is_ipv4() { [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

valid_name() { [[ $1 =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; }

# download_verified URL SHA256 DEST — refuses anything whose checksum does not match the pin.
download_verified() {
  local url=$1 want=$2 dest=$3 got
  curl -fsSL --retry 3 -o "$dest" "$url" || die "download failed: $url"
  got=$(sha256sum "$dest" | cut -d' ' -f1)
  [ "$got" = "$want" ] || { rm -f "$dest"; die "checksum mismatch for $url (got $got, want $want)"; }
}

has_systemd() { [ -d /run/systemd/system ]; }

# Make sure tailscaled never uploads logs to Tailscale Inc.
disable_tailscale_logs() {
  local defaults=/etc/default/tailscaled
  [ -f "$defaults" ] || printf 'PORT="41641"\nFLAGS=""\n' > "$defaults"
  if ! grep -q -- '--no-logs-no-support' "$defaults"; then
    if grep -q '^FLAGS=' "$defaults"; then
      sed -i 's/^FLAGS="\(.*\)"/FLAGS="\1 --no-logs-no-support"/; s/FLAGS=" /FLAGS="/' "$defaults"
    else
      echo 'FLAGS="--no-logs-no-support"' >> "$defaults"
    fi
  fi
}

# Install the open-source tailscale/tailscaled binaries (Linux, systemd) unless present.
install_tailscale() {
  local arch tmp sha
  has_systemd || die "systemd is not running. On WSL2 enable it (/etc/wsl.conf: [boot] systemd=true, then 'wsl --shutdown')."
  if command -v tailscaled >/dev/null 2>&1; then
    log "tailscale already installed ($(tailscale version 2>/dev/null | head -n1))"
  else
    arch=$(detect_arch)
    tmp=$(mktemp -d)
    sha="TAILSCALE_SHA256_$arch"
    log "installing tailscale $TAILSCALE_VERSION (open-source client)"
    download_verified "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_${arch}.tgz" "${!sha}" "$tmp/ts.tgz"
    tar -xzf "$tmp/ts.tgz" -C "$tmp"
    local dir="$tmp/tailscale_${TAILSCALE_VERSION}_${arch}"
    install -m 0755 "$dir/tailscale" /usr/bin/tailscale
    install -m 0755 "$dir/tailscaled" /usr/sbin/tailscaled
    install -m 0644 "$dir/systemd/tailscaled.service" /etc/systemd/system/tailscaled.service
    rm -rf "$tmp"
  fi
  disable_tailscale_logs
  systemctl daemon-reload
  systemctl enable tailscaled >/dev/null 2>&1
  systemctl restart tailscaled  # also reloads trusted CAs
  for _ in $(seq 1 40); do [ -S /run/tailscale/tailscaled.sock ] && return 0; sleep 0.5; done
  die "tailscaled did not start (journalctl -u tailscaled)"
}

# trust_ca FILE — add the fastnet CA to the system trust store (Linux distros, macOS).
trust_ca() {
  local ca=$1
  case "$(uname -s)" in
    Darwin)
      security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$ca" ;;
    Linux)
      if [ -d /usr/local/share/ca-certificates ] && command -v update-ca-certificates >/dev/null; then
        install -m 0644 "$ca" /usr/local/share/ca-certificates/fastnet-ca.crt && update-ca-certificates >/dev/null
      elif [ -d /etc/pki/ca-trust/source/anchors ]; then
        install -m 0644 "$ca" /etc/pki/ca-trust/source/anchors/fastnet-ca.crt && update-ca-trust
      elif command -v trust >/dev/null; then
        trust anchor --store "$ca"
      else
        die "do not know how to add a CA on this system; add $ca to the trust store by hand"
      fi ;;
    *) die "unsupported OS $(uname -s)" ;;
  esac
  log "trusted the fastnet CA"
}
