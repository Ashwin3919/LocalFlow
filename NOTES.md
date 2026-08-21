# LocalFlow Notes

Offline, local-only dictation for macOS. Hold a key, speak, release, text appears
in the focused app. No account, no subscription, no network except optional
localhost Ollama.

## Environment (verified 2026-08-21)

- macOS 26.5.2, Apple Silicon, 32 GB.
- Apple Swift 6.3.3, Command Line Tools only (no full Xcode needed — SwiftPM builds this).
- Ollama **not installed** on this machine. Cleanup is therefore shipped **off**
  by default, so the app works out of the box with raw transcripts.
- `AppleFnUsageType = 0` — the Fn key is already set to "Do Nothing" in System
  Settings, so Fn push-to-talk does not fight a system action here.

## Engine choice

**Apple `SpeechTranscriber` / `SpeechAnalyzer`** (macOS 26 framework).

Reasoning, weighed against the other two candidates:

- The model is system-owned, so it does not count against the app's own RSS.
  Measured idle footprint is ~50 MB, which is an order of magnitude under the
  700 MB budget. Parakeet via FluidAudio would have been ~600 MB resident and
  eaten almost the entire budget on its own.
- **German is a first-class supported locale**, not an afterthought. This was the
  deciding factor against Parakeet v3, whose German quality is materially behind
  its English. Both `en-US` and `de-DE` assets are installed at first launch and
  the engine auto-retries the other locale when the first pass looks too short
  (see `AppleSpeechEngine.transcribe`).
- Warm-load measured at **154 ms**, versus the 8–10 s cold start that motivated
  this project.

The known weakness is technical vocabulary. That is what the custom dictionary
plus the optional Ollama cleanup pass is for. If accuracy on jargon turns out to
be the binding constraint, swap in whisper.cpp `large-v3-turbo` q5_0 behind the
existing `TranscriptionEngine` protocol — nothing outside `AppleSpeechEngine.swift`
needs to change.

## Architecture

```
HotkeyManager   one CGEventTap, .defaultTap on .cgSessionEventTap
      │         classifies events only; all work goes to a background queue
      ▼
DictationController   @MainActor state machine: idle / recording / transcribing
      │
      ├── AudioRecorder      AVAudioEngine → 16 kHz mono Float32
      ├── AppleSpeechEngine  TranscriptionEngine protocol
      ├── Cleanup            optional Ollama, 3 s timeout, always falls back
      ├── TextInserter       AXUIElement first, pasteboard + Cmd+V fallback
      ├── FlowBar            transparent non-activating NSPanel, live waveform
      └── History            JSONL in ~/Library/Application Support/LocalFlow/
```

## Decisions and their reasons

### Microphone is opened per dictation, not held open

The brief asked for both "keep `AVAudioEngine` running with the tap installed at
all times" (for latency) and "do not hold the mic open continuously" (for
privacy). Those two directly contradict: installing a tap on the input node is
what lights the orange indicator, so an always-live tap means the indicator is on
24/7 and stops meaning anything.

Resolution: privacy wins, and the latency cost is bought back another way.
`AudioRecorder.prewarm()` resolves the hardware format, builds the
`AVAudioConverter`, and calls `engine.prepare()` at launch. `start()` then only
installs the tap and spins the engine. **Measured: 103 ms prewarm at launch, and
capture starts in single-digit to low-tens of ms afterwards** versus 144 ms in
the previous per-keypress build.

Consequence: there is no 300 ms pre-roll ring buffer, because a pre-roll
inherently requires an always-live microphone. Instead, the "tap to lock"
behaviour below means a too-short press is never silently thrown away.

### A short tap locks into hands-free instead of failing

The earlier build logged `Capture stopped (0.00 s)` repeatedly — a press shorter
than the engine start captured no audio at all and nothing happened, with no
feedback. Now:

- Hold longer than `minHold` (default 250 ms) → push-to-talk, release transcribes.
- Press shorter than `minHold` → interpreted as a tap and **locks into hands-free**,
  so recording continues. Tap again, press Fn+Space, or hit Esc to end it.
- Double-tap while already recording → also locks hands-free.

This makes every press do something. Configurable in Settings → Hotkeys.

### Insertion tries Accessibility before the pasteboard

`kAXSelectedTextAttribute` is only attempted when `AXUIElementIsAttributeSettable`
says yes. Some apps return `.success` for a write that does nothing, which would
silently swallow the transcript — checking settability first avoids that.

The pasteboard path saves every type of every pasteboard item and restores them
after `max(0.35 s, 3 × pasteDelay)`, so the clipboard is never left clobbered.

`waitForModifiersToClear()` exists because a synthesized Cmd+V merges with any
physically-held modifiers. If Fn or Ctrl+Opt is still down, Cmd+V becomes a
different shortcut entirely. It polls for up to 500 ms.

Synthesized events are tagged with `TextInserter.syntheticMarker` in the
`.eventSourceUserData` field so our own event tap does not react to its own
Cmd+V and loop.

### Cleanup never eats words

`Cleanup.polish` returns the raw transcript unchanged on any failure: Ollama
absent, model not pulled, 3 s timeout, non-200, undecodable JSON. It also has a
plausibility check — if the model returns fewer than 45% or more than 220% of the
original word count, the output is rejected as "the model answered the transcript
instead of cleaning it" and the raw text is used.

`think: false` is sent because qwen3 is a reasoning model, and `<think>` blocks
are stripped defensively anyway since some Ollama builds leak them regardless.
`keep_alive: -1` pins the model so it does not reload per dictation.

### Signing: use `make-cert.sh`, not ad-hoc

This is the single biggest maintenance gotcha. An ad-hoc signature's designated
requirement is the binary's **cdhash**, which changes on every rebuild. macOS
therefore treats each rebuild as a different application and **revokes
Accessibility and Input Monitoring**, so you re-grant permissions after every
single build.

`./make-cert.sh` creates a self-signed code-signing certificate in the login
keychain and trusts it for code signing (user trust only — no admin password).
The designated requirement then depends on the certificate, not the cdhash, so
grants survive rebuilds. `build.sh` picks the identity up automatically if it
exists and falls back to ad-hoc if it does not.

If permissions look granted but nothing works, the TCC entry is stale from an
older signature: select LocalFlow in the System Settings list, press **−**, then
re-add it with **+**.

### Notarization, if you ever want it

Ad-hoc and self-signed both mean Gatekeeper will warn on any other Mac. To ship
elsewhere you need:

1. An Apple Developer account ($99/yr) and a **Developer ID Application**
   certificate.
2. `codesign --sign "Developer ID Application: …" --options runtime --timestamp`
   — a real timestamp, not `--timestamp=none` as used here.
3. `Resources/LocalFlow.entitlements` already carries
   `com.apple.security.device.audio-input`, which the Hardened Runtime requires
   for microphone access. That file is why the build is already notarization-shaped.
4. `xcrun notarytool submit --wait` then `xcrun stapler staple`.

Accessibility and Input Monitoring are **never** plist entries. They are granted
only by the user in System Settings. Only `NSMicrophoneUsageDescription` (and
`NSSpeechRecognitionUsageDescription`) belong in `Info.plist`.

## Dead ends and things deliberately not done

- **300 ms pre-roll ring buffer** — requires an always-live microphone, which
  contradicts the privacy requirement. Replaced by prewarming plus tap-to-lock.
- **Consuming the Fn `flagsChanged` event** — not done. Fn is a modifier used by
  the F-key row and many other shortcuts; swallowing it would break the keyboard.
  Only `Space` (with the trigger held), `Esc` (only while recording), and
  `Cmd+Ctrl+V` are consumed.
- **Microphone picker via AVAudioEngine** — `AVAudioEngine` has no device
  property, so `AudioRecorder.applySelectedDevice` sets
  `kAudioOutputUnitProperty_CurrentDevice` on the input node's audio unit before
  the engine starts, resolving the saved UID through CoreAudio in
  `AudioDevices.swift`. Falls back to the system default and logs if that fails.

## Rebuilding

```
./make-cert.sh          # once, so permissions stop being revoked
./build.sh              # build + sign into .build/LocalFlow.app
./build.sh install       # also copy to /Applications and relaunch
make log                # tail -f /tmp/localflow.log
make stop               # kill the running instance
```

The log rotates itself at 512 KB and writes a header line per launch.
