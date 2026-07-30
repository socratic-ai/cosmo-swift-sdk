import Foundation
import HTTPTypes
import LiveKit
import OpenAPIRuntime
import Testing
@testable import CosmoRealtime

@Suite("client identity middleware")
struct ClientIdentityMiddlewareTests {

    private func intercepted(
        identity: ClientIdentity
    ) async throws -> HTTPRequest {
        let middleware = ClientIdentityMiddleware(identity: identity)
        var seen: HTTPRequest?
        _ = try await middleware.intercept(
            HTTPRequest(method: .post, scheme: "https", authority: "api.example.com", path: "/x"),
            body: nil,
            baseURL: URL(string: "https://api.example.com")!,
            operationID: "startSession"
        ) { request, _, _ in
            seen = request
            return (HTTPResponse(status: .ok), nil)
        }
        return try #require(seen)
    }

    @Test("sets client, version and build on the outbound generated request")
    func setsAllThreeFields() async throws {
        let request = try await intercepted(
            identity: ClientIdentity(client: "cosmo-mac", marketingVersion: "1.0.0", build: "42")
        )
        #expect(request.headerFields[.init("X-Cosmo-Client")!] == "cosmo-mac")
        #expect(request.headerFields[.init("X-Cosmo-Client-Version")!] == "1.0.0")
        #expect(request.headerFields[.init("X-Cosmo-Client-Build")!] == "42")
    }

    @Test("leaves headers set by earlier middleware intact")
    func preservesExistingFields() async throws {
        let middleware = ClientIdentityMiddleware(
            identity: ClientIdentity(client: "cosmo-mac", marketingVersion: "1.0.0", build: "42")
        )
        var request = HTTPRequest(
            method: .post, scheme: "https", authority: "api.example.com", path: "/x"
        )
        request.headerFields[.authorization] = "Bearer k"
        var seen: HTTPRequest?
        _ = try await middleware.intercept(
            request, body: nil,
            baseURL: URL(string: "https://api.example.com")!,
            operationID: "startSession"
        ) { req, _, _ in
            seen = req
            return (HTTPResponse(status: .ok), nil)
        }
        #expect(seen?.headerFields[.authorization] == "Bearer k")
    }
}

@Suite("generated-client middleware stack")
struct APIMiddlewareStackTests {

    private func options(identity: ClientIdentity?) -> RealtimeSession.Options {
        RealtimeSession.Options(
            apiKey: "cosmo_secret", baseURL: URL(string: "https://api.example.com")!,
            clientIdentity: identity
        )
    }

    @Test("bearer auth is always present")
    func alwaysBearer() {
        let stack = options(identity: nil)._apiMiddlewares(prepared: nil)
        #expect(stack.contains { $0 is BearerAuthMiddleware })
    }

    @Test("identity middleware is installed only when an identity is set")
    func identityGated() {
        let without = options(identity: nil)._apiMiddlewares(prepared: nil)
        #expect(!without.contains { $0 is ClientIdentityMiddleware })

        let with = options(
            identity: ClientIdentity(client: "cosmo-mac", marketingVersion: "1.0.0", build: "42")
        )._apiMiddlewares(prepared: nil)
        #expect(with.contains { $0 is ClientIdentityMiddleware })
    }

    @Test("the token convenience init forwards clientIdentity the same as the apiKey init")
    func tokenInitForwardsClientIdentity() {
        let opts = RealtimeSession.Options(
            token: "jwt-abc", baseURL: URL(string: "https://api.example.com")!,
            clientIdentity: ClientIdentity(client: "cosmo-mac", marketingVersion: "1.0.0", build: "42")
        )
        #expect(opts._apiMiddlewares(prepared: nil).contains { $0 is ClientIdentityMiddleware })
    }

    @Test("prepared-room middleware is installed only when a handle was taken")
    func preparedRoomGated() {
        let handle = RealtimeSession.PreparedSessionHandle(
            roomName: "cosmo-prep",
            roomGrant: "grant-xyz",
            token: "tok",
            livekitURL: "wss://a.example",
            room: Room(),
            preparedAt: Date(),
            baseURL: URL(string: "https://api.example.com")!
        )

        let without = options(identity: nil)._apiMiddlewares(prepared: nil)
        #expect(!without.contains { $0 is PreparedRoomHeaderMiddleware })

        let with = options(identity: nil)._apiMiddlewares(prepared: handle)
        #expect(with.contains { $0 is PreparedRoomHeaderMiddleware })
    }
}
