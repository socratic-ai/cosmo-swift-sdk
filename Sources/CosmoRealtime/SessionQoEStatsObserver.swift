import Foundation
import LiveKit
import os

/// Bridges LiveKit's per-track `TrackDelegate.didUpdateStatistics` (fired
/// ~1 Hz once ``Track/set(reportStatistics:)`` is enabled) into the
/// LiveKit-free ``SessionQoEAggregator``. One instance is registered on both
/// the local mic track (for outbound → ``remoteInboundRtpStream`` RTT) and
/// the remote agent-audio track (for ``inboundRtpStream`` jitter / loss /
/// jitter-buffer / concealment). A given track populates only the relevant
/// arm, so extracting both and recording nils-where-absent is correct.
///
/// LiveKit's `MulticastDelegate` holds delegates weakly, so the owning
/// transport must retain this observer.
final class SessionQoEStatsObserver: TrackDelegate, @unchecked Sendable {
    private static let log = Logger(subsystem: CosmoRealtimeLog.subsystem, category: "qoe-video")
    private let aggregator: SessionQoEAggregator

    init(aggregator: SessionQoEAggregator) {
        self.aggregator = aggregator
    }

    func track(
        _ track: Track,
        didUpdateStatistics statistics: TrackStatistics,
        simulcastStatistics: [VideoCodec: TrackStatistics]
    ) {
        // Dual-codec publishes (H.264 primary + VP8 backup) report the backup
        // sender here, not in `statistics` — surface it or it hides entirely.
        for (codec, stats) in simulcastStatistics {
            if let outbound = stats.outboundRtpStream.first(where: { $0.kind == "video" }) {
                Self.log.info("outbound video [backup \(codec.name, privacy: .public)] \(outbound.frameWidth ?? 0, privacy: .public)x\(outbound.frameHeight ?? 0, privacy: .public) qlim=\(outbound.qualityLimitationReason.map(String.init(describing:)) ?? "none", privacy: .public) target_bps=\(outbound.targetBitrate ?? 0, privacy: .public)")
            }
        }
        var sample = QoESample()
        // Inbound audio = the remote agent's voice.
        if let inbound = statistics.inboundRtpStream.first(where: { $0.kind == "audio" }) {
            sample.jitterSeconds = inbound.jitter
            sample.packetsLost = inbound.packetsLost
            sample.jitterBufferDelaySeconds = inbound.jitterBufferDelay
            sample.jitterBufferEmittedCount = inbound.jitterBufferEmittedCount
            sample.concealmentEvents = inbound.concealmentEvents
        }
        if let remoteInbound = statistics.remoteInboundRtpStream.first {
            sample.roundTripTimeSeconds = remoteInbound.roundTripTime
        }
        // Outbound video = our screen-share send (encode/fps/quality-limit).
        if let outbound = statistics.outboundRtpStream.first(where: { $0.kind == "video" }) {
            sample.outboundFramesPerSecond = outbound.framesPerSecond
            sample.totalEncodeTimeSeconds = outbound.totalEncodeTime
            sample.framesEncoded = outbound.framesEncoded
            sample.qualityLimitedCpuSeconds = outbound.qualityLimitationDurations?.cpu
            sample.qualityLimitedBandwidthSeconds = outbound.qualityLimitationDurations?.bandwidth
            Self.log.info("outbound video \(outbound.frameWidth ?? 0, privacy: .public)x\(outbound.frameHeight ?? 0, privacy: .public) qlim=\(outbound.qualityLimitationReason.map(String.init(describing:)) ?? "none", privacy: .public) target_bps=\(outbound.targetBitrate ?? 0, privacy: .public)")
        }
        aggregator.record(sample)
    }
}
