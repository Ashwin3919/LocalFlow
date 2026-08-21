import AVFoundation

/// Writes 16 kHz mono samples to a WAV file. Used for verifying capture during
/// development; the transcription path consumes the samples directly.
enum WavWriter {
    static func write(samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioRecorder.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        let file = try AVAudioFile(forWriting: url, settings: settings)

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioRecorder.sampleRate,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(max(samples.count, 1))
        ) else { return }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { source in
                guard let base = source.baseAddress else { return }
                channel.update(from: base, count: samples.count)
            }
        }

        try file.write(from: buffer)
    }
}
