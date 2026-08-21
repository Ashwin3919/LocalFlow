import AppKit
import Combine
import Foundation

// MARK: - The file format
//
// Frontmatter rendering, lenient parsing and filename derivation live here
// rather than in `MeetingWriter` because the store is the only thing that ever
// reads a file back; the writer needs three of these helpers and nothing more.
//
// Everything in here is deliberately hand-rolled rather than a YAML library:
// there are four keys, the file is meant to be hand-editable, and a dependency
// that can *reject* a user's file is exactly the failure mode to avoid.

enum MeetingMarkdown {
    /// A hand-edited file with a stray `---` somewhere in the prose must not have
    /// half its body eaten as metadata, so the closing delimiter is only looked
    /// for near the top of the file.
    private static let maximumFrontmatterLines = 40

    /// Slugs longer than this make filenames that are annoying to work with in a
    /// terminal and add nothing — the title in the frontmatter is the real name.
    private static let maximumSlugLength = 60

    /// `Date.ISO8601FormatStyle` is a Sendable struct, unlike `ISO8601DateFormatter`,
    /// so it can be a shared constant without a concurrency escape hatch.
    private static let iso = Date.ISO8601FormatStyle(timeZone: .gmt)
    private static let isoFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)

    // MARK: Writing

    static func frontmatter(title: String, started: Date, duration: TimeInterval, id: String) -> String {
        // No quoting of the title: the parser takes everything after the first
        // colon as the value, so colons and quotes in a title survive untouched
        // and the file stays pleasant to read in any editor.
        let lines = [
            "---",
            "title: \(singleLine(title))",
            "started: \(iso.format(started))",
            "duration: \(Int(max(0, duration).rounded()))",
            "id: \(id)",
            "---"
        ]
        return lines.joined(separator: "\n") + "\n\n"
    }

    /// The full file contents for a note. The body is written verbatim, which is
    /// what makes save-then-load a true round trip.
    static func document(for note: MeetingNote) -> String {
        frontmatter(title: note.title, started: note.started, duration: note.duration, id: note.id)
            + note.body
    }

    // MARK: Reading

    /// Never fails. Anything it cannot understand becomes body text, because the
    /// alternative — refusing to open a file someone typed into — loses words.
    static func note(from text: String, url: URL, folder: String?, fallbackDate: Date) -> MeetingNote {
        // Identity comes from the filename, not from the `id` field: the file can
        // be renamed in Finder, and then the field is the thing that is wrong.
        let id = url.deletingPathExtension().lastPathComponent
        let split = splitFrontmatter(text)
        let fields = split?.fields ?? [:]
        let body = split?.body ?? text

        let title = fields["title"].flatMap(nonEmpty)
            ?? firstHeading(in: body)
            ?? deslug(id)
        let started = fields["started"].flatMap(date(from:)) ?? fallbackDate
        let duration = fields["duration"].flatMap(seconds(from:)) ?? 0

        return MeetingNote(
            id: id,
            url: url,
            title: title,
            started: started,
            duration: duration,
            folder: folder,
            body: body
        )
    }

    /// `nil` when the text does not open with a frontmatter block that closes
    /// again near the top — in that case the caller treats the whole file as body.
    private static func splitFrontmatter(_ text: String) -> (fields: [String: String], body: String)? {
        var rest = text[...]
        guard let openingBreak = rest.firstIndex(where: \.isNewline) else { return nil }
        guard rest[..<openingBreak].trimmingCharacters(in: .whitespacesAndNewlines) == "---" else { return nil }
        rest = rest[rest.index(after: openingBreak)...]

        var fields: [String: String] = [:]
        for _ in 0..<maximumFrontmatterLines {
            guard let lineBreak = rest.firstIndex(where: \.isNewline) else { return nil }
            let line = rest[..<lineBreak].trimmingCharacters(in: .whitespacesAndNewlines)
            let after = rest[rest.index(after: lineBreak)...]

            // `...` is the other YAML document terminator; accept it too since a
            // user's editor may have inserted it.
            if line == "---" || line == "..." {
                return (fields, dropSeparatingBlankLine(String(after)))
            }
            if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty { fields[key] = unquoted(value) }
            }
            rest = after
        }
        return nil
    }

    /// `frontmatter` ends with a blank line as a separator; removing exactly one
    /// newline here is what makes a saved body load back byte-identical, even when
    /// the body itself starts with blank lines.
    private static func dropSeparatingBlankLine(_ body: String) -> String {
        var body = body
        // "\r\n" is a single Character in Swift, so this covers CRLF files too.
        if let first = body.first, first.isNewline { body.removeFirst() }
        return body
    }

    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        for quote in ["\"", "'"] where value.hasPrefix(quote) && value.hasSuffix(quote) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func firstHeading(in body: String) -> String? {
        for line in body.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("#") else { continue }
            return nonEmpty(String(trimmed.drop(while: { $0 == "#" })))
        }
        return nil
    }

    private static func date(from raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let parsed = try? Date(text, strategy: iso) { return parsed }
        if let parsed = try? Date(text, strategy: isoFractional) { return parsed }
        // Created per call rather than shared because it is a non-Sendable class;
        // it is worth the allocation because it accepts offsets and separators the
        // format style above rejects, which is what a hand-edited file contains.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withFullTime, .withDashSeparatorInDate,
                                   .withColonSeparatorInTime, .withColonSeparatorInTimeZone,
                                   .withSpaceBetweenDateAndTime]
        if let parsed = formatter.date(from: text) { return parsed }
        formatter.formatOptions = [.withFullDate]
        return formatter.date(from: text)
    }

    private static func seconds(from raw: String) -> TimeInterval? {
        // Tolerate "2841 s" and friends: take the leading number and ignore the rest.
        let digits = raw.prefix { $0.isNumber || $0 == "." || $0 == "-" }
        guard let value = TimeInterval(digits) else { return nil }
        return max(0, value)
    }

    // MARK: Names

    /// A title collapsed onto one line, so it cannot break the frontmatter it
    /// gets written into.
    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func slug(_ title: String) -> String {
        // Only ASCII alphanumerics survive, because those are the characters that
        // behave identically in Finder, a terminal and every sync client. So
        // transliterate first, or a German or Japanese title would be thrown away
        // entirely: this turns "Grüße" into "grusse" and "会議メモ" into "hui yimemo"
        // instead of "untitled". Plain folding is the fallback if ICU declines.
        let latin = title.applyingTransform(StringTransform("Any-Latin; Latin-ASCII"), reverse: false)
            ?? title.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
        let folded = latin.lowercased()
        var slug = ""
        var pendingSeparator = false
        for character in folded {
            if character.isASCII, character.isLetter || character.isNumber {
                if pendingSeparator, !slug.isEmpty { slug.append("-") }
                pendingSeparator = false
                slug.append(character)
            } else {
                pendingSeparator = true
            }
        }
        slug = String(slug.prefix(maximumSlugLength))
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "untitled" : slug
    }

    /// `YYYY-MM-DD-HHmm` in the user's own time zone: the filename is something a
    /// person reads in Finder, and a meeting held at 9pm belongs to that evening,
    /// not to tomorrow in UTC. The `started` field keeps the unambiguous instant.
    static func datePrefix(for date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(
            format: "%04d-%02d-%02d-%02d%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0
        )
    }

    /// The date prefix already present in a filename stem, so renaming a note
    /// keeps the moment it happened instead of moving it to today.
    static func datePrefix(ofStem stem: String) -> String? {
        let parts = stem.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 4 else { return nil }
        let head = parts[0..<4]
        guard head.map(\.count) == [4, 2, 2, 4] else { return nil }
        guard head.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        return head.joined(separator: "-")
    }

    /// A filename stem that is free in `directory`, appending `-2`, `-3`, … on
    /// collision. `ignoring` is the file being renamed, which does not count as a
    /// collision with itself.
    static func uniqueStem(prefix: String, title: String, in directory: URL, ignoring existing: URL? = nil) -> String {
        let base = prefix.isEmpty ? slug(title) : "\(prefix)-\(slug(title))"
        var candidate = base
        var counter = 2
        while true {
            let url = directory.appendingPathComponent(candidate).appendingPathExtension("md")
            if !FileManager.default.fileExists(atPath: url.path) { return candidate }
            if let existing, url.standardizedFileURL == existing.standardizedFileURL { return candidate }
            candidate = "\(base)-\(counter)"
            counter += 1
        }
    }

    static func uniqueStem(title: String, started: Date, in directory: URL) -> String {
        uniqueStem(prefix: datePrefix(for: started), title: title, in: directory)
    }

    /// Last-resort title for a file with no frontmatter and no heading.
    private static func deslug(_ stem: String) -> String {
        var name = stem
        if let prefix = datePrefix(ofStem: stem), name.hasPrefix(prefix) {
            name.removeFirst(prefix.count)
            while name.hasPrefix("-") { name.removeFirst() }
        }
        let words = name.replacingOccurrences(of: "-", with: " ").trimmingCharacters(in: .whitespaces)
        guard let first = words.first else { return stem }
        return first.uppercased() + words.dropFirst()
    }
}

// MARK: - The library

/// Every meeting on disk, for the library UI.
///
/// The store owns no cache and no index: it lists a directory and parses the
/// files it finds. At a few hundred meetings that is a handful of milliseconds,
/// and in exchange the folder stays fully editable from Finder — copy a file in
/// and it is simply there after the next `reload`.
@MainActor
final class MeetingStore: ObservableObject {
    static let shared = MeetingStore()

    @Published private(set) var notes: [MeetingNote] = []
    @Published private(set) var folders: [String] = []

    private let rootURL: URL
    var root: URL { rootURL }

    init(root: URL = NotesFM.defaultRoot) {
        self.rootURL = root
        createRootIfNeeded()
        reload()
    }

    // MARK: Loading

    func reload() {
        createRootIfNeeded()
        var found = loadNotes(in: rootURL, folder: nil)
        var names: [String] = []
        for directory in subdirectories(of: rootURL) {
            let name = directory.lastPathComponent
            names.append(name)
            found += loadNotes(in: directory, folder: name)
        }
        // Newest first, with the filename as a tiebreak so the order never
        // flickers between two meetings that share a timestamp.
        notes = found.sorted { $0.started == $1.started ? $0.id > $1.id : $0.started > $1.started }
        folders = names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func loadNotes(in directory: URL, folder: String?) -> [MeetingNote] {
        let keys: [URLResourceKey] = [.creationDateKey, .isDirectoryKey]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )) ?? []

        var result: [MeetingNote] = []
        for url in contents where url.pathExtension.lowercased() == "md" {
            guard let text = read(url) else {
                Log.write("MeetingStore could not read \(url.lastPathComponent)")
                continue
            }
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            result.append(MeetingMarkdown.note(from: text, url: url, folder: folder, fallbackDate: created))
        }
        return result
    }

    private func read(_ url: URL) -> String? {
        if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        guard let data = try? Data(contentsOf: url) else { return nil }
        // A file another editor saved in a legacy encoding still opens, with the
        // odd mangled character, instead of disappearing from the library.
        return String(data: data, encoding: .isoLatin1)
    }

    private func subdirectories(of directory: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        return contents.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    // MARK: Editing

    func save(_ note: MeetingNote) {
        guard write(note) else { return }
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            // Patch in place rather than reloading: an editor calls this on every
            // pause in typing, and a reload would reshuffle the list under the user.
            notes[index] = note
        } else {
            reload()
        }
    }

    func delete(_ note: MeetingNote) {
        do {
            // Trash, never remove. A meeting deleted by a mis-click has to be
            // recoverable, and this app is not the right place to be certain.
            try FileManager.default.trashItem(at: note.url, resultingItemURL: nil)
            notes.removeAll { $0.id == note.id }
            Log.write("MeetingStore trashed \(note.url.lastPathComponent)")
        } catch {
            Log.write("MeetingStore delete failed: \(error.localizedDescription)")
        }
    }

    func rename(_ note: MeetingNote, to title: String) {
        let clean = MeetingMarkdown.singleLine(title).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != note.title else { return }

        var updated = note
        updated.title = clean

        let directory = note.url.deletingLastPathComponent()
        let prefix = MeetingMarkdown.datePrefix(ofStem: note.id) ?? MeetingMarkdown.datePrefix(for: note.started)
        let stem = MeetingMarkdown.uniqueStem(prefix: prefix, title: clean, in: directory, ignoring: note.url)
        if stem != note.id, let moved = moveFile(at: note.url, toDirectory: directory, stem: stem) {
            updated.id = stem
            updated.url = moved
        }
        // The title is written even when the move failed, so a read-only folder
        // costs the user a filename, not their edit.
        _ = write(updated)
        reload()
    }

    func move(_ note: MeetingNote, toFolder folder: String?) {
        let name = folder.map(Self.sanitizedFolderName) ?? ""
        let destination = name.isEmpty ? rootURL : rootURL.appendingPathComponent(name, isDirectory: true)
        guard destination.standardizedFileURL != note.url.deletingLastPathComponent().standardizedFileURL else { return }

        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            Log.write("MeetingStore move failed: \(error.localizedDescription)")
            return
        }

        let prefix = MeetingMarkdown.datePrefix(ofStem: note.id) ?? MeetingMarkdown.datePrefix(for: note.started)
        let stem = MeetingMarkdown.uniqueStem(prefix: prefix, title: note.title, in: destination)
        guard let moved = moveFile(at: note.url, toDirectory: destination, stem: stem) else { return }

        var updated = note
        updated.id = stem
        updated.url = moved
        updated.folder = name.isEmpty ? nil : name
        _ = write(updated)
        reload()
    }

    func createFolder(_ name: String) {
        let clean = Self.sanitizedFolderName(name)
        guard !clean.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(
                at: rootURL.appendingPathComponent(clean, isDirectory: true), withIntermediateDirectories: true
            )
            reload()
        } catch {
            Log.write("MeetingStore createFolder failed: \(error.localizedDescription)")
        }
    }

    // MARK: Finding

    func search(_ query: String) -> [MeetingNote] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return notes }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return notes.filter {
            $0.title.range(of: needle, options: options) != nil
                || $0.body.range(of: needle, options: options) != nil
        }
    }

    func revealInFinder(_ note: MeetingNote) {
        NSWorkspace.shared.activateFileViewerSelecting([note.url])
    }

    // MARK: Plumbing

    private func createRootIfNeeded() {
        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        } catch {
            Log.write("MeetingStore could not create \(rootURL.path): \(error.localizedDescription)")
        }
    }

    private func write(_ note: MeetingNote) -> Bool {
        do {
            // Atomic: a crash halfway through a save must not truncate a meeting.
            try MeetingMarkdown.document(for: note).write(to: note.url, atomically: true, encoding: .utf8)
            return true
        } catch {
            Log.write("MeetingStore save failed for \(note.id): \(error.localizedDescription)")
            return false
        }
    }

    private func moveFile(at url: URL, toDirectory directory: URL, stem: String) -> URL? {
        let destination = directory.appendingPathComponent(stem).appendingPathExtension("md")
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        } catch {
            Log.write("MeetingStore could not move \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    /// Folder names come from a text field, so anything that would escape the
    /// root or hide the folder is stripped rather than rejected.
    private static func sanitizedFolderName(_ name: String) -> String {
        var clean = name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: " ")
        while clean.hasPrefix(".") || clean.hasPrefix(" ") { clean.removeFirst() }
        // Collapsing whitespace runs matters more than it looks: without it,
        // "Client / work" and "Client work" become two different folders.
        return clean.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
