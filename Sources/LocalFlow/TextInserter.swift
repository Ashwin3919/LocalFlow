import AppKit
import ApplicationServices

/// Puts transcribed text into whatever app owns the keyboard focus.
///
/// Two paths, in order of preference:
///   1. Accessibility: set `kAXSelectedTextAttribute` on the focused element.
///      No pasteboard involvement, no synthetic keys, no timing games.
///      Works in native AppKit text fields (Notes, Mail, TextEdit, Xcode).
///   2. Pasteboard + synthetic Cmd+V. Required for Electron apps (Slack, VS
///      Code, Cursor), browsers, and terminals, which either do not implement
///      the settable AX attribute or ignore writes to it.
///
/// The original pasteboard contents are saved and restored so dictation never
/// clobbers the user's clipboard.
enum TextInserter {
    /// Marker written into synthesized events so our own event tap can tell
    /// them apart from real key presses.
    static let syntheticMarker: Int64 = 0x1_0CA1_F10E

    private static let virtualKeyV: CGKeyCode = 9

    enum Path: String {
        case accessibility
        case pasteboard
    }

    @discardableResult
    static func insert(_ text: String) -> Path {
        guard !text.isEmpty else { return .accessibility }

        if Settings.shared.preferAccessibilityInsert, insertViaAccessibility(text) {
            Log.write("Inserted via Accessibility (\(text.count) chars)")
            return .accessibility
        }

        insertViaPasteboard(text)
        Log.write("Inserted via pasteboard + Cmd+V (\(text.count) chars)")
        return .pasteboard
    }

    // MARK: - Accessibility path

    private static func insertViaAccessibility(_ text: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focused
        ) == .success, let element = focused as! AXUIElement? else {
            return false
        }

        // Only attempt the write when the element actually advertises the
        // attribute as settable. Some apps return .success for a write that
        // does nothing, which would silently swallow the transcript.
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(
            element, kAXSelectedTextAttribute as CFString, &settable
        ) == .success, settable.boolValue else {
            return false
        }

        let result = AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFString
        )
        return result == .success
    }

    // MARK: - Pasteboard path

    private static func insertViaPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Electron apps and terminals drop the paste if the keystroke arrives
        // before they have observed the new pasteboard generation.
        let delay = Settings.shared.pasteDelay
        Thread.sleep(forTimeInterval: delay)

        waitForModifiersToClear()
        postCommandV()

        // Give the target app time to actually read the pasteboard before we
        // put the user's clipboard back.
        let restoreDelay = max(0.35, delay * 3)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + restoreDelay) {
            restore(saved, to: NSPasteboard.general)
        }
    }

    private static func postCommandV() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalKeyboardEvents, .permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKeyV, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKeyV, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        up?.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// If the user is still holding the dictation hotkey, a synthesized Cmd+V
    /// merges with those physical modifiers and turns into a different
    /// shortcut. Wait a short while for them to let go.
    private static func waitForModifiersToClear() {
        let interesting: CGEventFlags = [
            .maskSecondaryFn, .maskControl, .maskAlternate, .maskShift, .maskCommand
        ]
        for _ in 0..<25 {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.intersection(interesting).isEmpty { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        Log.write("Modifiers still held after 500 ms — pasting anyway")
    }

    // MARK: - Pasteboard save / restore

    private struct SavedItem {
        let payloads: [(NSPasteboard.PasteboardType, Data)]
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [SavedItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            SavedItem(payloads: item.types.compactMap { type in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            })
        }
    }

    private static func restore(_ saved: [SavedItem], to pasteboard: NSPasteboard) {
        guard !saved.isEmpty else {
            pasteboard.clearContents()
            return
        }
        let items: [NSPasteboardItem] = saved.compactMap { saved in
            guard !saved.payloads.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for (type, data) in saved.payloads {
                item.setData(data, forType: type)
            }
            return item
        }
        guard !items.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
    }
}
