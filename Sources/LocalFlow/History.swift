import Foundation

/// Append-only local transcript history, one JSON object per line.
/// Lives in ~/Library/Application Support/LocalFlow/history.jsonl.
enum History {
    static let directory: URL = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("LocalFlow", isDirectory: true)
    }()

    static let fileURL = directory.appendingPathComponent("history.jsonl")

    private static let queue = DispatchQueue(label: "com.localflow.history")

    struct Entry: Codable {
        let date: Date
        let raw: String
        let final: String
        let seconds: Double
        let engine: String
    }

    static func append(_ entry: Entry) {
        guard Settings.shared.historyEnabled else { return }
        queue.async {
            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true
                )
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                var data = try encoder.encode(entry)
                data.append(0x0A)
                if let handle = try? FileHandle(forWritingTo: fileURL) {
                    defer { try? handle.close() }
                    _ = try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    try data.write(to: fileURL)
                }
            } catch {
                Log.write("History write failed: \(error.localizedDescription)")
            }
        }
    }

    static func clear() {
        queue.async {
            try? FileManager.default.removeItem(at: fileURL)
            Log.write("History cleared")
        }
    }

    static func count() -> Int {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n").filter { !$0.isEmpty }.count
    }
}
