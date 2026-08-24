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
            window.contentMinSize = NSSize(width: 860, height: 560)
            window.setContentSize(NSSize(width: 1040, height: 720))
            window.center()
            // Remembering the frame is free here and saves the user re-sizing a
            // three-pane window every single time they open it.
            window.setFrameAutosaveName("NotesFMLibrary")
            // Setting the autosave name restores whatever frame was last saved,
            // including one saved before this window had a third pane to fit. A
            // three-pane window restored too small clips the detail pane, and the
            // Refine button lives at the bottom of it — the user sees a library
            // with its main action missing and no hint that it was ever there.
            let restored = window.contentRect(forFrameRect: window.frame)
            if restored.width < window.contentMinSize.width
                || restored.height < window.contentMinSize.height {
                window.setContentSize(NSSize(width: 1040, height: 720))
                window.center()
            }
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
