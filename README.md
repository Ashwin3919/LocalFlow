# LocalFlow

Hold a key, speak, let go — your words appear in whatever app you are using.

Fully offline dictation for macOS. No account, no subscription, no server, no
telemetry. The app is **708 KB** and sits at **~51 MB of memory and 0% CPU**
when idle, because it uses the speech models already built into macOS instead of
bundling its own.

Speaking a 48-second message transcribes in **587 ms**. From releasing the key to
seeing text is about **290 ms**.

Supports **English and German**, switching automatically.

---

## Requirements

| | |
|---|---|
| **macOS 26 (Tahoe) or later** | Non-negotiable — the app uses `SpeechTranscriber`, which does not exist in earlier versions. |
| **Apple Silicon** | Tested on M-series. Intel is untested. |
| **Xcode Command Line Tools** | `xcode-select --install`. Full Xcode is *not* needed. |
| **~200 MB of disk, once** | macOS downloads its English and German speech models on first launch. After that it never touches the network. |

## Install

Three commands. Takes about a minute.

```sh
git clone <this-repo> LocalFlow && cd LocalFlow
./make-cert.sh          # one-time: creates a local signing certificate
./build.sh install      # builds, signs, copies to /Applications, launches
```

That is it. A **LocalFlow Setup** window opens and walks you through the three
permissions macOS requires. Grant them and start talking.

<details>
<summary>What <code>make-cert.sh</code> does, and why you need it</summary>

It creates a self-signed code-signing certificate in your login keychain and
trusts it for code signing only. No admin password, nothing leaves your machine.

Without it the app is signed ad-hoc, which means its identity is a hash of the
binary. Every rebuild produces a different hash, macOS treats it as a brand new
app, and **revokes your Accessibility and Input Monitoring permissions every
single time you build.** The certificate makes the identity stable, so the
permissions stick.

Undo it any time with `./make-cert.sh --undo`.
</details>

<details>
<summary>Why there is no download link</summary>

Distributing a prebuilt `.app` requires an Apple Developer account ($99/yr) to
notarize it. Without notarization macOS refuses to open a downloaded app and
sends you hunting through Privacy & Security to override it.

**Building it yourself sidesteps this entirely.** An app compiled on your own
machine has no quarantine flag, so Gatekeeper never objects. That is the whole
reason the install is source-based, and it is why it is three commands rather
than a wall of warnings to click through.
</details>

## Permissions

macOS gives no API to grant these — you must flip the switches yourself, and no
app can shortcut it. The setup window deep-links you to the right pane and ticks
each one off live as it takes effect, so there is no guessing and no relaunching.

| Permission | Why |
|---|---|
| **Microphone** | To hear you. The orange dot appears only while you are dictating. |
| **Accessibility** | To place text into the app you are typing in. |
| **Input Monitoring** | To notice the Fn key while another app is focused. |

You can reopen the guide any time from the menu bar → **Setup Guide…**

**One extra thing worth checking:** System Settings → Keyboard → *Press fn key
to* should be set to **Do Nothing**, otherwise Fn will fire an emoji picker or
switch input source while you are trying to dictate. The setup window flags this
if it is set to something else.

## Using it

| | |
|---|---|
| **Hold Fn** | Push-to-talk. Speak, release, text appears. |
| **Tap Fn** | Hands-free — keeps recording after you let go. Tap again to stop. |
| **Fn + Space** | Toggle hands-free explicitly. |
| **Esc** | Cancel without inserting anything. |
| **⌘⌃V** | Paste the last transcript again. |

Prefer not to use Fn? Settings → Hotkeys switches the trigger to **Ctrl+Option**.
The app does this automatically if it detects a non-Apple keyboard, where Fn
often does not report correctly.

While you speak, a small waveform floats near the bottom of the screen and moves
with your voice. It goes still when you go quiet, and vanishes when the text
lands. There is no "Transcribing…" label because it finishes faster than you
could read one.

## Privacy

- The microphone opens when you press the key and closes when you release it.
  Never held open.
- **No network calls, ever**, other than macOS fetching its own speech models on
  first launch, and an optional connection to `localhost:11434` if you turn on
  Ollama cleanup yourself. Off by default.
- No analytics, no crash reporting, no third-party SDKs of any kind.
- Transcript history is a plain text file at
  `~/Library/Application Support/LocalFlow/`. Turn it off in Settings, or delete it.

## Rebuilding and troubleshooting

```sh
./build.sh install     # rebuild and relaunch
make log               # watch what it is doing, live
make stop              # kill it
```

**Nothing happens when I hold Fn.** Open `make log` and check for
`Event tap active`. If Accessibility or Input Monitoring reads `false`, open the
Setup Guide.

**It says permissions are granted but it still does not work.** A stale entry
from an earlier build. Run:

```sh
tccutil reset Accessibility com.localflow.app
tccutil reset ListenEvent com.localflow.app
```

then relaunch and grant again. If either command prints twice, you had duplicate
entries — that was the problem.

**Text does not appear in one specific app.** Some apps need longer between the
clipboard being set and ⌘V arriving. Raise Settings → *Paste delay* from 80 ms to
150 ms.

## Where things are

`docs/ARCHITECTURE.md` explains how it works, with diagrams. `NOTES.md` records
why each decision was made, including the ones that did not work out. Read those
two before changing anything.

## Licence

Do what you like with it. It is provided as-is, with no warranty and no support.
