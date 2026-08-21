#!/bin/zsh
# Build, bundle, ad-hoc sign and (optionally) install LocalFlow.
#   ./build.sh            build + sign into .build/LocalFlow.app
#   ./build.sh install    also copy to /Applications and relaunch
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/.build"
APP="$BUILD_DIR/LocalFlow.app"
BUNDLE_ID="com.localflow.app"

# Fail with a sentence rather than a page of compiler errors. The engine is
# macOS 26-only; see install.sh for the long explanation.
OS_MAJOR="$(sw_vers -productVersion)"; OS_MAJOR="${OS_MAJOR%%.*}"
if (( OS_MAJOR < 26 )); then
    echo "LocalFlow needs macOS 26 or later (this Mac is on $(sw_vers -productVersion))." >&2
    echo "It transcribes with SpeechTranscriber, which does not exist before macOS 26." >&2
    exit 1
fi
if [[ "$(uname -m)" != "arm64" ]]; then
    echo "LocalFlow needs Apple Silicon (this Mac reports $(uname -m))." >&2
    echo "Apple's on-device speech models are not available on Intel hardware." >&2
    exit 1
fi

echo "==> Compiling (release)"
swift build --package-path "$ROOT" -c release

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$BUILD_DIR/release/LocalFlow" "$APP/Contents/MacOS/LocalFlow"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Prefer a stable self-signed identity if one exists (see ./make-cert.sh).
# An ad-hoc signature's designated requirement is the binary's cdhash, which
# changes on every rebuild, so macOS revokes Accessibility / Input Monitoring
# each time. A certificate-based signature keeps that identity stable.
IDENTITY="LocalFlow Self Signed"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "==> Signing with '$IDENTITY' (permissions persist across rebuilds)"
    SIGN_ARGS=(--sign "$IDENTITY")
else
    echo "==> Signing ad-hoc (run ./make-cert.sh once to stop re-granting permissions)"
    SIGN_ARGS=(--sign -)
fi

codesign --force "${SIGN_ARGS[@]}" --identifier "$BUNDLE_ID" \
    --entitlements "$ROOT/Resources/LocalFlow.entitlements" \
    --options runtime --timestamp=none "$APP" 2>&1 | sed 's/^/    /'
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

echo "==> Built $APP"

if [[ "${1:-}" == "install" ]]; then
    echo "==> Installing to /Applications"
    pkill -f "/Applications/LocalFlow.app/Contents/MacOS/LocalFlow" 2>/dev/null || true
    sleep 1
    rm -rf /Applications/LocalFlow.app
    cp -R "$APP" /Applications/LocalFlow.app
    echo "==> Launching"
    open /Applications/LocalFlow.app
fi
