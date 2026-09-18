import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

@testable import CosmoRealtime

/// The REST payloads that carry a server-authored enum survive a value this
/// package does not name.
///
/// These two calls read their body themselves rather than through the
/// generated client, whose `Components.Schemas` enums are `@frozen` and throw
/// on an unrecognized value — losing the whole response over one field the
/// caller may never read. Decoding through the SDK's own types is what makes
/// the `unknown` case reachable, so it is pinned end to end here rather than
/// on the type alone.
@Suite("REST enum tolerance")
struct RestEnumToleranceTests {

    @Test("an unrecognized session status keeps the rest of the usage summary")
    func unknownSessionStatus() async throws {
        let body = #"""
        {"status":"cancelled","usage_status":"estimating","duration_seconds":42.0,
         "turn_count":3,"user_speaking_seconds":null,"agent_speaking_seconds":null,
         "provider":"gemini","model":"some-model",
         "tokens":{"input_tokens":10,"output_tokens":5,"total_tokens":15}}
        """#
        let transport = StubTransport { jsonResponse(.ok, body) }
        let usage = try await makeStubClient(transport).sessionUsage(sessionId: "sess-1")

        #expect(usage.status == .unknown("cancelled"))
        #expect(usage.usageStatus == .unknown("estimating"))
        // The counters the caller asked for come back either way — the point
        // of tolerating the status rather than failing the response.
        #expect(usage.durationSeconds == 42.0)
        #expect(usage.turnCount == 3)
        #expect(usage.tokens?.totalTokens == 15)
    }

    @Test("a recognized status still decodes to its own case")
    func knownSessionStatus() async throws {
        let body = #"""
        {"status":"completed","usage_status":"recorded","duration_seconds":1.0,
         "turn_count":1,"user_speaking_seconds":null,"agent_speaking_seconds":null,
         "provider":null,"model":null,"tokens":null}
        """#
        let transport = StubTransport { jsonResponse(.ok, body) }
        let usage = try await makeStubClient(transport).sessionUsage(sessionId: "sess-1")
        #expect(usage.status == .completed)
        #expect(usage.usageStatus == .recorded)
    }

    @Test("an unrecognized credential kind keeps the scopes and capability flags")
    func unknownCredentialKind() async throws {
        let body = #"""
        {"credential":"service_account","scopes":["realtime:use"],
         "can_start_sessions":true,"realtime_voice_available":true}
        """#
        let transport = StubTransport { jsonResponse(.ok, body) }
        let info = try await makeStubClient(transport).verify()

        #expect(info.credential == .unknown("service_account"))
        #expect(info.scopes == ["realtime:use"])
        #expect(info.canStartSessions)
        #expect(info.realtimeVoiceAvailable)
    }

    @Test("a recognized credential kind still decodes to its own case")
    func knownCredentialKind() async throws {
        let body = #"""
        {"credential":"api_key","scopes":[],
         "can_start_sessions":true,"realtime_voice_available":true}
        """#
        let transport = StubTransport { jsonResponse(.ok, body) }
        #expect(try await makeStubClient(transport).verify().credential == .apiKey)
    }
}
