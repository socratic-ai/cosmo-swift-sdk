import CosmoRealtimeAPI
import Foundation

/// Server-runtime hook: perform `action` after `timeout_seconds` of user
/// silence.
public struct SilenceTimeout: Codable, Hashable, Sendable {
    /// What to do when the timeout fires — speak a line, or end the call.
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
    /// What to do when the timeout fires — speak a line, or end the call.
    public var action: SilenceTimeout.ActionPayload
    /// How many times this hook may fire, 1–10, so a silent caller is not
    /// prompted forever. Counted per run of silence when ``reset_mode`` is
    /// ``on_user_speech``, and across the session when it is ``never``.
    public var maxCount: Swift.Int?
    /// Label for this hook, for your own reference and the server's logs. It
    /// is not carried on the event the hook fires, so a session running several
    /// silence hooks cannot tell from the event which one fired.
    public var name: Swift.String?
    /// How much to widen ``timeoutSeconds`` once the caller has spoken at
    /// least once, 1–10, so a present but quiet caller waits longer than a
    /// line that was silent from the start. ``1`` waits the same either way.
    /// `nil` uses the server's default.
    public var presentMultiplier: Swift.Double?
    /// Whether the fire count resets. ``never`` counts across the whole
    /// session; ``on_user_speech`` starts over each time the user speaks.
    @_documentation(visibility: internal) @frozen public enum ResetModePayload: String, Codable, Hashable, Sendable, CaseIterable {
        case never = "never"
        case onUserSpeech = "on_user_speech"
    }
    /// Whether the fire count resets. ``never`` counts across the whole
    /// session; ``on_user_speech`` starts over each time the user speaks.
    public var resetMode: SilenceTimeout.ResetModePayload?
    /// Seconds of user silence before the action runs, 1–1000. Scaled by
    /// ``presentMultiplier`` once the caller has spoken at least once.
    public var timeoutSeconds: Swift.Double
    /// What fires the hook. Always ``user.speech.timeout``.
    @_documentation(visibility: internal) @frozen public enum TriggerPayload: String, Codable, Hashable, Sendable, CaseIterable {
        case user_speech_timeout = "user.speech.timeout"
    }
    /// What fires the hook. Always ``user.speech.timeout``.
    public var trigger: SilenceTimeout.TriggerPayload?
    /// Creates a new `SilenceTimeout`.
    ///
    /// - Parameters:
    ///   - action: What to do when the timeout fires — speak a line, or end the call.
    ///   - maxCount: How many times this hook may fire, 1–10, so a silent caller is not
    ///   - name: Label for this hook, for your own reference and the server's logs. It
    ///   - presentMultiplier: How much to widen ``timeoutSeconds`` once the caller has spoken at
    ///   - resetMode: Whether the fire count resets. ``never`` counts across the whole
    ///   - timeoutSeconds: Seconds of user silence before the action runs, 1–1000. Scaled by
    ///   - trigger: What fires the hook. Always ``user.speech.timeout``.
    @_documentation(visibility: internal) public init(
        action: SilenceTimeout.ActionPayload,
        maxCount: Swift.Int? = nil,
        name: Swift.String? = nil,
        presentMultiplier: Swift.Double? = nil,
        resetMode: SilenceTimeout.ResetModePayload? = nil,
        timeoutSeconds: Swift.Double,
        trigger: SilenceTimeout.TriggerPayload? = nil
    ) {
        self.action = action
        self.maxCount = maxCount
        self.name = name
        self.presentMultiplier = presentMultiplier
        self.resetMode = resetMode
        self.timeoutSeconds = timeoutSeconds
        self.trigger = trigger
    }
    enum CodingKeys: String, CodingKey {
        case action
        case maxCount = "max_count"
        case name
        case presentMultiplier = "present_multiplier"
        case resetMode = "reset_mode"
        case timeoutSeconds = "timeout_seconds"
        case trigger
    }
    public init(from decoder: any Swift.Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.action = try container.decode(
            SilenceTimeout.ActionPayload.self,
            forKey: .action
        )
        self.maxCount = try container.decodeIfPresent(
            Swift.Int.self,
            forKey: .maxCount
        )
        self.name = try container.decodeIfPresent(
            Swift.String.self,
            forKey: .name
        )
        self.presentMultiplier = try container.decodeIfPresent(
            Swift.Double.self,
            forKey: .presentMultiplier
        )
        self.resetMode = try container.decodeIfPresent(
            SilenceTimeout.ResetModePayload.self,
            forKey: .resetMode
        )
        self.timeoutSeconds = try container.decode(
            Swift.Double.self,
            forKey: .timeoutSeconds
        )
        self.trigger = try container.decodeIfPresent(
            SilenceTimeout.TriggerPayload.self,
            forKey: .trigger
        )
        try decoder.ensureNoUnknownKeys(knownKeys: [
            "action",
            "max_count",
            "name",
            "present_multiplier",
            "reset_mode",
            "timeout_seconds",
            "trigger"
        ])
    }
}

/// Idle-message action for a server hook: `text` = exact words,
/// `prompt` = model-generated per instruction, both unset = free model speech.
public struct Say: Codable, Hashable, Sendable {
    /// Instruction the model composes its line from, for wording that follows
    /// what has been said so far. Mutually exclusive with ``text``.
    public var prompt: Swift.String?
    /// Exact words for the assistant to speak. Mutually exclusive with
    /// ``prompt``.
    public var text: Swift.String?
    /// The action type. Always ``say``.
    @frozen public enum _TypePayload: String, Codable, Hashable, Sendable, CaseIterable {
        case say = "say"
    }
    /// The action type. Always ``say``.
    public var _type: Say._TypePayload
    /// Creates a new `Say`.
    ///
    /// - Parameters:
    ///   - prompt: Instruction the model composes its line from, for wording that follows
    ///   - text: Exact words for the assistant to speak. Mutually exclusive with
    ///   - _type: The action type. Always ``say``.
    @_documentation(visibility: internal) public init(
        prompt: Swift.String? = nil,
        text: Swift.String? = nil,
        _type: Say._TypePayload
    ) {
        self.prompt = prompt
        self.text = text
        self._type = _type
    }
    enum CodingKeys: String, CodingKey {
        case prompt
        case text
        case _type = "type"
    }
    public init(from decoder: any Swift.Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.prompt = try container.decodeIfPresent(
            Swift.String.self,
            forKey: .prompt
        )
        self.text = try container.decodeIfPresent(
            Swift.String.self,
            forKey: .text
        )
        self._type = try container.decode(
            Say._TypePayload.self,
            forKey: ._type
        )
        try decoder.ensureNoUnknownKeys(knownKeys: [
            "prompt",
            "text",
            "type"
        ])
    }
}

/// End-call action for a server hook.
public struct EndCall: Codable, Hashable, Sendable {
    /// Parting line to speak before hanging up. ``None`` ends the call
    /// without one.
    public var farewell: Swift.String?
    /// The action type. Always ``end_call``.
    @frozen public enum _TypePayload: String, Codable, Hashable, Sendable, CaseIterable {
        case endCall = "end_call"
    }
    /// The action type. Always ``end_call``.
    public var _type: EndCall._TypePayload
    /// Creates a new `EndCall`.
    ///
    /// - Parameters:
    ///   - farewell: Parting line to speak before hanging up. ``None`` ends the call
    ///   - _type: The action type. Always ``end_call``.
    @_documentation(visibility: internal) public init(
        farewell: Swift.String? = nil,
        _type: EndCall._TypePayload
    ) {
        self.farewell = farewell
        self._type = _type
    }
    enum CodingKeys: String, CodingKey {
        case farewell
        case _type = "type"
    }
    public init(from decoder: any Swift.Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.farewell = try container.decodeIfPresent(
            Swift.String.self,
            forKey: .farewell
        )
        self._type = try container.decode(
            EndCall._TypePayload.self,
            forKey: ._type
        )
        try decoder.ensureNoUnknownKeys(knownKeys: [
            "farewell",
            "type"
        ])
    }
}

/// How readily user speech interrupts the assistant mid-turn.
/// Which filter cleans the user's inbound audio before the model hears it.
///
/// ``denoise`` removes non-speech noise and keeps every voice in the room —
/// the mode for a microphone several people share. ``voiceFocus`` also
/// removes competing *voices*, keeping only the one it judges primary, which
/// is what a single-speaker setup wants and what a shared microphone must
/// avoid: to it, the second person is background.
@frozen public enum NoiseCancellation: String, Codable, Hashable, Sendable, CaseIterable {
    case off = "off"
    case denoise = "denoise"
    case voiceFocus = "voice_focus"
}

@frozen public enum InterruptionSensitivity: String, Codable, Hashable, Sendable, CaseIterable {
    case _default = "default"
    case high = "high"
    case low = "low"
}

/// Whether the Grok Voice model reasons before speaking.
///
/// Grok's own default is ``high``, which buys deliberate answers at
/// multi-second turn latency; ``none`` answers immediately.
@frozen public enum GrokReasoningEffort: String, Codable, Hashable, Sendable, CaseIterable {
    case high = "high"
    case none = "none"
}

extension GrokReasoningEffort {
    /// Unambiguous spelling of the wire value ``none``. In optional position
    /// a bare `.none` resolves to `Optional.none` — the knob is omitted and
    /// Grok keeps its reasoning default — so pass `.disabled` (or the fully
    /// qualified `GrokReasoningEffort.none`) to turn reasoning off.
    public static var disabled: Self { .none }
}

/// How hard the Responses model behind GPT Live reasons on delegated work.
@frozen public enum OpenAILiveReasoningEffort: String, Codable, Hashable, Sendable, CaseIterable {
    case minimal = "minimal"
    case low = "low"
    case medium = "medium"
    case high = "high"
}

/// How much the Responses model behind GPT Live writes back for the voice
/// model to say.
@frozen public enum OpenAILiveVerbosity: String, Codable, Hashable, Sendable, CaseIterable {
    case low = "low"
    case medium = "medium"
    case high = "high"
}

/// Whether the Responses model behind GPT Live must call a tool on each
/// delegated turn.
@frozen public enum OpenAILiveToolChoice: String, Codable, Hashable, Sendable, CaseIterable {
    case auto = "auto"
    case required = "required"
    case none = "none"
}

/// OpenAI processing tier for the Responses model behind GPT Live.
@frozen public enum OpenAILiveServiceTier: String, Codable, Hashable, Sendable, CaseIterable {
    case auto = "auto"
    case _default = "default"
    case flex = "flex"
    case priority = "priority"
}

/// Where GPT Live sends the work it decides a turn needs. The voice
/// model itself only listens and speaks.
@frozen public enum OpenAILiveDelegation: String, Codable, Hashable, Sendable, CaseIterable {
    /// A backend Responses model, configured by the ``responses…`` knobs,
    /// runs the reasoning and the agent's tools.
    case responses = "responses"
    /// Your application does the work. Each hand-off arrives as a
    /// ``RealtimeSessionEvent/delegationCreated(_:)`` event carrying the
    /// user's request; you answer through the ``RealtimeSession/appendThinking(_:delegationId:)``
    /// family. No tools run on the model, so an agent under client
    /// delegation declares none.
    case client = "client"
    /// Cosmo's workspace agent does the work on the server, with the
    /// workspace's tools and skills, and speaks its findings back through
    /// the voice model. Each hand-off still arrives as a
    /// ``RealtimeSessionEvent/delegationCreated(_:)`` event, and appends
    /// still steer the model.
    case cosmo = "cosmo"
}

/// Reasoning depth for Gemini models.
///
/// The server maps it onto the upstream enum; ``nil`` leaves the server
/// default in place.
@frozen public enum ThinkingLevel: String, Codable, Hashable, Sendable, CaseIterable {
    case minimal = "minimal"
    case low = "low"
    case medium = "medium"
    case high = "high"
}

/// How readily the provider decides the user's turn ended under
/// ``TurnDetectionMode/serverVad``, the end-of-turn counterpart to the
/// start-of-speech sensitivity ``InterruptionSensitivity`` drives.
///
/// ``high`` ends the turn sooner — lower endpointing latency, more likely
/// to cut in on a mid-thought pause. ``nil`` keeps the provider default.
@frozen public enum EndOfSpeechSensitivity: String, Codable, Hashable, Sendable, CaseIterable {
    case low = "low"
    case high = "high"
}

/// How eagerly OpenAI's ``TurnDetectionMode/semanticVad`` closes the user's
/// turn.
///
/// ``low`` waits longer for the user to continue, ``high`` responds sooner;
/// ``auto`` is the provider default and behaves like ``medium``.
@frozen public enum SemanticEagerness: String, Codable, Hashable, Sendable, CaseIterable {
    case low = "low"
    case medium = "medium"
    case high = "high"
    case auto = "auto"
}

/// Which turn detector ends the user's turn.
///
/// ``serverVad`` ends it on silence; ``semanticVad`` ends it when the
/// utterance reads as complete (OpenAI-only); ``cosmoVad`` runs Cosmo's own
/// semantic detector in the realtime worker (Gemini-only). ``nil`` keeps the
/// provider default: ``serverVad`` on OpenAI and Grok, ``cosmoVad`` on
/// Gemini.
@frozen public enum TurnDetectionMode: String, Codable, Hashable, Sendable, CaseIterable {
    case serverVad = "server_vad"
    case semanticVad = "semantic_vad"
    case cosmoVad = "cosmo_vad"
}

/// How the agent sounds: the prebuilt voice and the per-run speaking
/// style.
public struct VoiceConfig: Sendable, Equatable {
    /// Provider-specific prebuilt voice id. ``nil`` lets the upstream
    /// pick per session — the voice then drifts between connects.
    public var name: String?
    /// A "how to speak" instruction appended to the system prompt (e.g.
    /// warm / delivery / human, or any caller text). ``nil`` keeps the
    /// server default.
    public var speakingStyle: String?

    /// A voice, a speaking style, or both. Omit either to keep the
    /// server's default for it.
    public init(name: String? = nil, speakingStyle: String? = nil) {
        self.name = name
        self.speakingStyle = speakingStyle
    }

    /// ``nil`` when nothing is set, so an empty block stays off the wire.
    var wire: CosmoRealtimeAPI.Components.Schemas.VoiceConfig? {
        if name == nil && speakingStyle == nil { return nil }
        return .init(name: name, speakingStyle: speakingStyle)
    }
}

/// The agent's audio pipeline, configured once — not per run.
public struct AudioConfig: Sendable, Equatable {
    /// Whether the agent emits audio. ``false`` runs the session
    /// text-only: no speech is produced while input transcription and
    /// text output are unaffected. Rejected at session start when the
    /// resolved model cannot run text-only (self-contained
    /// speech-to-speech providers). ``nil`` keeps the server default
    /// (on).
    public var output: Bool?
    /// Which filter cleans the user's inbound audio before the model hears
    /// it. ``nil`` keeps the server default (``off``).
    public var noiseCancellation: NoiseCancellation?

    /// An audio pipeline configured from the knobs you name; anything
    /// omitted keeps the server's default.
    public init(
        output: Bool? = nil,
        noiseCancellation: NoiseCancellation? = nil
    ) {
        self.output = output
        self.noiseCancellation = noiseCancellation
    }

    /// ``nil`` when nothing is set, so an empty block stays off the wire.
    var wire: CosmoRealtimeAPI.Components.Schemas.AudioConfig? {
        if output == nil && noiseCancellation == nil {
            return nil
        }
        return .init(
            noiseCancellation: noiseCancellation.map { .init($0) },
            output: output
        )
    }
}

/// Knobs for Cosmo's own semantic turn detector, read only when it runs
/// (``GeminiModel/turnDetection`` unset or
/// ``GeminiModel/TurnDetection/cosmoVad``). ``nil`` keeps the server
/// default for each.
public struct CosmoVadConfig: Sendable, Equatable {
    /// Silence (ms) that triggers one end-of-turn inference; a mid-thought
    /// pause shorter than it holds the turn open.
    public var pauseMs: Int?
    /// Audio (ms) kept from before speech was detected, so a turn's
    /// opening syllable is not clipped.
    public var prefixMs: Int?
    /// Total silence (ms) after which the turn ends regardless of the
    /// classifier's verdict.
    public var maxHoldMs: Int?

    /// Turn-detector knobs; anything omitted keeps the server's default.
    public init(
        pauseMs: Int? = nil,
        prefixMs: Int? = nil,
        maxHoldMs: Int? = nil
    ) {
        self.pauseMs = pauseMs
        self.prefixMs = prefixMs
        self.maxHoldMs = maxHoldMs
    }

    var wire: CosmoRealtimeAPI.Components.Schemas.CosmoVadConfig {
        .init(maxHoldMs: maxHoldMs, pauseMs: pauseMs, prefixMs: prefixMs)
    }
}

/// Gemini realtime: the concrete model and the knobs Gemini reads. Build
/// one for ``RealtimeModel/gemini(_:)``.
public struct GeminiModel: Sendable, Equatable {
    /// The turn detectors Gemini offers. ``cosmoVad`` is Cosmo's own
    /// semantic detector — it classifies whether the utterance reads as
    /// finished instead of timing a silence window, and is also what runs
    /// when ``GeminiModel/turnDetection`` is unset; ``cosmoVad`` (the
    /// ``GeminiModel/cosmoVad`` field) carries its knobs. ``serverVad`` is
    /// the provider's fixed silence window, tuned by
    /// ``GeminiModel/endOfSpeechSensitivity``,
    /// ``GeminiModel/silenceDurationMs`` and
    /// ``GeminiModel/prefixPaddingMs``.
    public enum TurnDetection: Sendable, Equatable {
        /// Ends the turn as soon as the utterance reads as complete.
        case cosmoVad
        /// Ends the turn after a fixed window of silence.
        case serverVad

        var wire: CosmoRealtimeAPI.Components.Schemas.TurnDetectionMode {
            switch self {
            case .cosmoVad: return .cosmoVad
            case .serverVad: return .serverVad
            }
        }
    }

    /// Concrete Gemini model to run. ``nil`` runs the provider default. A
    /// model id that is not a Gemini model is rejected at session start.
    public var modelId: String?
    /// Sampling temperature (0–2) — higher is more varied, lower more
    /// deterministic. ``nil`` uses the provider default.
    public var temperature: Double?
    /// Cap on tokens per model response. ``nil`` uses the provider
    /// default.
    public var maxOutputTokens: Int?
    /// Reasoning depth. ``nil`` keeps the server's per-mode default.
    public var thinkingLevel: ThinkingLevel?
    /// Stream thought summaries alongside the answer. Only worth enabling
    /// for an app that reads them. ``nil`` keeps the server's per-mode
    /// default.
    public var includeThoughts: Bool?
    /// Which turn detector ends the user's turn. ``nil`` runs Cosmo's
    /// semantic detection; each detector's knobs are unread under the
    /// other, and the server rejects ``TurnDetection/serverVad``'s knobs
    /// alongside an explicit ``TurnDetection/cosmoVad``.
    public var turnDetection: TurnDetection?
    /// How readily the model decides the user's turn ended — ``high``
    /// endpoints sooner, so the assistant answers faster but is more
    /// likely to cut in on a mid-thought pause. Read only under
    /// ``TurnDetection/serverVad``. ``nil`` keeps the provider default.
    public var endOfSpeechSensitivity: EndOfSpeechSensitivity?
    /// Silence (ms, 0–5000) that ends the user's turn. Read only under
    /// ``TurnDetection/serverVad``. ``nil`` keeps the provider default.
    public var silenceDurationMs: Int?
    /// Audio (ms, 0–5000) kept from before speech was detected, so a
    /// turn's opening syllable is not clipped. Read only under
    /// ``TurnDetection/serverVad``. ``nil`` keeps the provider default.
    public var prefixPaddingMs: Int?
    /// Knobs for Cosmo's semantic detector, read only when it runs.
    public var cosmoVad: CosmoVadConfig?

    /// A Gemini model and the knobs Gemini reads. Anything omitted keeps
    /// the server's default.
    public init(
        modelId: String? = nil,
        temperature: Double? = nil,
        maxOutputTokens: Int? = nil,
        thinkingLevel: ThinkingLevel? = nil,
        includeThoughts: Bool? = nil,
        turnDetection: TurnDetection? = nil,
        endOfSpeechSensitivity: EndOfSpeechSensitivity? = nil,
        silenceDurationMs: Int? = nil,
        prefixPaddingMs: Int? = nil,
        cosmoVad: CosmoVadConfig? = nil
    ) {
        self.modelId = modelId
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
        self.thinkingLevel = thinkingLevel
        self.includeThoughts = includeThoughts
        self.turnDetection = turnDetection
        self.endOfSpeechSensitivity = endOfSpeechSensitivity
        self.silenceDurationMs = silenceDurationMs
        self.prefixPaddingMs = prefixPaddingMs
        self.cosmoVad = cosmoVad
    }

    var wire: CosmoRealtimeAPI.Components.Schemas.GeminiModel {
        .init(
            cosmoVad: cosmoVad?.wire,
            endOfSpeechSensitivity: endOfSpeechSensitivity.map { .init($0) },
            includeThoughts: includeThoughts,
            maxOutputTokens: maxOutputTokens,
            modelId: modelId,
            prefixPaddingMs: prefixPaddingMs,
            provider: .gemini,
            silenceDurationMs: silenceDurationMs,
            temperature: temperature,
            thinkingLevel: thinkingLevel.map { .init($0) },
            turnDetection: turnDetection?.wire
        )
    }
}

/// OpenAI Realtime: the concrete model and the knobs OpenAI reads — it
/// pins its own sampling and token limits, so the turn detector and its
/// knobs are the things to tune. Build one for
/// ``RealtimeModel/openai(_:)``.
public struct OpenAIModel: Sendable, Equatable {
    /// The turn detectors OpenAI Realtime offers. ``semanticVad`` ends the
    /// turn as soon as the utterance reads as complete, paced by
    /// ``OpenAIModel/eagerness``; ``serverVad`` ends it after a fixed
    /// window of silence, tuned by ``OpenAIModel/silenceDurationMs`` and
    /// ``OpenAIModel/prefixPaddingMs``.
    public enum TurnDetection: Sendable, Equatable {
        /// Ends the turn as soon as the utterance reads as complete.
        case semanticVad
        /// Ends the turn after a fixed window of silence.
        case serverVad

        var wire: CosmoRealtimeAPI.Components.Schemas.TurnDetectionMode {
            switch self {
            case .semanticVad: return .semanticVad
            case .serverVad: return .serverVad
            }
        }
    }

    /// Concrete OpenAI Realtime model to run. ``nil`` runs the provider
    /// default. A model id that is not an OpenAI Realtime model is
    /// rejected at session start.
    public var modelId: String?
    /// Which turn detector ends the user's turn; each detector's knobs are
    /// unread under the other. ``nil`` keeps the server's default
    /// detector.
    public var turnDetection: TurnDetection?
    /// How eagerly the semantic detector closes the user's turn — ``high``
    /// answers sooner, ``low`` waits longer for the user to continue. Read
    /// only under ``TurnDetection/semanticVad``. ``nil`` keeps the
    /// provider default.
    public var eagerness: SemanticEagerness?
    /// Silence (ms, 0–5000) that ends the user's turn. Read only under
    /// ``TurnDetection/serverVad``. ``nil`` keeps the provider default.
    public var silenceDurationMs: Int?
    /// Audio (ms, 0–5000) kept from before speech was detected, so a
    /// turn's opening syllable is not clipped. Read only under
    /// ``TurnDetection/serverVad``. ``nil`` keeps the provider default.
    public var prefixPaddingMs: Int?

    /// An OpenAI Realtime model and the knobs OpenAI reads. Anything
    /// omitted keeps the server's default.
    public init(
        modelId: String? = nil,
        turnDetection: TurnDetection? = nil,
        eagerness: SemanticEagerness? = nil,
        silenceDurationMs: Int? = nil,
        prefixPaddingMs: Int? = nil
    ) {
        self.modelId = modelId
        self.turnDetection = turnDetection
        self.eagerness = eagerness
        self.silenceDurationMs = silenceDurationMs
        self.prefixPaddingMs = prefixPaddingMs
    }

    var wire: CosmoRealtimeAPI.Components.Schemas.OpenAIModel {
        .init(
            eagerness: eagerness.map { .init($0) },
            modelId: modelId,
            prefixPaddingMs: prefixPaddingMs,
            provider: .openai,
            silenceDurationMs: silenceDurationMs,
            turnDetection: turnDetection?.wire
        )
    }
}

/// OpenAI Realtime mini tier — the same API on a faster, cheaper model,
/// and untunable today beyond the model itself. Build one for
/// ``RealtimeModel/openaiMini(_:)``.
public struct OpenAIMiniModel: Sendable, Equatable {
    /// Concrete model to run. ``nil`` runs the provider default. A model
    /// id outside the mini tier is rejected at session start.
    public var modelId: String?

    /// An OpenAI Realtime mini model. Omit `modelId` for the server's
    /// default.
    public init(modelId: String? = nil) {
        self.modelId = modelId
    }

    var wire: CosmoRealtimeAPI.Components.Schemas.OpenAIMiniModel {
        .init(modelId: modelId, provider: .openaiMini)
    }
}

/// OpenAI's GPT Live full-duplex voice model. It listens and speaks at
/// once and decides itself when each turn starts and ends, so no turn
/// detector is tunable here; tool calls and reasoning are delegated to a
/// backend Responses model, which is what the knobs configure. Audio
/// only: a session on it ignores video and screen frames. A ``voice_…``
/// id on the agent's voice selects an authorized custom voice. Build one
/// for ``RealtimeModel/openaiLive(_:)``.
public struct OpenAILiveModel: Sendable, Equatable {
    /// Concrete GPT Live model to run. ``nil`` runs the provider default.
    public var modelId: String?
    /// The Responses model tool calls and reasoning are delegated to, from
    /// the server's allowlist of small tiers; a model outside it is
    /// rejected at session start. ``nil`` runs the provider default.
    public var responsesModel: String?
    /// Instructions for the Responses model, distinct from the voice
    /// model's. ``nil`` gives it the agent's own instructions.
    public var responsesInstructions: String?
    /// How hard the Responses model reasons on delegated work. ``nil``
    /// keeps OpenAI's default.
    public var reasoningEffort: OpenAILiveReasoningEffort?
    /// How much the Responses model writes back for the voice model to
    /// say. ``nil`` keeps OpenAI's default.
    public var verbosity: OpenAILiveVerbosity?
    /// Whether a delegated turn must call a tool. ``nil`` lets the model
    /// decide (``auto``).
    public var toolChoice: OpenAILiveToolChoice?
    /// Whether one delegated turn may call several tools at once. ``nil``
    /// keeps OpenAI's default.
    public var parallelToolCalls: Bool?
    /// Cap on tokens one delegated response may generate (16–32768).
    /// ``nil`` keeps OpenAI's default.
    public var maxOutputTokens: Int?
    /// OpenAI processing tier for delegated work. ``nil`` keeps OpenAI's
    /// default.
    public var serviceTier: OpenAILiveServiceTier?
    /// Where the work a turn needs is done. ``nil`` keeps the server's
    /// default.
    public var delegation: OpenAILiveDelegation?

    /// A GPT Live model and the knobs of the Responses model behind it.
    /// Anything omitted keeps the server's default.
    public init(
        modelId: String? = nil,
        responsesModel: String? = nil,
        responsesInstructions: String? = nil,
        reasoningEffort: OpenAILiveReasoningEffort? = nil,
        verbosity: OpenAILiveVerbosity? = nil,
        toolChoice: OpenAILiveToolChoice? = nil,
        parallelToolCalls: Bool? = nil,
        maxOutputTokens: Int? = nil,
        serviceTier: OpenAILiveServiceTier? = nil,
        delegation: OpenAILiveDelegation? = nil
    ) {
        self.modelId = modelId
        self.responsesModel = responsesModel
        self.responsesInstructions = responsesInstructions
        self.reasoningEffort = reasoningEffort
        self.verbosity = verbosity
        self.toolChoice = toolChoice
        self.parallelToolCalls = parallelToolCalls
        self.maxOutputTokens = maxOutputTokens
        self.serviceTier = serviceTier
        self.delegation = delegation
    }

    var wire: CosmoRealtimeAPI.Components.Schemas.OpenAILiveModel {
        .init(
            delegation: delegation.map { .init($0) },
            maxOutputTokens: maxOutputTokens,
            modelId: modelId,
            parallelToolCalls: parallelToolCalls,
            provider: .openaiLive,
            reasoningEffort: reasoningEffort.map { .init($0) },
            responsesInstructions: responsesInstructions,
            responsesModel: responsesModel,
            serviceTier: serviceTier.map { .init($0) },
            toolChoice: toolChoice.map { .init($0) },
            verbosity: verbosity.map { .init($0) }
        )
    }
}

/// xAI Grok Voice: the concrete model and the knobs Grok reads — it pins
/// its own sampling and token limits and runs one detector, a fixed
/// silence window. Build one for ``RealtimeModel/grok(_:)``.
public struct GrokModel: Sendable, Equatable {
    /// The one turn detector Grok runs — ``nil`` and ``serverVad`` select
    /// the same fixed silence window, so naming it is only ever explicit.
    public enum TurnDetection: Sendable, Equatable {
        /// Ends the turn after a fixed window of silence.
        case serverVad

        var wire: CosmoRealtimeAPI.Components.Schemas.TurnDetectionMode {
            .serverVad
        }
    }

    /// Concrete Grok model to run. ``nil`` runs the provider default. A
    /// model id that is not a Grok model is rejected at session start.
    public var modelId: String?
    /// Grok's one detector, named explicitly. ``nil`` runs it all the
    /// same.
    public var turnDetection: TurnDetection?
    /// Silence (ms, 0–5000) that ends the user's turn. ``nil`` keeps the
    /// provider default.
    public var silenceDurationMs: Int?
    /// Audio (ms, 0–5000) kept from before speech was detected, so a
    /// turn's opening syllable is not clipped. ``nil`` keeps the provider
    /// default.
    public var prefixPaddingMs: Int?
    /// Whether the model reasons before speaking. Grok's own default is
    /// ``high``, which buys deliberate answers at multi-second turn
    /// latency; ``none`` answers immediately. ``nil`` keeps Grok's
    /// default.
    public var reasoningEffort: GrokReasoningEffort?
    /// Playback-rate multiplier for the agent's speech (0.7–1.5). ``nil``
    /// keeps normal speed.
    public var speed: Double?
    /// Milliseconds of user silence after a response before the server
    /// re-engages the user, re-arming after every response. ``nil`` never
    /// re-engages.
    public var idleTimeoutMs: Int?

    /// A Grok Voice model and the knobs Grok reads. Anything omitted
    /// keeps the server's default.
    public init(
        modelId: String? = nil,
        turnDetection: TurnDetection? = nil,
        silenceDurationMs: Int? = nil,
        prefixPaddingMs: Int? = nil,
        reasoningEffort: GrokReasoningEffort? = nil,
        speed: Double? = nil,
        idleTimeoutMs: Int? = nil
    ) {
        self.modelId = modelId
        self.turnDetection = turnDetection
        self.silenceDurationMs = silenceDurationMs
        self.prefixPaddingMs = prefixPaddingMs
        self.reasoningEffort = reasoningEffort
        self.speed = speed
        self.idleTimeoutMs = idleTimeoutMs
    }

    var wire: CosmoRealtimeAPI.Components.Schemas.GrokModel {
        .init(
            idleTimeoutMs: idleTimeoutMs,
            modelId: modelId,
            prefixPaddingMs: prefixPaddingMs,
            provider: .grok,
            reasoningEffort: reasoningEffort.map { .init($0) },
            silenceDurationMs: silenceDurationMs,
            speed: speed,
            turnDetection: turnDetection?.wire
        )
    }
}

/// What runs on the other end. ``id(_:)`` is a provider family alias
/// (``"gemini"``, ``"openai"``, ``"openai_mini"``, ``"openai_live"``, …) running that
/// provider's default model, or a concrete model id — resolved
/// server-side, carrying no knobs. A provider case carries that provider's
/// block: its knobs plus an optional concrete ``modelId``. One value names
/// the provider exactly once, so a model that disagrees with its knobs is
/// unrepresentable — ``GeminiModel/thinkingLevel`` exists only inside
/// ``gemini(_:)``.
public enum RealtimeModel: Sendable, Equatable {
    /// A provider family alias or a concrete model id, resolved
    /// server-side. Carries no knobs — every provider keeps its defaults.
    case id(String)
    /// Gemini realtime, carrying ``GeminiModel``'s knobs.
    case gemini(GeminiModel)
    /// OpenAI Realtime, carrying ``OpenAIModel``'s knobs.
    case openai(OpenAIModel)
    /// OpenAI Realtime mini tier, carrying ``OpenAIMiniModel``'s knobs.
    case openaiMini(OpenAIMiniModel)
    /// OpenAI GPT Live, carrying ``OpenAILiveModel``'s knobs.
    case openaiLive(OpenAILiveModel)
    /// xAI Grok Voice, carrying ``GrokModel``'s knobs.
    case grok(GrokModel)

    /// The wire form: the string case crosses as a bare JSON string, a
    /// provider case as that provider's block alone, discriminator set by
    /// the block.
    var wire: CosmoRealtimeAPI.Components.Schemas.InlineAgentConfig
        .ModelPayload
    {
        switch self {
        case let .id(value):
            return .init(value1: value)
        case let .gemini(model):
            return .init(value2: .gemini(model.wire))
        case let .openai(model):
            return .init(value2: .openai(model.wire))
        case let .openaiMini(model):
            return .init(value2: .openaiMini(model.wire))
        case let .openaiLive(model):
            return .init(value2: .openaiLive(model.wire))
        case let .grok(model):
            return .init(value2: .grok(model.wire))
        }
    }
}

/// One entry of an agent's tool set.
/// A tool an agent may use. Build one by calling its constructor
/// (``webSearchTool()``, ``drawBoxTool(onDraw:)``); the cases it lowers to are
/// internal, so there is one way to spell each tool.
public struct AgentTool: Sendable, Equatable {
    let payload: AgentToolPayload

    init(_ payload: AgentToolPayload) { self.payload = payload }

}

enum AgentToolPayload: Sendable, Equatable {
    /// Reserved wire-name prefix of the client tools the SDK ships itself.
    static let sdkToolNamePrefix = "cosmo_sdk_"

    /// A client-executed tool, self-described at session start. The
    /// server runs it by invoking this client over the transport
    /// (LiveKit RPC). ``parameters`` is the JSON Schema for the tool's
    /// arguments (restricted dialect, top-level ``type: "object"``).
    ///
    /// A tool carries the handler that runs it: declaring one this
    /// client cannot execute advertises a tool that fails on every
    /// invocation. A tool the server invokes over RPC without ever
    /// listing it to the agent is the register-only complement — pass
    /// it to ``RealtimeAgent/start(…rpcHandlers:)`` instead.
    case client(
        name: String,
        description: String,
        parameters: [String: JSONValue],
        handler: ClientToolHandler
    )
    /// A client-executed tool whose work runs in the background. Declared
    /// and sent identically to ``client(name:description:parameters:handler:)``
    /// (same wire shape); the background behavior is entirely client-side.
    /// Its handler receives a ``ClientToolJob``: it acks the call immediately
    /// (``ClientToolJob/ack(note:)``) so the session isn't blocked, then
    /// delivers the result later (``ClientToolJob/complete(result:summary:)``
    /// / ``ClientToolJob/fail(error:)``). Use it for a tool whose execution
    /// can outlast the voice turn (an export, a scan, a wait for input).
    case backgroundClient(
        name: String,
        description: String,
        parameters: [String: JSONValue],
        handler: BackgroundClientToolHandler
    )
    /// Opt-in to the server-executed web-search tool. Zero-config —
    /// the server owns the model-facing declaration. Resolved-flow
    /// vocabulary.
    case webSearch
    /// Opt-in to the server-executed frame-examination tool (reads the
    /// freshest camera/screen frame at full resolution). Zero-config;
    /// resolved-flow vocabulary.
    case examineImage
    /// Opt-in to the server-executed object locator that returns boxes —
    /// one per matching instance. Pairs with a client renderer
    /// (`cosmo_sdk_draw_box`): the model picks one of the candidates and
    /// passes it on. Zero-config; resolved-flow vocabulary.
    case detectObjects
    /// The point-returning sibling of ``detectObjects``, pairing with
    /// `cosmo_sdk_draw_point`.
    case pointAtObject
    /// Opt-in to the server-kept speaker log of the room: a diarizing
    /// transcript runs beside the model, and the agent can read the last
    /// few seconds back with one stable label per voice. Zero-config;
    /// resolved-flow vocabulary.
    case speakerLog
    /// Opt-in to the server-executed hang-up, so the agent can end the
    /// call itself. Ending binds the call, not just the agent — every leg
    /// drops — and the spoken goodbye is allowed to finish first.
    /// Zero-config; resolved-flow vocabulary.
    case endCall
    /// A client tool the SDK ships, carrying its own handler.
    ///
    /// Its payload has no public initializer, so this case can only come
    /// from an SDK factory (``drawBox(onDraw:)`` and friends). That is
    /// what makes the ``cosmo_sdk_`` reservation hold: a caller cannot
    /// hand-build a spec under an SDK tool's name, not even the exact
    /// name, because they cannot build this payload at all.
    case sdkClient(SDKClientTool)
    /// The host's screen, offered to the server-executed locator
    /// (`cosmo_screen_locate`) rather than to the model. Alone among the
    /// cases here it is never advertised: it registers an RPC handler the
    /// locator drives, and declaring it is what asks for the locator.
    /// Its payload has no public initializer either — build it with
    /// ``screenLocate(capture:)``.
    case screenLocate(ScreenLocateTool)

    var name: String {
        switch self {
        case let .client(name, _, _, _): return name
        case let .backgroundClient(name, _, _, _): return name
        case let .sdkClient(tool): return tool.name
        case .webSearch: return "web_search"
        case .examineImage: return "examine_image"
        case .detectObjects: return "cosmo_detect_objects"
        case .pointAtObject: return "cosmo_point_at_object"
        case .speakerLog: return "speaker_log"
        case .endCall: return "cosmo_end_call"
        case .screenLocate: return "screen_locate"
        }
    }

    /// The local handler the session would register for this tool — so a
    /// host can invoke its own declared tool the way the session will.
    /// Reading a handler back cannot forge one: an SDK-shipped tool's still
    /// only comes from its factory. ``nil`` for deferred background handlers
    /// and server-tool opt-ins — a client tool always carries one.
    public var clientToolHandler: ClientToolHandler? {
        switch self {
        case let .client(_, _, _, handler): return handler
        case let .sdkClient(tool): return tool.handler
        case .backgroundClient, .webSearch, .examineImage, .detectObjects,
            .pointAtObject, .speakerLog, .endCall, .screenLocate:
            return nil
        }
    }

    static func == (lhs: AgentToolPayload, rhs: AgentToolPayload) -> Bool {
        switch (lhs, rhs) {
        case let (.client(ln, ld, lp, _), .client(rn, rd, rp, _)):
            // Handlers are local-only closures, excluded from
            // equality (and from the wire).
            return ln == rn && ld == rd && lp == rp
        case let (.backgroundClient(ln, ld, lp, _), .backgroundClient(rn, rd, rp, _)):
            return ln == rn && ld == rd && lp == rp
        case let (.sdkClient(l), .sdkClient(r)):
            return l == r
        case (.webSearch, .webSearch), (.examineImage, .examineImage),
            (.detectObjects, .detectObjects), (.pointAtObject, .pointAtObject),
            (.speakerLog, .speakerLog),
            (.endCall, .endCall),
            // Zero-config like the opt-ins above: two capture slots declare
            // the same capability, and the handler behind them is
            // local-only, as with every other handler here.
            (.screenLocate, .screenLocate):
            return true
        // Every case is spelled out rather than caught by `default`: a
        // case added to the enum then fails to compile here instead of
        // silently comparing unequal to itself.
        case (.client, _), (.backgroundClient, _), (.sdkClient, _),
            (.webSearch, _), (.examineImage, _), (.detectObjects, _),
            (.pointAtObject, _), (.speakerLog, _), (.endCall, _), (.screenLocate, _):
            return false
        }
    }
}

/// The assembled per-session wire config: the created agent's fields plus
/// one run's params, flattened for ``RealtimeAgent/start(resumeSessionId:maxSessionSeconds:storeRecording:storeAudio:storeTranscript:storeVideo:micMuted:rpcHandlers:onStateChange:)``.
/// Public callers never touch it — ``RealtimeClient/agent(instructions:model:voice:audio:tools:interruptionSensitivity:greeting:skills:mcp:hooks:)``
/// and ``RealtimeAgent/start(resumeSessionId:maxSessionSeconds:storeRecording:storeAudio:storeTranscript:storeVideo:micMuted:rpcHandlers:onStateChange:)``
/// assemble it.
///
/// Every field is optional: the server applies neutral defaults for
/// anything left unset, and unset fields stay off the wire entirely.
struct SessionConfig: Sendable, Equatable {
    typealias Voice = VoiceConfig
    typealias Audio = AudioConfig
    typealias Tool = AgentTool
    typealias RealtimeModel = CosmoRealtime.RealtimeModel
    typealias InterruptionSensitivity = CosmoRealtime.InterruptionSensitivity
    typealias ThinkingLevel = CosmoRealtime.ThinkingLevel
    typealias EndOfSpeechSensitivity = CosmoRealtime.EndOfSpeechSensitivity
    typealias SemanticEagerness = CosmoRealtime.SemanticEagerness
    typealias TurnDetectionMode = CosmoRealtime.TurnDetectionMode

    /// Machine handle of a workspace catalog agent to run (lowercase
    /// ``[a-z0-9-]``, e.g. ``"driver-pay"``). The stored agent config runs
    /// verbatim; a stored-config agent field set alongside the handle
    /// throws ``SessionStateError`` at start — only
    /// ``agentInputs``, ``tools``, and ``voice`` may accompany it.
    /// ``nil`` runs the inline per-field config with no catalog agent.
    var agentName: String?
    /// String inputs for the referenced agent (template placeholders).
    /// Valid only alongside ``agentName``.
    var agentInputs: [String: String]?
    /// What runs on the other end: a family alias or concrete model id
    /// (``RealtimeModel/id(_:)``), or a provider case carrying that provider's knobs
    /// and an optional concrete ``modelId``. ``nil`` lets the server choose
    /// its default; unavailable values are rejected explicitly at session
    /// start.
    var model: RealtimeModel?
    /// How the agent sounds — prebuilt voice id and speaking style.
    /// ``nil`` keeps the server defaults for both.
    var voice: Voice?
    /// The agent's audio pipeline — output emission and inbound noise
    /// cancellation. ``nil`` keeps every server default (audio on,
    /// cancellation on).
    var audio: Audio?
    /// System instructions. Replaces the server's neutral default when
    /// set.
    var instructions: String?
    /// Tool set for the session: client-executed specs this client
    /// fulfils locally, plus opt-in server tools by name. ``nil`` (the
    /// default) inherits the client-level default tools; an explicit empty
    /// array runs the session with no tools (overriding any default); a
    /// non-empty array is used as-is.
    var tools: [Tool]?
    /// How readily the user's speech interrupts the agent. ``nil`` keeps
    /// the server default.
    var interruptionSensitivity: InterruptionSensitivity?
    /// Opening line the assistant speaks first, voiced server-side as soon
    /// as the model session opens — before the client even receives
    /// ``ready``. ``nil`` keeps the wait-for-user behavior.
    var greeting: String?
    /// When set, the server resumes the named prior session. Carried
    /// under ``RealtimeSessionParams/experimental`` — an unstable knob
    /// that may change shape between releases.
    var resumeSessionId: String?
    /// Requested wall-clock cap on the session, in seconds. The server resolves
    /// the effective cap as the minimum of this and its own limits — a client
    /// can only shorten, never extend. The effective value is echoed on
    /// ``ready``. ``nil`` requests no client-side cap.
    var maxSessionSeconds: Int?
    /// Persist this run's recording artifacts (audio/video/transcript/tool
    /// events) server-side. Per-run option, not agent config. ``nil`` stores
    /// as much as the account's consents allow. The per-artifact properties
    /// below win over this one.
    var storeRecording: Bool?
    /// Persist this run's audio. Narrowing only: a session can request less
    /// storage than the account permits, never more. ``nil`` defers to
    /// ``storeRecording``, then to those consents.
    var storeAudio: Bool?
    /// Persist this run's transcript and tool-call events. Same contract as
    /// ``storeAudio``.
    var storeTranscript: Bool?
    /// Persist this run's screen-share video and screenshots. Same contract
    /// as ``storeAudio``.
    var storeVideo: Bool?
    /// One list, two kinds of hooks: in-process client hooks built by the
    /// seam factories (``sessionStart(_:)``, ``preToolUse(matcher:_:)``, …;
    /// list order is fold order) and declarative server hooks
    /// (``Hook/server(_:)`` wrapping a ``SilenceTimeout``) the server
    /// executes even if this process dies mid-call. Server hooks serialize
    /// in the agent block and take part in equality; client callbacks are
    /// local-only (like client-tool handlers).
    var hooks: [Hook]?

    init(
        agentName: String? = nil,
        agentInputs: [String: String]? = nil,
        model: RealtimeModel? = nil,
        voice: Voice? = nil,
        audio: Audio? = nil,
        instructions: String? = nil,
        tools: [Tool]? = nil,
        interruptionSensitivity: InterruptionSensitivity? = nil,
        greeting: String? = nil,
        resumeSessionId: String? = nil,
        maxSessionSeconds: Int? = nil,
        storeRecording: Bool? = nil,
        storeAudio: Bool? = nil,
        storeTranscript: Bool? = nil,
        storeVideo: Bool? = nil,
        hooks: [Hook]? = nil
    ) {
        self.agentName = agentName
        self.agentInputs = agentInputs
        self.model = model
        self.voice = voice
        self.audio = audio
        self.instructions = instructions
        self.tools = tools
        self.interruptionSensitivity = interruptionSensitivity
        self.greeting = greeting
        self.resumeSessionId = resumeSessionId
        self.maxSessionSeconds = maxSessionSeconds
        self.storeRecording = storeRecording
        self.storeAudio = storeAudio
        self.storeTranscript = storeTranscript
        self.storeVideo = storeVideo
        self.hooks = hooks
    }

    static func == (lhs: SessionConfig, rhs: SessionConfig) -> Bool {
        // hooks is local-only (closures), excluded from equality — same
        // pattern as client-tool handlers in Tool.==.
        lhs.agentName == rhs.agentName
            && lhs.agentInputs == rhs.agentInputs
            && lhs.model == rhs.model
            && lhs.voice == rhs.voice
            && lhs.audio == rhs.audio
            && lhs.instructions == rhs.instructions
            && lhs.tools == rhs.tools
            && lhs.interruptionSensitivity == rhs.interruptionSensitivity
            && lhs.greeting == rhs.greeting
            && lhs.resumeSessionId == rhs.resumeSessionId
            && lhs.maxSessionSeconds == rhs.maxSessionSeconds
            && lhs.storeRecording == rhs.storeRecording
            && lhs.storeAudio == rhs.storeAudio
            && lhs.storeTranscript == rhs.storeTranscript
            && lhs.storeVideo == rhs.storeVideo
            && lhs.serverHooks == rhs.serverHooks
    }
}

/// A client tool the SDK ships: the declaration it owns plus the handler a
/// caller supplied. Construct one through an SDK factory — there is no
/// public initializer, which is precisely what keeps the ``cosmo_sdk_``
/// namespace closed.
public struct SDKClientTool: Sendable, Equatable {
    /// Two are equal when they declare the same tool. The handler is a
    /// local-only closure, excluded here as it is from the wire.
    public static func == (lhs: SDKClientTool, rhs: SDKClientTool) -> Bool {
        lhs.name == rhs.name
            && lhs.description == rhs.description
            && lhs.parameters == rhs.parameters
    }

    let name: String
    let description: String
    let parameters: [String: JSONValue]
    let handler: ClientToolHandler

    init(
        name: String,
        description: String,
        parameters: [String: JSONValue],
        handler: @escaping ClientToolHandler
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.handler = handler
    }
}

/// An async client-tool handler: `(args) -> result`. ``args`` is the
/// decoded tool-call arguments; the returned object is reported back to
/// the agent as the tool result. Throw to surface a tool error. The
/// handler is local-only — it is excluded from serialization and never
/// crosses the wire.
public typealias ClientToolHandler =
    @Sendable ([String: JSONValue]) async throws -> [String: JSONValue]

extension SessionConfig {
    /// Caught here rather than at the server's 422 so the message names the
    /// offending tool and arrives while the caller is still looking at the
    /// code that declared it.
    func assertNoReservedToolNames() throws {
        for tool in tools ?? [] {
            // Both hand-built cases, because they serialize to the same
            // ``kind: "client"`` wire shape — checking only ``.client``
            // would leave ``.backgroundClient`` free to take an SDK name.
            // ``.sdkClient`` is exempt by construction, not by name: a
            // caller cannot build one, so there is nothing to allow-list
            // and no way to shadow an SDK tool by matching its name exactly.
            let declaredName: String?
            switch tool.payload {
            case let .client(name, _, _, _): declaredName = name
            case let .backgroundClient(name, _, _, _): declaredName = name
            case .sdkClient, .webSearch, .examineImage, .detectObjects,
                .pointAtObject, .speakerLog, .endCall, .screenLocate:
                declaredName = nil
            }
            guard let name = declaredName, name.hasPrefix(AgentToolPayload.sdkToolNamePrefix)
            else { continue }
            throw SessionStateError(code: .invalidPayload, message:
                "\(name): the \(AgentToolPayload.sdkToolNamePrefix) prefix is reserved for "
                + "tools the SDK ships — rename your tool"
            )
        }
    }

    /// The server half of the unified ``hooks`` list — wire config for the
    /// agent block; ``nil`` when there are none (stays off the wire).
    var serverHooks: [SilenceTimeout]? {
        let server = splitHooks(hooks ?? []).server
        return server.isEmpty ? nil : server
    }

    /// The in-process half of the unified ``hooks`` list, as the dispatch
    /// engine; ``nil`` when there are no client hooks.
    var hookEngine: HookEngine? {
        splitHooks(hooks ?? []).engine
    }

    /// The ``session-config`` wire payload: the SDK identity and only
    /// the fields the caller actually set. Agent-scoped knobs nest under
    /// ``RealtimeSessionConfig/agent``; session-scoped ones under
    /// ``RealtimeSessionConfig/session``. A sub-object with no set fields
    /// stays off the wire entirely, same as an unset leaf.
    func wirePayload() throws -> CosmoRealtimeAPI.Components.Schemas.SessionConfig {
        try assertNoReservedToolNames()
        let agent: CosmoRealtimeAPI.Components.Schemas.SessionConfig.AgentPayload?
        if let agentName {
            // The catalog variant carries only per-run ride-alongs; a
            // stored-config field alongside the handle is a client-side
            // error, never silently dropped.
            // Server hooks are refused as a hook problem, the same way the
            // sibling SDKs refuse them, so one catch covers hook registration
            // whichever guard rejects it.
            guard (serverHooks ?? []).isEmpty else {
                throw HookError(
                    code: .serverHookNotAllowed,
                    message: "a catalog agent runs its stored config verbatim — "
                        + "server hooks cannot ride along"
                )
            }
            let storedConfigFields: [(String, Bool)] = [
                ("model", model != nil),
                ("audio", audio != nil),
                ("instructions", instructions != nil),
                ("interruptionSensitivity", interruptionSensitivity != nil),
                ("greeting", greeting != nil),
            ]
            let offending = storedConfigFields.filter(\.1).map(\.0)
            guard offending.isEmpty else {
                throw SessionStateError(code: .invalidPayload, message: 
                    "a catalog agent runs its stored config verbatim — remove: "
                        + offending.joined(separator: ", ")
                )
            }
            // An explicit empty tool set and an unset one both serialize as
            // absent; the server applies its neutral default for absent.
            let wireTools = try tools.flatMap { specs in
                specs.isEmpty ? nil : try specs.map { try $0.catalogWirePayload() }
            }
            agent = .catalog(
                .init(
                    inputs: agentInputs.map { .init(additionalProperties: $0) },
                    name: agentName,
                    tools: wireTools,
                    _type: .catalog,
                    voice: voice?.wire
                )
            )
        } else {
            // An explicit empty tool set and an unset one both serialize as
            // absent; the server applies its neutral default for absent.
            let wireTools = try tools.flatMap { specs in
                specs.isEmpty ? nil : try specs.map { try $0.inlineWirePayload() }
            }
            let inline = CosmoRealtimeAPI.Components.Schemas.InlineAgentConfig(
                audio: audio?.wire,
                greeting: greeting,
                hooks: serverHooks.map { $0.map { .init($0) } },
                instructions: instructions,
                interruptionSensitivity: interruptionSensitivity.map { .init($0) },
                model: model?.wire,
                tools: wireTools,
                _type: .inline,
                voice: voice?.wire
            )
            // An inline block carrying only its tag is the neutral default
            // agent — omit the block entirely.
            agent = inline == .init(_type: .inline) ? nil : .inline(inline)
        }
        let session = CosmoRealtimeAPI.Components.Schemas.SessionParams(
            experimental: resumeSessionId.map { .init(resumeSessionId: $0) },
            maxSessionSeconds: maxSessionSeconds,
            storeAudio: storeAudio,
            storeRecording: storeRecording,
            storeTranscript: storeTranscript,
            storeVideo: storeVideo
        )
        return CosmoRealtimeAPI.Components.Schemas.SessionConfig(
            agent: agent,
            sdk: .init(name: sdkName, version: sdkVersion),
            session: session == .init() ? nil : session,
            _type: .sessionConfig
        )
    }

    /// Client tools that carry a local handler, keyed by tool name. The
    /// transport registers an RPC method per entry so the agent can
    /// invoke them.
    func clientToolHandlers() -> [String: ClientToolHandler] {
        var handlers: [String: ClientToolHandler] = [:]
        for tool in tools ?? [] {
            if case let .client(name, _, _, handler) = tool.payload {
                handlers[name] = handler
            }
            if case let .sdkClient(sdkTool) = tool.payload {
                handlers[sdkTool.name] = sdkTool.handler
            }
        }
        return handlers
    }

    /// Handlers registered by wire method name but never advertised — the
    /// ``AgentTool/screenLocate(_:)`` slot, which a server tool drives directly.
    /// Keyed by RPC method rather than tool name, since the model never sees it.
    func rpcOnlyHandlers() -> [String: ClientToolHandler] {
        var handlers: [String: ClientToolHandler] = [:]
        for case let .screenLocate(capture) in (tools ?? []).map(\.payload) {
            handlers[ScreenLocateTool.rpcMethod] = capture.handler()
        }
        return handlers
    }

    /// The capture slots this config declares, so the session can bind their
    /// byte-stream publish once its transport is up.
    var screenLocateTools: [ScreenLocateTool] {
        (tools ?? []).compactMap { tool in
            guard case let .screenLocate(capture) = tool.payload else { return nil }
            return capture
        }
    }

    /// Background client tools that carry a handler, keyed by tool name. The
    /// transport registers a deferred RPC method per entry.
    func backgroundClientToolHandlers() -> [String: BackgroundClientToolHandler] {
        var handlers: [String: BackgroundClientToolHandler] = [:]
        for tool in tools ?? [] {
            if case let .backgroundClient(name, _, _, handler) = tool.payload {
                handlers[name] = handler
            }
        }
        return handlers
    }
}

extension AgentTool {
    // The generator emits a structurally-identical but distinct tools
    // payload type per agent variant, so each variant gets its own mapping.
    fileprivate func inlineWirePayload() throws
        -> CosmoRealtimeAPI.Components.Schemas.InlineAgentConfig.ToolsPayloadPayload
    {
        switch payload {
        case .sdkClient(let sdkTool):
            return .client(
                .init(
                    description: sdkTool.description,
                    kind: .client,
                    name: sdkTool.name,
                    parameters: .init(additionalProperties: try objectContainer(from: sdkTool.parameters))
                )
            )
        case .client(let name, let description, let parameters, _),
            .backgroundClient(let name, let description, let parameters, _):
            // A background client tool is declared identically to a plain one;
            // the deferral is inferred server-side from the reply.
            return .client(
                .init(
                    description: description,
                    kind: .client,
                    name: name,
                    parameters: .init(additionalProperties: try objectContainer(from: parameters))
                )
            )
        case .webSearch:
            return .webSearch(.init(kind: .webSearch))
        case .examineImage:
            return .examineImage(.init(kind: .examineImage))
        case .detectObjects:
            return .detectObjects(.init(kind: .detectObjects))
        case .pointAtObject:
            return .pointAtObject(.init(kind: .pointAtObject))
        case .speakerLog:
            return .speakerLog(.init(kind: .speakerLog))
        case .endCall:
            return .endCall(.init(kind: .endCall))
        case .screenLocate:
            return .screenLocate(.init(kind: .screenLocate))
        }
    }

    fileprivate func catalogWirePayload() throws
        -> CosmoRealtimeAPI.Components.Schemas.CatalogAgentConfig.ToolsPayloadPayload
    {
        switch payload {
        case .sdkClient(let sdkTool):
            return .client(
                .init(
                    description: sdkTool.description,
                    kind: .client,
                    name: sdkTool.name,
                    parameters: .init(additionalProperties: try objectContainer(from: sdkTool.parameters))
                )
            )
        case .client(let name, let description, let parameters, _),
            .backgroundClient(let name, let description, let parameters, _):
            return .client(
                .init(
                    description: description,
                    kind: .client,
                    name: name,
                    parameters: .init(additionalProperties: try objectContainer(from: parameters))
                )
            )
        case .webSearch:
            return .webSearch(.init(kind: .webSearch))
        case .examineImage:
            return .examineImage(.init(kind: .examineImage))
        case .detectObjects:
            return .detectObjects(.init(kind: .detectObjects))
        case .pointAtObject:
            return .pointAtObject(.init(kind: .pointAtObject))
        case .speakerLog:
            return .speakerLog(.init(kind: .speakerLog))
        case .endCall:
            return .endCall(.init(kind: .endCall))
        case .screenLocate:
            return .screenLocate(.init(kind: .screenLocate))
        }
    }
}

/// Bridge a typed ``JSONValue`` object into the generated
/// ``OpenAPIObjectContainer`` via a JSON round-trip — both sides are
/// Codable, so this avoids any untyped ``[String: Any]`` step.
func objectContainer(from object: [String: JSONValue]) throws -> OpenAPIRuntime.OpenAPIObjectContainer {
    let data = try JSONEncoder().encode(object)
    return try JSONDecoder().decode(OpenAPIRuntime.OpenAPIObjectContainer.self, from: data)
}
