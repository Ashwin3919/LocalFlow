import AppKit
import SwiftUI

/// The panel shown while a meeting is being recorded.
///
/// A meeting is not like dictation: it runs for an hour, so the feedback has to
/// be a window you can glance at and type into, not a transient pill. It stays
/// out of the way in a corner and never takes focus, because the user is in a
/// call in another app the whole time.
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
        let panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.title = "NotesFM"
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.setFrameAutosaveName("NotesFMHUD")
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
                Button("Add", action: commitNote)
                    .disabled(note.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Button(role: .destructive) {
                Task { await session.stop() }
            } label: {
                Label("Stop and Save", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
        .padding(14)
        .frame(minWidth: 320, minHeight: 260)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(session.isRunning ? Color.red : Color.secondary)
                .frame(width: 8, height: 8)
            Text(NotesFM.timestamp(session.elapsed))
                .font(.system(.title3, design: .monospaced))
                .monospacedDigit()
            Spacer()
            Text(session.state == .stopping ? "Saving…" : "Recording")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                    Text("Listening…")
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
