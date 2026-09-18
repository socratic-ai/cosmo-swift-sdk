import CosmoRealtimeAPI
import Foundation
import Testing

@testable import CosmoRealtime

/// The connect-timings report: one frame per session, sent once the client's
/// own connect phases and a readiness signal — the ``ready`` frame, the agent's
/// track going live, or the agent speaking — are both in hand.
@Suite("Connect-timings report")
struct SessionConnectTimingsSendTests {

    private static let readyFrame = Data(
        #"{"type":"ready","session_id":"0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"}"#.utf8
    )
    private static let botStartedSpeakingFrame = Data(#"{"type":"bot-started-speaking"}"#.utf8)

    private static let serverTimings = RealtimeSessionStartTimings(
        dbInsertMs: 41,
        dispatchMs: 12,
        mintTokensMs: 18,
        projectCheckMs: 0,
        providerResolveMs: 0,
        resolveMs: 25,
        totalMs: 96,
        versionCheckMs: 0
    )

    private func started(_ transport: FakeSessionTransport) async throws -> RealtimeSession {
        let session = RealtimeSession(transport: transport)
        try await session._start(config: SessionConfig(), rpcHandlers: [:])
        return session
    }

    private func reports(_ transport: FakeSessionTransport) async -> [ObservedEvent] {
        await transport.sent.map(observeSentFrame).filter { $0.type == "connect-timings" }
    }

    /// The report is published from a detached task, so poll for it rather
    /// than reading straight after the frame that triggers it.
    private func awaitReport(_ transport: FakeSessionTransport) async -> [ObservedEvent] {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let found = await reports(transport)
            if !found.isEmpty { return found }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await reports(transport)
    }

    /// Long enough for a report that was going to be sent to have been sent.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    @Test("the report rounds the client phases and echoes the server breakdown verbatim")
    func reportShape() async throws {
        let transport = FakeSessionTransport()
        await transport.setStartResponse(
            RealtimeSessionResponse(
                livekitUrl: "ws://fake.invalid",
                roomName: "room-1",
                sessionId: "session-1",
                timings: .init(Self.serverTimings),
                token: "token-1"
            )
        )
        let session = try await started(transport)
        transport.timings.setHandshakeStart(Date().addingTimeInterval(-1.18))
        transport.timings.setConnectPhases(wsMs: 210.4, roomMs: 430.6, micMs: 54.5, totalMs: 700)
        await transport.inject(Self.readyFrame)

        let found = await awaitReport(transport)
        #expect(found.count == 1)
        let report = try #require(found.first)
        #expect(report.fields["request_ms"] == .int(210))
        #expect(report.fields["room_ms"] == .int(431))
        #expect(report.fields["mic_ms"] == .int(55))
        // Measured against the handshake origin, not the frame's own arrival.
        guard case .int(let readyMs)? = report.fields["ready_ms"] else {
            Issue.record("no ready_ms on the report")
            return
        }
        #expect(readyMs >= 1180)
        #expect(readyMs < 1500)
        #expect(report.fields["server"] == .object([
            "db_insert_ms": .int(41),
            "dispatch_ms": .int(12),
            "mint_tokens_ms": .int(18),
            "project_check_ms": .int(0),
            "provider_resolve_ms": .int(0),
            "resolve_ms": .int(25),
            "total_ms": .int(96),
            "version_check_ms": .int(0),
        ]))
        #expect(
            Set(report.fields.keys)
                == ["type", "request_ms", "room_ms", "mic_ms", "ready_ms", "server"]
        )
        await session.close()
    }

    @Test("a phase the client never measured is left off the report")
    func absentPhasesAreOmitted() async throws {
        let transport = FakeSessionTransport()
        let session = try await started(transport)
        transport.timings.setConnectPhases(wsMs: 210, roomMs: 430, micMs: 0, totalMs: 700)
        await transport.inject(Self.readyFrame)

        let report = try #require(await awaitReport(transport).first)
        // No start response carried a server breakdown, so nothing to echo.
        #expect(report.fields["server"] == nil)
        #expect(report.fields["mic_ms"] == .int(0))
        await session.close()
    }

    @Test("no report while nothing has shown the agent to be live")
    func noReportWithoutReadiness() async throws {
        let transport = FakeSessionTransport()
        let session = try await started(transport)
        transport.timings.setConnectPhases(wsMs: 210, roomMs: 430, micMs: 55, totalMs: 700)

        await settle()
        #expect(await reports(transport).isEmpty)
        await session.close()
    }

    @Test("the agent's track going live releases the report, without ready_ms")
    func agentTrackReleasesTheReport() async throws {
        // ``ready`` is a one-shot data frame a prepared-room session can miss.
        // The track signal is the race-free seam, so the phases still land.
        let transport = FakeSessionTransport()
        let session = try await started(transport)
        transport.timings.setConnectPhases(wsMs: 210, roomMs: 430, micMs: 55, totalMs: 700)
        await transport.signalAgentLive()

        let report = try #require(await awaitReport(transport).first)
        #expect(report.fields["ready_ms"] == nil)
        #expect(report.fields["request_ms"] == .int(210))
        #expect(Set(report.fields.keys) == ["type", "request_ms", "room_ms", "mic_ms"])
        await session.close()
    }

    @Test("a speaking event releases it too, and a late ready adds no second one")
    func speakingReleasesTheReportOnce() async throws {
        let transport = FakeSessionTransport()
        let session = try await started(transport)
        transport.timings.setConnectPhases(wsMs: 210, roomMs: 430, micMs: 55, totalMs: 700)
        await transport.inject(Self.botStartedSpeakingFrame)

        let report = try #require(await awaitReport(transport).first)
        #expect(report.fields["ready_ms"] == nil)

        await transport.inject(Self.readyFrame)
        await settle()
        #expect(await reports(transport).count == 1)
        // The breakdown still takes the mark — only the report has closed.
        #expect(session.connectTimings.readyMs != nil)
        await session.close()
    }

    @Test("no half report when the connect phases are missing")
    func noReportWithoutConnectPhases() async throws {
        let transport = FakeSessionTransport()
        let session = try await started(transport)
        await transport.inject(Self.readyFrame)

        await settle()
        #expect(await reports(transport).isEmpty)
        await session.close()
    }

    @Test("a ready that beats the phases onto the recorder still reports, once")
    func readyAheadOfConnectPhases() async throws {
        let transport = FakeSessionTransport()
        // Delivered from inside connect, before the phases are recorded: the
        // report has to wait for the second half rather than go out partial.
        await transport.scriptFrameDuringConnect(Self.readyFrame)
        await transport.scriptConnectPhases(ws: 210, room: 430, mic: 55, total: 700)
        let session = try await started(transport)

        let found = await awaitReport(transport)
        #expect(found.count == 1)
        #expect(found.first?.fields["request_ms"] == .int(210))
        await session.close()
    }

    @Test("one report per session, however many ready frames arrive")
    func reportedOnce() async throws {
        let transport = FakeSessionTransport()
        let session = try await started(transport)
        transport.timings.setConnectPhases(wsMs: 210, roomMs: 430, micMs: 55, totalMs: 700)
        await transport.inject(Self.readyFrame)
        _ = await awaitReport(transport)
        await transport.inject(Self.readyFrame)
        await transport.inject(Self.readyFrame)

        await settle()
        #expect(await reports(transport).count == 1)
        await session.close()
    }

    @Test("a refused send is swallowed, and the session keeps running")
    func sendFailureIsSwallowed() async throws {
        let transport = FakeSessionTransport()
        let session = try await started(transport)
        transport.timings.setConnectPhases(wsMs: 210, roomMs: 430, micMs: 55, totalMs: 700)
        await transport.scriptSendError(SessionStateError(code: .notConnected, message: "RealtimeSession is not connected."))
        await transport.inject(Self.readyFrame)

        await settle()
        #expect(await reports(transport).isEmpty)
        // The refused report is not retried, and nothing about it is terminal.
        try await session.send(text: "still alive")
        let texts = await transport.sent.map(observeSentFrame).filter { $0.type == "send-text" }
        #expect(texts.count == 1)
        await session.close()
    }
}
