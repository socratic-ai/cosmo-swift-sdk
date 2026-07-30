import Foundation
import Testing

@testable import CosmoNotesKit

@Suite struct NoteDocumentStoreTests {
    private func freshStore() -> (EncryptedNoteDocumentStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-\(UUID().uuidString)", isDirectory: true)
        return (EncryptedNoteDocumentStore(root: root), root)
    }

    // Integral-second dates so the `.iso8601` JSON round-trip is exact (the
    // default ISO8601 strategy has no fractional seconds, so sub-second
    // precision is dropped).
    private func savedNote(
        _ store: EncryptedNoteDocumentStore,
        id: String,
        kind: Note.Kind,
        title: String,
        body: String,
        modifiedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) async -> Note {
        var note = await store.loadOrCreate(id: id, kind: kind, title: title)
        note.body = body
        note.modifiedAt = modifiedAt
        await store.save(note)
        return note
    }

    @Test func sidecarTracksBodyEmptinessOnEveryWrite() async throws {
        let (store, _) = freshStore()
        let dateKey = "2026-07-05"
        let id = Note.dailyID(dateKey: dateKey)

        _ = await store.loadOrCreate(id: id, kind: .daily(dateKey: dateKey), title: dateKey)
        var flags: [Bool?] = await store.list().map(\.bodyIsEmpty)
        #expect(flags == [true])

        _ = await store.append(
            text: "call the vet", id: id, kind: .daily(dateKey: dateKey), title: dateKey,
            header: "# \(dateKey)")
        flags = await store.list().map(\.bodyIsEmpty)
        #expect(flags == [false])
    }

    @Test func saveReportsFailureAndLeavesTheFileUntouched() async throws {
        let (store, root) = freshStore()
        let dateKey = "2026-07-06"
        let id = Note.dailyID(dateKey: dateKey)
        let saved = await savedNote(
            store, id: id, kind: .daily(dateKey: dateKey), title: dateKey,
            body: "# 2026-07-06\n\noriginal\n")
        #expect(await store.save(saved))

        // A read-only docs directory makes the atomic rename fail.
        let fm = FileManager.default
        let docsDir = root.appendingPathComponent("docs", isDirectory: true)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: docsDir.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: docsDir.path) }

        var edited = saved
        edited.body = "# 2026-07-06\n\nlost edit\n"
        edited.modifiedAt = Date(timeIntervalSince1970: 1_700_000_300)
        #expect(await store.save(edited) == false)

        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: docsDir.path)
        let loaded = try #require(await store.load(id: id))
        #expect(loaded.body == "# 2026-07-06\n\noriginal\n")
    }

    @Test func dailyNoteRoundTrip() async throws {
        let (store, root) = freshStore()
        let dateKey = "2026-07-17"
        let id = Note.dailyID(dateKey: dateKey)
        #expect(id == "daily-2026-07-17")

        let created = await store.loadOrCreate(id: id, kind: .daily(dateKey: dateKey), title: dateKey)
        #expect(created.id == id)
        #expect(created.kind == .daily(dateKey: dateKey))
        #expect(created.kind.dateKey == dateKey)
        #expect(created.title == dateKey)
        #expect(created.body.isEmpty)
        #expect(created.createdAt == created.modifiedAt)
        #expect(created.schemaVersion == Note.currentSchemaVersion)

        var edited = created
        edited.body = "# 2026-07-17\n\ncall the vet\n"
        edited.modifiedAt = Date(timeIntervalSince1970: 1_700_000_100)
        await store.save(edited)

        let loaded = try #require(await store.load(id: id))
        #expect(loaded == edited)
        // Full note and summary sidecar both live under docs/.
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: root.appendingPathComponent("docs/\(id).json").path))
        #expect(fm.fileExists(atPath: root.appendingPathComponent("docs/\(id).summary.json").path))
    }

    @Test func namedNoteRoundTrip() async throws {
        let (store, _) = freshStore()
        let id = Note.newNamedID(existing: [])
        let created = await store.loadOrCreate(id: id, kind: .named, title: "Packing list")
        #expect(created.kind == .named)
        #expect(created.kind.dateKey == nil)
        #expect(created.title == "Packing list")

        var edited = created
        edited.title = "Travel packing list"
        edited.body = "- sunscreen\n"
        edited.modifiedAt = Date(timeIntervalSince1970: 1_700_000_200)
        await store.save(edited)

        let loaded = try #require(await store.load(id: id))
        #expect(loaded == edited)
        let summary = try #require(await store.list().first)
        #expect(summary == edited.summary)
        #expect(summary.title == "Travel packing list")
        #expect(summary.dateKey == nil)
    }

    @Test func loadOrCreateReturnsTheExistingNoteUnchanged() async throws {
        let (store, _) = freshStore()
        let dateKey = "2026-07-01"
        let id = Note.dailyID(dateKey: dateKey)
        let saved = await savedNote(
            store, id: id, kind: .daily(dateKey: dateKey), title: dateKey, body: "existing content\n")

        let again = await store.loadOrCreate(id: id, kind: .daily(dateKey: dateKey), title: dateKey)
        #expect(again == saved)
        #expect(again.body == "existing content\n")
    }

    @Test func concurrentLoadOrCreateForSameDailyIDYieldsOneNote() async throws {
        let (store, root) = freshStore()
        let dateKey = "2026-07-17"
        let id = Note.dailyID(dateKey: dateKey)

        // Concurrent load-or-creates for "today" must converge on one document,
        // not race into several creates with drifting timestamps.
        let notes = await withTaskGroup(of: Note.self) { group -> [Note] in
            for _ in 0..<20 {
                group.addTask {
                    await store.loadOrCreate(id: id, kind: .daily(dateKey: dateKey), title: dateKey)
                }
            }
            var collected: [Note] = []
            for await note in group { collected.append(note) }
            return collected
        }
        let first = try #require(notes.first)
        for note in notes { #expect(note == first) }

        // Exactly one full note + one sidecar on disk, and one listing entry.
        let entries = try FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("docs").path)
        #expect(entries.sorted() == ["\(id).json", "\(id).summary.json"])
        #expect(await store.list().map(\.id) == [id])
    }

    @Test func listSelfHealsAMissingSummarySidecar() async throws {
        let (store, root) = freshStore()
        let dateKey = "2026-07-10"
        let id = Note.dailyID(dateKey: dateKey)
        let saved = await savedNote(
            store, id: id, kind: .daily(dateKey: dateKey), title: dateKey, body: "healed body\n")

        // Simulate a note whose independent summary-sidecar write failed.
        let fm = FileManager.default
        let summaryURL = root.appendingPathComponent("docs/\(id).summary.json")
        try fm.removeItem(at: summaryURL)
        #expect(!fm.fileExists(atPath: summaryURL.path))

        let summaries = await store.list()
        #expect(summaries == [saved.summary])
        // The sidecar is regenerated and decodes back to the same summary.
        #expect(fm.fileExists(atPath: summaryURL.path))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let healed = try decoder.decode(NoteSummary.self, from: Data(contentsOf: summaryURL))
        #expect(healed == saved.summary)
    }

    @Test func listIsMostRecentlyModifiedFirst() async throws {
        let (store, _) = freshStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        _ = await savedNote(
            store, id: Note.dailyID(dateKey: "2026-07-01"), kind: .daily(dateKey: "2026-07-01"),
            title: "2026-07-01", body: "old\n", modifiedAt: base)
        _ = await savedNote(
            store, id: "n-mid00000", kind: .named,
            title: "Packing list", body: "mid\n", modifiedAt: base.addingTimeInterval(100))
        _ = await savedNote(
            store, id: Note.dailyID(dateKey: "2026-07-02"), kind: .daily(dateKey: "2026-07-02"),
            title: "2026-07-02", body: "new\n", modifiedAt: base.addingTimeInterval(200))

        let summaries = await store.list()
        #expect(summaries.map(\.id) == ["daily-2026-07-02", "n-mid00000", "daily-2026-07-01"])
        #expect(summaries.map(\.dateKey) == ["2026-07-02", nil, "2026-07-01"])
    }

    @Test func listOrderIsDeterministicForSameSecondModifications() async throws {
        let (store, _) = freshStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        _ = await savedNote(
            store, id: "n-tie00001", kind: .named,
            title: "Tie B", body: "b\n", modifiedAt: base)
        _ = await savedNote(
            store, id: Note.dailyID(dateKey: "2026-07-04"), kind: .daily(dateKey: "2026-07-04"),
            title: "2026-07-04", body: "a\n", modifiedAt: base)
        _ = await savedNote(
            store, id: Note.dailyID(dateKey: "2026-07-08"), kind: .daily(dateKey: "2026-07-08"),
            title: "2026-07-08", body: "new\n", modifiedAt: base.addingTimeInterval(100))

        // Newest first; equal timestamps fall back to ascending id.
        #expect(await store.list().map(\.id) == ["daily-2026-07-08", "daily-2026-07-04", "n-tie00001"])
    }

    @Test func deleteRemovesBothFiles() async throws {
        let (store, root) = freshStore()
        let id = Note.dailyID(dateKey: "2026-07-03")
        _ = await savedNote(
            store, id: id, kind: .daily(dateKey: "2026-07-03"), title: "2026-07-03", body: "gone\n")

        await store.delete(id: id)

        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("docs/\(id).json").path))
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("docs/\(id).summary.json").path))
        #expect(await store.load(id: id) == nil)
        #expect(await store.list().isEmpty)
    }

    @Test func loadOrCreateQuarantinesAnUndecodableNoteInsteadOfClobbering() async throws {
        let (store, root) = freshStore()
        let dateKey = "2026-07-05"
        let id = Note.dailyID(dateKey: dateKey)
        let docsDir = root.appendingPathComponent("docs", isDirectory: true)
        let corruptBytes = Data("not json".utf8)
        try corruptBytes.write(to: docsDir.appendingPathComponent("\(id).json"))

        let created = await store.loadOrCreate(id: id, kind: .daily(dateKey: dateKey), title: dateKey)
        #expect(created.body.isEmpty)

        // The original bytes survive, moved aside to `<id>.json.corrupt`.
        let corruptURL = docsDir.appendingPathComponent("\(id).json.corrupt")
        #expect(try Data(contentsOf: corruptURL) == corruptBytes)
        // A fresh note took the id's place; the quarantined file is not listed.
        let loaded = try #require(await store.load(id: id))
        #expect(loaded == created)
        #expect(await store.list().map(\.id) == [id])
    }

    @Test func loadOnAnUndecodableNoteReturnsNilWithoutDestroyingIt() async throws {
        let (store, root) = freshStore()
        let id = Note.dailyID(dateKey: "2026-07-06")
        let noteURL = root.appendingPathComponent("docs/\(id).json")
        let corruptBytes = Data("{\"meta\":".utf8)
        try corruptBytes.write(to: noteURL)

        #expect(await store.load(id: id) == nil)
        #expect(try Data(contentsOf: noteURL) == corruptBytes)
    }

    @Test func newerSchemaNoteIsPreservedAndRefused() async throws {
        let (store, root) = freshStore()
        let dateKey = "2026-07-09"
        let id = Note.dailyID(dateKey: dateKey)
        let noteURL = root.appendingPathComponent("docs/\(id).json")
        let futureBytes = Data(#"""
            {"meta":{"id":"daily-2026-07-09","kind":{"daily":{"dateKey":"2026-07-09"}},"title":"2026-07-09","createdAt":"2023-11-14T22:13:20Z","modifiedAt":"2023-11-14T22:13:20Z","schemaVersion":\#(Note.currentSchemaVersion + 1),"futureField":"kept"},"body":"from the future\n"}
            """#.utf8)
        try futureBytes.write(to: noteURL)

        // A valid note from a newer build is refused, not adopted: the caller
        // gets an in-memory note and nothing is persisted.
        let fallback = await store.loadOrCreate(
            id: id, kind: .daily(dateKey: dateKey), title: dateKey)
        #expect(fallback.body.isEmpty)
        #expect(fallback.schemaVersion == Note.currentSchemaVersion)

        // The file is byte-identical afterward — neither rewritten nor
        // quarantined — and load refuses it rather than let a later save
        // drop the newer build's fields.
        #expect(try Data(contentsOf: noteURL) == futureBytes)
        #expect(!FileManager.default.fileExists(atPath: noteURL.path + ".corrupt"))
        #expect(await store.load(id: id) == nil)
    }

    @Test func loadOrCreateDoesNotPersistOverAnUnreadableNote() async throws {
        // Root bypasses POSIX permissions, so the unreadable simulation below
        // can't work there.
        guard getuid() != 0 else { return }
        let (store, root) = freshStore()
        let dateKey = "2026-07-07"
        let id = Note.dailyID(dateKey: dateKey)
        let saved = await savedNote(
            store, id: id, kind: .daily(dateKey: dateKey), title: dateKey, body: "precious\n")

        // Stand-in for a Data Protection read failure while the device is
        // locked: the file exists but reading it throws.
        let noteURL = root.appendingPathComponent("docs/\(id).json")
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: noteURL.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: noteURL.path) }

        let fallback = await store.loadOrCreate(id: id, kind: .daily(dateKey: dateKey), title: dateKey)
        #expect(fallback.body.isEmpty)

        // The stored note was not overwritten by the fallback.
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: noteURL.path)
        let reloaded = try #require(await store.load(id: id))
        #expect(reloaded == saved)
    }

    @Test func sanitizeNeverEscapesRoot() async throws {
        let (store, root) = freshStore()
        let docsDir = root.appendingPathComponent("docs", isDirectory: true)
        let docsPrefix = docsDir.standardizedFileURL.path + "/"
        let evilIds = ["../../etc/x", "a/b", "", "..", "/etc/passwd", "....//....//x"]
        for id in evilIds {
            let safe = store.sanitize(id)
            // Sanitized output carries no path separators or traversal tokens.
            #expect(!safe.contains("/"))
            #expect(!safe.contains(".."))
            #expect(!safe.isEmpty)
            let url = docsDir.appendingPathComponent("\(safe).json")
            #expect(url.standardizedFileURL.path.hasPrefix(docsPrefix))
        }
        // An already-safe generated id passes through unchanged.
        #expect(store.sanitize("daily-2026-07-17") == "daily-2026-07-17")
        #expect(store.sanitize("n-ab12cd34") == "n-ab12cd34")

        // A write under a hostile id lands inside docs/ and stays loadable
        // under the original id.
        _ = await store.loadOrCreate(id: "../escape", kind: .named, title: "evil")
        let entries = try FileManager.default.contentsOfDirectory(atPath: docsDir.path)
        #expect(entries.count == 2)
        let loaded = try #require(await store.load(id: "../escape"))
        #expect(loaded.title == "evil")
    }

    @Test func rootIsExcludedFromBackup() throws {
        // Init must eagerly create the shared notes root and exclude it from
        // device backup, whichever store touches the root first. The iOS-only
        // Data Protection class cannot be observed on the macOS test host, so it
        // is intentionally not asserted here.
        let (_, root) = freshStore()
        let values = try root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }
}

@Suite struct NoteDocumentStoreAppendTests {
    private func freshStore() -> (EncryptedNoteDocumentStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-\(UUID().uuidString)", isDirectory: true)
        return (EncryptedNoteDocumentStore(root: root), root)
    }

    private let dateKey = "2026-07-21"
    private var dailyID: String { Note.dailyID(dateKey: dateKey) }
    private var header: String { MarkdownSections.dailyHeader(stamp: dateKey) }

    private func appendDaily(
        _ store: EncryptedNoteDocumentStore, _ text: String
    ) async -> NoteAppendOutcome {
        await store.append(
            text: text, id: dailyID, kind: .daily(dateKey: dateKey), title: dateKey, header: header)
    }

    @Test func appendSeedsAFreshDailyNote() async throws {
        let (store, root) = freshStore()
        let outcome = await appendDaily(store, "call the vet")

        guard case .appended(let note, let created) = outcome else {
            Issue.record("expected an appended outcome, got \(outcome)")
            return
        }
        #expect(created)
        #expect(note.id == dailyID)
        #expect(note.kind == .daily(dateKey: dateKey))
        #expect(note.title == dateKey)
        #expect(note.body == "# 2026-07-21\n\ncall the vet\n")

        // Persisted, with the summary sidecar, not just returned.
        let loaded = try #require(await store.load(id: dailyID))
        #expect(loaded == note)
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: root.appendingPathComponent("docs/\(dailyID).summary.json").path))
    }

    @Test func appendComposesOntoExistingContent() async throws {
        let (store, _) = freshStore()
        _ = await appendDaily(store, "first")
        let outcome = await appendDaily(store, "second")

        guard case .appended(let note, let created) = outcome else {
            Issue.record("expected an appended outcome, got \(outcome)")
            return
        }
        #expect(!created)
        #expect(note.body == "# 2026-07-21\n\nfirst\n\nsecond\n")
    }

    @Test func appendSeedsTheHeaderOntoAnExistingEmptyNote() async throws {
        let (store, _) = freshStore()
        _ = await store.loadOrCreate(id: dailyID, kind: .daily(dateKey: dateKey), title: dateKey)

        let outcome = await appendDaily(store, "late start")
        guard case .appended(let note, let created) = outcome else {
            Issue.record("expected an appended outcome, got \(outcome)")
            return
        }
        // The note file already existed (empty body), so this call did not
        // create it — but the block composition still seeds the header.
        #expect(!created)
        #expect(note.body == "# 2026-07-21\n\nlate start\n")
    }

    @Test func appendUpdatesModifiedAtAndKeepsCreatedAt() async throws {
        let (store, _) = freshStore()
        var stale = await store.loadOrCreate(
            id: dailyID, kind: .daily(dateKey: dateKey), title: dateKey)
        stale.modifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        await store.save(stale)

        let outcome = await appendDaily(store, "fresh entry")
        guard case .appended(let note, _) = outcome else {
            Issue.record("expected an appended outcome, got \(outcome)")
            return
        }
        #expect(note.modifiedAt > stale.modifiedAt)
        #expect(note.createdAt == stale.createdAt)
    }

    @Test func appendRefusesANewerSchemaFileUntouched() async throws {
        let (store, root) = freshStore()
        let noteURL = root.appendingPathComponent("docs/\(dailyID).json")
        let futureBytes = Data(#"""
            {"meta":{"id":"daily-2026-07-21","kind":{"daily":{"dateKey":"2026-07-21"}},"title":"2026-07-21","createdAt":"2023-11-14T22:13:20Z","modifiedAt":"2023-11-14T22:13:20Z","schemaVersion":\#(Note.currentSchemaVersion + 1),"futureField":"kept"},"body":"from the future\n"}
            """#.utf8)
        try futureBytes.write(to: noteURL)

        let outcome = await appendDaily(store, "must not land")
        #expect(outcome == .refused(.newerSchema))
        #expect(try Data(contentsOf: noteURL) == futureBytes)
    }

    @Test func appendRefusesAnUnreadableFileUntouched() async throws {
        // Root bypasses POSIX permissions, so the unreadable simulation below
        // can't work there.
        guard getuid() != 0 else { return }
        let (store, root) = freshStore()
        _ = await appendDaily(store, "precious")

        let noteURL = root.appendingPathComponent("docs/\(dailyID).json")
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: noteURL.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: noteURL.path) }

        let outcome = await appendDaily(store, "must not land")
        #expect(outcome == .refused(.unreadable))

        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: noteURL.path)
        let reloaded = try #require(await store.load(id: dailyID))
        #expect(reloaded.body == "# 2026-07-21\n\nprecious\n")
    }

    @Test func appendRefusesWhenTheWriteFailsAndKeepsTheOldFiles() async throws {
        // Root bypasses POSIX permissions, so the write-failure simulation
        // below can't work there.
        guard getuid() != 0 else { return }
        let (store, root) = freshStore()
        let seeded = await appendDaily(store, "precious")
        guard case .appended(let before, _) = seeded else {
            Issue.record("expected an appended outcome, got \(seeded)")
            return
        }
        let docsDir = root.appendingPathComponent("docs", isDirectory: true)
        let summaryURL = docsDir.appendingPathComponent("\(dailyID).summary.json")
        let summaryBefore = try Data(contentsOf: summaryURL)

        // A read-only docs directory makes the atomic write fail.
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: docsDir.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: docsDir.path) }

        let outcome = await appendDaily(store, "must not land")
        #expect(outcome == .refused(.writeFailed))

        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: docsDir.path)
        let reloaded = try #require(await store.load(id: dailyID))
        #expect(reloaded == before)
        #expect(try Data(contentsOf: summaryURL) == summaryBefore)
    }

    @Test func appendQuarantinesAnUndecodableFileThenSeeds() async throws {
        let (store, root) = freshStore()
        let docsDir = root.appendingPathComponent("docs", isDirectory: true)
        let corruptBytes = Data("not json".utf8)
        try corruptBytes.write(to: docsDir.appendingPathComponent("\(dailyID).json"))

        let outcome = await appendDaily(store, "recovered")
        guard case .appended(let note, let created) = outcome else {
            Issue.record("expected an appended outcome, got \(outcome)")
            return
        }
        #expect(created)
        #expect(note.body == "# 2026-07-21\n\nrecovered\n")
        // The original bytes survive, moved aside to `<id>.json.corrupt`.
        let corruptURL = docsDir.appendingPathComponent("\(dailyID).json.corrupt")
        #expect(try Data(contentsOf: corruptURL) == corruptBytes)
    }

    @Test func concurrentAppendsToOneDailyNoteLoseNothing() async throws {
        let (store, root) = freshStore()
        // Zero-padded so every text is the same length (the expected total
        // below is then order-independent) and no text is a substring of
        // another (exact-occurrence counting stays unambiguous).
        let texts = (0..<24).map { String(format: "entry-%02d", $0) }

        let outcomes = await withTaskGroup(of: NoteAppendOutcome.self) { group -> [NoteAppendOutcome] in
            for text in texts {
                group.addTask { await self.appendDaily(store, text) }
            }
            var collected: [NoteAppendOutcome] = []
            for await outcome in group { collected.append(outcome) }
            return collected
        }

        var createdCount = 0
        for outcome in outcomes {
            guard case .appended(_, let created) = outcome else {
                Issue.record("an append was refused: \(outcome)")
                return
            }
            if created { createdCount += 1 }
        }
        // Exactly one append observed the absent file and seeded it.
        #expect(createdCount == 1)

        let final = try #require(await store.load(id: dailyID))
        // Every appended text present exactly once, whatever the order.
        for text in texts {
            #expect(final.body.components(separatedBy: text).count - 1 == 1, "lost or duplicated \(text)")
        }
        #expect(final.body.hasPrefix("\(header)\n\n"))
        #expect(final.body.hasSuffix("\n"))
        // Uncorrupted: the body is exactly the header seed plus one block per
        // append — nothing torn, nothing interleaved.
        let seedLength: Int = header.count + 2
        let blockLengths: Int = texts.map { $0.count + 1 }.reduce(0, +)
        let separators: Int = texts.count - 1
        let expectedLength: Int = seedLength + blockLengths + separators
        #expect(final.body.count == expectedLength)

        // One note file + one sidecar; no strays from racing writers.
        let entries = try FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("docs").path)
        #expect(entries.sorted() == ["\(dailyID).json", "\(dailyID).summary.json"])
    }
}

@Suite struct NoteCodableTests {
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

    @Test func decodesADailyBlobAndPinsItsWireShape() throws {
        let json = #"""
            {"meta":{"id":"daily-2026-07-10","kind":{"daily":{"dateKey":"2026-07-10"}},"title":"2026-07-10","createdAt":"2023-11-14T22:13:20Z","modifiedAt":"2023-11-14T22:13:20Z","schemaVersion":1},"body":"# 2026-07-10\n"}
            """#
        let note = try makeDecoder().decode(Note.self, from: Data(json.utf8))
        #expect(note.id == "daily-2026-07-10")
        #expect(note.kind == .daily(dateKey: "2026-07-10"))
        #expect(note.body == "# 2026-07-10\n")
        #expect(note.schemaVersion == 1)
    }

    @Test func missingSchemaVersionFailsToDecode() throws {
        // Every version of the format writes schemaVersion; a blob without it is
        // not a note document, so decoding must fail rather than guess.
        let json = #"""
            {"meta":{"id":"daily-2026-07-10","kind":{"daily":{"dateKey":"2026-07-10"}},"title":"2026-07-10","createdAt":"2023-11-14T22:13:20Z","modifiedAt":"2023-11-14T22:13:20Z"},"body":"# 2026-07-10\n"}
            """#
        #expect(throws: DecodingError.self) {
            _ = try makeDecoder().decode(Note.self, from: Data(json.utf8))
        }
    }

    @Test func roundTripKeepsMetaAndBodySeparate() throws {
        let original = Note(
            id: "n-ab12cd34",
            kind: .named,
            title: "Packing list",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_060),
            body: "- sunscreen\n"
        )
        let data = try makeEncoder().encode(original)
        let decoded = try makeDecoder().decode(Note.self, from: data)
        #expect(decoded == original)
        #expect(decoded.schemaVersion == Note.currentSchemaVersion)

        // The persisted envelope is `{meta, body}`: the Markdown lives only
        // under the top-level `body` key.
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["meta", "body"])
        #expect(object["body"] as? String == "- sunscreen\n")
        let meta = try #require(object["meta"] as? [String: Any])
        #expect(meta["id"] as? String == "n-ab12cd34")
        #expect(meta["schemaVersion"] as? Int == Note.currentSchemaVersion)
        // Pin the named kind's wire shape (the daily shape is pinned above).
        let kind = try #require(meta["kind"] as? [String: Any])
        #expect(Set(kind.keys) == ["named"])
        #expect((kind["named"] as? [String: Any])?.isEmpty == true)
    }
}

@Suite struct NoteIDHelperTests {
    @Test func dailyIDIsDeterministic() {
        #expect(Note.dailyID(dateKey: "2026-07-17") == "daily-2026-07-17")
    }

    @Test func namedIDIsNamespacedLowercaseAlphanumeric() {
        let id = Note.newNamedID(existing: ["daily-2026-07-17", "n-existing1"])
        #expect(id.hasPrefix("n-"))
        #expect(id.count == 10)
        #expect(id.dropFirst(2).allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) })
    }
}
