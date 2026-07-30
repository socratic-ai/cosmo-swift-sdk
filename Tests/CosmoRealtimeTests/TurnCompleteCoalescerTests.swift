import XCTest
@testable import CosmoRealtime

/// Tests for ``TurnCompleteCoalescer``.
///
/// Why this exists at all: the HAL stream emits ``.userSpeaking`` /
/// ``.userSilent`` on every transition — a sneeze, a cough, a "hmm"
/// each produce an active/silent edge. The coalescer turns that noise
/// into a single ``turnComplete`` per actual utterance:
///   - a leading-edge filter (``minSpeakingDuration``) rejects brief
///     noises that never crossed into "real" speaking;
///   - a trailing-edge debounce (``minSilenceForTurnEnd``) waits long
///     enough that mid-sentence pauses don't fire.
///
/// All tests run against an injected ``Clock`` so they're deterministic
/// — no `Task.sleep` racing test timers.
@MainActor
final class TurnCompleteCoalescerTests: XCTestCase {

    // ─────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────

    /// Build a coalescer with a manual clock and short thresholds for
    /// fast tests. Default thresholds match production defaults.
    private func makeCoalescer(
        minSpeakingMs: Int = 300,
        minSilenceMs: Int = 500
    ) -> (TurnCompleteCoalescer, ManualClock) {
        let clock = ManualClock()
        let coalescer = TurnCompleteCoalescer(
            minSpeakingDuration: .milliseconds(minSpeakingMs),
            minSilenceForTurnEnd: .milliseconds(minSilenceMs),
            clock: clock
        )
        return (coalescer, clock)
    }

    /// ManualClock.advance synchronously resumes any sleep continuations
    /// whose deadline has been crossed — but the *awaiting Task body*
    /// still needs the MainActor scheduler to pick it back up before
    /// ``fireTurnComplete`` actually runs. A single ``Task.yield()``
    /// covers one suspension hop; the chain here is two
    /// (sleep-continuation-resume → MainActor reschedule → method call),
    /// and counting yields gets brittle across Swift runtimes. A brief
    /// real-time pause is robust because the in-flight Tasks are tied
    /// to the already-advanced ``ManualClock``, not the wall clock —
    /// so this doesn't burn the silence-gate window.
    private func drainScheduledFires() async {
        try? await Task.sleep(for: .milliseconds(20))
    }

    // ─────────────────────────────────────────────────────────────────────
    // Tests
    // ─────────────────────────────────────────────────────────────────────

    func test_one_full_utterance_fires_exactly_one_turn_complete() async throws {
        let (coalescer, clock) = makeCoalescer()
        coalescer.ingest(.userSpeaking)
        clock.advance(by: .milliseconds(500))  // user speaks for 500 ms — well over the 300 ms gate
        coalescer.ingest(.userSilent)
        clock.advance(by: .milliseconds(500))  // silence holds for the required 500 ms
        await drainScheduledFires()  // let the deferred Task run

        XCTAssertEqual(coalescer._turnCompleteCount, 1)
    }

    func test_brief_noise_below_min_speaking_does_not_fire() async throws {
        // A cough lasting 100 ms should not register as a turn —
        // ``minSpeakingDuration`` is 300 ms.
        let (coalescer, clock) = makeCoalescer()
        coalescer.ingest(.userSpeaking)
        clock.advance(by: .milliseconds(100))
        coalescer.ingest(.userSilent)
        clock.advance(by: .milliseconds(500))
        await drainScheduledFires()

        XCTAssertEqual(coalescer._turnCompleteCount, 0)
    }

    func test_silence_shorter_than_threshold_does_not_fire() async throws {
        // A 200 ms mid-sentence pause is shorter than the 500 ms silence
        // gate — must not fire a turn-complete.
        let (coalescer, clock) = makeCoalescer()
        coalescer.ingest(.userSpeaking)
        clock.advance(by: .milliseconds(500))
        coalescer.ingest(.userSilent)
        clock.advance(by: .milliseconds(200))
        // User resumes before the silence gate expires.
        coalescer.ingest(.userSpeaking)
        clock.advance(by: .milliseconds(500))
        coalescer.ingest(.userSilent)
        clock.advance(by: .milliseconds(500))
        await drainScheduledFires()

        // Only one turn-complete: the second silence transition (after the
        // pause + resumed speech) is the real end of the utterance.
        XCTAssertEqual(coalescer._turnCompleteCount, 1)
    }

    func test_repeated_silent_edges_only_fire_once() async throws {
        // HAL can emit two `.userSilent` in a row (it's edge-triggered
        // but state-read; sub-threshold flapping shows up). Only ONE
        // turn-complete should fire.
        let (coalescer, clock) = makeCoalescer()
        coalescer.ingest(.userSpeaking)
        clock.advance(by: .milliseconds(500))
        coalescer.ingest(.userSilent)
        clock.advance(by: .milliseconds(100))
        coalescer.ingest(.userSilent)  // duplicate edge
        clock.advance(by: .milliseconds(500))
        await drainScheduledFires()

        XCTAssertEqual(coalescer._turnCompleteCount, 1)
    }

    func test_repeated_speaking_edges_do_not_restart_the_speaking_gate() async throws {
        // Two consecutive ``.userSpeaking`` must NOT reset the speaking
        // start time. If the second edge reset it, an utterance that
        // straddles a noisy double-edge would lose its min-speaking
        // credit and never fire.
        let (coalescer, clock) = makeCoalescer()
        coalescer.ingest(.userSpeaking)
        clock.advance(by: .milliseconds(200))
        coalescer.ingest(.userSpeaking)  // duplicate edge — must not reset
        clock.advance(by: .milliseconds(150))
        // Total speaking time so far: 350 ms — enough to clear the
        // 300 ms gate ONLY if the second edge didn't reset.
        coalescer.ingest(.userSilent)
        clock.advance(by: .milliseconds(500))
        await drainScheduledFires()

        XCTAssertEqual(coalescer._turnCompleteCount, 1)
    }

    func test_two_full_utterances_in_a_row_fire_two_turn_completes() async throws {
        let (coalescer, clock) = makeCoalescer()

        // Utterance 1.
        coalescer.ingest(.userSpeaking)
        clock.advance(by: .milliseconds(500))
        coalescer.ingest(.userSilent)
        clock.advance(by: .milliseconds(500))
        await drainScheduledFires()
        XCTAssertEqual(coalescer._turnCompleteCount, 1)

        // Utterance 2.
        coalescer.ingest(.userSpeaking)
        clock.advance(by: .milliseconds(500))
        coalescer.ingest(.userSilent)
        clock.advance(by: .milliseconds(500))
        await drainScheduledFires()
        XCTAssertEqual(coalescer._turnCompleteCount, 2)
    }

    func test_ingest_silent_with_no_prior_speaking_is_ignored() async throws {
        // A `.userSilent` arriving cold (e.g. monitor start when nobody
        // is speaking) must not fire — there was no turn to complete.
        let (coalescer, clock) = makeCoalescer()
        coalescer.ingest(.userSilent)
        clock.advance(by: .milliseconds(500))
        await drainScheduledFires()
        XCTAssertEqual(coalescer._turnCompleteCount, 0)
    }
}
