import Foundation

/// Writes the one markdown file belonging to one recording session.
///
/// The whole design goal is durability: whatever has been said is on disk within
/// `NotesFM.flushInterval` seconds, and force-quitting the app — or losing power —
/// costs at most that. Everything else (merging lines, stamping the duration) is
/// secondary to that and gives way when the two conflict.
///
/// Locked with `NSLock` rather than written as an actor on purpose: `append` is
/// called from audio and transcription callbacks and `flush` from a timer, all
/// synchronous contexts that cannot `await`. The lock is held only around array
/// mutations, never around file I/O, so an audio callback is never waiting on the
/// disk. `@unchecked Sendable` is the consequence of that hand-written locking.
///
/// The file format itself lives in `MeetingMarkdown` (MeetingStore.swift).
final class MeetingWriter: @unchecked Sendable {
    /// Consecutive same-speaker text closer together than this becomes one line.
    ///
    /// A streaming recogniser finalises a clause at a time, so writing one line
    /// per callback produces a page of four-word lines that is unreadable. Eight
    /// seconds is long enough to hold a normal sentence-to-sentence pause together
    /// and short enough that a genuine hand-over to the other speaker — which
    /// changes the speaker anyway and so breaks the line regardless — is never
    /// swallowed. The gap is measured from the *end* of what has been merged so
    /// far, not from the start of the line, so a long uninterrupted monologue
    /// stays one paragraph, which is what it is.
    private static let mergeGap: TimeInterval = 8

    private let fileURL: URL
    private let started: Date

    /// Guards the buffered lines. Cheap and uncontended.
    private let lock = NSLock()
    /// Serialises file access, so two overlapping flushes cannot interleave their
    /// writes or race the frontmatter rewrite in `finish`.
    private let diskLock = NSLock()

    /// Rendered lines that are not on disk yet.
    private var pending: [String] = []
    /// The line still open for merging, if any.
    private var open: OpenLine?
    /// Latest timestamp seen, so a note can never be stamped earlier than the
    /// transcript line printed above it.
    private var latestTime: TimeInterval = 0
    private var isFinished = false

    private struct OpenLine {
        let speaker: Speaker
        /// Timestamp shown in the file: where the merged run began.
        let start: TimeInterval
        /// End of the most recent piece, for the merge-gap test.
        var last: TimeInterval
        var text: String
    }

    var url: URL { fileURL }

    init(root: URL, title: String, started: Date) throws {
        let clean = MeetingMarkdown.singleLine(title).trimmingCharacters(in: .whitespacesAndNewlines)
        let heading = clean.isEmpty ? "Untitled meeting" : clean
        self.started = started

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stem = MeetingMarkdown.uniqueStem(title: heading, started: started, in: root)
        self.fileURL = root.appendingPathComponent(stem).appendingPathExtension("md")

        // The file exists — with a duration of zero — from the first second of the
        // meeting. That way a crash before the first flush still leaves a note the
        // user can find, and an unwritable folder is reported to the caller now,
        // while it can still cancel the recording, instead of at the first flush.
        let header = MeetingMarkdown.frontmatter(title: heading, started: started, duration: 0, id: stem)
        try header.write(to: fileURL, atomically: true, encoding: .utf8)
        Log.write("MeetingWriter opened \(fileURL.lastPathComponent)")
    }

    // MARK: Appending

    func append(speaker: Speaker, at time: TimeInterval, text: String) {
        let cleaned = MeetingMarkdown.singleLine(text)
        guard !cleaned.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }
        // A transcription callback can land after the session was closed; drop it
        // rather than reopening a file whose duration is already stamped.
        guard !isFinished else { return }
        latestTime = max(latestTime, time)

        // Notes never merge: two things the user chose to write down are two
        // thoughts, even if they typed them ten seconds apart.
        if speaker != .note, var current = open, current.speaker == speaker, time - current.last <= Self.mergeGap {
            current.text += " " + cleaned
            current.last = max(current.last, time)
            open = current
            return
        }

        closeOpenLine()
        open = OpenLine(speaker: speaker, start: time, last: time, text: cleaned)
    }

    /// A note carries no timestamp of its own, so the caller passes the session's
    /// elapsed *recorded* time.
    ///
    /// Recorded, not wall clock: the transcript's timestamps come from the audio
    /// the analyzer has been given, so a pause freezes them, and a wall-clock note
    /// written after a long pause would be stamped far below words that were
    /// actually spoken later. The floor is belt and braces — a note can never be
    /// stamped above the line already printed before it.
    func appendNote(_ text: String, at elapsed: TimeInterval) {
        lock.lock()
        let floor = latestTime
        lock.unlock()
        append(speaker: .note, at: max(elapsed, floor), text: text)
    }

    /// A standalone line attributed to nobody, used for the pause marker.
    ///
    /// Rendered as italic prose rather than a speaker line so that nothing — not
    /// the reader, not the library's renderer — can mistake it for something a
    /// participant said.
    func appendMarker(_ text: String, at time: TimeInterval) {
        let cleaned = MeetingMarkdown.singleLine(text)
        guard !cleaned.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }
        latestTime = max(latestTime, time)
        closeOpenLine()
        pending.append("_— \(cleaned) —_")
    }

    // MARK: Flushing

    func flush() {
        lock.lock()
        if isFinished {
            lock.unlock()
            return
        }
        // The open line is closed and written too. That caps merging at the flush
        // boundary, so a sentence spanning one becomes two lines — an acceptable
        // price, because the alternative is holding words in memory that a force
        // quit would erase, and durability is the entire point of this class.
        closeOpenLine()
        let lines = pending
        pending = []
        lock.unlock()

        write(lines)
    }

    func finish(duration: TimeInterval) {
        lock.lock()
        if isFinished {
            lock.unlock()
            return
        }
        closeOpenLine()
        let lines = pending
        pending = []
        isFinished = true
        lock.unlock()

        write(lines)
        stamp(duration: duration)
        Log.write("MeetingWriter closed \(fileURL.lastPathComponent) after \(Int(duration))s")
    }

    // MARK: Internals

    /// Caller must hold `lock`.
    private func closeOpenLine() {
        guard let current = open else { return }
        pending.append(Self.render(speaker: current.speaker, at: current.start, text: current.text))
        open = nil
    }

    private static func render(speaker: Speaker, at time: TimeInterval, text: String) -> String {
        "**[\(NotesFM.timestamp(time))] \(speaker.label)** — \(text)"
    }

    /// Appends to the end of the file. Never rewrites it, so the cost of a flush
    /// is the same in the third hour of a meeting as in the first minute.
    private func write(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        guard let data = (lines.joined(separator: "\n") + "\n").data(using: .utf8) else { return }

        diskLock.lock()
        defer { diskLock.unlock() }
        do {
            // Opened per flush rather than kept open for the session: `finish`
            // replaces the file atomically to stamp the duration, and a long-lived
            // handle would afterwards be writing into the file that was replaced.
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Deliberately swallowed. A failed disk write must not tear down the
            // audio pipeline mid-meeting; the log is where this gets noticed.
            Log.write("MeetingWriter write failed: \(error.localizedDescription)")
        }
    }

    /// The one place the frontmatter is rewritten. The file is re-read first so
    /// that anything else which touched it during the meeting — including the user
    /// editing it in another app — survives having the duration stamped in.
    private func stamp(duration: TimeInterval) {
        diskLock.lock()
        defer { diskLock.unlock() }
        do {
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            var note = MeetingMarkdown.note(from: text, url: fileURL, folder: nil, fallbackDate: started)
            note.duration = duration
            try MeetingMarkdown.document(for: note).write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            Log.write("MeetingWriter could not stamp duration: \(error.localizedDescription)")
        }
    }
}
