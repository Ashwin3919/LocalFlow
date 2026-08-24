import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let warningLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let lastTranscriptLine = NSMenuItem(title: "No transcript yet", action: nil, keyEquivalent: "")

    private let hotkeys = HotkeyManager()
    private let controller = DictationController(engine: AppleSpeechEngine())
    private let settingsWindow = SettingsWindowController()
    private let setupWindow = SetupWindowController()
    private let meeting = MeetingSession()
    private lazy var meetingHUD = MeetingHUDController(session: meeting)
    private let notesWindow = NotesFMWindowController()
    private let meetingLine = NSMenuItem(title: "Start Meeting", action: nil, keyEquivalent: "")
    private let pauseLine = NSMenuItem(title: "Pause Meeting", action: nil, keyEquivalent: "")
    /// Shown only during a meeting: the HUD has a close button, and closing it
    /// used to strand the user with a running meeting they could no longer see or
    /// add notes to.
    private let hudLine = NSMenuItem(title: "Show Meeting Window", action: nil, keyEquivalent: "")
    private var lastWarnings: [String] = ["__unset__"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--notesfm-selftest") {
            exit(NotesFMSelfTest.run())
        }
        // Runs the same code path the Refine button uses, so the Process wiring
        // can be exercised without a GUI. Prints the notes; writes no files.
        if let index = CommandLine.arguments.firstIndex(of: "--notesfm-refine"),
           index + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[index + 1]
            let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            guard !text.isEmpty else {
                FileHandle.standardError.write(Data("could not read \(path)\n".utf8))
                exit(1)
            }
            let semaphore = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var code: Int32 = 0
            // `Task.detached`, not `Task`. This method is `@MainActor`, so a plain
            // `Task` inherits the main actor and could never start while the
            // semaphore below is holding the main thread — a deadlock, not a slow
            // network call. The button in the library has no such problem: it
            // awaits rather than blocking.
            Task.detached {
                do {
                    let notes = try await Refine.notes(
                        from: text,
                        title: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                    )
                    print(notes)
                } catch {
                    FileHandle.standardError.write(
                        Data("refine failed: \(error.localizedDescription)\n".utf8))
                    code = 1
                }
                semaphore.signal()
            }
            semaphore.wait()
            exit(code)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--notesfm-capture-test") {
            let seconds = CommandLine.arguments.count > index + 1
                ? Double(CommandLine.arguments[index + 1]) ?? 8
                : 8
            NotesFMCaptureTest.run(seconds: seconds)
        }
        Log.startSession()
        Sound.preload()
        buildMenu()

        controller.onStateChange = { [weak self] state in
            self?.render(state: state)
        }
        controller.onTranscript = { [weak self] text in
            self?.lastTranscriptLine.title = Self.truncate(text)
        }

        hotkeys.isRecording = { [controller] in
            MainActor.assumeIsolated { controller.isRecordingNow }
        }
        hotkeys.onAction = { [weak self] action in
            Task { @MainActor in
                guard let self else { return }
                // Meetings are a separate mode, so the action is routed here
                // rather than being taught to the dictation state machine. Both
                // chords abandon the hold that started them first: Fn produces no
                // keyDown, so the hold had already begun a dictation by the time
                // the letter arrived.
                switch action {
                case .toggleMeeting:
                    self.controller.abandonHold()
                    await self.toggleMeeting()
                case .togglePause:
                    self.controller.abandonHold()
                    await self.togglePause()
                default:
                    guard !self.blockedByMeeting(action) else { return }
                    self.controller.handle(action)
                }
            }
        }

        meeting.onFinished = { [weak self] identifier in
            self?.meetingHUD.hide()
            self?.renderMeetingState()
            self?.notesWindow.show(selecting: identifier)
        }
        settingsWindow.onHotkeyModeChange = { [weak self] mode in
            self?.hotkeys.mode = mode
            self?.refreshWarnings()
        }

        chooseHotkeyMode()
        renderMeetingState()
        startEventTap()
        refreshWarnings()
        presentSetupIfNeeded()

        Task { await controller.prepare() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys.stop()
        // A meeting in progress owns an open file whose duration is still zero.
        // Quitting without this leaves the user a transcript that looks broken.
        meeting.saveBeforeQuit()
        Log.write("LocalFlow terminated")
    }

    // MARK: - Menu

    private func buildMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.icon(for: .idle)
        item.button?.toolTip = "LocalFlow"

        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        warningLine.isEnabled = true
        warningLine.action = #selector(openRelevantSettings)
        warningLine.target = self
        warningLine.isHidden = true
        menu.addItem(warningLine)

        menu.addItem(.separator())

        lastTranscriptLine.isEnabled = false
        menu.addItem(lastTranscriptLine)

        let pasteLast = NSMenuItem(
            title: "Paste Last Transcript",
            action: #selector(pasteLast),
            keyEquivalent: "v"
        )
        pasteLast.keyEquivalentModifierMask = [.command, .control]
        pasteLast.target = self
        menu.addItem(pasteLast)

        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        meetingLine.action = #selector(toggleMeetingFromMenu)
        meetingLine.target = self
        menu.addItem(meetingLine)

        pauseLine.action = #selector(togglePauseFromMenu)
        pauseLine.target = self
        menu.addItem(pauseLine)

        hudLine.action = #selector(showMeetingHUD)
        hudLine.target = self
        menu.addItem(hudLine)

        let captureTest = NSMenuItem(
            title: "Test Audio Capture…",
            action: #selector(testCapture),
            keyEquivalent: ""
        )
        captureTest.target = self
        menu.addItem(captureTest)

        let library = NSMenuItem(
            title: "NotesFM Library…",
            action: #selector(openNotes),
            keyEquivalent: "l"
        )
        library.target = self
        menu.addItem(library)

        menu.addItem(.separator())

        let setup = NSMenuItem(
            title: "Setup Guide…",
            action: #selector(openSetup),
            keyEquivalent: ""
        )
        setup.target = self
        menu.addItem(setup)

        let permissions = NSMenu()
        for (title, selector) in [
            ("Accessibility…", #selector(openAccessibilitySettings)),
            ("Input Monitoring…", #selector(openInputMonitoringSettings)),
            ("Microphone…", #selector(openMicrophoneSettings)),
            ("Keyboard (Fn key behaviour)…", #selector(openKeyboardSettings))
        ] {
            let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            entry.target = self
            permissions.addItem(entry)
        }
        let permissionsItem = NSMenuItem(title: "Open System Settings", action: nil, keyEquivalent: "")
        permissionsItem.submenu = permissions
        menu.addItem(permissionsItem)

        let request = NSMenuItem(
            title: "Ask For Permissions Again…",
            action: #selector(requestPermissions),
            keyEquivalent: ""
        )
        request.target = self
        menu.addItem(request)

        let log = NSMenuItem(title: "Reveal Log File…", action: #selector(revealLogFile), keyEquivalent: "")
        log.target = self
        menu.addItem(log)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit LocalFlow", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    private func render(state: DictationController.State) {
        statusItem?.button?.image = Self.icon(for: state)
        switch state {
        case .idle:
            statusLine.title = readyDescription
        case .recording(let locked):
            statusLine.title = locked ? "Hands-free — Esc to cancel" : "Listening…"
        case .transcribing:
            statusLine.title = "Transcribing…"
        }
    }

    private var readyDescription: String {
        let trigger = Settings.shared.usesFn ? "Fn" : "Ctrl+Option"
        return "Ready — hold \(trigger) to dictate"
    }

    private static func icon(for state: DictationController.State) -> NSImage? {
        let name: String
        switch state {
        case .idle: name = "waveform"
        case .recording: name = "waveform.circle.fill"
        case .transcribing: name = "ellipsis.circle"
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "LocalFlow")
        image?.isTemplate = true
        return image
    }

    private static func truncate(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count <= 48 ? flat : String(flat.prefix(48)) + "…"
    }

    // MARK: - Hotkey mode and permissions

    /// Fn on third-party keyboards is handled in the keyboard's own firmware and
    /// never reaches macOS, so switch to Ctrl+Option automatically rather than
    /// leaving push-to-talk dead.
    private func chooseHotkeyMode() {
        let keyboards = KeyboardWatch.scan()
        if Settings.shared.usesFn, keyboards.hasExternalNonApple {
            Settings.shared.hotkeyMode = "ctrlOpt"
            Log.write("External keyboard detected (\(keyboards.names.joined(separator: ", "))) "
                      + "— switched trigger to Ctrl+Option")
            notify(
                title: "LocalFlow switched to Ctrl+Option",
                body: "Fn is not reported by \(keyboards.names.first ?? "your keyboard"). "
                    + "Hold Ctrl+Option to dictate."
            )
        }
        hotkeys.mode = Settings.shared.hotkeyMode
    }

    /// Ask macOS for the two permissions we cannot grant ourselves.
    ///
    /// This matters for usability, not just correctness: an app only appears in
    /// the Accessibility / Input Monitoring lists once it has *asked*. Calling
    /// these puts LocalFlow in both lists with a ready-to-flip switch, instead
    /// of leaving the user to hunt for the app with the "+" button.
    @objc private func requestPermissions() {
        if !AXIsProcessTrusted() {
            // kAXTrustedCheckOptionPrompt is an imported global var, which
            // Swift 6 refuses to touch across isolation domains. The literal
            // key is stable API.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            Log.write("Requested Accessibility permission (system prompt shown)")
        }
        if !CGPreflightListenEventAccess() {
            CGRequestListenEventAccess()
            Log.write("Requested Input Monitoring permission (system prompt shown)")
        }
    }

    private func startEventTap() {
        let accessibility = AXIsProcessTrusted()
        let inputMonitoring = CGPreflightListenEventAccess()
        Log.write("Accessibility: \(accessibility), Input Monitoring: \(inputMonitoring)")

        requestPermissions()

        if hotkeys.start() {
            Log.write("Event tap active (mode \(hotkeys.mode))")
        } else {
            Log.write("Event tap creation FAILED — permission missing")
        }
        render(state: .idle)
    }

    private func refreshWarnings() {
        var warnings: [String] = []

        if !AXIsProcessTrusted() {
            warnings.append("⚠︎ Grant Accessibility — needed to type text")
        }
        if !CGPreflightListenEventAccess() {
            warnings.append("⚠︎ Grant Input Monitoring — needed for the hotkey")
        }
        if !hotkeys.isRunning {
            warnings.append("⚠︎ Hotkey listener is not running")
        }
        if Settings.shared.usesFn, !KeyboardWatch.fnIsFree {
            warnings.append("⚠︎ Set Keyboard → “Press 🌐 key to” → Do Nothing")
        }

        if let first = warnings.first {
            warningLine.title = first
            warningLine.isHidden = false
            statusItem?.button?.image = NSImage(
                systemSymbolName: "exclamationmark.triangle.fill",
                accessibilityDescription: "Setup needed"
            )
        } else {
            warningLine.isHidden = true
            render(state: controller.state)
        }

        // Only log on a change. This used to log every poll, which by itself
        // cost measurable idle CPU.
        if warnings != lastWarnings {
            lastWarnings = warnings
            Log.write(warnings.isEmpty
                ? "Setup complete — all permissions granted"
                : "Setup warnings: \(warnings.joined(separator: " | "))")
        }

        // Permission grants land asynchronously after the user flips a switch
        // in System Settings, so keep re-checking while anything is missing.
        // Stops entirely once everything is granted, so idle CPU returns to 0.
        if !warnings.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self else { return }
                if !self.hotkeys.isRunning { self.hotkeys.start() }
                self.refreshWarnings()
            }
        }
    }

    private func notify(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Actions

    @objc private func pasteLast() { controller.handle(.pasteLast) }
    @objc private func openSettings() { settingsWindow.show() }
    @objc private func openNotes() { notesWindow.show() }

    /// Ten seconds of both capture paths, reported plainly. Needed because the
    /// System Audio Recording permission cannot be queried — the only way to
    /// know it was granted is to capture and look at the samples.
    @objc private func testCapture() {
        let waiting = NSAlert()
        waiting.messageText = "Testing audio capture"
        waiting.informativeText = """
            Listening for 10 seconds. Say something, and play a video or some \
            music so there is system audio to capture too.

            The result will appear here and in the log.
            """
        waiting.addButton(withTitle: "Start")
        waiting.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard waiting.runModal() == .alertFirstButtonReturn else { return }

        NotesFMCaptureTest.runInApp { text in
            let result = NSAlert()
            result.messageText = "Audio capture result"
            result.informativeText = text
            result.addButton(withTitle: "OK")
            result.addButton(withTitle: "Open Permission Settings")
            NSApp.activate(ignoringOtherApps: true)
            if result.runModal() == .alertSecondButtonReturn {
                self.open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            }
        }
    }
    /// One microphone, two features that both want it.
    ///
    /// The guard used to run only one way — a meeting refused to start while a
    /// dictation was in progress, but nothing stopped a dictation once a meeting
    /// was under way. Holding Fn mid-meeting then opened a second engine on the
    /// same device and typed the user's own words into whatever app was in front,
    /// while the meeting recorded them again as "You".
    private func blockedByMeeting(_ action: HotkeyManager.Action) -> Bool {
        guard meeting.isActive else { return false }
        switch action {
        case .holdBegan, .lockHandsFree:
            // Silent. Fn going down is also the first half of Fn+R and Fn+P, and
            // telling someone dictation is off when they were reaching for the
            // stop hotkey would be a message about nothing.
            return true
        case .holdEnded:
            // Only here is it certain the hold was meant as dictation: a chord
            // suppresses the release entirely, so reaching this point means Fn was
            // pressed and let go with no letter in between.
            controller.flash("Meeting recording — dictation is off")
            return true
        case .toggleHandsFree:
            controller.flash("Meeting recording — dictation is off")
            return true
        case .cancel, .pasteLast, .toggleMeeting, .togglePause:
            return false
        }
    }

    @objc private func toggleMeetingFromMenu() { Task { await toggleMeeting() } }
    @objc private func togglePauseFromMenu() { Task { await togglePause() } }
    @objc private func showMeetingHUD() { meetingHUD.show() }

    private func togglePause() async {
        guard meeting.isActive else { return }
        await meeting.togglePause()
        renderMeetingState()
    }

    private func toggleMeeting() async {
        if meeting.isActive {
            await meeting.stop()
        } else {
            guard !controller.isRecordingNow else {
                // One microphone, two features that both want it. Dictation is
                // the shorter-lived of the two, so the meeting waits rather than
                // stealing the mic out from under a sentence in progress.
                notify(title: "NotesFM", body: "Finish dictating first, then press Fn+R.")
                return
            }
            meetingHUD.show()
            await meeting.start()
            renderMeetingState()
            if meeting.state == .idle { meetingHUD.hide() }
        }
        renderMeetingState()
    }

    private func renderMeetingState() {
        meetingLine.title = meeting.isActive ? "Stop Meeting  (Fn+R)" : "Start Meeting  (Fn+R)"
        pauseLine.title = meeting.isPaused ? "Resume Meeting  (Fn+P)" : "Pause Meeting  (Fn+P)"
        pauseLine.isHidden = !meeting.isActive
        hudLine.isHidden = !meeting.isActive
    }
    @objc private func openSetup() { setupWindow.show() }

    /// Show the guide on a first launch, or on any launch where a permission is
    /// still missing and the user has not already chosen to skip it. Someone who
    /// has everything granted never sees it.
    private func presentSetupIfNeeded() {
        // --setup forces the guide open regardless of state. Useful for testing
        // the window on a machine where everything is already granted.
        if CommandLine.arguments.contains("--setup") {
            setupWindow.show()
            return
        }
        guard !SetupWindowController.isComplete else {
            Settings.shared.hasCompletedSetup = true
            return
        }
        guard !Settings.shared.hasCompletedSetup else { return }
        setupWindow.onFinished = { [weak self] in
            self?.startEventTap()
            self?.refreshWarnings()
        }
        setupWindow.show()
    }

    @objc private func openRelevantSettings() {
        if !AXIsProcessTrusted() { openAccessibilitySettings() }
        else if !CGPreflightListenEventAccess() { openInputMonitoringSettings() }
        else { openKeyboardSettings() }
    }

    @objc private func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }
    @objc private func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }
    @objc private func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }
    @objc private func openKeyboardSettings() {
        open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }

    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func revealLogFile() {
        NSWorkspace.shared.selectFile(
            Log.fileURL.path,
            inFileViewerRootedAtPath: Log.fileURL.deletingLastPathComponent().path
        )
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
