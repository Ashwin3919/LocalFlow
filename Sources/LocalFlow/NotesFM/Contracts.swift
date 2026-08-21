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
protocol StreamingTranscriber: AnyObject, Sendable {
    /// Segments as the engine produces them, volatile ones included.
    var segments: AsyncStream<TranscribedSegment> { get }

    func start() async throws
    /// Feed 16 kHz mono Float32 samples. `at` is seconds since session start.
    func append(samples: [Float], at time: TimeInterval) async
    /// Flush anything pending and stop. Safe to call twice.
    func finish() async
}

// MARK: - Audio capture

/// Where a stream of meeting audio comes from.
///
/// Implementations deliver 16 kHz mono Float32 on an unspecified thread — often
/// a real-time audio thread, so callbacks must not allocate heavily, block, or
/// touch the main actor synchronously.
protocol MeetingAudioSource: AnyObject {
    /// Human-readable, for logs and the UI.
    var name: String { get }
    /// Which side of the conversation this source represents.
    var speaker: Speaker { get }

    /// - Parameter onBuffer: samples, and seconds since `start` was called.
    func start(onBuffer: @escaping @Sendable ([Float], TimeInterval) -> Void) throws
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

// MARK: - Shared constants

enum NotesFM {
    /// 16 kHz mono, matching what the speech engine wants and what dictation
    /// already produces, so nothing has to resample twice.
    static let sampleRate: Double = 16_000

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
}
