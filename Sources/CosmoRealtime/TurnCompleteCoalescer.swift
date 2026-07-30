import Foundation

/// Debounces a noisy ``VoiceActivityEvent`` stream into one coalesced
/// "turn complete" per actual utterance:
///   - ``minSpeakingDuration``: ambient-noise filter — too-short
///     speaking blips never count as a turn.
///   - ``minSilenceForTurnEnd``: trailing debounce — mid-sentence
///     pauses below this don't fire.
@MainActor
public final class TurnCompleteCoalescer {

    /// Injectable clock for testability. Production uses
    /// ``ContinuousClockWrapper``; tests use ``ManualClock``.
    public protocol CoalescerClock: Sendable {
        var now: ContinuousClock.Instant { get }
        func sleep(for duration: Duration) async throws
        /// Sleep until an absolute deadline. The coalescer prefers
        /// this so the wait isn't re-anchored if the clock advances
        /// between schedule and the Task body's first await.
        func sleep(until deadline: ContinuousClock.Instant) async throws
    }

    public typealias TurnCompleteCallback = @MainActor () async -> Void

    private let minSpeakingDuration: Duration
    private let minSilenceForTurnEnd: Duration
    private let clock: any CoalescerClock
    private let onTurnComplete: TurnCompleteCallback?

    private var speakingStartedAt: ContinuousClock.Instant?
    private var pendingFireTask: Task<Void, Never>?

    private var continuation: AsyncStream<Void>.Continuation?
    /// Test-facing stream — production wires through ``onTurnComplete``.
    public let turnCompletes: AsyncStream<Void>

    internal var _turnCompleteCount: Int = 0

    public init(
        minSpeakingDuration: Duration = .milliseconds(300),
        minSilenceForTurnEnd: Duration = .milliseconds(500),
        clock: any CoalescerClock = ContinuousClockWrapper(),
        onTurnComplete: TurnCompleteCallback? = nil
    ) {
        self.minSpeakingDuration = minSpeakingDuration
        self.minSilenceForTurnEnd = minSilenceForTurnEnd
        self.clock = clock
        self.onTurnComplete = onTurnComplete
        var captured: AsyncStream<Void>.Continuation!
        self.turnCompletes = AsyncStream<Void> { c in
            captured = c
        }
        self.continuation = captured
    }

    deinit {
        continuation?.finish()
    }

    public func ingest(_ event: VoiceActivityEvent) {
        switch event {
        case .userSpeaking:
            // Duplicate edges must NOT reset the start time, or an utterance
            // that straddles a noisy double-edge loses its speaking credit.
            if speakingStartedAt == nil {
                speakingStartedAt = clock.now
            }
            pendingFireTask?.cancel()
            pendingFireTask = nil

        case .userSilent:
            guard let start = speakingStartedAt else { return }
            let speakingTime = clock.now - start
            speakingStartedAt = nil
            guard speakingTime >= minSpeakingDuration else { return }
            pendingFireTask?.cancel()
            let clock = self.clock
            let deadline = clock.now.advanced(by: minSilenceForTurnEnd)
            pendingFireTask = Task { @MainActor [weak self] in
                do {
                    try await clock.sleep(until: deadline)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.fireTurnComplete()
            }
        }
    }

    internal func _hasPendingEvent() -> Bool {
        pendingFireTask != nil && !(pendingFireTask?.isCancelled ?? true)
    }

    private func fireTurnComplete() {
        pendingFireTask = nil
        _turnCompleteCount += 1
        continuation?.yield(())
        if let onTurnComplete {
            Task { @MainActor in
                await onTurnComplete()
            }
        }
    }
}

// MARK: - Clocks

public struct ContinuousClockWrapper: TurnCompleteCoalescer.CoalescerClock {
    private let inner = ContinuousClock()
    public init() {}
    public var now: ContinuousClock.Instant { inner.now }
    public func sleep(for duration: Duration) async throws {
        try await inner.sleep(for: duration)
    }
    public func sleep(until deadline: ContinuousClock.Instant) async throws {
        try await inner.sleep(until: deadline)
    }
}

/// Manual clock for tests — advances only via ``advance(by:)``;
/// resumes any waiters whose deadline the advance crossed.
public final class ManualClock: TurnCompleteCoalescer.CoalescerClock, @unchecked Sendable {
    private struct Waiter {
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var current: ContinuousClock.Instant
    private var waiters: [Waiter] = []

    public init(start: ContinuousClock.Instant = ContinuousClock().now) {
        self.current = start
    }

    public var now: ContinuousClock.Instant {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func sleep(for duration: Duration) async throws {
        try await sleep(until: now.advanced(by: duration))
    }

    public func sleep(until deadline: ContinuousClock.Instant) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if deadline <= current {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(Waiter(deadline: deadline, continuation: continuation))
            lock.unlock()
        }
    }

    public func advance(by duration: Duration) {
        lock.lock()
        current = current.advanced(by: duration)
        let toResume = waiters.filter { $0.deadline <= current }
        waiters.removeAll { $0.deadline <= current }
        lock.unlock()
        for waiter in toResume {
            waiter.continuation.resume()
        }
    }
}
