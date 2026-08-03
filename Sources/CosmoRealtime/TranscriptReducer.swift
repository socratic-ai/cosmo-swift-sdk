import Foundation

/// Pure value-type reducer that turns the stream of `ServerEvent`s into the
/// user-facing `[TranscriptLine]`. Extracted from the old `AppModel` so the
/// transcript-assembly behavior can be unit-tested without instantiating an
/// AppKit / UIKit view model or opening a real voice session.
///
/// Use:
///
///     var r = TranscriptReducer()
///     for event in stream { r.reduce(event) }
///     render(r.lines)
///
/// Reducer is value-typed (`struct` with `mutating` reduce) so it composes
/// naturally with `@Observable` view models, and can be snapshotted for
/// undo / scroll restoration without aliasing concerns.
public struct TranscriptReducer: Sendable {
    public private(set) var lines: [TranscriptLine]

    /// ID of the user line currently being streamed in (nil between turns).
    public private(set) var inProgressUserLineId: UUID?

    /// ID of the assistant line currently being streamed in (nil between turns).
    public private(set) var inProgressAssistantLineId: UUID?

    /// An assistant line that ``turn_complete`` just closed but whose cumulative
    /// ``is_final`` transcript may still be in flight. The wire ordering is
    /// final-then-terminator, but a fast next generation can flush the terminator
    /// ahead of the final (the speaking→listening state change fires before the
    /// item that carries the final). Parking the closed line here for one event
    /// lets that late final collapse into it instead of appending a duplicate
    /// assistant line. Consumed once, by the next assistant transcript event.
    public private(set) var pendingFinalizeAssistantLineId: UUID?

    /// Maps `tool_call.callId` → the `TranscriptLine.id` we appended for it,
    /// so a later `tool_result` can update the same row in place.
    public private(set) var pendingToolLines: [String: UUID]

    /// Most recent ``Ready`` event seen, if any — exposed so the owning
    /// view-model can derive ``VoiceSessionState.live`` without re-decoding.
    public private(set) var lastReady: Ready?

    /// Most recent ``ServerError`` seen, if any.
    public private(set) var lastError: ServerError?

    public init(lines: [TranscriptLine] = []) {
        self.lines = lines
        self.inProgressUserLineId = nil
        self.inProgressAssistantLineId = nil
        self.pendingFinalizeAssistantLineId = nil
        self.pendingToolLines = [:]
        self.lastReady = nil
        self.lastError = nil
    }

    /// Reset transcript + in-progress state. Use on a new session.
    public mutating func reset() {
        lines.removeAll()
        inProgressUserLineId = nil
        inProgressAssistantLineId = nil
        pendingFinalizeAssistantLineId = nil
        pendingToolLines.removeAll()
        lastReady = nil
        lastError = nil
    }

    /// Append a free-form system or error line. Returns the new line's id.
    @discardableResult
    public mutating func appendSystem(_ text: String) -> UUID {
        let line = TranscriptLine(kind: .system, text: text)
        lines.append(line)
        return line.id
    }

    @discardableResult
    public mutating func appendError(_ text: String) -> UUID {
        let line = TranscriptLine(kind: .error, text: text)
        lines.append(line)
        return line.id
    }

    /// Append a locally-originated user text turn (a composer send). Distinct
    /// from wire user transcript: text input has no audio to transcribe, so the
    /// bubble is echoed locally. Returns the new line's id so the caller can
    /// later flag it delivery-failed if the wire send fails. Pass ``id`` to
    /// re-seed a bubble under its existing id — e.g. restoring a pre-connect
    /// queue across a session reset so a later failed flush still flags it.
    @discardableResult
    public mutating func appendUserText(_ text: String, id: UUID = UUID()) -> UUID {
        let line = TranscriptLine(id: id, kind: .user, text: text)
        lines.append(line)
        return line.id
    }

    /// Flag a line whose wire send failed so the UI can show the model never
    /// received it. No-op if the id is unknown.
    public mutating func markDeliveryFailed(id: UUID) {
        guard let idx = lines.firstIndex(where: { $0.id == id }) else { return }
        let l = lines[idx]
        lines[idx] = TranscriptLine(
            id: l.id, kind: l.kind, text: l.text,
            toolDetails: l.toolDetails, deliveryFailed: true
        )
    }

    /// Close every tool line still awaiting its result (`ok == nil`), marking
    /// it failed with a "no result" summary. Once the session is over no
    /// `tool_result` can arrive, so a still-open line would render as running
    /// forever. Returns the ids of the lines mutated.
    @discardableResult
    public mutating func closeDanglingToolLines() -> [UUID] {
        guard !pendingToolLines.isEmpty else { return [] }
        var closed: [UUID] = []
        for (callId, lineId) in pendingToolLines {
            guard let index = lines.firstIndex(where: { $0.id == lineId }) else { continue }
            let name = lines[index].toolDetails?.name ?? "(unknown)"
            let summary = "no result — session ended"
            lines[index] = TranscriptLine(
                id: lineId,
                kind: .tool,
                text: "\(name) → err \(summary)",
                toolDetails: TranscriptLine.ToolDetails(
                    callId: callId,
                    name: name,
                    ok: false,
                    summary: summary
                )
            )
            closed.append(lineId)
        }
        pendingToolLines.removeAll()
        return closed
    }

    /// Apply one `ServerEvent`. Returns the IDs of lines that were inserted
    /// or mutated, in case the caller wants to scroll or animate them.
    @discardableResult
    public mutating func reduce(_ event: ServerEvent) -> [UUID] {
        switch event {
        case .ready(let ready):
            lastReady = ready
            return [appendSystem("Ready (\(ready.sessionId.prefix(8))…)")]

        case .transcript(let transcript):
            return reduceTranscript(transcript)

        case .turnComplete(let role):
            // Park a still-open assistant line so a late cumulative final (one
            // that lost the race with its terminator) collapses into it instead
            // of appending a duplicate. A subsequent partial is a new turn and
            // discards the window (see ``reduceTranscript``).
            if role == .assistant, inProgressAssistantLineId != nil {
                pendingFinalizeAssistantLineId = inProgressAssistantLineId
            }
            inProgressAssistantLineId = nil
            if role == .assistant {
                // Gemini Live never emits turn_complete for role=user;
                // the assistant's turn_complete is the natural finalize
                // point for the user's preceding utterance.
                inProgressUserLineId = nil
            }
            return []

        case .toolCall(let call):
            let details = TranscriptLine.ToolDetails(
                callId: call.callId,
                name: call.name,
                ok: nil,
                summary: nil
            )
            let line = TranscriptLine(kind: .tool, text: "\(call.name) …", toolDetails: details)
            lines.append(line)
            pendingToolLines[call.callId] = line.id
            return [line.id]

        case .toolResult(let result):
            return reduceToolResult(result)

        case .usage:
            // Usage is surfaced separately (VoiceSessionModel.usage), not as a
            // transcript line.
            return []

        case .error(let err):
            lastError = err
            return [appendError("\(err.code): \(err.message)")]

        case .toolInvocation, .pong, .unknown:
            return []
        }
    }

    /// Apply one ``RealtimeSession/Event`` — what ``RealtimeSession/events``
    /// yields. Events with no transcript representation (speaking phases,
    /// model text, reconnects) fold to nothing.
    ///
    /// Labelled rather than overloading ``reduce(_:)``: the two event enums
    /// share case names, so an unlabelled overload makes every existing
    /// leading-dot call site (`reduce(.pong)`) ambiguous.
    @discardableResult
    public mutating func reduce(sessionEvent: RealtimeSession.Event) -> [UUID] {
        guard let narrowed = ServerEvent(sessionEvent) else { return [] }
        return reduce(narrowed)
    }

    /// Returns the ids of lines inserted, mutated, or removed (0 or 1).
    private mutating func reduceTranscript(_ transcript: Transcript) -> [UUID] {
        // Per `RealtimeModelEventTranscript` contract: append deltas, replace on final.
        // TODO(v0.5+): fast-path when in-progress id == lines.last?.id (O(n) firstIndex).
        let kind: TranscriptLine.Kind = (transcript.role == .user) ? .user : .assistant
        var inProgressId: UUID? = (transcript.role == .user) ? inProgressUserLineId : inProgressAssistantLineId

        // Consume the post-turn_complete finalize window (one-shot per assistant
        // event). If this is the turn's cumulative final arriving just after its
        // terminator, redirect it into the just-closed line so it finalizes in
        // place; a fresh partial (isFinal=false) is a new turn and correctly
        // falls through to a new line below. The prefix guard keeps a genuinely
        // new bare final (different text) from being merged into a stale line.
        if transcript.role == .assistant {
            let pending = pendingFinalizeAssistantLineId
            pendingFinalizeAssistantLineId = nil
            if inProgressId == nil, transcript.isFinal, let pending,
               let idx = lines.firstIndex(where: { $0.id == pending }),
               transcript.text.isEmpty || transcript.text.hasPrefix(lines[idx].text) {
                inProgressId = pending
            }
        }

        // An empty final is the backend's line-close primitive for a suppressed
        // turn (role-echo / silent-marker force-close): REMOVE the open line
        // rather than replacing it with "" (which would strand an empty bubble).
        // With no open line there is nothing to close — a no-op, never an empty
        // append.
        if transcript.isFinal, transcript.text.isEmpty {
            guard let id = inProgressId,
                  let index = lines.firstIndex(where: { $0.id == id }) else {
                return []
            }
            lines.remove(at: index)
            clearInProgress(for: transcript.role)
            return [id]
        }

        if let id = inProgressId,
           let index = lines.firstIndex(where: { $0.id == id }) {
            let newText = transcript.isFinal
                ? transcript.text
                : lines[index].text + transcript.text
            lines[index] = TranscriptLine(id: id, kind: kind, text: newText)
            if transcript.isFinal {
                clearInProgress(for: transcript.role)
            }
            return [id]
        }

        let line = TranscriptLine(kind: kind, text: transcript.text)
        lines.append(line)
        if !transcript.isFinal {
            if transcript.role == .user {
                inProgressUserLineId = line.id
            } else {
                inProgressAssistantLineId = line.id
            }
        }
        return [line.id]
    }

    private mutating func clearInProgress(for role: Role) {
        if role == .user {
            inProgressUserLineId = nil
        } else {
            inProgressAssistantLineId = nil
        }
    }

    private mutating func reduceToolResult(_ result: ToolResult) -> [UUID] {
        let prefix = result.ok ? "ok" : "err"
        let summary = result.summary ?? ""

        guard let lineId = pendingToolLines.removeValue(forKey: result.callId),
              let index = lines.firstIndex(where: { $0.id == lineId }) else {
            // No pending tool_call line; surface the result on its own.
            let details = TranscriptLine.ToolDetails(
                callId: result.callId,
                name: "(unknown)",
                ok: result.ok,
                summary: result.summary
            )
            let line = TranscriptLine(
                kind: .tool,
                text: "(unknown) → \(prefix) \(summary)",
                toolDetails: details
            )
            lines.append(line)
            return [line.id]
        }
        let existing = lines[index]
        let name = existing.toolDetails?.name ?? "(unknown)"
        let updatedDetails = TranscriptLine.ToolDetails(
            callId: result.callId,
            name: name,
            ok: result.ok,
            summary: result.summary
        )
        lines[index] = TranscriptLine(
            id: lineId,
            kind: .tool,
            text: "\(name) → \(prefix) \(summary)",
            toolDetails: updatedDetails
        )
        return [lineId]
    }
}
