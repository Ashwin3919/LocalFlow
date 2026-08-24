# LocalFlow + NotesFM

Two features, one menu-bar app, no Electron, no network.

- **LocalFlow** — hold Fn, speak, release, text appears in the focused app. Shipped and in daily use.
- **NotesFM** — Fn+R records a meeting, Fn+P pauses it, transcribing both sides live into a markdown file. Built, not yet proven against a real call.

Recording and transcription are **always** on-device. Network traffic happens in exactly three places: macOS fetching its own speech models once, an optional localhost Ollama call that is **off by default**, and **Refine into Notes** — a button that hands one transcript to the local Codex CLI, which does reach OpenAI. Nothing is sent unless somebody presses it.

## Working agreements

These come from the person who maintains this alone. They are not suggestions.

- **Boring, debuggable code over clever code.** Comments explain *why*, never *what*.
- **Check current docs before writing against an API.** Do not write Apple API code from memory. Both NotesFM research passes found that memory would have been wrong.
- **Say directly when something is not achievable.** Do not soften it.
- **Resource budget is hard**: under 700 MB RSS idle, effectively 0% idle CPU. This is the entire reason the project exists instead of paying for Wispr Flow.
- **Ask for as little help as possible.** Verify things yourself. When the user genuinely must click something, stop and give a short numbered list.
- **Report honestly.** Separate what was measured from what was assumed. Never claim a thing works because it compiles.

## Commands

```sh
./build.sh install                    # build, sign, copy to /Applications, relaunch
make log                              # tail -f /tmp/localflow.log
make stop
./make-cert.sh                        # once per machine; see Signing below

# Verification
/Applications/LocalFlow.app/Contents/MacOS/LocalFlow --notesfm-selftest
# Menu bar → Test Audio Capture…       (must be in-app; see TCC gotcha below)
```

Build into a scratch path when another agent might be building concurrently:
`swift build -c release --scratch-path /tmp/<something>`

## Layout

```
Sources/LocalFlow/
  main.swift               AppDelegate, menu bar, permissions, routes hotkey actions
  HotkeyManager.swift      one CGEventTap; classifies only, work goes to a queue
  DictationController.swift @MainActor state machine: idle / recording / transcribing
  AudioRecorder.swift      AVAudioEngine → 16 kHz mono, prewarmed, RMS ring for the waveform
  AppleSpeechEngine.swift  batch transcription behind TranscriptionEngine
  TextInserter.swift       AXUIElement first, pasteboard + synthetic Cmd+V fallback
  FlowBar.swift            transparent non-activating NSPanel, theme-adaptive waveform
  SetupWindow.swift        first-run permission guide, plain AppKit on purpose
  Settings/Sound/History/Log/KeyboardWatch/AudioDevices/Cleanup/SettingsWindow

Sources/LocalFlow/NotesFM/
  Contracts.swift          shared types — read this first
  MeetingSession.swift     @MainActor orchestrator: sources + transcribers + writer
  MeetingTranscriber.swift long-lived streaming SpeechAnalyzer, one per stream
  MicMeetingSource.swift   microphone, its own AVAudioEngine
  SystemAudioSource.swift  Core Audio process tap — the hardest file here
  MeetingWriter.swift      append-only, flushes every 15 s
  MeetingStore.swift       markdown + frontmatter, lenient parsing, folder scan
  NotesFMWindow.swift      NSWindow host
  NotesFMLibrary.swift     SwiftUI three-pane library
  MeetingHUD.swift         floating panel shown while recording
  SelfTest.swift           --notesfm-selftest
  CaptureTest.swift        Test Audio Capture… menu item
```

`docs/ARCHITECTURE.md` has the diagrams. `NOTES.md` has decisions and dead ends. Read both before changing anything structural.

## Decisions that will look wrong until you know why

**Apple `SpeechTranscriber`, not whisper.cpp.** The model is system-owned, so it sits outside the app's RSS: 1.8 MB bundle, ~49 MB resident, versus ~600 MB for a bundled model. German is also a first-class locale, which Parakeet's is not. Cost: macOS 26 + Apple Silicon only, hard-gated in `install.sh`, `build.sh` and `LSMinimumSystemVersion`.

**The microphone opens per dictation, not continuously.** The brief asked for both an always-live tap and a mic that is not held open. Those contradict — installing the tap is what lights the orange indicator. Privacy won; latency was bought back with `prewarm()`. Consequence: no pre-roll ring buffer, so a too-short press locks into hands-free instead of being discarded.

**Signing uses `make-cert.sh`, never ad-hoc.** An ad-hoc signature's designated requirement is the cdhash, which changes every rebuild, so macOS treats each build as a new app and **revokes Accessibility and Input Monitoring**. A self-signed cert makes the requirement depend on the certificate instead.

**Distribution is source-based, deliberately.** A prebuilt `.app` needs a paid Developer ID to notarize, or users click through security warnings. An app compiled on the user's own machine carries no quarantine flag, so Gatekeeper never objects.

**Transcripts are plain prose by default, not `**[00:04:12] You** —` lines.** The file is read end to end and then handed to a model; a wall of timestamped speaker prefixes serves neither. Dual capture still does the work it was built for — two streams are what allow both sides to be transcribed at all — the labels simply stop being printed. `Settings → Meetings` turns them back on, and `TranscriptStyle` is the switch. Typed notes stay as `>` blockquotes so the user's own words are never put in a speaker's mouth.

**Refine writes a new file; it never edits the transcript.** `MeetingStore.createSibling` puts the notes next to the recording as `… — Notes`. A model's rewrite of what was said must not be able to replace what was actually recorded, and the raw file stays the record.

**Refine shells out to `codex exec`, and is given no power beyond text.** `--sandbox read-only` in a temp directory, `--ephemeral`, stdout to `/dev/null`, and the answer read from `--output-last-message` so progress chatter can never land in somebody's notes. Codex is an agentic coding tool; here it is a text transform and has no means to be anything else.

**Meeting files are markdown text, and the file is the source of truth.** `MeetingNote` is metadata plus a body *string*, not a parsed segment tree. A parsed model would let a hand edit put the file into a state the parser rejects, losing the user's words on the next save.

**Speaker labels come from the stream, not a model.** Mic is You, system audio is Them. This is why two separate captures are worth the extra work — speaker identification is normally the hardest part of meeting transcription and here it is free.

**System audio uses Core Audio process taps, not ScreenCaptureKit.** Different TCC service (`kTCCServiceAudioCapture`), and its prompt says "record your system audio" rather than "capture the contents of the system display". ScreenCaptureKit also re-prompts monthly.

**Pause stops capture; it does not gate buffers.** `pause()` stops both sources outright rather than dropping their buffers, so the microphone indicator goes out. A pause the indicator contradicts is not one anybody should trust, and pausing is exactly what someone does before saying something off the record. The transcribers stay alive across the gap so the transcript keeps one clock.

**The meeting clock is recorded time, not wall clock.** `AnalyzerInput` is enqueued with no explicit start time, so the analyzer times every result by how much audio it has been handed — feed it nothing and its clock stops. `MeetingClock` mirrors that exactly. Get this wrong and a note added after a ten-minute pause is filed ten minutes below the words it was written about. It is a pure value type taking `Date` as a parameter because it is the only part of pause handling testable without a microphone.

**The meeting HUD is `KeyableMeetingPanel`, not `NonActivatingPanel`.** The two are separate questions and the SDK says so: `NSWindowStyleMaskNonactivatingPanel` "specifies that a panel that does not activate the owning application", while keyboard focus is decided by `canBecomeKeyWindow`. `NonActivatingPanel` returns false there — right for the dictation pill, fatal for a window with a text field.

**Meetings never use a preset.** `.transcription` reports neither timestamps nor partials; `.timeIndexedProgressiveTranscription` adds `.fastResults`, documented as trading accuracy for latency. Meetings want accuracy: `reportingOptions: [.volatileResults]`, `attributeOptions: [.audioTimeRange]`.

**`MeetingTranscriber` is not an actor.** `append` runs per buffer on the audio thread; an actor hop would allocate a `Task` each time for nothing. `NSLock` is unavailable from async contexts, hence the small synchronous accessor helpers.

## Gotchas that have already cost time

- **TCC attributes permissions to the responsible process.** A binary launched from a shell has the *terminal* as responsible, so it is denied the mic and silenced on the tap no matter what LocalFlow holds. Audio capture can only be tested in-app.
- **System Audio Recording cannot be queried or requested.** No API exists. The only way to know is to capture and inspect the samples. macOS also requires a **relaunch** after the grant.
- **`CATapDescription.isExclusive` is a scope switch, not a lock.** The global initialiser sets it `true` meaning "all except the listed processes". Setting it `false` inverts it to "only the listed processes" — silence.
- **Default output device changes leave the tap stale and silent.** Plugging in AirPods requires rebuilding the whole graph, tap included. Watched and handled.
- **Apple's analyzer performs no audio conversion** and rejects any format but the one it asked for. This is the documented cause of "works in batch, silent when streaming".
- **A GUI app does not inherit the shell's `PATH`.** `Refine.locate()` checks where the Codex CLI actually installs before falling back to asking a login shell. Assuming `codex` is on `PATH` works from a terminal and fails in the shipped app.
- **`Task { }` inside a `@MainActor` method inherits the main actor.** The `--notesfm-refine` seam deadlocked instantly because a `DispatchSemaphore` held the main thread while the `Task` waited for it. `Task.detached` is required whenever a blocking wait is involved.
- **Duplicate stale TCC entries** look identical in System Settings. If permissions read granted but nothing works: `tccutil reset Accessibility com.localflow.app` and `tccutil reset ListenEvent com.localflow.app`. Printing twice means duplicates were the problem.
- **A window that cannot become key silently eats every keystroke.** No error, no warning — the text field just never receives anything. This is what made "Add a note…" impossible to type into for the whole first version of the HUD.
- **Fn produces no keyDown, so `.holdBegan` fires before the letter of any chord.** Fn+R therefore started a dictation, which then tripped the meeting's own "finish dictating first" guard, so Fn+R never once started a meeting — and the release typed whatever it had heard into the focused app. `HotkeyManager.fireChord` marks the hold as spoken for and suppresses the release; `abandonHold()` discards the recording silently.
- Swift 6 strict concurrency is on. Resolve warnings; do not suppress them.

## Measured

| | |
|---|---|
| App on disk | 1.8 MB bundle (1792 KB binary) — the 740 KB in earlier notes was stale well before pause was added; the pre-pause binary measured 1656 KB |
| Idle RSS | 49 MB (71 MB after Settings opens once — SwiftUI, non-returning) |
| Idle CPU | 0.0% sustained |
| ASR warm-load | 88–107 ms (vs the 8–10 s cold start this replaces) |
| Release → text visible | ~290 ms |
| Long transcription | 48.63 s of audio in 587 ms (~83× real time) |

## State

Branch `feature/notesfm`. `main` holds shipped dictation. Tag `v0.2.0-dictation` is the last known-good dictation-only build.

**Verified:** dictation end to end; `--notesfm-selftest` 59/59 — durability, markdown round trip, note stamping and the whole pause clock; zero build warnings; idle footprint 49 MB at 0.0% CPU after install.

**Verified: the installer path.** Rehearsed end to end from a clean clone —
`install.sh` → checks → existing cert detected → release build → bundle → sign →
`/Applications` → launch, then `--notesfm-selftest` from the installed binary.
Accessibility and Input Monitoring survived being rebuilt from a *different
directory*, which is the claim the `make-cert.sh` decision rests on and had not
been demonstrated before. Piping the script into `sh` now fails with the
corrected command instead of a syntax error.

**Blocked on one thing only:** `install.sh` and `README.md` still say `<you>`
where the GitHub owner goes, and there is no git remote — nothing has ever been
pushed. The one-liner cannot work until both are filled in and the repo is
public.

**Not verified — do not claim these work:**
- Any real system-audio capture. The permission has never been granted on this machine.
- A real meeting, of any length. The multi-hour question is answered by docs only.
- Text insertion outside TextEdit — Safari, Cursor, Slack, Terminal, Mail are all untested.
- German spoken through it. The locale retry path has never fired.
- The library sidebar and toolbar rendering, and Ollama cleanup.
- **Typing into the HUD note field.** The panel fix follows from the SDK, but no keystroke has been observed landing in it.
- **The Refine button itself.** The code path behind it is proven — `--notesfm-refine` runs the same `Refine.notes` through the app binary and returned real notes in 8.7 s — but nobody has clicked the button, so the SwiftUI state, the green tint and the jump to the new note are unobserved.
- **A very long transcript through Refine.** Tested at ~1 kB. A two-hour meeting is a different proposition and the 240 s timeout is a guess.
- **Pause and resume against live audio.** The clock arithmetic is tested; stopping and rebuilding a real mic graph and a real process tap mid-meeting is not.
- **A long pause with the analyzer left idle.** Nothing documents what `SpeechAnalyzer` does when its input goes quiet for an hour.
- Fn+P, and Fn+R now that it no longer trips the dictation guard.
- The microphone surviving a device change mid-meeting, and meetings honouring the chosen mic.

**Known open risks:** Core Audio taps reportedly return silence for Microsoft Teams; on speakers the mic re-hears the far end, so the same words may appear under both labels.

**Next, once capture is confirmed:** phase 3 is LLM cleanup and phase 4 is chat, both bring-your-own-key against an OpenAI-compatible `/v1/chat/completions` endpoint — one code path that covers hosted providers and local Ollama alike. Transcription stays local always; only an explicit, opt-in action ever leaves the machine, and a summary is written as a separate file so the raw transcript is never overwritten.
