import Foundation
import Testing

@testable import CosmoNotesKit

@Suite struct NotesSearchTests {
    // Words deliberately span recap / captured notes / transcript and multiple
    // lines, mirroring the macOS NotesSearch corpus intent.
    private let notes: [SessionNote] = [
        SessionNote(
            id: "2026-06-18",
            startedAt: Date(timeIntervalSince1970: 1_718_000_000),
            title: "WeWork sync",
            lines: [
                NoteLine(role: .user, text: "Went to Indiranagar WeWork."),
                NoteLine(role: .assistant, text: "Met Utkarsh and Sambhav about the launch."),
            ],
            recap: Recap(summary: "Planning meeting", keyPoints: ["launch timing"])
        ),
        SessionNote(
            id: "2026-06-17",
            startedAt: Date(timeIntervalSince1970: 1_717_900_000),
            title: "Architecture",
            lines: [NoteLine(role: .assistant, text: "TODO: create client-side notes tools.")],
            notes: [CapturedNote(text: "Decided reminders should be app-owned.", source: .user)]
        ),
        SessionNote(
            id: "2026-06-15",
            startedAt: Date(timeIntervalSince1970: 1_717_700_000),
            title: "Search spike",
            lines: [NoteLine(role: .user, text: "Explored local embeddings for search.")]
        ),
    ]

    @Test func caseInsensitiveSingleTerm() {
        let result = NotesSearch.rank(query: "wework", notes: notes, limit: 5)
        #expect(result.hits.first?.noteId == "2026-06-18")
    }

    @Test func findsMultiTermAcrossLines() {
        // "utkarsh wework" appears on no single line; coverage ranking still wins.
        let result = NotesSearch.rank(query: "utkarsh wework", notes: notes, limit: 5)
        #expect(result.hits.first?.noteId == "2026-06-18")
    }

    @Test func matchesRecapAndCapturedNotes() {
        #expect(NotesSearch.rank(query: "reminders", notes: notes, limit: 5).hits.first?.noteId == "2026-06-17")
        #expect(NotesSearch.rank(query: "embeddings", notes: notes, limit: 5).hits.first?.noteId == "2026-06-15")
    }

    @Test func ordersByCoverageThenFrequency() {
        let result = NotesSearch.rank(query: "wework launch", notes: notes, limit: 5)
        #expect(result.hits.first?.noteId == "2026-06-18")
    }

    @Test func emptyQueryReturnsNothing() {
        let result = NotesSearch.rank(query: "   ", notes: notes, limit: 5)
        #expect(result.hits.isEmpty)
        #expect(result.truncated == false)
    }

    @Test func respectsLimit() {
        let result = NotesSearch.rank(query: "the", notes: notes, limit: 1)
        #expect(result.hits.count <= 1)
    }

    @Test func truncatedWhenMoreMatchesThanLimit() {
        // All three notes contain "the"-ish coverage via shared terms; query a
        // term that matches multiple notes and cap the limit below that count.
        let all = NotesSearch.rank(query: "wework launch reminders embeddings", notes: notes, limit: 5)
        #expect(all.truncated == false)
        let capped = NotesSearch.rank(query: "wework launch reminders embeddings", notes: notes, limit: 1)
        #expect(capped.hits.count == 1)
        #expect(capped.truncated == true)
    }

    @Test func hitCarriesTitleAndPreview() throws {
        let hit = try #require(NotesSearch.rank(query: "utkarsh", notes: notes, limit: 5).hits.first)
        #expect(hit.title == "WeWork sync")
        #expect(hit.preview.lowercased().contains("utkarsh"))
    }

    @Test func recentReturnsNewestFirst() {
        let result = NotesSearch.recent(notes: notes, limit: 5)
        #expect(result.hits.map(\.noteId) == ["2026-06-18", "2026-06-17", "2026-06-15"])
        #expect(result.truncated == false)
    }

    @Test func recentPreviewPrefersRecapSummaryThenFirstLine() {
        let result = NotesSearch.recent(notes: notes, limit: 5)
        // 2026-06-18 has a recap: preview is its summary.
        #expect(result.hits.first?.preview == "Planning meeting")
        // 2026-06-15 has no recap: preview falls back to the first transcript line.
        #expect(result.hits.first { $0.noteId == "2026-06-15" }?.preview
            == "Explored local embeddings for search.")
    }

    @Test func recentRespectsLimitAndTruncates() {
        let result = NotesSearch.recent(notes: notes, limit: 2)
        #expect(result.hits.count == 2)
        #expect(result.hits.map(\.noteId) == ["2026-06-18", "2026-06-17"])
        #expect(result.truncated == true)
    }

    // The summaries are deliberately out of chronological order to prove sorting.
    private let summaries: [SessionNoteSummary] = [
        SessionNoteSummary(
            id: "mid", startedAt: Date(timeIntervalSince1970: 1_717_900_000),
            title: "Middle", recapSummary: "second summary", lineCount: 3, noteCount: 0),
        SessionNoteSummary(
            id: "new", startedAt: Date(timeIntervalSince1970: 1_718_000_000),
            title: "Newest", recapSummary: "newest summary", lineCount: 2, noteCount: 1),
        SessionNoteSummary(
            id: "old", startedAt: Date(timeIntervalSince1970: 1_717_700_000),
            title: "Oldest", recapSummary: nil, lineCount: 1, noteCount: 0),
    ]

    @Test func recentFromSummariesOrdersNewestFirstAndPreviewsRecap() {
        let result = NotesSearch.recent(summaries: summaries, limit: 5)
        #expect(result.hits.map(\.noteId) == ["new", "mid", "old"])
        #expect(result.truncated == false)
        // Preview is the recap summary; a summary with no recap previews empty.
        #expect(result.hits.first?.preview == "newest summary")
        #expect(result.hits.first?.title == "Newest")
        #expect(result.hits.first { $0.noteId == "old" }?.preview == "")
    }

    @Test func recentFromSummariesRespectsLimitAndTruncates() {
        let result = NotesSearch.recent(summaries: summaries, limit: 2)
        #expect(result.hits.map(\.noteId) == ["new", "mid"])
        #expect(result.truncated == true)
    }
}
