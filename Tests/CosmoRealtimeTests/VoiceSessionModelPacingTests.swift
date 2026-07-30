import Foundation
import Testing
@testable import CosmoRealtime

/// Behaviour: the assistant transcript is revealed word-by-word through a
/// ``TranscriptRevealer`` (cosmetic pacing so the caption doesn't race ahead of
/// the voice), while the user's own transcript is immediate. The reducer stays
/// the source of truth for structure; only the still-revealing assistant line's
/// displayed text is the paced prefix. These tests drive ``ingest`` directly
/// (the same seam ``handle`` uses) with a 1ms reveal interval so the pacing
/// resolves within the test.
@Suite struct VoiceSessionModelPacingTests {

    /// Poll `model.transcript` until `predicate` holds or the deadline passes.
    @MainActor
    private func waitUntil(
        _ model: VoiceSessionModel,
        timeout: Duration = .seconds(10),
        _ predicate: () -> Bool
    ) async -> Bool {
        let start = ContinuousClock().now
        while ContinuousClock().now - start < timeout {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return predicate()
    }

    @MainActor
    private func assistantLine(_ model: VoiceSessionModel) -> TranscriptLine? {
        model.transcript.last { $0.kind == .assistant }
    }

    @Test @MainActor
    func userTranscriptIsImmediate_notPaced() {
        guard #available(macOS 14, iOS 17, *) else { return }
        let model = VoiceSessionModel()
        // The user's own words are not revealed word-by-word — they land the
        // instant the delta is reduced (synchronous, no await).
        model.ingest(.transcript(Transcript(role: .user, text: "list my files", isFinal: false)))
        let line = model.transcript.last { $0.kind == .user }
        #expect(line?.text == "list my files")
    }

    @Test @MainActor
    func assistantRevealEventuallyShowsFullText() async {
        guard #available(macOS 14, iOS 17, *) else { return }
        let model = VoiceSessionModel()
        model.assistantRevealIntervalOverride = .milliseconds(1)

        // Deltas append; the final carries the cumulative per the wire contract.
        model.ingest(.transcript(Transcript(role: .assistant, text: "Hello ", isFinal: false)))
        model.ingest(.transcript(Transcript(role: .assistant, text: "there ", isFinal: false)))
        model.ingest(.transcript(Transcript(role: .assistant, text: "friend", isFinal: false)))
        model.ingest(.transcript(Transcript(role: .assistant, text: "Hello there friend", isFinal: true)))

        let reached = await waitUntil(model) { assistantLine(model)?.text == "Hello there friend" }
        #expect(reached)
    }

    @Test @MainActor
    func assistantRevealOnlyEverShowsWordAlignedPrefixes() async {
        guard #available(macOS 14, iOS 17, *) else { return }
        let model = VoiceSessionModel()
        model.assistantRevealIntervalOverride = .milliseconds(1)

        let full = "one two three four five"
        model.ingest(.transcript(Transcript(role: .assistant, text: full, isFinal: false)))

        // Sample the paced line a few times; every value must be a word-aligned
        // prefix of the target (never a mid-word or ahead-of-target string).
        let tokens = TranscriptRevealer.tokenize(full)
        let validPrefixes = Set((0...tokens.count).map { tokens[0..<$0].joined() })
        for _ in 0..<20 {
            if let text = assistantLine(model)?.text {
                #expect(validPrefixes.contains(text), "unexpected prefix: \(text)")
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        model.ingest(.transcript(Transcript(role: .assistant, text: full, isFinal: true)))
        let reached = await waitUntil(model) { assistantLine(model)?.text == full }
        #expect(reached)
    }

    @Test @MainActor
    func assistantEmptyFinalRemovesTheLine() async {
        guard #available(macOS 14, iOS 17, *) else { return }
        let model = VoiceSessionModel()
        model.assistantRevealIntervalOverride = .milliseconds(1)

        // Suppressed turn: partials stream, then the backend force-closes with
        // an empty final. The line must be REMOVED, not left as an empty bubble.
        model.ingest(.transcript(Transcript(role: .assistant, text: "model", isFinal: false)))
        _ = await waitUntil(model) { assistantLine(model) != nil }

        model.ingest(.transcript(Transcript(role: .assistant, text: "", isFinal: true)))
        let gone = await waitUntil(model) { assistantLine(model) == nil }
        #expect(gone)
    }

    @Test @MainActor
    func lateFinalAfterTurnCompleteRendersTurnOnce() async {
        guard #available(macOS 14, iOS 17, *) else { return }
        let model = VoiceSessionModel()
        model.assistantRevealIntervalOverride = .milliseconds(1)

        // Terminator races ahead of the cumulative final. The published
        // transcript (what the apps render) must settle on ONE assistant line,
        // not the streamed partial line plus a duplicate final line.
        model.ingest(.transcript(Transcript(role: .assistant, text: "Hello ", isFinal: false)))
        model.ingest(.transcript(Transcript(role: .assistant, text: "there", isFinal: false)))
        model.ingest(.turnComplete(role: .assistant))
        model.ingest(.transcript(Transcript(role: .assistant, text: "Hello there", isFinal: true)))

        let settled = await waitUntil(model) {
            assistantLine(model)?.text == "Hello there"
                && model.transcript.filter { $0.kind == .assistant }.count == 1
        }
        #expect(settled)
        #expect(model.transcript.filter { $0.kind == .assistant }.count == 1)
    }

    @Test @MainActor
    func userLineCoexistsWithPacedAssistantLine() async {
        guard #available(macOS 14, iOS 17, *) else { return }
        let model = VoiceSessionModel()
        model.assistantRevealIntervalOverride = .milliseconds(1)

        model.ingest(.transcript(Transcript(role: .user, text: "hi", isFinal: true)))
        model.ingest(.transcript(Transcript(role: .assistant, text: "Well hello", isFinal: false)))
        model.ingest(.transcript(Transcript(role: .assistant, text: "Well hello.", isFinal: true)))

        let ok = await waitUntil(model) {
            model.transcript.contains { $0.kind == .user && $0.text == "hi" }
                && assistantLine(model)?.text == "Well hello."
        }
        #expect(ok)
    }
}
