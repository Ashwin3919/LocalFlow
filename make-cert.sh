#!/bin/zsh
# Create a stable self-signed code-signing identity for LocalFlow.
#
# Why this exists: an ad-hoc signature (`codesign --sign -`) has a designated
# requirement based on the binary's cdhash, which changes on every rebuild.
# macOS therefore treats each rebuild as a different application and revokes the
# Accessibility / Input Monitoring grants, so you would have to re-grant them
# every time. Signing with a real (even if self-signed) certificate makes the
# designated requirement depend on the certificate instead, so the permission
# grants survive rebuilds.
#
# This touches your login keychain. Read it before running it.
# Run it yourself:  ./make-cert.sh
# Undo it with:     ./make-cert.sh --undo
set -euo pipefail

NAME="LocalFlow Self Signed"
DIR="$HOME/.localflow-signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
P12_PASSWORD="localflow"   # not a secret; the file never leaves this machine

if [[ "${1:-}" == "--undo" ]]; then
    echo "==> Removing '$NAME' from the login keychain"
    while security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; do
        security delete-identity -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1 \
            || security delete-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1 \
            || break
    done
    rm -rf "$DIR"
    echo "==> Done. build.sh will fall back to ad-hoc signing."
    exit 0
fi

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "Identity '$NAME' already exists — nothing to do."
    security find-identity -v -p codesigning
    exit 0
fi

mkdir -p "$DIR"
cd "$DIR"

cat > openssl.cnf <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = LocalFlow Self Signed
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

echo "==> Generating key and self-signed certificate (valid 10 years)"
rm -f key.pem cert.pem identity.p12
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout key.pem -out cert.pem -config openssl.cnf 2>/dev/null

echo "==> Importing into the login keychain"
echo "    macOS may ask for your login password, and may ask twice. That is expected."

# OpenSSL 3 writes a PKCS#12 MAC that Apple's Security framework cannot verify
# when the password is empty, which fails as "MAC verification failed". Using a
# real password avoids that. Legacy PBE algorithms are requested for maximum
# compatibility with `security import`.
imported=0
if openssl pkcs12 -export -inkey key.pem -in cert.pem -out identity.p12 \
        -name "$NAME" -passout "pass:$P12_PASSWORD" \
        -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 2>/dev/null \
   && security import identity.p12 -k "$KEYCHAIN" -P "$P12_PASSWORD" \
        -T /usr/bin/codesign -A >/dev/null 2>&1; then
    echo "    imported via PKCS#12"
    imported=1
else
    # Fallback: import the private key and the certificate separately as PEM.
    # This skips PKCS#12 entirely and sidesteps every MAC/algorithm issue.
    echo "    PKCS#12 import did not take — importing key and certificate separately"
    security import key.pem  -k "$KEYCHAIN" -t priv -f openssl \
        -T /usr/bin/codesign -A >/dev/null
    security import cert.pem -k "$KEYCHAIN" -t cert -f openssl \
        -T /usr/bin/codesign -A >/dev/null
    echo "    imported via PEM"
    imported=1
fi

echo "==> Marking it trusted for code signing (user trust only, no admin needed)"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" cert.pem

echo
if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "==> Success. Code-signing identities now available:"
    security find-identity -v -p codesigning
    echo
    echo "Next:  ./build.sh install"
    echo "build.sh picks this identity up automatically."
else
    echo "==> The identity did not register. Current state:"
    security find-identity -v -p codesigning || true
    echo
    echo "Tell Claude what this printed; ad-hoc signing still works as a fallback."
    exit 1
fi
