import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

@testable import CosmoRealtime

/// The two calls that read their body themselves still send the request a
/// generated call sends.
///
/// They bypass the generated `Client`, and middlewares belong to it, so
/// everything `BearerAuthMiddleware` adds has to be added at the call site —
/// where it can be forgotten. It was: the first version of this path carried
/// the bearer token and dropped the SDK identity, leaving these two the only
/// REST calls in any Cosmo SDK the server could not attribute to an SDK
/// version. Nothing failed, because tolerance tests read the response and
/// never looked at the request.
@Suite("Hand-decoded REST requests")
struct HandDecodedRequestTests {

    private static let okUsage = #"""
    {"status":"completed","usage_status":"recorded","duration_seconds":1.0,
     "turn_count":1,"user_speaking_seconds":null,"agent_speaking_seconds":null,
     "provider":null,"model":null,"tokens":null}
    """#

    private static let okVerify = #"""
    {"credential":"api_key","scopes":[],
     "can_start_sessions":true,"realtime_voice_available":true}
    """#

    private func captureRequest(
        responding body: String,
        _ call: (RealtimeClient) async throws -> Void
    ) async throws -> HTTPRequest {
        let captured = Captured()
        let transport = StubTransport(onRequest: { captured.store($0) }) {
            jsonResponse(.ok, body)
        }
        try await call(makeStubClient(transport))
        return try #require(captured.value)
    }

    private final class Captured: @unchecked Sendable {
        private let lock = NSLock()
        private var request: HTTPRequest?
        func store(_ request: HTTPRequest) {
            lock.withLock { self.request = request }
        }
        var value: HTTPRequest? { lock.withLock { request } }
    }

    @Test("the usage read is attributable to this SDK and version")
    func usageCarriesSdkIdentity() async throws {
        let request = try await captureRequest(responding: Self.okUsage) {
            _ = try await $0.sessionUsage(sessionId: "sess-1")
        }

        #expect(
            request.headerFields[BearerAuthMiddleware.sdkHeaderField]
                == sdkIdentityHeaderValue
        )
        #expect(request.headerFields[.authorization] == "Bearer sk-test")
        #expect(request.method == .get)
        #expect(request.path == "/api/v1/external/sessions/sess-1/usage")
    }

    @Test("the credential preflight is attributable to this SDK and version")
    func verifyCarriesSdkIdentity() async throws {
        let request = try await captureRequest(responding: Self.okVerify) {
            _ = try await $0.verify()
        }

        #expect(
            request.headerFields[BearerAuthMiddleware.sdkHeaderField]
                == sdkIdentityHeaderValue
        )
        #expect(request.headerFields[.authorization] == "Bearer sk-test")
        #expect(request.method == .get)
        #expect(request.path == "/api/v1/external/realtime/verify")
    }

    @Test("a token-source credential is resolved for the hand-decoded call")
    func tokenSourceResolvesPerCall() async throws {
        let source = TokenSource.custom {
            MintedToken(jwt: "fetched-jwt", expiresAt: Date().addingTimeInterval(3600))
        }
        let captured = Captured()
        let transport = StubTransport(onRequest: { captured.store($0) }) {
            jsonResponse(.ok, Self.okVerify)
        }
        _ = try await makeStubClient(transport, credential: .tokenSource(source)).verify()

        let request = try #require(captured.value)
        #expect(request.headerFields[.authorization] == "Bearer fetched-jwt")
        #expect(
            request.headerFields[BearerAuthMiddleware.sdkHeaderField]
                == sdkIdentityHeaderValue
        )
    }
}
