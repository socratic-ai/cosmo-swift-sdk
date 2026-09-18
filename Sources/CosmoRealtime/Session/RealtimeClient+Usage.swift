import CosmoRealtimeAPI
import Foundation
import OpenAPIRuntime

/// Usage summary for one session, in provider-reported units.
///
/// ``duration_seconds`` is set once the session ends. The rest of the
/// detail arrives with the summary, so it is present only while
/// ``usage_status`` is ``RECORDED``, at which point the numbers are
/// final. ``tokens`` is absent when the provider reports none.
public struct SessionUsage: Codable, Hashable, Sendable {
    /// How long the agent was speaking.
    public var agentSpeakingSeconds: Swift.Double?
    /// Wall-clock length of the session, set once it ends.
    public var durationSeconds: Swift.Double?
    /// The concrete model id that ran, which a family alias resolves to.
    public var model: Swift.String?
    /// Which model provider actually ran the session, after the server
    /// resolved the requested model.
    @_documentation(visibility: internal) @frozen public enum ProviderPayload: String, Codable, Hashable, Sendable, CaseIterable {
        case gemini = "gemini"
        case openai = "openai"
        case openaiMini = "openai_mini"
        case openaiLive = "openai_live"
        case grok = "grok"
        case cosmoVoicePersonaplex = "cosmo_voice_personaplex"
        case cosmoVoiceUltravox = "cosmo_voice_ultravox"
    }
    /// Which model provider actually ran the session, after the server
    /// resolved the requested model.
    public var provider: SessionUsage.ProviderPayload?
    /// Where the session itself ended up.
    public var status: SessionStatus
    /// The token breakdown. Absent when the provider reported none — that is
    /// absence of reporting, not zero usage.
    public var tokens: SessionTokenUsage?
    /// How many turns the session took.
    public var turnCount: Swift.Int?
    /// Whether the usage summary exists yet. Poll while this is ``pending``;
    /// stop on ``unavailable``.
    public var usageStatus: UsageStatus
    /// How long the user was speaking.
    public var userSpeakingSeconds: Swift.Double?
    init(
        agentSpeakingSeconds: Swift.Double? = nil,
        durationSeconds: Swift.Double? = nil,
        model: Swift.String? = nil,
        provider: SessionUsage.ProviderPayload? = nil,
        status: SessionStatus,
        tokens: SessionTokenUsage? = nil,
        turnCount: Swift.Int? = nil,
        usageStatus: UsageStatus,
        userSpeakingSeconds: Swift.Double? = nil
    ) {
        self.agentSpeakingSeconds = agentSpeakingSeconds
        self.durationSeconds = durationSeconds
        self.model = model
        self.provider = provider
        self.status = status
        self.tokens = tokens
        self.turnCount = turnCount
        self.usageStatus = usageStatus
        self.userSpeakingSeconds = userSpeakingSeconds
    }
    enum CodingKeys: String, CodingKey {
        case agentSpeakingSeconds = "agent_speaking_seconds"
        case durationSeconds = "duration_seconds"
        case model
        case provider
        case status
        case tokens
        case turnCount = "turn_count"
        case usageStatus = "usage_status"
        case userSpeakingSeconds = "user_speaking_seconds"
    }
}

/// Token usage reported by the session's model provider, split by
/// direction and modality. The live ``cosmo.usage`` event's counters plus
/// the input and output totals, with the same cumulative semantics.
public struct SessionTokenUsage: Codable, Hashable, Sendable {
    /// Audio the model was given.
    public var inputAudioTokens: Swift.Int
    /// Input served from the provider's cache. Already counted in
    /// ``input_tokens`` — a subset, not an addition.
    public var inputCachedTokens: Swift.Int
    /// Images the model was given.
    public var inputImageTokens: Swift.Int
    /// Text the model was given.
    public var inputTextTokens: Swift.Int
    /// Every input token, across all modalities.
    public var inputTokens: Swift.Int
    /// Audio the model produced. On a session running ``audio.output=false``
    /// this depends on the provider: one with a native text-only mode produces
    /// none, while one without keeps generating speech that is discarded, and
    /// those tokens still accrue.
    public var outputAudioTokens: Swift.Int
    /// Text the model produced.
    public var outputTextTokens: Swift.Int
    /// Every output token, across all modalities.
    public var outputTokens: Swift.Int
    /// Input plus output, as the provider reports it.
    public var totalTokens: Swift.Int
    init(
        inputAudioTokens: Swift.Int,
        inputCachedTokens: Swift.Int,
        inputImageTokens: Swift.Int,
        inputTextTokens: Swift.Int,
        inputTokens: Swift.Int,
        outputAudioTokens: Swift.Int,
        outputTextTokens: Swift.Int,
        outputTokens: Swift.Int,
        totalTokens: Swift.Int
    ) {
        self.inputAudioTokens = inputAudioTokens
        self.inputCachedTokens = inputCachedTokens
        self.inputImageTokens = inputImageTokens
        self.inputTextTokens = inputTextTokens
        self.inputTokens = inputTokens
        self.outputAudioTokens = outputAudioTokens
        self.outputTextTokens = outputTextTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
    }
    enum CodingKeys: String, CodingKey {
        case inputAudioTokens = "input_audio_tokens"
        case inputCachedTokens = "input_cached_tokens"
        case inputImageTokens = "input_image_tokens"
        case inputTextTokens = "input_text_tokens"
        case inputTokens = "input_tokens"
        case outputAudioTokens = "output_audio_tokens"
        case outputTextTokens = "output_text_tokens"
        case outputTokens = "output_tokens"
        case totalTokens = "total_tokens"
    }
    /// Decodes a token breakdown from the wire; an omitted counter decodes
    /// as ``0``.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputAudioTokens = try container.decodeIfPresent(Swift.Int.self, forKey: .inputAudioTokens) ?? 0
        inputCachedTokens = try container.decodeIfPresent(Swift.Int.self, forKey: .inputCachedTokens) ?? 0
        inputImageTokens = try container.decodeIfPresent(Swift.Int.self, forKey: .inputImageTokens) ?? 0
        inputTextTokens = try container.decodeIfPresent(Swift.Int.self, forKey: .inputTextTokens) ?? 0
        inputTokens = try container.decodeIfPresent(Swift.Int.self, forKey: .inputTokens) ?? 0
        outputAudioTokens = try container.decodeIfPresent(Swift.Int.self, forKey: .outputAudioTokens) ?? 0
        outputTextTokens = try container.decodeIfPresent(Swift.Int.self, forKey: .outputTextTokens) ?? 0
        outputTokens = try container.decodeIfPresent(Swift.Int.self, forKey: .outputTokens) ?? 0
        totalTokens = try container.decodeIfPresent(Swift.Int.self, forKey: .totalTokens) ?? 0
    }
}

/// Where a realtime session is in its lifecycle.
public enum SessionStatus: RawRepresentable, Codable, Hashable, Sendable, CaseIterable {
    case active
    case completed
    case error
    /// A value added to the server after this package shipped, verbatim.
    case unknown(String)

    public static var allCases: [SessionStatus] {
        [
            .active,
            .completed,
            .error,
        ]
    }

    public var rawValue: String {
        switch self {
        case .active: return "active"
        case .completed: return "completed"
        case .error: return "error"
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

/// Whether a session's detailed usage summary is available.
///
/// ``PENDING`` while the session runs and for a short window after it
/// ends, before the summary is written. ``RECORDED`` once it is there
/// and the numbers are final. ``UNAVAILABLE`` once that window has
/// passed without one arriving: a session with no turn or speech
/// activity records none, and neither does one torn down abnormally.
public enum UsageStatus: RawRepresentable, Codable, Hashable, Sendable, CaseIterable {
    case pending
    case recorded
    case unavailable
    /// A value added to the server after this package shipped, verbatim.
    case unknown(String)

    public static var allCases: [UsageStatus] {
        [
            .pending,
            .recorded,
            .unavailable,
        ]
    }

    public var rawValue: String {
        switch self {
        case .pending: return "pending"
        case .recorded: return "recorded"
        case .unavailable: return "unavailable"
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

/// How far a usage read got before it failed.
///
/// Closed: every one is thrown by this SDK, so it changes only when the SDK
/// does. It says what happened to the attempt, never why the server refused —
/// that is the server's own slug, an open set, on ``ApiError/serverCode``.
public enum UsageErrorCode: String, Sendable, Equatable {
    /// The request did not produce a usable answer — a network failure or
    /// timeout, or a redirect, which is refused rather than followed so a
    /// credential is never re-sent to another origin.
    case requestFailed = "request_failed"
    /// The server refused. ``ApiError/serverCode`` carries its own slug for why.
    case requestRejected = "request_rejected"
    /// The server answered, but not with a body this SDK could parse.
    case invalidResponse = "invalid_response"
    /// The SDK refused to make the call — this session carries no usage
    /// surface. Nothing reached the server.
    case invalidRequest = "invalid_request"
}

/// ``RealtimeSession/usage()`` failed.
public struct UsageError: ApiError, LocalizedError, Sendable, Equatable {
    /// How far the attempt got. A closed set this SDK throws — switch on it.
    public let code: UsageErrorCode
    /// Human-readable explanation, for logs and display. The server's own
    /// prose for a rejection, the transport or decode detail otherwise.
    public let message: String
    /// The server's own rejection slug when it sent one. `nil` when no server
    /// verdict was parsed.
    public let serverCode: String?

    /// A failure with its cross-SDK code and message.
    public init(code: UsageErrorCode, message: String, serverCode: String? = nil) {
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
    /// Fetch a session's usage summary (GET sessions/{id}/usage):
    /// duration, talk time, and token counts in provider-reported units.
    ///
    /// Takes an explicit session id because the client outlives any one
    /// session — ``RealtimeSession/usage()`` is the id-carrying surface.
    ///
    /// Throws ``UsageError`` when the server rejects the request, the
    /// transport fails, or the response body cannot be decoded.
    public func sessionUsage(sessionId: String) async throws -> SessionUsage {
        guard sessionTransport != .websocket else {
            throw UsageError(
                code: .invalidRequest,
                message: "usage is not available on the local websocket transport"
            )
        }
        // Reads the body itself rather than through the generated client:
        // ``status`` and ``usage_status`` are server-authored sets, and the
        // generated enums are frozen, so a state added after this package
        // shipped would fail the whole response — the token counts with it.
        // See ``_getDecodingOurselves(path:as:failure:)``.
        return try await _getDecodingOurselves(
            path: "/api/v1/external/sessions/\(sessionId)/usage",
            as: SessionUsage.self,
            failure: UsageError.self
        )
    }
}

extension RealtimeSession {
    /// Fetch this session's usage summary: duration, talk time, and token
    /// counts in provider-reported units.
    ///
    /// An authenticated REST read, not a data-channel frame — callable while
    /// the session is live and, unlike the sends, after it ends. The
    /// detailed summary is written shortly after the session ends;
    /// ``SessionUsage/usageStatus`` on the result reports whether it
    /// is present yet.
    ///
    /// Throws ``UsageError`` on a server rejection or transport failure, and
    /// ``SessionStateError`` if the session never started.
    public func usage() async throws -> SessionUsage {
        guard let client, let sessionId else {
            throw SessionStateError(code: .notConnected, message: "RealtimeSession is not connected.")
        }
        return try await client.sessionUsage(sessionId: sessionId)
    }
}

extension UsageError: ApiErrorBuilding {
    static func rejected(code: String?, detail: String) -> UsageError {
        UsageError(code: .requestRejected, message: detail, serverCode: code)
    }

    static func transport(message: String) -> UsageError {
        UsageError(code: .requestFailed, message: message)
    }

    static func invalidResponse(message: String) -> UsageError {
        UsageError(code: .invalidResponse, message: message)
    }
}
