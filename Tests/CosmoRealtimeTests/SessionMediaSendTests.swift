import Foundation
import Testing
@testable import CosmoRealtime

@Suite("RealtimeSession media sends")
struct SessionMediaSendTests {

    private func startedSession() async throws -> (RealtimeSession, FakeSessionTransport) {
        let transport = FakeSessionTransport()
        let session = RealtimeSession(transport: transport)
        try await session._start(config: SessionConfig())
        return (session, transport)
    }

    /// The frames the session handed the transport, minus the leading
    /// ``session-config`` start payload and the ``bind-input`` frame the
    /// session emits on start (this client is the voice), normalized to the
    /// trace vocabulary (wire ``type`` + JSON fields).
    private func sentSends(_ transport: FakeSessionTransport) async -> [ObservedEvent] {
        await transport.sent
            .dropFirst()
            .map(observeSentFrame)
            .filter { $0.type != "bind-input" }
    }

    @Test("start() binds the agent input as the voice")
    func startBindsInput() async throws {
        let (_, transport) = try await startedSession()
        // After the leading session-config, the session binds the agent's
        // input so it listens to this client.
        let frames = await transport.sent.dropFirst().map(observeSentFrame)
        let bind = try #require(frames.first { $0.type == "bind-input" })
        #expect(Set(bind.fields.keys) == ["type"])
    }

    @Test("send(image:) records send-image with documented defaults")
    func sendImageDefaults() async throws {
        let (session, transport) = try await startedSession()
        try await session.send(image: "YWJj")

        let sends = await sentSends(transport)
        #expect(sends.count == 1)
        let frame = try #require(sends.first)
        #expect(frame.type == "send-image")
        #expect(frame.fields["data"] == .string("YWJj"))
        #expect(frame.fields["mime_type"] == .string("image/jpeg"))
        #expect(frame.fields["stream_id"] == .string("video.input.default"))
    }

    @Test("send(image:) carries explicit mime type and stream id")
    func sendImageExplicit() async throws {
        let (session, transport) = try await startedSession()
        try await session.send(image: "ZGVm", mimeType: "image/png", streamId: "video.input.screen")

        let frame = try #require(await sentSends(transport).first)
        #expect(frame.type == "send-image")
        #expect(frame.fields["data"] == .string("ZGVm"))
        #expect(frame.fields["mime_type"] == .string("image/png"))
        #expect(frame.fields["stream_id"] == .string("video.input.screen"))
    }

    @Test("send(bytes:topic:) streams the payload to the transport on the topic")
    func sendBytes() async throws {
        let (session, transport) = try await startedSession()
        let payload = Data("grounding".utf8)
        try await session.send(bytes: payload, topic: "grounding.capture")

        let streamed = await transport.sentBytes
        #expect(streamed.count == 1)
        #expect(streamed.first?.data == payload)
        #expect(streamed.first?.topic == "grounding.capture")
    }

    @Test("send(bytes:) throws notConnected before start")
    func sendBytesRejectsBeforeStart() async {
        let session = RealtimeSession(transport: FakeSessionTransport())
        await #expect(throws: RealtimeSessionError.notConnected) {
            try await session.send(bytes: Data("x".utf8), topic: "t")
        }
    }

    @Test("sendActivityEnd() records a bare activity-end frame")
    func activityEnd() async throws {
        let (session, transport) = try await startedSession()
        try await session.sendActivityEnd()

        let sends = await sentSends(transport)
        #expect(sends.count == 1)
        let frame = try #require(sends.first)
        #expect(frame.type == "activity-end")
        // activity-end carries only the discriminator.
        #expect(Set(frame.fields.keys) == ["type"])
    }

    @Test("media sends throw notConnected before start")
    func mediaSendsRejectBeforeStart() async {
        let session = RealtimeSession(transport: FakeSessionTransport())
        await #expect(throws: RealtimeSessionError.notConnected) {
            try await session.send(image: "YWJj")
        }
        await #expect(throws: RealtimeSessionError.notConnected) {
            try await session.sendActivityEnd()
        }
    }

    @Test("media sends throw notConnected after end")
    func mediaSendsRejectAfterEnd() async throws {
        let (session, _) = try await startedSession()
        await session.end()
        await #expect(throws: RealtimeSessionError.notConnected) {
            try await session.send(image: "YWJj")
        }
        await #expect(throws: RealtimeSessionError.notConnected) {
            try await session.sendActivityEnd()
        }
    }
}
