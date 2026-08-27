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

# Note: no -v. A self-signed certificate is reported as CSSMERR_TP_NOT_TRUSTED and so
# is not a "valid" identity, but codesign signs with it perfectly well — and signing is
# all this is for.
if security find-identity -p codesigning | grep -qF "$NAME"; then
    echo "Certificate '$NAME' already exists — nothing to do."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Generating a self-signed code-signing certificate"
# Extensions go through a config file rather than -addext: the flag's availability
# differs between the LibreSSL macOS ships and the OpenSSL Homebrew puts first in PATH.
cat > "$WORK/openssl.cnf" <<CONFIG
[req]
distinguished_name = dn
prompt = no
[dn]
CN = $NAME
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONFIG

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -config "$WORK/openssl.cnf" -extensions v3 2>/dev/null

echo "==> Importing into the login keychain"
# Imported as separate PEM files rather than bundled into a PKCS#12. OpenSSL 3 writes
# PKCS#12 with algorithms the macOS Security framework cannot read, which fails as a
# misleading "MAC verification failed ... (wrong password?)".
#
# -T grants codesign access to the key up front, so signing does not prompt every time.
security import "$WORK/key.pem" -k "$KEYCHAIN" -T /usr/bin/codesign
security import "$WORK/cert.pem" -k "$KEYCHAIN" -T /usr/bin/codesign

if ! security find-identity -p codesigning | grep -qF "$NAME"; then
    echo "Import reported success but the identity is not visible to codesign." >&2
    exit 1
fi

echo
echo "Done. '$NAME' is now available to codesign."
echo "Scripts/build-app.sh will pick it up automatically."
echo
echo "It is listed as untrusted, which is expected and does not matter here: it exists"
echo "only to give the app a stable identity so privacy grants survive a rebuild."
