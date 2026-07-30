import Foundation

/// One ranked match of a query against a kept note.
public struct SearchHit: Sendable, Equatable {
    public let noteId: String
    public let title: String?
    public let score: Double
    public let preview: String

    public init(noteId: String, title: String?, score: Double, preview: String) {
        self.noteId = noteId
        self.title = title
        self.score = score
        self.preview = preview
    }
}

/// The outcome of a ``NotesSearch/rank(query:notes:limit:)`` call: the ranked
/// hits (already clamped to `limit`) plus whether more matches existed than the
/// limit returned, so callers can surface a "more results" signal.
public struct NotesSearchResult: Sendable, Equatable {
    public let hits: [SearchHit]
    public let truncated: Bool

    public init(hits: [SearchHit], truncated: Bool) {
        self.hits = hits
        self.truncated = truncated
    }
}

/// Ranked keyword search across a note's recap, captured notes, and transcript.
/// Ports the macOS `RankedScorer`: a note scores by how many distinct query
/// terms it contains (coverage dominates) plus total term frequency, and the
/// best-matching line becomes the preview. This finds multi-term queries whose
/// words sit on different lines and orders by relevance.
public enum NotesSearch {
    public static func rank(query: String, notes: [SessionNote], limit: Int = 8) -> NotesSearchResult {
        let terms = Set(tokenize(query))
        guard !terms.isEmpty else { return NotesSearchResult(hits: [], truncated: false) }

        var scored: [(hit: SearchHit, startedAt: Date)] = []
        for note in notes {
            let lines = searchableLines(of: note)
            var distinct: Set<String> = []
            var frequency = 0
            var bestLine = 0
            var bestLineHits = -1
            for (i, line) in lines.enumerated() {
                let lineTokens = tokenize(line)
                let present = Set(lineTokens).intersection(terms)
                if present.isEmpty { continue }
                distinct.formUnion(present)
                let lineFreq = lineTokens.filter { terms.contains($0) }.count
                frequency += lineFreq
                if lineFreq > bestLineHits {
                    bestLineHits = lineFreq
                    bestLine = i
                }
            }
            guard !distinct.isEmpty else { continue }
            // Coverage dominates frequency so a note matching more distinct terms
            // always outranks one matching a single term many times.
            let score = Double(distinct.count) * 1000 + Double(frequency)
            let hit = SearchHit(
                noteId: note.id, title: note.title, score: score,
                preview: previewLine(lines[bestLine])
            )
            scored.append((hit, note.startedAt))
        }
        scored.sort { lhs, rhs in
            lhs.hit.score != rhs.hit.score
                ? lhs.hit.score > rhs.hit.score
                : lhs.startedAt > rhs.startedAt
        }
        let totalMatchedDocs = scored.count
        let hits = Array(scored.prefix(limit).map(\.hit))
        return NotesSearchResult(hits: hits, truncated: totalMatchedDocs > limit)
    }

    /// Newest-first recall with no keyword filter: the fallback for recency asks
    /// ("what did we discuss last session") that share no content words with any
    /// note. Orders by ``SessionNote/startedAt`` descending, previews the recap
    /// summary when present (else the first transcript line), and reuses the same
    /// preview/truncation shape as ``rank(query:notes:limit:)``.
    public static func recent(notes: [SessionNote], limit: Int = 8) -> NotesSearchResult {
        let sorted = notes.sorted { $0.startedAt > $1.startedAt }
        let hits = sorted.prefix(limit).map { note in
            let raw = note.recap?.summary ?? note.lines.first?.text ?? ""
            return SearchHit(
                noteId: note.id,
                title: note.title,
                score: note.startedAt.timeIntervalSince1970,
                preview: previewLine(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            )
        }
        return NotesSearchResult(hits: Array(hits), truncated: notes.count > limit)
    }

    /// Newest-first recall built from the cheap ``SessionNoteSummary`` sidecars
    /// alone — no transcript decode. This is the recency path's preferred input:
    /// the app pairs it with ``NoteStore/list()`` so answering "what did we
    /// discuss last session" never loads a full note. Previews the recap summary
    /// (the only content a summary carries). Keyword search still needs full
    /// notes and stays on ``rank(query:notes:limit:)``.
    public static func recent(summaries: [SessionNoteSummary], limit: Int = 8) -> NotesSearchResult {
        let sorted = summaries.sorted { $0.startedAt > $1.startedAt }
        let hits = sorted.prefix(limit).map { summary in
            SearchHit(
                noteId: summary.id,
                title: summary.title,
                score: summary.startedAt.timeIntervalSince1970,
                preview: previewLine(
                    (summary.recapSummary ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            )
        }
        return NotesSearchResult(hits: Array(hits), truncated: summaries.count > limit)
    }

    /// Flatten everything a note exposes to search into newline-joined lines,
    /// then split — mirroring the macOS corpus's per-line scoring.
    private static func searchableLines(of note: SessionNote) -> [String] {
        var parts: [String] = []
        if let title = note.title { parts.append(title) }
        if let recap = note.recap {
            parts.append(recap.summary)
            parts.append(contentsOf: recap.keyPoints)
            parts.append(contentsOf: recap.actionItems.map(\.text))
        }
        parts.append(contentsOf: note.notes.map(\.text))
        parts.append(contentsOf: note.lines.map(\.text))
        return parts.joined(separator: "\n").components(separatedBy: "\n")
    }

    private static func tokenize(_ s: String) -> [String] {
        s.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
    }

    private static func previewLine(_ line: String, max: Int = 240) -> String {
        line.count > max ? String(line.prefix(max)) + "…" : line
    }
}
