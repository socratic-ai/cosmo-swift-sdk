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

    /// One-shot flag so whichever of the two racers below finishes first is the
    /// one that resumes. ``@MainActor`` rather than a lock — both hop back here
    /// to claim it.
    @MainActor
    private final class Once {
        private var claimed = false
        func claim() -> Bool { defer { claimed = true }; return !claimed }
    }

    /// Suspend until the turn's reveal has settled, reporting whether it did.
    /// Awaiting the reveal rather than polling for the text keeps these tests
    /// off the wall clock — co-scheduled with the rest of the suite the paced
    /// ticker can be descheduled for far longer than any budget worth
    /// hard-coding — but the await is bounded so a reveal that never completes
    /// fails with a name instead of wedging the whole run. The ceiling is only
    /// a backstop: it is never approached when the reveal works.
    ///
    /// Raced through a one-shot continuation rather than a task group because
    /// `Task<Void, Never>.value` does not honour cancellation: a group would
    /// wait forever on the losing child at scope exit, which is the hang this
    /// is here to prevent.
    @MainActor
    private func awaitRevealSettled(
        _ model: VoiceSessionModel,
        timeout: Duration = .seconds(30)
    ) async -> Bool {
        guard let reveal = model.assistantRevealTask else { return true }
        let once = Once()
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            Task { @MainActor in
                await reveal.value
                if once.claim() { cont.resume(returning: true) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                if once.claim() { cont.resume(returning: false) }
            }
        }
    }

    /// Poll until `predicate` holds. Only for the two conditions that are
    /// deliberately observed mid-reveal, where there is no completion to await.
    @MainActor
    private func waitUntil(
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

        #expect(await awaitRevealSettled(model), "the reveal never settled")
        #expect(assistantLine(model)?.text == "Hello there friend")
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
        #expect(await awaitRevealSettled(model), "the reveal never settled")
        #expect(assistantLine(model)?.text == full)
    }

    @Test @MainActor
    func assistantEmptyFinalRemovesTheLine() async {
        guard #available(macOS 14, iOS 17, *) else { return }
        let model = VoiceSessionModel()
        model.assistantRevealIntervalOverride = .milliseconds(1)

        // Suppressed turn: partials stream, then the backend force-closes with
        // an empty final. The line must be REMOVED, not left as an empty bubble.
        // The wait is what makes this meaningful — without a visible bubble
        // first, the empty final would trivially leave nothing behind.
        model.ingest(.transcript(Transcript(role: .assistant, text: "model", isFinal: false)))
        #expect(await waitUntil { assistantLine(model) != nil })

        model.ingest(.transcript(Transcript(role: .assistant, text: "", isFinal: true)))
        #expect(assistantLine(model) == nil)
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

        #expect(await awaitRevealSettled(model), "the reveal never settled")
        #expect(assistantLine(model)?.text == "Hello there")
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

        #expect(await awaitRevealSettled(model), "the reveal never settled")
        #expect(model.transcript.contains { $0.kind == .user && $0.text == "hi" })
        #expect(assistantLine(model)?.text == "Well hello.")
    }

    @Test @MainActor
    func revealThatOutrunsTheFinalStillReleasesTheLine() async {
        guard #available(macOS 14, iOS 17, *) else { return }
        let model = VoiceSessionModel()
        model.assistantRevealIntervalOverride = .milliseconds(1)

        // The paced reveal catches the whole partial before the wire final
        // lands, so the final carries a cumulative the reveal has already
        // displayed and the revealer has no further word to yield. The line
        // must still be released — otherwise every later structural change the
        // reducer makes to it is masked by the frozen paced prefix, until the
        // next assistant turn tears the reveal down.
        //
        // One word on purpose: the reveal has to outrun the final, and a
        // single token is the fewest paced ticks that can be starved by the
        // rest of the suite while this waits on them.
        model.ingest(.transcript(Transcript(role: .assistant, text: "Hello", isFinal: false)))
        #expect(await waitUntil { assistantLine(model)?.text == "Hello" })

        model.ingest(.transcript(Transcript(role: .assistant, text: "Hello", isFinal: true)))

        #expect(await awaitRevealSettled(model), "the reveal never released the line")
        #expect(assistantLine(model)?.text == "Hello")
    }
}
