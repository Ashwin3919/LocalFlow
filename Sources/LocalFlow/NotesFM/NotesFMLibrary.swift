import AppKit
import SwiftUI

// MARK: - Library

/// Three-pane meetings library: folders, meetings, meeting.
///
/// Deliberately shaped like Apple Notes. The layout is the one every Mac user
/// already knows, so nothing here tries to be clever about it.
@MainActor
struct NotesFMLibraryView: View {
    @ObservedObject var store: MeetingStore
    @ObservedObject var selection: NotesFMSelection

    @State private var scope: LibraryScope? = .all
    @State private var query = ""
    @State private var isNamingFolder = false
    @State private var newFolderName = ""

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            meetingList
        } detail: {
            detail
        }
        // Wide enough that all three panes get a usable share. The detail pane is
        // where the transcript and the Refine button live, and it is the one that
        // gets squeezed when this is set too low.
        .frame(minWidth: 820, minHeight: 520)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $scope) {
            Section("Library") {
                sidebarRow(.all, title: "All Meetings", systemImage: "tray.full", count: store.meetings.count)
            }
            if !store.folders.isEmpty {
                Section("Folders") {
                    ForEach(store.folders, id: \.self) { folder in
                        sidebarRow(
                            .folder(folder),
                            title: folder,
                            systemImage: "folder",
                            count: store.meetings.count { $0.folder == folder }
                        )
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 300)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    newFolderName = ""
                    isNamingFolder = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.plain)
                .font(.callout)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .alert("New Folder", isPresented: $isNamingFolder) {
            TextField("Name", text: $newFolderName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { createFolder() }
        } message: {
            Text("Folders are real sub-folders of the meetings folder on disk.")
        }
    }

    private func sidebarRow(
        _ item: LibraryScope,
        title: String,
        systemImage: String,
        count: Int
    ) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text("\(count)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .tag(item)
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        store.createFolder(name)
        scope = .folder(name)
    }

    // MARK: Meeting list

    /// Search runs through the store so it can look inside bodies, not just the
    /// titles that happen to be in memory.
    private var visibleNotes: [MeetingNote] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // `meetings`, not `notes`: a refined meeting is one row with two files
        // behind it, not two rows.
        let matching = trimmed.isEmpty ? store.meetings : store.searchMeetings(trimmed)
        guard case .folder(let folder) = scope else { return matching }
        return matching.filter { $0.folder == folder }
    }

    private var meetingList: some View {
        VStack(spacing: 0) {
            // Which slice is being listed, in the column that lists it. This used
            // to be the window's title, but a `navigationTitle` on this column
            // overwrites the title the window was given, so the titlebar read
            // "All Meetings" and never said what app it belonged to.
            Text(scopeTitle)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 10)
            searchField
            Divider()
            listBody
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
    }

    private var scopeTitle: String {
        switch scope {
        case .folder(let folder): folder
        default: "All Meetings"
        }
    }

    @ViewBuilder
    private var listBody: some View {
        let notes = visibleNotes
        if notes.isEmpty {
            // Filling the column matters: an empty state that shrinks to its own
            // size leaves the rest of the pane unpainted.
            emptyList
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selection.noteID) {
                ForEach(notes) { note in
                    MeetingRow(note: note, hasNotes: store.attachedNotes(for: note) != nil)
                        .tag(note.id)
                        .contextMenu {
                            Button("Reveal in Finder") { store.revealInFinder(note) }
                            Divider()
                            Button("Delete", role: .destructive) {
                                store.delete(note)
                                if selection.noteID == note.id { selection.noteID = nil }
                            }
                        }
                }
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private var emptyList: some View {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView.search(text: query)
        } else if store.notes.isEmpty {
            ContentUnavailableView {
                Label("No Meetings Yet", systemImage: "waveform")
            } description: {
                Text("Press Fn + R to start recording one. Each meeting is saved as "
                     + "a markdown file in \(store.root.lastPathComponent).")
            }
        } else {
            ContentUnavailableView {
                Label("Empty Folder", systemImage: "folder")
            } description: {
                Text("Open a meeting and use the ••• button in the toolbar to move it here.")
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear search")
            }
        }
        .padding(6)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .padding(8)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let note = store.meetings.first(where: { $0.id == selection.noteID }) {
            MeetingDetailView(store: store, note: note, selectedID: $selection.noteID)
                // Identity is the note, so switching meetings starts the editor
                // and its pending save from scratch instead of carrying the
                // previous note's draft across.
                .id(note.id)
        } else {
            ContentUnavailableView {
                Label("No Meeting Selected", systemImage: "doc.text")
            } description: {
                Text("Pick a meeting from the list to read or edit it.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}

/// Which slice of the library the sidebar is pointing at.
private enum LibraryScope: Hashable {
    case all
    case folder(String)
}

// MARK: - List row

@MainActor
private struct MeetingRow: View {
    let note: MeetingNote
    /// Whether Refine has been run on this meeting. Worth a mark in the list: it
    /// is the difference between a meeting you still have to read and one that
    /// has already been written up.
    let hasNotes: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(note.title.isEmpty ? "Untitled" : note.title)
                    .font(.headline)
                    .lineLimit(1)
                if hasNotes {
                    Image(systemName: "wand.and.stars")
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .help("Refined notes have been written for this meeting")
                }
                // Only shown for a notes file left without its meeting — a stray
                // duplicate from the old naming, or a recording deleted from
                // Finder. It stays listed rather than disappearing, because it is
                // still a file with somebody's words in it.
                if note.notesFor != nil {
                    Text("Notes")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }
            HStack(spacing: 6) {
                Text(note.started.formatted(date: .abbreviated, time: .shortened))
                if let duration = NotesFMFormat.duration(note.duration) {
                    Text("·")
                    Text(duration)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(NotesFMFormat.plain(note.snippet))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Detail

@MainActor
private struct MeetingDetailView: View {
    @ObservedObject var store: MeetingStore
    let note: MeetingNote
    @Binding var selectedID: String?

    private enum Mode: Hashable {
        case read
        case raw
    }

    /// Which of the meeting's two files is on screen. The refined notes live in
    /// their own file so a model's rewrite can never replace the recording, but
    /// they are still part of the same meeting, so they are a tab here rather
    /// than another row in the list.
    private enum Document: Hashable {
        case transcript
        case notes
    }

    @State private var mode: Mode = .read
    @State private var document: Document = .transcript
    @State private var draftTitle: String
    @State private var draftBody: String
    @State private var draftNotes: String
    @State private var pendingSave: Task<Void, Never>?
    @State private var isConfirmingDelete = false
    @State private var isConfirmingRefine = false
    @State private var isRefining = false
    @State private var refineError: String?
    @FocusState private var titleFocused: Bool

    init(store: MeetingStore, note: MeetingNote, selectedID: Binding<String?>) {
        _store = ObservedObject(wrappedValue: store)
        self.note = note
        _selectedID = selectedID
        _draftTitle = State(initialValue: note.title)
        _draftBody = State(initialValue: note.body)
        _draftNotes = State(initialValue: store.attachedNotes(for: note)?.body ?? "")
        // Somebody who has already refined a meeting opened it to read the notes,
        // not to re-read the transcript they just refined.
        _document = State(initialValue: store.attachedNotes(for: note) == nil ? .transcript : .notes)
    }

    /// The notes file for this meeting as it stands on disk, or `nil` if Refine
    /// has never been run on it.
    private var notesNote: MeetingNote? { store.attachedNotes(for: note) }
    private var hasNotes: Bool { notesNote != nil }

    /// The document actually on screen. Every read of the body goes through this
    /// so the read view, the editor and the character count can never disagree
    /// about which of the two files is being shown.
    private var shownText: Binding<String> {
        showingNotes ? $draftNotes : $draftBody
    }

    /// `document` alone is not enough: deleting the notes leaves it pointing at a
    /// file that is gone, and the pane would render an empty editor for it.
    private var showingNotes: Bool { document == .notes && hasNotes }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .toolbar {
            // The same action as the footer button, in the titlebar. Two places
            // rather than one because the footer is the bottom of a pane that
            // shares its width with two others, and this one cannot be squeezed,
            // scrolled past, or clipped by a window restored too small.
            ToolbarItem {
                Button {
                    startRefine()
                } label: {
                    Label(refineTitle, systemImage: "wand.and.stars")
                }
                .disabled(refineDisabled)
                .help(refineHelp)
            }
            ToolbarItem {
                Button {
                    store.revealInFinder(note)
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .help("Reveal in Finder")
            }
            ToolbarItem {
                actionsMenu
            }
        }
        // Switching selection must not silently drop the last second of typing
        // that the debounce is still holding. The guard matters: this view is
        // also torn down when a rename or a move retires the note's id, and
        // writing then would resurrect the file at its old path.
        .onDisappear {
            guard store.notes.contains(where: { $0.id == note.id }) else { return }
            saveNow()
            commitTitle()
        }
        .confirmationDialog(
            "Delete “\(note.title)”?",
            isPresented: $isConfirmingDelete
        ) {
            Button("Delete", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(hasNotes
                 ? "The meeting's markdown file and its notes are moved to the Trash."
                 : "The meeting's markdown file is moved to the Trash.")
        }
        // Refining again overwrites notes somebody may have edited by hand, so it
        // asks. The first refine never does — there is nothing to lose yet.
        .confirmationDialog(
            "Replace the existing notes?",
            isPresented: $isConfirmingRefine
        ) {
            Button("Refine Again", role: .destructive) { refine() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The transcript is untouched either way. Any edits you made to "
                 + "the notes themselves will be overwritten.")
        }
    }

    // MARK: Refine wording

    private var refineTitle: String {
        hasNotes ? "Refine Again" : "Refine into Meeting Notes"
    }

    private var refineDisabled: Bool {
        isRefining || draftBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var refineCaption: String {
        if isRefining { return "Codex is working. A long meeting can take a couple of minutes." }
        if hasNotes {
            return "Sends the transcript to Codex again and replaces these notes. "
                + "The recording itself is never touched, and nothing else in this app leaves your Mac."
        }
        return "Sends this transcript to Codex. The notes are saved as a new file beside it; "
            + "nothing else in this app leaves your Mac."
    }

    private var refineHelp: String {
        hasNotes
            ? "Run the transcript through the Codex CLI again, replacing these notes"
            : "Rewrite this transcript as meeting notes using the Codex CLI"
    }

    private var actionsMenu: some View {
        Menu {
            Button("Rename") { titleFocused = true }
            Menu("Move to Folder") {
                Button("Top Level") { move(to: nil) }
                    .disabled(note.folder == nil)
                if !store.folders.isEmpty {
                    Divider()
                    ForEach(store.folders, id: \.self) { folder in
                        Button(folder) { move(to: folder) }
                            .disabled(folder == note.folder)
                    }
                }
            }
            Divider()
            Button("Reveal in Finder") { store.revealInFinder(note) }
            if let notesNote {
                Button("Reveal Notes in Finder") { store.revealInFinder(notesNote) }
            }
            Divider()
            if hasNotes {
                Button("Delete Notes", role: .destructive) { deleteNotes() }
            }
            Button("Delete Meeting", role: .destructive) { isConfirmingDelete = true }
        } label: {
            Label("Actions", systemImage: "ellipsis.circle")
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Title", text: $draftTitle)
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
                .focused($titleFocused)
                .onSubmit { commitTitle() }

            HStack(spacing: 6) {
                // Abbreviated, not `.long`. This row shares its width with two
                // segmented controls, and the long form wrapped the date onto a
                // second line, which pushed the whole header taller.
                Text(note.started.formatted(date: .abbreviated, time: .shortened))
                    .lineLimit(1)
                if let duration = NotesFMFormat.duration(note.duration) {
                    Text("·")
                    Text(duration)
                }
                if let folder = note.folder {
                    Text("·")
                    Label(folder, systemImage: "folder")
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                // Only when there is something to switch to. A two-way control
                // with one reachable side is worse than no control.
                if hasNotes {
                    Picker("Document", selection: $document) {
                        Text("Notes").tag(Document.notes)
                        Text("Transcript").tag(Document.transcript)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 155)
                    // Both files are editable, so leaving one is the moment to be
                    // sure it reached disk before the other is shown.
                    .onChange(of: document) { _, _ in saveNow() }
                }
                Picker("Mode", selection: $mode) {
                    Text("Read").tag(Mode.read)
                    Text("Raw").tag(Mode.raw)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 100)
                // Leaving the editor is a natural moment to be sure the file on
                // disk matches what is on screen.
                .onChange(of: mode) { _, new in
                    if new == .read { saveNow() }
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: Refine

    /// The one action in this app that sends anything off the machine, so it is a
    /// button somebody presses, never something that happens on its own — and it
    /// says where the text goes right next to itself rather than in a settings
    /// pane nobody opens.
    private var footer: some View {
        // The caption sits *under* the button rather than beside it. Beside it,
        // a narrow detail pane spends the width on wrapping the sentence and
        // squeezes the button — the one control this pane exists for — down to an
        // ellipsis.
        VStack(alignment: .leading, spacing: 6) {
            Button {
                startRefine()
            } label: {
                HStack(spacing: 6) {
                    if isRefining {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "wand.and.stars")
                    }
                    Text(isRefining ? "Refining…" : refineTitle)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .controlSize(.large)
            .disabled(refineDisabled)
            .help(refineHelp)

            // No `fixedSize(vertical:)` here, and this is the whole reason the
            // window was unusable. It forces the text to its wrapped height,
            // which becomes the footer's *minimum* height; measured at the
            // narrowest width the detail column is allowed, a sentence this long
            // wraps far enough to make the pane's minimum taller than the window.
            // SwiftUI then lays the split view out at that minimum and centres
            // the overflow, so the sidebar's rows sat above the titlebar and this
            // button sat 1029pt below the sill. `lineLimit` lets the caption
            // wrap as far as it needs while keeping the floor bounded.
            if let refineError {
                Label(refineError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.orange)
                    .lineLimit(3)
            } else {
                Text(refineCaption)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// Asks first only when there are notes to lose.
    private func startRefine() {
        guard !isRefining else { return }
        if hasNotes {
            isConfirmingRefine = true
        } else {
            refine()
        }
    }

    private func refine() {
        guard !isRefining else { return }
        // The model must see what is on screen, not what was last debounced.
        saveNow()
        isRefining = true
        refineError = nil

        // Always the transcript, never whichever document happens to be on
        // screen: refining the notes would be refining a refinement.
        let transcript = draftBody
        let title = draftTitle
        let source = note

        Task {
            do {
                let written = try await Refine.notes(from: transcript, title: title)
                isRefining = false
                if store.writeNotes(for: source, body: written) != nil {
                    // Read the body back from the store rather than reusing the
                    // string: the store normalises the trailing newline, and a
                    // draft that differs from disk by one character would look
                    // dirty and schedule a pointless write.
                    draftNotes = store.attachedNotes(for: source)?.body ?? written
                    document = .notes
                    mode = .read
                } else {
                    refineError = "Notes were written but could not be saved."
                }
            } catch {
                isRefining = false
                refineError = error.localizedDescription
                Log.write("Refine failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Body

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .read:
            ScrollView {
                // Renders the draft rather than the saved note so the read view
                // never lags a debounce behind the raw editor.
                MarkdownText(markdown: shownText.wrappedValue)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .textSelection(.enabled)
            .background(Color(nsColor: .textBackgroundColor))
        case .raw:
            TextEditor(text: shownText)
                .font(.system(.body, design: .monospaced))
                .padding(12)
                .background(Color(nsColor: .textBackgroundColor))
                // Two `onChange`es rather than one on `shownText`, because a
                // binding is not Equatable and each document saves to its own file.
                .onChange(of: draftBody) { _, _ in scheduleSave() }
                .onChange(of: draftNotes) { _, _ in scheduleSave() }
        }
    }

    // MARK: Saving

    /// The transcript as it stands on screen, unsaved edits included. Every store
    /// call goes through here so an edit that is still inside the debounce
    /// window is carried along instead of being overwritten by the stale copy.
    private var edited: MeetingNote {
        var updated = note
        updated.body = draftBody
        return updated
    }

    /// The notes file as it stands on screen, or `nil` when there are none.
    private var editedNotes: MeetingNote? {
        guard var updated = notesNote else { return nil }
        updated.body = draftNotes
        return updated
    }

    /// The files whose draft differs from disk. Two documents share one debounce,
    /// so this is what decides which of them a write actually has to touch —
    /// saving the untouched one would rewrite a file for no reason and, worse,
    /// stamp it over an edit made in another editor.
    private func pendingWrites() -> [MeetingNote] {
        var result: [MeetingNote] = []
        if draftBody != note.body { result.append(edited) }
        if let current = notesNote, let editedNotes, editedNotes.body != current.body {
            result.append(editedNotes)
        }
        return result
    }

    /// Typing is a disk write, so it is debounced: every keystroke replaces the
    /// pending write instead of adding one.
    private func scheduleSave() {
        pendingSave?.cancel()
        // Everything the write needs is captured by value now, because the task
        // deliberately outlives the view — closing the window tears the view
        // down without an `onDisappear`, and the last keystrokes still have to
        // reach disk.
        let store = self.store
        let pending = pendingWrites()
        guard !pending.isEmpty else { return }
        pendingSave = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            for file in pending {
                // The file may have been renamed, moved or deleted in the meantime.
                guard store.notes.contains(where: { $0.id == file.id }) else { continue }
                store.save(file)
            }
        }
    }

    private func saveNow() {
        cancelPendingSave()
        for file in pendingWrites() { store.save(file) }
    }

    private func deleteNotes() {
        cancelPendingSave()
        store.deleteNotes(for: note)
        draftNotes = ""
        document = .transcript
    }

    private func cancelPendingSave() {
        pendingSave?.cancel()
        pendingSave = nil
    }

    private func commitTitle() {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // A nameless file is worse than an unchanged one.
            draftTitle = note.title
            return
        }
        guard trimmed != note.title else { return }
        // A rename can move the file, so a pending write to the old path would
        // be a write to a path that no longer exists.
        cancelPendingSave()
        store.rename(edited, to: trimmed)
        followNote()
    }

    private func move(to folder: String?) {
        cancelPendingSave()
        store.move(edited, toFolder: folder)
        followNote()
    }

    private func delete() {
        cancelPendingSave()
        store.delete(note)
        selectedID = nil
    }

    /// The filename stem is the identity, so renaming or moving a note can
    /// retire the id the selection is holding. Re-find the same meeting by when
    /// it started, which nothing in the library can change.
    private func followNote() {
        guard !store.notes.contains(where: { $0.id == note.id }) else { return }
        selectedID = store.notes.first { $0.started == note.started }?.id
    }
}

// MARK: - Markdown

/// Renders markdown with nothing but Foundation.
///
/// `AttributedString(markdown:)` with `.full` gives correct inline styling and
/// tags every block with a `presentationIntent`, but it strips the newlines
/// between blocks and SwiftUI's `Text` ignores those intents entirely — a
/// straight `Text(attributedString)` runs the whole document together on one
/// line. So the intents are turned back into a stack of views here, one per
/// block, which is also what makes headings and block quotes look like
/// headings and block quotes.
@MainActor
private struct MarkdownText: View {
    let markdown: String

    @State private var blocks: [MarkdownBlock] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { block in
                view(for: block)
            }
        }
        // Parsing a long transcript is not free, so it happens when the text
        // changes rather than on every layout pass.
        .task(id: markdown) {
            blocks = MarkdownBlock.parse(markdown)
        }
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block.kind {
        case .heading(let level):
            Text(block.text)
                .font(headingFont(level))
                .padding(.top, level == 1 ? 0 : 6)
        case .paragraph:
            Text(block.text)
        case .quote:
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.tertiary)
                    .frame(width: 3)
                Text(block.text)
                    .italic()
                    .foregroundStyle(.secondary)
            }
        case .bullet(let depth):
            listRow(marker: "•", depth: depth, text: block.text)
        case .numbered(let ordinal, let depth):
            listRow(marker: "\(ordinal).", depth: depth, text: block.text)
        case .code:
            Text(block.text)
                .font(.system(.callout, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        case .rule:
            Divider()
        }
    }

    private func listRow(marker: String, depth: Int, text: AttributedString) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text(text)
        }
        .padding(.leading, CGFloat(max(0, depth - 1)) * 18)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2.weight(.bold)
        case 2: .title3.weight(.semibold)
        default: .headline
        }
    }
}

/// One block-level element of a parsed markdown document.
private struct MarkdownBlock: Identifiable {
    enum Kind: Equatable {
        case paragraph
        case heading(Int)
        case quote
        /// List nesting depth, counted from 1.
        case bullet(Int)
        case numbered(Int, Int)
        case code
        case rule
    }

    let id: Int
    var kind: Kind
    var text: AttributedString

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        // The failure policy above means this practically never throws, but
        // unparseable input must still show the user their own words.
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return [MarkdownBlock(id: 0, kind: .paragraph, text: AttributedString(markdown))]
        }

        var blocks: [MarkdownBlock] = []
        var currentIntent: PresentationIntent?
        var started = false

        for run in parsed.runs {
            var piece = AttributedString(parsed[run.range])
            // A single newline inside a paragraph parses as a soft break whose
            // text is a space. Transcript turns are one per line, so the line
            // structure has to survive.
            if let inline = run.inlinePresentationIntent,
               inline.contains(.softBreak) || inline.contains(.lineBreak) {
                piece = AttributedString("\n")
            }

            let intent = run.presentationIntent
            if started, intent == currentIntent {
                blocks[blocks.count - 1].text += piece
            } else {
                currentIntent = intent
                started = true
                blocks.append(MarkdownBlock(id: blocks.count, kind: kind(of: intent), text: piece))
            }
        }

        return blocks.map {
            var block = $0
            block.text = trimmingTrailingNewlines(block.text)
            return block
        }
    }

    /// `components` runs innermost first, so a list item names its own list
    /// before its ancestors and the count of lists is the nesting depth.
    private static func kind(of intent: PresentationIntent?) -> Kind {
        guard let intent else { return .paragraph }
        var depth = 0
        var ordinal: Int?
        var isOrdered = false

        for component in intent.components {
            switch component.kind {
            case .header(let level): return .heading(level)
            case .codeBlock: return .code
            case .thematicBreak: return .rule
            case .blockQuote: return .quote
            case .listItem(let itemOrdinal):
                if ordinal == nil { ordinal = itemOrdinal }
            case .orderedList:
                depth += 1
                if depth == 1 { isOrdered = true }
            case .unorderedList:
                depth += 1
            default:
                break
            }
        }

        if let ordinal {
            return isOrdered ? .numbered(ordinal, depth) : .bullet(depth)
        }
        return .paragraph
    }

    private static func trimmingTrailingNewlines(_ text: AttributedString) -> AttributedString {
        var trimmed = text
        while let last = trimmed.characters.last, last == "\n" || last == "\r" {
            let end = trimmed.characters.endIndex
            trimmed.removeSubrange(trimmed.characters.index(before: end)..<end)
        }
        return trimmed
    }
}

// MARK: - Formatting

enum NotesFMFormat {
    /// The list shows prose, not source, so the emphasis markers a transcript
    /// puts around speaker names would only be noise there. Deliberately only
    /// the two markers the transcript format actually uses — guessing at every
    /// markdown construct would start mangling ordinary words.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// `nil` for a note that was never recorded, so callers can leave the slot
    /// empty instead of printing a meaningless "0 min".
    static func duration(_ seconds: TimeInterval) -> String? {
        guard seconds >= 1 else { return nil }
        let minutes = max(1, Int((seconds / 60).rounded()))
        guard minutes >= 60 else { return "\(minutes) min" }
        let remainder = minutes % 60
        return remainder == 0 ? "\(minutes / 60) hr" : "\(minutes / 60) hr \(remainder) min"
    }
}
