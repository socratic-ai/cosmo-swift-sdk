import Foundation

/// A standalone Markdown note the assistant writes into across sessions — a
/// daily note (one per calendar day) or an explicitly named topic note. Not a
/// session record: ``SessionNote`` stays the per-session chat store, and a
/// `Note` carries no session reference. Encodes as a `{meta, body}` envelope —
/// the on-disk document format — so the Markdown body stays separate from the
/// metadata.
public struct Note: Codable, Identifiable, Equatable, Sendable {
    /// On-disk schema version. Stamped on write so a future field change can add
    /// a migration path instead of failing to load every existing note. Required
    /// on decode: every version of this format has written the key, so its
    /// absence means the blob is not a note document.
    public static let currentSchemaVersion = 1

    /// Which kind of note this is. Ids are namespaced per kind (`daily-` vs
    /// `n-`), so kinds can never collide on one document.
    public enum Kind: Codable, Equatable, Sendable {
        /// The default note for one calendar day; `dateKey` is `YYYY-MM-DD`.
        case daily(dateKey: String)
        /// A user-requested topic note, identified by its unique title.
        case named

        /// The `daily` date key, or nil for a named note.
        public var dateKey: String? {
            if case .daily(let dateKey) = self { return dateKey }
            return nil
        }
    }

    /// Always code-generated (``dailyID(dateKey:)`` / ``newNamedID(existing:)``),
    /// never caller-supplied free text.
    public let id: String
    public let kind: Kind
    /// Daily: the date stamp; named: the unique display title.
    public var title: String
    public let createdAt: Date
    public var modifiedAt: Date
    /// Markdown, the canonical content format.
    public var body: String
    public var schemaVersion: Int

    public init(
        id: String,
        kind: Kind,
        title: String,
        createdAt: Date,
        modifiedAt: Date,
        body: String,
        schemaVersion: Int = Note.currentSchemaVersion
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.body = body
        self.schemaVersion = schemaVersion
    }

    private enum CodingKeys: String, CodingKey {
        case meta
        case body
    }

    private enum MetaKeys: String, CodingKey {
        case id
        case kind
        case title
        case createdAt
        case modifiedAt
        case schemaVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let meta = try container.nestedContainer(keyedBy: MetaKeys.self, forKey: .meta)
        id = try meta.decode(String.self, forKey: .id)
        kind = try meta.decode(Kind.self, forKey: .kind)
        title = try meta.decode(String.self, forKey: .title)
        createdAt = try meta.decode(Date.self, forKey: .createdAt)
        modifiedAt = try meta.decode(Date.self, forKey: .modifiedAt)
        body = try container.decode(String.self, forKey: .body)
        schemaVersion = try meta.decode(Int.self, forKey: .schemaVersion)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var meta = container.nestedContainer(keyedBy: MetaKeys.self, forKey: .meta)
        try meta.encode(id, forKey: .id)
        try meta.encode(kind, forKey: .kind)
        try meta.encode(title, forKey: .title)
        try meta.encode(createdAt, forKey: .createdAt)
        try meta.encode(modifiedAt, forKey: .modifiedAt)
        try meta.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(body, forKey: .body)
    }
}

extension Note {
    /// The deterministic id for one calendar day's daily note, so concurrent
    /// writes to the same day converge on one document.
    public static func dailyID(dateKey: String) -> String {
        "daily-\(dateKey)"
    }

    /// A fresh named-note id: `n-` + 8 random lowercase alphanumerics,
    /// collision-checked against `existing`.
    public static func newNamedID(existing: Set<String>) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        while true {
            let candidate = "n-" + String((0..<8).map { _ in alphabet.randomElement()! })
            if !existing.contains(candidate) { return candidate }
        }
    }
}

/// A lightweight projection of ``Note`` for listing — everything a notes list
/// shows, without the Markdown ``Note/body``. Persisted alongside each note as
/// a `<id>.summary.json` sidecar so listing never decodes a body.
public struct NoteSummary: Codable, Identifiable, Equatable, Sendable {
    /// Equals the owning ``Note/id``.
    public let id: String
    public let kind: Note.Kind
    public let title: String
    public let modifiedAt: Date
    /// Whether the note's body was empty at the last sidecar write. Nil on
    /// sidecars written before this field existed — unknown, not empty.
    public let bodyIsEmpty: Bool?

    /// The daily date key, or nil for a named note.
    public var dateKey: String? { kind.dateKey }

    public init(id: String, kind: Note.Kind, title: String, modifiedAt: Date, bodyIsEmpty: Bool? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.modifiedAt = modifiedAt
        self.bodyIsEmpty = bodyIsEmpty
    }
}

extension Note {
    /// The list-display projection of this note.
    public var summary: NoteSummary {
        NoteSummary(id: id, kind: kind, title: title, modifiedAt: modifiedAt, bodyIsEmpty: body.isEmpty)
    }
}
