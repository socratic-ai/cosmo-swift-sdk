import Foundation
import Testing
@testable import CosmoRealtime

/// Session-owned transcript state: folding semantics of
/// ``RealtimeSession/transcript`` / ``RealtimeSessionEvent/transcriptUpdated(_:)``
/// over the wire stream — growth, barge-in interleaving, retraction,
/// silent-session chunked finals, dangling-line close, send(text:) echo,
/// and teardown. TypeScript's `transcript_state.test.ts` and Python's
/// `test_transcript_state.py` are the cross-SDK spec.
@Suite("Session-owned transcript")
struct TranscriptStateTests {

    private func startedSession() async throws -> RealtimeSession {
        let session = RealtimeSession(transport: FakeSessionTransport())
        try await session._start(config: SessionConfig())
        return session
    }

    private func inject(
        _ session: RealtimeSession, role: String, text: String, isFinal: Bool
    ) async {
        let payload: [String: Any] = [
            "type": "transcript", "role": role, "text": text, "is_final": isFinal,
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        await session._receiveFrame(data)
    }

    private func injectTurnComplete(_ session: RealtimeSession, role: String) async {
        let data = Data(#"{"type":"turn-complete","role":"\#(role)"}"#.utf8)
        await session._receiveFrame(data)
    }

    private struct Bare: Equatable {
        let role: TranscriptRole
        let text: String
        let isFinal: Bool
    }

    private func bare(_ items: [TranscriptItem]) -> [Bare] {
        items.map { Bare(role: $0.role, text: $0.text, isFinal: $0.isFinal) }
    }

    @Test("Deltas grow the open bubble and the final replaces")
    func deltasGrowAndFinalReplaces() async throws {
        let session = try await startedSession()
        await inject(session, role: "ASSISTANT", text: "Hel", isFinal: false)
        await inject(session, role: "ASSISTANT", text: "lo th", isFinal: false)
        #expect(bare(await session.transcript) == [Bare(role: .assistant, text: "Hello th", isFinal: false)])
        // The final is authoritative and can correct a reworded prefix.
        await inject(session, role: "ASSISTANT", text: "Hello there.", isFinal: true)
        #expect(bare(await session.transcript) == [Bare(role: .assistant, text: "Hello there.", isFinal: true)])
    }

    @Test("Item id is stable from open to close")
    func itemIdStable() async throws {
        let session = try await startedSession()
        await inject(session, role: "USER", text: "partial", isFinal: false)
        let openId = (await session.transcript)[0].id
        await inject(session, role: "USER", text: "partial and final", isFinal: true)
        #expect((await session.transcript)[0].id == openId)
    }

    @Test("Barge-in interleaving holds turns together")
    func bargeInInterleaving() async throws {
        let session = try await startedSession()
        // Wire order under barge-in: user partial → assistant delta → user final.
        await inject(session, role: "USER", text: "Wait, ", isFinal: false)
        await inject(session, role: "ASSISTANT", text: "As I was say", isFinal: false)
        await inject(session, role: "USER", text: "Wait, stop.", isFinal: true)
        #expect(bare(await session.transcript) == [
            Bare(role: .user, text: "Wait, stop.", isFinal: true),
            Bare(role: .assistant, text: "As I was say", isFinal: false),
        ])
    }

    @Test("An empty final retracts the open bubble")
    func emptyFinalRetracts() async throws {
        let session = try await startedSession()
        await inject(session, role: "ASSISTANT", text: "user\n2969", isFinal: false)
        #expect((await session.transcript).count == 1)
        // The server force-closes a leaked garbled line with an empty final:
        // the streamed partials must not stand.
        await inject(session, role: "ASSISTANT", text: "", isFinal: true)
        #expect((await session.transcript).isEmpty)
    }

    @Test("Blank deltas never open a bubble")
    func blankNeverOpens() async throws {
        let session = try await startedSession()
        await inject(session, role: "ASSISTANT", text: "", isFinal: true)
        await inject(session, role: "USER", text: "   ", isFinal: false)
        #expect((await session.transcript).isEmpty)
    }

    @Test("A final with no open bubble lands as its own closed item")
    func chunkedFinals() async throws {
        let session = try await startedSession()
        // Silent-session shape: the endpoint commits a chunk, the model's
        // late final carries only the remaining suffix — each is complete.
        await inject(session, role: "USER", text: "Schedule the meeting", isFinal: true)
        await inject(session, role: "USER", text: "for tomorrow at nine.", isFinal: true)
        #expect(bare(await session.transcript) == [
            Bare(role: .user, text: "Schedule the meeting", isFinal: true),
            Bare(role: .user, text: "for tomorrow at nine.", isFinal: true),
        ])
    }

    @Test("Turn-complete closes a dangling open bubble")
    func turnCompleteClosesDangling() async throws {
        let session = try await startedSession()
        await inject(session, role: "ASSISTANT", text: "What the caller heard", isFinal: false)
        await injectTurnComplete(session, role: "ASSISTANT")
        #expect(bare(await session.transcript) == [Bare(role: .assistant, text: "What the caller heard", isFinal: true)])
    }

    @Test("transcriptUpdated is yielded on events after each fold, carrying the current items")
    func updatedEventFollowsEachFold() async throws {
        let session = try await startedSession()
        await inject(session, role: "USER", text: "One", isFinal: false)
        var iterator = session.events.makeAsyncIterator()
        let delta = try await iterator.next()
        let updated = try await iterator.next()
        guard case .transcript(let deltaPayload) = delta else {
            Issue.record("expected .transcript, got \(String(describing: delta))")
            return
        }
        #expect(deltaPayload.text == "One")
        guard case .transcriptUpdated(let update) = updated else {
            Issue.record("expected .transcriptUpdated, got \(String(describing: updated))")
            return
        }
        #expect(bare(update.items) == [Bare(role: .user, text: "One", isFinal: false)])
        #expect(update.items == (await session.transcript))
    }

    @Test("send(text:) echo folds in; transcript: false keeps it out")
    func sendTextEcho() async throws {
        let session = try await startedSession()
        try await session.send(text: "typed question")
        try await session.send(text: "off the record", transcript: false)
        #expect(bare(await session.transcript) == [Bare(role: .user, text: "typed question", isFinal: true)])
    }

    @Test("send(text:) lands as its own turn and never touches an open speech bubble")
    func sendTextNeverTouchesOpenSpeech() async throws {
        let session = try await startedSession()
        // The mic is live: the user's speech transcription is still open.
        await inject(session, role: "USER", text: "I was saying something", isFinal: false)
        try await session.send(text: "typed question")
        #expect(bare(await session.transcript) == [
            Bare(role: .user, text: "I was saying something", isFinal: false),
            Bare(role: .user, text: "typed question", isFinal: true),
        ])
        // The speech turn's real final still closes its own bubble, in
        // place — chronological order by turn start, no duplicate item.
        await inject(session, role: "USER", text: "I was saying something important", isFinal: true)
        #expect(bare(await session.transcript) == [
            Bare(role: .user, text: "I was saying something important", isFinal: true),
            Bare(role: .user, text: "typed question", isFinal: true),
        ])
    }

    @Test("Deltas keep folding into the open bubble behind a typed turn")
    func deltasFoldBehindTypedTurn() async throws {
        let session = try await startedSession()
        await inject(session, role: "USER", text: "Hel", isFinal: false)
        try await session.send(text: "typed")
        await inject(session, role: "USER", text: "lo there", isFinal: false)
        #expect(bare(await session.transcript) == [
            Bare(role: .user, text: "Hello there", isFinal: false),
            Bare(role: .user, text: "typed", isFinal: true),
        ])
        await injectTurnComplete(session, role: "USER")
        #expect(bare(await session.transcript) == [
            Bare(role: .user, text: "Hello there", isFinal: true),
            Bare(role: .user, text: "typed", isFinal: true),
        ])
    }

    @Test("End closes open bubbles; the closing update precedes the terminal sentinel")
    func endClosesAndSurvives() async throws {
        let session = try await startedSession()
        await inject(session, role: "ASSISTANT", text: "Goodbye th", isFinal: false)
        await session.end()
        #expect(bare(await session.transcript) == [Bare(role: .assistant, text: "Goodbye th", isFinal: true)])
        var updates: [TranscriptUpdatedEvent] = []
        var sawTerminal = false
        for try await event in session.events {
            if case .transcriptUpdated(let update) = event { updates.append(update) }
            if case .sessionEnded = event {
                sawTerminal = true
                // The closing update already landed before the sentinel.
                #expect(bare(updates.last?.items ?? []) == [Bare(role: .assistant, text: "Goodbye th", isFinal: true)])
            }
        }
        #expect(sawTerminal)
    }
}
