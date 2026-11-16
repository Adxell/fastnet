# shellcheck shell=bash
# Your own certificate authority, so headscale needs no outside CA (no Let's Encrypt).

# make_ca DIR — creates DIR/ca.key and DIR/ca.crt once (10 years). Never overwrites.
make_ca() {
  local dir=$1
  [ -f "$dir/ca.crt" ] && return 0
  mkdir -p "$dir" && chmod 700 "$dir"
  openssl req -x509 -new -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$dir/ca.key" -out "$dir/ca.crt" -days 3650 \
    -subj "/CN=fastnet CA $(hostname -s 2>/dev/null || echo server) $(date +%Y%m%d)" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null || die "openssl failed creating the CA"
  chmod 600 "$dir/ca.key"
}

# make_server_cert CA_DIR OUT_DIR HOST — leaf certificate for HOST (IP or DNS name),
# plus 127.0.0.1/localhost so the server can join its own network without NAT hairpinning.
# 825 days is the longest validity Apple devices accept.
make_server_cert() {
  local ca=$1 out=$2 host=$3 san ext
  if is_ipv4 "$host"; then san="IP:$host"; else san="DNS:$host"; fi
  san="$san,IP:127.0.0.1,DNS:localhost"
  mkdir -p "$out"
  ext=$(mktemp)
  printf 'subjectAltName=%s\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\n' "$san" > "$ext"
  openssl req -new -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$out/server.key" -out "$out/server.csr" -subj "/CN=$host" 2>/dev/null &&
  openssl x509 -req -in "$out/server.csr" -CA "$ca/ca.crt" -CAkey "$ca/ca.key" -CAcreateserial \
    -out "$out/leaf.crt" -days 825 -sha256 -extfile "$ext" 2>/dev/null || { rm -f "$ext"; die "openssl failed signing the server certificate"; }
  rm -f "$ext" "$out/server.csr"
  # Full chain: some clients (Android) reject a leaf without its issuer.
  cat "$out/leaf.crt" "$ca/ca.crt" > "$out/server.crt"
  rm -f "$out/leaf.crt"
  chmod 640 "$out/server.key" "$out/server.crt"
}

ca_fingerprint() { openssl x509 -in "$1" -noout -fingerprint -sha256 | cut -d= -f2; }
