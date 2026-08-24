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

        // Land on a meeting, not on an empty pane.
        //
        // With nothing selected the detail column is a "No Meeting Selected"
        // placeholder, and everything that belongs to a meeting — the transcript
        // and the Refine button under it — is simply absent. Somebody opening
        // Meetings to read the call they just finished reads it as the window
        // having lost its contents, and there is nothing on screen to suggest
        // clicking the list would bring them back.
        // `meetings`, not `notes`. Sorting is newest-first with the filename as
        // the tiebreak, and a notes file shares its meeting's start time with a
        // higher stem — so `notes.first` was reliably the refined notes rather
        // than the meeting, and the window opened on a row the list no longer has.
        if selection.noteID == nil
            || !MeetingStore.shared.meetings.contains(where: { $0.id == selection.noteID }) {
            selection.noteID = MeetingStore.shared.meetings.first?.id
        }

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
            // Deliberately not "NotesFMLibrary". That key held a frame saved by
            // an earlier build — 1920×998, filling an external display — and
            // setting the autosave name restores it over the size set above, so
            // the window opened at somebody else's idea of a good size and no
            // amount of fixing the default changed that. Renaming the key is how
            // a saved frame gets retired.
            window.setFrameAutosaveName("NotesFMLibraryWindow")
            // A restored frame can be wrong in two directions: too small for
            // three panes, so the detail column and the Refine button in it get
            // clipped, or saved on a display that is no longer attached.
            let restored = window.contentRect(forFrameRect: window.frame)
            let fits = NSScreen.screens.contains { $0.visibleFrame.intersects(window.frame) }
            if !fits
                || restored.width < window.contentMinSize.width
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
