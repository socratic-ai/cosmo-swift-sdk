import CosmoRealtime
import Foundation

/// The client-declared note tools and the RPC handler that services them,
/// decoupled from app state via closures. Wire it up in two lines at session
/// start: advertise ``tools`` and install ``handler``.
public enum NoteToolPack {
    public static let saveNoteName = "save_note"
    public static let readNotesName = "read_notes"
    public static let submitRecapName = "submit_recap"
    public static let group = "notes"

    /// Declarations for the tools — pass straight to the session's
    /// `declaredTools`. Schemas use the backend's restricted dialect
    /// (`type/properties/required/description`).
    public static var tools: [DeclaredClientTool] {
        [
            DeclaredClientTool(
                name: saveNoteName,
                description:
                    "Save a short note for the user — use it when the user says \"note that "
                    + "down\" or asks you to remember something. The note is appended to the "
                    + "user's daily note (today's by default, or the given date's) and kept on "
                    + "this session's record.",
                parametersJSON: #"""
                {"type":"object","properties":{"text":{"type":"string","description":"The note to save, in the user's words."},"date":{"type":"string","description":"Optional YYYY-MM-DD day whose daily note to append to; omit for today."}},"required":["text"]}
                """#,
                group: group
            ),
            DeclaredClientTool(
                name: readNotesName,
                description:
                    "Recall the user's notes and past sessions. Pass keywords to find matching "
                    + "notes, or call with an empty/omitted query to get the most recent sessions "
                    + "— use the empty-query form to answer 'what did we discuss last time / last "
                    + "session / recently'. Pass a YYYY-MM-DD date to read that day's daily note "
                    + "instead; if that day has no note, the reply lists the dates that do.",
                parametersJSON: #"""
                {"type":"object","properties":{"query":{"type":"string","description":"Keywords to search past notes for; may be empty or omitted to return the most recent sessions."},"date":{"type":"string","description":"Optional YYYY-MM-DD day whose daily note to read; when given, search is skipped."}}}
                """#,
                group: group
            ),
            DeclaredClientTool(
                name: submitRecapName,
                description:
                    "Submit the end-of-session recap as structured data. Call this when wrapping up: "
                    + "provide a short 3-6 word title, a concise summary, the key points discussed, and "
                    + "any action items the user should follow up on — do not print the recap as plain text.",
                // Uses the dialect's array support (`type:"array"` + `items`), which
                // the backend's restricted schema (`ClientToolSchemaDialect`) allows.
                parametersJSON: #"""
                {"type":"object","properties":{"title":{"type":"string","description":"A short 3-6 word title for the session."},"summary":{"type":"string","description":"One or two sentences summarizing the session."},"keyPoints":{"type":"array","items":{"type":"string"},"description":"Short bullet strings of the main points discussed."},"actionItems":{"type":"array","items":{"type":"string"},"description":"Short strings, each a thing the user should do next."}},"required":["summary"]}
                """#,
                group: group
            ),
        ]
    }

    /// The methods this pack services — pass to `setClientToolHandler(methods:)`.
    public static var methods: [String] { [saveNoteName, readNotesName, submitRecapName] }

    /// Build the daily-note RPC handler. `save_note` resolves its target day
    /// through ``NoteTargetResolver`` — sampling `now()`/`timeZone()` at the
    /// moment of the call — appends through the store's atomic primitive, and
    /// hands the text to `onSaveNote` whether or not the append was refused,
    /// so the chat record keeps every accepted save even when the daily-note
    /// write fails (the reply still reports the refusal). `read_notes` with a
    /// `date` returns that day's note content
    /// (head-capped), or only the dates that have notes when the day is empty
    /// or its file is refused; without `date` it runs the search/recency form
    /// through `onReadNotes`.
    public static func handler(
        store: NoteDocumentStore,
        now: @escaping @Sendable () -> Date = { Date() },
        timeZone: @escaping @Sendable () -> TimeZone = { TimeZone.current },
        onSaveNote: @escaping @Sendable (String) async -> Void,
        onReadNotes: @escaping @Sendable (String) async -> NotesSearchResult,
        onSubmitRecap: @escaping @Sendable (Recap) async -> Void
    ) -> ClientToolRPCHandler {
        { method, payload in
            switch method {
            case saveNoteName:
                guard let args = decodeObject(payload) else {
                    return ClientToolReply.envelope(ok: false, error: "args must be a JSON object")
                }
                let text: String
                switch parseSaveNoteText(args) {
                case .errorReply(let reply): return reply
                case .text(let value): text = value
                }
                let target: NoteTargetResolver.DailyTarget
                switch resolveDailyTarget(args, now: now(), timeZone: timeZone()) {
                case .errorReply(let reply): return reply
                case .target(let value): target = value
                }
                let outcome = await store.append(
                    text: text,
                    id: target.id,
                    kind: .daily(dateKey: target.dateKey),
                    title: target.dateKey,
                    header: MarkdownSections.dailyHeader(stamp: target.dateKey)
                )
                switch outcome {
                case .refused(let refusal):
                    await onSaveNote(text)
                    return ClientToolReply.envelope(ok: false, error: message(for: refusal))
                case .appended(let note, let created):
                    await onSaveNote(text)
                    return ClientToolReply.envelope(ok: true, result: [
                        "note_id": .string(note.id),
                        "title": .string(note.title),
                        "created": .bool(created),
                    ])
                }

            case readNotesName:
                guard let args = decodeObject(payload) else {
                    return ClientToolReply.envelope(ok: false, error: "args must be a JSON object")
                }
                // A `date` selects the day-lookup form; search/recency only
                // apply when no date is given.
                switch stringArg(args, "date") {
                case .wrongType:
                    return ClientToolReply.envelope(ok: false, error: "'date' must be a YYYY-MM-DD string")
                case .value:
                    let target: NoteTargetResolver.DailyTarget
                    switch resolveDailyTarget(args, now: now(), timeZone: timeZone()) {
                    case .errorReply(let reply): return reply
                    case .target(let value): target = value
                    }
                    return await dayReply(target, store: store)
                case .absent:
                    return await searchReply(args, onReadNotes: onReadNotes)
                }

            case submitRecapName:
                return await submitRecapReply(payload, onSubmitRecap: onSubmitRecap)

            default:
                return ClientToolReply.envelope(ok: false, error: "unknown method '\(method)'")
            }
        }
    }

    // MARK: - Reply shaping

    /// Cap an individual hit's title so one pathological note can't dominate the
    /// reply budget (and to keep what the model reads concise).
    static let maxTitleLength = 120
    /// Cap the `save_note` text so a runaway model can't write unbounded content
    /// to disk; clamped before it reaches `onSaveNote`.
    static let maxSaveNoteLength = 4000
    /// Initial head-cap for one day's note content (the macOS notes tools'
    /// capture cap); ``dayContentReply(noteID:dateKey:body:)`` shrinks below
    /// it until the re-wrapped reply fits ``ClientToolReply/maxBytes``.
    static let dayContentMaxBytes = 12_000
    /// How many daily-note date keys the empty-day fallback lists.
    static let maxAvailableDates = 30

    /// Build the `read_notes` success reply: a `truncated` flag plus the hits,
    /// dropping hits from the end until the re-wrapped reply fits
    /// ``ClientToolReply/maxBytes`` (flipping `truncated` true when it has to).
    static func readNotesReply(_ search: NotesSearchResult) -> String {
        var hits = search.hits
        var truncated = search.truncated
        while true {
            let body: [String: JSONValue] = [
                "count": .int(hits.count),
                "truncated": .bool(truncated),
                "hits": .array(hits.map(encode)),
            ]
            if ClientToolReply.rewrappedSize(ok: true, result: body) <= ClientToolReply.maxBytes
                || hits.isEmpty
            {
                return ClientToolReply.envelope(ok: true, result: body)
            }
            hits.removeLast()
            truncated = true
        }
    }

    /// Truncate `text` to at most `maxBytes` of UTF-8 by trimming from the
    /// head — a daily note grows by appending, so the most recent entries are
    /// what the model needs. The cut lands on a character boundary, dropping a
    /// multi-byte character whole rather than splitting it.
    static func headCapped(
        _ text: String, maxBytes: Int = dayContentMaxBytes
    ) -> (text: String, truncated: Bool) {
        let utf8 = text.utf8
        guard utf8.count > maxBytes else { return (text, false) }
        var cut = utf8.index(utf8.endIndex, offsetBy: -maxBytes)
        while cut != utf8.endIndex, cut.samePosition(in: text) == nil {
            cut = utf8.index(after: cut)
        }
        let index = cut.samePosition(in: text) ?? text.endIndex
        return (String(text[index...]), true)
    }

    // MARK: - Shared handler pieces

    private enum ParsedSaveNoteText {
        case text(String)
        case errorReply(String)
    }

    /// Decode, clamp, and reject-empty the `save_note` text.
    private static func parseSaveNoteText(_ args: [String: JSONValue]) -> ParsedSaveNoteText {
        guard let text = string(args, "text") else {
            return .errorReply(ClientToolReply.envelope(ok: false, error: "missing required 'text'"))
        }
        // Clamp before handing off so a runaway model can't write
        // unbounded content to disk.
        let clamped = String(text.prefix(maxSaveNoteLength))
        // Reject an empty/whitespace-only note: storing it would write a
        // blank note and bias the recap default toward Keep.
        guard !clamped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .errorReply(ClientToolReply.envelope(ok: false, error: "note text is empty"))
        }
        return .text(clamped)
    }

    private enum ResolvedDailyTarget {
        case target(NoteTargetResolver.DailyTarget)
        case errorReply(String)
    }

    /// Resolve the daily target from the call's optional `date` argument.
    private static func resolveDailyTarget(
        _ args: [String: JSONValue], now: Date, timeZone: TimeZone
    ) -> ResolvedDailyTarget {
        var targets: [NoteTargetResolver.Target] = []
        switch stringArg(args, "date") {
        case .value(let stamp): targets.append(.date(stamp))
        case .absent: break
        case .wrongType:
            return .errorReply(
                ClientToolReply.envelope(ok: false, error: "'date' must be a YYYY-MM-DD string"))
        }
        switch NoteTargetResolver.resolveDaily(targets: targets, now: now, timeZone: timeZone) {
        case .resolved(let target):
            return .target(target)
        case .invalidDate(let stamp):
            // Echo at most 64 characters: a runaway stamp would blow the reply
            // past the transport cap and destroy the corrective hint.
            return .errorReply(ClientToolReply.envelope(
                ok: false, error: "'\(stamp.prefix(64))' is not a valid YYYY-MM-DD calendar date"))
        }
    }

    private static func message(for refusal: NoteAppendRefusal) -> String {
        let reason: String
        switch refusal {
        case .unreadable:
            reason = "the note file can't be read right now"
        case .newerSchema:
            reason = "it was written by a newer app version"
        case .quarantineFailed:
            reason = "the note file is damaged and couldn't be set aside"
        case .writeFailed:
            reason = "the write failed"
        }
        return "couldn't write the daily note (\(reason)); the text was kept in this chat's record"
    }

    /// The day-lookup reply: the day's content head-capped, or — when the day
    /// is empty or its file is refused — only the daily dates that do have
    /// notes, so the model corrects itself instead of inventing content.
    private static func dayReply(
        _ target: NoteTargetResolver.DailyTarget, store: NoteDocumentStore
    ) async -> String {
        if let note = await store.load(id: target.id), !note.body.isEmpty {
            return dayContentReply(noteID: note.id, dateKey: target.dateKey, body: note.body)
        }
        // An empty-bodied note can exist for any day (loadOrCreate seeds one);
        // offering such a day — or the queried day itself, whose older sidecar
        // may predate the emptiness signal — sends the model to a day with no
        // content to read.
        let dates = await store.list()
            .filter { $0.bodyIsEmpty != true }
            .compactMap(\.dateKey)
            .filter { $0 != target.dateKey }
            .sorted(by: >)
            .prefix(maxAvailableDates)
        return ClientToolReply.envelope(ok: true, result: [
            "available_dates": .array(dates.map(JSONValue.string)),
        ])
    }

    /// The content reply for one day, shrunk from the head until the
    /// re-wrapped reply fits ``ClientToolReply/maxBytes`` — JSON escaping and
    /// the dispatcher's re-wrap both inflate past any raw-byte cap, and the
    /// transport fails an oversized reply closed, which would leave a grown
    /// day permanently unreadable.
    static func dayContentReply(noteID: String, dateKey: String, body: String) -> String {
        var budget = dayContentMaxBytes
        var capped = headCapped(body, maxBytes: budget)
        while true {
            let result: [String: JSONValue] = [
                "note_id": .string(noteID),
                "date": .string(dateKey),
                "content": .string(capped.text),
                "truncated": .bool(capped.truncated),
            ]
            let size = ClientToolReply.rewrappedSize(ok: true, result: result)
            if size <= ClientToolReply.maxBytes || capped.text.isEmpty {
                return ClientToolReply.envelope(ok: true, result: result)
            }
            // Escaping inflates each kept byte by a content-dependent factor,
            // so scale the raw budget by the overshoot ratio (subtracting the
            // serialized overflow from it can overshoot to empty); the
            // min(budget - 1, _) keeps the shrink strictly decreasing.
            budget = max(0, min(budget - 1, budget * ClientToolReply.maxBytes / size))
            capped = budget > 0 ? headCapped(body, maxBytes: budget) : ("", true)
        }
    }

    /// The search/recency reply — `read_notes` with no `date`.
    private static func searchReply(
        _ args: [String: JSONValue],
        onReadNotes: @Sendable (String) async -> NotesSearchResult
    ) async -> String {
        // `query` is optional: an absent key — or an explicit JSON null,
        // which voice models commonly send to mean "omitted" — means
        // "recent sessions" and maps to an empty query the controller
        // turns into recency recall. A present value of a genuinely wrong
        // type (number/object/etc.) is still a graceful error.
        let query: String
        switch stringArg(args, "query") {
        case .value(let s): query = s
        case .absent: query = ""
        case .wrongType:
            return ClientToolReply.envelope(ok: false, error: "'query' must be a string")
        }
        let search = await onReadNotes(query)
        return readNotesReply(search)
    }

    private static func submitRecapReply(
        _ payload: String,
        onSubmitRecap: @Sendable (Recap) async -> Void
    ) async -> String {
        guard let args = decodeObject(payload) else {
            return ClientToolReply.envelope(ok: false, error: "args must be a JSON object")
        }
        guard let summary = string(args, "summary") else {
            return ClientToolReply.envelope(ok: false, error: "missing required 'summary'")
        }
        guard let keyPoints = stringArray(args, "keyPoints") else {
            return ClientToolReply.envelope(ok: false, error: "'keyPoints' must be an array of strings")
        }
        guard let actionTexts = stringArray(args, "actionItems") else {
            return ClientToolReply.envelope(ok: false, error: "'actionItems' must be an array of strings")
        }
        // `title` is optional: absent, null, or a wrong-typed value all
        // yield nil rather than an error, so a missing title never blocks
        // recording a recap.
        let title = string(args, "title")
        let recap = Recap(
            title: title,
            summary: summary,
            keyPoints: keyPoints,
            actionItems: actionTexts.map { ActionItem(id: UUID(), text: $0, done: false) }
        )
        await onSubmitRecap(recap)
        return ClientToolReply.envelope(ok: true, result: ["recorded": .bool(true)])
    }

    // MARK: - Argument decoding

    /// An optional string argument, distinguishing "not given" (absent, an
    /// explicit JSON null, or an empty string — the ways voice models express
    /// an omitted parameter) from "given with the wrong type".
    private enum StringArg {
        case value(String)
        case absent
        case wrongType
    }

    private static func stringArg(_ object: [String: JSONValue], _ key: String) -> StringArg {
        switch object[key] {
        case .some(.string(let value)): return value.isEmpty ? .absent : .value(value)
        case .none, .some(.null): return .absent
        case .some: return .wrongType
        }
    }

    private static func encode(_ hit: SearchHit) -> JSONValue {
        var object: [String: JSONValue] = [
            "note_id": .string(hit.noteId),
            "score": .double(hit.score),
            "preview": .string(hit.preview),
        ]
        if let title = hit.title { object["title"] = .string(String(title.prefix(maxTitleLength))) }
        return .object(object)
    }

    private static func decodeObject(_ payload: String) -> [String: JSONValue]? {
        if payload.isEmpty { return [:] }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8)),
              case .object(let object) = value
        else { return nil }
        return object
    }

    private static func string(_ object: [String: JSONValue], _ key: String) -> String? {
        if case .string(let value)? = object[key] { return value }
        return nil
    }

    /// Decode an optional array-of-strings field. An absent key yields an empty
    /// array (the field is optional); a present-but-wrong-typed value (not an
    /// array, or an array with a non-string element) yields `nil` so the caller
    /// can return an error reply.
    private static func stringArray(_ object: [String: JSONValue], _ key: String) -> [String]? {
        guard let value = object[key] else { return [] }
        guard case .array(let items) = value else { return nil }
        var out: [String] = []
        for item in items {
            guard case .string(let s) = item else { return nil }
            out.append(s)
        }
        return out
    }
}
