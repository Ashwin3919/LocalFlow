#!/bin/zsh
# Build, bundle, ad-hoc sign and (optionally) install LocalFlow.
#   ./build.sh            build + sign into .build/LocalFlow.app
#   ./build.sh install    also copy to /Applications and relaunch
#   ./build.sh release    also pack dist/LocalFlow-<version>-arm64.zip to hand out
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
# A stale Command Line Tools install passes every check above and then fails deep
# in the build with "using Swift tools version 6.2.0 but the installed version is
# 5.10.0". Package.swift is swift-tools-version 6.2; catch an old toolchain here.
SWIFT_SEMVER="$(swift --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)"
SWIFT_MAJOR="${SWIFT_SEMVER%%.*}"; SWIFT_MINOR="${SWIFT_SEMVER#*.}"
if [[ -z "$SWIFT_SEMVER" ]] || (( SWIFT_MAJOR < 6 || (SWIFT_MAJOR == 6 && SWIFT_MINOR < 2) )); then
    echo "LocalFlow needs Swift 6.2 or later (this toolchain reports ${SWIFT_SEMVER:-none})." >&2
    echo "Update the Command Line Tools — no Apple ID, no full Xcode, ~900 MB:" >&2
    echo "    softwareupdate --list      # find 'Command Line Tools for Xcode 26.x'" >&2
    echo "    softwareupdate --install 'Command Line Tools for Xcode 26.6'" >&2
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

if [[ "${1:-}" == "release" ]]; then
    # A zip to hand somebody, signed with the same certificate as every other
    # build. Refusing to pack an ad-hoc signature is deliberate: its designated
    # requirement is the cdhash, so each new version would look like a different
    # app and revoke the recipient's Accessibility and Input Monitoring grants.
    if [[ "${SIGN_ARGS[2]:-}" == "-" || "${SIGN_ARGS[1]:-}" == "-" ]]; then
        echo "Refusing to pack a release from an ad-hoc signature." >&2
        echo "Run ./make-cert.sh once, then ./build.sh release — otherwise every" >&2
        echo "update you ship revokes the recipient's permissions." >&2
        exit 1
    fi

    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
    DIST="$ROOT/dist"
    STAGE="$DIST/LocalFlow-$VERSION"
    ZIP="$DIST/LocalFlow-$VERSION-arm64.zip"

    echo "==> Packing $ZIP"
    rm -rf "$STAGE" "$ZIP"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/LocalFlow.app"

    # The recipient will be stopped by Gatekeeper, because this is signed with a
    # certificate their Mac has no reason to trust. Shipping the way past it in
    # the zip is the difference between a working handoff and a bug report.
    cat > "$STAGE/INSTALL.txt" <<'TXT'
LocalFlow — install

Needs macOS 26 or later on Apple Silicon. It will not run on anything older,
because the on-device speech model it uses does not exist there.

1. Drag LocalFlow.app to /Applications.

2. Double-click it. macOS will refuse to open it and say it cannot check it for
   malicious software. That is expected: this build is signed, but not with a
   $99/year Apple Developer certificate, so your Mac has no way to recognise it.
   Nothing is being hidden from you — the source is on GitHub and you can build
   it yourself instead if you prefer.

   Go to System Settings -> Privacy & Security, scroll to the bottom, and click
   "Open Anyway" next to LocalFlow. Confirm, and enter your password.
   (Control-clicking the app no longer works for this; Apple removed that in
   macOS 15.)

   In a hurry, this does the same thing from a terminal:
       xattr -d com.apple.quarantine /Applications/LocalFlow.app

3. LocalFlow lives in the menu bar — there is no window and no Dock icon. Its
   first-run window asks for three permissions. All three are needed:
       Microphone         - to hear you
       Accessibility      - to type the text into the app you are using
       Input Monitoring   - to notice the Fn key being held

4. Quit and reopen LocalFlow after granting them.

5. Hold Fn, say something, let go. The text appears where your cursor is.

For meetings (Fn+R to record, Fn+P to pause), macOS also asks for System Audio
Recording the first time, and you have to relaunch the app after allowing it.

Everything is transcribed on your Mac. Nothing is uploaded unless you press
"Refine into Notes" yourself.
TXT

    # ditto, not zip: it preserves the bundle's structure and its signature.
    ( cd "$DIST" && ditto -c -k --sequesterRsrc --keepParent "LocalFlow-$VERSION" "$(basename "$ZIP")" )
    rm -rf "$STAGE"
    echo "==> $ZIP  ($(du -h "$ZIP" | cut -f1))"
    exit 0
fi

if [[ "${1:-}" == "install" ]]; then
    echo "==> Installing to /Applications"
    pkill -f "/Applications/LocalFlow.app/Contents/MacOS/LocalFlow" 2>/dev/null || true
    sleep 1
    rm -rf /Applications/LocalFlow.app
    cp -R "$APP" /Applications/LocalFlow.app
    echo "==> Launching"
    open /Applications/LocalFlow.app
fi
