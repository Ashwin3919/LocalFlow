import AVFoundation

/// Hands a single buffer to `AVAudioConverter`, then reports that the input is
/// exhausted so the converter does not block waiting for more.
final class PendingInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
