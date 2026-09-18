import CosmoRealtimeAPI
import Foundation
import OpenAPIRuntime
import OpenAPIURLSession

/// A short-lived per-user JWT — minted server-side by
/// ``RealtimeClient/mintToken(_:ttlSeconds:)`` or fetched by a
/// ``TokenSource``.
public struct MintedToken: Sendable, Equatable {
    /// The token itself. This is the only part a browser or device needs.
    public let jwt: String
    /// When the token stops being accepted. A ``TokenSource`` refreshes ahead
    /// of this by itself.
    public let expiresAt: Date
    /// Server-side revocation handle (``DELETE auth/token/{token_id}``) —
    /// keep it on your server; the device only needs ``jwt``. Cosmo always
    /// returns it; it is optional here because this type doubles as the
    /// ``TokenSource`` cached shape, whose contract is any backend
    /// returning ``{ jwt, expires_at }``.
    public let tokenId: String?

    /// A minted token and the moment it stops being accepted.
    public init(jwt: String, expiresAt: Date, tokenId: String? = nil) {
        self.jwt = jwt
        self.expiresAt = expiresAt
        self.tokenId = tokenId
    }
}

/// How far a token request got before it failed.
///
/// Raised by ``RealtimeClient/mintToken(_:ttlSeconds:)``.
/// Resolving a ``TokenSource`` raises ``TokenSourceError`` instead.
///
/// Closed: every one is raised by this SDK, so it changes only when the SDK
/// does. It says what happened to the attempt, never why the server refused —
/// that is the server's own slug, an open set, on ``MintTokenError/serverCode``.
public enum MintTokenErrorCode: String, Sendable, Equatable {
    /// The request did not produce a usable answer — a transport failure or
    /// timeout, or a redirect, which is refused rather than followed so a
    /// workspace key is never re-sent to another origin.
    case requestFailed = "request_failed"
    /// The server answered, but not with a token this SDK could parse.
    case invalidResponse = "invalid_response"
    /// The server refused. ``MintTokenError/serverCode`` carries its slug.
    case requestRejected = "request_rejected"
    /// Minting needs a workspace API key, and this client holds an end-user
    /// token. Tokens cannot mint tokens.
    case missingApiKey = "missing_api_key"
}

/// ``RealtimeClient/mintToken(_:ttlSeconds:)`` failed.
///
/// ``code`` names what this SDK saw — match on it rather than on the message,
/// which is written for a human. When it is
/// ``MintTokenErrorCode/requestRejected`` the server declined the request and
/// ``serverCode`` carries the server's own slug, an open set: a typed
/// rejection such as ``"workspace_forbidden"``, or a synthetic
/// ``"http_<status>"`` when the response carried none.
public struct MintTokenError: ApiError, LocalizedError, Equatable {
    /// How far the attempt got. A closed set this SDK raises — switch on it.
    public let code: MintTokenErrorCode
    /// Human-readable explanation, for logs and display.
    public let message: String
    /// The server's own rejection slug when it sent one, or a synthetic
    /// `http_<status>`. An open set: log it, do not switch on it.
    public let serverCode: String?

    /// A mint failure with its cross-SDK code and message.
    public init(code: MintTokenErrorCode, message: String, serverCode: String? = nil) {
        self.code = code
        self.message = message
        self.serverCode = serverCode
    }

    /// The message, for `LocalizedError` presentation.
    public var errorDescription: String? { message }
}
