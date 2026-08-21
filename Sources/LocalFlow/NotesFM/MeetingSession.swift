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
    private var startedAt: Date?
    private var lastFlush = Date()

    var isRunning: Bool { state == .running }

    // MARK: - Start

    func start() async {
        guard state == .idle else { return }
        state = .running
        warning = nil
        lines = []
        pending = [:]
        elapsed = 0

        let started = Date()
        startedAt = started
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
        let mic = MicMeetingSource()
        let micTranscriber = MeetingTranscriber(speaker: .you, locale: locale)
        do {
            try await micTranscriber.start()
            try mic.start { [weak micTranscriber] buffer in
                micTranscriber?.append(buffer)
            }
        } catch {
            fail("Microphone unavailable: \(error.localizedDescription)")
            return
        }
        self.mic = mic
        self.micTranscriber = micTranscriber
        consume(micTranscriber)

        // System audio is optional. Losing it costs the other participants, not
        // the meeting, so a failure degrades rather than aborts.
        let system = SystemAudioSource()
        let systemTranscriber = MeetingTranscriber(speaker: .them, locale: locale)
        do {
            try await systemTranscriber.start()
            try system.start { [weak systemTranscriber] buffer in
                systemTranscriber?.append(buffer)
            }
            self.system = system
            self.systemTranscriber = systemTranscriber
            consume(systemTranscriber)
        } catch {
            await systemTranscriber.finish()
            warning = "Recording your voice only — \(error.localizedDescription)"
            Log.write("NotesFM: system audio unavailable, continuing mic-only: \(error.localizedDescription)")
        }

        startTicker()
        Sound.recordingStarted()
        Log.write("NotesFM: meeting started — \(writer?.url.lastPathComponent ?? "?")")
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

    // MARK: - Notes

    /// A thought the user wants in the record, typed or dictated mid-meeting.
    func addNote(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, state == .running else { return }
        writer?.appendNote(trimmed)
        lines.append(TranscribedSegment(
            text: trimmed,
            start: elapsed,
            end: elapsed,
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
        guard state == .running else { return }
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

        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? elapsed
        let url = writer?.url
        writer?.finish(duration: duration)

        mic = nil
        system = nil
        micTranscriber = nil
        systemTranscriber = nil
        writer = nil
        startedAt = nil
        state = .idle
        pending = [:]

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
        state = .idle
    }

    // MARK: - Clock and flush heartbeat

    private func startTicker() {
        ticker?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let started = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(started)

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
