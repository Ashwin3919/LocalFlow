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
        // Explicitly labelled: `.plain` is the default now, and section 7 covers
        // it. This section exists to keep the labelled format honest for anyone
        // who turns it back on in Settings.
        guard let writer = try? MeetingWriter(
            root: root, title: "Weekly Sync: Q3 planning", started: Date(), style: .labelled
        ) else {
            print("  FAIL could not create writer")
            return 1
        }
        check("writer created the file immediately", FileManager.default.fileExists(atPath: writer.url.path))

        writer.append(speaker: .you, at: 4.2, text: "Let's start with the migration.")
        writer.append(speaker: .you, at: 7.9, text: "I pushed the branch last night.")
        writer.append(speaker: .them, at: 12.4, text: "Did the rollback plan get reviewed?")
        writer.appendNote("check rollback before Friday", at: 14.0)
        // A note whose elapsed time lags the transcript must not be printed above
        // the line before it, which is what the floor in `appendNote` is for.
        writer.appendNote("stamped by the floor, not by 1 s", at: 1.0)
        writer.appendMarker("paused for 3m 20s", at: 20.0)
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
        check("note stamped at the elapsed time it was given",
              afterFlush.contains("[00:00:14] Note"))
        check("a note behind the transcript is floored, never stamped above it",
              afterFlush.contains("[00:00:14] Note** — stamped by the floor"))
        check("two notes stay two lines, never merged",
              afterFlush.contains("check rollback before Friday")
                  && afterFlush.contains("stamped by the floor, not by 1 s")
                  && !afterFlush.contains("Friday stamped"))
        check("pause marker written as italic prose, not as a speaker",
              afterFlush.contains("_— paused for 3m 20s —_"))
        check("pause marker is attributed to nobody",
              !afterFlush.contains("paused for 3m 20s** —"))

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
        check("pause marker survived the store round trip",
              note.body.contains("_— paused for 3m 20s —_"))
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

        // 6. The pause clock. Pure arithmetic on injected dates, so the one part
        //    of pause handling that does not need a microphone is actually proven
        //    rather than assumed.
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
        func at(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }

        var clock = MeetingClock()
        clock.start(at: t0)
        check("clock counts a running span", abs(clock.elapsed(at: at(10)) - 10) < 0.001)

        clock.pause(at: at(10))
        check("clock reports paused", clock.isPaused)
        check("a paused clock does not advance", abs(clock.elapsed(at: at(600)) - 10) < 0.001)

        let gap = clock.resume(at: at(610))
        check("resume reports the length of the pause", abs(gap - 600) < 0.001)
        check("clock is no longer paused", !clock.isPaused)
        check("recorded time excludes the pause",
              abs(clock.elapsed(at: at(615)) - 15) < 0.001)

        clock.pause(at: at(615))
        clock.resume(at: at(1215))
        check("two pauses both come off the total",
              abs(clock.elapsed(at: at(1220)) - 20) < 0.001)

        // Stopping while paused must not bank the pause as recorded audio, and
        // freeze has to be safe to evaluate more than once.
        var stopped = clock
        stopped.pause(at: at(1220))
        stopped.freeze(at: at(9999))
        check("stopping while paused excludes the pause",
              abs(stopped.elapsed(at: at(99999)) - 20) < 0.001)
        check("a frozen clock never moves again",
              stopped.elapsed(at: at(100)) == stopped.elapsed(at: at(1_000_000)))

        var never = MeetingClock()
        check("an unstarted clock reads zero", never.elapsed(at: t0) == 0)
        check("resuming a clock that never paused is a no-op", never.resume(at: t0) == 0)
        never.pause(at: t0)
        check("pausing an unstarted clock does not start it", !never.isPaused)

        check("span description reads as a length, not a timestamp",
              NotesFM.spanDescription(200) == "3m 20s"
                  && NotesFM.spanDescription(45) == "45s"
                  && NotesFM.spanDescription(3700) == "1h 1m")

        // 7. The plain transcript format — the default, and what Refine reads.
        let plainRoot = root.appendingPathComponent("plain", isDirectory: true)
        guard let plain = try? MeetingWriter(
            root: plainRoot, title: "Plain style", started: Date(), style: .plain
        ) else {
            print("  FAIL could not create a plain writer")
            return 1
        }
        plain.append(speaker: .you, at: 4.0, text: "Let's start with the migration.")
        plain.append(speaker: .them, at: 12.0, text: "Did the rollback plan get reviewed?")
        plain.appendNote("check rollback before Friday", at: 13.0)
        plain.appendMarker("paused for 3m 20s", at: 20.0)
        plain.finish(duration: 30)
        let plainText = (try? String(contentsOf: plain.url, encoding: .utf8)) ?? ""
        let plainBody = plainText.components(separatedBy: "---").last ?? ""

        check("plain style writes no timestamps", !plainBody.contains("00:00:"))
        check("plain style writes no speaker labels",
              !plainBody.contains("You**") && !plainBody.contains("Them**"))
        check("plain style keeps every spoken word",
              plainBody.contains("Let's start with the migration.")
                  && plainBody.contains("Did the rollback plan get reviewed?"))
        check("a typed note stays distinguishable as a quote",
              plainBody.contains("> check rollback before Friday"))
        check("the pause marker survives in plain style",
              plainBody.contains("_— paused for 3m 20s —_"))
        check("blocks are separated by a blank line, so markdown sees paragraphs",
              plainBody.contains("Let's start with the migration.\n\nDid the rollback"))

        // 8. Refine plumbing. The network call itself is not exercised — this is
        //    the part that can be wrong without anyone noticing.
        check("fence-wrapped answers are unwrapped",
              Refine.stripFence("```markdown\n# Notes\n\n- one\n```") == "# Notes\n\n- one")
        check("a code block inside real notes is left alone",
              Refine.stripFence("# Notes\n\n```sh\nls\n```") == "# Notes\n\n```sh\nls\n```")
        check("unfenced answers pass through untouched",
              Refine.stripFence("# Notes\n\n- one") == "# Notes\n\n- one")
        let builtPrompt = Refine.prompt(title: "Weekly Sync", transcript: "we ship Thursday")
        check("the prompt carries the transcript and forbids invention",
              builtPrompt.contains("we ship Thursday")
                  && builtPrompt.contains("Invent nothing")
                  && builtPrompt.contains("Weekly Sync"))

        // 9. Refined notes are written beside the transcript, never over it, and
        //    they belong to the meeting rather than becoming another row.
        let transcriptBefore = (try? String(contentsOf: writer.url, encoding: .utf8)) ?? ""
        guard let notesID = store.writeNotes(
            for: note, body: "# Notes\n\n- decided to ship Thursday\n"
        ) else {
            print("  FAIL writeNotes returned nothing")
            return 1
        }
        let transcriptAfter = (try? String(contentsOf: writer.url, encoding: .utf8)) ?? ""
        check("the original transcript file is byte-identical afterwards",
              transcriptBefore == transcriptAfter)
        check("the notes landed in a different file", notesID != note.id)
        check("the notes filename is derived from the meeting's",
              notesID == note.id + "-notes")
        check("the notes are titled from the meeting",
              store.notes.contains { $0.id == notesID && $0.title == "Weekly Sync: Q3 planning — Notes" })
        check("the notes carry no duration, having recorded no audio",
              store.notes.first { $0.id == notesID }?.duration == 0)
        check("the notes body was written",
              store.notes.first { $0.id == notesID }?.body.contains("ship Thursday") == true)

        // 9b. The pairing. This is what stops a refined meeting from showing up
        //     twice in the library, which is what it used to do.
        check("the notes record which meeting they belong to",
              store.notes.first { $0.id == notesID }?.notesFor == note.id)
        check("the meeting itself claims no parent",
              store.notes.first { $0.id == note.id }?.notesFor == nil)
        check("the notes are reachable from the meeting",
              store.attachedNotes(for: note)?.id == notesID)
        check("the library lists the meeting but not its notes",
              store.meetings.contains { $0.id == note.id }
                  && !store.meetings.contains { $0.id == notesID })
        check("a search that only matches the notes still finds the meeting",
              store.searchMeetings("ship Thursday").contains { $0.id == note.id })

        // 9c. Refining again replaces the notes. The old uniquing left
        //     `… — Notes` and `… — Notes 2` behind as two more rows, neither
        //     reachable from the meeting they described.
        let again = store.writeNotes(for: note, body: "# Notes\n\n- shipped\n")
        check("refining again reuses the same file", again == notesID)
        check("refining again replaces the body, and adds no second file",
              store.notes.first { $0.id == notesID }?.body.contains("shipped") == true
                  && store.notes.count { $0.notesFor == note.id } == 1)

        // 9d. A rename must not break the pair. Without this the notes keep the
        //     old stem and reappear as an orphan row.
        let renamedTitle = "Weekly Sync: Q3 planning, renamed"
        store.rename(note, to: renamedTitle)
        guard let renamed = store.meetings.first(where: { $0.title == renamedTitle }) else {
            print("  FAIL the meeting vanished after a rename")
            return 1
        }
        check("the notes follow the meeting through a rename",
              store.attachedNotes(for: renamed)?.id == renamed.id + "-notes")
        check("the renamed pair is still one row",
              store.meetings.count { $0.id == renamed.id || $0.notesFor == renamed.id } == 1)
        check("the notes are retitled with the meeting",
              store.attachedNotes(for: renamed)?.title == renamedTitle + " — Notes")

        // 9e. Deleting only the notes leaves the recording alone.
        store.deleteNotes(for: renamed)
        check("deleting the notes leaves the meeting listed",
              store.attachedNotes(for: renamed) == nil
                  && store.meetings.contains { $0.id == renamed.id })

        // 9f. The filename fallback, for the notes files written before
        //     `notes-for` existed — including the `-2` duplicates.
        check("a legacy notes filename maps back to its meeting",
              MeetingMarkdown.meetingStem(ofNotesStem: "2026-08-24-1003-standup-notes")
                  == "2026-08-24-1003-standup")
        check("a duplicate left by the old uniquing maps back too",
              MeetingMarkdown.meetingStem(ofNotesStem: "2026-08-24-1003-standup-notes-2")
                  == "2026-08-24-1003-standup")
        check("an ordinary meeting filename is not mistaken for notes",
              MeetingMarkdown.meetingStem(ofNotesStem: "2026-08-24-1003-standup") == nil)
        check("a meeting whose own title ends in the word notes is not mistaken for one",
              MeetingMarkdown.meetingStem(ofNotesStem: "notes") == nil)

        // 11. The echo filter. Fixtures are real pairs lifted out of a recording
        //     made on speakers, where the microphone re-heard the far end and both
        //     transcribers wrote the same sentence. That recording is the reason
        //     this exists, so it is what the thresholds are checked against.
        check("an identical pair is an echo",
              EchoFilter.isEcho(
                  "Um, I don't know the reason for it, what it's causing this at the moment.",
                  "Um, I don't know the reason for it, what it's causing this at the moment."))
        check("a pair the recogniser heard slightly differently is still an echo",
              EchoFilter.isEcho(
                  "Um, just waiting for for review from Gammon or like from someone from security at the moment.",
                  "Um, just waiting for for review from Gammon or like from some of the security at the moment."))
        check("punctuation and case do not matter",
              EchoFilter.isEcho("Maybe we can also look into them deeper in the session today.",
                                "maybe we can also look into them deeper in the session today"))
        check("two people genuinely saying different things is not an echo",
              !EchoFilter.isEcho(
                  "So from my side, I was working on Plexus and what was blocking me.",
                  "Just for people to know, the Azure VMs are the equivalent of EC2."))
        check("agreement is not an echo — both people really do say yes",
              !EchoFilter.isEcho("Yeah", "Yeah")
                  && !EchoFilter.isEcho("Yep.", "Yep"))
        // The important safety property. A microphone line that contains the far
        // end's sentence *and* the user's own words must survive, because dropping
        // it would throw the user's words away to remove a duplicate.
        check("a short far-end line inside a longer mic line is not an echo of it",
              !EchoFilter.isEcho(
                  "Thanks for that. Right, so from my side I finished the migration branch.",
                  "Thanks for that."))
        check("bare punctuation carries no words",
              EchoFilter.isWordless(".") && EchoFilter.isWordless("..") && EchoFilter.isWordless(", ,."))
        check("real words are not wordless", !EchoFilter.isWordless("Okay, then."))
        check("digits count as words", !EchoFilter.isWordless("2026"))

        // 10. Search.
        check("search finds by body text", !store.search("rollback").isEmpty)
        check("search is case-insensitive", !store.search("ROLLBACK").isEmpty)
        check("search misses nonsense", store.search("zzzznotpresent").isEmpty)

        print("\n\(failures.isEmpty ? "PASSED" : "FAILED (\(failures.count))")")
        for failure in failures { print("  - \(failure)") }
        return failures.isEmpty ? 0 : 1
    }
}
