import AVFoundation
import CoreAudio

/// Captures microphone audio into 16 kHz mono float samples, which is the
/// format every candidate speech engine expects.
///
/// The audio graph and the sample-rate converter are built once at launch
/// (`prewarm`), so `start()` only has to install a tap and spin up the engine.
/// That keeps the microphone (and the orange macOS indicator) off until
/// dictation actually begins, while still starting fast enough that the first
/// syllable is not clipped.
final class AudioRecorder: @unchecked Sendable {
    enum RecorderError: Error, LocalizedError {
        case microphoneDenied
        case converterUnavailable

        var errorDescription: String? {
            switch self {
            case .microphoneDenied: "Microphone permission not granted"
            case .converterUnavailable: "Could not build an audio converter"
            }
        }
    }

    static let sampleRate: Double = 16_000

    /// Hard cap so a stuck hotkey cannot grow the buffer without bound.
    private static let maximumDuration: Double = 300

    private let queue = DispatchQueue(label: "com.localflow.audio")
    private let engine = AVAudioEngine()
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioRecorder.sampleRate,
        channels: 1,
        interleaved: false
    )!

    private var converter: AVAudioConverter?
    private var cachedInputFormat: AVAudioFormat?
    private var samples: [Float] = []
    private var isRecording = false
    private var tapInstalled = false

    /// Rolling history of normalised loudness, newest last. The flow bar reads
    /// this to draw a real travelling waveform rather than one pulsing value.
    ///
    /// Written from the audio render thread and read from the main thread, so it
    /// is guarded by a lock rather than the recorder's serial queue — the
    /// critical section is a single array write and must not wait on audio work.
    private let historyLock = NSLock()
    private static let historyCapacity = 128
    private var history = [Float](repeating: 0, count: AudioRecorder.historyCapacity)
    private var historyIndex = 0

    /// Anything quieter than this is treated as silence, so the waveform sits
    /// still when you are not speaking instead of twitching on room noise.
    private static let noiseFloor: Float = 0.004
    /// RMS that maps to a full-height bar.
    private static let fullScale: Float = 0.18

    var isActive: Bool { queue.sync { isRecording } }

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// Resolve the hardware format and build the converter ahead of time.
    /// Called once at launch on a background queue.
    func prewarm() {
        queue.sync {
            let started = ContinuousClock.now
            let format = engine.inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else {
                Log.write("Audio prewarm skipped — no input device yet")
                return
            }
            cachedInputFormat = format
            converter = AVAudioConverter(from: format, to: targetFormat)
            engine.prepare()
            samples.reserveCapacity(Int(AudioRecorder.sampleRate * 30))
            let ms = started.duration(to: ContinuousClock.now) / .milliseconds(1)
            Log.write(String(
                format: "Audio prewarmed in %.0f ms (input %.0f Hz, %d ch)",
                ms, format.sampleRate, format.channelCount
            ))
        }
    }

    func start() throws {
        try queue.sync {
            guard !isRecording else { return }
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                throw RecorderError.microphoneDenied
            }

            let started = ContinuousClock.now
            let input = engine.inputNode
            applySelectedDevice(to: input)
            let inputFormat = input.outputFormat(forBus: 0)

            // Rebuild the converter only if the hardware format changed
            // (device switch, sample-rate change).
            if converter == nil || cachedInputFormat?.sampleRate != inputFormat.sampleRate
                || cachedInputFormat?.channelCount != inputFormat.channelCount {
                guard let fresh = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                    throw RecorderError.converterUnavailable
                }
                converter = fresh
                cachedInputFormat = inputFormat
            } else {
                converter?.reset()
            }

            samples.removeAll(keepingCapacity: true)
            resetHistory()

            if !tapInstalled {
                input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) {
                    [weak self] buffer, _ in
                    self?.append(buffer: buffer)
                }
                tapInstalled = true
            }

            if !engine.isRunning {
                try engine.start()
            }
            isRecording = true
            let ms = started.duration(to: ContinuousClock.now) / .milliseconds(1)
            Log.write(String(format: "Capture started in %.0f ms", ms))
        }
    }

    /// Stops capture and returns the recorded samples at 16 kHz mono.
    /// Waits briefly after key-up so the last hardware buffers can land.
    @discardableResult
    func stop() -> [Float] {
        let shouldDrain = queue.sync { isRecording }
        guard shouldDrain else { return [] }
        Thread.sleep(forTimeInterval: 0.12)

        return queue.sync {
            guard isRecording else { return [] }
            isRecording = false
            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            engine.stop()
            resetHistory()

            let captured = samples
            samples.removeAll(keepingCapacity: true)
            let seconds = Double(captured.count) / AudioRecorder.sampleRate
            Log.write(String(format: "Capture stopped (%.2f s)", seconds))
            return captured
        }
    }

    /// Throw away whatever has been captured and shut the microphone off.
    func cancel() {
        _ = stop()
    }

    private func append(buffer: AVAudioPCMBuffer) {
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: capacity
        ) else { return }

        // The input block is invoked synchronously by the converter, but it is
        // typed as @Sendable, so the pending buffer is held in a reference box.
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

        if let error {
            Log.write("Audio conversion error: \(error.localizedDescription)")
            return
        }

        guard output.frameLength > 0, let channel = output.floatChannelData?[0] else { return }
        let count = Int(output.frameLength)
        // Copy out of the converter buffer before leaving the audio thread; the
        // buffer is reused once this callback returns.
        let chunk = Array(UnsafeBufferPointer(start: channel, count: count))

        // RMS, not peak: peak is dominated by transients and makes every bar
        // look the same height. RMS tracks perceived loudness, which is what
        // makes the waveform look like the speech that produced it.
        var sumOfSquares: Float = 0
        for value in chunk { sumOfSquares += value * value }
        let rms = (sumOfSquares / Float(count)).squareRoot()

        // Gate, then compress. Speech RMS lives around 0.02-0.15, so a linear
        // mapping would keep every bar in the bottom fifth of the pill.
        let gated = max(0, rms - AudioRecorder.noiseFloor)
        let normalised = min(1, pow(gated / AudioRecorder.fullScale, 0.6))
        push(level: normalised)

        queue.async { [weak self] in
            guard let self, self.isRecording else { return }
            let limit = Int(AudioRecorder.sampleRate * AudioRecorder.maximumDuration)
            guard self.samples.count < limit else { return }
            self.samples.append(contentsOf: chunk)
        }
    }

    // MARK: - Level history

    private func push(level: Float) {
        historyLock.lock()
        history[historyIndex] = level
        historyIndex = (historyIndex + 1) % history.count
        historyLock.unlock()
    }

    private func resetHistory() {
        historyLock.lock()
        for index in history.indices { history[index] = 0 }
        historyIndex = 0
        historyLock.unlock()
    }

    /// The last `count` loudness samples, oldest first, newest last.
    func recentLevels(_ count: Int) -> [Float] {
        historyLock.lock()
        defer { historyLock.unlock() }
        let capacity = history.count
        var out = [Float](repeating: 0, count: count)
        for offset in 0..<count {
            let stepsBack = count - offset
            let index = ((historyIndex - stepsBack) % capacity + capacity) % capacity
            out[offset] = history[index]
        }
        return out
    }

    /// Point the engine's input node at the microphone chosen in Settings.
    /// Must happen before `engine.start()`. Falls back to the system default
    /// input whenever the saved device is missing or the call fails.
    private func applySelectedDevice(to input: AVAudioInputNode) {
        let uid = Settings.shared.microphoneUID
        guard !uid.isEmpty else { return }
        guard var deviceID = AudioDevices.coreAudioID(forUID: uid) else {
            Log.write("Selected microphone is not connected — using system default")
            return
        }
        guard let unit = input.audioUnit else { return }
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            Log.write("Could not select microphone (status \(status)) — using system default")
        }
    }

}
