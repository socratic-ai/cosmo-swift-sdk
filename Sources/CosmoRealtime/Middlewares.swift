import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Injects ``Authorization: Bearer <token>`` on every outbound request.
/// The bearer value is either a workspace api key or a minted per-user
/// JWT — indistinguishable on the wire.
struct BearerAuthMiddleware: ClientMiddleware {
    let bearerToken: String

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var req = request
        req.headerFields[.authorization] = "Bearer \(bearerToken)"
        return try await next(req, body, baseURL)
    }
}

/// Injects the first-party prepared-room ref on ``/session/start``. The
/// session-config request body is the published developer schema, which
/// deliberately doesn't model the prepare-room feature — so first-party
/// clients send the ref as headers and the backend folds it back into the
/// typed request.
struct PreparedRoomHeaderMiddleware: ClientMiddleware {
    static let roomNameField = HTTPField.Name("x-cosmo-prepared-room-name")!
    static let roomGrantField = HTTPField.Name("x-cosmo-prepared-room-grant")!

    let roomName: String
    let roomGrant: String

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var req = request
        req.headerFields[Self.roomNameField] = roomName
        req.headerFields[Self.roomGrantField] = roomGrant
        return try await next(req, body, baseURL)
    }
}

/// Injects the calling client's identity on every generated-client request.
/// The `URLRequest` counterpart is ``ClientIdentity/apply(to:)``; both read
/// ``ClientHeaderName``.
struct ClientIdentityMiddleware: ClientMiddleware {
    static let clientField = HTTPField.Name(ClientHeaderName.client)!
    static let versionField = HTTPField.Name(ClientHeaderName.version)!
    static let buildField = HTTPField.Name(ClientHeaderName.build)!

    let identity: ClientIdentity

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var req = request
        req.headerFields[Self.clientField] = identity.client
        req.headerFields[Self.versionField] = identity.marketingVersion
        req.headerFields[Self.buildField] = identity.build
        return try await next(req, body, baseURL)
    }
}

