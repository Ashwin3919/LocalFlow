import AVFoundation
import CoreMedia
import Speech

/// One long-lived streaming transcription session, for one audio stream.
///
/// Two of these run during a meeting — one fed by the microphone, one by system
/// audio — which is where speaker attribution comes from. Apple documents that
/// several transcribers can share one backing engine when they are configured
/// alike, so both are built with identical locale and options on purpose.
///
/// Not an actor. `append` is called from the audio thread on every buffer, and
/// an actor hop there would mean a `Task` allocation per buffer for no benefit:
/// conversion is a few hundred microseconds and `AsyncStream.yield` is already
/// thread-safe. The handful of mutable fields are guarded by a lock instead.
final class MeetingTranscriber: StreamingTranscriber, @unchecked Sendable {
    let segments: AsyncStream<TranscribedSegment>

    private let speaker: Speaker
    private let locale: Locale
    private let emit: AsyncStream<TranscribedSegment>.Continuation

    private let lock = NSLock()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var resultsTask: Task<Void, Never>?
    private var finished = false
    private var dropped = 0

    init(speaker: Speaker, locale: Locale) {
        self.speaker = speaker
        self.locale = locale
        (segments, emit) = AsyncStream.makeStream(of: TranscribedSegment.self)
    }

    // MARK: - Lifecycle

    func start() async throws {
        let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? locale

        // Not a preset. `.transcription` reports neither partial results nor time
        // ranges, and `.timeIndexedProgressiveTranscription` would add
        // `.fastResults`, which Apple documents as trading accuracy for latency.
        // A meeting record wants the accurate version, so the options are spelled
        // out: live partials for the capture window, timings for the transcript.
        let transcriber = SpeechTranscriber(
            locale: resolved,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            Log.write("NotesFM: downloading speech asset for \(resolved.identifier)")
            try await request.downloadAndInstall()
        }

        // `.lingering` rather than `.processLifetime`: the two analyzers start and
        // stop together and are compatible, so this gets them model sharing and
        // avoids a reload between back-to-back meetings, without pinning models
        // for the life of the process.
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering)
        )

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw MeetingAudioError.unavailable("no compatible audio format for \(resolved.identifier)")
        }
        try await analyzer.prepareToAnalyze(in: format)

        // Bounded on purpose. An unbounded stream grows without limit over a long
        // meeting if transcription ever falls behind real time; dropping the
        // oldest buffers instead trades a gap for a hard memory ceiling, and the
        // drop count is logged so a silent gap is never invisible.
        let (sequence, continuation) = AsyncStream.makeStream(
            of: AnalyzerInput.self,
            bufferingPolicy: .bufferingNewest(96)
        )

        // Consume results before starting, so nothing produced early is missed.
        let task = Task { [weak self] in
            guard let self else { return }
            await self.resultStream(transcriber)
        }

        install(transcriber: transcriber, analyzer: analyzer, format: format,
                input: continuation, task: task)

        try await analyzer.start(inputSequence: sequence)
        Log.write("NotesFM: \(speaker.label) stream started (\(resolved.identifier), \(Int(format.sampleRate)) Hz)")
    }

    private func resultStream(_ transcriber: SpeechTranscriber) async {
        do {
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                guard !text.isEmpty else { continue }
                emit.yield(TranscribedSegment(
                    text: text,
                    start: result.range.start.seconds,
                    end: result.range.end.seconds,
                    isFinal: result.isFinal,
                    speaker: speaker
                ))
            }
        } catch {
            Log.write("NotesFM: \(speaker.label) result stream ended: \(error.localizedDescription)")
        }
        emit.finish()
    }

    // MARK: - Feeding

    /// Called on the audio thread. Converts to the analyzer's exact format and
    /// enqueues. The analyzer does no conversion itself and rejects anything
    /// else, which is the documented cause of "works in batch, silent when
    /// streaming", so this is the one place that has to be right.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard !finished, let input, let format = analyzerFormat else {
            lock.unlock()
            return
        }
        if buffer.format != format, converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        let activeConverter = converter
        lock.unlock()

        let outgoing: AVAudioPCMBuffer
        if buffer.format == format {
            outgoing = buffer
        } else if let activeConverter, let converted = Self.convert(buffer, with: activeConverter, to: format) {
            outgoing = converted
        } else {
            return
        }

        if case .dropped = input.yield(AnalyzerInput(buffer: outgoing)) {
            let total = countDrop()
            // Only log on powers of two, so a sustained backlog does not itself
            // become the thing eating the CPU.
            if total & (total - 1) == 0 {
                Log.write("NotesFM: \(speaker.label) dropped \(total) buffer(s) — transcription behind real time")
            }
        }
    }

    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        let pending = PendingInput(buffer: buffer)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            guard let next = pending.take() else {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return next
        }
        if error != nil || output.frameLength == 0 { return nil }
        return output
    }

    // MARK: - Locked accessors
    //
    // `NSLock.lock()` is unavailable from an async context, so every piece of
    // shared state an async method needs is read or mutated through one of
    // these synchronous helpers instead.

    private func install(
        transcriber: SpeechTranscriber,
        analyzer: SpeechAnalyzer,
        format: AVAudioFormat,
        input: AsyncStream<AnalyzerInput>.Continuation,
        task: Task<Void, Never>
    ) {
        lock.lock()
        defer { lock.unlock() }
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.analyzerFormat = format
        self.input = input
        self.resultsTask = task
    }

    private func countDrop() -> Int {
        lock.lock()
        defer { lock.unlock() }
        dropped += 1
        return dropped
    }

    private func currentAnalyzer() -> (SpeechAnalyzer?, Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (analyzer, finished)
    }

    /// Marks the session finished and hands back what the caller must drain.
    /// Returns `nil` if another call already did this, which makes `finish()`
    /// safe to call twice.
    private func beginFinish() -> (SpeechAnalyzer?, AsyncStream<AnalyzerInput>.Continuation?, Task<Void, Never>?, Int)? {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return nil }
        finished = true
        return (analyzer, input, resultsTask, dropped)
    }

    private func releaseState() {
        lock.lock()
        defer { lock.unlock() }
        analyzer = nil
        transcriber = nil
        input = nil
        converter = nil
        resultsTask = nil
    }

    // MARK: - Draining

    /// Collapse the volatile window forward. Called on the flush heartbeat so
    /// unfinalised state cannot accumulate across a long meeting.
    func flush() async {
        let (target, done) = currentAnalyzer()
        guard !done, let target else { return }
        do {
            try await target.finalize(through: nil)
        } catch {
            Log.write("NotesFM: \(speaker.label) flush failed: \(error.localizedDescription)")
        }
    }

    func finish() async {
        guard let (target, continuation, task, lost) = beginFinish() else { return }

        continuation?.finish()
        do {
            try await target?.finalizeAndFinishThroughEndOfInput()
        } catch {
            Log.write("NotesFM: \(speaker.label) finish failed: \(error.localizedDescription)")
            await target?.cancelAndFinishNow()
        }
        _ = await task?.value
        releaseState()

        Log.write("NotesFM: \(speaker.label) stream finished\(lost > 0 ? " (\(lost) buffers dropped)" : "")")
    }
}
