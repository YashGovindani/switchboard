#!/bin/zsh
# One-time setup: creates a self-signed code-signing certificate
# ("Switchboard Signing") in the login keychain so Switchboard.app keeps a
# stable identity across rebuilds — macOS privacy grants (Accessibility)
# then survive reinstalls instead of resetting on every build.
set -euo pipefail

if security find-identity -v -p codesigning 2>/dev/null | grep -q "Switchboard Signing"; then
    echo "Signing identity 'Switchboard Signing' already exists."
    exit 0
fi

DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT

cat > "$DIR/cert.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Switchboard Signing
[ext]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:false
EOF

openssl req -x509 -newkey rsa:2048 -keyout "$DIR/key.pem" -out "$DIR/cert.pem" \
    -days 3650 -nodes -config "$DIR/cert.cnf" >/dev/null 2>&1
# OpenSSL 3 needs -legacy for a PKCS12 the macOS keychain can import.
openssl pkcs12 -export -legacy -out "$DIR/switchboard.p12" -inkey "$DIR/key.pem" \
    -in "$DIR/cert.pem" -passout pass:switchboard 2>/dev/null ||
openssl pkcs12 -export -out "$DIR/switchboard.p12" -inkey "$DIR/key.pem" \
    -in "$DIR/cert.pem" -passout pass:switchboard

KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
security import "$DIR/switchboard.p12" -k "$KEYCHAIN" -P switchboard -A

# May show a system dialog asking to confirm the trust change.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$DIR/cert.pem"

echo "Created signing identity:"
security find-identity -v -p codesigning | grep "Switchboard Signing" || true
