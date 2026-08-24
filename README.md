# LocalFlow

Hold a key, speak, let go — your words appear in whatever app you are using.

Fully offline dictation for macOS. No account, no subscription, no server, no
telemetry. The app is **708 KB** and sits at **~51 MB of memory and 0% CPU**
when idle, because it uses the speech models already built into macOS instead of
bundling its own.

Speaking a 48-second message transcribes in **587 ms**. From releasing the key to
seeing text is about **290 ms**.

Supports **English and German**, switching automatically.

Built by [Ashwin Shirke](https://github.com/Ashwin3919) — a single-maintainer
project, made to avoid paying for a cloud dictation subscription.

---

## Requirements

| | |
|---|---|
| **macOS 26 (Tahoe) or later** | Non-negotiable — the app uses `SpeechTranscriber`, which does not exist in earlier versions. |
| **Apple Silicon** | Tested on M-series. Intel is untested. |
| **Xcode Command Line Tools** | `xcode-select --install`. Full Xcode is *not* needed. |
| **~200 MB of disk, once** | macOS downloads its English and German speech models on first launch. After that it never touches the network. |

## Install

One command:

```sh
curl -fsSL https://raw.githubusercontent.com/Ashwin3919/LocalFlow/main/install.sh | zsh
```

It checks your macOS version, architecture and toolchain first, so if your Mac
cannot run it you get one clear sentence instead of a page of compiler errors.
Then it clones, signs, builds, installs to `/Applications` and launches.

Or do it by hand, which is the same three steps:

```sh
git clone <this-repo> LocalFlow && cd LocalFlow
./make-cert.sh          # one-time: creates a local signing certificate
./build.sh install      # builds, signs, copies to /Applications, launches
```

Either way, a **LocalFlow Setup** window opens and walks you through the three
permissions macOS requires. Grant them and start talking.

### If your Mac is not supported

**macOS 26 is a hard requirement, not a preference.** The app transcribes with
`SpeechTranscriber`, Apple's on-device speech engine, which does not exist in
earlier versions — and that engine is precisely why the app is under 2 MB rather
than 600 MB, because there is no bundled model to fall back on.

Every Apple Silicon Mac *can* run macOS 26, so for M1 and later this is a
software update, not a hardware limit. Intel Macs cannot run the engine at all.

Supporting older versions means writing a second engine behind the existing
`TranscriptionEngine` protocol — `SFSpeechRecognizer` for macOS 13+, or
whisper.cpp. `NOTES.md` covers the trade-offs. Nothing outside one file changes.

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
| **Fn + R** | Start or stop recording a meeting. |
| **Fn + P** | Pause or resume the meeting. |

Prefer not to use Fn? Settings → Hotkeys switches the trigger to **Ctrl+Option**.
The app does this automatically if it detects a non-Apple keyboard, where Fn
often does not report correctly.

While you speak, a small waveform floats near the bottom of the screen and moves
with your voice. It goes still when you go quiet, and vanishes when the text
lands. There is no "Transcribing…" label because it finishes faster than you
could read one.

### Meetings

**Fn + R** records a meeting. Both sides are transcribed: your microphone becomes
*You* and the system audio becomes *Them*, so who said what comes from which
stream it arrived on rather than from any speaker-identification model. A small
floating window shows the transcript as it happens, with Pause and Stop.
**Fn + P** pauses — capture stops outright, so the orange microphone indicator
goes out, which is the point of pausing.

Each meeting is one markdown file in `~/Documents/NotesFM`, and that file is the
truth: edit it in Finder or any editor and the library picks the change up. The
library window (menu bar → **NotesFM Library…**, or ⌘L) lists them, searches
inside them, and sorts them into folders that are real sub-folders on disk.

**Refine into Meeting Notes** turns a transcript into a summary with decisions and
action items. It writes the notes to their own file next to the recording and
shows them as a **Notes** tab on the meeting; the raw transcript is never
rewritten, and refining again replaces the notes rather than piling up copies.

Which tool does the writing is up to you — `Settings → Meetings → Engine`:

| Engine | Where your transcript goes | Speed |
|---|---|---|
| **Codex CLI** (default) | OpenAI | ~7–10 s |
| **Claude Code** | Anthropic | ~7–9 s |
| **Cursor Agent** | Cursor | ~50 s |
| **Ollama** | **nowhere — it runs on this Mac** | ~3 s |
| **Custom…** | wherever your command sends it | — |

Each built-in engine is run with the flag that denies it file and shell access,
in a temporary folder. There is a **Test Engine…** button that runs three
sentences through your choice and shows you the raw reply, so a tool that prints
progress noise into its answer is obvious before a real meeting goes through it.

Picking **Ollama** makes LocalFlow entirely offline — see Privacy. Install it with
`brew install ollama`, start it (`brew services start ollama`), and pull a model
(`ollama pull llama3.2:3b`). A small local model is quick and follows the section
headings loosely; a bigger one reads better and takes longer.

## Privacy

- The microphone opens when you press the key and closes when you release it.
  Never held open.
- **Recording and transcription are always on-device.** Nothing about them
  touches a network, for dictation or for meetings.
- Network traffic happens in exactly three places, and only one of them can carry
  your words off the machine:
  - macOS fetching its own speech models, once, on first launch.
  - `localhost:11434` if you turn on Ollama cleanup yourself. Off by default, and
    localhost is not the internet.
  - **Refine into Meeting Notes**, which hands one transcript to whichever engine
    you chose. Nothing is sent unless you press that button, and Settings says
    where it goes right next to the picker. With the default (Codex) that is
    OpenAI; **choose Ollama and it goes nowhere at all** — the whole app is then
    offline. Engines use the CLI sign-in you already have, so no API key is
    stored here.
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
