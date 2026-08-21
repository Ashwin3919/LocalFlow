import AVFoundation
import Foundation

/// One meeting, from Fn+R to Fn+R.
///
/// Owns two capture sources and two transcribers — microphone and system audio —
/// and a writer that appends to the markdown file as text is finalised. Nothing
/// waits until the end: the transcript is on disk while the meeting is still
/// happening, which is the entire point of the feature.
///
/// Audio samples are never accumulated. Three hours of Float32 at 16 kHz would be
/// about 690 MB; the text of the same meeting is a few hundred kilobytes. Buffers
/// go straight from the capture callback into the transcriber and are forgotten.
@MainActor
final class MeetingSession: ObservableObject {
    enum State: Equatable {
        case idle
        case running
        /// Capture is stopped but the meeting still exists: the transcribers are
        /// alive, the file is open, and notes can still be added.
        case paused
        case stopping
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    /// Finalised lines, newest last. Capped for display only — the file has all of it.
    @Published private(set) var lines: [TranscribedSegment] = []
    /// What each side is saying right now, before the engine commits to it.
    @Published private(set) var pending: [Speaker: String] = [:]
    /// Set when system audio could not be captured, so the UI can say why.
    @Published private(set) var warning: String?
    @Published private(set) var title: String = ""

    /// Fires with the finished note's id once a meeting is written.
    var onFinished: ((String) -> Void)?

    private static let displayedLineLimit = 300

    private var mic: MicMeetingSource?
    private var system: SystemAudioSource?
    private var micTranscriber: MeetingTranscriber?
    private var systemTranscriber: MeetingTranscriber?
    private var writer: MeetingWriter?
    private var consumers: [Task<Void, Never>] = []
    private var ticker: Timer?
    private var lastFlush = Date()

    /// Recorded time, paused spans excluded. See `MeetingClock`.
    private var clock = MeetingClock()

    var isRunning: Bool { state == .running }
    var isPaused: Bool { state == .paused }
    /// A meeting exists — recording or paused. What the menu bar and the
    /// dictation interlock care about.
    var isActive: Bool { state == .running || state == .paused }

    /// Recorded seconds so far, live.
    private var currentElapsed: TimeInterval { clock.elapsed(at: Date()) }

    // MARK: - Start

    func start() async {
        guard state == .idle else { return }
        state = .running
        warning = nil
        lines = []
        pending = [:]
        elapsed = 0

        let started = Date()
        clock.start(at: started)
        lastFlush = started
        title = Self.defaultTitle(for: started)

        let locale = Locale(identifier: Settings.shared.meetingLocale)

        do {
            writer = try MeetingWriter(root: NotesFM.defaultRoot, title: title, started: started)
        } catch {
            fail("Could not create the meeting file: \(error.localizedDescription)")
            return
        }

        // The microphone is required. Without it there is no meeting.
        let micTranscriber = MeetingTranscriber(speaker: .you, locale: locale)
        do {
            try await micTranscriber.start()
        } catch {
            fail("Microphone transcription unavailable: \(error.localizedDescription)")
            return
        }
        self.micTranscriber = micTranscriber
        self.mic = MicMeetingSource()
        consume(micTranscriber)
        do {
            try startMicCapture()
        } catch {
            fail("Microphone unavailable: \(error.localizedDescription)")
            return
        }

        // System audio is optional. Losing it costs the other participants, not
        // the meeting, so a failure degrades rather than aborts.
        let systemTranscriber = MeetingTranscriber(speaker: .them, locale: locale)
        do {
            try await systemTranscriber.start()
            self.systemTranscriber = systemTranscriber
            self.system = SystemAudioSource()
            try startSystemCapture()
            consume(systemTranscriber)
        } catch {
            await systemTranscriber.finish()
            self.systemTranscriber = nil
            self.system = nil
            warning = "Recording your voice only — \(error.localizedDescription)"
            Log.write("NotesFM: system audio unavailable, continuing mic-only: \(error.localizedDescription)")
        }

        startTicker()
        Sound.recordingStarted()
        Log.write("NotesFM: meeting started — \(writer?.url.lastPathComponent ?? "?")")
    }

    /// Attach the microphone to its transcriber.
    ///
    /// Factored out so `resume` goes through exactly the same path as `start`
    /// rather than a parallel copy that can drift out of step with it.
    private func startMicCapture() throws {
        guard let mic, let micTranscriber else {
            throw MeetingAudioError.unavailable("microphone stream")
        }
        try mic.start { [weak micTranscriber] buffer in
            micTranscriber?.append(buffer)
        }
    }

    private func startSystemCapture() throws {
        guard let system, let systemTranscriber else {
            throw MeetingAudioError.unavailable("system audio stream")
        }
        try system.start { [weak systemTranscriber] buffer in
            systemTranscriber?.append(buffer)
        }
    }

    private func consume(_ transcriber: MeetingTranscriber) {
        let task = Task { [weak self] in
            for await segment in transcriber.segments {
                guard let self else { return }
                await MainActor.run { self.receive(segment) }
            }
        }
        consumers.append(task)
    }

    private func receive(_ segment: TranscribedSegment) {
        guard state != .idle else { return }
        if segment.isFinal {
            pending[segment.speaker] = nil
            writer?.append(speaker: segment.speaker, at: segment.start, text: segment.text)
            lines.append(segment)
            if lines.count > Self.displayedLineLimit {
                lines.removeFirst(lines.count - Self.displayedLineLimit)
            }
        } else {
            pending[segment.speaker] = segment.text
        }
    }

    // MARK: - Pause

    /// Stop capturing without ending the meeting.
    ///
    /// The sources are genuinely stopped rather than having their buffers dropped
    /// on the floor. A pause that leaves the microphone indicator lit is not a
    /// pause anyone should trust, and the moment someone pauses is exactly the
    /// moment they are about to say something they do not want in the file. The
    /// transcribers stay alive, so the transcript keeps one continuous clock
    /// across the gap instead of restarting at zero.
    func pause() async {
        guard state == .running else { return }
        state = .paused

        mic?.stop()
        system?.stop()

        let now = Date()
        clock.pause(at: now)
        elapsed = clock.elapsed(at: now)

        ticker?.invalidate()
        ticker = nil

        // Collapse the volatile window so words that were half-recognised when
        // the pause landed are committed, rather than sitting unfinalised across
        // a gap that may last an hour.
        await micTranscriber?.flush()
        await systemTranscriber?.flush()
        writer?.flush()

        Sound.cancelled()
        Log.write(String(format: "NotesFM: meeting paused at %.0f s", elapsed))
    }

    /// Resume capture, rebuilding both audio graphs from scratch.
    ///
    /// Rebuilding is not laziness about saving state: the output device may have
    /// changed while the meeting was paused, and both a fresh tap and a fresh mic
    /// graph pick up the current hardware format, which the transcribers then
    /// convert from. The pause marker is written here rather than at pause time so
    /// it can state how long the gap was, and so it lands *after* any finalised
    /// text that was still arriving when the pause happened.
    func resume() async {
        guard state == .paused else { return }

        do {
            try startMicCapture()
        } catch {
            // Staying paused is the honest outcome. A running clock over a dead
            // microphone is the one failure this feature must never present.
            warning = "Could not resume the microphone — \(error.localizedDescription)"
            Log.write("NotesFM: resume failed: \(error.localizedDescription)")
            return
        }

        if system != nil {
            do {
                try startSystemCapture()
                warning = nil
            } catch {
                system = nil
                warning = "Recording your voice only — \(error.localizedDescription)"
                Log.write("NotesFM: system audio did not resume: \(error.localizedDescription)")
            }
        }

        let now = Date()
        let at = clock.elapsed(at: now)
        let gap = clock.resume(at: now)
        if gap > 0 {
            writer?.appendMarker("paused for \(NotesFM.spanDescription(gap))", at: at)
            writer?.flush()
        }

        state = .running
        startTicker()
        Sound.recordingStarted()
        Log.write("NotesFM: meeting resumed")
    }

    func togglePause() async {
        switch state {
        case .running: await pause()
        case .paused: await resume()
        case .idle, .stopping: break
        }
    }

    // MARK: - Notes

    /// A thought the user wants in the record, typed mid-meeting.
    ///
    /// Allowed while paused on purpose: pausing and then writing down what was
    /// just said off the record is the reason both features exist.
    func addNote(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isActive else { return }
        let at = currentElapsed
        writer?.appendNote(trimmed, at: at)
        lines.append(TranscribedSegment(
            text: trimmed,
            start: at,
            end: at,
            isFinal: true,
            speaker: .note
        ))
        writer?.flush()
    }

    func rename(to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        title = trimmed
    }

    // MARK: - Stop

    func stop() async {
        guard state == .running || state == .paused else { return }
        // Freeze the clock before anything else. Stopping while paused must not
        // count the pause, and stopping while running must not lose the last
        // second of the span.
        let duration = clock.elapsed(at: Date())
        clock.freeze(at: Date())
        state = .stopping

        ticker?.invalidate()
        ticker = nil

        // Stop capture first so no new audio arrives while the engines drain.
        mic?.stop()
        system?.stop()

        await micTranscriber?.finish()
        await systemTranscriber?.finish()
        for task in consumers { _ = await task.value }
        consumers = []

        let url = writer?.url
        writer?.finish(duration: duration)

        mic = nil
        system = nil
        micTranscriber = nil
        systemTranscriber = nil
        writer = nil
        state = .idle
        pending = [:]
        elapsed = duration

        Sound.pasted()
        if let url {
            let identifier = url.deletingPathExtension().lastPathComponent
            Log.write(String(format: "NotesFM: meeting saved (%.0f s) → %@", duration, url.lastPathComponent))
            MeetingStore.shared.reload()
            onFinished?(identifier)
        }
    }

    private func fail(_ message: String) {
        Log.write("NotesFM: \(message)")
        warning = message
        mic?.stop()
        system?.stop()
        writer = nil
        mic = nil
        system = nil
        micTranscriber = nil
        systemTranscriber = nil
        clock = MeetingClock()
        state = .idle
    }

    // MARK: - Clock and flush heartbeat

    private func startTicker() {
        ticker?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state == .running else { return }
                self.elapsed = self.clock.elapsed(at: Date())

                // The whole reason for a heartbeat: a crash or a dead battery
                // should cost at most this many seconds, not the whole meeting.
                if Date().timeIntervalSince(self.lastFlush) >= NotesFM.flushInterval {
                    self.lastFlush = Date()
                    self.writer?.flush()
                    Task { [weak self] in
                        await self?.micTranscriber?.flush()
                        await self?.systemTranscriber?.flush()
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private static func defaultTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE HH:mm"
        return "Meeting \(formatter.string(from: date))"
    }
}
