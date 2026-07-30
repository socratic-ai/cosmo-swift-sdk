import Foundation
import Testing
@testable import CosmoRealtime

/// Behaviour: `VoiceSessionModel` accepts user text turns (composer sends),
/// echoing them into the transcript immediately and — before the session is
/// live — queuing them for flush on `.ready`. Start-muted supports
/// type-before-you-talk. A failed send flags the echoed bubble.
@Suite struct VoiceSessionModelTextTests {

    // NOTE: the paths that need a real `start()` — start-muted, and the queued
    // text actually *flushing to the wire* on `.ready` — are intentionally NOT
    // unit-tested here. `start()` kicks a live LiveKit connect (harmless locally,
    // fails fast) but on the macos-15 CI runner that connect hangs/retries and
    // stalls the whole test process until the job timeout; and the flush needs a
    // live `VoiceSession`, which is a concrete actor with no fake seam (GAPS.md
    // testability hole). Those are verified on device. What IS unit-tested below
    // is the queue's failure contract and the re-seed primitive that makes a
    // pre-connect message survive the session reset — the parts that broke.

    @Test @MainActor
    func sendTextBeforeLiveEchoesUserBubbleImmediately() {
        guard #available(macOS 14, iOS 17, *) else { return }
        let model = VoiceSessionModel()
        // Idle (not live): the text is echoed right away and queued for flush.
        model.sendText("book me a table")
        let line = model.transcript.last { $0.kind == .user }
        #expect(line?.text == "book me a table")
        #expect(line?.deliveryFailed == false)
    }

    @Test @MainActor
    func queuedTextIsFlaggedFailedWhenSessionEndsBeforeFlush() {
        guard #available(macOS 14, iOS 17, *) else { return }
        let model = VoiceSessionModel()
        // Type-before-you-talk queues the turn while idle (not yet flushed).
        model.sendText("did this send?")
        #expect(model.transcript.last { $0.kind == .user }?.deliveryFailed == false)

        // The session ends/errors before ever going live (here a preflight error,
        // which drives the same `.error` terminal transition a failed connect
        // does). The never-flushed queued turn must be flagged so the user sees
        // the model never received it — not silently dropped.
        model.markPreflightError(
            AppErrorPresentation(
                headline: "Couldn't start session",
                message: "no network",
                heardTranscript: nil,
                actions: [.retry]
            )
        )
        let line = model.transcript.last { $0.kind == .user }
        #expect(line?.text == "did this send?")
        #expect(line?.deliveryFailed == true)
    }

    @Test func appendUserTextReSeedsUnderGivenId() {
        // start() preserves a pre-connect text queue across the session reset by
        // re-echoing each queued turn under its ORIGINAL id (so a later failed
        // flush still flags the right bubble). Verify the reducer primitive that
        // makes that possible: the caller-supplied id is honoured end-to-end.
        var reducer = TranscriptReducer()
        let id = UUID()
        let returned = reducer.appendUserText("hold my place", id: id)
        #expect(returned == id)
        #expect(reducer.lines.count == 1)
        #expect(reducer.lines[0].id == id)
        reducer.markDeliveryFailed(id: id)
        #expect(reducer.lines[0].deliveryFailed == true)
    }

    // MARK: - Reducer text primitives (pure)

    @Test func appendUserTextAddsAFinalUserLine() {
        var reducer = TranscriptReducer()
        let id = reducer.appendUserText("hi there")
        #expect(reducer.lines.count == 1)
        #expect(reducer.lines[0].kind == .user)
        #expect(reducer.lines[0].text == "hi there")
        #expect(reducer.lines[0].id == id)
        #expect(reducer.lines[0].deliveryFailed == false)
    }

    @Test func markDeliveryFailedFlagsTheLine() {
        var reducer = TranscriptReducer()
        let id = reducer.appendUserText("did this send?")
        reducer.markDeliveryFailed(id: id)
        #expect(reducer.lines[0].deliveryFailed == true)
        // Unknown id is a no-op, not a crash.
        reducer.markDeliveryFailed(id: UUID())
        #expect(reducer.lines.count == 1)
    }

    // MARK: - TranscriptLine.deliveryFailed backward-compatible decode

    @Test func transcriptLineDecodesWithoutDeliveryFailedKey() throws {
        // An older on-disk line has no `deliveryFailed` key; it must decode to
        // false rather than fail.
        let json = #"{"id":"\#(UUID().uuidString)","kind":"user","text":"legacy"}"#
        let line = try JSONDecoder().decode(TranscriptLine.self, from: Data(json.utf8))
        #expect(line.deliveryFailed == false)
        #expect(line.text == "legacy")
    }

    @Test func transcriptLineRoundTripsDeliveryFailed() throws {
        let original = TranscriptLine(kind: .user, text: "oops", deliveryFailed: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TranscriptLine.self, from: data)
        #expect(decoded.deliveryFailed == true)
        #expect(decoded == original)
    }
}
