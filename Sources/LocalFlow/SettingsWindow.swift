import AppKit
import ServiceManagement
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
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var ollamaReachable: Bool? = nil
    @State private var historyCount = History.count()

    private let microphones = AudioDevices.inputs()

    var body: some View {
        TabView {
            hotkeysTab.tabItem { Text("Hotkeys") }
            speechTab.tabItem { Text("Speech") }
            cleanupTab.tabItem { Text("Cleanup") }
            generalTab.tabItem { Text("General") }
        }
        .padding(16)
        .frame(width: 520, height: 620)
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
