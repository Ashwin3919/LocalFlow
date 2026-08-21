import AVFoundation

/// The microphone, as a meeting audio source.
///
/// A separate `AVAudioEngine` from the one `AudioRecorder` uses for dictation.
/// Sharing a single engine would mean one feature could stop the other's tap by
/// stopping the engine, and the two have opposite lifetimes: dictation's engine
/// spins up for a second at a time, this one runs for the length of a meeting.
///
/// Buffers are handed on in the hardware's own format. Resampling here would be
/// wasted work — `MeetingTranscriber` has to convert to the analyzer's exact
/// format anyway, and converting twice loses quality for nothing.
final class MicMeetingSource: MeetingAudioSource, @unchecked Sendable {
    let name = "Microphone"
    let speaker: Speaker = .you

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var running = false

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw MeetingAudioError.permissionDenied("Microphone")
        }

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MeetingAudioError.unavailable("no microphone input format")
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            onBuffer(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw MeetingAudioError.failed("microphone engine: \(error.localizedDescription)")
        }

        lock.lock(); running = true; lock.unlock()
        Log.write("NotesFM: microphone capturing at \(Int(format.sampleRate)) Hz, \(format.channelCount) ch")
    }

    func stop() {
        lock.lock()
        let wasRunning = running
        running = false
        lock.unlock()
        guard wasRunning else { return }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        Log.write("NotesFM: microphone stopped")
    }
}
