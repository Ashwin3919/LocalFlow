import AppKit
import SwiftUI

/// The panel shown while a meeting is being recorded.
///
/// A meeting is not like dictation: it runs for an hour, so the feedback has to
/// be a window you can glance at and type into, not a transient pill. It stays
/// out of the way in a corner and never takes focus, because the user is in a
/// call in another app the whole time.
/// A panel that can take keyboard focus without bringing the app forward.
///
/// `NonActivatingPanel` cannot be reused here. It returns false from
/// `canBecomeKey`, which is correct for the dictation pill — that window must
/// never take focus away from whatever is being typed into — and fatal for this
/// one, because a window that can never become key has no first responder, so
/// its text field silently swallows every keystroke. That is precisely what made
/// "Add a note…" impossible to type into.
///
/// The two properties are separate questions, and the SDK is explicit about it:
/// `NSWindowStyleMaskNonactivatingPanel` "specifies that a panel that does not
/// activate the owning application", while whether the panel can hold keyboard
/// focus is decided by `canBecomeKeyWindow`. Together they give the behaviour a
/// meeting needs — type a note without the call losing the foreground.
final class KeyableMeetingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class MeetingHUDController {
    private var window: NSWindow?
    private let session: MeetingSession

    init(session: MeetingSession) {
        self.session = session
    }

    func show() {
        if window == nil { build() }
        position()
        window?.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func build() {
        let hosting = NSHostingController(rootView: MeetingHUDView(session: session))
        // Resizable, and without `.fullSizeContentView`. Both were mistakes worth
        // naming: a fixed-height panel showing an hour of transcript cannot be
        // made bigger no matter how much the user wants to read, and full-size
        // content puts the timer underneath the close button.
        let panel = KeyableMeetingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 440),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.title = "NotesFM"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentMinSize = NSSize(width: 340, height: 320)
        panel.setContentSize(NSSize(width: 380, height: 440))
        panel.setFrameAutosaveName("NotesFMHUDPanel")
        // Setting the autosave name restores a saved frame, which may have been
        // saved by a build whose window was smaller than this one can legally be.
        // A restored frame below the minimum clips its own controls.
        if panel.contentRect(forFrameRect: panel.frame).height < panel.contentMinSize.height
            || panel.contentRect(forFrameRect: panel.frame).width < panel.contentMinSize.width {
            panel.setContentSize(NSSize(width: 380, height: 440))
        }
        window = panel
    }

    private func position() {
        guard let window, window.frameAutosaveName.isEmpty || window.frame.origin == .zero else { return }
        guard let visible = NSScreen.main?.visibleFrame else { return }
        window.setFrameOrigin(NSPoint(
            x: visible.maxX - window.frame.width - 24,
            y: visible.maxY - window.frame.height - 24
        ))
    }
}

private struct MeetingHUDView: View {
    @ObservedObject var session: MeetingSession
    @State private var note = ""
    @FocusState private var noteFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let warning = session.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            transcript

            HStack(spacing: 6) {
                TextField("Add a note…", text: $note)
                    .textFieldStyle(.roundedBorder)
                    .focused($noteFocused)
                    .onSubmit(commitNote)
                    .disabled(!session.isActive)
                Button("Add", action: commitNote)
                    .disabled(note.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            HStack(spacing: 8) {
                // Not focused automatically. The user is in a call in another app,
                // and stealing their keystrokes into this field the moment the
                // window appears would be worse than one click.
                Button {
                    Task { await session.togglePause() }
                } label: {
                    Label(
                        session.isPaused ? "Resume" : "Pause",
                        systemImage: session.isPaused ? "play.fill" : "pause.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .disabled(!session.isActive)

                Button(role: .destructive) {
                    Task { await session.stop() }
                } label: {
                    Label("Stop and Save", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
            }
            .controlSize(.large)
        }
        .padding(14)
        // Only a minimum: the panel is resizable now, so the content has to be
        // willing to grow into whatever height the user drags it to.
        .frame(minWidth: 320, maxWidth: .infinity, minHeight: 280, maxHeight: .infinity)
    }

    /// The clock stops while paused, so the label has to say why — a frozen timer
    /// with "Recording" next to it is the worst of the possible readings.
    private var status: String {
        switch session.state {
        case .running: "Recording"
        case .paused: "Paused — not recording"
        case .stopping: "Saving…"
        case .idle: "Stopped"
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(session.isRunning ? Color.red : session.isPaused ? Color.orange : Color.secondary)
                .frame(width: 8, height: 8)
            Text(NotesFM.timestamp(session.elapsed))
                .font(.system(.title3, design: .monospaced))
                .monospacedDigit()
            Spacer()
            Text(status)
                .font(.caption)
                .foregroundStyle(session.isPaused ? Color.orange : Color.secondary)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(session.lines.enumerated()), id: \.offset) { index, line in
                        line.view
                            .id(index)
                    }
                    // What the engine has heard but not committed to yet, so the
                    // window is never frozen while someone is mid-sentence.
                    ForEach(Speaker.allCases, id: \.self) { speaker in
                        if let text = session.pending[speaker], !text.isEmpty {
                            Text(text)
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                                .italic()
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .onChange(of: session.lines.count) {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .frame(maxHeight: .infinity)
            .overlay {
                if session.lines.isEmpty && session.pending.isEmpty {
                    Text(session.isPaused ? "Paused" : "Listening…")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func commitNote() {
        session.addNote(note)
        note = ""
    }
}

private extension TranscribedSegment {
    @ViewBuilder var view: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(speaker == .note ? "Note" : speaker.label)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(speaker == .you ? Color.accentColor
                                 : speaker == .note ? Color.orange : Color.secondary)
                .frame(width: 34, alignment: .leading)
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
