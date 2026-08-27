#!/bin/bash
#
# Creates a local self-signed code-signing certificate, once.
#
# Why this is needed: an ad-hoc signature has no identity, so macOS identifies the app
# purely by the hash of its contents:
#
#     designated => cdhash H"776db06f..."
#
# That hash changes on every build, and privacy grants are attached to it. Input
# Monitoring and Accessibility therefore have to be granted again after every single
# rebuild, which makes the app unusable to develop against.
#
# Signing with a certificate — even a self-signed one that Gatekeeper does not trust —
# changes the requirement to "this bundle identifier, signed by this certificate",
# which survives rebuilds. The grant is then given once.
#
# This only affects your own machine. It does not make the app trusted for anyone else;
# distribution still needs a real Developer ID. To undo it, delete the certificate in
# Keychain Access.

set -euo pipefail

NAME="${SIGNING_IDENTITY:-PenBridge Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -qF "$NAME"; then
    echo "Certificate '$NAME' already exists — nothing to do."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Generating a self-signed code-signing certificate"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    2>/dev/null

openssl pkcs12 -export -out "$WORK/identity.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -passout pass: 2>/dev/null

echo "==> Importing into the login keychain"
# -T grants codesign access to the key up front, so signing does not prompt every time.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "" -T /usr/bin/codesign

echo
echo "Done. '$NAME' is now available to codesign."
echo "Scripts/build-app.sh will pick it up automatically."
echo
echo "macOS may ask for your login password the first time it signs — that is the"
echo "keychain releasing the key to codesign. Choosing \"Always Allow\" stops it asking."
