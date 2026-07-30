import Testing
@testable import CosmoRealtime

@Suite struct SessionQoEAggregatorTests {
    private func jitterSample(_ seconds: Double) -> QoESample {
        QoESample(jitterSeconds: seconds)
    }

    @Test func emptyAggregatorHasNoSummariesOrQuality() {
        let agg = SessionQoEAggregator()
        let snap = agg.snapshot()
        #expect(snap.sampleCount == 0)
        #expect(snap.jitterMs == nil)
        #expect(snap.roundTripMs == nil)
        #expect(snap.jitterBufferMs == nil)
        #expect(snap.connectionQuality == nil)
        #expect(snap.wsMs == nil)
        // Never observed → nil (distinct from a measured zero).
        #expect(snap.packetsLost == nil)
        #expect(snap.concealmentEvents == nil)
        #expect(snap.screenShareFps == nil)
    }

    @Test func connectPhasesCarryIntoSnapshot() {
        let agg = SessionQoEAggregator()
        agg.setConnectPhases(wsMs: 12.5, roomMs: 300, micMs: 450, totalMs: 762.5)
        let snap = agg.snapshot()
        #expect(snap.wsMs == 12.5)
        #expect(snap.roomMs == 300)
        #expect(snap.micMs == 450)
        #expect(snap.totalConnectMs == 762.5)
    }

    @Test func emptySampleIsIgnored() {
        let agg = SessionQoEAggregator()
        agg.record(QoESample())
        #expect(agg.snapshot().sampleCount == 0)
    }

    @Test func jitterPercentilesUseNearestRank() {
        let agg = SessionQoEAggregator()
        // 10 values: 10ms … 100ms (feed out of order to exercise sorting).
        for ms in [50.0, 10, 90, 30, 70, 20, 100, 40, 80, 60] {
            agg.record(jitterSample(ms / 1000))
        }
        let summary = agg.snapshot().jitterMs
        #expect(summary?.count == 10)
        #expect(summary?.min == 10)
        #expect(summary?.max == 100)
        #expect(summary?.avg == 55)
        #expect(summary?.p50 == 50)   // ceil(0.50*10)=5 → sorted[4]
        #expect(summary?.p95 == 100)  // ceil(0.95*10)=10 → sorted[9]
        #expect(agg.snapshot().sampleCount == 10)
    }

    @Test func cumulativeCountersSumDeltasMonotonic() {
        let agg = SessionQoEAggregator()
        // Monotonic growth: total == final cumulative value (first reading is
        // growth from 0, then positive deltas).
        agg.record(QoESample(packetsLost: 5))
        agg.record(QoESample(packetsLost: 8))
        agg.record(QoESample(packetsLost: 12))
        #expect(agg.snapshot().packetsLost == 12)
    }

    @Test func cumulativeCountersSurviveReset() {
        let agg = SessionQoEAggregator()
        // A reconnect resets the WebRTC counter; the post-reset value is the
        // increment since the reset, so the session total must keep climbing.
        agg.record(QoESample(packetsLost: 5))   // 0 → 5
        agg.record(QoESample(packetsLost: 9))   // +4 → 9
        agg.record(QoESample(packetsLost: 2))   // reset, +2 → 11
        agg.record(QoESample(packetsLost: 3))   // +1 → 12
        #expect(agg.snapshot().packetsLost == 12)
    }

    @Test func screenShareOutboundStatsFromLiveKit() {
        let agg = SessionQoEAggregator()
        // Two readings of LiveKit's outbound video stats.
        agg.record(QoESample(outboundFramesPerSecond: 30,
                             totalEncodeTimeSeconds: 1.0, framesEncoded: 100,
                             qualityLimitedCpuSeconds: 2.0))
        agg.record(QoESample(outboundFramesPerSecond: 30,
                             totalEncodeTimeSeconds: 1.5, framesEncoded: 150,
                             qualityLimitedCpuSeconds: 2.0))
        let snap = agg.snapshot()
        #expect(snap.screenShareFps?.avg == 30)
        // Δencode 0.5s over Δframes 50 = 0.01s → 10ms avg encode.
        #expect(snap.screenShareEncodeMs?.avg == 10)
        #expect(snap.screenShareCpuLimitedMs == 2000)          // 2.0s cumulative
        #expect(snap.screenShareBandwidthLimitedMs == nil)     // never observed
    }

    @Test func audioOnlySessionHasNoScreenShareStats() {
        let agg = SessionQoEAggregator()
        agg.record(QoESample(jitterSeconds: 0.01, packetsLost: 1))
        let snap = agg.snapshot()
        #expect(snap.screenShareFps == nil)
        #expect(snap.screenShareEncodeMs == nil)
        #expect(snap.screenShareCpuLimitedMs == nil)
    }

    @Test func counterPresenceIsPerMetric() {
        let agg = SessionQoEAggregator()
        // Packet loss present, concealment never observed → only the observed
        // counter is reported; the other stays nil, not 0.
        agg.record(QoESample(jitterSeconds: 0.01, packetsLost: 4))
        let snap = agg.snapshot()
        #expect(snap.packetsLost == 4)
        #expect(snap.concealmentEvents == nil)
    }

    @Test func jitterBufferDelayIsAveragedPerInterval() {
        let agg = SessionQoEAggregator()
        // First sample only establishes the cumulative baseline.
        agg.record(QoESample(jitterBufferDelaySeconds: 1.0, jitterBufferEmittedCount: 100))
        #expect(agg.snapshot().jitterBufferMs == nil)
        // Δdelay=0.5s over Δemitted=50 → 0.01s avg → 10ms.
        agg.record(QoESample(jitterBufferDelaySeconds: 1.5, jitterBufferEmittedCount: 150))
        let summary = agg.snapshot().jitterBufferMs
        #expect(summary?.count == 1)
        #expect(summary?.avg == 10)
    }

    @Test func roundTripTimeSummarized() {
        let agg = SessionQoEAggregator()
        agg.record(QoESample(roundTripTimeSeconds: 0.040))
        agg.record(QoESample(roundTripTimeSeconds: 0.060))
        let summary = agg.snapshot().roundTripMs
        #expect(summary?.min == 40)
        #expect(summary?.max == 60)
        #expect(summary?.avg == 50)
    }

    @Test func connectionQualityTracksWorstAndDegradedCount() {
        let agg = SessionQoEAggregator()
        agg.record(quality: .good)
        agg.record(quality: .poor)
        agg.record(quality: .excellent)
        var snap = agg.snapshot().connectionQuality
        #expect(snap?.worst == .poor)
        #expect(snap?.updates == 3)
        #expect(snap?.poorOrLostUpdates == 1)

        agg.record(quality: .lost)
        snap = agg.snapshot().connectionQuality
        #expect(snap?.worst == .lost)
        #expect(snap?.updates == 4)
        #expect(snap?.poorOrLostUpdates == 2)
    }

    @Test func unknownDoesNotDominateWorst() {
        let agg = SessionQoEAggregator()
        agg.record(quality: .good)
        agg.record(quality: .unknown)
        // unknown ranks above lost/poor, so a transient unknown after a
        // good session does not become the "worst".
        #expect(agg.snapshot().connectionQuality?.worst == .good)
    }
}
