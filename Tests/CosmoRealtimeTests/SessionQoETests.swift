import CosmoRealtimeAPI
import Foundation
import LiveKit
import Testing
@testable import CosmoRealtime

/// QoE/stats surface on the new ``RealtimeSession``. The aggregator math
/// is covered by ``SessionQoEAggregatorTests``; these assert only the new
/// wiring — the transport's aggregator passes through to the session, the
/// server-timings payload maps field-by-field into the snapshot, and the
/// LiveKit connection-quality enum maps to the neutral type. Fully
/// offline: no LiveKit server, no real tracks.
@Suite("Session QoE/stats")
struct SessionQoETests {

    private func makeTransport() -> LiveKitSessionTransport {
        LiveKitSessionTransport(
            options: RealtimeSession.Options(
                apiKey: "test-key",
                baseURL: URL(string: "https://example.invalid")!
            )
        )
    }

    @Test("fresh session exposes an empty snapshot")
    func freshSnapshotIsEmpty() async {
        let session = RealtimeSession(transport: makeTransport())
        let snap = session.qoeSnapshot
        #expect(snap.sampleCount == 0)
        #expect(snap.wsMs == nil)
        #expect(snap.serverTimings == nil)
        #expect(snap.connectionQuality == nil)
        #expect(snap.packetsLost == nil)
    }

    @Test("session passes the transport's QoE snapshot through")
    func sessionForwardsSnapshot() async {
        let transport = makeTransport()
        let session = RealtimeSession(transport: transport)

        transport.qoe.setConnectPhases(wsMs: 12.5, roomMs: 300, micMs: 450, totalMs: 762.5)
        transport.qoe.record(QoESample(jitterSeconds: 0.02))
        transport.qoe.record(quality: .poor)

        let snap = session.qoeSnapshot
        #expect(snap.wsMs == 12.5)
        #expect(snap.roomMs == 300)
        #expect(snap.micMs == 450)
        #expect(snap.totalConnectMs == 762.5)
        #expect(snap.jitterMs?.avg == 20)
        #expect(snap.connectionQuality?.worst == .poor)
        #expect(snap.sampleCount == 1)
    }

    @Test("server-start timings map field-by-field into the snapshot")
    func serverTimingsMapping() {
        let wire = CosmoRealtimeAPI.Components.Schemas.RealtimeSessionStartTimings(
            dbInsertMs: 4,
            dispatchMs: 6,
            mintTokensMs: 5,
            projectCheckMs: 2,
            providerResolveMs: 3,
            totalMs: 7,
            versionCheckMs: 1
        )
        let mapped = LiveKitSessionTransport.serverTimings(from: wire)
        #expect(mapped.versionCheckMs == 1)
        #expect(mapped.projectCheckMs == 2)
        #expect(mapped.providerResolveMs == 3)
        #expect(mapped.dbInsertMs == 4)
        #expect(mapped.mintTokensMs == 5)
        #expect(mapped.dispatchMs == 6)
        #expect(mapped.totalMs == 7)
    }

    @Test("mapped server timings carry into the session snapshot")
    func serverTimingsCarryThroughSession() {
        let transport = makeTransport()
        let session = RealtimeSession(transport: transport)
        let wire = CosmoRealtimeAPI.Components.Schemas.RealtimeSessionStartTimings(
            dbInsertMs: 40,
            dispatchMs: 60,
            mintTokensMs: 50,
            projectCheckMs: 20,
            providerResolveMs: 30,
            totalMs: 200,
            versionCheckMs: 10
        )
        transport.qoe.setServerTimings(LiveKitSessionTransport.serverTimings(from: wire))

        let timings = session.qoeSnapshot.serverTimings
        #expect(timings?.versionCheckMs == 10)
        #expect(timings?.dispatchMs == 60)
        #expect(timings?.totalMs == 200)
    }

    @Test("LiveKit connection-quality enum maps to the neutral type")
    func connectionQualityMapping() {
        #expect(LiveKitSessionTransport.mapConnectionQuality(.unknown) == .unknown)
        #expect(LiveKitSessionTransport.mapConnectionQuality(.lost) == .lost)
        #expect(LiveKitSessionTransport.mapConnectionQuality(.poor) == .poor)
        #expect(LiveKitSessionTransport.mapConnectionQuality(.good) == .good)
        #expect(LiveKitSessionTransport.mapConnectionQuality(.excellent) == .excellent)
    }

    @Test("recordConnectionQuality folds into the snapshot via the session")
    func recordConnectionQualityFoldsIn() {
        let transport = makeTransport()
        let session = RealtimeSession(transport: transport)
        transport.recordConnectionQuality(.good)
        transport.recordConnectionQuality(.poor)
        transport.recordConnectionQuality(.excellent)

        let quality = session.qoeSnapshot.connectionQuality
        #expect(quality?.worst == .poor)
        #expect(quality?.updates == 3)
        #expect(quality?.poorOrLostUpdates == 1)
    }
}
