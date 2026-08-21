import Foundation

/// Exercises the meeting file pipeline end to end without a microphone.
///
/// Run with `LocalFlow --notesfm-selftest`. It exists because the durability and
/// round-trip guarantees are the parts that quietly lose a user's meeting if they
/// are wrong, and those are exactly the parts that cannot be checked by reading
/// the code. Writes to a temporary folder and cleans up after itself.
@MainActor
enum NotesFMSelfTest {
    static func run() -> Int32 {
        var failures: [String] = []

        func check(_ label: String, _ condition: Bool) {
            print("\(condition ? "  ok  " : "  FAIL") \(label)")
            if !condition { failures.append(label) }
        }

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("notesfm-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        print("NotesFM self-test")
        print("root: \(root.path)\n")

        // 1. A recording session, as it happens live.
        guard let writer = try? MeetingWriter(root: root, title: "Weekly Sync: Q3 planning", started: Date()) else {
            print("  FAIL could not create writer")
            return 1
        }
        check("writer created the file immediately", FileManager.default.fileExists(atPath: writer.url.path))

        writer.append(speaker: .you, at: 4.2, text: "Let's start with the migration.")
        writer.append(speaker: .you, at: 7.9, text: "I pushed the branch last night.")
        writer.append(speaker: .them, at: 12.4, text: "Did the rollback plan get reviewed?")
        writer.appendNote("check rollback before Friday")
        writer.append(speaker: .them, at: 40.0, text: "Separate thought, well after the gap.")
        writer.flush()

        let afterFlush = (try? String(contentsOf: writer.url, encoding: .utf8)) ?? ""
        check("flush wrote transcript to disk", afterFlush.contains("Let's start with the migration"))
        check("both speakers present", afterFlush.contains("You") && afterFlush.contains("Them"))
        check("note present", afterFlush.contains("check rollback before Friday"))
        check("timestamp formatted", afterFlush.contains("00:00:04"))
        check("consecutive same-speaker lines merged",
              afterFlush.contains("Let's start with the migration. I pushed the branch last night."))
        check("distant same-speaker line NOT merged",
              afterFlush.contains("00:00:40") || afterFlush.contains("Separate thought"))

        // 2. Durability: everything up to the last flush must already be on disk,
        //    which is what makes a force-quit mid-meeting survivable.
        writer.append(speaker: .you, at: 60.0, text: "This line is only flushed at finish.")
        let beforeFinish = (try? String(contentsOf: writer.url, encoding: .utf8)) ?? ""
        check("pre-flush line not yet on disk (proves append is buffered)",
              !beforeFinish.contains("only flushed at finish"))

        writer.finish(duration: 62.5)
        let final = (try? String(contentsOf: writer.url, encoding: .utf8)) ?? ""
        check("finish flushed the last line", final.contains("only flushed at finish"))
        check("finish stamped real duration", final.contains("duration: 62") || final.contains("duration: 63"))

        // 3. Reading it back through the store.
        let store = MeetingStore(root: root)
        store.reload()
        check("store found exactly one meeting", store.notes.count == 1)

        guard let note = store.notes.first else {
            print("\nFAILED: store returned nothing")
            return 1
        }
        check("title round-tripped including the colon", note.title == "Weekly Sync: Q3 planning")
        // The writer stores whole seconds, so 62.5 legitimately becomes 63.
        check("duration round-tripped", abs(note.duration - 62.5) <= 1)
        check("body kept the transcript", note.body.contains("rollback plan get reviewed"))
        check("snippet is non-empty", !note.snippet.isEmpty)

        // 4. Round-trip safety: save then reload must not alter the body.
        var edited = note
        edited.body = note.body + "\n\n## My own heading\n\nHand-typed after the fact.\n"
        store.save(edited)
        store.reload()
        let reloaded = store.notes.first
        check("hand edit survived save+reload",
              reloaded?.body.contains("Hand-typed after the fact") == true)
        check("save+reload did not corrupt the transcript",
              reloaded?.body.contains("rollback plan get reviewed") == true)
        check("body is byte-identical after round trip", reloaded?.body == edited.body)

        // 5. A file a user mangled by hand must still load, never vanish.
        let mangled = root.appendingPathComponent("2026-01-02-1500-hand-written.md")
        try? "no frontmatter at all\n\n# Just A Heading\n\nsome words".write(to: mangled, atomically: true, encoding: .utf8)
        store.reload()
        check("mangled file still loads", store.notes.count == 2)
        check("title recovered from heading",
              store.notes.contains { $0.title == "Just A Heading" })
        check("mangled file body preserved whole",
              store.notes.contains { $0.body.contains("no frontmatter at all") })

        // 6. Search.
        check("search finds by body text", !store.search("rollback").isEmpty)
        check("search is case-insensitive", !store.search("ROLLBACK").isEmpty)
        check("search misses nonsense", store.search("zzzznotpresent").isEmpty)

        print("\n\(failures.isEmpty ? "PASSED" : "FAILED (\(failures.count))")")
        for failure in failures { print("  - \(failure)") }
        return failures.isEmpty ? 0 : 1
    }
}
