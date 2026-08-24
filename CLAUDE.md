# LocalFlow + NotesFM

Two features, one menu-bar app, no Electron, no network.

- **LocalFlow** — hold Fn, speak, release, text appears in the focused app. Shipped and in daily use.
- **NotesFM** — Fn+R records a meeting, Fn+P pauses it, transcribing both sides live into a markdown file. Built, not yet proven against a real call.

Recording and transcription are **always** on-device. Network traffic happens in exactly three places: macOS fetching its own speech models once, an optional localhost Ollama call that is **off by default**, and **Refine into Notes** — a button that hands one transcript to a CLI the user chooses. With the default (Codex) that reaches OpenAI; with the Ollama engine it reaches nothing at all, and the app is then entirely offline. Nothing is sent unless somebody presses it.

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

**Refine writes a new file; it never edits the transcript.** `MeetingStore.writeNotes` puts the notes next to the recording as `<meeting>-notes.md`. A model's rewrite of what was said must not be able to replace what was actually recorded, and the raw file stays the record.

**The notes are a tab on the meeting, not a second row in the library.** "Its own
file" was being read as "its own meeting": notes share their source's `started`
and sort by filename as the tiebreak, so they sorted *above* the transcript, the
library opened on them, and the recording looked like a duplicate underneath.
Pressing the button twice left `… — Notes 2`. The link is `notes-for: <stem>` in
the notes file's frontmatter; the filename is **derived, not uniqued**, so
refining again replaces. `MeetingStore.notes` stays the flat on-disk truth and
`meetings` is what the library lists. Files predating the key are paired by
filename at load, in memory only — an old library reads correctly without being
rewritten on disk. A notes file whose meeting is gone stays listed: an orphan is
still a file with somebody's words in it.

**The notes engine is a typed table, not a command name.** The obvious version of
"let people choose their tool" is a text field holding a binary name, and it
cannot work: these CLIs do not share an invocation shape. Verified against the
tools installed here rather than from memory — `codex` takes the prompt on stdin
and writes its answer to a **file** (`--output-last-message`) with `--sandbox
read-only`; `claude -p` answers on **stdout** and is restrained with
`--allowed-tools ''`; `cursor-agent -p` answers on stdout and needs `--mode ask
--trust --sandbox enabled`; `ollama run <model>` is stdin to stdout with nothing
to sandbox because it has no tools. Three different answers to every question, so
`RefineEngine` carries the arguments, and the `{dir}`/`{answer}`/`{prompt}`/`{model}`
tokens in them *declare the shape* — an `{answer}` present means the reply is a
file, a `{prompt}` present means the transcript goes in as an argument. That is
what keeps a row of toggles off the Settings pane. Presets are marked verified
only if they have actually been run; **Custom** is marked unsandboxed always,
because what somebody else's tool does with a `--yes` flag cannot be known.

**Ollama is the point of the engine setting, not a bonus.** Refine was the one
feature that broke the app's own premise. Choosing the local runner means nothing
leaves the Mac at all, and it is also the fastest of the four (3 s against Codex's
7 s), at the cost of a small model following the section headings loosely.

**Refine shells out to `codex exec`, and is given no power beyond text.** `--sandbox read-only` in a temp directory, `--ephemeral`, stdout to `/dev/null`, and the answer read from `--output-last-message` so progress chatter can never land in somebody's notes. Codex is an agentic coding tool; here it is a text transform and has no means to be anything else.

**Meeting files are markdown text, and the file is the source of truth.** `MeetingNote` is metadata plus a body *string*, not a parsed segment tree. A parsed model would let a hand edit put the file into a state the parser rejects, losing the user's words on the next save.

**Both streams heard it? The system-audio copy wins.** On speakers the mic
re-hears the far end, so both transcribers finalise the same sentence and the
file printed everything twice — measured on a real call: 29 of 48 mic lines were
echoes. `EchoFilter` decides from what each stream can physically hear: system
audio carries *only* the far end, so a sentence appearing there came from the far
end, and it is a digital copy rather than a recording of a loudspeaker. A mic
final therefore waits 1.5 s to see whether system audio heard it too. Matching is
shared words over the **union**, not over the shorter side — union scoring makes a
length mismatch count against a match, which is what stops a short far-end line
from being called an echo of a long mic line that also holds the user's own words.
Deliberately conservative: at 0.6 a heavily garbled duplicate survives, and that
is the right way to be wrong.

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
- **An agent CLI's progress output can land inside somebody's notes, and
  stripping the escape codes is not enough.** Measured from Ollama's real stdout:
  before wrapping a line it writes part of the next word, rewinds the cursor over
  it with `ESC[<n>D`, erases to end of line, breaks the line, then writes the word
  again in full. Deleting the escapes and keeping everything else put `assigned
  tasks to [K` and duplicated half-words into finished notes. `ESC[<n>D` has to be
  *honoured* — it deletes the last n characters — and the line break straight
  after it is the wrap, so the logical line has none. Ollama does this whether
  stdout is a pipe or a file, and neither `NO_COLOR` nor `TERM=dumb` stops it.
  This is why an engine that writes its answer to a file is trusted over one that
  answers on stdout, and why Settings has a **Test Engine…** button that shows the
  raw reply.
- **`.fixedSize(horizontal: false, vertical: true)` sets a pane's *minimum*
  height, and SwiftUI centres content it cannot fit.** This is what made the
  library window unusable, and it looked like everything except what it was. One
  `fixedSize` on the footer caption under the Refine button forced that sentence
  to its wrapped height; measured at the narrowest width the detail column
  allows, it wrapped far enough that the pane's minimum was taller than the
  window. SwiftUI then laid the split view out at that minimum and centred the
  overflow: content 1376pt in a 773pt window, 275pt clipped off the top, 328pt off
  the bottom, and the green button 1029pt *below* the sill. The sidebar read as
  blank and the detail pane as empty because their contents were not inside the
  window at all. The taller the transcript, the worse it got — which is why it was
  fine while meetings were short. `lineLimit` wraps without pinning a floor.
  **Do not reach for `NSHostingController.sizingOptions` here**; it is the obvious
  suspect, it matches the documented centring wording, and a harness proved it
  changes nothing (see `NOTES.md`).
- **A window that cannot become key silently eats every keystroke.** No error, no warning — the text field just never receives anything. This is what made "Add a note…" impossible to type into for the whole first version of the HUD.
- **Fn produces no keyDown, so `.holdBegan` fires before the letter of any chord.** Fn+R therefore started a dictation, which then tripped the meeting's own "finish dictating first" guard, so Fn+R never once started a meeting — and the release typed whatever it had heard into the focused app. `HotkeyManager.fireChord` marks the hold as spoken for and suppresses the release; `abandonHold()` discards the recording silently.
- **The library opening with nothing selected looks like a broken window.** The
  detail column is a placeholder, so the transcript *and* the Refine button under
  it are simply absent, with nothing on screen to suggest that clicking the list
  brings them back. It reads as the app having lost its contents. `present()` now
  lands on the newest meeting.
- **A SwiftUI window's layout can be read with the accessibility tree.** `osascript`
  walking `UI elements` of the live window is how "the button is missing" was told
  apart from "the pane the button lives in was never rendered" — it needs no
  clicking and nothing appears on screen. `cacheDisplay` into a bitmap does *not*
  work: SwiftUI is layer-backed and the capture comes out blank. The measurement
  that matters is each element's `y` against the window's own visible range: a
  control drawn *outside* its window is invisible rather than absent, and the two
  need opposite fixes. That comparison is what turned "the Refine button is
  missing" into "it is at y=7 and the window ends at y=-249".
- **`.fullSizeContentView` puts the content under the traffic lights.** The
  meeting HUD's timer was sitting behind its own close button. It also had no
  `.resizable`, so an hour of transcript was stuck in 300 px that could not be
  dragged bigger.
- **`setFrameAutosaveName` restores a frame saved by an older build.** Setting it
  overrides the `setContentSize` above it, so a three-pane window can come back
  smaller than its own minimum and clip the pane holding its main action. Both
  NotesFM windows now re-apply the default size when the restored frame is under
  the minimum.
- **A meeting must be closed on `applicationWillTerminate`.** Quitting mid-meeting
  — which is what `./build.sh install` does — left a transcript stamped
  `duration: 0` and missing everything since the last flush. `saveBeforeQuit()` is
  the synchronous subset of `stop()`; the terminate handler cannot await.
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

**Verified:** dictation end to end; `--notesfm-selftest` 117/117 — durability, markdown round trip, note stamping, the whole pause clock and the echo filter's thresholds against real pairs from a real call; zero build warnings; idle footprint 49 MB at 0.0% CPU after install.

**Verified: system audio capture, on this machine, for real.** A 5-minute call was
recorded with both streams — the log line is `system audio confirmed`. That
recording is also what proved the echo problem, and `Refine` was then run over the
whole 8 KB of it through the installed binary: **24.8 s**, and the notes named the
people the transcript named, marked the garbled parts `[unclear]`, and invented no
owners. The `--notesfm-refine` seam runs exactly the `Refine.notes` the green
button calls.

**Verified: the library window renders inside itself again.** It had been drawing
its own controls outside the window — measured before the fix: 1376pt of content
in a 773pt window, the title field 261pt above the top edge and the green Refine
button 1029pt below the bottom. After removing the `fixedSize` (see the gotcha
above): content 721pt against a 721pt host, **0 of 14 controls outside the
window**, titlebar reads "Meetings" rather than "All Meetings", and a real
`CGEvent` click on a list row switches the detail pane. Screenshots confirm the
sidebar, the list, the transcript and the green button all draw. The notes pairing
took the user's own library from 7 rows to 5, with the refined meetings showing a
wand and a `Notes | Transcript` switch that opens on the notes.

**Verified: all four notes engines, through the app binary.** `--notesfm-refine`
runs exactly the `Refine.notes` the green button calls. Same transcript, same
prompt, measured on this Mac: **Codex 7 s, Claude 9 s, Cursor Agent 55 s, Ollama
3 s**, all four returning clean markdown with zero escape bytes. Each engine's
read-only flag was tested by prompting it to write a file: Claude and Cursor Agent
both refused and **wrote nothing** — Claude said it would not route around the
block with a shell command. The Settings pane was checked through the
accessibility tree: engine picker and Test button render inside the window, and
the model field appears only for an engine whose command needs one.

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
- Real *dual* capture over a long call. One 5-minute call worked; the multi-hour
  question is still answered by docs only.
- A real meeting, of any length. The multi-hour question is answered by docs only.
- Text insertion outside TextEdit — Safari, Cursor, Slack, Terminal, Mail are all untested.
- German spoken through it. The locale retry path has never fired.
- Ollama cleanup. (The library sidebar and toolbar do render — observed.)
- **Pressing Refine and getting notes back, since the pairing change.** The button
  itself is now observed: it draws, it enables and disables, it reads "Refine
  Again" when notes exist, and the `Notes | Transcript` switch it lands on works.
  The write path is covered by the self-test. The full button → Codex → notes
  round trip has not been re-run against the new `writeNotes`.
- **A very long transcript through Refine.** Tested at ~1 kB. A two-hour meeting is a different proposition and the 240 s timeout is a guess.
- **Pause and resume against live audio.** The clock arithmetic is tested; stopping and rebuilding a real mic graph and a real process tap mid-meeting is not.
- **A long pause with the analyzer left idle.** Nothing documents what `SpeechAnalyzer` does when its input goes quiet for an hour.
- Fn+P, and Fn+R now that it no longer trips the dictation guard.
- The microphone surviving a device change mid-meeting, and meetings honouring the chosen mic.

**Known broken — measured, not suspected:**
- **Typing into the meeting HUD's note field does not work.** Previously listed
  here as merely unverified; it is a defect. A real `CGEvent` click (an
  accessibility press never reaches `sendEvent`) gives the field first responder —
  `AXFocused` true — and a real keystroke still lands in the frontmost
  application. Keyboard input goes to the key window of the *active* app and an
  accessory app is never active on its own; `NSApplication.h` says plainly that
  `activate()` "does not guarantee that the app will be activated at all".
  Removing `.nonactivatingPanel` made it worse, not better: the click then did not
  focus the field at all. Three approaches failed and were reverted rather than
  shipped — see the dead ends in `NOTES.md`. A fix needs a route that activates
  the app from a click macOS honours, most likely the status menu.

**Known open risks:** Core Audio taps reportedly return silence for Microsoft Teams; on speakers the mic re-hears the far end, so the same words may appear under both labels.

**Next, once capture is confirmed:** phase 3 is LLM cleanup and phase 4 is chat, both bring-your-own-key against an OpenAI-compatible `/v1/chat/completions` endpoint — one code path that covers hosted providers and local Ollama alike. Transcription stays local always; only an explicit, opt-in action ever leaves the machine, and a summary is written as a separate file so the raw transcript is never overwritten.
