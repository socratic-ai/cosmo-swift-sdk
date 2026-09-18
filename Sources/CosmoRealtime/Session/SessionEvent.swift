import CosmoRealtimeAPI
import Foundation

// The SDK declares the wire payload types it speaks: hand-written mirrors
// of the external protocol's component schemas, one per typealias this
// file used to re-export from the generated module. The names are the
// cross-SDK ones: session-event union members carry the ``Event`` postfix
// and live at the top level, matching Python and TypeScript
// symbol-for-symbol. Drift between these models and the spec fails a CI
// pin test; the generated module stays an implementation detail of the
// REST client and the send path.

/// Sent after the upstream session is established and the agent is ready.
public struct ReadyEvent: Codable, Hashable, Sendable {
    /// Resolved registry-agent summary (see ``ResolvedAgent``).
    /// ``None`` for inline / default-agent sessions.
    public var agent: ResolvedAgent?
    /// Effective server-enforced session duration cap, so clients can render
    /// their own countdown. ``None`` = no cap. The server also pushes
    /// ``session-ending-soon`` near the deadline and ``session-ended`` at
    /// cutoff.
    public var maxSessionSeconds: Swift.Int?
    /// Tools this session could not get — a registered tool the deployment
    /// or workspace cannot run right now — with the reason for each. The session
    /// starts without them, so check this to see what it is actually running.
    ///
    /// Only availability drops appear here. A spec the server considers
    /// malformed — a bad schema, a duplicate or reserved name, a ``kind`` this
    /// flow does not execute — rejects the whole session start with a 422
    /// (``invalid_tool_config``) instead, and never reaches this list.
    public var rejectedTools: [RejectedTool]
    /// Server-assigned id for this session. Clients persist it and pass it back
    /// as ``experimental.resume_session_id`` on a fresh ``session-config`` to
    /// resume after a disconnect.
    public var sessionId: Swift.String
    /// The event type. Always ``ready``.
    @frozen public enum _TypePayload: String, Codable, Hashable, Sendable, CaseIterable {
        case ready = "ready"
    }
    /// The event type. Always ``ready``.
    public var _type: ReadyEvent._TypePayload
    init(
        agent: ResolvedAgent? = nil,
        maxSessionSeconds: Swift.Int? = nil,
        rejectedTools: [RejectedTool] = [],
        sessionId: Swift.String,
        _type: ReadyEvent._TypePayload
    ) {
        self.agent = agent
        self.maxSessionSeconds = maxSessionSeconds
        self.rejectedTools = rejectedTools
        self.sessionId = sessionId
        self._type = _type
    }
    enum CodingKeys: String, CodingKey {
        case agent
        case maxSessionSeconds = "max_session_seconds"
        case rejectedTools = "rejected_tools"
        case sessionId = "session_id"
        case _type = "type"
    }
    /// Decodes a ready event from the wire; omitted ``rejected_tools``
    /// decodes as empty — nothing was rejected.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agent = try container.decodeIfPresent(ResolvedAgent.self, forKey: .agent)
        maxSessionSeconds = try container.decodeIfPresent(Swift.Int.self, forKey: .maxSessionSeconds)
        rejectedTools = try container.decodeIfPresent([RejectedTool].self, forKey: .rejectedTools) ?? []
        sessionId = try container.decode(Swift.String.self, forKey: .sessionId)
        _type = try container.decode(ReadyEvent._TypePayload.self, forKey: ._type)
    }
}

/// Streaming transcript event for either speaker.
///
/// For the assistant role in audio sessions, this is the audio
/// transcription — the words the listener actually heard. The model may
/// ALSO emit a separate text channel via ``ModelTextEvent``; consumers
/// that render a "what was spoken" bubble should subscribe to
/// ``transcript`` only.
///
/// Contract (wire-level, applies to both user and assistant):
///
/// * Streaming events (``is_final=False``): ``text`` is the **new
///   fragment since the previous event** for that role's turn (a
///   delta). Consumers append.
/// * Terminating event (``is_final=True``): ``text`` is the
///   **cumulative full transcript** for the turn. Consumers replace
///   whatever they accumulated with this value.
///
/// Two carve-outs where the terminating event is NOT the full turn, both
/// load-bearing rather than accidental:
///
/// * **Empty final.** A turn the model produced nothing usable for (a
///   suppressed or garbled turn) finalizes with ``text=""``. It means an
///   empty turn, not "unchanged" — a consumer that skips empty finals
///   leaves the turn's bubble dangling into the next one.
/// * **Suffix final on a silent session.** When the agent runs with
///   ``audio.output=False``, a user final that arrives after the VAD
///   endpoint already committed the utterance is stripped of the committed
///   prefix, so it carries only the remainder. Replacing on final would
///   drop the part committed at the endpoint.
///
/// A consumer that only ever appends non-finals and replaces on final is
/// correct for the common path; these two need the extra handling.
///
/// For the folded conversation, read ``RealtimeSession/transcript``
/// instead.
public struct TranscriptDeltaEvent: Codable, Hashable, Sendable {
    /// Whether this closes the turn. Append while it is false; on true,
    /// replace what you accumulated — except in the two cases the class
    /// docstring describes, where the final carries less than the whole turn
    /// and replacing loses text.
    public var isFinal: Swift.Bool
    /// Who was speaking — the user, or the assistant.
    public var role: TranscriptRole
    /// The new fragment while ``is_final`` is false, the whole turn once it
    /// is true. The class docstring names the two cases where a final carries
    /// less than the whole turn.
    public var text: Swift.String
    /// The event type. Always ``transcript``.
    @frozen public enum _TypePayload: String, Codable, Hashable, Sendable, CaseIterable {
        case transcript = "transcript"
    }
    /// The event type. Always ``transcript``.
    public var _type: TranscriptDeltaEvent._TypePayload
    init(
        isFinal: Swift.Bool,
        role: TranscriptRole,
        text: Swift.String,
        _type: TranscriptDeltaEvent._TypePayload
    ) {
        self.isFinal = isFinal
        self.role = role
        self.text = text
        self._type = _type
    }
    enum CodingKeys: String, CodingKey {
        case isFinal = "is_final"
        case role
        case text
        case _type = "type"
    }
}

/// Streaming text-channel fragment from the model.
///
/// Distinct from ``transcript``: this is text the model emits alongside its
/// audio output, not a transcription of the audio itself. In audio sessions
/// the upstream may write function-call narration here that the model did
/// NOT speak; in text-only sessions it carries the model's response.
/// Consumers building a "what was spoken" transcript should subscribe to
/// ``TranscriptDeltaEvent`` instead.
public struct ModelTextEvent: Codable, Hashable, Sendable {
    /// Whether this closes the text response.
    public var isFinal: Swift.Bool?
    /// The fragment of model text emitted since the previous event.
    public var text: Swift.String
    /// The event type. Always ``model-text``.
    @frozen public enum _TypePayload: String, Codable, Hashable, Sendable, CaseIterable {
        case modelText = "model-text"
    }
    /// The event type. Always ``model-text``.
    public var _type: ModelTextEvent._TypePayload
    init(
        isFinal: Swift.Bool? = nil,
        text: Swift.String,
        _type: ModelTextEvent._TypePayload
    ) {
        self.isFinal = isFinal
        self.text = text
        self._type = _type
    }
    enum CodingKeys: String, CodingKey {
        case isFinal = "is_final"
        case text
        case _type = "type"
    }
}

/// Marks the end of a turn so the client can finalize a transcript bubble.
public struct TurnCompleteEvent: Codable, Hashable, Sendable {
    /// Whose turn ended.
    public var role: TranscriptRole
    /// The event type. Always ``turn-complete``.
    @frozen public enum _TypePayload: String, Codable, Hashable, Sendable, CaseIterable {
        case turnComplete = "turn-complete"
    }
    /// The event type. Always ``turn-complete``.
    public var _type: TurnCompleteEvent._TypePayload
    init(
        role: TranscriptRole,
        _type: TurnCompleteEvent._TypePayload
    ) {
        self.role = role
        self._type = _type
    }
    enum CodingKeys: String, CodingKey {
        case role
        case _type = "type"
    }
}

/// Model decided to invoke a server-executed tool.
///
/// Three-event lifecycle:
///   ``tool-call`` (model decided)
///     → ``tool-dispatch-started`` (server-side handler began)
///     → ``tool-result`` (completed).
public struct ToolCallEvent: Codable, Hashable, Sendable {
    /// Name of the tool being invoked.
    public var name: Swift.String
    /// Stable per-invocation id (the upstream's function-call id). Use this
    /// to correlate the ``tool-call`` / ``tool-dispatch-started`` /
    /// ``tool-result`` triple for one invocation. Distinct from the
    /// message-level ``id``.
    public var toolCallId: Swift.String
    /// The event type. Always ``tool-call``.
    @frozen public enum _TypePayload: String, Codable, Hashable, Sendable, CaseIterable {
        case toolCall = "tool-call"
    }
    /// The event type. Always ``tool-call``.
    public var _type: ToolCallEvent._TypePayload
    init(
        name: Swift.String,
        toolCallId: Swift.String,
        _type: ToolCallEvent._TypePayload
    ) {
        self.name = name
        self.toolCallId = toolCallId
        self._type = _type
    }
    enum CodingKeys: String, CodingKey {
        case name
        case toolCallId = "tool_call_id"
        case _type = "type"
    }
}

/// Server-side handler for the tool call began executing.
///
/// Sits between ``tool-call`` and ``tool-result`` to let UIs show a
/// "dispatching…" state — useful for slow tools where the gap between
/// model decision and result is multiple seconds.
public struct ToolDispatchStartedEvent: Codable, Hashable, Sendable {
    /// Name of the tool that started executing.
    public var name: Swift.String
    /// Correlates with the ``tool-call`` that opened this invocation.
    public var toolCallId: Swift.String
    /// The event type. Always ``tool-dispatch-started``.
    @frozen public enum _TypePayload: String, Codable, Hashable, Sendable, CaseIterable {
        case toolDispatchStarted = "tool-dispatch-started"
    }
    /// The event type. Always ``tool-dispatch-started``.
    public var _type: ToolDispatchStartedEvent._TypePayload
    init(
        name: Swift.String,
        toolCallId: Swift.String,
        _type: ToolDispatchStartedEvent._TypePayload
    ) {
        self.name = name
        self.toolCallId = toolCallId
        self._type = _type
    }
    enum CodingKeys: String, CodingKey {
        case name
        case toolCallId = "tool_call_id"
        case _type = "type"
    }
}

/// Server-side tool finished. ``summary`` is a short human-readable line.
public struct ToolResultEvent: Codable, Hashable, Sendable {
    /// Whether the tool succeeded.
    public var ok: Swift.Bool
    /// Short human-readable line about the outcome, for display.
    public var summary: Swift.String?
    /// Correlates with the ``tool-call`` that opened this invocation.
    public var toolCallId: Swift.String
    /// The event type. Always ``tool-result``.
    @frozen public enum _TypePayload: String, Codable, Hashable, Sendable, CaseIterable {
        case toolResult = "tool-result"
    }
    /// The event type. Always ``tool-result``.
    public var _type: ToolResultEvent._TypePayload
    init(
        ok: Swift.Bool,
        summary: Swift.String? = nil,
        toolCallId: Swift.String,
        _type: ToolResultEvent._TypePayload
    ) {
        self.ok = ok
        self.summary = summary
        self.toolCallId = toolCallId
        self._type = _type
    }
    enum CodingKeys: String, CodingKey {
        case ok
        case summary
        case toolCallId = "tool_call_id"
        case _type = "type"
    }
}

/// Server is transparently rotating the upstream session.
///
/// Emitted after the upstream signals an imminent shutdown when the server
/// has cached a resumption handle and is reopening the model session. The
/// transport and session state survive the swap; clients can show a brief
/// "reconnecting…" indicator and otherwise stay put.
public struct ReconnectingEvent: Codable, Hashable, Sendable {
    /// Rough seconds until the swap completes, when the upstream reports
    /// it. ``None`` when it does not.
    public var secondsRemaining: Swift.Double?
    /// The event type. Always ``reconnecting``.
    @frozen public enum _TypePayload: String, Codable, Hashable, Sendable, CaseIterable {
        case reconnecting = "reconnecting"
    }
    /// The event type. Always ``reconnecting``.
    public var _type: ReconnectingEvent._TypePayload
    init(
        secondsRemaining: Swift.Double? = nil,
        _type: ReconnectingEvent._TypePayload
    ) {
        self.secondsRemaining = secondsRemaining
        self._type = _type
    }
    enum CodingKeys: String, CodingKey {
        case secondsRemaining = "seconds_remaining"
        case _type = "type"
    }
}

/// The server will end this session shortly (e.g. the max-duration cap
/// is about to fire). Clients may show a countdown; the session keeps
/// running until ``session-ended``.
public struct SessionEndingSoonEvent: Codable, Hashable, Sendable {
    /// Stable slug for why the session is ending (e.g.
    /// ``"max_session_duration"``). The vocabulary is additive: match the
    /// slugs you know and treat an unfamiliar one as a plain end.
    public var reason: Swift.String
    /// Seconds until the session is cut, for a countdown.
    public var secondsRemaining: Swift.Double
    /// The event type. Always ``session-ending-soon``.
    @frozen public enum _TypePayload: String, Codable, Hashable, Sendable, CaseIterable {
        case sessionEndingSoon = "session-ending-soon"
    }
    /// The event type. Always ``session-ending-soon``.
    public var _type: SessionEndingSoonEvent._TypePayload
    init(
        reason: Swift.String,
        secondsRemaining: Swift.Double,
        _type: SessionEndingSoonEvent._TypePayload
    ) {
        self.reason = reason
        self.secondsRemaining = secondsRemaining
        self._type = _type
    }
    enum CodingKeys: String, CodingKey {
        case reason
        case secondsRemaining = "seconds_remaining"
        case _type = "type"
    }
}

/// Recoverable or terminal error. Clients switch on ``code`` for
/// recovery UX.
///
/// ``fatal=True`` signals the session is dead; the client should tear down
/// and reconnect rather than retry the current turn. ``fatal=False`` means
/// this turn failed but the session can continue.
public struct ErrorEvent: Codable, Hashable, Sendable {
    /// Stable code to switch on for recovery. Match this, not
    /// ``message``.
    public var code: ErrorCode
    /// ``true`` means the session is dead and must be torn down; ``false``
    /// means only this turn failed.
    public var fatal: Swift.Bool
    /// Human-readable explanation, for logs and display.
    public var message: Swift.String
    /// The event type. Always ``error``.
    @frozen public enum _TypePayload: String, Codable, Hashable, Sendable, CaseIterable {
        case error = "error"
    }
    /// The event type. Always ``error``.
    public var _type: ErrorEvent._TypePayload
    init(
        code: ErrorCode,
        fatal: Swift.Bool,
        message: Swift.String,
        _type: ErrorEvent._TypePayload
    ) {
        self.code = code
        self.fatal = fatal
        self.message = message
        self._type = _type
    }
    enum CodingKeys: String, CodingKey {
        case code
        case fatal
        case message
        case _type = "type"
    }
    /// Decodes an error from the wire; an omitted ``fatal`` decodes as
    /// ``false``.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(ErrorCode.self, forKey: .code)
        fatal = try container.decodeIfPresent(Swift.Bool.self, forKey: .fatal) ?? false
        message = try container.decode(Swift.String.self, forKey: .message)
        _type = try container.decode(ErrorEvent._TypePayload.self, forKey: ._type)
    }
}

/// Stable error codes carried on wire-protocol error events; clients
/// switch on them to choose recovery behavior. Distinct from the REST
/// rejection codes carried on error envelopes (``error.code``).
/// The set is the server's, not this SDK's, so a deployment newer than your
/// package can send a code this version does not name. It arrives as
/// ``unknown(_:)`` carrying the raw string rather than failing to decode —
/// an unrecognized code would otherwise cost the whole error event, which is
/// the surface a caller needs most when something has already gone wrong.
/// Switch on the cases you know and let a `default` carry the rest.
///
/// ``allCases`` lists the codes this version names; ``unknown(_:)`` is not
/// among them, so iterating stays meaningful.
public enum ErrorCode: RawRepresentable, Codable, Hashable, Sendable, CaseIterable {
    case authFailed
    case workspaceForbidden
    case voiceDisabled
    case upstreamDisconnect
    case internalError
    case invalidMessage
    case versionMismatch
    /// A code added to the server after this package shipped, verbatim.
    case unknown(String)

    public static var allCases: [ErrorCode] {
        [
            .authFailed,
            .workspaceForbidden,
            .voiceDisabled,
            .upstreamDisconnect,
            .internalError,
            .invalidMessage,
            .versionMismatch,
        ]
    }

    public var rawValue: String {
        switch self {
        case .authFailed: return "auth_failed"
        case .workspaceForbidden: return "workspace_forbidden"
        case .voiceDisabled: return "voice_disabled"
        case .upstreamDisconnect: return "upstream_disconnect"
        case .internalError: return "internal_error"
        case .invalidMessage: return "invalid_message"
        case .versionMismatch: return "version_mismatch"
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

/// One tool spec the server refused, with the reason — so a client can
/// log *why* a spec was dropped instead of debugging silence.
public struct RejectedTool: Codable, Hashable, Sendable {
    /// What the dropped tool was called — a client tool's declared name, or a
    /// server tool's wire kind.
    public var name: Swift.String
    /// Why it was unavailable, e.g. a capability this workspace has not
    /// enabled. Free text for logs and display, not a stable code to match
    /// on.
    public var reason: Swift.String
    init(
        name: Swift.String,
        reason: Swift.String
    ) {
        self.name = name
        self.reason = reason
    }
    enum CodingKeys: String, CodingKey {
        case name
        case reason
    }
}

/// Resolved-agent summary echoed on ``ready`` when the session referenced a
/// registry agent (``agent.name``). Informational only — never authoritative;
/// clients don't act on it.
public struct ResolvedAgent: Codable, Hashable, Sendable {
    /// The registry agent the session resolved against.
    public var name: Swift.String
    /// Final effective tool names (registry tools ∪ client-declared tools,
    /// by name).
    public var tools: [Swift.String]?
    init(
        name: Swift.String,
        tools: [Swift.String]? = nil
    ) {
        self.name = name
        self.tools = tools
    }
    enum CodingKeys: String, CodingKey {
        case name
        case tools
    }
}

/// First-party cosmo event: cumulative token usage for the live session,
/// split by direction and modality. Emitted for any external session whose
/// upstream reports usage — translation is stateless, not gated on the
/// ``cosmo`` config block.
public struct UsageEvent: Codable, Hashable, Sendable {
    /// Audio tokens sent to the model so far this session.
    public var inputAudioTokens: Swift.Int
    /// Input tokens served from the provider's cache, already counted in the
    /// input totals above.
    public var inputCachedTokens: Swift.Int
    /// Image tokens sent to the model so far this session.
    public var inputImageTokens: Swift.Int
    /// Text tokens sent to the model so far this session.
    public var inputTextTokens: Swift.Int
    /// Audio tokens the model produced so far this session.
    public var outputAudioTokens: Swift.Int
    /// Text tokens the model produced so far this session.
    public var outputTextTokens: Swift.Int
    /// Every token counted above, as the provider reports the total.
    public var totalTokens: Swift.Int
    /// The event type. Always ``cosmo.usage``.
    @frozen public enum _TypePayload: String, Codable, Hashable, Sendable, CaseIterable {
        case cosmo_usage = "cosmo.usage"
    }
    /// The event type. Always ``cosmo.usage``.
    public var _type: UsageEvent._TypePayload
    init(
        inputAudioTokens: Swift.Int,
        inputCachedTokens: Swift.Int,
        inputImageTokens: Swift.Int,
        inputTextTokens: Swift.Int,
        outputAudioTokens: Swift.Int,
        outputTextTokens: Swift.Int,
        totalTokens: Swift.Int,
        _type: UsageEvent._TypePayload
    ) {
        self.inputAudioTokens = inputAudioTokens
        self.inputCachedTokens = inputCachedTokens
        self.inputImageTokens = inputImageTokens
        self.inputTextTokens = inputTextTokens
        self.outputAudioTokens = outputAudioTokens
        self.outputTextTokens = outputTextTokens
        self.totalTokens = totalTokens
        self._type = _type
    }
    enum CodingKeys: String, CodingKey {
        case inputAudioTokens = "input_audio_tokens"
        case inputCachedTokens = "input_cached_tokens"
        case inputImageTokens = "input_image_tokens"
        case inputTextTokens = "input_text_tokens"
        case outputAudioTokens = "output_audio_tokens"
        case outputTextTokens = "output_text_tokens"
        case totalTokens = "total_tokens"
        case _type = "type"
    }
    /// Decodes a usage event from the wire; an omitted counter decodes
    /// as ``0``.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputAudioTokens = try container.decodeIfPresent(Swift.Int.self, forKey: .inputAudioTokens) ?? 0
        inputCachedTokens = try container.decodeIfPresent(Swift.Int.self, forKey: .inputCachedTokens) ?? 0
        inputImageTokens = try container.decodeIfPresent(Swift.Int.self, forKey: .inputImageTokens) ?? 0
        inputTextTokens = try container.decodeIfPresent(Swift.Int.self, forKey: .inputTextTokens) ?? 0
        outputAudioTokens = try container.decodeIfPresent(Swift.Int.self, forKey: .outputAudioTokens) ?? 0
        outputTextTokens = try container.decodeIfPresent(Swift.Int.self, forKey: .outputTextTokens) ?? 0
        totalTokens = try container.decodeIfPresent(Swift.Int.self, forKey: .totalTokens) ?? 0
        _type = try container.decode(UsageEvent._TypePayload.self, forKey: ._type)
    }
}

/// A server-runtime silence timeout fired: the user was silent past a
/// configured threshold and the server performed `action`. Observability only.
public struct UserSpeechTimeoutEvent: Codable, Hashable, Sendable {
    /// What the server did in response.
    @_documentation(visibility: internal) @frozen public enum ActionPayload: Codable, Hashable, Sendable {
        case endCall(EndCall)
        case say(Say)
        enum CodingKeys: String, CodingKey {
            case _type = "type"
        }
        public init(from decoder: any Swift.Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let discriminator = try container.decode(
                Swift.String.self,
                forKey: ._type
            )
            switch discriminator {
            case "end_call":
                self = .endCall(try .init(from: decoder))
            case "say":
                self = .say(try .init(from: decoder))
            default:
                throw Swift.DecodingError.dataCorrupted(
            .init(
                codingPath: decoder.codingPath,
                debugDescription: "unknown discriminator value: \(discriminator)"
            )
        )
            }
        }
        public func encode(to encoder: any Swift.Encoder) throws {
            switch self {
            case let .endCall(value):
                try value.encode(to: encoder)
            case let .say(value):
                try value.encode(to: encoder)
            }
        }
    }
    /// What the server did in response.
    public var action: UserSpeechTimeoutEvent.ActionPayload
    /// The hook's nudge ceiling. It goes quiet after the last one rather
    /// than escalating; under ``reset_mode: on_user_speech`` the count resets on
    /// user speech, so this bounds one run of silence, not the session.
    public var maxCount: Swift.Int
    /// Session the timeout fired on.
    public var sessionId: Swift.String
    /// Silence accrued in the window that fired. The clock restarts after
    /// each firing, so on a second or later nudge this measures from the
    /// previous one, not from the last time the user spoke.
    public var silenceMs: Swift.Int
    /// Which firing this is in the current run, from one. Under
    /// ``reset_mode: on_user_speech`` the count restarts when the user speaks,
    /// so it can return to one within a session.
    public var triggerCount: Swift.Int
    /// The event type. Always ``user-speech-timeout``.
    @frozen public enum _TypePayload: String, Codable, Hashable, Sendable, CaseIterable {
        case userSpeechTimeout = "user-speech-timeout"
    }
    /// The event type. Always ``user-speech-timeout``.
    public var _type: UserSpeechTimeoutEvent._TypePayload
    init(
        action: UserSpeechTimeoutEvent.ActionPayload,
        maxCount: Swift.Int,
        sessionId: Swift.String,
        silenceMs: Swift.Int,
        triggerCount: Swift.Int,
        _type: UserSpeechTimeoutEvent._TypePayload
    ) {
        self.action = action
        self.maxCount = maxCount
        self.sessionId = sessionId
        self.silenceMs = silenceMs
        self.triggerCount = triggerCount
        self._type = _type
    }
    enum CodingKeys: String, CodingKey {
        case action
        case maxCount = "max_count"
        case sessionId = "session_id"
        case silenceMs = "silence_ms"
        case triggerCount = "trigger_count"
        case _type = "type"
    }
}

/// The voice model decided the user's request needs work done and
/// handed it to your application. Do the work, then answer with the
/// ``RealtimeSession/appendThinking(_:delegationId:)`` family carrying
/// this event's id; the model keeps talking with the user meanwhile.
public struct DelegationCreatedEvent: Codable, Hashable, Sendable {
    /// Identifies this hand-off. Pass it on every append that answers it.
    public var delegationId: Swift.String
    /// What the user said in the turn that prompted the hand-off. Earlier
    /// turns are yours to keep from the ``transcript`` events.
    public var transcript: Swift.String
    /// The event type. Always ``delegation-created``.
    @frozen public enum _TypePayload: String, Codable, Hashable, Sendable, CaseIterable {
        case delegationCreated = "delegation-created"
    }
    /// The event type. Always ``delegation-created``.
    public var _type: DelegationCreatedEvent._TypePayload
    init(
        delegationId: Swift.String,
        transcript: Swift.String,
        _type: DelegationCreatedEvent._TypePayload
    ) {
        self.delegationId = delegationId
        self.transcript = transcript
        self._type = _type
    }
    enum CodingKeys: String, CodingKey {
        case delegationId = "delegation_id"
        case transcript
        case _type = "type"
    }
}

/// How an appended text reaches the voice model.
@frozen public enum DelegationChannel: String, Codable, Hashable, Sendable, CaseIterable {
    /// Background the model keeps to itself and draws on when relevant.
    case thinking = "thinking"
    /// Something for the model to say now, in its own words.
    case commentary = "commentary"
    /// Guidance that changes how the model behaves from here on.
    case instructions = "instructions"
}

/// Which runtime authored a tool invocation. Closed, like the wire schema
/// and the other SDKs' spellings of it — an unrecognized value fails the
/// event's decode, which surfaces the frame as
/// ``RealtimeSessionEvent/unknown(rawType:payload:)`` rather than as a typed
/// event carrying a value the protocol forbids.
public enum ToolInvocationOrigin: String, Sendable, Equatable, Codable {
    /// The live model on this session asked for the call.
    case realtime
    /// A server-side agent working on the session's behalf reached the same
    /// client tool.
    case server
}

/// Observability record of the server invoking a declared client tool.
///
/// Hand-written over the generated wire type so ``args`` is a plain
/// dictionary rather than the generator's opaque additional-properties
/// container.
public struct ToolInvocationEvent: Sendable, Equatable, Codable {
    /// Identifies this notification. Minted fresh for the event and unrelated
    /// to the call's own transport-level request, so it is not a handle to
    /// reply on.
    public let requestId: String
    /// The model's own id for the call, shared with the ``toolCall(_:)``
    /// lifecycle.
    public let toolCallId: String
    /// Name of the client tool being invoked.
    public let name: String
    /// Decoded tool-call arguments. Empty when the wire omits them.
    public let args: [String: JSONValue]
    /// Which runtime dispatched the invocation (wire default: `realtime`).
    public let origin: ToolInvocationOrigin
    /// Whether a local handler is registered for the tool.
    public let executable: Bool

    /// Creates an invocation event. The SDK builds these from the wire; you
    /// receive one.
    public init(
        requestId: String,
        toolCallId: String,
        name: String,
        args: [String: JSONValue] = [:],
        origin: ToolInvocationOrigin = .realtime,
        executable: Bool = true
    ) {
        self.requestId = requestId
        self.toolCallId = toolCallId
        self.name = name
        self.args = args
        self.origin = origin
        self.executable = executable
    }

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case toolCallId = "tool_call_id"
        case name
        case args
        case origin
        case executable
    }

    /// Decodes an invocation from the wire, defaulting the fields the
    /// server may omit.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try container.decode(String.self, forKey: .requestId)
        toolCallId = try container.decode(String.self, forKey: .toolCallId)
        name = try container.decode(String.self, forKey: .name)
        args = try container.decodeIfPresent([String: JSONValue].self, forKey: .args) ?? [:]
        origin = try container.decodeIfPresent(ToolInvocationOrigin.self, forKey: .origin) ?? .realtime
        executable = try container.decodeIfPresent(Bool.self, forKey: .executable) ?? true
    }
}

/// Terminal sentinel for ``RealtimeSessionEvent/sessionEnded(_:)``. The
/// server publishes a ``session-ended`` wire frame best-effort before a
/// deliberate teardown; the SDK latches its reason and never surfaces
/// the frame mid-stream. The transport close remains the terminal
/// signal — the SDK synthesizes this local sentinel as the final
/// element of ``RealtimeSession/events``, carrying the latched reason
/// when one arrived.
public struct SessionEndedEvent: Sendable, Equatable {
    /// Why the session ended, when known.
    public let reason: String?
    /// Creates a terminal event. The SDK synthesizes these; you receive one.
    public init(reason: String?) { self.reason = reason }
}

/// One server event from ``RealtimeSession/events``.
///
/// Forward compatibility: a frame with an unrecognized ``type`` —
/// or one whose payload fails to decode against the known schema —
/// surfaces as ``unknown(rawType:payload:)`` and the session keeps
/// running. Decode failure is never terminal.
///
/// ``sessionEnded(_:)`` is the final element of the stream; the
/// sequence finishes after it.
@frozen
public enum RealtimeSessionEvent: Sendable {
    /// The upstream session is established and the agent is ready
    /// for input. Carries the ``sessionId`` and any soft-rejected
    /// tool specs.
    case ready(ReadyEvent)
    /// Streaming transcript fragment (delta while ``isFinal`` is
    /// false; cumulative full text on the final event).
    case transcript(TranscriptDeltaEvent)
    /// The session-owned coalesced transcript changed; carries the full
    /// updated item list. Session-synthesized after each fold — like
    /// ``sessionEnded(_:)``, not a wire frame.
    case transcriptUpdated(TranscriptUpdatedEvent)
    /// Text-channel fragment from the model (distinct from the
    /// spoken-audio transcript).
    case modelText(ModelTextEvent)
    /// A turn finished, after its transcript and tool activity.
    case turnComplete(TurnCompleteEvent)
    /// Voice-activity detection heard the user begin speaking. For UI only
    /// — the microphone keeps streaming, so overlapping speech is captured.
    case userStartedSpeaking
    /// Voice-activity detection saw the user stop speaking. Not necessarily
    /// the end of their turn — the turn detector decides that separately, and
    /// a mid-thought pause can hold the turn open.
    case userStoppedSpeaking
    /// The first audio frame of an assistant turn left the server. For UI
    /// only — do not gate the microphone on it.
    case botStartedSpeaking
    /// The assistant's audio finished.
    case botStoppedSpeaking
    /// The model began generating its turn, which can precede any audio —
    /// useful for a "thinking" indicator while tool calls run.
    case botLlmStarted
    /// The model finished generating — which is not the turn ending;
    /// ``turnComplete`` marks that. Where this falls relative to the turn's
    /// final transcript depends on the upstream pipeline, so drive turn
    /// state off ``turnComplete`` rather than off their order.
    case botLlmStopped
    /// Speech synthesis started, immediately before ``botStartedSpeaking``
    /// — one moment, not two, so do not time the gap between them.
    case botTtsStarted
    /// Speech synthesis finished, immediately before ``botStoppedSpeaking``.
    case botTtsStopped
    /// Model decided to invoke a server-executed tool.
    case toolCall(ToolCallEvent)
    /// The server-side handler for that call began executing. Sits between
    /// ``toolCall(_:)`` and ``toolResult(_:)`` so a UI can show progress on a
    /// slow tool.
    case toolDispatchStarted(ToolDispatchStartedEvent)
    /// The tool call finished. Last of the three keyed by the call id.
    case toolResult(ToolResultEvent)
    /// Observability: the server invoked a declared client tool.
    /// Execution and the reply happen via the tool's local handler
    /// over the transport (LiveKit RPC), not a send on this stream.
    case toolInvocation(ToolInvocationEvent)
    /// Server is transparently rotating the upstream session.
    case reconnecting(ReconnectingEvent)
    /// The server will end this session shortly (e.g. the max-duration
    /// cap is about to fire). Carries ``SessionEndingSoonEvent/secondsRemaining``
    /// and a stable ``SessionEndingSoonEvent/reason`` slug; the session
    /// keeps running until ``sessionEnded(_:)``.
    case sessionEndingSoon(SessionEndingSoonEvent)
    /// Cumulative token usage for the session (wire ``cosmo.usage``).
    /// The server emits these for first-party sessions; delivery is not
    /// gated on the client having sent a `cosmo` block on
    /// `session-config`.
    case usage(UsageEvent)
    /// Observability: a server-runtime silence hook fired. ``action``
    /// reports what the server already did (say / end call).
    case userSpeechTimeout(UserSpeechTimeoutEvent)
    /// The model handed the user's request to your application. Answer
    /// with ``RealtimeSession/appendThinking(_:delegationId:)``,
    /// ``RealtimeSession/appendCommentary(_:delegationId:)`` or
    /// ``RealtimeSession/appendInstructions(_:delegationId:)`` carrying
    /// ``DelegationCreatedEvent/delegationId``.
    case delegationCreated(DelegationCreatedEvent)
    /// Terminal: the session is over; the stream finishes after
    /// this element.
    case sessionEnded(SessionEndedEvent)
    /// Recoverable or terminal error — switch on ``ErrorEvent/fatal``.
    case error(ErrorEvent)
    /// Reply to a ping. Its arrival is the whole signal; it carries nothing.
    case pong
    /// A frame the SDK could not interpret: ``rawType`` is the wire
    /// ``type`` (``nil`` when the frame was not decodable JSON at
    /// all); ``payload`` is the raw frame bytes.
    case unknown(rawType: String?, payload: Data)
}

extension RealtimeSession {
    /// Result of classifying one raw inbound frame.
    enum ClassifiedFrame {
        case envelopeChunk(envelopeId: String, seq: Int, total: Int, data: String)
        /// The server's best-effort ``session-ended`` frame: latched by the
        /// session for the terminal reason, never yielded as a stream event.
        case serverSessionEnded(reason: String?)
        case event(RealtimeSessionEvent)
    }

    /// Decode a raw server frame into a ``RealtimeSessionEvent`` (or an
    /// envelope chunk for the reassembler). Tolerant by construction:
    /// anything unrecognized or undecodable becomes
    /// ``RealtimeSessionEvent/unknown(rawType:payload:)``.
    static func classifyFrame(_ data: Data) -> ClassifiedFrame {
        struct TypeProbe: Decodable {
            let type: String
        }
        let decoder = JSONDecoder()
        guard let probe = try? decoder.decode(TypeProbe.self, from: data) else {
            return .event(.unknown(rawType: nil, payload: data))
        }

        func decodePayload<T: Decodable>(
            _ type: T.Type, _ project: (T) -> RealtimeSessionEvent
        ) -> ClassifiedFrame {
            guard let value = try? decoder.decode(type, from: data) else {
                log.warning("frame decode failed type=\(probe.type, privacy: .public); surfacing as unknown event")
                return .event(.unknown(rawType: probe.type, payload: data))
            }
            return .event(project(value))
        }

        switch probe.type {
        case "server-envelope-chunk":
            struct Chunk: Decodable {
                let envelope_id: String
                let seq: Int
                let total: Int
                let data: String
            }
            guard let chunk = try? decoder.decode(Chunk.self, from: data) else {
                return .event(.unknown(rawType: probe.type, payload: data))
            }
            return .envelopeChunk(
                envelopeId: chunk.envelope_id,
                seq: chunk.seq,
                total: chunk.total,
                data: chunk.data
            )
        case "ready":
            return decodePayload(ReadyEvent.self) { .ready($0) }
        case "transcript":
            return decodePayload(TranscriptDeltaEvent.self) { .transcript($0) }
        case "model-text":
            return decodePayload(ModelTextEvent.self) { .modelText($0) }
        case "turn-complete":
            return decodePayload(TurnCompleteEvent.self) { .turnComplete($0) }
        case "user-started-speaking":
            return .event(.userStartedSpeaking)
        case "user-stopped-speaking":
            return .event(.userStoppedSpeaking)
        case "bot-started-speaking":
            return .event(.botStartedSpeaking)
        case "bot-stopped-speaking":
            return .event(.botStoppedSpeaking)
        case "bot-llm-started":
            return .event(.botLlmStarted)
        case "bot-llm-stopped":
            return .event(.botLlmStopped)
        case "bot-tts-started":
            return .event(.botTtsStarted)
        case "bot-tts-stopped":
            return .event(.botTtsStopped)
        case "tool-call":
            return decodePayload(ToolCallEvent.self) { .toolCall($0) }
        case "tool-dispatch-started":
            return decodePayload(ToolDispatchStartedEvent.self) { .toolDispatchStarted($0) }
        case "tool-result":
            return decodePayload(ToolResultEvent.self) { .toolResult($0) }
        case "tool-invocation":
            return decodePayload(ToolInvocationEvent.self) { .toolInvocation($0) }
        case "reconnecting":
            return decodePayload(ReconnectingEvent.self) { .reconnecting($0) }
        case "session-ending-soon":
            return decodePayload(SessionEndingSoonEvent.self) { .sessionEndingSoon($0) }
        case "cosmo.usage":
            return decodePayload(UsageEvent.self) { .usage($0) }
        case "error":
            return decodePayload(ErrorEvent.self) { .error($0) }
        case "user-speech-timeout":
            return decodePayload(UserSpeechTimeoutEvent.self) { .userSpeechTimeout($0) }
        case "delegation-created":
            return decodePayload(DelegationCreatedEvent.self) { .delegationCreated($0) }
        case "session-ended":
            guard
                let ended = try? decoder.decode(
                    CosmoRealtimeAPI.Components.Schemas.SessionEndedEvent.self, from: data
                )
            else {
                return .event(.unknown(rawType: probe.type, payload: data))
            }
            return .serverSessionEnded(reason: ended.reason)
        case "pong":
            return .event(.pong)
        default:
            return .event(.unknown(rawType: probe.type, payload: data))
        }
    }
}
