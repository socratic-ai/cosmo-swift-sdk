import Foundation

/// Coarse, server-computed connection-quality rating mirrored from the
/// transport layer so the public surface never leaks the LiveKit type.
public enum RealtimeConnectionQuality: String, Sendable, Equatable {
    case unknown
    case lost
    case poor
    case good
    case excellent

    /// Ordering for "worst observed": ``lost`` is worst, ``excellent`` best.
    /// ``unknown`` ("no measurement") is excluded from worst-tracking by the
    /// aggregator, so its rank here is a never-compared sentinel.
    var severityRank: Int {
        switch self {
        case .lost: return 0
        case .poor: return 1
        case .good: return 2
        case .excellent: return 3
        case .unknown: return Int.max
        }
    }
}

/// Distribution summary for a metric sampled across a session.
public struct SessionQoEMetricSummary: Sendable, Equatable {
    public let count: Int
    public let min: Double
    public let avg: Double
    public let p50: Double
    public let p95: Double
    public let max: Double

    public init(count: Int, min: Double, avg: Double, p50: Double, p95: Double, max: Double) {
        self.count = count
        self.min = min
        self.avg = avg
        self.p50 = p50
        self.p95 = p95
        self.max = max
    }
}

/// Coarse connection-quality accounting over a session, aggregated
/// **session-wide across all participants** (local + remote) — `worst` is the
/// worst quality any participant reported, not a single transport direction.
/// Quality updates are event-driven (on change), so this is a summary — worst
/// observed plus how many updates landed in a degraded state — rather than a
/// precise time-in-state breakdown.
public struct SessionConnectionQualitySummary: Sendable, Equatable {
    public let worst: RealtimeConnectionQuality
    public let updates: Int
    public let poorOrLostUpdates: Int

    public init(worst: RealtimeConnectionQuality, updates: Int, poorOrLostUpdates: Int) {
        self.worst = worst
        self.updates = updates
        self.poorOrLostUpdates = poorOrLostUpdates
    }
}

/// Server-side phase breakdown of `POST /session/start` (milliseconds),
/// echoed in the start response. Joined with the client connect phases in
/// the startup-waterfall event so each millisecond of connect latency is
/// attributable to client, network, or server.
public struct SessionStartServerTimings: Sendable, Equatable {
    public let versionCheckMs: Int
    public let projectCheckMs: Int
    public let providerResolveMs: Int
    public let dbInsertMs: Int
    public let mintTokensMs: Int
    public let dispatchMs: Int
    public let totalMs: Int
    /// The resolved flow's single resolution seam. ``nil`` from a backend
    /// that doesn't report it; phases a flow doesn't have report 0.
    public let resolveMs: Int?

    public init(
        versionCheckMs: Int,
        projectCheckMs: Int,
        providerResolveMs: Int,
        dbInsertMs: Int,
        mintTokensMs: Int,
        dispatchMs: Int,
        totalMs: Int,
        resolveMs: Int? = nil
    ) {
        self.versionCheckMs = versionCheckMs
        self.projectCheckMs = projectCheckMs
        self.providerResolveMs = providerResolveMs
        self.dbInsertMs = dbInsertMs
        self.mintTokensMs = mintTokensMs
        self.dispatchMs = dispatchMs
        self.totalMs = totalMs
        self.resolveMs = resolveMs
    }
}

/// Per-session WebRTC quality snapshot, aggregated from LiveKit's W3C
/// `getStats()` output plus our own connect-phase timings. Sink-agnostic:
/// the SDK builds it; consumers (e.g. the macOS app) decide where to report
/// it. Connect-phase fields are `nil` until ``connect()`` completes; sampled
/// metric summaries are `nil` when no stats arrived (very short or failed
/// sessions).
public struct SessionQoESnapshot: Sendable, Equatable {
    // Connect-phase breakdown (milliseconds). Mirrors the `ws_ms` /
    // `room_ms` / `mic_ms` / `total_ms` previously logged only to OSLog.
    public let wsMs: Double?
    public let roomMs: Double?
    public let micMs: Double?
    public let totalConnectMs: Double?

    /// Server-side session-start phases from the start response; `nil` on
    /// older backends.
    public let serverTimings: SessionStartServerTimings?

    // Sampled transport quality over the session lifetime (milliseconds).
    public let jitterMs: SessionQoEMetricSummary?
    public let roundTripMs: SessionQoEMetricSummary?
    public let jitterBufferMs: SessionQoEMetricSummary?

    // Screen-share send health, straight from LiveKit's outbound video
    // stats (nil when no screen-share happened). Encode time + quality
    // limitation are how WebRTC reports whether the encoder is struggling.
    public let screenShareFps: SessionQoEMetricSummary?
    public let screenShareEncodeMs: SessionQoEMetricSummary?
    public let screenShareCpuLimitedMs: Double?
    public let screenShareBandwidthLimitedMs: Double?

    // Reset-safe cumulative audio counters. `nil` = never observed (distinct
    // from an observed zero).
    public let packetsLost: Int64?
    public let concealmentEvents: UInt64?

    public let connectionQuality: SessionConnectionQualitySummary?

    /// Number of stat samples folded into the metric summaries.
    public let sampleCount: Int

    public init(
        wsMs: Double?,
        roomMs: Double?,
        micMs: Double?,
        totalConnectMs: Double?,
        serverTimings: SessionStartServerTimings? = nil,
        jitterMs: SessionQoEMetricSummary?,
        roundTripMs: SessionQoEMetricSummary?,
        jitterBufferMs: SessionQoEMetricSummary?,
        screenShareFps: SessionQoEMetricSummary?,
        screenShareEncodeMs: SessionQoEMetricSummary?,
        screenShareCpuLimitedMs: Double?,
        screenShareBandwidthLimitedMs: Double?,
        packetsLost: Int64?,
        concealmentEvents: UInt64?,
        connectionQuality: SessionConnectionQualitySummary?,
        sampleCount: Int
    ) {
        self.wsMs = wsMs
        self.roomMs = roomMs
        self.micMs = micMs
        self.totalConnectMs = totalConnectMs
        self.serverTimings = serverTimings
        self.jitterMs = jitterMs
        self.roundTripMs = roundTripMs
        self.jitterBufferMs = jitterBufferMs
        self.screenShareFps = screenShareFps
        self.screenShareEncodeMs = screenShareEncodeMs
        self.screenShareCpuLimitedMs = screenShareCpuLimitedMs
        self.screenShareBandwidthLimitedMs = screenShareBandwidthLimitedMs
        self.packetsLost = packetsLost
        self.concealmentEvents = concealmentEvents
        self.connectionQuality = connectionQuality
        self.sampleCount = sampleCount
    }
}

/// One reading pulled from a track's `statistics`. LiveKit-free so the
/// aggregator stays unit-testable without a live room. All fields optional
/// because any given track exposes only the relevant subset (inbound vs
/// remote-inbound). Cumulative fields carry WebRTC's monotonic counters;
/// the aggregator deltas them where a per-interval value is needed.
struct QoESample: Sendable, Equatable {
    // Inbound (remote agent audio).
    var jitterSeconds: Double?
    var roundTripTimeSeconds: Double?
    var jitterBufferDelaySeconds: Double?
    var jitterBufferEmittedCount: UInt64?
    var packetsLost: Int64?
    var concealmentEvents: UInt64?

    // Outbound video (our screen-share send). Populated only for the
    // screen-share track; LiveKit measures encode/quality so we don't.
    var outboundFramesPerSecond: Double?
    var totalEncodeTimeSeconds: Double?
    var framesEncoded: UInt?
    var qualityLimitedCpuSeconds: Double?
    var qualityLimitedBandwidthSeconds: Double?

    var isEmpty: Bool {
        jitterSeconds == nil
            && roundTripTimeSeconds == nil
            && jitterBufferDelaySeconds == nil
            && packetsLost == nil
            && concealmentEvents == nil
            && outboundFramesPerSecond == nil
            && totalEncodeTimeSeconds == nil
            && qualityLimitedCpuSeconds == nil
            && qualityLimitedBandwidthSeconds == nil
    }
}
