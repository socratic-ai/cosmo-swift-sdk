import Foundation

/// One row in the live transcript. Independent of any view layer: the same
/// type is consumed by macOS SwiftUI views today and by a future iOS UI.
public struct TranscriptLine: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public let kind: Kind
    public let text: String
    /// Populated only when ``kind == .tool``.
    public let toolDetails: ToolDetails?
    /// A locally-originated user text turn whose wire send failed — surfaced so
    /// the user knows the model never received what's in the bubble. Always
    /// `false` for wire-sourced lines. Transient UI state; decodes to `false`
    /// when absent so older on-disk transcripts still load (see custom
    /// ``init(from:)``).
    public let deliveryFailed: Bool

    /// Stable string raw values: this type is persisted to the macOS on-disk
    /// session store (`transcript.jsonl`) and read back across app versions, so
    /// the wire/disk spelling must not drift with case renames.
    public enum Kind: String, Equatable, Sendable, Codable {
        case user
        case assistant
        case tool
        case system
        case error
    }

    public struct ToolDetails: Equatable, Sendable, Codable {
        public let callId: String
        public let name: String
        public let ok: Bool?
        public let summary: String?

        public init(callId: String, name: String, ok: Bool?, summary: String?) {
            self.callId = callId
            self.name = name
            self.ok = ok
            self.summary = summary
        }
    }

    public init(
        id: UUID = UUID(),
        kind: Kind,
        text: String,
        toolDetails: ToolDetails? = nil,
        deliveryFailed: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.toolDetails = toolDetails
        self.deliveryFailed = deliveryFailed
    }

    // Custom decode so `deliveryFailed`, added after the on-disk format was
    // already in use, defaults to `false` when absent from an older
    // `transcript.jsonl`. Encoding stays synthesized.
    private enum CodingKeys: String, CodingKey {
        case id, kind, text, toolDetails, deliveryFailed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.kind = try c.decode(Kind.self, forKey: .kind)
        self.text = try c.decode(String.self, forKey: .text)
        self.toolDetails = try c.decodeIfPresent(ToolDetails.self, forKey: .toolDetails)
        self.deliveryFailed = try c.decodeIfPresent(Bool.self, forKey: .deliveryFailed) ?? false
    }
}
