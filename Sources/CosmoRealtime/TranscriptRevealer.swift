import Foundation

/// Drives a word-by-word reveal of a streaming transcript line, decoupling
/// display pacing from the (often chunky, provider-dependent) cadence of
/// transcript deltas on the wire.
///
/// Feed it the latest **cumulative** text for one transcript line via
/// ``setTarget(_:isFinal:)`` as deltas arrive, and render ``revealed`` — a
/// prefix that grows one word at a time at ``wordInterval``. When the line
/// finalizes (`isFinal: true`) the reveal snaps to the full text and the
/// stream finishes. UI-agnostic: it yields plain `String`s, so it drives
/// SwiftUI, UIKit, or AppKit equally.
///
/// One revealer drives one line — make a fresh ``TranscriptRevealer`` for each
/// new in-progress line (e.g. each turn / role).
///
/// Wiring it to the transcript event stream (the wire contract is
/// "append on non-final, replace on final"):
/// ```swift
/// let revealer = TranscriptRevealer()
/// var accumulated = ""
/// let token = await client.onTranscript { delta in
///     accumulated = delta.isFinal ? delta.text : accumulated + delta.text
///     await revealer.setTarget(accumulated, isFinal: delta.isFinal)
/// }
/// for await text in revealer.revealed { label.text = text }
/// ```
///
/// The reveal is a cosmetic fixed cadence, not synced to the spoken audio
/// (neither provider exposes per-word timestamps). To keep it from trailing a
/// fast talker it never lags more than ``maxLagWords`` behind the target, and
/// it snaps fully on finalize.
public actor TranscriptRevealer {

    /// Progressively-revealed text for the line. Yields word-aligned prefixes
    /// of the current target; the final element is the full finalized text,
    /// after which the stream finishes.
    public nonisolated let revealed: AsyncStream<String>

    private let continuation: AsyncStream<String>.Continuation
    /// Mutable so the tail can be drained once the voice has stopped — see
    /// ``accelerate(to:)``.
    private var wordInterval: Duration
    private let maxLagWords: Int

    /// Grid slack tolerated before the schedule is re-based on now. Ordinary
    /// jitter is absorbed by the grid; anything past this is a suspension.
    private static let maxGridCatchUp: Duration = .seconds(1)
    /// Small enough that coalescing can't visibly stagger the reveal, and with
    /// an absolute grid it no longer accumulates.
    private static let wakeupTolerance: Duration = .milliseconds(15)

    /// Word tokens of the current target; concatenating them reproduces the
    /// target verbatim (see ``tokenize(_:)``).
    private var tokens: [String] = []
    private var revealedCount = 0
    private var isFinished = false
    private var ticker: Task<Void, Never>?

    /// - Parameters:
    ///   - wordInterval: minimum delay between revealed words. 70ms ≈ a brisk
    ///     speaking pace; the lowest rate that still reads as "live".
    ///   - maxLagWords: cap on how far the reveal may trail the target before
    ///     it reveals multiple words per tick to catch up.
    public init(wordInterval: Duration = .milliseconds(70), maxLagWords: Int = 8) {
        self.wordInterval = wordInterval
        self.maxLagWords = max(1, maxLagWords)
        (self.revealed, self.continuation) = AsyncStream.makeStream(of: String.self)
        continuation.onTermination = { [weak self] _ in
            // Consumer stopped listening — tear the ticker down.
            Task { await self?.finish() }
        }
    }

    /// Update the line's latest cumulative text. `isFinal: true` snaps the
    /// reveal to `fullText` and finishes the stream. No-op after the line has
    /// finished.
    public func setTarget(_ fullText: String, isFinal: Bool) {
        guard !isFinished else { return }
        tokens = Self.tokenize(fullText)
        revealedCount = min(revealedCount, tokens.count)
        if isFinal {
            revealedCount = tokens.count
            continuation.yield(fullText)
            finish()
        } else {
            ensureTicking()
        }
    }

    /// Stop revealing and finish the stream. Idempotent.
    public func finish() {
        guard !isFinished else { return }
        isFinished = true
        ticker?.cancel()
        ticker = nil
        continuation.finish()
    }

    private func ensureTicking() {
        guard ticker == nil, !isFinished else { return }
        ticker = Task { [weak self] in
            guard let self else { return }
            // Absolute deadlines on a fixed grid, not `sleep(for:)` after each
            // step. A relative sleep restarts the clock once the step returns,
            // so scheduling slack — and the wakeup tolerance below — compounds
            // instead of averaging out; with no catch-up at the call site that
            // drift is permanent lag for the rest of the turn.
            var deadline = ContinuousClock.now
            // Reveal one step immediately for responsiveness, then pace.
            while await self.advanceOneStep() {
                deadline = deadline.advanced(by: await self.currentInterval)
                let now = ContinuousClock.now
                // Back on the grid one word at a time after ordinary jitter, but
                // a long suspension (backgrounded app) must not bank credit and
                // dump the backlog on resume.
                if deadline < now - Self.maxGridCatchUp { deadline = now }
                try? await ContinuousClock().sleep(until: deadline, tolerance: Self.wakeupTolerance)
            }
        }
    }

    /// Shorten the remaining cadence. Used to drain the tail once the voice has
    /// stopped, where the reason for pacing at all no longer applies.
    public func accelerate(to interval: Duration) {
        guard !isFinished, interval < wordInterval else { return }
        wordInterval = interval
    }

    private var currentInterval: Duration { wordInterval }

    /// Advance the reveal by one paced step. Returns whether the ticker should
    /// keep running; stops itself (clears ``ticker``) once it catches up so it
    /// never outlives the work it drives.
    private func advanceOneStep() -> Bool {
        guard !isFinished else { return false }
        let step = Self.step(deficit: tokens.count - revealedCount, maxLagWords: maxLagWords)
        guard step > 0 else {
            ticker = nil
            return false
        }
        revealedCount += step
        continuation.yield(tokens[0..<revealedCount].joined())
        return true
    }

    // MARK: - Pure helpers (deterministically unit-tested)

    /// Split `s` into word tokens whose concatenation reproduces `s` exactly.
    /// A token is a word plus the whitespace that follows it; a new token
    /// begins at each whitespace→word transition. Revealing the first N tokens
    /// therefore always yields a valid, word-aligned prefix of `s`.
    static func tokenize(_ s: String) -> [String] {
        guard !s.isEmpty else { return [] }
        var tokens: [String] = []
        var current = ""
        var prevWasSpace = false
        for ch in s {
            let isSpace = ch.isWhitespace
            if !isSpace, prevWasSpace, !current.isEmpty {
                tokens.append(current)
                current = ""
            }
            current.append(ch)
            prevWasSpace = isSpace
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Words to reveal this tick: one at a time normally, but enough extra to
    /// pull the backlog back to ``maxLagWords`` whenever it exceeds that — so
    /// the reveal never trails the target by more than the cap.
    static func step(deficit: Int, maxLagWords: Int) -> Int {
        guard deficit > 0 else { return 0 }
        return deficit > maxLagWords ? deficit - maxLagWords : 1
    }
}
