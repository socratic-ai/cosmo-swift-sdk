import Foundation
import os

/// Accumulates per-session WebRTC quality from `TrackStatistics` updates
/// (delivered ~1 Hz via ``SessionQoEStatsObserver``) and connection-quality
/// updates, then computes a ``SessionQoESnapshot`` on demand. Lock-guarded
/// and ``Sendable`` because it's written from LiveKit's off-actor delegate
/// queue and read at terminal close.
///
/// At ~1 Hz a session is a few hundred samples per metric, so we keep raw
/// gauge-sample arrays and compute percentiles on demand — no histogram
/// dependency. Cross-session percentile aggregation is the backend's job.
/// Pathologically long sessions are bounded by ``maxSamples``.
final class SessionQoEAggregator: Sendable {
    /// Rolling window of gauge samples (~1 h at the 1 Hz update cadence).
    /// Bounds memory on marathon sessions while keeping percentiles recent —
    /// a fixed cap that dropped *new* samples would freeze p95 at the first
    /// hour and hide later degradation.
    private static let maxSamples = 3600

    /// Sums a cumulative WebRTC counter into a session total that survives
    /// counter resets (e.g. a reconnect spins up a fresh PeerConnection and
    /// the counter restarts at 0). Adds the first observed value (growth
    /// from 0), then positive deltas; on a reset (value < previous) it adds
    /// the new value as the post-reset increment. `observed` distinguishes
    /// "measured 0" from "never measured" so audio-only sessions don't emit
    /// video counters as if they were zero.
    struct CounterAccumulator: Sendable, Equatable {
        private(set) var total: Double = 0
        private(set) var observed = false
        private var prev: Double?

        mutating func record(_ value: Double) {
            observed = true
            if let prev {
                total += value >= prev ? (value - prev) : value
            } else {
                total += value
            }
            prev = value
        }
    }

    private struct State {
        var wsMs: Double?
        var roomMs: Double?
        var micMs: Double?
        var totalMs: Double?
        var serverTimings: SessionStartServerTimings?

        var jitterMs: [Double] = []
        var rttMs: [Double] = []
        var jitterBufferMs: [Double] = []

        // Screen-share send (outbound video).
        var screenShareFps: [Double] = []
        var screenShareEncodeMs: [Double] = []
        var screenShareCpuLimitedMs = CounterAccumulator()
        var screenShareBandwidthLimitedMs = CounterAccumulator()
        var prevEncodeSeconds: Double?
        var prevFramesEncoded: UInt?

        var packetsLost = CounterAccumulator()
        var concealmentEvents = CounterAccumulator()

        var sampleCount = 0

        var prevJitterBufferDelaySeconds: Double?
        var prevJitterBufferEmittedCount: UInt64?

        var worstQuality: RealtimeConnectionQuality?
        var qualityUpdates = 0
        var poorOrLostUpdates = 0
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    func setConnectPhases(wsMs: Double, roomMs: Double, micMs: Double, totalMs: Double) {
        state.withLock {
            $0.wsMs = wsMs
            $0.roomMs = roomMs
            $0.micMs = micMs
            $0.totalMs = totalMs
        }
    }

    func setServerTimings(_ timings: SessionStartServerTimings) {
        state.withLock { $0.serverTimings = timings }
    }

    /// Fold one stats reading. Gauge fields (jitter, RTT) are sampled
    /// directly; cumulative counters accumulate reset-safe; jitter-buffer
    /// delay is averaged per-interval via deltas (negative deltas from a
    /// counter reset are dropped).
    func record(_ sample: QoESample) {
        guard !sample.isEmpty else { return }
        state.withLock { s in
            s.sampleCount += 1

            if let jitter = sample.jitterSeconds {
                appendBounded(&s.jitterMs, jitter * 1000)
            }
            if let rtt = sample.roundTripTimeSeconds {
                appendBounded(&s.rttMs, rtt * 1000)
            }

            if let delay = sample.jitterBufferDelaySeconds,
               let emitted = sample.jitterBufferEmittedCount {
                if let prevDelay = s.prevJitterBufferDelaySeconds,
                   let prevEmitted = s.prevJitterBufferEmittedCount,
                   emitted > prevEmitted, delay >= prevDelay {
                    let avgSeconds = (delay - prevDelay) / Double(emitted - prevEmitted)
                    appendBounded(&s.jitterBufferMs, avgSeconds * 1000)
                }
                s.prevJitterBufferDelaySeconds = delay
                s.prevJitterBufferEmittedCount = emitted
            }

            if let v = sample.packetsLost { s.packetsLost.record(Double(v)) }
            if let v = sample.concealmentEvents { s.concealmentEvents.record(Double(v)) }

            // Screen-share send (outbound video) — straight from LiveKit.
            if let fps = sample.outboundFramesPerSecond {
                appendBounded(&s.screenShareFps, fps)
            }
            if let encode = sample.totalEncodeTimeSeconds,
               let frames = sample.framesEncoded {
                if let prevEncode = s.prevEncodeSeconds,
                   let prevFrames = s.prevFramesEncoded,
                   frames > prevFrames, encode >= prevEncode {
                    let avgSeconds = (encode - prevEncode) / Double(frames - prevFrames)
                    appendBounded(&s.screenShareEncodeMs, avgSeconds * 1000)
                }
                s.prevEncodeSeconds = encode
                s.prevFramesEncoded = frames
            }
            if let v = sample.qualityLimitedCpuSeconds { s.screenShareCpuLimitedMs.record(v * 1000) }
            if let v = sample.qualityLimitedBandwidthSeconds { s.screenShareBandwidthLimitedMs.record(v * 1000) }
        }
    }

    func record(quality: RealtimeConnectionQuality) {
        state.withLock { s in
            s.qualityUpdates += 1
            // ``.unknown`` is "no measurement", not a quality level — it
            // neither sets the worst observed quality nor counts as degraded.
            guard quality != .unknown else { return }
            if quality == .poor || quality == .lost {
                s.poorOrLostUpdates += 1
            }
            if let worst = s.worstQuality {
                if quality.severityRank < worst.severityRank {
                    s.worstQuality = quality
                }
            } else {
                s.worstQuality = quality
            }
        }
    }

    func snapshot() -> SessionQoESnapshot {
        state.withLock { s in
            let quality: SessionConnectionQualitySummary? = s.worstQuality.map {
                SessionConnectionQualitySummary(
                    worst: $0,
                    updates: s.qualityUpdates,
                    poorOrLostUpdates: s.poorOrLostUpdates
                )
            }
            return SessionQoESnapshot(
                wsMs: s.wsMs,
                roomMs: s.roomMs,
                micMs: s.micMs,
                totalConnectMs: s.totalMs,
                serverTimings: s.serverTimings,
                jitterMs: Self.summarize(s.jitterMs),
                roundTripMs: Self.summarize(s.rttMs),
                jitterBufferMs: Self.summarize(s.jitterBufferMs),
                screenShareFps: Self.summarize(s.screenShareFps),
                screenShareEncodeMs: Self.summarize(s.screenShareEncodeMs),
                screenShareCpuLimitedMs: s.screenShareCpuLimitedMs.observed ? s.screenShareCpuLimitedMs.total : nil,
                screenShareBandwidthLimitedMs: s.screenShareBandwidthLimitedMs.observed ? s.screenShareBandwidthLimitedMs.total : nil,
                packetsLost: s.packetsLost.observed ? Int64(s.packetsLost.total) : nil,
                concealmentEvents: s.concealmentEvents.observed ? UInt64(s.concealmentEvents.total) : nil,
                connectionQuality: quality,
                sampleCount: s.sampleCount
            )
        }
    }

    private func appendBounded(_ array: inout [Double], _ value: Double) {
        array.append(value)
        if array.count > Self.maxSamples {
            array.removeFirst(array.count - Self.maxSamples)
        }
    }

    static func summarize(_ samples: [Double]) -> SessionQoEMetricSummary? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let sum = sorted.reduce(0, +)
        return SessionQoEMetricSummary(
            count: sorted.count,
            min: sorted.first!,
            avg: sum / Double(sorted.count),
            p50: percentile(sorted, 0.50),
            p95: percentile(sorted, 0.95),
            max: sorted.last!
        )
    }

    /// Nearest-rank percentile over a pre-sorted array.
    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        let index = Swift.min(Swift.max(rank - 1, 0), sorted.count - 1)
        return sorted[index]
    }
}
