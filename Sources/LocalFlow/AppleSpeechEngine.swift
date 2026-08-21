import AVFoundation
import Speech

/// Apple SpeechAnalyzer / SpeechTranscriber backend.
///
/// English and German each have their own locale model. There is no mixed-language
/// session, so we keep one locale hot, then retry the other only if the first
/// pass comes back empty or very short. That avoids running two engines on every
/// utterance and keeps idle memory low.
actor AppleSpeechEngine: TranscriptionEngine {
    let displayName = "Apple SpeechTranscriber"

    private let english = Locale(identifier: "en-US")
    private let german = Locale(identifier: "de-DE")
    private var preferredLocale = Locale(identifier: "en-US")
    private var isPrepared = false

    func prepare() async throws {
        try await installIfNeeded(english)
        try await installIfNeeded(german)
        try await warm(locale: preferredLocale)
        isPrepared = true
        Log.write("ASR ready (\(displayName), en-US + de-DE)")
    }

    func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
        if !isPrepared {
            try await prepare()
        }

        guard samples.count > Int(sampleRate * 0.25) else {
            return ""
        }

        let first = try await transcribe(samples: samples, sampleRate: sampleRate, locale: preferredLocale)
        if looksUsable(first, sampleCount: samples.count, sampleRate: sampleRate) {
            return first
        }

        let other = preferredLocale.identifier == english.identifier ? german : english
        Log.write("ASR retrying with \(other.identifier)")
        let second = try await transcribe(samples: samples, sampleRate: sampleRate, locale: other)
        if second.count >= first.count, !second.isEmpty {
            preferredLocale = other
            return second
        }
        return first
    }

    private func transcribe(
        samples: [Float],
        sampleRate: Double,
        locale: Locale
    ) async throws -> String {
        let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? locale
        let transcriber = SpeechTranscriber(locale: resolved, preset: .transcription)
        try await installIfNeeded(resolved)

        let options = SpeechAnalyzer.Options(
            priority: .userInitiated,
            modelRetention: .processLifetime
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: options)

        guard let sourceBuffer = Self.pcmBuffer(samples: samples, sampleRate: sampleRate) else {
            return ""
        }

        let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
            ?? sourceBuffer.format
        try await analyzer.prepareToAnalyze(in: targetFormat)

        let converted = try Self.convert(sourceBuffer, to: targetFormat)

        let (inputSequence, inputBuilder) = AsyncStream.makeStream(of: AnalyzerInput.self)
        inputBuilder.yield(AnalyzerInput(buffer: converted))
        inputBuilder.finish()

        let resultsTask = Task { () throws -> [String] in
            var parts: [String] = []
            for try await result in transcriber.results where result.isFinal {
                parts.append(String(result.text.characters))
            }
            return parts
        }

        let lastSampleTime = try await analyzer.analyzeSequence(inputSequence)
        if let lastSampleTime {
            try await analyzer.finalizeAndFinish(through: lastSampleTime)
        } else {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        let parts = try await resultsTask.value

        let text = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        Log.write("ASR \(resolved.identifier): \(text.isEmpty ? "(empty)" : text)")
        return text
    }

    private func installIfNeeded(_ locale: Locale) async throws {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            Log.write("Downloading speech asset for \(locale.identifier) (one-time, system-owned)")
            try await request.downloadAndInstall()
        }
    }

    private func warm(locale: Locale) async throws {
        let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? locale
        let transcriber = SpeechTranscriber(locale: resolved, preset: .transcription)
        let options = SpeechAnalyzer.Options(
            priority: .userInitiated,
            modelRetention: .processLifetime
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: options)
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)
    }

    private func looksUsable(_ text: String, sampleCount: Int, sampleRate: Double) -> Bool {
        let words = text.split { $0.isWhitespace || $0.isNewline }
        if words.count >= 3 { return true }
        if !text.isEmpty, Double(sampleCount) / sampleRate < 2.0 { return true }
        return false
    }

    private static func pcmBuffer(samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return nil }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress, let dest = buffer.floatChannelData?[0] else { return }
            dest.update(from: base, count: samples.count)
        }
        return buffer
    }

    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        to format: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        if buffer.format == format { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            return buffer
        }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return buffer
        }

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
        if let error { throw error }
        return output
    }
}
