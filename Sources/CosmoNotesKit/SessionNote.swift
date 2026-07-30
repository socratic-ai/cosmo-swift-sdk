import CosmoRealtime
import Foundation

/// The whole record kept for one voice session: its transcript, any notes
/// captured mid-call, and the end-of-session recap. Self-contained and
/// `Codable` so the store can write it as a single JSON file; the app maps its
/// live transcript lines into ``NoteLine`` rather than this kit depending on any
/// app type.
public struct SessionNote: Codable, Equatable, Sendable, Identifiable {
    /// On-disk schema version. Stamped on write so a future field change can add
    /// a migration path instead of failing `load(id:)` for every existing note.
    /// Decoding is tolerant: a v0 file with no `schemaVersion` key decodes with
    /// this default rather than throwing (see `init(from:)`).
    public static let currentSchemaVersion = 1

    /// Equals the realtime `sessionId`, so a session has exactly one note.
    public let id: String
    public let startedAt: Date
    public var endedAt: Date?
    /// Derived display title (e.g. the first user line); nil until set.
    public var title: String?
    public var lines: [NoteLine]
    public var notes: [CapturedNote]
    public var recap: Recap?
    public var schemaVersion: Int

    public init(
        id: String,
        startedAt: Date,
        endedAt: Date? = nil,
        title: String? = nil,
        lines: [NoteLine] = [],
        notes: [CapturedNote] = [],
        recap: Recap? = nil,
        schemaVersion: Int = SessionNote.currentSchemaVersion
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.title = title
        self.lines = lines
        self.notes = notes
        self.recap = recap
        self.schemaVersion = schemaVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        lines = try container.decodeIfPresent([NoteLine].self, forKey: .lines) ?? []
        notes = try container.decodeIfPresent([CapturedNote].self, forKey: .notes) ?? []
        recap = try container.decodeIfPresent(Recap.self, forKey: .recap)
        // Back-compat: existing v0 files have no `schemaVersion` key.
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Self.currentSchemaVersion
    }
}

/// A lightweight projection of ``SessionNote`` for listing: identity, timing,
/// title, recap summary text, and counts — everything the notes list UI shows —
/// without the bulky transcript ``SessionNote/lines`` or captured
/// ``SessionNote/notes``. Persisted alongside each note as a `<id>.summary.json`
/// sidecar so ``NoteStore/list()`` never has to decode a full transcript.
public struct SessionNoteSummary: Codable, Sendable, Equatable, Identifiable {
    /// Equals the owning ``SessionNote/id``.
    public let id: String
    public let startedAt: Date
    public let endedAt: Date?
    public let title: String?
    /// The recap's `summary` text, or nil if the session has no recap.
    public let recapSummary: String?
    /// Number of transcript lines, mirrored so the list need not load them.
    public let lineCount: Int
    /// Number of mid-session captured notes.
    public let noteCount: Int

    public init(
        id: String,
        startedAt: Date,
        endedAt: Date? = nil,
        title: String? = nil,
        recapSummary: String? = nil,
        lineCount: Int,
        noteCount: Int
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.title = title
        self.recapSummary = recapSummary
        self.lineCount = lineCount
        self.noteCount = noteCount
    }
}

extension SessionNote {
    /// The list-display projection of this note. Derives `recapSummary` from the
    /// recap (if any) and the counts from the transcript/captured-note arrays.
    public var summary: SessionNoteSummary {
        SessionNoteSummary(
            id: id,
            startedAt: startedAt,
            endedAt: endedAt,
            title: title,
            recapSummary: recap?.summary,
            lineCount: lines.count,
            noteCount: notes.count
        )
    }
}

/// One transcript turn reduced to what the note keeps. ``Role`` is reused from
/// the SDK (`.user` / `.assistant`) since it is exactly this shape.
public struct NoteLine: Codable, Equatable, Sendable {
    public let role: Role
    public let text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

/// A note captured mid-session — typically "Cosmo, note that down".
public struct CapturedNote: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        case assistant
        case user
    }

    public var text: String
    public let createdAt: Date
    public let source: Source

    public init(text: String, createdAt: Date = Date(), source: Source) {
        self.text = text
        self.createdAt = createdAt
        self.source = source
    }
}

/// The end-of-session AI recap.
public struct Recap: Codable, Equatable, Sendable {
    /// A short 3-6 word title for the session, set by the model in submit_recap;
    /// nil when the model omits it. Optional + tolerant-decoded so existing
    /// recaps with no `title` key still decode.
    public var title: String?
    public var summary: String
    public var keyPoints: [String]
    public var actionItems: [ActionItem]

    public init(
        title: String? = nil,
        summary: String,
        keyPoints: [String] = [],
        actionItems: [ActionItem] = []
    ) {
        self.title = title
        self.summary = summary
        self.keyPoints = keyPoints
        self.actionItems = actionItems
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        summary = try container.decode(String.self, forKey: .summary)
        keyPoints = try container.decodeIfPresent([String].self, forKey: .keyPoints) ?? []
        actionItems = try container.decodeIfPresent([ActionItem].self, forKey: .actionItems) ?? []
    }
}

/// One recap action item, toggleable in the UI.
public struct ActionItem: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var text: String
    public var done: Bool

    public init(id: UUID = UUID(), text: String, done: Bool = false) {
        self.id = id
        self.text = text
        self.done = done
    }
}
