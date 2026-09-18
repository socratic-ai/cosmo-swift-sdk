import CosmoRealtimeAPI
import Foundation
import OpenAPIRuntime

/// Result of a credential preflight — a 200 means the credential
/// authenticated; the fields say what it can do from here.
public struct CredentialInfo: Codable, Hashable, Sendable {
    /// Whether this credential carries the scope a session start needs. False means the credential is valid but under-scoped.
    public var canStartSessions: Swift.Bool
    /// Which of the two credential kinds the server saw.
    public var credential: CredentialKind
    /// The end user a minted token is bound to; null for an API key.
    public var externalUserId: Swift.String?
    /// Whether this deployment has the default voice stack configured — LiveKit plus the default provider's key. A floor, not a per-session guarantee: a session that requests an opt-in provider is checked against that provider instead, so a start can still return 503 when this is true.
    public var realtimeVoiceAvailable: Swift.Bool
    /// Scopes granted to this credential, e.g. ``realtime:start``. Reported after hierarchy expansion: a credential holding the deprecated ``realtime:use`` umbrella lists it alongside the child scopes it implies.
    public var scopes: [Swift.String]
    /// The workspace the credential is bound to. Present for an API key, which the workspace's own developer holds; null for a minted token, which is held by an end user.
    public var workspace: WorkspaceInfo?
    init(
        canStartSessions: Swift.Bool,
        credential: CredentialKind,
        externalUserId: Swift.String? = nil,
        realtimeVoiceAvailable: Swift.Bool,
        scopes: [Swift.String],
        workspace: WorkspaceInfo? = nil
    ) {
        self.canStartSessions = canStartSessions
        self.credential = credential
        self.externalUserId = externalUserId
        self.realtimeVoiceAvailable = realtimeVoiceAvailable
        self.scopes = scopes
        self.workspace = workspace
    }
    enum CodingKeys: String, CodingKey {
        case canStartSessions = "can_start_sessions"
        case credential
        case externalUserId = "external_user_id"
        case realtimeVoiceAvailable = "realtime_voice_available"
        case scopes
        case workspace
    }
}

/// The workspace the credential is bound to.
public struct WorkspaceInfo: Codable, Hashable, Sendable {
    /// Human-readable workspace name.
    public var name: Swift.String
    /// URL-safe workspace identifier.
    public var slug: Swift.String
    init(
        name: Swift.String,
        slug: Swift.String
    ) {
        self.name = name
        self.slug = slug
    }
    enum CodingKeys: String, CodingKey {
        case name
        case slug
    }
}

/// Which of the two realtime credentials the server saw.
public enum CredentialKind: RawRepresentable, Codable, Hashable, Sendable, CaseIterable {
    case apiKey
    case userToken
    /// A value added to the server after this package shipped, verbatim.
    case unknown(String)

    public static var allCases: [CredentialKind] {
        [
            .apiKey,
            .userToken,
        ]
    }

    public var rawValue: String {
        switch self {
        case .apiKey: return "api_key"
        case .userToken: return "user_token"
        case .unknown(let value): return value
        }
    }

    // Failable to keep the signature Swift synthesized for the raw-value
    // enum this replaced — existing `if let`/`guard let` parsing still
    // compiles. It never returns nil: an unrecognized value is the whole
    // point, so it becomes `unknown` rather than nothing.
    public init?(rawValue: String) {
        self = Self.allCases.first { $0.rawValue == rawValue } ?? .unknown(rawValue)
    }
}

/// How far a credential check got before it failed.
///
/// Closed: every one is thrown by this SDK, so it changes only when the SDK
/// does. It says what happened to the attempt, never why the server refused —
/// that is the server's own slug, an open set, on ``ApiError/serverCode``.
public enum VerifyErrorCode: String, Sendable, Equatable {
    /// The request did not produce a usable answer — a network failure or
    /// timeout, or a redirect, which is refused rather than followed so a
    /// credential is never re-sent to another origin.
    case requestFailed = "request_failed"
    /// The server refused. ``ApiError/serverCode`` carries its own slug for why.
    case requestRejected = "request_rejected"
    /// The server answered, but not with a body this SDK could parse.
    case invalidResponse = "invalid_response"
}

/// ``RealtimeClient/verify()`` failed.
///
/// An under-scoped credential is not an error here — it comes back as
/// ``CredentialInfo/canStartSessions`` being false.
public struct VerifyError: ApiError, LocalizedError, Sendable, Equatable {
    /// How far the attempt got. A closed set this SDK throws — switch on it.
    public let code: VerifyErrorCode
    /// Human-readable explanation, for logs and display. The server's own
    /// prose for a rejection, the transport or decode detail otherwise.
    public let message: String
    /// The server's own rejection slug when it sent one. `nil` when no server
    /// verdict was parsed.
    public let serverCode: String?

    /// A failure with its cross-SDK code and message.
    public init(code: VerifyErrorCode, message: String, serverCode: String? = nil) {
        self.code = code
        self.message = message
        self.serverCode = serverCode
    }

    /// The code and message, for `LocalizedError` presentation.
    public var errorDescription: String? {
        message.isEmpty ? code.rawValue : "\(code.rawValue): \(message)"
    }
}

extension RealtimeClient {
    /// Check this client's credential without starting a session (GET
    /// realtime/verify).
    ///
    /// A free preflight for a launch-time check or a CI smoke test: it
    /// confirms the credential authenticates against ``RealtimeClient/baseURL``,
    /// and the result separates the failure modes a first session would
    /// otherwise conflate — under-scoped (``CredentialInfo/canStartSessions``)
    /// versus a deployment with no default voice stack configured
    /// (``CredentialInfo/realtimeVoiceAvailable``).
    ///
    /// Throws ``VerifyError`` when the server rejects the credential, the
    /// transport fails, or the response body cannot be decoded.
    public func verify() async throws -> CredentialInfo {
        // Reads the body itself rather than through the generated client:
        // ``credential`` is a server-authored set, and the generated enum is
        // frozen, so a kind added after this package shipped would fail the
        // whole response. See ``_getDecodingOurselves(path:as:failure:)``.
        return try await _getDecodingOurselves(
            path: "/api/v1/external/realtime/verify",
            as: CredentialInfo.self,
            failure: VerifyError.self
        )
    }
}

extension VerifyError: ApiErrorBuilding {
    static func rejected(code: String?, detail: String) -> VerifyError {
        VerifyError(code: .requestRejected, message: detail, serverCode: code)
    }

    static func transport(message: String) -> VerifyError {
        VerifyError(code: .requestFailed, message: message)
    }

    static func invalidResponse(message: String) -> VerifyError {
        VerifyError(code: .invalidResponse, message: message)
    }
}
