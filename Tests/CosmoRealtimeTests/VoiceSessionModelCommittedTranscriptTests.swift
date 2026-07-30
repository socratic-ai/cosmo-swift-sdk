import Foundation
import Testing

@testable import CosmoRealtime

/// ``committedUserTranscript`` exposes only finalized user text, never a
/// still-revising hypothesis — what Mac dictation types from.
@Suite struct VoiceSessionModelCommittedTranscriptTests {

    @Test @MainActor
    func inProgressUserLineIsExcludedUntilFinal() {
        guard #available(macOS 14, iOS 17, *) else { return }
        let model = VoiceSessionModel()

        // Streaming partials accumulate into the in-progress line — not committed.
        model.ingest(.transcript(Transcript(role: .user, text: "Hel", isFinal: false)))
        model.ingest(.transcript(Transcript(role: .user, text: "lo there", isFinal: false)))
        #expect(model.committedUserTranscript == "")

        // The final commits the utterance.
        model.ingest(.transcript(Transcript(role: .user, text: "Hello there", isFinal: true)))
        #expect(model.committedUserTranscript == "Hello there")

        // A new utterance's partials are again excluded until committed.
        model.ingest(.transcript(Transcript(role: .user, text: "next", isFinal: false)))
        #expect(model.committedUserTranscript == "Hello there")
        model.ingest(.transcript(Transcript(role: .user, text: "next phrase", isFinal: true)))
        #expect(model.committedUserTranscript == "Hello there next phrase")
    }

    @Test @MainActor
    func aRevisedPartialNeverReachesCommittedText() {
        guard #available(macOS 14, iOS 17, *) else { return }
        let model = VoiceSessionModel()

        // A revised partial garbles the in-progress line, but committed stays
        // empty — the case that used to latch dictation to the card.
        model.ingest(.transcript(Transcript(role: .user, text: "helo", isFinal: false)))
        model.ingest(.transcript(Transcript(role: .user, text: "hello world", isFinal: false)))
        #expect(model.committedUserTranscript == "")

        // Only the clean final is committed.
        model.ingest(.transcript(Transcript(role: .user, text: "hello world", isFinal: true)))
        #expect(model.committedUserTranscript == "hello world")
    }

    @Test @MainActor
    func assistantLinesAreNotUserCommittedText() {
        guard #available(macOS 14, iOS 17, *) else { return }
        let model = VoiceSessionModel()
        model.ingest(.transcript(Transcript(role: .user, text: "type this", isFinal: true)))
        model.ingest(.transcript(Transcript(role: .assistant, text: "okay", isFinal: true)))
        #expect(model.committedUserTranscript == "type this")
    }
}
