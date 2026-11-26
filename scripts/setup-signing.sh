#!/bin/bash
# Creates a self-signed code signing certificate in the login keychain, once per machine.
# The first build afterwards asks for keychain access: enter the login password and choose "Always Allow".
set -euo pipefail

IDENTITY="PeekShot Local Signing"
if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  echo "\"$IDENTITY\" already exists"
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

# The system LibreSSL writes a PKCS#12 format that `security import` accepts.
PASSWORD=$(uuidgen)
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$IDENTITY" \
  -out "$WORK/identity.p12" -passout "pass:$PASSWORD"
security import "$WORK/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P "$PASSWORD" -T /usr/bin/codesign
echo "Created \"$IDENTITY\""
