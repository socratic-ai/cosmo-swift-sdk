import CosmoRealtime
import Foundation
import Testing

@testable import CosmoNotesKit

/// The daily-note handler factory: `save_note` writes through the store's
/// atomic append (and still feeds the session-record closure), `read_notes`
/// with a `date` reads that day or falls back to the dates that have notes.
@Suite struct NoteToolPackDailyTests {
    // 2026-07-21T12:00:00Z
    private static let noon = Date(timeIntervalSince1970: 1_784_635_200)
    private static let utc = TimeZone(identifier: "UTC")!
    private let todayKey = "2026-07-21"

    /// A settable wall clock shared with a running handler, so a test can
    /// prove the handler samples the clock at each tool call.
    private final class ClockBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Date
        init(_ date: Date) { stored = date }
        var date: Date {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); defer { lock.unlock() }; stored = newValue }
        }
    }

    private actor Captured {
        private(set) var value: String?
        private(set) var count = 0
        func set(_ v: String) {
            value = v
            count += 1
        }
    }

    private func freshStore() -> (EncryptedNoteDocumentStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-\(UUID().uuidString)", isDirectory: true)
        return (EncryptedNoteDocumentStore(root: root), root)
    }

    private func makeHandler(
        store: NoteDocumentStore,
        clock: ClockBox = ClockBox(noon),
        timeZone: TimeZone = utc,
        savedTexts: Captured = Captured(),
        queries: Captured = Captured()
    ) -> ClientToolRPCHandler {
        NoteToolPack.handler(
            store: store,
            now: { clock.date },
            timeZone: { timeZone },
            onSaveNote: { await savedTexts.set($0) },
            onReadNotes: { query in
                await queries.set(query)
                return NotesSearchResult(
                    hits: [SearchHit(noteId: "s1", title: "T", score: 1, preview: "p \(query)")],
                    truncated: false
                )
            },
            onSubmitRecap: { _ in }
        )
    }

    private func decode(_ reply: String) throws -> [String: JSONValue] {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(reply.utf8))
        guard case .object(let object) = value else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not an object"))
        }
        return object
    }

    private func result(_ reply: [String: JSONValue]) throws -> [String: JSONValue] {
        guard case .object(let object)? = reply["result"] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "no result object"))
        }
        return object
    }

    /// The size the transport enforces: the RPC dispatcher decodes the
    /// handler's reply string and re-wraps it as the result of a fresh
    /// `{ok: true}` envelope before the cap check.
    private func simulatedWireSize(_ reply: String) throws -> Int {
        ClientToolReply.envelope(ok: true, result: try decode(reply)).utf8.count
    }

    // MARK: - save_note

    @Test func saveNoteAppendsToTodaysDailyNoteAndKeepsTheSessionCopy() async throws {
        let (store, _) = freshStore()
        let savedTexts = Captured()
        let handler = makeHandler(store: store, savedTexts: savedTexts)

        let reply = try decode(await handler("save_note", #"{"text":"buy milk"}"#))
        #expect(reply["ok"] == .bool(true))
        let result = try result(reply)
        #expect(result["note_id"] == .string("daily-2026-07-21"))
        #expect(result["title"] == .string(todayKey))
        #expect(result["created"] == .bool(true))

        let note = try #require(await store.load(id: "daily-2026-07-21"))
        #expect(note.body == "# 2026-07-21\n\nbuy milk\n")
        // Both writes stay possible: the session-record closure still fires.
        #expect(await savedTexts.value == "buy milk")
    }

    @Test func twoSavesInOneDayShareOneDailyNote() async throws {
        let (store, _) = freshStore()
        let handler = makeHandler(store: store)

        _ = await handler("save_note", #"{"text":"morning entry"}"#)
        let second = try decode(await handler("save_note", #"{"text":"evening entry"}"#))
        #expect(try result(second)["created"] == .bool(false))

        let note = try #require(await store.load(id: "daily-2026-07-21"))
        #expect(note.body == "# 2026-07-21\n\nmorning entry\n\nevening entry\n")
        #expect(await store.list().count == 1)
    }

    @Test func savesAcrossMidnightLandInDifferentDailyNotes() async throws {
        let (store, _) = freshStore()
        let clock = ClockBox(Date(timeIntervalSince1970: 1_784_678_340))  // 23:59:00Z
        let handler = makeHandler(store: store, clock: clock)

        _ = await handler("save_note", #"{"text":"last thing today"}"#)
        clock.date = Date(timeIntervalSince1970: 1_784_678_460)  // 00:01:00Z next day
        _ = await handler("save_note", #"{"text":"first thing tomorrow"}"#)

        let before = try #require(await store.load(id: "daily-2026-07-21"))
        let after = try #require(await store.load(id: "daily-2026-07-22"))
        #expect(before.body == "# 2026-07-21\n\nlast thing today\n")
        #expect(after.body == "# 2026-07-22\n\nfirst thing tomorrow\n")
    }

    @Test func todayFollowsTheDeviceTimezone() async throws {
        let (store, _) = freshStore()
        // 03:00Z is still the previous day in Los Angeles.
        let clock = ClockBox(Date(timeIntervalSince1970: 1_784_602_800))
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        let handler = makeHandler(store: store, clock: clock, timeZone: losAngeles)

        let reply = try decode(await handler("save_note", #"{"text":"late night"}"#))
        #expect(try result(reply)["note_id"] == .string("daily-2026-07-20"))
    }

    @Test func saveNoteWithExplicitDateTargetsThatDay() async throws {
        let (store, _) = freshStore()
        let handler = makeHandler(store: store)

        let reply = try decode(
            await handler("save_note", #"{"text":"backfill","date":"2026-07-01"}"#))
        #expect(reply["ok"] == .bool(true))
        #expect(try result(reply)["note_id"] == .string("daily-2026-07-01"))

        let note = try #require(await store.load(id: "daily-2026-07-01"))
        #expect(note.body == "# 2026-07-01\n\nbackfill\n")
        #expect(await store.load(id: "daily-2026-07-21") == nil)
    }

    @Test func saveNoteNullDateMeansToday() async throws {
        let (store, _) = freshStore()
        let handler = makeHandler(store: store)

        let reply = try decode(await handler("save_note", #"{"text":"x","date":null}"#))
        #expect(try result(reply)["note_id"] == .string("daily-2026-07-21"))
    }

    @Test func saveNoteEmptyStringDateMeansToday() async throws {
        let (store, _) = freshStore()
        let handler = makeHandler(store: store)

        let reply = try decode(await handler("save_note", #"{"text":"x","date":""}"#))
        #expect(reply["ok"] == .bool(true))
        #expect(try result(reply)["note_id"] == .string("daily-2026-07-21"))
    }

    @Test(arguments: [
        #"{"text":"x","date":"2026-13-40"}"#,  // not a calendar date
        #"{"text":"x","date":"tomorrow"}"#,  // not a stamp
        #"{"text":"x","date":123}"#,  // wrong type
    ])
    func saveNoteBadDateIsAnErrorAndWritesNothing(payload: String) async throws {
        let (store, _) = freshStore()
        let savedTexts = Captured()
        let handler = makeHandler(store: store, savedTexts: savedTexts)

        let reply = try decode(await handler("save_note", payload))
        #expect(reply["ok"] == .bool(false))
        #expect(reply["error"] != .null)
        #expect(await store.list().isEmpty)
        #expect(await savedTexts.value == nil)
    }

    @Test func saveNoteEmptyTextIsRejectedAndWritesNothing() async throws {
        let (store, _) = freshStore()
        let savedTexts = Captured()
        let handler = makeHandler(store: store, savedTexts: savedTexts)

        let reply = try decode(await handler("save_note", #"{"text":"  \n  "}"#))
        #expect(reply["ok"] == .bool(false))
        #expect(await store.list().isEmpty)
        #expect(await savedTexts.value == nil)
    }

    @Test func saveNoteClampsOversizedTextBeforeBothWrites() async throws {
        let (store, _) = freshStore()
        let savedTexts = Captured()
        let handler = makeHandler(store: store, savedTexts: savedTexts)

        let huge = String(repeating: "a", count: NoteToolPack.maxSaveNoteLength + 5000)
        let reply = try decode(await handler("save_note", "{\"text\":\"\(huge)\"}"))
        #expect(reply["ok"] == .bool(true))
        #expect(await savedTexts.value?.count == NoteToolPack.maxSaveNoteLength)
        let note = try #require(await store.load(id: "daily-2026-07-21"))
        // Header seed + blank line + clamped text + newline.
        #expect(note.body.count == "# 2026-07-21\n\n".count + NoteToolPack.maxSaveNoteLength + 1)
    }

    @Test func saveNoteRefusedAppendStillRecordsTheSessionCopy() async throws {
        let (store, root) = freshStore()
        let savedTexts = Captured()
        let handler = makeHandler(store: store, savedTexts: savedTexts)

        // Today's file claims a newer schema: the append must refuse and leave
        // the file untouched, while the chat record still keeps the text.
        let noteURL = root.appendingPathComponent("docs/daily-2026-07-21.json")
        let futureBytes = Data(#"""
            {"meta":{"id":"daily-2026-07-21","kind":{"daily":{"dateKey":"2026-07-21"}},"title":"2026-07-21","createdAt":"2023-11-14T22:13:20Z","modifiedAt":"2023-11-14T22:13:20Z","schemaVersion":\#(Note.currentSchemaVersion + 1)},"body":"from the future\n"}
            """#.utf8)
        try futureBytes.write(to: noteURL)

        let reply = try decode(await handler("save_note", #"{"text":"chat copy only"}"#))
        #expect(reply["ok"] == .bool(false))
        guard case .string(let message)? = reply["error"] else {
            Issue.record("expected error string")
            return
        }
        #expect(message.contains("kept in this chat's record"))
        #expect(await savedTexts.value == "chat copy only")
        #expect(await savedTexts.count == 1)
        #expect(try Data(contentsOf: noteURL) == futureBytes)
    }

    @Test func saveNoteFailedWriteStillRecordsTheSessionCopy() async throws {
        // Root bypasses POSIX permissions, so the write-failure simulation
        // below can't work there.
        guard getuid() != 0 else { return }
        let (store, root) = freshStore()
        let savedTexts = Captured()
        let handler = makeHandler(store: store, savedTexts: savedTexts)

        let docsDir = root.appendingPathComponent("docs", isDirectory: true)
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: docsDir.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: docsDir.path) }

        let reply = try decode(await handler("save_note", #"{"text":"kept in chat"}"#))
        #expect(reply["ok"] == .bool(false))
        guard case .string(let message)? = reply["error"] else {
            Issue.record("expected error string")
            return
        }
        #expect(message.contains("kept in this chat's record"))
        #expect(await savedTexts.value == "kept in chat")
        #expect(await savedTexts.count == 1)
    }

    // MARK: - read_notes day lookup

    @Test func readNotesWithDateReturnsTheDayContent() async throws {
        let (store, _) = freshStore()
        let handler = makeHandler(store: store)
        _ = await handler("save_note", #"{"text":"call the vet"}"#)

        let reply = try decode(await handler("read_notes", #"{"date":"2026-07-21"}"#))
        #expect(reply["ok"] == .bool(true))
        let result = try result(reply)
        #expect(result["note_id"] == .string("daily-2026-07-21"))
        #expect(result["date"] == .string(todayKey))
        #expect(result["content"] == .string("# 2026-07-21\n\ncall the vet\n"))
        #expect(result["truncated"] == .bool(false))
        #expect(result["available_dates"] == nil)
    }

    @Test func readNotesDateWinsOverQuery() async throws {
        let (store, _) = freshStore()
        let queries = Captured()
        let handler = makeHandler(store: store, queries: queries)
        _ = await handler("save_note", #"{"text":"call the vet"}"#)

        let reply = try decode(
            await handler("read_notes", #"{"date":"2026-07-21","query":"vet"}"#))
        let result = try result(reply)
        #expect(result["content"] == .string("# 2026-07-21\n\ncall the vet\n"))
        // The search closure never ran: the date selected the day-lookup form.
        #expect(await queries.value == nil)
    }

    @Test func readNotesEmptyDayListsOnlyAvailableDates() async throws {
        let (store, _) = freshStore()
        let handler = makeHandler(store: store)
        for (day, text) in [("2026-07-18", "a"), ("2026-07-19", "b"), ("2026-07-20", "c")] {
            _ = await handler("save_note", "{\"text\":\"\(text)\",\"date\":\"\(day)\"}")
        }
        // A named note must not surface in the daily-date fallback.
        _ = await store.append(
            text: "sunscreen", id: "n-pack0001", kind: .named, title: "Packing list",
            header: "# Packing list")

        let reply = try decode(await handler("read_notes", #"{"date":"2026-07-05"}"#))
        #expect(reply["ok"] == .bool(true))
        let result = try result(reply)
        // Nothing a model could mistake for note content — only the dates.
        #expect(Set(result.keys) == ["available_dates"])
        #expect(result["available_dates"] == .array([
            .string("2026-07-20"), .string("2026-07-19"), .string("2026-07-18"),
        ]))
    }

    @Test func readNotesEmptyDayExcludesItselfFromAvailableDates() async throws {
        let (store, _) = freshStore()
        let handler = makeHandler(store: store)
        // The queried day exists as an empty-bodied note (loadOrCreate seeds
        // one); it must not be offered back as a day that has notes.
        _ = await store.loadOrCreate(
            id: "daily-2026-07-05", kind: .daily(dateKey: "2026-07-05"), title: "2026-07-05")
        for (day, text) in [("2026-07-18", "a"), ("2026-07-19", "b")] {
            _ = await handler("save_note", "{\"text\":\"\(text)\",\"date\":\"\(day)\"}")
        }

        let reply = try decode(await handler("read_notes", #"{"date":"2026-07-05"}"#))
        let result = try result(reply)
        #expect(Set(result.keys) == ["available_dates"])
        #expect(result["available_dates"] == .array([
            .string("2026-07-19"), .string("2026-07-18"),
        ]))
    }

    @Test func readNotesAvailableDatesSkipEmptyBodiedDays() async throws {
        let (store, _) = freshStore()
        let handler = makeHandler(store: store)
        // An empty day seeded via the public loadOrCreate (e.g. by a notes UI)
        // is not a day with anything to read.
        _ = await store.loadOrCreate(
            id: "daily-2026-07-10", kind: .daily(dateKey: "2026-07-10"), title: "2026-07-10")
        for (day, text) in [("2026-07-18", "a"), ("2026-07-19", "b")] {
            _ = await handler("save_note", "{\"text\":\"\(text)\",\"date\":\"\(day)\"}")
        }

        let reply = try decode(await handler("read_notes", #"{"date":"2026-07-05"}"#))
        let result = try result(reply)
        #expect(result["available_dates"] == .array([
            .string("2026-07-19"), .string("2026-07-18"),
        ]))
    }

    @Test func legacySidecarWithoutEmptinessFieldStillDecodesAndLists() async throws {
        let (store, root) = freshStore()
        let handler = makeHandler(store: store)
        _ = await handler("save_note", #"{"text":"real content","date":"2026-07-11"}"#)
        // Rewrite the sidecar as a build without the emptiness field wrote it.
        let sidecarURL = root.appendingPathComponent("docs/daily-2026-07-11.summary.json")
        try Data(#"""
            {"id":"daily-2026-07-11","kind":{"daily":{"dateKey":"2026-07-11"}},"title":"2026-07-11","modifiedAt":"2023-11-14T22:13:20Z"}
            """#.utf8).write(to: sidecarURL)

        let flags: [Bool?] = await store.list().map(\.bodyIsEmpty)
        #expect(flags == [nil])
        // Unknown emptiness keeps the day listed rather than hiding real notes.
        let reply = try decode(await handler("read_notes", #"{"date":"2026-07-05"}"#))
        #expect(try result(reply)["available_dates"] == .array([.string("2026-07-11")]))
    }

    @Test func readNotesEmptyStoreListsNoDates() async throws {
        let (store, _) = freshStore()
        let handler = makeHandler(store: store)

        let reply = try decode(await handler("read_notes", #"{"date":"2026-07-05"}"#))
        #expect(reply["ok"] == .bool(true))
        let result = try result(reply)
        #expect(Set(result.keys) == ["available_dates"])
        #expect(result["available_dates"] == .array([]))
    }

    @Test func readNotesAvailableDatesCapAt30NewestFirst() async throws {
        let (store, _) = freshStore()
        let handler = makeHandler(store: store)
        let days = (1...17).map { String(format: "2026-06-%02d", $0) }
            + (1...18).map { String(format: "2026-07-%02d", $0) }
        for day in days {
            _ = await store.append(
                text: "x", id: Note.dailyID(dateKey: day), kind: .daily(dateKey: day),
                title: day, header: MarkdownSections.dailyHeader(stamp: day))
        }

        let reply = try decode(await handler("read_notes", #"{"date":"2025-01-01"}"#))
        guard case .array(let listed)? = try result(reply)["available_dates"] else {
            Issue.record("expected available_dates array")
            return
        }
        let expected = days.sorted(by: >).prefix(NoteToolPack.maxAvailableDates)
            .map(JSONValue.string)
        #expect(listed.count == NoteToolPack.maxAvailableDates)
        #expect(listed == Array(expected))
        #expect(listed.first == .string("2026-07-18"))
        #expect(listed.last == .string("2026-06-06"))
    }

    @Test func readNotesDayContentIsHeadCappedKeepingTheTail() async throws {
        let (store, _) = freshStore()
        let handler = makeHandler(store: store)
        var note = await store.loadOrCreate(
            id: "daily-2026-07-21", kind: .daily(dateKey: todayKey), title: todayKey)
        note.body = "OLDEST" + String(repeating: "a", count: 20_000) + "NEWEST"
        await store.save(note)

        let reply = try decode(await handler("read_notes", #"{"date":"2026-07-21"}"#))
        let result = try result(reply)
        #expect(result["truncated"] == .bool(true))
        guard case .string(let content)? = result["content"] else {
            Issue.record("expected content string")
            return
        }
        #expect(content.utf8.count <= NoteToolPack.dayContentMaxBytes)
        // Trimmed from the head: the most recent (appended) end survives.
        #expect(content.hasSuffix("NEWEST"))
        #expect(!content.contains("OLDEST"))
    }

    @Test func escapeHeavyDayContentStillFitsTheTransportCap() async throws {
        let (store, _) = freshStore()
        let handler = makeHandler(store: store)
        var note = await store.loadOrCreate(
            id: "daily-2026-07-21", kind: .daily(dateKey: todayKey), title: todayKey)
        // "ab" + six newlines: 8 raw bytes escape to 14 in JSON, so a
        // 12,000-byte raw tail serializes to ~21 KB — past the 15 KiB cap.
        note.body = String(repeating: "ab\n\n\n\n\n\n", count: 2_500) + "NEWEST"
        await store.save(note)

        let reply = await handler("read_notes", #"{"date":"2026-07-21"}"#)
        #expect(reply.utf8.count <= ClientToolReply.maxBytes)
        let fields = try decode(reply)
        #expect(fields["ok"] == .bool(true))
        let result = try result(fields)
        #expect(result["truncated"] == .bool(true))
        guard case .string(let content)? = result["content"] else {
            Issue.record("expected content string")
            return
        }
        #expect(!content.isEmpty)
        #expect(content.hasSuffix("NEWEST"))
    }

    @Test func dayContentInTheReWrapBandStillFitsTheWire() async throws {
        let (store, _) = freshStore()
        let handler = makeHandler(store: store)
        var note = await store.loadOrCreate(
            id: "daily-2026-07-21", kind: .daily(dateKey: todayKey), title: todayKey)
        // Sized so the inner envelope fits the cap on its own but the
        // dispatcher's re-wrap (+34 bytes) pushes the wire form past it.
        note.body = String(repeating: "aa\n", count: 3_810) + "TAIL"
        await store.save(note)

        let reply = await handler("read_notes", #"{"date":"2026-07-21"}"#)
        #expect(try simulatedWireSize(reply) <= ClientToolReply.maxBytes)
        let fields = try decode(reply)
        #expect(fields["ok"] == .bool(true))
        guard case .string(let content)? = try result(fields)["content"] else {
            Issue.record("expected content string")
            return
        }
        #expect(content.hasSuffix("TAIL"))
    }

    @Test func dayContentRepliesAcrossTheReWrapBandFitTheWire() throws {
        // Sweep body sizes across the band where the inner envelope fits
        // the cap but the re-wrapped wire form does not.
        for count in 3_795...3_820 {
            let body = String(repeating: "aa\n", count: count) + "TAIL"
            let reply = NoteToolPack.dayContentReply(
                noteID: "daily-2026-07-21", dateKey: todayKey, body: body)
            #expect(try simulatedWireSize(reply) <= ClientToolReply.maxBytes, "count=\(count)")
        }
    }

    @Test func dayContentReplyShrinksWhenEscapingInflatesUnderTheRawCap() throws {
        // 11,000 raw newline bytes are under the 12,000 raw cap but escape to
        // ~22 KB — the shrink must engage even though the raw cap never did.
        let body = String(repeating: "\n", count: 11_000) + "NEWEST"
        let reply = NoteToolPack.dayContentReply(
            noteID: "daily-2026-07-21", dateKey: todayKey, body: body)
        #expect(reply.utf8.count <= ClientToolReply.maxBytes)
        let result = try result(try decode(reply))
        #expect(result["truncated"] == .bool(true))
        guard case .string(let content)? = result["content"] else {
            Issue.record("expected content string")
            return
        }
        #expect(!content.isEmpty)
        #expect(content.hasSuffix("NEWEST"))
    }

    @Test func controlCharacterHeavyDayContentKeepsSubstantialContent() throws {
        // U+0001 escapes to six bytes: subtracting the serialized overflow
        // from the raw budget would overshoot straight to empty content even
        // though ~2.5 KB fits the wire.
        let body = String(repeating: "\u{01}", count: 29_996) + "TAIL"
        let reply = NoteToolPack.dayContentReply(
            noteID: "daily-2026-07-21", dateKey: todayKey, body: body)
        #expect(try simulatedWireSize(reply) <= ClientToolReply.maxBytes)
        let result = try result(try decode(reply))
        #expect(result["truncated"] == .bool(true))
        guard case .string(let content)? = result["content"] else {
            Issue.record("expected content string")
            return
        }
        #expect(content.hasSuffix("TAIL"))
        #expect(content.utf8.count > 2_000)
    }

    @Test(arguments: [
        #"{"date":"2026-02-30"}"#,
        #"{"date":"yesterday"}"#,
        #"{"date":42}"#,
    ])
    func readNotesBadDateIsAnError(payload: String) async throws {
        let (store, _) = freshStore()
        let handler = makeHandler(store: store)
        let reply = try decode(await handler("read_notes", payload))
        #expect(reply["ok"] == .bool(false))
        #expect(reply["error"] != .null)
    }

    @Test func readNotesEmptyStringDateFallsBackToSearch() async throws {
        let (store, _) = freshStore()
        let queries = Captured()
        let handler = makeHandler(store: store, queries: queries)

        let reply = try decode(await handler("read_notes", #"{"date":"","query":"vet"}"#))
        #expect(reply["ok"] == .bool(true))
        // The empty date reads as omitted: the search ran, not a day lookup.
        #expect(await queries.value == "vet")
        guard case .array(let hits)? = try result(reply)["hits"] else {
            Issue.record("expected hits array")
            return
        }
        #expect(hits.count == 1)
    }

    @Test func pathologicallyLongDateStillGetsACorrectiveErrorUnderTheCap() async throws {
        let (store, _) = freshStore()
        let handler = makeHandler(store: store)
        let runaway = String(repeating: "9", count: 16_000)

        let reply = await handler("read_notes", "{\"date\":\"\(runaway)\"}")
        #expect(try simulatedWireSize(reply) <= ClientToolReply.maxBytes)
        let fields = try decode(reply)
        #expect(fields["ok"] == .bool(false))
        guard case .string(let message)? = fields["error"] else {
            Issue.record("expected error string")
            return
        }
        #expect(message.contains("is not a valid YYYY-MM-DD calendar date"))
    }

    @Test func readNotesWithoutDateKeepsSearchAndRecencyBehavior() async throws {
        let (store, _) = freshStore()
        let queries = Captured()
        let handler = makeHandler(store: store, queries: queries)

        let search = try decode(await handler("read_notes", #"{"query":"milk"}"#))
        #expect(search["ok"] == .bool(true))
        #expect(await queries.value == "milk")
        guard case .array(let hits)? = try result(search)["hits"] else {
            Issue.record("expected hits array")
            return
        }
        #expect(hits.count == 1)

        let recency = try decode(await handler("read_notes", "{}"))
        #expect(recency["ok"] == .bool(true))
        #expect(await queries.value == "")
    }

    // MARK: - head cap

    @Test func headCapLeavesShortTextAlone() {
        let capped = NoteToolPack.headCapped("short", maxBytes: 100)
        #expect(capped.text == "short")
        #expect(!capped.truncated)
    }

    @Test func headCapCutsOnACharacterBoundary() {
        // Each emoji is 4 UTF-8 bytes; a 6-byte budget lands mid-emoji, so the
        // cut walks forward and keeps exactly one whole emoji.
        let capped = NoteToolPack.headCapped("🙂🙂🙂", maxBytes: 6)
        #expect(capped.text == "🙂")
        #expect(capped.truncated)
    }
}
