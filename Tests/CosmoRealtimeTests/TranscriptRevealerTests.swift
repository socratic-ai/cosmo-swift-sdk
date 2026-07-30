import Foundation
import Testing
@testable import CosmoRealtime

@Suite("TranscriptRevealer")
struct TranscriptRevealerTests {

    // MARK: - accelerate (tail drain once the voice has stopped)

    /// The reveal paces so it can't outrun the voice. Once the voice has
    /// stopped there is nothing to outrun, and the remaining words must drain
    /// rather than crawl on after the audio — otherwise the caption outlives
    /// the turn, which is the artifact this exists to remove.
    @Test func accelerateDrainsTheTailInsteadOfCrawling() async throws {
        // A cadence so slow that finishing on it is impossible inside the
        // timeout — only the acceleration can get there.
        let revealer = TranscriptRevealer(wordInterval: .seconds(10), maxLagWords: .max)
        let full = "one two three four five six"
        await revealer.setTarget(full, isFinal: false)
        await revealer.accelerate(to: .milliseconds(1))

        var last = ""
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        for await prefix in revealer.revealed {
            last = prefix
            if prefix == full { break }
            if ContinuousClock.now > deadline { break }
        }
        #expect(last == full)
    }

    /// Acceleration is one-way: a slower interval must never undo a drain that
    /// is already running.
    @Test func accelerateIgnoresASlowerInterval() async {
        let revealer = TranscriptRevealer(wordInterval: .milliseconds(10), maxLagWords: .max)
        await revealer.setTarget("one two three", isFinal: false)
        await revealer.accelerate(to: .seconds(5))

        var last = ""
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        for await prefix in revealer.revealed {
            last = prefix
            if prefix == "one two three" { break }
            if ContinuousClock.now > deadline { break }
        }
        #expect(last == "one two three")
    }

    // MARK: - tokenize (pure, exact)

    @Test func tokenizeRoundTripsVerbatim() {
        for s in [
            "", "Hello", "Hello world", "Hello there general Kenobi",
            "  leading", "trailing ", "multiple   spaces", "punctuation! Yes.",
            "\nnewlines\nhere", "tabs\tand spaces",
        ] {
            #expect(TranscriptRevealer.tokenize(s).joined() == s)
        }
    }

    @Test func tokenizeSplitsAtWordStarts() {
        #expect(TranscriptRevealer.tokenize("Hello world") == ["Hello ", "world"])
        #expect(TranscriptRevealer.tokenize("a b c") == ["a ", "b ", "c"])
        #expect(TranscriptRevealer.tokenize("one") == ["one"])
        #expect(TranscriptRevealer.tokenize("").isEmpty)
    }

    @Test func everyTokenPrefixIsAPrefixOfTheWhole() {
        let tokens = TranscriptRevealer.tokenize("Hello there general Kenobi")
        let full = tokens.joined()
        var acc = ""
        for t in tokens {
            acc += t
            #expect(full.hasPrefix(acc))
        }
    }

    // MARK: - step (pure, exact)

    @Test func stepRevealsOneWordByDefault() {
        #expect(TranscriptRevealer.step(deficit: 0, maxLagWords: 8) == 0)
        #expect(TranscriptRevealer.step(deficit: 1, maxLagWords: 8) == 1)
        #expect(TranscriptRevealer.step(deficit: 8, maxLagWords: 8) == 1)
    }

    @Test func stepCatchesUpWhenBacklogExceedsCap() {
        // deficit 20, cap 8 → reveal 12 so the remaining lag is exactly 8.
        #expect(TranscriptRevealer.step(deficit: 20, maxLagWords: 8) == 12)
        #expect(20 - TranscriptRevealer.step(deficit: 20, maxLagWords: 8) == 8)
    }

    // MARK: - streaming behavior (completion is deterministic via isFinal)

    @Test func revealEndsAtFullTextWithOnlyWordAlignedPrefixes() async {
        let full = "Hello there general Kenobi"
        let revealer = TranscriptRevealer(wordInterval: .milliseconds(1))
        let collector = Task { () -> [String] in
            var out: [String] = []
            for await s in revealer.revealed { out.append(s) }
            return out
        }
        await revealer.setTarget("Hello there", isFinal: false)
        await revealer.setTarget("Hello there general", isFinal: false)
        await revealer.setTarget(full, isFinal: true)

        let out = await collector.value
        #expect(!out.isEmpty)
        #expect(out.last == full)

        // Every emission is a word-aligned prefix of the final text.
        let tokens = TranscriptRevealer.tokenize(full)
        let validPrefixes = Set((0...tokens.count).map { tokens[0..<$0].joined() })
        for s in out {
            #expect(full.hasPrefix(s))
            #expect(validPrefixes.contains(s))
        }
    }

    @Test func finalSnapsImmediatelyEvenWithSlowInterval() async {
        let full = "one two three four five"
        // A 10s interval would never reveal via the ticker during the test;
        // the final must snap in one shot regardless.
        let revealer = TranscriptRevealer(wordInterval: .seconds(10))
        let collector = Task { () -> [String] in
            var out: [String] = []
            for await s in revealer.revealed { out.append(s) }
            return out
        }
        await revealer.setTarget(full, isFinal: true)
        let out = await collector.value
        #expect(out == [full])
    }

    @Test func finishStopsTheStream() async {
        let revealer = TranscriptRevealer(wordInterval: .milliseconds(1))
        let collector = Task { () -> String? in
            var last: String?
            for await s in revealer.revealed { last = s }
            return last  // returning means the stream finished (didn't hang)
        }
        await revealer.setTarget("alpha beta gamma delta", isFinal: false)
        await revealer.finish()
        let last = await collector.value
        if let last { #expect("alpha beta gamma delta".hasPrefix(last)) }
    }

    @Test func setTargetAfterFinishIsIgnored() async {
        let revealer = TranscriptRevealer(wordInterval: .milliseconds(1))
        let collector = Task { () -> [String] in
            var out: [String] = []
            for await s in revealer.revealed { out.append(s) }
            return out
        }
        await revealer.setTarget("done", isFinal: true)
        await revealer.setTarget("ignored extra text", isFinal: false)
        let out = await collector.value
        #expect(out == ["done"])
    }
}
