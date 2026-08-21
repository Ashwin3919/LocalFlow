import Foundation

/// Minimal append-only file logger. The app is a background agent with no
/// console attached, so stdout is not observable during normal use.
enum Log {
    static let fileURL = URL(fileURLWithPath: "/tmp/localflow.log")

    private static let maximumBytes = 512 * 1024

    private static let queue = DispatchQueue(label: "com.localflow.log")
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    /// Rotate the log at launch so a session's output is not buried under
    /// weeks of history, and write a header with the build's identity.
    static func startSession() {
        queue.sync {
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            let size = (attributes?[.size] as? Int) ?? 0
            if size > maximumBytes {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        write("──── LocalFlow \(version) launched (pid \(ProcessInfo.processInfo.processIdentifier)) ────")
    }

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}
