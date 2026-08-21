import Foundation

protocol TranscriptionEngine: Sendable {
    var displayName: String { get }
    func prepare() async throws
    func transcribe(samples: [Float], sampleRate: Double) async throws -> String
}
