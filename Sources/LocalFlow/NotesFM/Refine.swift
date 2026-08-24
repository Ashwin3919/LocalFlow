import Foundation

/// Turns a raw transcript into meeting notes, using the Codex CLI that is
/// already installed and signed in on this Mac.
///
/// **This is the only thing in the app that leaves the machine**, and it happens
/// only when somebody presses the button. Transcription itself is always local.
/// Two consequences are deliberate:
///
///  * The result is written to its **own file**. A model's idea of what was said
///    must never be able to overwrite what was actually recorded.
///  * The agent runs `--sandbox read-only` in a temporary directory. Codex is an
///    agentic coding tool that can edit files; here it is being used purely as a
///    text transform, and it is given no means to be anything else.
///
/// The prompt is one string rather than a chat: `codex exec` is a single-shot
/// interface, and the final message is collected from `--output-last-message`
/// rather than parsed out of stdout, so no amount of progress chatter can end up
/// inside somebody's notes.
enum Refine {
    /// Generous. A two-hour transcript is a lot of tokens, and the cost of being
    /// wrong here is throwing away work that was nearly finished.
    static let timeout: TimeInterval = 240

    enum Failure: LocalizedError {
        case codexMissing
        case timedOut(TimeInterval)
        case failed(status: Int32, detail: String)
        case emptyResult

        var errorDescription: String? {
            switch self {
            case .codexMissing:
                "Could not find the codex command. Install the Codex CLI and sign in, then try again."
            case .timedOut(let seconds):
                "Codex did not finish within \(Int(seconds)) seconds. The transcript may be very long."
            case .failed(let status, let detail):
                detail.isEmpty
                    ? "Codex exited with status \(status)."
                    : "Codex failed: \(detail)"
            case .emptyResult:
                "Codex returned nothing. Check that it is signed in with `codex login`."
            }
        }
    }

    // MARK: - Locating the CLI

    /// A GUI app does not inherit the shell's `PATH`, so the binary is looked for
    /// where it actually installs before falling back to asking a login shell.
    static func locate() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.codex/packages/standalone/current/bin/codex",
            "\(home)/.bun/bin/codex",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return askLoginShell()
    }

    private static func askLoginShell() -> String? {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v codex"]
        let out = Pipe()
        shell.standardOutput = out
        shell.standardError = FileHandle.nullDevice
        do { try shell.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        shell.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    static var isAvailable: Bool { locate() != nil }

    // MARK: - The prompt

    /// Written for the plain transcript the app produces now, which carries no
    /// speaker names and no timestamps — so the model has nothing to attribute
    /// with, and the instructions lean hard on not inventing an owner it cannot
    /// know. Files recorded before that change, and files from someone who turned
    /// labels back on, still carry `**[00:04:12] You** —` prefixes, so the prompt
    /// describes both rather than asserting one.
    static func prompt(title: String, transcript: String) -> String {
        """
        Turn the raw meeting transcript below into meeting notes.

        The transcript was produced live from audio by a speech recogniser. \
        Punctuation is approximate and individual words may be misheard. It is \
        usually continuous prose with no speaker names; if lines do carry a \
        prefix like "**[00:04:12] You** —" then "You" is the person whose Mac \
        recorded this and "Them" is everyone else, and those prefixes must not \
        appear in your output. Lines beginning with "> " are notes the person \
        typed themselves during the meeting, so treat those as reliable. A line \
        like "_— paused for 4m 10s —_" means recording was stopped there and \
        something is missing.

        Write Markdown, using only the sections the transcript actually supports:

        - a short summary paragraph
        - **Decisions** — what was settled
        - **Action items** — one per line; name an owner only if the transcript \
        names one, otherwise leave it unassigned
        - **Open questions** — what was raised and not resolved
        - **Details worth keeping** — numbers, dates, names, links

        Rules, in order of importance:

        1. Invent nothing. If the transcript does not say it, it does not go in.
        2. Do not guess who is responsible for anything.
        3. Keep the speakers' own wording for commitments, numbers and dates.
        4. Where the recogniser clearly garbled something important, write \
        [unclear] rather than a plausible guess.
        5. Omit a section entirely rather than filling it with padding.
        6. Output only the Markdown notes. No preamble, no sign-off, and do not \
        repeat the transcript back.

        Meeting title: \(title)

        --- TRANSCRIPT ---
        \(transcript)
        --- END TRANSCRIPT ---
        """
    }

    // MARK: - Running it

    private static let queue = DispatchQueue(label: "com.localflow.refine", qos: .userInitiated)

    static func notes(from transcript: String, title: String) async throws -> String {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.emptyResult }
        guard let codex = locate() else { throw Failure.codexMissing }
        let request = prompt(title: title, transcript: text)

        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try execute(codex: codex, prompt: request))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Blocking. Only ever called on `queue`.
    private static func execute(codex: String, prompt: String) throws -> String {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("localflow-refine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let answer = scratch.appendingPathComponent("notes.md")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: codex)
        process.arguments = [
            "exec",
            "--sandbox", "read-only",       // it must not be able to touch anything
            "--skip-git-repo-check",        // the scratch directory is not a repo
            "--ephemeral",                  // leave no session files behind
            "--color", "never",             // no escape codes in the transcript
            "--cd", scratch.path,
            "--output-last-message", answer.path,
            "-",                            // prompt arrives on stdin
        ]

        let input = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardError = errors
        // Progress chatter goes nowhere. The answer is read from the file, and an
        // undrained stdout pipe would eventually deadlock a long run.
        process.standardOutput = FileHandle.nullDevice

        try process.run()

        // Written on another thread: a prompt larger than the pipe buffer would
        // otherwise block here while nothing is reading the other end.
        let payload = Data(prompt.utf8)
        DispatchQueue.global(qos: .utility).async {
            input.fileHandleForWriting.write(payload)
            try? input.fileHandleForWriting.close()
        }

        var timedOut = false
        let killer = DispatchWorkItem {
            if process.isRunning {
                timedOut = true
                process.terminate()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)

        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()

        if timedOut { throw Failure.timedOut(timeout) }

        let text = (try? String(contentsOf: answer, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus != 0 {
            let detail = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Only the tail is useful, and the whole thing can be pages long.
            let tail = detail.split(separator: "\n").suffix(3).joined(separator: " ")
            throw Failure.failed(status: process.terminationStatus, detail: String(tail.prefix(300)))
        }
        guard !text.isEmpty else { throw Failure.emptyResult }

        Log.write("Refine: Codex returned \(text.count) characters of notes")
        return stripFence(text)
    }

    /// Models sometimes wrap the whole answer in a ```markdown fence despite
    /// being asked for Markdown itself. Unwrapped only when the fence encloses
    /// the entire response, so a code block inside real notes survives.
    static func stripFence(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 2,
              lines[0].trimmingCharacters(in: .whitespaces).hasPrefix("```"),
              lines[lines.count - 1].trimmingCharacters(in: .whitespaces) == "```",
              !lines[1..<(lines.count - 1)].contains(where: { $0.hasPrefix("```") })
        else { return text }
        return lines[1..<(lines.count - 1)].joined(separator: "\n")
    }
}
