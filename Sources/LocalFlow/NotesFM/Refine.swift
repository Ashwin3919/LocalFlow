import Foundation

/// Turns a raw transcript into meeting notes, using a command-line tool that is
/// already installed and signed in on this Mac.
///
/// **This is the only thing in the app that can leave the machine**, and it
/// happens only when somebody presses the button. Transcription itself is always
/// local. Two consequences are deliberate:
///
///  * The result is written to its **own file**. A model's idea of what was said
///    must never be able to overwrite what was actually recorded.
///  * The tool is run read-only in a temporary directory. These are agentic
///    coding tools that can edit files and run commands; here one is being used
///    purely as a text transform, and it is given no means to be anything else.
///    The flag that enforces that differs per tool and lives in `RefineEngine`.
///
/// Which tool runs is a setting — see `RefineEngine` for why that has to be a
/// typed description rather than a command name, and for what was verified
/// against each one. Choosing the local runner makes this feature stop being an
/// exception to the rest of the app.
///
/// The prompt is one string rather than a chat: every one of these is a
/// single-shot interface. Where the tool can write its final message to a file it
/// is read from there rather than parsed out of stdout, so no amount of progress
/// chatter can end up inside somebody's notes.
enum Refine {
    /// Generous. A two-hour transcript is a lot of tokens, and the cost of being
    /// wrong here is throwing away work that was nearly finished.
    static let timeout: TimeInterval = 240

    enum Failure: LocalizedError {
        case notConfigured
        case missing(engine: String, binary: String)
        case timedOut(engine: String, seconds: TimeInterval)
        case failed(engine: String, status: Int32, detail: String)
        case emptyResult(engine: String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                "No notes engine is set. Choose one in Settings → Meetings."
            case .missing(let engine, let binary):
                "Could not find the `\(binary)` command for \(engine). "
                    + "Install it and sign in, then try again — or choose a different engine in Settings → Meetings."
            case .timedOut(let engine, let seconds):
                "\(engine) did not finish within \(Int(seconds)) seconds. The transcript may be very long."
            case .failed(let engine, let status, let detail):
                detail.isEmpty
                    ? "\(engine) exited with status \(status)."
                    : "\(engine) failed: \(detail)"
            case .emptyResult(let engine):
                "\(engine) returned nothing. Check that it is installed, signed in and running."
            }
        }
    }

    // MARK: - Locating the CLI

    /// A GUI app does not inherit the shell's `PATH`, so the binary is looked for
    /// where it actually installs before falling back to asking a login shell.
    ///
    /// An absolute path is taken as given — somebody who typed one in Settings
    /// has already answered this question.
    static func locate(_ engine: RefineEngine) -> String? {
        if engine.binary.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: engine.binary) ? engine.binary : nil
        }
        guard !engine.binary.isEmpty else { return nil }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let directories = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.bun/bin",
        ]
        var candidates = directories.map { "\($0)/\(engine.binary)" }
        candidates += engine.extraCandidates.map {
            $0.hasPrefix("~") ? home + $0.dropFirst() : $0
        }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return askLoginShell(for: engine.binary)
    }

    private static func askLoginShell(for binary: String) -> String? {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // `--` so a binary name is never read as an option by `command`.
        shell.arguments = ["-lc", "command -v -- \(shellQuoted(binary))"]
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

    /// Single-quoted for the one place a shell is unavoidable: `command -v` has
    /// no `Process` equivalent that consults the login shell's `PATH`.
    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func isAvailable(_ engine: RefineEngine) -> Bool { locate(engine) != nil }

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

    /// Three sentences with one decision, one owner and one open question in
    /// them, so the Test button's output shows whether an engine can actually
    /// follow the prompt rather than only whether it runs.
    static let testTranscript = """
        Right, so we agreed to ship the installer on Thursday. Priya is going to \
        write the release notes. We still do not know whether the German locale \
        works, so somebody needs to check that before we announce anything.
        """

    /// Somewhere for a background read to land. Unchecked because the only
    /// hand-off is the `DispatchGroup` that waits for the write to finish before
    /// anything reads it.
    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }

    // MARK: - Running it

    private static let queue = DispatchQueue(label: "com.localflow.refine", qos: .userInitiated)

    static func notes(
        from transcript: String,
        title: String,
        engine: RefineEngine,
        model: String
    ) async throws -> String {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.emptyResult(engine: engine.name) }
        guard !engine.binary.isEmpty else { throw Failure.notConfigured }
        guard let executable = locate(engine) else {
            throw Failure.missing(engine: engine.name, binary: engine.binary)
        }
        let request = prompt(title: title, transcript: text)

        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try execute(
                        executable: executable, engine: engine, model: model, prompt: request
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Blocking. Only ever called on `queue`.
    private static func execute(
        executable: String,
        engine: RefineEngine,
        model: String,
        prompt: String
    ) throws -> String {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("localflow-refine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let answer = scratch.appendingPathComponent("notes.md")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = engine.resolvedArguments(
            directory: scratch.path, answerPath: answer.path, prompt: prompt, model: model
        )
        // Run it in the scratch directory, not wherever the app was launched
        // from. Tools that read a project's config from the working directory
        // find nothing there, which is the point.
        process.currentDirectoryURL = scratch

        let errors = Pipe()
        process.standardError = errors

        // Where the answer comes from decides what stdout is for. A tool that
        // writes its final message to a file puts progress chatter on stdout, and
        // chatter must never reach somebody's notes — so it is discarded, which
        // also removes the risk of an undrained pipe deadlocking a long run. A
        // tool that answers on stdout needs it drained instead.
        let output: Pipe?
        switch engine.answerSource {
        case .file:
            output = nil
            process.standardOutput = FileHandle.nullDevice
        case .standardOutput:
            let pipe = Pipe()
            output = pipe
            process.standardOutput = pipe
        }

        let input: Pipe?
        switch engine.promptDelivery {
        case .standardInput:
            let pipe = Pipe()
            input = pipe
            process.standardInput = pipe
        case .argument:
            input = nil
            // Closed rather than inherited: a tool that decides to read stdin
            // would otherwise block forever on a pipe nobody writes to.
            process.standardInput = FileHandle.nullDevice
        }

        try process.run()

        // Written on another thread: a prompt larger than the pipe buffer would
        // otherwise block here while nothing is reading the other end.
        if let input {
            let payload = Data(prompt.utf8)
            DispatchQueue.global(qos: .utility).async {
                input.fileHandleForWriting.write(payload)
                try? input.fileHandleForWriting.close()
            }
        }

        // Drained before `waitUntilExit`, for the same reason: a tool answering on
        // stdout can produce more than a pipe buffer holds.
        // A box rather than a captured `var`: the read happens on another queue,
        // and Swift 6 is right to refuse a mutation across that boundary. The
        // `DispatchGroup` below is the synchronisation.
        let streamed = DataBox()
        let drained = DispatchGroup()
        if let output {
            drained.enter()
            DispatchQueue.global(qos: .utility).async {
                streamed.data = output.fileHandleForReading.readDataToEndOfFile()
                drained.leave()
            }
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
        drained.wait()
        killer.cancel()

        if timedOut { throw Failure.timedOut(engine: engine.name, seconds: timeout) }

        // Stripped on the way in, not just in error messages. Measured: Ollama
        // emits a bare `ESC[K` — erase to end of line — *on stdout, mid-answer*,
        // so a sentence in the finished notes read "assigned tasks to [K". This
        // is the whole reason a tool that answers on stdout is treated as less
        // trustworthy than one that writes to a file, and why the Settings pane
        // has a Test button that shows the raw reply.
        let raw: String
        switch engine.answerSource {
        case .file:
            raw = (try? String(contentsOf: answer, encoding: .utf8)) ?? ""
        case .standardOutput:
            raw = String(decoding: streamed.data, as: UTF8.self)
        }
        let text = stripControlCodes(raw).trimmingCharacters(in: .whitespacesAndNewlines)

        if process.terminationStatus != 0 {
            let detail = stripControlCodes(String(decoding: errorData, as: UTF8.self))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Only the tail is useful, and the whole thing can be pages long.
            let tail = detail.split(separator: "\n").suffix(3).joined(separator: " ")
            throw Failure.failed(
                engine: engine.name,
                status: process.terminationStatus,
                detail: String(tail.prefix(300))
            )
        }
        guard !text.isEmpty else { throw Failure.emptyResult(engine: engine.name) }

        Log.write("Refine: \(engine.name) returned \(text.count) characters of notes")
        return stripFence(text)
    }

    /// Resolves terminal control codes into the text a terminal would have shown.
    ///
    /// Not simply "delete the escapes", and the difference is a correctness bug
    /// rather than a cosmetic one. Measured from Ollama's real output: before
    /// wrapping a line it writes a part of the next word, rewinds the cursor over
    /// it with `ESC[<n>D`, erases to end of line, breaks the line, and writes the
    /// word again in full:
    ///
    ///     ...shipping the installer  ESC[9D  ESC[K  \n  installer. To recap...
    ///
    /// Dropping the escapes and keeping everything else put `assigned tasks to
    /// [K` and duplicated half-words into finished notes. Ollama does this
    /// whether stdout is a pipe or a file, and neither `NO_COLOR` nor `TERM=dumb`
    /// stops it, so it has to be undone here.
    ///
    /// Three rules, which is all these tools actually use:
    ///  * `ESC[<n>D` moves the cursor back, so it deletes the last *n* characters.
    ///  * a line break straight after such a rewind is the wrap itself, and the
    ///    logical line has no break in it.
    ///  * a lone carriage return returns to the start of the line, so what was
    ///    written there is about to be overwritten and is dropped.
    ///
    /// Every other sequence only ever moved a cursor or set a colour, and is
    /// discarded.
    static func stripControlCodes(_ text: String) -> String {
        let characters = Array(text)
        var out: [Character] = []
        var index = 0
        var rewound = false

        while index < characters.count {
            let character = characters[index]

            if character == "\u{1B}" {
                index += 1
                guard index < characters.count else { break }
                let introducer = characters[index]
                index += 1

                if introducer == "[" {
                    var parameters = ""
                    while index < characters.count,
                          characters[index].isNumber || characters[index] == ";"
                            || characters[index] == "?" {
                        parameters.append(characters[index])
                        index += 1
                    }
                    let final: Character? = index < characters.count ? characters[index] : nil
                    if final != nil { index += 1 }
                    if final == "D" {
                        let count = max(1, Int(parameters.split(separator: ";").first ?? "") ?? 1)
                        out.removeLast(min(count, out.count))
                        rewound = true
                    }
                } else if introducer == "]" {
                    // An operating-system command, terminated by BEL or ESC \.
                    while index < characters.count {
                        if characters[index] == "\u{07}" { index += 1; break }
                        if characters[index] == "\u{1B}" { index += 2; break }
                        index += 1
                    }
                }
                // Anything else was a two-character sequence, already consumed.
                continue
            }

            if character == "\r" {
                while let last = out.last, last != "\n" { out.removeLast() }
                index += 1
                continue
            }

            if character == "\n", rewound {
                rewound = false
                index += 1
                continue
            }

            rewound = false
            out.append(character)
            index += 1
        }
        return String(out)
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
