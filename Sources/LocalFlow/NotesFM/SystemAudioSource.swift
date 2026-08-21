import AVFoundation
import CoreAudio

/// Everything coming out of the speakers, captured with a Core Audio process tap.
///
/// This is what makes meeting transcription possible: the other participants'
/// voices arrive through the output device, not the microphone. Capturing them
/// separately from the mic is also where speaker attribution comes from — mic is
/// you, this is them — with no speaker-identification model involved.
///
/// Why a Core Audio tap rather than ScreenCaptureKit: the tap uses a different
/// TCC service (`kTCCServiceAudioCapture`) whose prompt says "would like access
/// to record your system audio". ScreenCaptureKit would ask to "capture the
/// contents of the system display" and would additionally re-prompt monthly.
/// Asking a dictation app's users for screen recording is not a reasonable
/// trade when an audio-only permission exists.
///
/// There is no API to query this permission, so it cannot be pre-flighted. The
/// only way to know is to start and see whether real samples arrive, which is
/// why `hasHeardAudio` exists for the UI to nag about.
final class SystemAudioSource: MeetingAudioSource, @unchecked Sendable {
    let name = "System audio"
    let speaker: Speaker = .them

    /// False until at least one non-silent buffer has been seen. Used to tell
    /// "permission was never granted" apart from "nobody is talking yet".
    private(set) var hasHeardAudio = false

    private let control = DispatchQueue(label: "com.localflow.notesfm.systemtap.control")
    private let io = DispatchQueue(label: "com.localflow.notesfm.systemtap.io", qos: .userInitiated)
    private let lock = NSLock()

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapUUID: UUID?
    private var monoFormat: AVAudioFormat?
    private var scratch: AVAudioPCMBuffer?
    private var handler: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var running = false
    private var lastAudibleAt = Date()
    private var rebuilds = 0

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    // MARK: - Lifecycle

    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        lock.lock()
        handler = onBuffer
        running = true
        lastAudibleAt = Date()
        lock.unlock()

        do {
            try buildGraph()
        } catch {
            lock.lock(); running = false; lock.unlock()
            throw error
        }
        installOutputDeviceListener()
        Log.write("NotesFM: system audio tap started")
    }

    func stop() {
        lock.lock()
        let wasRunning = running
        running = false
        handler = nil
        lock.unlock()
        guard wasRunning else { return }

        removeOutputDeviceListener()
        control.sync { self.tearDownGraph() }
        Log.write("NotesFM: system audio tap stopped\(rebuilds > 0 ? " (\(rebuilds) rebuild(s))" : "")")
    }

    deinit { tearDownGraph() }

    // MARK: - Graph

    private func buildGraph() throws {
        // A global tap, excluding ourselves so the app's own ping sounds are not
        // transcribed as if someone said them. Per-process taps were rejected:
        // they are reported to return silence for some conferencing apps.
        let excluded = Self.ownProcessObject().map { [$0] } ?? []
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.name = "LocalFlow NotesFM"
        let uuid = UUID()
        description.uuid = uuid
        description.isPrivate = true          // invisible to other processes
        description.muteBehavior = .unmuted   // the user must still hear their call
        // Deliberately NOT touching `isExclusive`. The global initialiser sets it
        // true, meaning "everything except the listed processes". Setting it false
        // inverts the meaning to "only the listed processes" and yields silence.

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap != AudioObjectID(kAudioObjectUnknown) else {
            throw MeetingAudioError.permissionDenied(
                "System Audio Recording (Core Audio returned \(status))")
        }

        var asbd = try Self.tapFormat(tap)
        guard let tapAudioFormat = AVAudioFormat(streamDescription: &asbd) else {
            AudioHardwareDestroyProcessTap(tap)
            throw MeetingAudioError.failed("tap reported an unusable audio format")
        }

        // The tap follows the output device, which is not always 48 kHz — a rate
        // of 24 kHz has been observed in the wild. Never hardcode it.
        guard let mono = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: tapAudioFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            AudioHardwareDestroyProcessTap(tap)
            throw MeetingAudioError.failed("could not build a mono format")
        }

        let outputUID = try Self.defaultOutputDeviceUID()

        // The aggregate must contain the real output device as well as the tap;
        // a tap on its own is reported to deliver nothing. Drift compensation is
        // on because an aggregate forces a common rate on its members, which has
        // historically caused audible clicks on the real output otherwise.
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "LocalFlow NotesFM Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: uuid.uuidString
            ]]
        ]

        var aggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate)
        guard status == noErr, aggregate != AudioObjectID(kAudioObjectUnknown) else {
            AudioHardwareDestroyProcessTap(tap)
            throw MeetingAudioError.failed("could not create the tap device (\(status))")
        }

        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, io) {
            [weak self] _, input, _, _, _ in
            self?.receive(input)
        }
        guard status == noErr, let proc else {
            AudioHardwareDestroyAggregateDevice(aggregate)
            AudioHardwareDestroyProcessTap(tap)
            throw MeetingAudioError.failed("could not attach to the tap device (\(status))")
        }

        status = AudioDeviceStart(aggregate, proc)
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(aggregate, proc)
            AudioHardwareDestroyAggregateDevice(aggregate)
            AudioHardwareDestroyProcessTap(tap)
            throw MeetingAudioError.failed("could not start the tap device (\(status))")
        }

        lock.lock()
        tapID = tap
        aggregateID = aggregate
        ioProcID = proc
        tapUUID = uuid
        monoFormat = mono
        scratch = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 16_384)
        lock.unlock()

        Log.write("NotesFM: system audio at \(Int(tapAudioFormat.sampleRate)) Hz, \(tapAudioFormat.channelCount) ch")
    }

    /// Order matters: stop, detach, then destroy the aggregate, then the tap.
    /// The dispatch queue is retained until the IOProc is destroyed.
    private func tearDownGraph() {
        lock.lock()
        let aggregate = aggregateID
        let proc = ioProcID
        let tap = tapID
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        ioProcID = nil
        tapID = AudioObjectID(kAudioObjectUnknown)
        monoFormat = nil
        scratch = nil
        tapUUID = nil
        lock.unlock()

        if aggregate != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceStop(aggregate, proc)
            if let proc { AudioDeviceDestroyIOProcID(aggregate, proc) }
            AudioHardwareDestroyAggregateDevice(aggregate)
        }
        if tap != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tap)
        }
    }

    // MARK: - The audio callback
    //
    // The HAL dispatches this block synchronously, so its thread is blocked
    // while we run: downmix into a preallocated buffer and hand off, nothing
    // more. The scratch buffer exists so the steady state does not allocate.

    private func receive(_ input: UnsafePointer<AudioBufferList>) {
        lock.lock()
        guard running, let format = monoFormat, let out = scratch, let handler else {
            lock.unlock()
            return
        }
        lock.unlock()

        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, first.mDataByteSize > 0 else { return }

        let channels = max(1, Int(first.mNumberChannels))
        let frames = Int(first.mDataByteSize) / 4 / channels
        guard frames > 0, frames <= Int(out.frameCapacity), let destination = out.floatChannelData?[0] else { return }

        if buffers.count > 1 {
            // Non-interleaved: one buffer per channel. Average them to mono.
            for frame in 0..<frames { destination[frame] = 0 }
            var contributing = 0
            for buffer in buffers {
                guard let raw = buffer.mData, Int(buffer.mDataByteSize) / 4 >= frames else { continue }
                let samples = raw.assumingMemoryBound(to: Float.self)
                for frame in 0..<frames { destination[frame] += samples[frame] }
                contributing += 1
            }
            if contributing > 1 {
                let scale = 1 / Float(contributing)
                for frame in 0..<frames { destination[frame] *= scale }
            }
        } else if let raw = first.mData {
            // One buffer, possibly interleaved stereo.
            let samples = raw.assumingMemoryBound(to: Float.self)
            if channels == 1 {
                destination.update(from: samples, count: frames)
            } else {
                let scale = 1 / Float(channels)
                for frame in 0..<frames {
                    var sum: Float = 0
                    for channel in 0..<channels { sum += samples[frame * channels + channel] }
                    destination[frame] = sum * scale
                }
            }
        } else {
            return
        }

        out.frameLength = AVAudioFrameCount(frames)

        var peak: Float = 0
        for frame in 0..<frames { peak = max(peak, abs(destination[frame])) }
        noteLevel(peak)

        // Handing over the scratch buffer is safe because the transcriber
        // converts and enqueues synchronously before returning; nothing retains
        // it past this call.
        _ = format
        handler(out)
    }

    /// Watches for the documented defect where a tap keeps firing with perfectly
    /// formed but all-zero buffers after long uptime. Genuine silence is
    /// indistinguishable from it, so the only signal is duration, and the only
    /// recovery Apple's own forum thread reports is a full rebuild.
    private func noteLevel(_ peak: Float) {
        lock.lock()
        if peak > 0.0001 {
            lastAudibleAt = Date()
            if !hasHeardAudio {
                hasHeardAudio = true
                lock.unlock()
                Log.write("NotesFM: system audio confirmed — permission is granted")
                return
            }
            lock.unlock()
            return
        }
        let silentFor = Date().timeIntervalSince(lastAudibleAt)
        let heard = hasHeardAudio
        let attempts = rebuilds
        lock.unlock()

        guard heard, silentFor > 120, attempts < 3 else { return }
        lock.lock(); rebuilds += 1; lastAudibleAt = Date(); lock.unlock()
        Log.write("NotesFM: system audio silent for \(Int(silentFor))s after being live — rebuilding the tap")
        control.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.tearDownGraph()
            try? self.buildGraph()
        }
    }

    // MARK: - Output device changes
    //
    // Plugging in AirPods leaves the aggregate stale and silently delivering
    // nothing, so the whole graph has to be rebuilt rather than patched.

    private func installOutputDeviceListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            // Rebuild on the control queue, never on the notification queue: it
            // would mean destroying the aggregate from inside its own callback.
            self.control.async {
                guard self.isRunning else { return }
                Log.write("NotesFM: output device changed — rebuilding the system audio tap")
                self.tearDownGraph()
                do {
                    try self.buildGraph()
                } catch {
                    Log.write("NotesFM: rebuild failed: \(error.localizedDescription)")
                }
            }
        }
        deviceListener = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, control, block)
    }

    private func removeOutputDeviceListener() {
        guard let deviceListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, control, deviceListener)
        self.deviceListener = nil
    }

    // MARK: - Core Audio property helpers

    private static func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd)
        guard status == noErr else {
            throw MeetingAudioError.failed("could not read the tap's audio format (\(status))")
        }
        return asbd
    }

    private static func defaultOutputDeviceUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != AudioObjectID(kAudioObjectUnknown) else {
            throw MeetingAudioError.unavailable("no default output device")
        }

        var uid = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &uidSize, pointer)
        }
        guard status == noErr else {
            throw MeetingAudioError.failed("could not read the output device UID (\(status))")
        }
        return uid as String
    }

    /// Our own audio process object, so the global tap can exclude it.
    private static func ownProcessObject() -> AudioObjectID? {
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = withUnsafeMutablePointer(to: &pid) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<pid_t>.size), pointer, &size, &object)
        }
        guard status == noErr, object != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return object
    }
}
