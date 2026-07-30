import CosmoRealtimeAPI
import Foundation
import OpenAPIRuntime
import OpenAPIURLSession

/// A client for the external realtime API: mint end-user tokens, start
/// sessions, and read back voice-session data. Mirrors the Python
/// ``CosmoRealtime`` client. Construct once with your
/// ``RealtimeSession/Options``; reuse across mints and sessions.
public struct RealtimeClient: Sendable {
    private let options: RealtimeSession.Options
    private let transport: any ClientTransport

    public init(_ options: RealtimeSession.Options) {
        self.init(options: options, transport: makeRESTTransport(options: options))
    }

    init(options: RealtimeSession.Options, transport: any ClientTransport) {
        self.options = options
        self.transport = transport
    }

    /// Mint a short-lived per-user JWT for `externalUserId` (POST auth/token).
    /// Run this server-side with an api-key credential; hand the returned
    /// ``MintedToken/jwt`` to the end user's device, which constructs
    /// ``RealtimeSession/Options`` and starts a session. Idempotent per
    /// `(workspace, externalUserId)` — the same external user maps to the same
    /// auto-provisioned project on repeat calls.
    ///
    /// Throws ``MintTokenError`` if the server rejects the request, the
    /// transport fails, or the response body cannot be decoded.
    public func mintToken(externalUserId: String) async throws -> MintedToken {
        let output = try await _run(as: MintTokenError.self) {
            try await _mint(externalUserId: externalUserId)
        }
        switch output {
        case .ok(let ok):
            let response = try ok.body.json
            return MintedToken(jwt: response.jwt, expiresAt: response.expiresAt)
        case .unprocessableContent(let err):
            throw Self._rejected(as: MintTokenError.self, try? err.body.json)
        case .undocumented(let statusCode, let payload):
            throw await Self._undocumented(as: MintTokenError.self, statusCode, payload)
        }
    }

    /// Start a session with this client's options — convenience over
    /// ``RealtimeSession/start(_:config:)``.
    public func start(config: SessionConfig = SessionConfig()) async throws -> RealtimeSession {
        try await RealtimeSession.start(options, config: config)
    }

    /// The single generated mint call. Isolated so an operationId cleanup that
    /// renames the method is a one-line change.
    private func _mint(
        externalUserId: String
    ) async throws -> CosmoRealtimeAPI.Operations.MintProjectToken.Output {
        try await _apiClient().mintProjectToken(
            body: .json(.init(externalUserId: externalUserId))
        )
    }

    /// The generated client bound to this client's server and credential.
    func _apiClient() -> CosmoRealtimeAPI.Client {
        CosmoRealtimeAPI.Client(
            serverURL: options.baseURL,
            transport: transport,
            middlewares: options._apiMiddlewares(prepared: nil)
        )
    }

    /// A 200 whose body failed to decode against the schema: the generated
    /// client raises a ``ClientError`` carrying the 2xx response and a
    /// ``DecodingError``. Distinguishes that from a genuine transport failure
    /// (no decoding cause).
    static func _isSuccessBodyDecodeFailure(_ error: any Error) -> Bool {
        guard
            let clientError = error as? ClientError,
            let status = clientError.response?.status.code,
            (200..<300).contains(status)
        else { return false }
        return clientError.underlyingError is DecodingError
    }

    static func _collectBody(_ payload: OpenAPIRuntime.UndocumentedPayload) async -> String {
        guard let body = payload.body else { return "" }
        return (try? await String(collecting: body, upTo: 64 * 1024)) ?? ""
    }

}

/// A short-lived per-user JWT minted via ``RealtimeClient/mintToken(externalUserId:)``.
public struct MintedToken: Sendable, Equatable {
    public let jwt: String
    public let expiresAt: Date
}

/// A dedicated error type for ``RealtimeClient/mintToken(externalUserId:)``,
/// mirroring the Python SDK's ``MintTokenError``.
public enum MintTokenError: Error, LocalizedError, Equatable {
    /// The server refused the request (HTTP ≥ 400). ``code`` is the protocol
    /// error slug when the rejection carried one.
    case rejected(code: String?, detail: String)
    /// A network or transport failure before a server verdict.
    case transport(message: String)
    /// The server replied 200 but the body could not be decoded.
    case invalidResponse(message: String)

    public var errorDescription: String? {
        switch self {
        case .rejected(let code, let detail):
            if let code { return "\(code): \(detail)" }
            return detail
        case .transport(let message):
            return "Mint token transport failed: \(message)"
        case .invalidResponse(let message):
            return "Mint token response decode failed: \(message)"
        }
    }
}
