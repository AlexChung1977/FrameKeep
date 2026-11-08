#!/bin/sh
# Create a stable local codesigning identity so rebuilds keep the same
# code signature. That preserves TCC grants (screen recording) across compiles.
set -eu

NAME="Framekeep Local Codesign"
DIR="$HOME/Library/Application Support/Framekeep/codesign"
KEYCHAIN="$DIR/framekeep.keychain-db"
PASSFILE="$DIR/keychain-password"
TMP="$DIR/tmp-$$"

mkdir -p "$DIR"

if [ ! -f "$PASSFILE" ]; then
  openssl rand -base64 32 | tr -d '\n' > "$PASSFILE"
  chmod 600 "$PASSFILE"
fi
PASS="$(cat "$PASSFILE")"

if [ ! -f "$KEYCHAIN" ]; then
  security create-keychain -p "$PASS" "$KEYCHAIN"
fi

security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$PASS" "$KEYCHAIN"

# Keep the keychain in the user search list so Xcode/codesign can find it.
EXISTING="$(security list-keychains -d user | sed -E 's/^[[:space:]]*"//; s/"$//')"
FOUND=0
for kc in $EXISTING; do
  if [ "$kc" = "$KEYCHAIN" ]; then
    FOUND=1
    break
  fi
done
if [ "$FOUND" -eq 0 ]; then
  # shellcheck disable=SC2086
  security list-keychains -d user -s "$KEYCHAIN" $EXISTING
fi

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -Fq "$NAME"; then
  echo "codesign identity already present: $NAME"
  security find-identity -v -p codesigning "$KEYCHAIN"
  exit 0
fi

mkdir -p "$TMP"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$TMP/key.pem" \
  -out "$TMP/cert.pem" \
  -subj "/CN=$NAME" \
  -addext "extendedKeyUsage=codeSigning" \
  -addext "keyUsage=digitalSignature" \
  -addext "basicConstraints=critical,CA:FALSE"

openssl pkcs12 -export \
  -inkey "$TMP/key.pem" \
  -in "$TMP/cert.pem" \
  -out "$TMP/cert.p12" \
  -passout pass:framekeep-temp \
  -name "$NAME"

security import "$TMP/cert.p12" \
  -k "$KEYCHAIN" \
  -P framekeep-temp \
  -T /usr/bin/codesign \
  -T /usr/bin/security \
  -T /usr/bin/productsign \
  -T /usr/bin/productbuild

security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s -k "$PASS" "$KEYCHAIN" >/dev/null

# Trust for code signing so Gatekeeper-local checks accept it for this Mac.
security add-trusted-cert -d -r trustRoot -k "$KEYCHAIN" "$TMP/cert.pem" 2>/dev/null || true

echo "created codesign identity: $NAME"
security find-identity -v -p codesigning "$KEYCHAIN"
