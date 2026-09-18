import Foundation

/// Why ``start`` did not produce a live session.
///
/// Closed: every one is thrown by this SDK, so it changes only when the SDK
/// does. It says what happened to the attempt, never the server's own slug
/// for why it refused — that is an open set, on ``SessionStartError/serverCode``.
public enum SessionStartErrorCode: String, Sendable, Equatable {
    /// The request never reached the server, so nothing happened server-side
    /// and retrying is safe.
    case transport = "transport"
    /// The server answered, but not with a body this SDK could parse. The
    /// session may already exist, so this is not safe to retry blindly.
    case invalidResponse = "invalid_response"
    /// The transport could not join the room. The server accepted the
    /// session, so this is not a rejection and carries no verdict from it —
    /// the join itself is what failed.
    case joinFailed = "join_failed"
    /// The server refused the session configuration — an unavailable model, a
    /// tool config it cannot accept, instructions past its limit.
    case config = "config"
    /// The workspace is at its concurrent-session limit. Usually an abandoned
    /// session still holding a slot; retrying shortly after succeeds, and
    /// ``SessionStartError/retryAfterSeconds`` carries the server's
    /// `Retry-After` when it sent one.
    case busy = "busy"
    /// The plan refused the session: the free voice grant is spent, or the
    /// model's provider is not included. Not retryable.
    case entitlement = "entitlement"
    /// This SDK is older than the server's supported floor. Upgrade the
    /// package; nothing about the session can be retried.
    case versionMismatch = "version_mismatch"
    /// Realtime voice is not configured for this deployment or workspace.
    case voiceDisabled = "voice_disabled"
    /// The server refused for a reason with no more specific code.
    /// ``SessionStartError/serverCode`` carries its own slug.
    case rejected = "rejected"
    /// The transport joined but the room closed before `ready` — a failed
    /// boot. The session is torn down before ``start`` throws.
    case handshakeFailed = "handshake_failed"
    /// The transport joined but the server's ready handshake never arrived
    /// within the wait budget. The session is torn down before ``start``
    /// throws.
    case readyTimeout = "ready_timeout"
}

/// The server's structured reason for refusing a session start.
///
/// Every field beyond ``code`` and ``message`` belongs to one rejection, and
/// ``code`` says which — read the group that matches and ignore the rest.
/// ``extra`` carries anything the server sent that this SDK does not name, so
/// a field added server-side is passed through rather than dropped.
public struct SessionStartRejection: Sendable, Equatable, Decodable {
    /// The server's stable rejection slug — the same value as
    /// ``SessionStartError/serverCode``. Match on this to know which group of
    /// fields below is populated.
    public let code: String?
    /// Human-readable reason, written for a person to read.
    public let message: String?

    /// `concurrent_session_limit`: the workspace's cap on live sessions.
    public let limit: Int?
    /// `concurrent_session_limit`: sessions already running against that cap.
    public let active: Int?

    /// `free_minutes_exhausted`: minutes the free grant allowed in total.
    public let grantedMinutes: Int?
    /// `free_minutes_exhausted`: minutes already spent against that grant.
    public let usedMinutes: Int?

    /// `insufficient_credits`: prepaid balance remaining, in cents.
    public let balanceCents: Int?
    /// `insufficient_credits`: where to add credit.
    public let topUpPath: String?

    /// `quota_exceeded`: which allowance was exceeded.
    public let meter: String?
    /// `quota_exceeded`: how much the plan includes.
    public let included: Int?
    /// `quota_exceeded`: how much has been used.
    public let used: Int?
    /// `quota_exceeded`: when the allowance renews, or `nil` when it will not —
    /// a fixed term has ended and the way back is a plan change.
    public let resetAt: String?

    /// `provider_not_entitled`: the model provider the plan excludes.
    public let provider: String?
    /// `provider_not_entitled`: the providers it does include.
    public let allowedProviders: [String]?
    /// `provider_not_entitled` / `workspace_limit_reached`: the plan in force.
    public let plan: String?
    /// `provider_not_entitled` / `workspace_limit_reached`: where to upgrade.
    public let upgradePath: String?

    /// Fields the server sent that this SDK does not name.
    public let extra: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case code, message, limit, active, meter, included, used, provider, plan
        case grantedMinutes = "granted_minutes"
        case usedMinutes = "used_minutes"
        case balanceCents = "balance_cents"
        case topUpPath = "top_up_path"
        case resetAt = "reset_at"
        case allowedProviders = "allowed_providers"
        case upgradePath = "upgrade_path"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decodeIfPresent(String.self, forKey: .code)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        limit = try c.decodeIfPresent(Int.self, forKey: .limit)
        active = try c.decodeIfPresent(Int.self, forKey: .active)
        grantedMinutes = try c.decodeIfPresent(Int.self, forKey: .grantedMinutes)
        usedMinutes = try c.decodeIfPresent(Int.self, forKey: .usedMinutes)
        balanceCents = try c.decodeIfPresent(Int.self, forKey: .balanceCents)
        topUpPath = try c.decodeIfPresent(String.self, forKey: .topUpPath)
        meter = try c.decodeIfPresent(String.self, forKey: .meter)
        included = try c.decodeIfPresent(Int.self, forKey: .included)
        used = try c.decodeIfPresent(Int.self, forKey: .used)
        resetAt = try c.decodeIfPresent(String.self, forKey: .resetAt)
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        allowedProviders = try c.decodeIfPresent([String].self, forKey: .allowedProviders)
        plan = try c.decodeIfPresent(String.self, forKey: .plan)
        upgradePath = try c.decodeIfPresent(String.self, forKey: .upgradePath)

        let named = Set(CodingKeys.allCases.map(\.rawValue))
        if case .object(let all)? = try? JSONValue(from: decoder) {
            extra = all.filter { !named.contains($0.key) }
        } else {
            extra = [:]
        }
    }

    /// Decode one from a rejection body, or `nil` when the body carries none.
    static func from(body: Data) -> SessionStartRejection? {
        guard
            case .object(let payload)? = try? JSONDecoder().decode(JSONValue.self, from: body)
        else { return nil }
        for key in ["error", "detail"] {
            guard case .object(let inner)? = payload[key], inner["code"] != nil else { continue }
            guard let data = try? JSONEncoder().encode(inner) else { continue }
            return try? JSONDecoder().decode(SessionStartRejection.self, from: data)
        }
        return nil
    }
}

extension SessionStartRejection.CodingKeys: CaseIterable {}

/// ``start`` did not produce a live session.
///
/// Covers the whole start sequence, which is more than one request: the
/// session-start call, the transport join, and the server's ready handshake.
/// ``code`` names how far it got — switch on it rather than matching the
/// message.
///
/// ``serverCode`` is the server's own rejection slug when it sent one, an open
/// set. ``status`` is the HTTP status of a server rejection, `nil` when the
/// request never reached the server. ``retryAfterSeconds`` is set only for
/// ``SessionStartErrorCode/busy``, and only when the server sent a
/// `Retry-After`. ``detail`` is the server's structured reason when the
/// rejection carried one.
public struct SessionStartError: RealtimeError, LocalizedError, Sendable, Equatable {
    /// How far the attempt got. A closed set this SDK throws — switch on it.
    public let code: SessionStartErrorCode
    /// Human-readable explanation, for logs and display.
    public let message: String
    /// The HTTP status of a server rejection. `nil` when no server answered.
    public let status: Int?
    /// The server's own rejection slug when it sent one. An open set: log it,
    /// do not switch on it.
    public let serverCode: String?
    /// The server's `Retry-After` in whole seconds, for
    /// ``SessionStartErrorCode/busy``. `nil` when it sent none.
    public let retryAfterSeconds: Int?
    /// The server's structured reason, when the rejection carried one.
    public let detail: SessionStartRejection?

    /// A start failure with its cross-SDK code and message.
    public init(
        code: SessionStartErrorCode,
        message: String,
        status: Int? = nil,
        serverCode: String? = nil,
        retryAfterSeconds: Int? = nil,
        detail: SessionStartRejection? = nil
    ) {
        self.code = code
        self.message = message
        self.status = status
        self.serverCode = serverCode
        self.retryAfterSeconds = retryAfterSeconds
        self.detail = detail
    }

    /// The code and message, for `LocalizedError` presentation.
    public var errorDescription: String? {
        message.isEmpty ? code.rawValue : "\(code.rawValue): \(message)"
    }
}

/// Map one session-start rejection onto its closed code.
///
/// The slug decides when the meaning cannot be read off the status —
/// `contract/session-start-error-vectors.json` pins those pairs and every SDK
/// classifies them the same way. Everything else is read from the status.
func classifyStartRejection(serverCode: String?, status: Int?) -> SessionStartErrorCode {
    switch serverCode {
    case "concurrent_session_limit": return .busy
    case "free_minutes_exhausted", "provider_not_entitled": return .entitlement
    case "version_mismatch": return .versionMismatch
    default: break
    }
    if status == 503 { return .voiceDisabled }
    if status == 400 || status == 422 { return .config }
    return .rejected
}
