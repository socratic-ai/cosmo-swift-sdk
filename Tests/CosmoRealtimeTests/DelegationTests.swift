import Foundation
import Testing
@testable import CosmoRealtime
import CosmoRealtimeAPI

/// Client delegation: the ``delegation-created`` hand-off event and the
/// ``delegation-append`` replies.
@Suite struct DelegationTests {

    private static let createdFrame = Data("""
        {"type":"delegation-created","delegation_id":"dlg-1","transcript":"book me a table"}
        """.utf8)

    @Test("a delegation-created frame surfaces as .delegationCreated")
    func createdFrameDecodes() async throws {
        let transport = FakeSessionTransport()
        let session = RealtimeSession(transport: transport)
        try await session._start(config: SessionConfig(instructions: "hi"))

        let consumer = Task { () -> DelegationCreatedEvent? in
            for try await event in session.events {
                if case .delegationCreated(let payload) = event { return payload }
            }
            return nil
        }
        await session._receiveFrame(Self.createdFrame)
        let payload = try await consumer.value
        await session.end()

        let created = try #require(payload)
        #expect(created.delegationId == "dlg-1")
        #expect(created.transcript == "book me a table")
    }

    @Test("appendCommentary sends a delegation-append frame on the commentary channel")
    func appendCommentaryOnTheWire() async throws {
        let transport = FakeSessionTransport()
        let session = RealtimeSession(transport: transport)
        try await session._start(config: SessionConfig(instructions: "hi"))

        try await session.appendCommentary("Table for two at seven is booked.", delegationId: "dlg-1")
        await session.end()

        let frames = await transport.sent.map(observeSentFrame).filter { $0.type == "delegation-append" }
        let frame = try #require(frames.first)
        #expect(frame.fields["channel"] == .string("commentary"))
        #expect(frame.fields["content"] == .string("Table for two at seven is booked."))
        #expect(frame.fields["delegation_id"] == .string("dlg-1"))
    }

    @Test("appendInstructions without a delegation id omits the field")
    func appendWithoutDelegationId() async throws {
        let transport = FakeSessionTransport()
        let session = RealtimeSession(transport: transport)
        try await session._start(config: SessionConfig(instructions: "hi"))

        try await session.appendInstructions("Keep answers short.")
        await session.end()

        let frames = await transport.sent.map(observeSentFrame).filter { $0.type == "delegation-append" }
        let frame = try #require(frames.first)
        #expect(frame.fields["channel"] == .string("instructions"))
        #expect(frame.fields["delegation_id"] == nil)
    }

    @Test("delegation reaches the openai_live wire block")
    func delegationOnTheWire() throws {
        let config = SessionConfig(
            model: .openaiLive(OpenAILiveModel(delegation: .client)),
            instructions: "hi"
        )
        let payload = try config.wirePayload()
        guard case .inline(let inline)? = payload.agent else {
            Issue.record("expected an inline agent block")
            return
        }
        guard case .openaiLive(let model)? = inline.model?.value2 else {
            Issue.record("expected an openai_live model block")
            return
        }
        #expect(model.delegation == CosmoRealtimeAPI.Components.Schemas.OpenAILiveDelegation.client)
    }
}
