import Foundation

/// Optional post-processing of a raw transcript through a local Ollama model.
///
/// This step is strictly best-effort. Any failure — Ollama not installed, not
/// running, model not pulled, slow response, garbage output — returns the raw
/// transcript unchanged. Losing words is worse than leaving in a filler word.
enum Cleanup {
    static let endpoint = URL(string: "http://localhost:11434/api/generate")!
    static let timeout: TimeInterval = 3.0

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout + 1
        config.waitsForConnectivity = false
        config.allowsCellularAccess = false
        config.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: config)
    }()

    /// Returns cleaned text, or the input unchanged if anything goes wrong.
    static func polish(_ raw: String) async -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Settings.shared.cleanupEnabled, !trimmed.isEmpty else { return raw }

        let started = ContinuousClock.now
        do {
            let cleaned = try await request(trimmed)
            let ms = started.duration(to: ContinuousClock.now) / .milliseconds(1)
            guard isPlausible(cleaned, original: trimmed) else {
                Log.write(String(format: "Cleanup rejected implausible output (%.0f ms) — using raw", ms))
                return raw
            }
            Log.write(String(format: "Cleanup ok (%.0f ms)", ms))
            return cleaned
        } catch {
            let ms = started.duration(to: ContinuousClock.now) / .milliseconds(1)
            Log.write(String(
                format: "Cleanup unavailable (%.0f ms): %@ — pasting raw transcript",
                ms, error.localizedDescription
            ))
            return raw
        }
    }

    /// Ask Ollama to load the model and hold it resident, so the first real
    /// dictation does not pay the load cost. Silent no-op when Ollama is absent.
    static func warm() async {
        guard Settings.shared.cleanupEnabled else { return }
        let body: [String: Any] = [
            "model": Settings.shared.cleanupModel,
            "prompt": "",
            "stream": false,
            "keep_alive": -1
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        // Model load can take longer than a dictation timeout; allow more here.
        let warmSession = URLSession(configuration: {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 120
            return config
        }())
        do {
            _ = try await warmSession.data(for: request)
            Log.write("Ollama model \(Settings.shared.cleanupModel) warmed and pinned")
        } catch {
            Log.write("Ollama warm-up failed: \(error.localizedDescription)")
        }
    }

    static func isReachable() async -> Bool {
        var request = URLRequest(url: URL(string: "http://localhost:11434/api/tags")!)
        request.timeoutInterval = 1.0
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Private

    private struct Response: Decodable {
        let response: String
    }

    private static func request(_ transcript: String) async throws -> String {
        var instructions = Settings.shared.cleanupPrompt
        let terms = Settings.shared.dictionaryTerms
        if !terms.isEmpty {
            instructions += "\n\nSpell these terms exactly as written when they occur: "
                + terms.joined(separator: ", ") + "."
        }

        let body: [String: Any] = [
            "model": Settings.shared.cleanupModel,
            "system": instructions,
            "prompt": "Transcript:\n\(transcript)\n\nCleaned text:",
            "stream": false,
            "think": false,
            "keep_alive": -1,
            "options": [
                "temperature": 0.2,
                "num_predict": 800
            ]
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return strip(decoded.response)
    }

    /// Reasoning models leak `<think>` blocks even with `think: false` on some
    /// builds, and small models like to wrap answers in quotes.
    private static func strip(_ text: String) -> String {
        var out = text
        while let start = out.range(of: "<think>"), let end = out.range(of: "</think>") {
            guard start.lowerBound < end.lowerBound else { break }
            out.removeSubrange(start.lowerBound..<end.upperBound)
        }
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.count > 1, out.hasPrefix("\""), out.hasSuffix("\"") {
            out = String(out.dropFirst().dropLast())
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Guard against the model ignoring instructions and answering the
    /// transcript instead of cleaning it, or dropping half the content.
    private static func isPlausible(_ cleaned: String, original: String) -> Bool {
        guard !cleaned.isEmpty else { return false }
        let cleanedWords = cleaned.split(whereSeparator: \.isWhitespace).count
        let originalWords = original.split(whereSeparator: \.isWhitespace).count
        guard originalWords > 0 else { return false }
        let ratio = Double(cleanedWords) / Double(originalWords)
        // Cleanup removes filler, so shrinking is expected; ballooning is not.
        return ratio > 0.45 && ratio < 2.2
    }
}
