import CosmoRealtime
import Foundation
import Testing

@testable import CosmoNotesKit

@Suite struct NoteExportTests {
    @Test func exportContainsEverySection() {
        let note = SessionNote(
            id: "s1",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            title: "Planning the trip",
            lines: [
                NoteLine(role: .user, text: "Where should we go?"),
                NoteLine(role: .assistant, text: "How about Lisbon?"),
            ],
            notes: [CapturedNote(text: "Book flights early", source: .assistant)],
            recap: Recap(
                summary: "We planned a trip.",
                keyPoints: ["Pick dates", "Set a budget"],
                actionItems: [
                    ActionItem(text: "Reserve hotel", done: true),
                    ActionItem(text: "Buy tickets", done: false),
                ]
            )
        )

        let export = note.plainTextExport()

        #expect(export.contains("Planning the trip"))
        #expect(export.contains("We planned a trip."))
        #expect(export.contains("Key points:"))
        #expect(export.contains("• Pick dates"))
        #expect(export.contains("Action items:"))
        #expect(export.contains("[x] Reserve hotel"))
        #expect(export.contains("[ ] Buy tickets"))
        #expect(export.contains("Notes:"))
        #expect(export.contains("• Book flights early"))
        #expect(export.contains("Conversation:"))
        // Default labels are brand-free.
        #expect(export.contains("You: Where should we go?"))
        #expect(export.contains("Assistant: How about Lisbon?"))
    }

    @Test func exportUsesCustomLabels() {
        let note = SessionNote(
            id: "s2",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lines: [
                NoteLine(role: .user, text: "hi"),
                NoteLine(role: .assistant, text: "hello"),
            ]
        )
        let export = note.plainTextExport(assistantLabel: "Cosmo", userLabel: "Me")
        #expect(export.contains("Me: hi"))
        #expect(export.contains("Cosmo: hello"))
        #expect(!export.contains("Assistant:"))
    }
}
