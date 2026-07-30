import Foundation
import Testing
@testable import CosmoRealtime

/// Behaviour: `inFlightTools` mirrors the open set of `.toolCall` events
/// keyed by `callId`, drained by matching `.toolResult` events. Hosts
/// surface the count as a "running tools" badge, so a stuck entry shows
/// up as a stale badge — these tests exercise the lifecycle paths a real
/// session would walk.
@Suite struct InFlightToolsTests {
    @Test @MainActor
    func toolCallAppends_andResultRemoves() {
        guard #available(macOS 14, iOS 17, *) else { return }
        let model = VoiceSessionModel()

        model.ingest(.toolCall(ToolCall(callId: "call-a", name: "read_file")))
        #expect(model.inFlightTools.map(\.id) == ["call-a"])
        #expect(model.inFlightTools.first?.name == "read_file")

        model.ingest(.toolResult(ToolResult(callId: "call-a", ok: true, summary: nil)))
        #expect(model.inFlightTools.isEmpty)
    }

    @Test @MainActor
    func multipleConcurrentToolsAreTracked_andResultsRemoveOnlyMatchingId() {
        guard #available(macOS 14, iOS 17, *) else { return }
        let model = VoiceSessionModel()

        model.ingest(.toolCall(ToolCall(callId: "call-a", name: "read_file")))
        model.ingest(.toolCall(ToolCall(callId: "call-b", name: "run_shell")))
        model.ingest(.toolCall(ToolCall(callId: "call-c", name: "screenshot")))
        #expect(model.inFlightTools.map(\.id) == ["call-a", "call-b", "call-c"])

        // Out-of-order completion (middle tool finishes first) — only that
        // entry should drop.
        model.ingest(.toolResult(ToolResult(callId: "call-b", ok: true, summary: nil)))
        #expect(model.inFlightTools.map(\.id) == ["call-a", "call-c"])

        model.ingest(.toolResult(ToolResult(callId: "call-a", ok: false, summary: "boom")))
        #expect(model.inFlightTools.map(\.id) == ["call-c"])

        model.ingest(.toolResult(ToolResult(callId: "call-c", ok: true, summary: nil)))
        #expect(model.inFlightTools.isEmpty)
    }

    @Test @MainActor
    func toolResultForUnknownCallId_isIgnored_andDoesNotMutateOpenTools() {
        guard #available(macOS 14, iOS 17, *) else { return }
        let model = VoiceSessionModel()
        model.ingest(.toolCall(ToolCall(callId: "call-a", name: "read_file")))

        model.ingest(.toolResult(ToolResult(callId: "unknown-id", ok: true, summary: nil)))
        #expect(model.inFlightTools.map(\.id) == ["call-a"])
    }

    @Test @MainActor
    func sessionEnd_clearsAnyStrandedInFlightTools() async {
        guard #available(macOS 14, iOS 17, *) else { return }
        // A tool that never reports a result (e.g. the model dropped the
        // call mid-flight) should not leak into the next session. `end()`
        // routes through endLiveSessionIfNeeded which drains the list.
        let model = VoiceSessionModel()
        let ready = Ready(sessionId: "sess-1")
        model.ingest(.ready(ready))
        #expect(model.state.isLive)

        model.ingest(.toolCall(ToolCall(callId: "stranded", name: "read_file")))
        #expect(model.inFlightTools.count == 1)

        model.end()
        // `end()` returns synchronously from `.live`; the async tail
        // (transition to `.idle`) drains `inFlightTools` via the
        // `endLiveSessionIfNeeded` hook reached during `.ending`.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.inFlightTools.isEmpty)
    }

    @Test @MainActor
    func sessionEnd_closesStrandedToolTranscriptLines() async {
        guard #available(macOS 14, iOS 17, *) else { return }
        // The transcript outlives the session, so a tool line still awaiting
        // its result must be closed at session end — a retained `ok == nil`
        // line keeps its running-dots animation ticking (and burning CPU)
        // forever in any view that renders the old transcript.
        let model = VoiceSessionModel()
        model.ingest(.ready(Ready(sessionId: "sess-1")))
        model.ingest(.toolCall(ToolCall(callId: "stranded", name: "run_shell")))
        #expect(model.transcript.contains { $0.toolDetails?.ok == nil && $0.kind == .tool })

        model.end()
        try? await Task.sleep(for: .milliseconds(50))

        let line = model.transcript.first { $0.toolDetails?.callId == "stranded" }
        #expect(line?.toolDetails?.ok == false)
        #expect(model.transcript.allSatisfy { $0.kind != .tool || $0.toolDetails?.ok != nil })
    }
}
