import CosmoRealtime
import Foundation
import Testing

@testable import CosmoNotesKit

/// The tool declarations plus the handler paths shared by every tool call:
/// search/recency `read_notes`, `submit_recap`, and malformed-payload
/// handling. Daily-note targeting (dates, the store) is covered in
/// `NoteToolPackDailyTests`.
@Suite struct NoteToolPackTests {
    private func decode(_ reply: String) throws -> [String: JSONValue] {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(reply.utf8))
        guard case .object(let object) = value else {
            throw TestError.notAnObject
        }
        return object
    }

    private enum TestError: Error { case notAnObject }

    private func freshStore() -> EncryptedNoteDocumentStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-toolpack-\(UUID().uuidString)", isDirectory: true)
        return EncryptedNoteDocumentStore(root: root)
    }

    private func makeHandler(
        onSaveNote: @escaping @Sendable (String) async -> Void = { _ in },
        onReadNotes: @escaping @Sendable (String) async -> NotesSearchResult = { _ in
            NotesSearchResult(hits: [], truncated: false)
        },
        onSubmitRecap: @escaping @Sendable (Recap) async -> Void = { _ in }
    ) -> ClientToolRPCHandler {
        NoteToolPack.handler(
            store: freshStore(),
            onSaveNote: onSaveNote,
            onReadNotes: onReadNotes,
            onSubmitRecap: onSubmitRecap
        )
    }

    // The backend's restricted JSON-schema dialect (mirrors
    // CosmoRealtime.ClientToolSchemaDialect, which is internal to the transport
    // module so it cannot be referenced here).
    private static let allowedSchemaKeys: Set<String> = [
        "type", "properties", "required", "items", "enum",
        "description", "anyOf", "default", "maxLength", "minLength",
        "maximum", "minimum",
    ]

    // The dialect's allowed `type` values (mirrors
    // CosmoRealtime.ClientToolSchemaDialect.allowedTypes).
    private static let allowedSchemaTypes: Set<String> = [
        "object", "string", "number", "integer", "boolean", "array", "null",
    ]

    @Test func toolsMatchTheRestrictedSchemaDialect() throws {
        let tools = NoteToolPack.tools
        #expect(Set(tools.map(\.name)) == ["save_note", "read_notes", "submit_recap"])
        for tool in tools {
            // wire-name legality (backend `^[a-z][a-z0-9_]{2,63}$`)
            #expect(tool.name.wholeMatch(of: #/^[a-z][a-z0-9_]{2,63}$/#) != nil)

            let parsed = try JSONSerialization.jsonObject(with: Data(tool.parametersJSON.utf8))
            let schema = try #require(parsed as? [String: Any])
            #expect(schema["type"] as? String == "object")
            #expect(Set(schema.keys).isSubset(of: Self.allowedSchemaKeys))
            let properties = try #require(schema["properties"] as? [String: Any])
            for case let child as [String: Any] in properties.values {
                #expect(Set(child.keys).isSubset(of: Self.allowedSchemaKeys))
                let type = try #require(child["type"] as? String)
                #expect(Self.allowedSchemaTypes.contains(type))
                // Array properties must declare a legal string `items` schema.
                if type == "array" {
                    let items = try #require(child["items"] as? [String: Any])
                    #expect(Set(items.keys).isSubset(of: Self.allowedSchemaKeys))
                    #expect(items["type"] as? String == "string")
                }
            }
        }
    }

    @Test func dateParamsAreOptionalStrings() throws {
        let schemas = Dictionary(
            uniqueKeysWithValues: NoteToolPack.tools.map { ($0.name, $0.parametersJSON) })
        for name in ["save_note", "read_notes"] {
            let json = try #require(schemas[name])
            let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8))
            let schema = try #require(parsed as? [String: Any])
            let properties = try #require(schema["properties"] as? [String: Any])
            let date = try #require(properties["date"] as? [String: Any], "\(name) declares 'date'")
            #expect(date["type"] as? String == "string")
            // `date` stays optional on both tools.
            let required = schema["required"] as? [String] ?? []
            #expect(!required.contains("date"))
        }
        // save_note still requires exactly its text.
        let saveNote = try #require(schemas["save_note"])
        let parsed = try JSONSerialization.jsonObject(with: Data(saveNote.utf8))
        let schema = try #require(parsed as? [String: Any])
        #expect(schema["required"] as? [String] == ["text"])
    }

    @Test func readNotesReturnsHits() async throws {
        let handler = makeHandler(
            onReadNotes: { query in
                NotesSearchResult(
                    hits: [SearchHit(noteId: "n1", title: "T", score: 1234, preview: "matched \(query)")],
                    truncated: false
                )
            }
        )
        let reply = try decode(await handler("read_notes", #"{"query":"milk"}"#))
        #expect(reply["ok"] == .bool(true))
        guard case .object(let result)? = reply["result"],
              case .array(let hits)? = result["hits"],
              case .object(let first)? = hits.first
        else {
            Issue.record("expected hits array")
            return
        }
        #expect(result["count"] == .int(1))
        #expect(result["truncated"] == .bool(false))
        #expect(first["note_id"] == .string("n1"))
        #expect(first["title"] == .string("T"))
        #expect(first["preview"] == .string("matched milk"))
    }

    @Test func badPayloadIsAnErrorReply() async throws {
        let handler = makeHandler()

        let notObject = try decode(await handler("save_note", "[1,2,3]"))
        #expect(notObject["ok"] == .bool(false))
        #expect(notObject["error"] != .null)

        let missingField = try decode(await handler("save_note", #"{"wrong":"x"}"#))
        #expect(missingField["ok"] == .bool(false))

        let unknown = try decode(await handler("nope", "{}"))
        #expect(unknown["ok"] == .bool(false))
    }

    @Test func malformedPayloadsYieldGracefulErrors() async throws {
        let handler = makeHandler()

        // Invalid JSON.
        let invalid = try decode(await handler("save_note", "{"))
        #expect(invalid["ok"] == .bool(false))
        #expect(invalid["error"] != .null)

        // Empty-string payload decodes to an empty args object, so the handler
        // reports the missing required field rather than crashing.
        let empty = try decode(await handler("save_note", ""))
        #expect(empty["ok"] == .bool(false))
        #expect(empty["error"] != .null)

        // Wrong-typed field: text is a number, not a string.
        let wrongType = try decode(await handler("save_note", #"{"text":123}"#))
        #expect(wrongType["ok"] == .bool(false))
        #expect(wrongType["error"] != .null)

        // read_notes with a wrong-typed query is likewise a graceful error.
        let badQuery = try decode(await handler("read_notes", #"{"query":123}"#))
        #expect(badQuery["ok"] == .bool(false))
    }

    @Test func readNotesAllowsOmittedQuery() async throws {
        let captured = Captured()
        let handler = makeHandler(
            onReadNotes: { query in
                await captured.set(query)
                return NotesSearchResult(hits: [], truncated: false)
            }
        )
        // No `query` key at all: recency form, not a "missing required" error.
        let reply = try decode(await handler("read_notes", "{}"))
        #expect(reply["ok"] == .bool(true))
        #expect(await captured.value == "")
    }

    @Test func readNotesAllowsEmptyQuery() async throws {
        let captured = Captured()
        let handler = makeHandler(
            onReadNotes: { query in
                await captured.set(query)
                return NotesSearchResult(hits: [], truncated: false)
            }
        )
        // Explicit empty string: also the recency form.
        let reply = try decode(await handler("read_notes", #"{"query":""}"#))
        #expect(reply["ok"] == .bool(true))
        #expect(await captured.value == "")
    }

    @Test func readNotesTreatsExplicitNullQueryAsRecency() async throws {
        let captured = Captured()
        let handler = makeHandler(
            onReadNotes: { query in
                await captured.set(query)
                return NotesSearchResult(hits: [], truncated: false)
            }
        )
        // A voice model commonly sends {"query": null} to mean "omitted": treat it
        // like the recency form, not a type error.
        let reply = try decode(await handler("read_notes", #"{"query":null}"#))
        #expect(reply["ok"] == .bool(true))
        #expect(await captured.value == "")
    }

    @Test func readNotesReportsTruncationFlag() async throws {
        let handler = makeHandler(
            onReadNotes: { _ in
                NotesSearchResult(
                    hits: [SearchHit(noteId: "n1", title: "T", score: 1, preview: "p")],
                    truncated: true
                )
            }
        )
        let reply = try decode(await handler("read_notes", #"{"query":"x"}"#))
        guard case .object(let result)? = reply["result"] else {
            Issue.record("expected result object")
            return
        }
        #expect(result["truncated"] == .bool(true))
    }

    @Test func oversizedReadNotesResultIsClampedUnder15KB() async throws {
        // Far more (and far larger) hits than can fit the 15 KB transport cap.
        let big = (0..<400).map { i in
            SearchHit(
                noteId: "note-\(i)",
                title: String(repeating: "T", count: 300),  // exceeds the 120-char title cap
                score: Double(i),
                preview: String(repeating: "preview ", count: 40)
            )
        }
        let handler = makeHandler(
            onReadNotes: { _ in NotesSearchResult(hits: big, truncated: false) }
        )
        let reply = await handler("read_notes", #"{"query":"x"}"#)
        #expect(reply.utf8.count <= ClientToolReply.maxBytes)

        let object = try decode(reply)
        #expect(object["ok"] == .bool(true))
        guard case .object(let result)? = object["result"],
              case .array(let hits)? = result["hits"]
        else {
            Issue.record("expected hits array")
            return
        }
        // Dropping hits to fit flips truncated true...
        #expect(result["truncated"] == .bool(true))
        #expect(hits.count < big.count)
        // ...and every surviving title is capped to the 120-char limit.
        for case .object(let hit) in hits {
            if case .string(let title)? = hit["title"] {
                #expect(title.count <= NoteToolPack.maxTitleLength)
            }
        }
    }

    @Test func readNotesRepliesAcrossTheReWrapBandFitTheWire() throws {
        // The RPC dispatcher decodes the reply and the transport re-wraps it
        // (+34 bytes) before the cap check; sweep preview sizes across the
        // band where the inner envelope fits but the wire form does not.
        for length in stride(from: 15_100, through: 15_450, by: 20) {
            let search = NotesSearchResult(
                hits: [
                    SearchHit(
                        noteId: "n1", title: nil, score: 1,
                        preview: String(repeating: "p", count: length))
                ],
                truncated: false
            )
            let reply = NoteToolPack.readNotesReply(search)
            let wire = ClientToolReply.envelope(ok: true, result: try decode(reply))
            #expect(wire.utf8.count <= ClientToolReply.maxBytes, "length=\(length)")
        }
    }

    @Test func nilTitleIsOmittedFromHit() async throws {
        let handler = makeHandler(
            onReadNotes: { _ in
                NotesSearchResult(
                    hits: [SearchHit(noteId: "n1", title: nil, score: 1, preview: "p")],
                    truncated: false
                )
            }
        )
        let reply = try decode(await handler("read_notes", #"{"query":"x"}"#))
        guard case .object(let result)? = reply["result"],
              case .array(let hits)? = result["hits"],
              case .object(let first)? = hits.first
        else {
            Issue.record("expected hits array")
            return
        }
        #expect(first["note_id"] == .string("n1"))
        #expect(first["title"] == nil)  // nil-title branch omits the key
    }

    @Test func submitRecordsStructuredRecapAndReturnsOk() async throws {
        let captured = CapturedRecap()
        let handler = makeHandler(onSubmitRecap: { await captured.set($0) })
        let payload = #"""
            {"summary":"We reviewed the notes design.","keyPoints":["Notes attach to a session","Search ported from macOS"],"actionItems":["Ship the SDK","Wire up the app"]}
            """#
        let reply = try decode(await handler("submit_recap", payload))
        #expect(reply["ok"] == .bool(true))

        let recap = try #require(await captured.value)
        #expect(recap.summary == "We reviewed the notes design.")
        #expect(recap.keyPoints == ["Notes attach to a session", "Search ported from macOS"])
        #expect(recap.actionItems.map(\.text) == ["Ship the SDK", "Wire up the app"])
        #expect(recap.actionItems.allSatisfy { !$0.done })
    }

    @Test func submitRecapPopulatesTitleWhenProvided() async throws {
        let captured = CapturedRecap()
        let handler = makeHandler(onSubmitRecap: { await captured.set($0) })
        let payload = #"{"title":"Trip planning chat","summary":"We planned a trip."}"#
        let reply = try decode(await handler("submit_recap", payload))
        #expect(reply["ok"] == .bool(true))
        let recap = try #require(await captured.value)
        #expect(recap.title == "Trip planning chat")
        #expect(recap.summary == "We planned a trip.")
    }

    @Test func submitRecapLeavesTitleNilWhenOmitted() async throws {
        let captured = CapturedRecap()
        let handler = makeHandler(onSubmitRecap: { await captured.set($0) })
        let reply = try decode(await handler("submit_recap", #"{"summary":"No title here."}"#))
        #expect(reply["ok"] == .bool(true))
        let recap = try #require(await captured.value)
        #expect(recap.title == nil)
        #expect(recap.summary == "No title here.")
    }

    @Test func submitRecapAllowsOmittedArrays() async throws {
        let captured = CapturedRecap()
        let handler = makeHandler(onSubmitRecap: { await captured.set($0) })
        let reply = try decode(await handler("submit_recap", #"{"summary":"Just a summary."}"#))
        #expect(reply["ok"] == .bool(true))
        let recap = try #require(await captured.value)
        #expect(recap.summary == "Just a summary.")
        #expect(recap.keyPoints.isEmpty)
        #expect(recap.actionItems.isEmpty)
    }

    @Test func malformedSubmitRecapPayloadsYieldErrors() async throws {
        let captured = CapturedRecap()
        let handler = makeHandler(onSubmitRecap: { await captured.set($0) })

        // Missing required summary.
        let missing = try decode(await handler("submit_recap", #"{"keyPoints":["a"]}"#))
        #expect(missing["ok"] == .bool(false))
        #expect(missing["error"] != .null)

        // Wrong-typed keyPoints (not an array).
        let badKeyPoints = try decode(await handler("submit_recap", #"{"summary":"s","keyPoints":"oops"}"#))
        #expect(badKeyPoints["ok"] == .bool(false))
        #expect(badKeyPoints["error"] != .null)

        // Array element of the wrong type.
        let badElement = try decode(await handler("submit_recap", #"{"summary":"s","actionItems":[1,2]}"#))
        #expect(badElement["ok"] == .bool(false))

        // Invalid JSON.
        let invalid = try decode(await handler("submit_recap", "{"))
        #expect(invalid["ok"] == .bool(false))
        #expect(invalid["error"] != .null)

        // No closure should have fired for any malformed payload.
        #expect(await captured.value == nil)
    }

    private actor Captured {
        private(set) var value: String?
        func set(_ v: String) { value = v }
    }

    private actor CapturedRecap {
        private(set) var value: Recap?
        func set(_ v: Recap) { value = v }
    }
}
