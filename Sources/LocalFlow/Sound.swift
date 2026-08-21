import AppKit

/// Short confirmation pings. Preloaded so the first one is not delayed by
/// disk I/O in the middle of a dictation.
enum Sound {
    private static let start = NSSound(named: "Tink")
    private static let done = NSSound(named: "Pop")
    private static let abort = NSSound(named: "Boop") ?? NSSound(named: "Funk")

    static func preload() {
        _ = start
        _ = done
        _ = abort
    }

    static func recordingStarted() { play(start) }
    static func pasted() { play(done) }
    static func cancelled() { play(abort) }

    private static func play(_ sound: NSSound?) {
        guard Settings.shared.soundsEnabled, let sound else { return }
        DispatchQueue.main.async {
            if sound.isPlaying { sound.stop() }
            sound.volume = 0.35
            sound.play()
        }
    }
}
