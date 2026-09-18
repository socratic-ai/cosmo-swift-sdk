import CosmoRealtimeAPI
import Foundation

/// Speaker for a transcript fragment.
@frozen public enum TranscriptRole: String, Codable, Hashable, Sendable, CaseIterable {
    case user = "USER"
    case assistant = "ASSISTANT"
}

/// One coalesced turn in ``RealtimeSession/transcript``.
///
/// ``id`` is a stable render key, minted when the turn opens and never
/// reused. While ``isFinal`` is `false` the turn is in progress: its
/// ``text`` may grow, be replaced wholesale by the closing final, or the
/// item may be removed entirely (a retracted turn). Once ``isFinal`` is
/// `true` the item never changes again.
public struct TranscriptItem: Sendable, Equatable, Identifiable {
    /// Stable render key for this turn, minted when it opens and never
    /// reused, so a list can update in place rather than re-key.
    public let id: String
    /// Who spoke.
    public let role: TranscriptRole
    /// The turn's text so far, coalesced from the deltas.
    public let text: String
    /// Whether the turn is closed. A closed turn never changes again.
    public let isFinal: Bool

    /// Creates a transcript item. The session builds these; you read them.
    public init(id: String, role: TranscriptRole, text: String, isFinal: Bool) {
        self.id = id
        self.role = role
        self.text = text
        self.isFinal = isFinal
    }
}

/// The session's coalesced transcript changed. ``items`` is the complete
/// updated transcript — replace, don't merge. The same value is readable
/// at any time as ``RealtimeSession/transcript``.
public struct TranscriptUpdatedEvent: Sendable, Equatable {
    /// The complete transcript after this change — replace what you held, do
    /// not merge.
    public let items: [TranscriptItem]
    /// Creates the event. The session synthesizes these; you receive one.
    public init(items: [TranscriptItem]) { self.items = items }
}

private func isBlank(_ text: String) -> Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

/// Session-owned coalesced transcript fold.
///
/// The session folds its transcript and turn-complete streams into turn
/// items so consumers read state (``RealtimeSession/transcript`` /
/// ``RealtimeSessionEvent/transcriptUpdated(_:)``) instead of implementing the
/// wire's folding rules: an empty final retracts a leaked turn, a
/// turn-complete closes a line whose final was skipped server-side, and a
/// final arriving with no open bubble (a silent session's committed
/// chunk, a ``RealtimeSession/send(text:transcript:)`` echo) lands as its
/// own closed item. Coalescing is by the most recent still-open bubble
/// for the delta's role — robust to barge-in interleaving — and there is
/// at most one open bubble per role at a time. Python's
/// ``session/_transcript.py`` and TypeScript's ``core/transcript_state.ts``
/// mirror these semantics.
struct TranscriptStore {
    private(set) var current: [TranscriptItem] = []

    /// Index of the role's open bubble, or `nil` when none. At most one
    /// open bubble per role exists, but it is not necessarily the role's
    /// most recent item — a ``RealtimeSession/send(text:transcript:)`` echo
    /// lands as a closed item after a still-transcribing speech turn — so
    /// closed items are skipped, not treated as "that turn is done, stop
    /// looking".
    private func openIndex(role: TranscriptRole) -> Int? {
        for i in stride(from: current.count - 1, through: 0, by: -1) {
            guard current[i].role == role, !current[i].isFinal else { continue }
            return i
        }
        return nil
    }

    /// Fold one transcript delta. Returns whether the transcript changed.
    mutating func applyDelta(role: TranscriptRole, text: String, isFinal: Bool) -> Bool {
        if let idx = openIndex(role: role) {
            let entry = current[idx]
            if isFinal {
                // The final is the authoritative turn text: replace the
                // accumulation. An empty final retracts the turn — the
                // server sends one only when streamed partials must not
                // stand (a suppressed/garbled line).
                if isBlank(text) {
                    current.remove(at: idx)
                } else {
                    current[idx] = TranscriptItem(
                        id: entry.id, role: entry.role, text: text, isFinal: true
                    )
                }
            } else {
                if text.isEmpty { return false }
                current[idx] = TranscriptItem(
                    id: entry.id, role: entry.role, text: entry.text + text, isFinal: false
                )
            }
            return true
        }
        // No open bubble. A blank delta must not open one (it would render
        // as an empty bubble); a non-blank final with no open bubble is a
        // complete turn in one event and lands closed.
        if isBlank(text) { return false }
        current.append(
            TranscriptItem(id: UUID().uuidString, role: role, text: text, isFinal: isFinal)
        )
        return true
    }

    /// Append a complete turn of its own — the send(text:) echo. Never
    /// folds into or closes an open bubble: typed text is not part of an
    /// in-progress speech turn, whose deltas keep folding into their own
    /// bubble. Returns whether the transcript changed.
    mutating func appendClosed(role: TranscriptRole, text: String) -> Bool {
        if isBlank(text) { return false }
        current.append(
            TranscriptItem(id: UUID().uuidString, role: role, text: text, isFinal: true)
        )
        return true
    }

    /// Close the role's dangling open bubble, if any. The normal path
    /// closes bubbles on their final; this catches a line whose final the
    /// server skipped (already-committed silent-session text), which would
    /// otherwise merge into the next turn.
    mutating func applyTurnComplete(role: TranscriptRole) -> Bool {
        guard let idx = openIndex(role: role) else { return false }
        let entry = current[idx]
        if isBlank(entry.text) {
            current.remove(at: idx)
        } else {
            current[idx] = TranscriptItem(
                id: entry.id, role: entry.role, text: entry.text, isFinal: true
            )
        }
        return true
    }

    /// Close every still-open bubble; runs at session teardown so the
    /// surviving transcript holds no forever-open turns.
    mutating func closeOpen() -> Bool {
        var changed = false
        for i in stride(from: current.count - 1, through: 0, by: -1) {
            let item = current[i]
            guard !item.isFinal else { continue }
            if isBlank(item.text) {
                current.remove(at: i)
            } else {
                current[i] = TranscriptItem(
                    id: item.id, role: item.role, text: item.text, isFinal: true
                )
            }
            changed = true
        }
        return changed
    }
}
