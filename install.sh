#!/bin/zsh
# One-command installer for LocalFlow.
#
#   curl -fsSL https://raw.githubusercontent.com/Ashwin3919/LocalFlow/main/install.sh | zsh
#
# or, from inside a clone:  ./install.sh
#
# Everything is checked up front, so the failure you get is a sentence rather
# than a wall of compiler output.
set -euo pipefail

REPO="${LOCALFLOW_REPO:-https://github.com/Ashwin3919/LocalFlow.git}"
CLONE_DIR="${LOCALFLOW_DIR:-$HOME/LocalFlow}"

MIN_MACOS=26

# Run under zsh, not sh.
#
# The whole point of the checks below is that a wrong machine gets a sentence
# instead of a wall of output. Piping this into `sh` used to defeat that before
# the first check ran: `print` is a zsh builtin, and sh rejects a function whose
# closing brace has no `;` before it, so the script died on a syntax error.
# People copy the command as printed, so it has to survive being run the wrong
# way and say which way is right.
if [ -z "${ZSH_VERSION:-}" ]; then
    echo "" >&2
    echo "Run this with zsh rather than sh:" >&2
    echo "" >&2
    echo "    curl -fsSL <the raw install.sh URL> | zsh" >&2
    echo "" >&2
    echo "Or, from inside a clone:  ./install.sh" >&2
    echo "" >&2
    exit 1
fi

bold() { print -P "%B$1%b"; }
fail() { print -u2 ""; print -u2 "$1"; print -u2 ""; exit 1; }

# Catch a repo URL that was never filled in.
#
# Only reachable when this script is fetched on its own, since running it inside
# a clone never consults REPO. Without this the user gets git's "does not appear
# to be a git repository" about a URL containing a literal `<you>`, which reads
# like their network is broken rather than like the link they were given is
# unfinished.
if [[ "$REPO" == *"<you>"* && ! -f "./Package.swift" ]]; then
    fail "This copy of install.sh still has a placeholder where the repository URL goes.

Whoever published it needs to replace <you> in the REPO line with the real
GitHub path, or you can point this run at the right one yourself:

    LOCALFLOW_REPO=https://github.com/OWNER/LocalFlow.git
    curl -fsSL <the raw install.sh URL> | LOCALFLOW_REPO=\$LOCALFLOW_REPO zsh"
fi

# ─── 1. macOS version ────────────────────────────────────────────────────────
os_version="$(sw_vers -productVersion)"
os_major="${os_version%%.*}"

if (( os_major < MIN_MACOS )); then
    fail "LocalFlow needs macOS ${MIN_MACOS} (Tahoe) or later. This Mac is on macOS ${os_version}.

It transcribes using SpeechTranscriber, Apple's on-device speech engine, which
was introduced in macOS ${MIN_MACOS} and simply does not exist before it. That engine is
also the reason the app is under 2 MB instead of 600 MB — there is no bundled
speech model to fall back on, by design.

Every Apple Silicon Mac can run macOS ${MIN_MACOS}: System Settings → General →
Software Update. Once you are on it, run this again."
fi

# ─── 2. Apple Silicon ────────────────────────────────────────────────────────
if [[ "$(uname -m)" != "arm64" ]]; then
    fail "LocalFlow is built for Apple Silicon (M1 and later). This Mac reports $(uname -m).

Apple's on-device speech models are not available on Intel hardware, so the
transcription engine has nothing to run on.

There is no workaround short of swapping in a different engine — see
NOTES.md if you want to try that."
fi

# ─── 3. Command Line Tools ───────────────────────────────────────────────────
if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swift >/dev/null 2>&1; then
    fail "Xcode Command Line Tools are missing. Install them, then run this again:

    xcode-select --install

Full Xcode is not needed — the Command Line Tools are about 1.5 GB and include
the Swift compiler, which is all this builds with."
fi

swift_version="$(swift --version 2>/dev/null | head -1)"

# ─── 4. Get the source ───────────────────────────────────────────────────────
if [[ -f "./Package.swift" ]]; then
    ROOT="$(pwd)"
    bold "==> Building from the current directory"
else
    command -v git >/dev/null 2>&1 || fail "git is not installed, so the source cannot be fetched."
    if [[ -d "$CLONE_DIR/.git" ]]; then
        bold "==> Updating existing clone at $CLONE_DIR"
        git -C "$CLONE_DIR" pull --ff-only
    else
        bold "==> Cloning into $CLONE_DIR"
        git clone --depth 1 "$REPO" "$CLONE_DIR"
    fi
    ROOT="$CLONE_DIR"
fi
cd "$ROOT"

print ""
bold "LocalFlow"
print "  macOS ${os_version} · $(uname -m) · ${swift_version}"
print "  source: ${ROOT}"
print ""

# ─── 5. Signing identity ─────────────────────────────────────────────────────
# Without a stable certificate every rebuild looks like a new app to macOS and
# the Accessibility / Input Monitoring grants are revoked. make-cert.sh touches
# the login keychain, so say so before running it.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "LocalFlow Self Signed"; then
    bold "==> Signing identity already present"
else
    bold "==> Creating a local code-signing certificate"
    print "    This adds a self-signed certificate to your login keychain and trusts"
    print "    it for code signing only. No admin password, nothing leaves this Mac."
    print "    Without it, macOS revokes the app's permissions on every rebuild."
    print "    Undo any time with: ./make-cert.sh --undo"
    print ""
    ./make-cert.sh
fi

# ─── 6. Build and install ────────────────────────────────────────────────────
./build.sh install

cat <<'DONE'

────────────────────────────────────────────────────────────────
LocalFlow is installed and running. Look for the waveform icon in
your menu bar.

A setup window should have opened with three permissions to grant.
macOS requires you to flip those switches yourself — no app is
allowed to do it for you. Each one ticks green the moment it takes
effect, so there is nothing to relaunch and nothing to guess.

Then hold Fn anywhere, speak, and let go.

  Rebuild later:  ./build.sh install
  Watch the log:  make log
  Uninstall:      rm -rf /Applications/LocalFlow.app && ./make-cert.sh --undo
────────────────────────────────────────────────────────────────
DONE
