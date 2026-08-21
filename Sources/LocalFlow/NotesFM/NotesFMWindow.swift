import AppKit
import SwiftUI

/// What the library is currently pointed at.
///
/// Selection lives outside the view tree so `show(selecting:)` can aim the
/// window at a note without rebuilding it. A recording that has just finished
/// wants to open straight to its own page, and that happens while the window may
/// already exist with its own state.
@MainActor
final class NotesFMSelection: ObservableObject {
    @Published var noteID: String?
}

/// Single meetings library window, hosted SwiftUI inside a plain NSWindow.
/// The app is an accessory app, so the window has to activate the process
/// explicitly or it opens behind everything.
@MainActor
final class NotesFMWindowController {
    private var window: NSWindow?
    private let selection = NotesFMSelection()

    func show() {
        present()
    }

    /// Opens the library with one note already showing.
    func show(selecting id: String) {
        selection.noteID = id
        present()
    }

    /// Shows the folder the markdown files actually live in, for the user who
    /// would rather work in Finder and their own editor.
    func revealLibrary() {
        let root = MeetingStore.shared.root
        // `open` fails if the folder was never created; selecting it in Finder
        // at least lands the user in the right neighbourhood.
        if !NSWorkspace.shared.open(root) {
            NSWorkspace.shared.activateFileViewerSelecting([root])
        }
    }

    // MARK: - Window

    private func present() {
        // Files can change on disk while the window is closed — the user editing
        // a note in their own editor, or a recording finishing — so every open
        // starts from what is actually there.
        MeetingStore.shared.reload()

        if window == nil {
            let view = NotesFMLibraryView(store: MeetingStore.shared, selection: selection)
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Meetings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 1000, height: 680))
            window.contentMinSize = NSSize(width: 720, height: 420)
            window.center()
            // Remembering the frame is free here and saves the user re-sizing a
            // three-pane window every single time they open it.
            window.setFrameAutosaveName("NotesFMLibrary")
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
