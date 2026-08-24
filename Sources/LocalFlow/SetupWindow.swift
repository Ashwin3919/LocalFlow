import AppKit
import AVFoundation

/// First-run permission guide.
///
/// macOS deliberately gives no API to grant Accessibility or Input Monitoring —
/// the user must flip those switches themselves, and nothing can shortcut it.
/// The most an app can do is ask for each one at the right moment, deep-link
/// straight to the correct pane, and show live status so it is obvious when a
/// step has actually taken effect. That is all this window does.
///
/// Written in plain AppKit rather than SwiftUI on purpose: this window opens on
/// first launch for every new user, and importing SwiftUI costs roughly 20 MB
/// of resident memory that never comes back.
@MainActor
final class SetupWindowController: NSObject {
    private var window: NSWindow?
    private var rows: [PermissionRow] = []
    private var timer: Timer?
    private var doneButton: NSButton?
    private var summary: NSTextField?

    var onFinished: (() -> Void)?

    /// True when every permission the app cannot function without is granted.
    static var isComplete: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            && AXIsProcessTrusted()
            && CGPreflightListenEventAccess()
    }

    func show() {
        if window == nil { build() }
        refresh()
        startPolling()
        // An accessory (LSUIElement) app cannot reliably front a window or
        // surface a microphone TCC prompt: both need the app to be a regular,
        // activatable app. Promote for the life of this window — otherwise the
        // Microphone button's requestAccess never presents its dialog — and drop
        // back to accessory on close so the Dock icon does not linger.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        stopPolling()
        window?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Construction

    private func build() {
        let width: CGFloat = 520

        let title = NSTextField(labelWithString: "Welcome to LocalFlow")
        title.font = .systemFont(ofSize: 22, weight: .semibold)

        let blurb = NSTextField(wrappingLabelWithString: """
            Hold the Fn key, speak, let go — your words appear in whatever app \
            you are using. Everything happens on this Mac; nothing is uploaded.

            macOS requires you to grant these by hand. No app can do it for you, \
            so this window walks you through them and ticks each one off as it \
            takes effect. The last two are optional.
            """)
        blurb.font = .systemFont(ofSize: 12.5)
        blurb.textColor = .secondaryLabelColor

        rows = [
            PermissionRow(
                name: "Microphone",
                why: "To hear you. The orange dot appears only while you dictate.",
                tccService: "Microphone",
                check: { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized },
                act: {
                    if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { granted in
                            Log.write("Microphone permission \(granted ? "granted" : "denied")")
                        }
                    } else {
                        Self.open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                    }
                }
            ),
            PermissionRow(
                name: "Accessibility",
                why: "To place text into the app you are typing in.",
                // The TCC service name tccutil uses for this permission. Present so
                // the row can offer a self-heal when the switch is on but the tick
                // never turns green — see PermissionRow.resetTapped.
                tccService: "Accessibility",
                check: { AXIsProcessTrusted() },
                act: {
                    // Prompting first makes LocalFlow appear in the list with a
                    // switch already waiting, instead of the user hunting for +.
                    _ = AXIsProcessTrustedWithOptions(
                        ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                    )
                    Self.open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                }
            ),
            PermissionRow(
                name: "Input Monitoring",
                why: "To notice when you hold the Fn key, even in another app.",
                tccService: "ListenEvent",
                check: { CGPreflightListenEventAccess() },
                act: {
                    _ = CGRequestListenEventAccess()
                    Self.open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
                }
            ),
            PermissionRow(
                name: "System Audio Recording",
                why: "Only for NotesFM meetings — so other people in a call can be transcribed.",
                optional: true,
                // There is no API to query this one, so it cannot show a real
                // tick. It opens the right pane and says so rather than pretending.
                check: { false },
                act: {
                    Self.open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
                }
            ),
            PermissionRow(
                name: "Fn key set to “Do Nothing”",
                why: "Otherwise Fn opens an emoji picker or switches input source instead.",
                optional: true,
                check: { !Settings.shared.usesFn || KeyboardWatch.fnIsFree },
                act: {
                    Self.open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
                }
            )
        ]

        let summary = NSTextField(wrappingLabelWithString: "")
        summary.font = .systemFont(ofSize: 12, weight: .medium)
        self.summary = summary

        let done = NSButton(title: "Start Using LocalFlow", target: self, action: #selector(finish))
        done.bezelStyle = .push
        done.keyEquivalent = "\r"
        doneButton = done

        let later = NSButton(title: "Later", target: self, action: #selector(dismiss))
        later.bezelStyle = .push

        let buttons = NSStackView(views: [later, done])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [title, blurb] + rows.map(\.view) + [summary, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        // summary lives in `stack`, not in `buttons`; setCustomSpacing raises an
        // exception when the view is not its own arranged subview, and that thrown
        // exception is what silently aborted build() so the window never appeared.
        stack.setCustomSpacing(20, after: summary)

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            blurb.widthAnchor.constraint(equalToConstant: width - 48),
            summary.widthAnchor.constraint(equalToConstant: width - 48)
        ])
        for row in rows {
            row.view.widthAnchor.constraint(equalToConstant: width - 48).isActive = true
        }
        buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -24).isActive = true

        let window = NSWindow(contentRect: .zero,
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "LocalFlow Setup"
        window.contentView = container
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
    }

    // MARK: - Live status

    /// Poll rather than observe: there is no notification for a TCC change, and
    /// a one-second tick costs nothing while a single window is on screen.
    private func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        rows.forEach { $0.refresh() }
        let required = rows.filter { !$0.optional }
        let granted = required.filter { $0.isGranted }.count
        let complete = granted == required.count

        summary?.stringValue = complete
            ? "All set. Hold Fn anywhere and start talking."
            : "\(granted) of \(required.count) granted — this updates by itself, no need to relaunch."
        summary?.textColor = complete ? .systemGreen : .secondaryLabelColor
        doneButton?.title = complete ? "Start Using LocalFlow" : "Continue Anyway"
    }

    // MARK: - Actions

    @objc private func finish() {
        Settings.shared.hasCompletedSetup = true
        close()
        onFinished?()
    }

    @objc private func dismiss() {
        close()
        onFinished?()
    }

    private static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}

extension SetupWindowController: NSWindowDelegate {
    // The two buttons route through close(); the title-bar close button does not,
    // so drop back to accessory here as well or the Dock icon outlives the window.
    func windowWillClose(_ notification: Notification) {
        stopPolling()
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - One row

/// A status glyph, a name, a reason, and a button that opens the right pane.
@MainActor
private final class PermissionRow {
    let name: String
    let optional: Bool
    /// The service name tccutil keys this permission under, or nil if it has none
    /// (the Fn-key row is a keyboard setting, not a TCC grant). When present, the
    /// row can clear a stale entry itself instead of needing a hand at a terminal.
    private let tccService: String?
    private let check: () -> Bool
    private let act: () -> Void

    private(set) var isGranted = false
    /// Set the first time the user taps the primary button. The reset affordance
    /// only appears after this, so it never greets someone who has not yet tried.
    private var hasAttempted = false

    let view = NSStackView()
    private let glyph = NSTextField(labelWithString: "○")
    private let button: NSButton
    private let resetButton: NSButton

    init(name: String,
         why: String,
         optional: Bool = false,
         tccService: String? = nil,
         check: @escaping () -> Bool,
         act: @escaping () -> Void) {
        self.name = name
        self.optional = optional
        self.tccService = tccService
        self.check = check
        self.act = act

        button = NSButton(title: "Open", target: nil, action: nil)
        button.bezelStyle = .push
        button.controlSize = .small

        resetButton = NSButton(title: "Reset & retry", target: nil, action: nil)
        resetButton.bezelStyle = .push
        resetButton.controlSize = .small
        resetButton.isHidden = true
        resetButton.toolTip = "Switched it on but the tick is still grey? macOS is "
            + "probably holding a stale entry from an older build. This clears it "
            + "and asks again — the same fix, without a terminal."

        glyph.font = .systemFont(ofSize: 15, weight: .bold)
        glyph.widthAnchor.constraint(equalToConstant: 18).isActive = true

        let heading = NSTextField(labelWithString: optional ? "\(name) — optional" : name)
        heading.font = .systemFont(ofSize: 13, weight: .medium)

        let reason = NSTextField(labelWithString: why)
        reason.font = .systemFont(ofSize: 11.5)
        reason.textColor = .secondaryLabelColor

        let text = NSStackView(views: [heading, reason])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        view.orientation = .horizontal
        view.alignment = .centerY
        view.spacing = 10
        view.setViews([glyph, text], in: .leading)
        view.setViews([resetButton, button], in: .trailing)

        button.target = self
        button.action = #selector(tapped)
        resetButton.target = self
        resetButton.action = #selector(resetTapped)
    }

    @objc private func tapped() {
        hasAttempted = true
        act()
    }

    /// The self-heal the user otherwise needs a terminal for. `tccutil reset`
    /// clears this app's stored decision for one service, so the next request
    /// lands on the current signature instead of a stale one, and the tick can
    /// finally turn green. Resetting one's own bundle needs no admin rights.
    @objc private func resetTapped() {
        guard let tccService else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", tccService, "com.localflow.app"]
        do {
            try task.run()
            task.waitUntilExit()
            Log.write("Reset TCC \(tccService) for com.localflow.app (setup self-heal)")
        } catch {
            Log.write("tccutil reset \(tccService) failed: \(error)")
        }
        // Re-request straight away so the fresh prompt/pane is right there.
        act()
    }

    func refresh() {
        isGranted = check()
        glyph.stringValue = isGranted ? "●" : "○"
        glyph.textColor = isGranted ? .systemGreen : .tertiaryLabelColor
        button.isHidden = isGranted
        // Only offer the reset once someone has tried and is still stuck, and only
        // for a permission that actually has a TCC entry to clear.
        resetButton.isHidden = !(tccService != nil && !isGranted && hasAttempted)
    }
}
