import Foundation

/// One way of turning a transcript into notes: a command to run, and where to
/// read the answer from.
///
/// The obvious design — a text field holding a command *name* — cannot work,
/// because these tools do not share an invocation shape. Checked against the
/// tools installed on the development machine rather than from memory:
///
/// | tool | prompt arrives via | answer comes from | read-only flag |
/// |---|---|---|---|
/// | `codex` | stdin (`-`) | a **file** (`--output-last-message`) | `--sandbox read-only` |
/// | `claude` | stdin (`-p`) | **stdout** | `--allowed-tools ''` |
/// | `cursor-agent` | stdin (`-p`) | **stdout** | `--mode ask --sandbox enabled` |
/// | `ollama` | stdin | **stdout** | none needed — it has no tools |
///
/// Three different answers to every question, so the shape has to be data rather
/// than a string. `cursor-agent --help` is blunt about why the flags are not
/// optional: its print mode "Has access to all tools, including write and shell".
///
/// The tokens below declare the shape, which is what keeps this from needing a
/// row of toggles beside it: an `{answer}` in the arguments means the answer is a
/// file, and a `{prompt}` means the transcript goes in as an argument. Absent
/// either, stdout and stdin are assumed.
struct RefineEngine: Hashable, Sendable, Identifiable {
    /// Substituted into `arguments` before the process runs.
    enum Token {
        /// The scratch directory the command is pointed at.
        static let directory = "{dir}"
        /// The file the command should write its answer to.
        static let answer = "{answer}"
        /// The prompt, for a command that cannot read stdin.
        static let prompt = "{prompt}"
        /// The model name, for a runner that needs one.
        static let model = "{model}"
    }

    enum PromptDelivery: Sendable {
        /// Written to stdin. Preferred: a two-hour transcript as an `argv` entry
        /// is a length limit waiting to be hit.
        case standardInput
        case argument
    }

    enum AnswerSource: Sendable {
        /// Read from the file named by `{answer}`. Preferred wherever the engine
        /// offers it — stdout carries progress chatter, and chatter must never
        /// land in somebody's notes.
        case file
        case standardOutput
    }

    /// Stable key written to preferences. Never change one of these.
    var id: String
    /// Shown in Settings.
    var name: String
    /// Executable to look for on disk.
    var binary: String
    /// Arguments, tokens included.
    var arguments: [String]
    /// Where the transcript ends up, in one phrase, so Settings can say it out
    /// loud instead of burying it in a privacy page nobody opens.
    var destination: String
    /// Extra absolute paths to try before asking a login shell, for a tool that
    /// installs somewhere unusual. `~` is expanded.
    var extraCandidates: [String] = []
    /// True only for a preset that has actually been run end to end here.
    var isVerified: Bool = false
    /// Whether the app can state what stops this engine touching files. False
    /// for a command somebody typed in, because it cannot be known.
    var isSandboxed: Bool = true

    /// Inferred from the arguments, so a custom engine needs no toggles: writing
    /// `{answer}` somewhere in the command *is* the declaration that the answer
    /// is a file.
    var answerSource: AnswerSource {
        arguments.contains { $0.contains(Token.answer) } ? .file : .standardOutput
    }

    var promptDelivery: PromptDelivery {
        arguments.contains { $0.contains(Token.prompt) } ? .argument : .standardInput
    }

    /// Fills in the tokens. Substitution is per whole argument rather than a
    /// blind string replace across the joined command, so a path containing a
    /// brace cannot corrupt the next argument.
    func resolvedArguments(directory: String, answerPath: String, prompt: String, model: String) -> [String] {
        arguments.map { argument in
            argument
                .replacingOccurrences(of: Token.directory, with: directory)
                .replacingOccurrences(of: Token.answer, with: answerPath)
                .replacingOccurrences(of: Token.prompt, with: prompt)
                .replacingOccurrences(of: Token.model, with: model)
        }
    }
}

// MARK: - The presets

extension RefineEngine {
    /// Codex stays the default: it is what this feature was built and measured
    /// against, so nobody's setup changes by upgrading.
    static let codex = RefineEngine(
        id: "codex",
        name: "Codex CLI",
        binary: "codex",
        arguments: [
            "exec",
            "--sandbox", "read-only",       // it must not be able to touch anything
            "--skip-git-repo-check",        // the scratch directory is not a repo
            "--ephemeral",                  // leave no session files behind
            "--color", "never",             // no escape codes in the notes
            "--cd", Token.directory,
            "--output-last-message", Token.answer,
            "-",                            // prompt arrives on stdin
        ],
        destination: "OpenAI, through the Codex CLI you are already signed in to",
        extraCandidates: ["~/.codex/packages/standalone/current/bin/codex"],
        isVerified: true
    )

    /// `--allowed-tools ''` rather than a read-only sandbox. For a pure text
    /// transform the strongest setting is not "may read but not write" but "has
    /// no tools at all", and this is the flag that says so. Verified by asking it
    /// to write a file: it refused, wrote nothing, and said it would not route
    /// around the block with a shell command.
    static let claude = RefineEngine(
        id: "claude",
        name: "Claude Code",
        binary: "claude",
        arguments: ["-p", "--output-format", "text", "--allowed-tools", ""],
        destination: "Anthropic, through the Claude Code CLI you are already signed in to",
        isVerified: true
    )

    /// `--mode ask` is its read-only mode, `--trust` is required or it stops to
    /// ask about the scratch directory and a non-interactive run simply hangs,
    /// and `--sandbox enabled` is stated rather than left to config. Verified the
    /// same way as Claude: asked to write a file, it refused and wrote nothing.
    static let cursorAgent = RefineEngine(
        id: "cursor-agent",
        name: "Cursor Agent",
        binary: "cursor-agent",
        arguments: [
            "-p",
            "--output-format", "text",
            "--mode", "ask",
            "--trust",
            "--sandbox", "enabled",
        ],
        destination: "Cursor, through the cursor-agent CLI you are already signed in to",
        isVerified: true
    )

    /// The one that keeps the promise the rest of this app makes. Ollama is a
    /// model runner rather than an agent — there are no tools to switch off,
    /// nothing to sandbox, and no network beyond localhost. Choosing this makes
    /// Refine the last feature to stop being an exception.
    static let ollama = RefineEngine(
        id: "ollama",
        name: "Ollama (on this Mac)",
        binary: "ollama",
        arguments: ["run", Token.model],
        destination: "nowhere — it runs on this Mac and never leaves it",
        isVerified: true
    )

    /// Chosen by id when the user has typed their own command.
    static let customID = "custom"

    /// Order matters: this is the order the Settings picker shows.
    static let presets: [RefineEngine] = [codex, claude, cursorAgent, ollama]

    static func preset(id: String) -> RefineEngine? {
        presets.first { $0.id == id }
    }

    /// Builds the engine described by a command the user typed.
    ///
    /// Marked unsandboxed whatever it contains: the app has no way to know what
    /// somebody else's tool does with a `--yes` flag, and claiming otherwise in
    /// the UI would be the kind of reassurance that gets a repository rewritten.
    static func custom(binary: String, arguments: [String], model: String) -> RefineEngine {
        RefineEngine(
            id: customID,
            name: "Custom",
            binary: binary,
            arguments: arguments,
            destination: "wherever the command you entered sends it",
            isVerified: false,
            isSandboxed: false
        )
    }
}

// MARK: - Parsing a typed command line

extension RefineEngine {
    /// Splits a typed argument string into arguments.
    ///
    /// Deliberately not a shell. It honours double quotes so a path with a space
    /// in it survives, and does nothing else — no globbing, no variables, no
    /// backticks, no pipes. A command line is being built for `Process`, which
    /// takes an argument vector directly, so there is no shell to quote *for*,
    /// and pretending otherwise is how a setting field turns into an injection.
    static func splitArguments(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quoted = false
        var sawAny = false

        for character in line {
            if character == "\"" {
                quoted.toggle()
                // An empty pair of quotes is a real, empty argument — which is
                // exactly what `claude --allowed-tools ""` needs.
                sawAny = true
            } else if character.isWhitespace, !quoted {
                if sawAny { result.append(current) }
                current = ""
                sawAny = false
            } else {
                current.append(character)
                sawAny = true
            }
        }
        if sawAny { result.append(current) }
        return result
    }
}
