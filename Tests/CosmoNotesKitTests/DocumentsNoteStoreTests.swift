import Foundation
import Testing

@testable import CosmoNotesKit

@Suite struct DocumentsNoteStoreTests {
    private func freshStore() -> (DocumentsNoteStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-\(UUID().uuidString)", isDirectory: true)
        return (DocumentsNoteStore(root: root), root)
    }

    // Integral-second dates so the `.iso8601` JSON round-trip is exact (the
    // default ISO8601 strategy has no fractional seconds, so sub-second
    // precision is dropped).
    private func note(_ id: String, startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> SessionNote {
        SessionNote(
            id: id,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60),
            title: "Session \(id)",
            lines: [NoteLine(role: .user, text: "hello"), NoteLine(role: .assistant, text: "hi")],
            notes: [CapturedNote(text: "remember the milk", createdAt: startedAt, source: .user)],
            recap: Recap(summary: "a chat", keyPoints: ["point"], actionItems: [ActionItem(text: "do it")])
        )
    }

    @Test func draftKeepLoadRoundTrip() async throws {
        let (store, root) = freshStore()
        let original = note("abc")

        await store.saveDraft(original)
        // A draft is not yet a kept note.
        #expect(await store.load(id: "abc") == nil)
        #expect(await store.list().isEmpty)
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("drafts/abc.json").path))

        await store.keep(id: "abc")
        let loaded = try #require(await store.load(id: "abc"))
        #expect(loaded == original)
        // Both the full note and its summary draft are gone after promotion.
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("drafts/abc.json").path))
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("drafts/abc.summary.json").path))
        // Both kept files exist.
        #expect(fm.fileExists(atPath: root.appendingPathComponent("abc.json").path))
        #expect(fm.fileExists(atPath: root.appendingPathComponent("abc.summary.json").path))
    }

    @Test func discardRemovesDraftAndKeepsNothing() async throws {
        let (store, root) = freshStore()
        await store.saveDraft(note("x"))
        let fm = FileManager.default
        // Both draft files were written.
        #expect(fm.fileExists(atPath: root.appendingPathComponent("drafts/x.json").path))
        #expect(fm.fileExists(atPath: root.appendingPathComponent("drafts/x.summary.json").path))

        await store.discard(id: "x")
        // Both draft files are gone.
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("drafts/x.json").path))
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("drafts/x.summary.json").path))
        #expect(await store.load(id: "x") == nil)
        await store.keep(id: "x")  // nothing to promote
        #expect(await store.load(id: "x") == nil)
        #expect(await store.list().isEmpty)
    }

    @Test func sweepClearsOnlyDrafts() async throws {
        let (store, root) = freshStore()
        await store.saveDraft(note("kept"))
        await store.keep(id: "kept")
        await store.saveDraft(note("abandoned"))

        await store.sweepDrafts()

        // The whole drafts/ dir is gone, including the summary sidecar.
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("drafts").path))
        #expect(await store.load(id: "kept") != nil)   // kept survives
        await store.keep(id: "abandoned")              // its draft is gone
        #expect(await store.load(id: "abandoned") == nil)
    }

    @Test func listIsNewestFirst() async throws {
        let (store, _) = freshStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for (offset, id) in [("old", 0.0), ("mid", 100.0), ("new", 200.0)] {
            await store.saveDraft(note(offset, startedAt: base.addingTimeInterval(id)))
            await store.keep(id: offset)
        }
        let ids = await store.list().map(\.id)
        #expect(ids == ["new", "mid", "old"])
    }

    @Test func deleteRemovesKeptNote() async throws {
        let (store, _) = freshStore()
        await store.saveDraft(note("z"))
        await store.keep(id: "z")
        await store.delete(id: "z")
        #expect(await store.load(id: "z") == nil)
        #expect(await store.list().isEmpty)
    }

    @Test func keepReplacesAnAlreadyKeptNoteWithoutLoss() async throws {
        let (store, _) = freshStore()
        // First take.
        await store.saveDraft(note("dup", startedAt: Date(timeIntervalSince1970: 1_700_000_000)))
        await store.keep(id: "dup")
        // Second take of the same session id, kept over the first.
        let second = note("dup", startedAt: Date(timeIntervalSince1970: 1_700_000_500))
        await store.saveDraft(second)
        await store.keep(id: "dup")

        let loaded = try #require(await store.load(id: "dup"))
        #expect(loaded == second)
        #expect(await store.list().map(\.id) == ["dup"])
    }

    @Test func updateRewritesBothDraftFiles() async throws {
        let (store, root) = freshStore()
        await store.saveDraft(note("d"))

        var edited = note("d")
        edited.title = "edited title"
        edited.notes.append(CapturedNote(text: "extra", createdAt: edited.startedAt, source: .user))
        await store.update(edited)

        let fm = FileManager.default
        // Still a draft (never promoted): both draft files exist, no kept files.
        #expect(fm.fileExists(atPath: root.appendingPathComponent("drafts/d.json").path))
        #expect(fm.fileExists(atPath: root.appendingPathComponent("drafts/d.summary.json").path))
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("d.json").path))
        // load() reads only kept notes, so the edit is not visible there yet.
        #expect(await store.load(id: "d") == nil)

        // Promote and confirm the full note carries the edit and the summary
        // sidecar reflects it too.
        await store.keep(id: "d")
        let loaded = try #require(await store.load(id: "d"))
        #expect(loaded == edited)
        #expect(loaded.title == "edited title")
        let summary = try #require(await store.list().first)
        #expect(summary.title == "edited title")
        #expect(summary.noteCount == 2)
    }

    @Test func updateRewritesBothKeptFiles() async throws {
        let (store, root) = freshStore()
        await store.saveDraft(note("k"))
        await store.keep(id: "k")

        var edited = note("k")
        edited.title = "kept edit"
        edited.recap = Recap(summary: "new summary", keyPoints: [], actionItems: [])
        await store.update(edited)

        // The kept files were rewritten in place (no draft files recreated).
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: root.appendingPathComponent("k.json").path))
        #expect(fm.fileExists(atPath: root.appendingPathComponent("k.summary.json").path))
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("drafts/k.json").path))

        let loaded = try #require(await store.load(id: "k"))
        #expect(loaded == edited)
        // The summary sidecar (read by list()) reflects the change.
        let summary = try #require(await store.list().first)
        #expect(summary.title == "kept edit")
        #expect(summary.recapSummary == "new summary")
    }

    @Test func updateIsNoOpWhenNeitherFileExists() async throws {
        let (store, root) = freshStore()
        // No draft and no kept note for this id: update must not create either.
        await store.update(note("ghost"))

        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("ghost.json").path))
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("ghost.summary.json").path))
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("drafts/ghost.json").path))
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("drafts/ghost.summary.json").path))
        #expect(await store.load(id: "ghost") == nil)
        #expect(await store.list().isEmpty)
        #expect(await store.listDraftSummaries().isEmpty)
    }

    @Test func listDraftSummariesReturnsOnlyDrafts() async throws {
        let (store, _) = freshStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // One kept note (must not appear) and two drafts (newest first).
        await store.saveDraft(note("kept"))
        await store.keep(id: "kept")
        await store.saveDraft(note("draftOld", startedAt: base))
        await store.saveDraft(note("draftNew", startedAt: base.addingTimeInterval(100)))

        let drafts = await store.listDraftSummaries()
        #expect(drafts.map(\.id) == ["draftNew", "draftOld"])
        // Decoded from the summary sidecars, so derived fields are present.
        let newest = try #require(drafts.first)
        #expect(newest.title == "Session draftNew")
        #expect(newest.lineCount == 2)
        #expect(newest.noteCount == 1)
        // The kept summary is not in the draft listing.
        #expect(!drafts.map(\.id).contains("kept"))
    }

    @Test func listDraftSummariesIsEmptyWithNoDrafts() async throws {
        let (store, _) = freshStore()
        #expect(await store.listDraftSummaries().isEmpty)
    }

    @Test func concurrentGateOpsStayConsistent() async throws {
        let (store, _) = freshStore()
        let n = 50

        // Fire N concurrent save/keep/delete cycles across distinct ids. The
        // gate must serialize file IO so none of these crash, observe a
        // half-written file, or corrupt the listing.
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<n {
                group.addTask {
                    let id = "c\(i)"
                    await store.saveDraft(self.note(id))
                    await store.keep(id: id)
                    // Delete the even ids; keep the odd ones.
                    if i % 2 == 0 { await store.delete(id: id) }
                }
            }
        }

        let listed = await store.list()
        let ids = Set(listed.map(\.id))
        // Exactly the odd ids survive, and every survivor decodes cleanly.
        let expected = Set((0..<n).filter { $0 % 2 == 1 }.map { "c\($0)" })
        #expect(ids == expected)
        for note in listed {
            #expect(note.title == "Session \(note.id)")
        }
    }

    @Test func listReturnsSummariesWithoutLoadingTranscripts() async throws {
        let (store, root) = freshStore()
        let original = note("sum")
        await store.saveDraft(original)
        await store.keep(id: "sum")

        let summaries = await store.list()
        let summary = try #require(summaries.first)
        #expect(summaries.count == 1)
        #expect(summary == original.summary)
        // Derived fields are correct.
        #expect(summary.id == "sum")
        #expect(summary.title == "Session sum")
        #expect(summary.recapSummary == "a chat")
        #expect(summary.lineCount == 2)
        #expect(summary.noteCount == 1)

        // A summary sidecar and a separate full note file both exist on disk;
        // list() reads only the summary.
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: root.appendingPathComponent("sum.summary.json").path))
        #expect(fm.fileExists(atPath: root.appendingPathComponent("sum.json").path))

        // Corrupt the full note: list() must still succeed because it never
        // decodes the transcript, proving the summary path is independent.
        try Data("not json".utf8).write(to: root.appendingPathComponent("sum.json"))
        let stillListed = await store.list()
        #expect(stillListed.map(\.id) == ["sum"])
        #expect(stillListed.first?.lineCount == 2)
    }

    @Test func listSelfHealsAMissingSummarySidecar() async throws {
        let (store, root) = freshStore()
        let original = note("heal")
        await store.saveDraft(original)
        await store.keep(id: "heal")

        // Simulate a note whose independent summary-sidecar write failed: the full
        // note is kept but the sidecar is gone. list() must still return it.
        let fm = FileManager.default
        let summaryURL = root.appendingPathComponent("heal.summary.json")
        try fm.removeItem(at: summaryURL)
        #expect(!fm.fileExists(atPath: summaryURL.path))

        let summaries = await store.list()
        #expect(summaries.map(\.id) == ["heal"])
        #expect(summaries.first == original.summary)
        // The sidecar is regenerated (self-healed) and decodes back to the same
        // summary.
        #expect(fm.fileExists(atPath: summaryURL.path))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let healed = try decoder.decode(SessionNoteSummary.self, from: Data(contentsOf: summaryURL))
        #expect(healed == original.summary)
    }

    @Test func loadAllReturnsFullNotesForSearch() async throws {
        let (store, _) = freshStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let a = note("a", startedAt: base)
        let b = note("b", startedAt: base.addingTimeInterval(100))
        for n in [a, b] {
            await store.saveDraft(n)
            await store.keep(id: n.id)
        }

        let all = await store.loadAll()
        // Newest first, full transcript content present (what search needs).
        #expect(all.map(\.id) == ["b", "a"])
        #expect(all == [b, a])
        for n in all {
            #expect(n.lines == [NoteLine(role: .user, text: "hello"),
                                NoteLine(role: .assistant, text: "hi")])
        }
    }

    @Test func rootIsExcludedFromBackup() throws {
        // Init must eagerly create the root and exclude it from device backup
        // (iCloud/iTunes) so per-session PII never leaves the device. Backup
        // exclusion works on the macOS test host, so we can assert it here.
        //
        // The iOS-only at-rest Data Protection (`.completeFileProtectionUnlessOpen`
        // on writes + the `.completeUnlessOpen` protection class on the notes/
        // and drafts/ directories) cannot be observed on the macOS test host, so
        // it is intentionally not asserted here; it is exercised at runtime on
        // device.
        let (_, root) = freshStore()
        let values = try root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func sanitizeKeepsCollidingIdsDistinct() {
        let (store, _) = freshStore()
        // Ids that reduce to the same allowlisted string must not collide onto one
        // file. Each pair strips to the same core, so the hash suffix must keep
        // them apart.
        for (a, b) in [("a.b", "ab"), ("sess_1", "sess1"), ("x/y", "xy")] {
            #expect(store.sanitize(a) != store.sanitize(b))
        }
        // An already-safe id passes through unchanged (a server UUID isn't rewritten).
        let uuid = "550e8400-e29b-41d4-a716-446655440000"
        #expect(store.sanitize(uuid) == uuid)
        // Sanitizing is stable across calls.
        #expect(store.sanitize("a.b") == store.sanitize("a.b"))
    }

    @Test func sanitizeNeverEscapesRoot() {
        let (store, root) = freshStore()
        let rootPrefix = root.standardizedFileURL.path + "/"
        let evilIds = ["../../etc/x", "a/b", "", "..", "/etc/passwd", "....//....//x", "a/../../b"]
        for id in evilIds {
            let safe = store.sanitize(id)
            // Sanitized output carries no path separators or traversal tokens.
            #expect(!safe.contains("/"))
            #expect(!safe.contains(".."))
            #expect(!safe.isEmpty)
            // The resulting file URLs resolve to a location inside root.
            for url in [
                root.appendingPathComponent("\(safe).json"),
                root.appendingPathComponent("drafts", isDirectory: true).appendingPathComponent("\(safe).json"),
            ] {
                #expect(url.standardizedFileURL.path.hasPrefix(rootPrefix))
            }
        }
    }
}

@Suite struct SessionNoteCodableTests {
    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    @Test func decodesLegacyBlobWithoutSchemaVersion() throws {
        // A file written before schemaVersion existed has no such key; it must
        // still decode (defaulting to the current version) rather than throw and
        // make the note invisible.
        let json = #"""
            {"id":"legacy","startedAt":"2023-11-14T22:13:20Z","title":"Old note","lines":[{"role":"USER","text":"hi"}],"notes":[],"recap":{"summary":"a recap"}}
            """#
        let note = try makeDecoder().decode(SessionNote.self, from: Data(json.utf8))
        #expect(note.id == "legacy")
        #expect(note.title == "Old note")
        #expect(note.schemaVersion == SessionNote.currentSchemaVersion)
        // The recap also lacks a title key and must decode with title nil.
        #expect(note.recap?.title == nil)
        #expect(note.recap?.summary == "a recap")
    }

    @Test func roundTripCarriesSchemaVersionAndRecapTitle() throws {
        let original = SessionNote(
            id: "rt",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            title: "Round trip",
            lines: [NoteLine(role: .user, text: "hello")],
            recap: Recap(title: "Concise title", summary: "sum")
        )
        let data = try makeEncoder().encode(original)
        let decoded = try makeDecoder().decode(SessionNote.self, from: data)
        #expect(decoded == original)
        #expect(decoded.schemaVersion == SessionNote.currentSchemaVersion)
        #expect(decoded.recap?.title == "Concise title")
    }
}
