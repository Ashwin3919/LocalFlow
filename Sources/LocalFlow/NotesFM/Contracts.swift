import AVFoundation
import Foundation

// MARK: - The document
//
// Design rule that everything else follows from: **the markdown file on disk is
// the source of truth.** A meeting note is metadata plus a body string, not a
// parsed tree of segments. The live capture writes structured lines into the
// body; the library edits that body as plain text.
//
// The reason is robustness. If the model were a parsed structure, a user editing
// the raw markdown could put it into a state the parser rejects, and their words
// would be lost on the next save. With text as the truth, an edit can never
// corrupt anything — at worst a line stops being recognised as a speaker line
// and renders as ordinary prose.

/// One meeting, backed by one markdown file.
struct MeetingNote: Identifiable, Hashable, Sendable {
    /// The filename stem, which is also the stable identity on disk.
    var id: String
    var url: URL
    var title: String
    var started: Date
    /// Seconds of recorded audio. Zero for a note that was never recorded.
    var duration: TimeInterval
    /// Sub-folder relative to the store root; `nil` means the root itself.
    var folder: String?
    /// Everything after the YAML frontmatter.
    var body: String

    /// First non-empty, non-heading line of the body — used in the list.
    var snippet: String {
        for line in body.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("---") else { continue }
            return String(trimmed.prefix(140))
        }
        return ""
    }
}

/// Who produced a line of transcript.
///
/// Attribution comes from *which audio stream* the words arrived on, not from
/// any speaker-identification model: the microphone is you, the system output is
/// everyone else. That is the whole trick, and it is why two separate capture
/// streams are worth the extra work.
enum Speaker: String, Sendable, CaseIterable {
    case you
    case them
    /// A note the user added themselves during the meeting.
    case note

    var label: String {
        switch self {
        case .you: "You"
        case .them: "Them"
        case .note: "Note"
        }
    }
}

// MARK: - Streaming transcription

/// One run of recognised text, as it arrives from the engine.
struct TranscribedSegment: Sendable, Hashable {
    var text: String
    /// Seconds from the start of the session.
    var start: TimeInterval
    var end: TimeInterval
    /// `false` while the engine may still revise these words.
    var isFinal: Bool
    var speaker: Speaker
}

/// A long-lived transcription session, as opposed to `TranscriptionEngine`,
/// which transcribes one finished buffer. Deliberately a separate protocol: the
/// dictation path must keep working exactly as it does today, and a batch
/// transcriber and a streaming one have genuinely different shapes.
///
/// Buffers are passed as `AVAudioPCMBuffer` in whatever format the hardware
/// produced, not as `[Float]` at an assumed rate. Apple's analyzer performs **no
/// audio conversion of its own** and rejects anything that is not exactly the
/// format it asked for, so conversion has to happen in one place that knows what
/// that format is — here — rather than being guessed at the capture end.
protocol StreamingTranscriber: AnyObject, Sendable {
    /// Segments as the engine produces them. Volatile ones are included and
    /// flagged, so a caller can show live text but persist only finalised text.
    var segments: AsyncStream<TranscribedSegment> { get }

    func start() async throws
    /// Called from the audio thread. Must not block.
    func append(_ buffer: AVAudioPCMBuffer)
    /// Collapse the pending window so unfinalised state cannot accumulate.
    func flush() async
    /// Drain, finalise and stop. Safe to call twice.
    func finish() async
}

// MARK: - Audio capture

/// Where a stream of meeting audio comes from.
///
/// Buffers arrive on an unspecified thread, usually a real-time audio thread, so
/// callbacks must not block or touch the main actor synchronously. The buffer is
/// only valid for the duration of the call — copy anything you keep.
protocol MeetingAudioSource: AnyObject {
    /// Human-readable, for logs and the UI.
    var name: String { get }
    /// Which side of the conversation this source represents.
    var speaker: Speaker { get }
    var isRunning: Bool { get }

    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws
    func stop()
}

/// Raised by a source that cannot run on this machine or lacks permission, so
/// the UI can say which of the two it is instead of failing silently.
enum MeetingAudioError: LocalizedError {
    case permissionDenied(String)
    case unavailable(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let what): "Permission needed: \(what)"
        case .unavailable(let what): "Not available: \(what)"
        case .failed(let what): "Audio capture failed: \(what)"
        }
    }
}

/// How transcript lines are written into the file.
///
/// `plain` is the default because of how the file is actually used: it is read
/// end to end, and then handed to a model to turn into notes. A wall of
/// `**[00:04:12] You** —` prefixes serves neither. Attribution still does the
/// work it was built for — two capture streams are what allow both sides to be
/// transcribed at all — it simply stops being printed.
enum TranscriptStyle: String, Sendable {
    /// Continuous prose. No timestamps, no speaker names; a change of speaker is
    /// a paragraph break and nothing more.
    case plain
    /// `**[00:04:12] You** — …`, which is what makes a transcript searchable by
    /// position and by who was talking.
    case labelled
}

// MARK: - The meeting clock

/// Wall time minus every paused span.
///
/// A separate value type, and not just three fields on `MeetingSession`, for two
/// reasons. It is the one part of pause handling that can be checked without a
/// microphone — `MeetingSession` needs TCC permission and real hardware, this
/// needs a date — and it is the part most worth checking, because every timestamp
/// in the file, the duration in the frontmatter, and the position of every note
/// are derived from it.
///
/// Why recorded time rather than wall clock is the meeting's clock: `AnalyzerInput`
/// is enqueued without an explicit start time, so Apple's analyzer times each
/// result by how much audio it has been handed. Hand it nothing during a pause and
/// its clock stops. If this one kept running, a note added after a ten-minute
/// pause would be filed ten minutes below the words it was written about.
///
/// `Date` is passed in rather than read inside, so a test can advance time.
struct MeetingClock: Equatable {
    private var accumulated: TimeInterval = 0
    /// Start of the span currently being recorded; `nil` while paused or stopped.
    private var spanStartedAt: Date?
    private var pausedAt: Date?

    var isPaused: Bool { pausedAt != nil }

    mutating func start(at now: Date) {
        accumulated = 0
        spanStartedAt = now
        pausedAt = nil
    }

    /// Seconds recorded so far.
    func elapsed(at now: Date) -> TimeInterval {
        guard let spanStartedAt else { return accumulated }
        return accumulated + now.timeIntervalSince(spanStartedAt)
    }

    mutating func pause(at now: Date) {
        guard spanStartedAt != nil else { return }
        accumulated = elapsed(at: now)
        spanStartedAt = nil
        pausedAt = now
    }

    /// Resumes and reports how long the pause lasted, which is what the marker
    /// line in the transcript says.
    @discardableResult
    mutating func resume(at now: Date) -> TimeInterval {
        guard let pausedAt else { return 0 }
        let gap = now.timeIntervalSince(pausedAt)
        self.pausedAt = nil
        spanStartedAt = now
        return gap
    }

    /// Stops the clock for good. Idempotent, so stopping a paused meeting cannot
    /// add the pause to the total.
    mutating func freeze(at now: Date) {
        accumulated = elapsed(at: now)
        spanStartedAt = nil
        pausedAt = nil
    }
}

// MARK: - Shared constants

enum NotesFM {
    /// Used only for the level meter and for sizing waveform history. The
    /// speech engine dictates its own format via `bestAvailableAudioFormat`,
    /// which is not necessarily this, so never assume it for transcription.
    static let meterSampleRate: Double = 16_000

    /// Transcript is flushed to disk this often, so a crash or a dead battery
    /// costs at most this many seconds of a meeting.
    static let flushInterval: TimeInterval = 15

    /// Where meetings live. Documents, not Application Support: "the files are
    /// yours" only means something if you can find them without a terminal.
    static var defaultRoot: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return documents.appendingPathComponent("NotesFM", isDirectory: true)
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// "2m 14s" — a *length*, for the pause marker. `timestamp` is not used there
    /// because 00:02:14 in a transcript reads as a position, not a duration.
    static func spanDescription(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(secs)s" }
        return "\(secs)s"
    }
}
