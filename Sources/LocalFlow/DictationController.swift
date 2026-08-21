import AppKit

/// The state machine that ties hotkeys, audio, ASR, cleanup and insertion
/// together. Everything user-visible flows through here.
@MainActor
final class DictationController {
    enum State: Equatable {
        case idle
        case recording(locked: Bool)
        case transcribing

        var isRecording: Bool {
            if case .recording = self { return true }
            return false
        }
    }

    private(set) var state: State = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    var onStateChange: ((State) -> Void)?
    var onTranscript: ((String) -> Void)?

    private let recorder = AudioRecorder()
    private let engine: any TranscriptionEngine
    private let flowBar = FlowBar()

    /// Serialises microphone start/stop so a fast press-release-press cannot
    /// interleave them. `stop()` sleeps to drain, so it must never run on main.
    private let pipeline = DispatchQueue(label: "com.localflow.pipeline")

    private(set) var lastTranscript: String = ""
    private var recordingStartedAt: ContinuousClock.Instant?

    init(engine: any TranscriptionEngine) {
        self.engine = engine
        flowBar.levelsProvider = { [weak self] count in
            self?.recorder.recentLevels(count) ?? []
        }
    }

    var isRecordingNow: Bool { state.isRecording }

    // MARK: - Warm-up

    func prepare() async {
        let granted = await AudioRecorder.requestPermission()
        Log.write("Microphone permission: \(granted ? "granted" : "DENIED")")

        pipeline.async { [recorder] in recorder.prewarm() }

        do {
            let started = ContinuousClock.now
            try await engine.prepare()
            let ms = started.duration(to: ContinuousClock.now) / .milliseconds(1)
            Log.write(String(format: "ASR warm-loaded in %.0f ms (%@)", ms, engine.displayName))
        } catch {
            Log.write("ASR prepare failed: \(error.localizedDescription)")
        }

        Task.detached(priority: .utility) { await Cleanup.warm() }
    }

    // MARK: - Hotkey actions

    func handle(_ action: HotkeyManager.Action) {
        switch action {
        case .holdBegan:
            guard !state.isRecording else { return }
            beginRecording(locked: false)

        case .holdEnded(let duration):
            guard case .recording(let locked) = state else { return }
            if locked { return }
            if duration < Settings.shared.minHold, Settings.shared.tapToLock {
                // Too short to be speech. Treat it as a tap and keep going
                // hands-free rather than throwing away the attempt.
                state = .recording(locked: true)
                flowBar.show(.listening(locked: true))
                Log.write(String(format: "Tap (%.0f ms) — locked into hands-free", duration * 1000))
                return
            }
            finishRecording()

        case .toggleMeeting:
            // Routed to NotesFM by the app delegate. Dictation deliberately
            // knows nothing about meetings.
            return

        case .toggleHandsFree:
            if state.isRecording {
                finishRecording()
            } else {
                beginRecording(locked: true)
            }

        case .lockHandsFree:
            guard case .recording = state else { return }
            state = .recording(locked: true)
            flowBar.show(.listening(locked: true))
            Log.write("Locked into hands-free")

        case .cancel:
            cancelRecording()

        case .pasteLast:
            pasteLast()
        }
    }

    // MARK: - Recording

    private func beginRecording(locked: Bool) {
        state = .recording(locked: locked)
        recordingStartedAt = ContinuousClock.now
        flowBar.show(.listening(locked: locked))
        Sound.recordingStarted()

        pipeline.async { [recorder] in
            do {
                try recorder.start()
            } catch {
                Log.write("Audio start failed: \(error.localizedDescription)")
                Task { @MainActor in
                    self.state = .idle
                    self.flowBar.flash("Microphone unavailable")
                }
            }
        }
    }

    private func finishRecording() {
        guard state.isRecording else { return }
        state = .transcribing
        // No "Transcribing" indicator: the round trip finishes in ~200 ms, so a
        // label would flash by unread. The bar simply goes away, and only the
        // failure paths below bring it back with a message.
        flowBar.hide()

        pipeline.async { [recorder] in
            let samples = recorder.stop()
            Task { @MainActor in
                await self.process(samples: samples)
            }
        }
    }

    private func cancelRecording() {
        guard state.isRecording else { return }
        state = .idle
        flowBar.flash("Cancelled")
        Sound.cancelled()
        pipeline.async { [recorder] in recorder.cancel() }
        Log.write("Recording cancelled")
    }

    // MARK: - Pipeline

    private func process(samples: [Float]) async {
        let seconds = Double(samples.count) / AudioRecorder.sampleRate
        guard seconds >= 0.25 else {
            Log.write(String(format: "Nothing captured (%.2f s)", seconds))
            state = .idle
            flowBar.flash("No audio captured")
            return
        }

        let transcribeStart = ContinuousClock.now
        var raw = ""
        do {
            raw = try await engine.transcribe(
                samples: samples,
                sampleRate: AudioRecorder.sampleRate
            )
        } catch {
            Log.write("Transcription failed: \(error.localizedDescription)")
            state = .idle
            flowBar.flash("Transcription failed")
            return
        }
        let asrMs = transcribeStart.duration(to: ContinuousClock.now) / .milliseconds(1)

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            Log.write(String(format: "No speech detected (%.2f s audio, %.0f ms ASR)", seconds, asrMs))
            state = .idle
            flowBar.flash("No speech detected")
            return
        }

        var final = trimmed
        if Settings.shared.cleanupEnabled {
            final = await Cleanup.polish(trimmed)
        }

        state = .idle
        flowBar.hide()

        lastTranscript = final
        onTranscript?(final)

        // Insertion blocks on sleeps and synthetic key posts; keep it off main.
        let toInsert = final
        pipeline.async {
            let path = TextInserter.insert(toInsert)
            Task { @MainActor in
                if path == .pasteboard { Sound.pasted() } else { Sound.pasted() }
            }
        }

        let totalMs = transcribeStart.duration(to: ContinuousClock.now) / .milliseconds(1)
        Log.write(String(
            format: "Done: %.2f s audio, %.0f ms ASR, %.0f ms total → %@",
            seconds, asrMs, totalMs, final
        ))

        History.append(History.Entry(
            date: Date(),
            raw: trimmed,
            final: final,
            seconds: seconds,
            engine: engine.displayName
        ))
    }

    private func pasteLast() {
        guard !lastTranscript.isEmpty else {
            flowBar.flash("No transcript yet")
            return
        }
        let text = lastTranscript
        pipeline.async {
            TextInserter.insert(text)
            Task { @MainActor in Sound.pasted() }
        }
        Log.write("Pasted last transcript on request")
    }
}
