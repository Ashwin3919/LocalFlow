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
    /// Serialises graph work, so a burst of device changes cannot have two
    /// rebuilds tearing down and starting the same engine at once.
    private let control = DispatchQueue(label: "com.localflow.notesfm.mic.control")

    private var running = false
    private var handler: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var observer: NSObjectProtocol?
    private var rebuilds = 0

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    // MARK: - Lifecycle

    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw MeetingAudioError.permissionDenied("Microphone")
        }

        lock.lock()
        handler = onBuffer
        running = true
        lock.unlock()

        do {
            try control.sync { try buildGraph() }
        } catch {
            lock.lock()
            running = false
            handler = nil
            lock.unlock()
            throw error
        }

        observeConfigurationChanges()
    }

    func stop() {
        lock.lock()
        let wasRunning = running
        running = false
        handler = nil
        let token = observer
        observer = nil
        lock.unlock()
        guard wasRunning else { return }

        if let token { NotificationCenter.default.removeObserver(token) }
        control.sync { tearDownGraph() }
        Log.write("NotesFM: microphone stopped\(rebuilds > 0 ? " (\(rebuilds) rebuild(s))" : "")")
    }

    // MARK: - Graph

    /// Must run on `control`.
    private func buildGraph() throws {
        let input = engine.inputNode
        applySelectedDevice(to: input)

        // Read the format *after* pointing the node at the chosen device. The
        // format belongs to that device, and a headset does not run at the
        // built-in microphone's rate.
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MeetingAudioError.unavailable("no microphone input format")
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.deliver(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw MeetingAudioError.failed("microphone engine: \(error.localizedDescription)")
        }

        Log.write("NotesFM: microphone capturing at \(Int(format.sampleRate)) Hz, \(format.channelCount) ch")
    }

    /// Must run on `control`.
    private func tearDownGraph() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func deliver(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let sink = running ? handler : nil
        lock.unlock()
        sink?(buffer)
    }

    /// Point the engine's input node at the microphone chosen in Settings.
    ///
    /// Meetings honour the same setting dictation does. Not doing so was a real
    /// bug: someone who picks a headset for dictation reasonably expects the
    /// meeting to use it too, and instead got the system default with no hint
    /// that the two disagreed. Falls back to the default whenever the saved
    /// device is missing, which is what happens when it is simply unplugged.
    private func applySelectedDevice(to input: AVAudioInputNode) {
        let uid = Settings.shared.microphoneUID
        guard !uid.isEmpty else { return }
        guard var deviceID = AudioDevices.coreAudioID(forUID: uid) else {
            Log.write("NotesFM: selected microphone is not connected — using system default")
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
            Log.write("NotesFM: could not select microphone (status \(status)) — using system default")
        }
    }

    // MARK: - Surviving a device change

    /// Plugging in AirPods halfway through a meeting used to end the mic half of
    /// the transcript silently.
    ///
    /// Apple documents that when the input hardware's sample rate or channel
    /// count changes, the engine **stops itself** and posts this notification,
    /// and that the nodes keep their previous formats — so the app has to
    /// re-establish the connections. Reinstalling the tap is exactly that.
    ///
    /// The rebuild is pushed onto `control` rather than done here because the
    /// notification arrives on an internal queue, where the same documentation
    /// warns that tearing the engine down synchronously can deadlock.
    private func observeConfigurationChanges() {
        let token = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.control.async { self.rebuild() }
        }
        lock.lock()
        observer = token
        lock.unlock()
    }

    /// Must run on `control`.
    private func rebuild() {
        guard isRunning else { return }
        tearDownGraph()
        do {
            try buildGraph()
            rebuilds += 1
            Log.write("NotesFM: microphone graph rebuilt after an input device change")
        } catch {
            // Deliberately does not clear `running`: the meeting is still live and
            // the system-audio half may still be recording. The log and the next
            // device change are the recovery path.
            Log.write("NotesFM: microphone rebuild failed: \(error.localizedDescription)")
        }
    }
}
