import Foundation
import Testing
import CosmoRealtime

@Suite struct TranscriptReducerTests {
    // MARK: - Ready event

    @Test func readyAppendsSystemBanner() {
        var reducer = TranscriptReducer()
        reducer.reduce(.ready(Ready(sessionId: "abcd1234567890")))

        #expect(reducer.lines.count == 1)
        let line = reducer.lines[0]
        #expect(line.kind == .system)
        #expect(line.text.contains("abcd1234"))
        #expect(reducer.lastReady?.sessionId == "abcd1234567890")
    }

    // MARK: - User transcript streaming

    @Test func userTranscriptAppendsDeltasAndReplacesOnFinal() {
        var reducer = TranscriptReducer()

        // Streaming events are deltas; the final event carries the
        // cumulative full transcript per the wire-protocol contract.
        reducer.reduce(.transcript(Transcript(role: .user, text: "Hel", isFinal: false)))
        reducer.reduce(.transcript(Transcript(role: .user, text: "lo", isFinal: false)))
        #expect(reducer.lines.count == 1)
        #expect(reducer.lines[0].kind == .user)
        #expect(reducer.lines[0].text == "Hello")

        reducer.reduce(.transcript(Transcript(role: .user, text: "Hello there", isFinal: true)))
        #expect(reducer.lines.count == 1)
        #expect(reducer.lines[0].text == "Hello there")
        #expect(reducer.inProgressUserLineId == nil)
    }

    @Test func turnCompleteForAssistantAlsoFinalizesUserLine() {
        var reducer = TranscriptReducer()
        reducer.reduce(.transcript(Transcript(role: .user, text: "Hi", isFinal: false)))
        reducer.reduce(.turnComplete(role: .assistant))

        #expect(reducer.inProgressUserLineId == nil)
        #expect(reducer.inProgressAssistantLineId == nil)

        // A subsequent user transcript should start a NEW line.
        reducer.reduce(.transcript(Transcript(role: .user, text: "Second turn", isFinal: false)))
        #expect(reducer.lines.count == 2)
        #expect(reducer.lines[1].text == "Second turn")
    }

    // MARK: - Assistant transcript: deltas → cumulative-on-final contract

    @Test func assistantStreamingDeltasAppend() {
        var reducer = TranscriptReducer()
        reducer.reduce(.transcript(Transcript(role: .assistant, text: "Hel", isFinal: false)))
        reducer.reduce(.transcript(Transcript(role: .assistant, text: "lo", isFinal: false)))
        reducer.reduce(.transcript(Transcript(role: .assistant, text: " buddy", isFinal: false)))

        #expect(reducer.lines.count == 1)
        #expect(reducer.lines[0].kind == .assistant)
        #expect(reducer.lines[0].text == "Hello buddy")
    }

    @Test func assistantFinalEventReplacesWithCumulative() {
        var reducer = TranscriptReducer()
        reducer.reduce(.transcript(Transcript(role: .assistant, text: "Hel", isFinal: false)))
        reducer.reduce(.transcript(Transcript(role: .assistant, text: "lo", isFinal: false)))
        // The provider sends the cumulative full transcript on is_final.
        reducer.reduce(.transcript(Transcript(role: .assistant, text: "Hello buddy.", isFinal: true)))

        #expect(reducer.lines.count == 1)
        #expect(reducer.lines[0].text == "Hello buddy.")
        #expect(reducer.inProgressAssistantLineId == nil)
    }

    @Test func nextAssistantTurnStartsNewLineAfterFinal() {
        var reducer = TranscriptReducer()
        reducer.reduce(.transcript(Transcript(role: .assistant, text: "Hi.", isFinal: true)))
        reducer.reduce(.transcript(Transcript(role: .assistant, text: "Bye", isFinal: false)))
        reducer.reduce(.transcript(Transcript(role: .assistant, text: "Bye.", isFinal: true)))

        #expect(reducer.lines.count == 2)
        #expect(reducer.lines[0].text == "Hi.")
        #expect(reducer.lines[1].text == "Bye.")
    }

    // MARK: - Late final after turn_complete (streamed partials must not duplicate)

    @Test func lateAssistantFinalAfterTurnCompleteCollapsesInPlace() {
        // Wire ordering is normally partials → final → turn_complete, but a fast
        // next generation can flush the terminator ahead of the turn's cumulative
        // final. The late final must finalize the streamed line in place — one
        // renderable turn, not the streamed partial line plus a duplicate final
        // line. Regression for the assistant-turn-rendered-twice bug.
        var reducer = TranscriptReducer()
        reducer.reduce(.transcript(Transcript(role: .assistant, text: "Hello ", isFinal: false)))
        reducer.reduce(.transcript(Transcript(role: .assistant, text: "there", isFinal: false)))
        // Partials are renderable before the final lands.
        #expect(reducer.lines.filter { $0.kind == .assistant }.count == 1)
        #expect(reducer.lines[0].text == "Hello there")

        reducer.reduce(.turnComplete(role: .assistant))
        reducer.reduce(.transcript(Transcript(role: .assistant, text: "Hello there", isFinal: true)))

        let assistant = reducer.lines.filter { $0.kind == .assistant }
        #expect(assistant.count == 1)
        #expect(assistant[0].text == "Hello there")
        #expect(reducer.inProgressAssistantLineId == nil)
        #expect(reducer.pendingFinalizeAssistantLineId == nil)
    }

    @Test func emptyLateFinalAfterTurnCompleteRemovesTheStreamedLine() {
        // A suppressed turn whose empty-final terminator lands after turn_complete
        // must still remove the leaked partial line, not strand an empty bubble.
        var reducer = TranscriptReducer()
        reducer.reduce(.transcript(Transcript(role: .assistant, text: "model", isFinal: false)))
        reducer.reduce(.turnComplete(role: .assistant))
        reducer.reduce(.transcript(Transcript(role: .assistant, text: "", isFinal: true)))

        #expect(reducer.lines.isEmpty)
        #expect(reducer.pendingFinalizeAssistantLineId == nil)
    }

    @Test func newTurnPartialAfterTurnCompleteStartsFreshLine() {
        // The finalize window is one-shot: a fresh partial after turn_complete is
        // a new turn and must NOT merge into the just-closed line (the tool-call
        // narration contract). Guards the fix from over-collapsing.
        var reducer = TranscriptReducer()
        reducer.reduce(.transcript(Transcript(role: .assistant, text: "First turn.", isFinal: false)))
        reducer.reduce(.turnComplete(role: .assistant))
        reducer.reduce(.transcript(Transcript(role: .assistant, text: "Second", isFinal: false)))
        reducer.reduce(.transcript(Transcript(role: .assistant, text: "Second turn.", isFinal: true)))

        let assistant = reducer.lines.filter { $0.kind == .assistant }
        #expect(assistant.map { $0.text } == ["First turn.", "Second turn."])
    }

    // MARK: - Empty final = line-close primitive (removes the line)

    @Test func assistantEmptyFinalRemovesTheOpenLine() {
        // The backend force-closes a suppressed (role-echo / silent-marker)
        // turn with an empty final. That must REMOVE the open assistant line,
        // not replace it with "" (which would strand an empty bubble).
        var reducer = TranscriptReducer()
        reducer.reduce(.transcript(Transcript(role: .assistant, text: "model", isFinal: false)))
        #expect(reducer.lines.count == 1)

        let removed = reducer.reduce(.transcript(Transcript(role: .assistant, text: "", isFinal: true)))
        #expect(reducer.lines.isEmpty)
        #expect(removed.count == 1)  // the removed line's id is reported
        #expect(reducer.inProgressAssistantLineId == nil)
    }

    @Test func userEmptyFinalRemovesTheOpenLine() {
        var reducer = TranscriptReducer()
        reducer.reduce(.transcript(Transcript(role: .user, text: "umm", isFinal: false)))
        #expect(reducer.lines.count == 1)

        reducer.reduce(.transcript(Transcript(role: .user, text: "", isFinal: true)))
        #expect(reducer.lines.isEmpty)
        #expect(reducer.inProgressUserLineId == nil)
    }

    @Test func emptyFinalWithNoOpenLineIsANoOp() {
        // No open line to close → never append an empty line.
        var reducer = TranscriptReducer()
        let ids = reducer.reduce(.transcript(Transcript(role: .assistant, text: "", isFinal: true)))
        #expect(reducer.lines.isEmpty)
        #expect(ids.isEmpty)
    }

    @Test func emptyFinalLeavesOtherLinesUntouched() {
        var reducer = TranscriptReducer()
        reducer.reduce(.transcript(Transcript(role: .user, text: "hi there", isFinal: true)))
        reducer.reduce(.transcript(Transcript(role: .assistant, text: "model", isFinal: false)))
        #expect(reducer.lines.count == 2)

        reducer.reduce(.transcript(Transcript(role: .assistant, text: "", isFinal: true)))
        // Only the open assistant line is removed; the finalized user line stays.
        #expect(reducer.lines.count == 1)
        #expect(reducer.lines[0].kind == .user)
        #expect(reducer.lines[0].text == "hi there")
    }

    @Test func nonEmptyFinalStillReplacesNotRemoves() {
        // Guard the boundary: a non-empty final is the ordinary replace path.
        var reducer = TranscriptReducer()
        reducer.reduce(.transcript(Transcript(role: .assistant, text: "Hel", isFinal: false)))
        reducer.reduce(.transcript(Transcript(role: .assistant, text: "Hello.", isFinal: true)))
        #expect(reducer.lines.count == 1)
        #expect(reducer.lines[0].text == "Hello.")
    }

    // MARK: - Tool call → tool result

    @Test func toolCallAndResultUpdateSameLineInPlace() {
        var reducer = TranscriptReducer()
        reducer.reduce(.toolCall(ToolCall(callId: "call-1", name: "tmux_list_sessions")))
        let afterCall = reducer.lines.count
        #expect(afterCall == 1)
        #expect(reducer.lines[0].kind == .tool)
        #expect(reducer.lines[0].text.contains("tmux_list_sessions"))
        #expect(reducer.pendingToolLines["call-1"] != nil)

        reducer.reduce(.toolResult(ToolResult(callId: "call-1", ok: true, summary: "2 sessions")))

        #expect(reducer.lines.count == afterCall)
        #expect(reducer.lines[0].text == "tmux_list_sessions → ok 2 sessions")
        let details = reducer.lines[0].toolDetails
        #expect(details?.callId == "call-1")
        #expect(details?.ok == true)
        #expect(details?.summary == "2 sessions")
        #expect(reducer.pendingToolLines.isEmpty)
    }

    @Test func toolResultWithoutPriorCallAppendsStandaloneLine() {
        var reducer = TranscriptReducer()
        reducer.reduce(.toolResult(ToolResult(callId: "orphan", ok: false, summary: "boom")))

        #expect(reducer.lines.count == 1)
        #expect(reducer.lines[0].kind == .tool)
        #expect(reducer.lines[0].text.contains("(unknown)"))
        #expect(reducer.lines[0].text.contains("err"))
        #expect(reducer.lines[0].toolDetails?.ok == false)
    }

    @Test func failedToolResultRendersErrPrefix() {
        var reducer = TranscriptReducer()
        reducer.reduce(.toolCall(ToolCall(callId: "c2", name: "file_read")))
        reducer.reduce(.toolResult(ToolResult(callId: "c2", ok: false, summary: "permission denied")))

        #expect(reducer.lines[0].text == "file_read → err permission denied")
    }

    // MARK: - Interleaving

    @Test func assistantStreamContinuesIntoSameLineAcrossToolCall() {
        // Gemini Live's common pattern: the assistant starts narrating,
        // pauses to invoke a tool, then continues the same sentence with
        // the tool's result. `turn_complete` arrives AFTER the second
        // chunk, so `inProgressAssistantLineId` is still live when the
        // continuation lands and the reducer concatenates into the
        // existing assistant line rather than starting a new one.
        var reducer = TranscriptReducer()
        reducer.reduce(.transcript(Transcript(role: .assistant, text: "Let me check.", isFinal: false)))
        reducer.reduce(.toolCall(ToolCall(callId: "c1", name: "tmux_list_sessions")))
        reducer.reduce(.toolResult(ToolResult(callId: "c1", ok: true, summary: "1 session")))
        reducer.reduce(.transcript(Transcript(role: .assistant, text: " You have one session.", isFinal: false)))

        // Three lines total: the (merged) assistant line, the tool line,
        // and nothing else. The assistant line carries both chunks.
        #expect(reducer.lines.count == 2)
        #expect(reducer.lines[0].kind == .assistant)
        #expect(reducer.lines[0].text == "Let me check. You have one session.")
        #expect(reducer.lines[1].kind == .tool)
        #expect(reducer.lines[1].text == "tmux_list_sessions → ok 1 session")
        // The in-progress assistant line is still live (no turn_complete yet).
        #expect(reducer.inProgressAssistantLineId == reducer.lines[0].id)

        // Once turn_complete lands, a follow-up assistant chunk starts a
        // fresh line — confirms the reducer doesn't keep appending forever.
        reducer.reduce(.turnComplete(role: .assistant))
        reducer.reduce(.transcript(Transcript(role: .assistant, text: "Anything else?", isFinal: false)))
        #expect(reducer.lines.count == 3)
        #expect(reducer.lines[2].text == "Anything else?")
    }

    @Test func interleavedUserAssistantAndToolCallsKeepDistinctLines() {
        var reducer = TranscriptReducer()
        reducer.reduce(.transcript(Transcript(role: .user, text: "list my sessions", isFinal: false)))
        reducer.reduce(.toolCall(ToolCall(callId: "c1", name: "tmux_list_sessions")))
        reducer.reduce(.toolResult(ToolResult(callId: "c1", ok: true, summary: "1 session")))
        reducer.reduce(.transcript(Transcript(role: .assistant, text: "You have one tmux session.", isFinal: false)))
        reducer.reduce(.turnComplete(role: .assistant))

        #expect(reducer.lines.count == 3)
        #expect(reducer.lines[0].kind == .user)
        #expect(reducer.lines[1].kind == .tool)
        #expect(reducer.lines[2].kind == .assistant)
        #expect(reducer.lines[2].text == "You have one tmux session.")
        #expect(reducer.inProgressUserLineId == nil)
        #expect(reducer.inProgressAssistantLineId == nil)
    }

    // MARK: - Server-side errors

    @Test func serverErrorEventCapturedAndRendered() {
        var reducer = TranscriptReducer()
        reducer.reduce(.error(ServerError(code: "RATE_LIMITED", message: "Slow down")))

        #expect(reducer.lines.count == 1)
        #expect(reducer.lines[0].kind == .error)
        #expect(reducer.lines[0].text == "RATE_LIMITED: Slow down")
        #expect(reducer.lastError?.code == "RATE_LIMITED")
    }

    // MARK: - Dangling tool close

    @Test func closeDanglingToolLinesMarksOpenToolsFailed() {
        var reducer = TranscriptReducer()
        reducer.reduce(.toolCall(ToolCall(callId: "done", name: "read_file")))
        reducer.reduce(.toolResult(ToolResult(callId: "done", ok: true, summary: "42 lines")))
        reducer.reduce(.toolCall(ToolCall(callId: "stranded", name: "run_shell")))

        let closed = reducer.closeDanglingToolLines()

        #expect(closed.count == 1)
        #expect(reducer.pendingToolLines.isEmpty)
        // The resolved line is untouched.
        #expect(reducer.lines[0].toolDetails?.ok == true)
        #expect(reducer.lines[0].text == "read_file → ok 42 lines")
        // The stranded line is closed as failed, so no consumer renders it
        // as still running.
        let stranded = reducer.lines[1]
        #expect(stranded.id == closed[0])
        #expect(stranded.toolDetails?.ok == false)
        #expect(stranded.toolDetails?.name == "run_shell")
        #expect(stranded.text == "run_shell → err no result — session ended")
        // A late result for the closed call no longer matches a pending line.
        reducer.reduce(.toolResult(ToolResult(callId: "stranded", ok: true, summary: nil)))
        #expect(reducer.lines[1].toolDetails?.ok == false)
    }

    @Test func closeDanglingToolLinesIsNoOpWithoutOpenTools() {
        var reducer = TranscriptReducer()
        reducer.reduce(.toolCall(ToolCall(callId: "c", name: "read_file")))
        reducer.reduce(.toolResult(ToolResult(callId: "c", ok: false, summary: "boom")))

        #expect(reducer.closeDanglingToolLines().isEmpty)
        #expect(reducer.lines[0].text == "read_file → err boom")
    }

    // MARK: - Reset

    @Test func resetClearsAllState() {
        var reducer = TranscriptReducer()
        reducer.reduce(.transcript(Transcript(role: .user, text: "hi", isFinal: false)))
        reducer.reduce(.toolCall(ToolCall(callId: "c", name: "x")))
        reducer.reduce(.ready(Ready(sessionId: "s")))

        reducer.reset()

        #expect(reducer.lines.isEmpty)
        #expect(reducer.inProgressUserLineId == nil)
        #expect(reducer.inProgressAssistantLineId == nil)
        #expect(reducer.pendingToolLines.isEmpty)
        #expect(reducer.lastReady == nil)
        #expect(reducer.lastError == nil)
    }

    // MARK: - Pass-throughs

    @Test func unknownEventsLeaveTranscriptUnchanged() {
        var reducer = TranscriptReducer()
        reducer.reduce(.pong)
        reducer.reduce(.unknown(type: "future-event", raw: [:]))

        #expect(reducer.lines.isEmpty)
    }

    // MARK: - RealtimeSession.Event

    /// ``RealtimeSession/events`` is the documented stream, so the reducer has
    /// to fold what it yields — not only the ``ServerEvent`` the app wrapper
    /// emits. Same reduction rules, one narrowing step.
    @Test func sessionTranscriptEventsFoldWithTheSameRules() {
        func delta(_ text: String, isFinal: Bool) -> RealtimeSession.Event {
            .transcript(RealtimeSession.TranscriptDelta(
                isFinal: isFinal, role: .assistant, text: text, _type: .transcript
            ))
        }
        var reducer = TranscriptReducer()
        reducer.reduce(sessionEvent: delta("Hel", isFinal: false))
        reducer.reduce(sessionEvent: delta("lo", isFinal: false))
        #expect(reducer.lines.map(\.text) == ["Hello"])

        reducer.reduce(sessionEvent: delta("Hello there", isFinal: true))
        #expect(reducer.lines.map(\.text) == ["Hello there"])
    }

    @Test func sessionEventsWithoutATranscriptRepresentationFoldToNothing() {
        var reducer = TranscriptReducer()
        #expect(reducer.reduce(sessionEvent: .botStartedSpeaking).isEmpty)
        #expect(reducer.reduce(sessionEvent: .userStartedSpeaking).isEmpty)
        #expect(reducer.reduce(sessionEvent: .unknown(rawType: "future-event", payload: Data())).isEmpty)
        #expect(reducer.lines.isEmpty)
    }
}
