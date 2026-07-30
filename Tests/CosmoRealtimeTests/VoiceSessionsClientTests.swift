import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import CosmoRealtime

@Suite("Voice sessions client")
struct VoiceSessionsClientTests {


    @Test("list decodes the wire snake_case fields into the generated summaries")
    func listDecodesSummaries() async throws {
        let body = #"""
        [{"id":"9c3a62fe-1111-4222-8333-444455556666","started_at":1751900000.5,
          "ended_at":1751900100.5,"status":"completed","provider":"gemini",
          "has_resumption_handle":true},
         {"id":"9c3a62fe-7777-4888-9999-000011112222","started_at":1751910000.0,
          "status":"active","has_resumption_handle":false}]
        """#
        let transport = StubTransport { jsonResponse(.ok, body) }
        let sessions = try await makeStubClient(transport).listVoiceSessions(limit: 20)
        #expect(sessions.count == 2)
        #expect(sessions[0].id == "9c3a62fe-1111-4222-8333-444455556666")
        #expect(sessions[0].startedAt == 1751900000.5)
        #expect(sessions[0].endedAt == 1751900100.5)
        #expect(sessions[0].status == .completed)
        #expect(sessions[0].hasResumptionHandle == true)
        #expect(sessions[1].endedAt == nil)
        #expect(sessions[1].status == .active)
    }

    @Test("a single session fetch decodes the summary")
    func singleSessionDecodes() async throws {
        let body = #"""
        {"id":"9c3a62fe-1111-4222-8333-444455556666","started_at":1751900000.5,
         "ended_at":1751900100.5,"status":"completed","provider":"gemini",
         "has_resumption_handle":true}
        """#
        let transport = StubTransport { jsonResponse(.ok, body) }
        let session = try await makeStubClient(transport).voiceSession(
            sessionId: "9c3a62fe-1111-4222-8333-444455556666"
        )
        #expect(session.id == "9c3a62fe-1111-4222-8333-444455556666")
        #expect(session.startedAt == 1751900000.5)
        #expect(session.status == .completed)
        #expect(session.hasResumptionHandle == true)
    }

    @Test("a single session fetch maps 404 to VoiceSessionsError.notFound")
    func singleSessionMapsNotFound() async throws {
        let transport = StubTransport {
            jsonResponse(.notFound, #"{"detail":"voice session not found"}"#)
        }
        await #expect {
            _ = try await makeStubClient(transport).voiceSession(
                sessionId: "9c3a62fe-1111-4222-8333-444455556666"
            )
        } throws: { error in
            error as? VoiceSessionsError == .notFound
        }
    }

    @Test("capabilities decodes the wire snake_case key")
    func capabilitiesDecodesSnakeCaseKey() async throws {
        // Regression: the retired hand-written client expected a camelCase
        // ``openaiProviderAvailable`` wire key and silently failed on the
        // backend's actual snake_case serialization.
        let transport = StubTransport {
            jsonResponse(.ok, #"{"openai_provider_available":true}"#)
        }
        let capabilities = try await makeStubClient(transport).realtimeCapabilities()
        #expect(capabilities.openaiProviderAvailable == true)
    }

    @Test("transcript decodes turns with typed roles")
    func transcriptDecodesTurns() async throws {
        let body = #"""
        [{"ts":12.5,"role":"user","text":"hello"},
         {"ts":14.0,"role":"assistant","text":"hi there"}]
        """#
        let transport = StubTransport { jsonResponse(.ok, body) }
        let turns = try await makeStubClient(transport).voiceSessionTranscript(
            sessionId: "9c3a62fe-1111-4222-8333-444455556666"
        )
        #expect(turns.count == 2)
        #expect(turns[0].role == .user)
        #expect(turns[0].text == "hello")
        #expect(turns[1].role == .assistant)
        #expect(turns[0].id != turns[1].id)
    }

    @Test("delete treats 204 as success")
    func deleteSucceedsOnNoContent() async throws {
        let transport = StubTransport { (HTTPResponse(status: .noContent), nil) }
        try await makeStubClient(transport).deleteVoiceSession(
            sessionId: "9c3a62fe-1111-4222-8333-444455556666"
        )
    }

    @Test("delete maps 404 to VoiceSessionsError.notFound")
    func deleteMapsNotFound() async {
        let transport = StubTransport {
            jsonResponse(.notFound, #"{"detail":"voice session not found"}"#)
        }
        await #expect {
            try await makeStubClient(transport).deleteVoiceSession(
                sessionId: "9c3a62fe-1111-4222-8333-444455556666"
            )
        } throws: { error in
            error as? VoiceSessionsError == .notFound
        }
    }

    @Test("an undocumented 4xx maps to .rejected with the status and body")
    func undocumentedRejectionMapsToRejected() async {
        let transport = StubTransport {
            jsonResponse(.forbidden, #"{"detail":{"code":"forbidden","message":"missing scope"}}"#)
        }
        await #expect {
            _ = try await makeStubClient(transport).listVoiceSessions()
        } throws: { error in
            guard case .rejected(let code, let detail) = error as? VoiceSessionsError else {
                return false
            }
            return code == "forbidden" && detail.contains("missing scope")
        }
    }

    @Test("a 200 with an undecodable body maps to .invalidResponse")
    func undecodableSuccessBodyMapsToInvalidResponse() async {
        let transport = StubTransport { jsonResponse(.ok, "not json at all") }
        await #expect {
            _ = try await makeStubClient(transport).listVoiceSessions()
        } throws: { error in
            guard case .invalidResponse(let message) = error as? VoiceSessionsError else {
                return false
            }
            return !message.isEmpty
        }
    }

    @Test("a transport throw maps to .transport")
    func transportThrowMapsToTransport() async {
        let transport = StubTransport { throw StubError() }
        await #expect {
            _ = try await makeStubClient(transport).realtimeCapabilities()
        } throws: { error in
            guard case .transport(let message) = error as? VoiceSessionsError else {
                return false
            }
            return !message.isEmpty
        }
    }
}
