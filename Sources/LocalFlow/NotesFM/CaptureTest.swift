import AVFoundation
import Foundation

/// Headless check that both capture paths actually deliver audio.
///
/// Run with `LocalFlow --notesfm-capture-test [seconds]`. It exists because the
/// System Audio Recording permission has **no API to query it** — the only way to
/// know whether it was granted is to start a tap and see whether real samples
/// arrive. This also makes the tap testable without sitting through a meeting.
@MainActor
enum NotesFMCaptureTest {
    static func run(seconds: Double) -> Never {
        print("NotesFM capture test — \(Int(seconds))s\n")

        let mic = MicMeetingSource()
        let system = SystemAudioSource()

        let counts = Counters()

        print("Microphone:")
        do {
            try mic.start { buffer in counts.record(.you, buffer) }
            print("  started")
        } catch {
            print("  FAILED — \(error.localizedDescription)")
        }

        print("System audio:")
        do {
            try system.start { buffer in counts.record(.them, buffer) }
            print("  started")
        } catch {
            print("  FAILED — \(error.localizedDescription)")
            print("""

                  This is expected until the permission is granted. macOS offers no
                  way to ask for it programmatically, so grant it by hand:
                    System Settings → Privacy & Security
                      → Screen & System Audio Recording
                      → System Audio Recording Only  →  enable LocalFlow
                  Then QUIT and relaunch LocalFlow. macOS does not apply this grant
                  to an already-running app.
                  """)
        }

        print("\nListening. Talk, and play something with sound…\n")

        Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated {
                mic.stop()
                system.stop()
                let report = counts.report()
                print(report.text)
                exit(report.ok ? 0 : 1)
            }
        }
        RunLoop.main.run()
        fatalError("unreachable")
    }

    /// The same check, run from inside the normally-launched app.
    ///
    /// This is the only way it can give a true answer: a process started from a
    /// shell has the terminal as its TCC-responsible process, so macOS denies it
    /// the microphone and silences the tap no matter what LocalFlow was granted.
    static func runInApp(seconds: Double = 10, completion: @escaping @MainActor (String) -> Void) {
        let mic = MicMeetingSource()
        let system = SystemAudioSource()
        let counts = Counters()
        var problems: [String] = []

        do {
            try mic.start { buffer in counts.record(.you, buffer) }
        } catch {
            problems.append("Microphone could not start: \(error.localizedDescription)")
        }
        do {
            try system.start { buffer in counts.record(.them, buffer) }
        } catch {
            problems.append("System audio could not start: \(error.localizedDescription)")
        }

        Log.write("NotesFM: capture test running for \(Int(seconds))s")
        Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated {
                mic.stop()
                system.stop()
                let report = counts.report()
                let text = (problems + [report.text]).joined(separator: "\n\n")
                Log.write("NotesFM capture test:\n\(text)")
                completion(text)
            }
        }
    }

    /// Buffers arrive on audio threads, so the tallies are lock-guarded.
    private final class Counters: @unchecked Sendable {
        private let lock = NSLock()
        private var buffers: [Speaker: Int] = [:]
        private var frames: [Speaker: Int] = [:]
        private var peak: [Speaker: Float] = [:]
        private var rate: [Speaker: Double] = [:]

        func record(_ speaker: Speaker, _ buffer: AVAudioPCMBuffer) {
            var loudest: Float = 0
            if let channel = buffer.floatChannelData?[0] {
                for index in 0..<Int(buffer.frameLength) {
                    loudest = max(loudest, abs(channel[index]))
                }
            }
            lock.lock()
            buffers[speaker, default: 0] += 1
            frames[speaker, default: 0] += Int(buffer.frameLength)
            peak[speaker] = max(peak[speaker] ?? 0, loudest)
            rate[speaker] = buffer.format.sampleRate
            lock.unlock()
        }

        func report() -> (text: String, ok: Bool) {
            lock.lock()
            defer { lock.unlock() }
            var lines = ["Results:"]
            var micHeard = false

            for speaker in [Speaker.you, Speaker.them] {
                let label = speaker == .you ? "Microphone " : "System audio"
                let count = buffers[speaker] ?? 0
                let loudest = peak[speaker] ?? 0
                let hz = rate[speaker] ?? 0
                let secondsOfAudio = hz > 0 ? Double(frames[speaker] ?? 0) / hz : 0

                if count == 0 {
                    lines.append("  \(label): no buffers at all — not capturing")
                } else if loudest < 0.0005 {
                    lines.append(String(
                        format: "  %@: %d buffers, %.1fs at %.0f Hz, but SILENT (peak %.5f)",
                        label, count, secondsOfAudio, hz, loudest))
                    lines.append("      buffers arriving but all zero — that is the permission being denied")
                } else {
                    lines.append(String(
                        format: "  %@: %d buffers, %.1fs at %.0f Hz, peak %.3f  ✓ real audio",
                        label, count, secondsOfAudio, hz, loudest))
                    if speaker == .you { micHeard = true }
                }
            }
            return (lines.joined(separator: "\n"), micHeard)
        }
    }
}
