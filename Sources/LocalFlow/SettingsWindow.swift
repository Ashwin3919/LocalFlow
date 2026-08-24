import AppKit
import ServiceManagement
import Speech
import SwiftUI

/// Single settings window, hosted SwiftUI inside a plain NSWindow.
/// The app is an accessory app, so the window has to activate the process
/// explicitly or it opens behind everything.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    var onHotkeyModeChange: ((String) -> Void)?

    func show() {
        if window == nil {
            let view = SettingsView(onHotkeyModeChange: { [weak self] mode in
                self?.onHotkeyModeChange?(mode)
            })
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "LocalFlow Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 520, height: 620))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Launch at login

enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.write("Launch at login: \(enabled)")
        } catch {
            Log.write("Launch at login change failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - View

private struct SettingsView: View {
    let onHotkeyModeChange: (String) -> Void

    @State private var hotkeyMode = Settings.shared.hotkeyMode
    @State private var tapToLock = Settings.shared.tapToLock
    @State private var minHoldMs = Double(Int(Settings.shared.minHold * 1000))
    @State private var pasteDelayMs = Double(Int(Settings.shared.pasteDelay * 1000))
    @State private var preferAX = Settings.shared.preferAccessibilityInsert
    @State private var cleanupEnabled = Settings.shared.cleanupEnabled
    @State private var cleanupModel = Settings.shared.cleanupModel
    @State private var cleanupPrompt = Settings.shared.cleanupPrompt
    @State private var dictionary = Settings.shared.customDictionary
    @State private var sounds = Settings.shared.soundsEnabled
    @State private var flowBar = Settings.shared.flowBarEnabled
    @State private var historyEnabled = Settings.shared.historyEnabled
    @State private var micUID = Settings.shared.microphoneUID
    @State private var meetingLocale = Settings.shared.meetingLocale
    @State private var speakerLabels = Settings.shared.meetingSpeakerLabels
    @State private var meetingLocales: [Locale] = []
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var ollamaReachable: Bool? = nil
    @State private var refineEngineID = Settings.shared.refineEngineID
    @State private var refineCustomBinary = Settings.shared.refineCustomBinary
    @State private var refineCustomArguments = Settings.shared.refineCustomArguments
    @State private var refineModel = Settings.shared.refineModel
    @State private var refineTest: RefineTestState = .idle
    @State private var historyCount = History.count()

    private let microphones = AudioDevices.inputs()

    var body: some View {
        TabView {
            hotkeysTab.tabItem { Text("Hotkeys") }
            speechTab.tabItem { Text("Speech") }
            meetingsTab.tabItem { Text("Meetings") }
            cleanupTab.tabItem { Text("Cleanup") }
            generalTab.tabItem { Text("General") }
        }
        .padding(16)
        .frame(width: 520, height: 620)
    }

    // MARK: Meetings

    private var meetingsTab: some View {
        Form {
            Picker("Meeting language", selection: $meetingLocale) {
                // The saved value always has a row of its own, even before the
                // list has loaded and even if the model for it is no longer
                // offered. Without it the picker would show some other language
                // while the app went on using this one.
                if !meetingLocales.contains(where: { $0.identifier == meetingLocale }) {
                    Text(Self.languageName(meetingLocale)).tag(meetingLocale)
                }
                ForEach(meetingLocales, id: \.identifier) { locale in
                    Text(Self.languageName(locale.identifier)).tag(locale.identifier)
                }
            }
            .onChange(of: meetingLocale) { _, value in
                Settings.shared.meetingLocale = value
            }

            Text("A meeting commits to one language and stays there. Dictation can "
                 + "afford to retry a phrase in another locale; an hour of audio "
                 + "cannot be transcribed twice.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("Transcript").font(.headline)
            Toggle("Label every line with a timestamp and speaker", isOn: $speakerLabels)
                .onChange(of: speakerLabels) { _, value in
                    Settings.shared.meetingSpeakerLabels = value
                }
            Text(speakerLabels
                 ? "Lines are written as **[00:04:12] You** — …  Searchable by position and by who spoke, at the cost of being harder to read straight through."
                 : "The transcript is written as continuous prose, and a change of speaker is a paragraph break. This is what Refine into Notes reads, and what most people want to skim.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Applies to the next meeting. Files already written are untouched.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Divider()

            refineSection

            Divider()

            Text("Microphone").font(.headline)
            Text("Meetings use the microphone chosen on the Speech tab — currently "
                 + selectedMicrophoneName + ".")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("Where meetings are saved").font(.headline)
            HStack {
                Text(NotesFM.defaultRoot.path)
                    .font(.caption)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Reveal") { revealMeetingsFolder() }
            }
            Text("Plain markdown, one file per meeting. Nothing here needs this app "
                 + "to read it.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Text("Fn+R starts and stops a meeting. Fn+P pauses and resumes it — "
                 + "pausing stops capture completely, and notes can still be added "
                 + "while paused.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task {
            // Asked for rather than hardcoded: the installed set depends on the
            // machine, and a list of languages the engine cannot actually do is
            // worse than no list.
            let supported = await SpeechTranscriber.supportedLocales
            meetingLocales = supported.sorted {
                Self.languageName($0.identifier).localizedCompare(Self.languageName($1.identifier)) == .orderedAscending
            }
        }
    }

    private var selectedMicrophoneName: String {
        guard !micUID.isEmpty else {
            return "the system default (" + AudioDevices.defaultInputName() + ")"
        }
        return microphones.first(where: { $0.id == micUID })?.name
            ?? "a device that is not connected"
    }

    // MARK: Refine engine

    /// The result of the Test button. Kept out of `Refine` itself: this is about
    /// showing somebody what their tool actually emits before they trust it with
    /// a real meeting.
    private enum RefineTestState {
        case idle
        case running
        case succeeded(String)
        case failed(String)
    }

    private var selectedEngine: RefineEngine {
        if let preset = RefineEngine.preset(id: refineEngineID) { return preset }
        return RefineEngine.custom(
            binary: refineCustomBinary.trimmingCharacters(in: .whitespaces),
            arguments: RefineEngine.splitArguments(refineCustomArguments),
            model: refineModel
        )
    }

    /// Held as constants rather than built inline: a concatenation chain with
    /// string interpolation inside it is what made the type checker give up on
    /// this view.
    private static let customEngineHelp = """
        The transcript is written to the command's standard input, and the notes \
        are read from its standard output. Two optional substitutions: \
        \(RefineEngine.Token.answer) if the tool writes its reply to a file \
        instead, and \(RefineEngine.Token.directory) for the temporary folder it \
        is run in. Quotes are honoured; nothing else is — this is not a shell.
        """

    private static let customEngineWarning = """
        LocalFlow cannot tell what your command is allowed to do. Each built-in \
        engine is run with the flag that denies it file and shell access; a \
        command entered here gets whatever flags you give it.
        """

    private var refineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Refine into Notes").font(.headline)

            Picker("Engine", selection: $refineEngineID) {
                ForEach(RefineEngine.presets) { engine in
                    Text(engine.name).tag(engine.id)
                }
                Text("Custom…").tag(RefineEngine.customID)
            }
            .onChange(of: refineEngineID) { _, value in
                Settings.shared.refineEngineID = value
                refineTest = .idle
            }

            // Said out loud, next to the control, rather than left in a privacy
            // page nobody opens. This is the only button in the app that can send
            // anything anywhere, so where it goes is not a footnote.
            Label {
                Text("Your transcript goes to: \(selectedEngine.destination).")
            } icon: {
                Image(systemName: selectedEngine.id == RefineEngine.ollama.id
                      ? "lock.laptopcomputer" : "globe")
            }
            .font(.caption)
            .foregroundStyle(selectedEngine.id == RefineEngine.ollama.id ? Color.green : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if selectedEngine.arguments.contains(where: { $0.contains(RefineEngine.Token.model) }) {
                TextField("Model", text: $refineModel)
                    .onChange(of: refineModel) { _, value in
                        Settings.shared.refineModel = value.trimmingCharacters(in: .whitespaces)
                    }
                Text("Any model you have pulled — `ollama list` shows them. A small "
                     + "model summarises a meeting in seconds but follows the section "
                     + "headings loosely; a larger one reads better and takes longer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if refineEngineID == RefineEngine.customID {
                customEngineFields
            }

            refineAvailability
            refineTestRow
        }
    }

    private var customEngineFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Command", text: $refineCustomBinary, prompt: Text("goose"))
                .onChange(of: refineCustomBinary) { _, value in
                    Settings.shared.refineCustomBinary = value.trimmingCharacters(in: .whitespaces)
                    refineTest = .idle
                }
            TextField("Arguments", text: $refineCustomArguments, prompt: Text("run --no-session -t"))
                .onChange(of: refineCustomArguments) { _, value in
                    Settings.shared.refineCustomArguments = value
                    refineTest = .idle
                }
            Text(Self.customEngineHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label(Self.customEngineWarning, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var refineAvailability: some View {
        let engine = selectedEngine
        if engine.binary.isEmpty {
            Text("Enter the command to run.")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if let path = Refine.locate(engine) {
            Text("Found at \(path).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        } else {
            Text("`\(engine.binary)` was not found. Install it and sign in, or pick "
                 + "another engine. Everything else in the app works without it.")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var refineTestRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button("Test Engine…") { runRefineTest() }
                    .disabled(isTestingRefine || selectedEngine.binary.isEmpty)
                if isTestingRefine { ProgressView().controlSize(.small) }
            }
            switch refineTest {
            case .idle:
                Text("Runs three sentences through it and shows you exactly what comes "
                     + "back, so a tool that prints progress chatter into its answer is "
                     + "obvious before a real meeting goes through it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .running:
                Text("Running…").font(.caption).foregroundStyle(.secondary)
            case .succeeded(let notes):
                VStack(alignment: .leading, spacing: 4) {
                    Label("It answered. This is verbatim:", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    ScrollView {
                        Text(notes)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 110)
                    .padding(6)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var isTestingRefine: Bool {
        if case .running = refineTest { return true }
        return false
    }

    private func runRefineTest() {
        refineTest = .running
        let engine = selectedEngine
        let model = refineModel.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                let notes = try await Refine.notes(
                    from: Refine.testTranscript, title: "Engine Test", engine: engine, model: model
                )
                refineTest = .succeeded(notes)
            } catch {
                refineTest = .failed(error.localizedDescription)
            }
        }
    }

    private func revealMeetingsFolder() {
        let root = NotesFM.defaultRoot
        // The folder is created on the first meeting, so it may not exist yet;
        // revealing nothing would look like a bug rather than an empty library.
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: root.path)
    }

    private static func languageName(_ identifier: String) -> String {
        let locale = Locale(identifier: identifier)
        return Locale.current.localizedString(forIdentifier: identifier)
            ?? locale.identifier
    }

    // MARK: Hotkeys

    private var hotkeysTab: some View {
        Form {
            Picker("Trigger", selection: $hotkeyMode) {
                Text("Hold Fn").tag("fn")
                Text("Hold Ctrl + Option").tag("ctrlOpt")
            }
            .pickerStyle(.radioGroup)
            .onChange(of: hotkeyMode) { _, value in
                Settings.shared.hotkeyMode = value
                onHotkeyModeChange(value)
            }

            if hotkeyMode == "fn", !KeyboardWatch.fnIsFree {
                Label(
                    "System Settings → Keyboard → \"Press 🌐 key to\" is not set to "
                    + "\"Do Nothing\". Fn push-to-talk will fight the system action.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .font(.callout)
            }

            Divider()

            Text("Fixed shortcuts").font(.headline)
            LabeledContent("Hands-free toggle", value: hotkeyMode == "fn"
                ? "Fn + Space" : "Ctrl + Option + Space")
            LabeledContent("Lock hands-free", value: "Double-tap trigger while recording")
            LabeledContent("Paste last transcript", value: "Cmd + Ctrl + V")
            LabeledContent("Cancel recording", value: "Esc")

            Divider()

            Toggle("A quick tap locks into hands-free instead of discarding", isOn: $tapToLock)
                .onChange(of: tapToLock) { _, value in Settings.shared.tapToLock = value }

            VStack(alignment: .leading) {
                Text("Minimum hold to count as push-to-talk: \(Int(minHoldMs)) ms")
                Slider(value: $minHoldMs, in: 100...600, step: 25)
                    .onChange(of: minHoldMs) { _, value in
                        Settings.shared.minHold = value / 1000
                    }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Speech

    private var speechTab: some View {
        Form {
            LabeledContent("Engine", value: "Apple SpeechTranscriber (on-device)")
            LabeledContent("Languages", value: "English (en-US) + German (de-DE), auto-detected")

            Picker("Microphone", selection: $micUID) {
                Text("System default — \(AudioDevices.defaultInputName())").tag("")
                ForEach(microphones) { device in
                    Text(device.name).tag(device.id)
                }
            }
            .onChange(of: micUID) { _, value in Settings.shared.microphoneUID = value }

            Divider()

            Text("Custom dictionary").font(.headline)
            Text("One term per line, or comma separated. These are given to the "
                 + "cleanup model so proper nouns and jargon survive.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $dictionary)
                .font(.system(.body, design: .monospaced))
                .frame(height: 140)
                .onChange(of: dictionary) { _, value in Settings.shared.customDictionary = value }
        }
        .formStyle(.grouped)
    }

    // MARK: Cleanup

    private var cleanupTab: some View {
        Form {
            Toggle("Polish transcripts with a local LLM", isOn: $cleanupEnabled)
                .onChange(of: cleanupEnabled) { _, value in
                    Settings.shared.cleanupEnabled = value
                    if value { Task.detached { await Cleanup.warm() } }
                }

            HStack {
                TextField("Ollama model", text: $cleanupModel)
                    .onChange(of: cleanupModel) { _, value in Settings.shared.cleanupModel = value }
                Button("Test") {
                    Task {
                        ollamaReachable = await Cleanup.isReachable()
                    }
                }
            }

            if let reachable = ollamaReachable {
                Label(
                    reachable
                        ? "Ollama is responding on localhost:11434"
                        : "Ollama is not reachable — raw transcripts will be pasted",
                    systemImage: reachable ? "checkmark.circle.fill" : "xmark.circle.fill"
                )
                .foregroundStyle(reachable ? .green : .orange)
                .font(.callout)
            }

            Text("Cleanup runs with a 3 second timeout. If it fails for any "
                 + "reason the raw transcript is pasted instead.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Text("Cleanup prompt").font(.headline)
            TextEditor(text: $cleanupPrompt)
                .font(.system(.body, design: .monospaced))
                .frame(height: 180)
                .onChange(of: cleanupPrompt) { _, value in Settings.shared.cleanupPrompt = value }
            Button("Restore default prompt") {
                cleanupPrompt = Settings.defaultCleanupPrompt
                Settings.shared.cleanupPrompt = cleanupPrompt
            }
        }
        .formStyle(.grouped)
    }

    // MARK: General

    private var generalTab: some View {
        Form {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, value in LoginItem.set(value) }
            Toggle("Ping sounds", isOn: $sounds)
                .onChange(of: sounds) { _, value in Settings.shared.soundsEnabled = value }
            Toggle("Show the floating flow bar while recording", isOn: $flowBar)
                .onChange(of: flowBar) { _, value in Settings.shared.flowBarEnabled = value }

            Divider()

            Toggle("Prefer direct Accessibility insertion when available", isOn: $preferAX)
                .onChange(of: preferAX) { _, value in
                    Settings.shared.preferAccessibilityInsert = value
                }
            VStack(alignment: .leading) {
                Text("Delay before synthesizing Cmd+V: \(Int(pasteDelayMs)) ms")
                Slider(value: $pasteDelayMs, in: 20...300, step: 10)
                    .onChange(of: pasteDelayMs) { _, value in
                        Settings.shared.pasteDelay = value / 1000
                    }
                Text("Electron apps and terminals drop the paste if this is too low.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Toggle("Keep a local transcript history", isOn: $historyEnabled)
                .onChange(of: historyEnabled) { _, value in Settings.shared.historyEnabled = value }
            HStack {
                Text("\(historyCount) entries in \(History.fileURL.path)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear history") {
                    History.clear()
                    historyCount = 0
                }
            }
        }
        .formStyle(.grouped)
    }
}
