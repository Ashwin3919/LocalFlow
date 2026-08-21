import AppKit
import CoreGraphics

/// All global keyboard handling, on a single `CGEventTap`.
///
/// Two things matter here and are easy to get wrong:
///
///  * **Fn never produces a keyDown.** It only shows up as a `flagsChanged`
///    event with the `.maskSecondaryFn` bit set, so it is tracked as a modifier
///    transition, not a key press.
///  * **macOS silently disables a tap whose callback is slow.** The callback
///    below does nothing but classify the event and hand it to a background
///    queue, and `.tapDisabledByTimeout` / `.tapDisabledByUserInput` are
///    handled by re-enabling the tap.
final class HotkeyManager: @unchecked Sendable {
    enum Action: Sendable {
        case holdBegan
        case holdEnded(duration: TimeInterval)
        case toggleHandsFree
        case toggleMeeting
        case togglePause
        case lockHandsFree
        case cancel
        case pasteLast
    }

    private enum Keycode {
        static let space: Int64 = 49
        static let escape: Int64 = 53
        static let r: Int64 = 15
        static let p: Int64 = 35
        static let v: Int64 = 9
    }

    private let workQueue = DispatchQueue(
        label: "com.localflow.hotkeys",
        qos: .userInteractive
    )

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Modifier state, only touched from the tap callback thread.
    private var triggerIsDown = false
    private var triggerDownAt: TimeInterval = 0
    private var lastTriggerUpAt: TimeInterval = 0
    private var tapChainCount = 0
    /// Set when a chord like Fn+R fired during the current hold, so releasing the
    /// trigger does not then look like the end of a dictation.
    private var chordFiredDuringHold = false

    /// Set by the owner so Esc is only swallowed while we are actually recording.
    var isRecording: (@Sendable () -> Bool)?
    var onAction: (@Sendable (Action) -> Void)?

    /// "fn" or "ctrlOpt". Read on the callback thread, written from main; a
    /// stale read for one keystroke after a settings change is harmless.
    var mode: String = Settings.shared.hotkeyMode

    // MARK: - Lifecycle

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }

        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        return true
    }

    func stop() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    var isRunning: Bool {
        guard let tap = eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    // MARK: - Event classification

    /// Returns true when the event should be consumed (not forwarded).
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            Log.write("Event tap was disabled by the system — re-enabled")
            return false
        }

        // Never react to the Cmd+V we synthesize ourselves.
        if event.getIntegerValueField(.eventSourceUserData) == TextInserter.syntheticMarker {
            return false
        }

        let flags = event.flags
        switch type {
        case .flagsChanged:
            handleFlags(flags)
            return false

        case .keyDown:
            return handleKeyDown(event.getIntegerValueField(.keyboardEventKeycode), flags: flags)

        default:
            return false
        }
    }

    private func triggerHeld(in flags: CGEventFlags) -> Bool {
        if mode == "fn" {
            return flags.contains(.maskSecondaryFn)
        }
        return flags.contains(.maskControl)
            && flags.contains(.maskAlternate)
            && !flags.contains(.maskCommand)
    }

    private func handleFlags(_ flags: CGEventFlags) {
        let isDown = triggerHeld(in: flags)
        guard isDown != triggerIsDown else { return }
        triggerIsDown = isDown
        let now = ProcessInfo.processInfo.systemUptime

        if isDown {
            // A second press soon after the previous release, while a recording
            // is still running, means "lock into hands-free".
            if now - lastTriggerUpAt < 0.4, isRecording?() == true {
                tapChainCount += 1
                if tapChainCount >= 1 {
                    emit(.lockHandsFree)
                    triggerDownAt = now
                    return
                }
            } else {
                tapChainCount = 0
            }
            triggerDownAt = now
            chordFiredDuringHold = false
            emit(.holdBegan)
        } else {
            lastTriggerUpAt = now
            // Fn going down always emits `.holdBegan`, because Fn produces no
            // keyDown of its own and there is no way to know yet whether a letter
            // is coming. If one did come, this hold belonged to that chord and
            // never to dictation, so the release must not be reported as the end
            // of a phrase — otherwise Fn+R both blocked the meeting it was asking
            // for and typed whatever it heard into the focused app.
            if chordFiredDuringHold {
                chordFiredDuringHold = false
                return
            }
            emit(.holdEnded(duration: now - triggerDownAt))
        }
    }

    private func handleKeyDown(_ keycode: Int64, flags: CGEventFlags) -> Bool {
        // Cmd+Ctrl+V — paste last transcript.
        if keycode == Keycode.v,
           flags.contains(.maskCommand),
           flags.contains(.maskControl),
           !flags.contains(.maskAlternate) {
            emit(.pasteLast)
            return true
        }

        // Trigger + R — start or stop a NotesFM meeting. A meeting is a separate
        // mode from dictation rather than a variation of it: it captures system
        // audio too, runs for hours, and writes to a file instead of typing.
        if keycode == Keycode.r, triggerHeld(in: flags), !flags.contains(.maskCommand) {
            fireChord(.toggleMeeting)
            return true
        }

        // Trigger + P — pause or resume the meeting. Worth a hotkey of its own:
        // the reason to pause is usually that someone is about to say something
        // off the record, and that is not a moment to go hunting for a window.
        if keycode == Keycode.p, triggerHeld(in: flags), !flags.contains(.maskCommand) {
            fireChord(.togglePause)
            return true
        }

        // Trigger + Space — hands-free toggle.
        if keycode == Keycode.space, triggerHeld(in: flags) {
            fireChord(.toggleHandsFree)
            return true
        }

        // Esc — cancel, but only swallow it when there is something to cancel.
        if keycode == Keycode.escape, isRecording?() == true {
            emit(.cancel)
            return true
        }

        return false
    }

    /// A chord pressed while the trigger is held. Marks the hold as spoken for so
    /// the eventual release is not mistaken for the end of a dictation.
    private func fireChord(_ action: Action) {
        chordFiredDuringHold = true
        emit(action)
    }

    private func emit(_ action: Action) {
        let handler = onAction
        workQueue.async { handler?(action) }
    }
}

private let hotkeyCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
    if manager.handle(type: type, event: event) {
        return nil
    }
    return Unmanaged.passUnretained(event)
}
