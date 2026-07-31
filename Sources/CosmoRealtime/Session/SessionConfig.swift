import CosmoRealtimeAPI
import Foundation

/// Tier-2 server hook: perform an action after sustained customer
/// silence. Wire config — serialized in the agent block and executed
/// server-side, so it works with no client attached (telephony).
public typealias SilenceTimeout = CosmoRealtimeAPI.Components.Schemas.RealtimeSilenceTimeout
/// Idle-message action for ``SilenceTimeout``: ``text`` = exact words,
/// ``prompt`` = model-generated, both nil = free model speech.
public typealias Say = CosmoRealtimeAPI.Components.Schemas.RealtimeSay
/// End-call action for ``SilenceTimeout``.
public typealias EndCall = CosmoRealtimeAPI.Components.Schemas.RealtimeEndCall

/// Per-session configuration for ``RealtimeSession/start(_:config:)``.
///
/// Every field is optional: the server applies neutral defaults for
/// anything left unset, and unset fields stay off the wire entirely.
/// Client-level defaults can be supplied once via
/// ``RealtimeSession/Options/defaultConfig`` — per-call values win over
/// them field by field. A catalog-agent launch (``agentName``) never
/// inherits persona defaults: the stored config governs, and only per-run
/// ride-alongs resolve against defaults.
public struct SessionConfig: Sendable, Equatable {
    /// Machine handle of a workspace catalog agent to run (lowercase
    /// ``[a-z0-9-]``, e.g. ``"driver-pay"``). The stored agent config runs
    /// verbatim; a stored-config agent field set alongside the handle
    /// throws ``RealtimeSessionError/invalidPayload(_:)`` at start — only
    /// ``agentInputs``, ``tools``, and ``speakingStyle`` may accompany it.
    /// ``nil`` runs the inline per-field config with no catalog agent.
    public var agentName: String?
    /// String inputs for the referenced agent (template placeholders).
    /// Valid only alongside ``agentName``.
    public var agentInputs: [String: String]?
    /// Provider/model selection. ``nil`` lets the server choose its
    /// default; unavailable values are rejected explicitly at session
    /// start.
    public var model: String?
    /// Provider-scoped model knobs (sampling, reasoning depth, turn-taking),
    /// discriminated on provider. Each knob is honored only by its provider,
    /// so an illegal pairing is unrepresentable. ``nil`` keeps every provider
    /// default; ``model`` selects the concrete model within the provider.
    public var modelOptions: ModelOptions?
    /// Provider-specific prebuilt voice id. When ``nil`` the upstream
    /// picks per session — the voice then drifts between connects.
    public var voice: String?
    /// Whether the agent emits audio. ``false`` runs the session
    /// text-only: no speech is produced while input transcription and
    /// text output are unaffected — for transcription, captioning, or
    /// text-response apps. Rejected at session start when the resolved
    /// model cannot run text-only (self-contained speech-to-speech
    /// providers). ``nil`` keeps the server default (on).
    public var audioOutput: Bool?
    /// System instructions. Replaces the server's neutral default when
    /// set.
    public var instructions: String?
    /// A "how to speak" instruction appended to the system prompt (e.g. warm /
    /// delivery / human, or any caller text). ``nil`` keeps the server default.
    public var speakingStyle: String?
    /// Tool set for the session: client-executed specs this client
    /// fulfils locally, plus opt-in server tools by name. ``nil`` (the
    /// default) inherits the client-level default tools; an explicit empty
    /// array runs the session with no tools (overriding any default); a
    /// non-empty array is used as-is.
    public var tools: [Tool]?
    /// How readily the user's speech interrupts the agent. ``nil`` keeps
    /// the server default.
    public var interruptionSensitivity: InterruptionSensitivity?
    /// Enable upstream noise cancellation on the input audio. ``nil``
    /// keeps the server default (off).
    public var noiseCancellationEnabled: Bool?
    /// Opening line the assistant speaks first, voiced server-side as soon
    /// as the model session opens — before the client even receives
    /// ``ready``. ``nil`` keeps the wait-for-user behavior.
    public var greeting: String?
    /// When set, the server resumes the named prior session. Carried
    /// under ``RealtimeSessionParams/experimental`` — an unstable knob
    /// that may change shape without a protocol-version bump.
    public var resumeSessionId: String?
    /// Requested wall-clock cap on the session, in seconds. The server resolves
    /// the effective cap as the minimum of this and its own limits — a client
    /// can only shorten, never extend. The effective value is echoed on
    /// ``ready``. ``nil`` requests no client-side cap.
    public var maxSessionSeconds: Int?
    /// Persist this run's recording artifacts (audio/video/transcript/tool
    /// events) server-side. Per-run option, not agent config. ``nil`` keeps
    /// the server default: the session records.
    public var storeRecording: Bool?
    /// One list, two kinds of hooks: in-process client hooks built by the
    /// seam factories (``sessionStart(_:)``, ``preToolUse(matcher:_:)``, …;
    /// list order is fold order) and declarative server hooks
    /// (``Hook/server(_:)`` wrapping a ``SilenceTimeout``) the server
    /// executes even if this process dies mid-call. Server hooks serialize
    /// in the agent block and take part in equality; client callbacks are
    /// local-only (like client-tool handlers).
    public var hooks: [Hook]?
    /// The screen-interaction capability declaration. Never authorable —
    /// the SDK sets it mechanically iff the host supplied a
    /// ``ScreenInteraction`` implementation (whose RPC handlers it
    /// registers alongside); the server derives the grounded screen tools
    /// from it.
    var declaresScreenInteraction: Bool = false

    public init(
        agentName: String? = nil,
        agentInputs: [String: String]? = nil,
        model: String? = nil,
        modelOptions: ModelOptions? = nil,
        voice: String? = nil,
        audioOutput: Bool? = nil,
        instructions: String? = nil,
        speakingStyle: String? = nil,
        tools: [Tool]? = nil,
        interruptionSensitivity: InterruptionSensitivity? = nil,
        noiseCancellationEnabled: Bool? = nil,
        greeting: String? = nil,
        resumeSessionId: String? = nil,
        maxSessionSeconds: Int? = nil,
        storeRecording: Bool? = nil,
        hooks: [Hook]? = nil
    ) {
        self.agentName = agentName
        self.agentInputs = agentInputs
        self.model = model
        self.modelOptions = modelOptions
        self.voice = voice
        self.audioOutput = audioOutput
        self.instructions = instructions
        self.speakingStyle = speakingStyle
        self.tools = tools
        self.interruptionSensitivity = interruptionSensitivity
        self.noiseCancellationEnabled = noiseCancellationEnabled
        self.greeting = greeting
        self.resumeSessionId = resumeSessionId
        self.maxSessionSeconds = maxSessionSeconds
        self.storeRecording = storeRecording
        self.hooks = hooks
    }

    public static func == (lhs: SessionConfig, rhs: SessionConfig) -> Bool {
        // hooks is local-only (closures), excluded from equality — same
        // pattern as client-tool handlers in Tool.==.
        lhs.agentName == rhs.agentName
            && lhs.agentInputs == rhs.agentInputs
            && lhs.model == rhs.model
            && lhs.modelOptions == rhs.modelOptions
            && lhs.voice == rhs.voice
            && lhs.audioOutput == rhs.audioOutput
            && lhs.instructions == rhs.instructions
            && lhs.speakingStyle == rhs.speakingStyle
            && lhs.tools == rhs.tools
            && lhs.interruptionSensitivity == rhs.interruptionSensitivity
            && lhs.noiseCancellationEnabled == rhs.noiseCancellationEnabled
            && lhs.greeting == rhs.greeting
            && lhs.resumeSessionId == rhs.resumeSessionId
            && lhs.maxSessionSeconds == rhs.maxSessionSeconds
            && lhs.storeRecording == rhs.storeRecording
            && lhs.serverHooks == rhs.serverHooks
            && lhs.declaresScreenInteraction == rhs.declaresScreenInteraction
    }

    /// Re-exposed generated enum so consumers never spell the
    /// ``CosmoRealtimeAPI.Components.Schemas`` namespace.
    public typealias InterruptionSensitivity =
        CosmoRealtimeAPI.Components.Schemas.InterruptionSensitivity
    public typealias ThinkingLevel =
        CosmoRealtimeAPI.Components.Schemas.RealtimeThinkingLevel

    /// Provider-scoped model knobs, discriminated on the provider. A knob is
    /// honored only by its provider — ``thinkingLevel`` lives only on
    /// ``gemini`` — so an illegal pairing is unrepresentable. ``model`` on
    /// ``SessionConfig`` selects the concrete model within the chosen provider.
    public enum ModelOptions: Sendable, Equatable {
        /// Gemini-realtime knobs.
        case gemini(
            temperature: Double? = nil,
            maxOutputTokens: Int? = nil,
            thinkingLevel: ThinkingLevel? = nil
        )
        /// OpenAI Realtime — pins its own sampling and token limits; nothing
        /// tunable today.
        case openai
        /// Ultravox knobs.
        case ultravox(
            temperature: Double? = nil,
            turnEndpointDelaySeconds: Double? = nil
        )
        /// PersonaPlex (Cosmo Voice Light) — nothing tunable today.
        case personaplex

        /// The provider-scoped wire block: only the selected provider's knobs
        /// cross the wire, with the discriminator set explicitly.
        var wire: CosmoRealtimeAPI.Components.Schemas.RealtimeInlineAgentConfig
            .ModelOptionsPayload
        {
            switch self {
            case let .gemini(temperature, maxOutputTokens, thinkingLevel):
                return .gemini(
                    .init(
                        maxOutputTokens: maxOutputTokens,
                        provider: .gemini,
                        temperature: temperature,
                        thinkingLevel: thinkingLevel
                    ))
            case .openai:
                return .openai(.init(provider: .openai))
            case let .ultravox(temperature, turnEndpointDelaySeconds):
                return .cosmoVoiceUltravox(
                    .init(
                        provider: .cosmoVoiceUltravox,
                        temperature: temperature,
                        turnEndpointDelaySeconds: turnEndpointDelaySeconds
                    ))
            case .personaplex:
                return .cosmoVoicePersonaplex(.init(provider: .cosmoVoicePersonaplex))
            }
        }
    }

    /// One entry of ``tools``.
    public enum Tool: Sendable, Equatable {
        /// A client-executed tool, self-described at session start. The
        /// server runs it by invoking this client over the transport
        /// (LiveKit RPC); declare a ``handler`` to make it executable.
        /// ``parameters`` is the JSON Schema for the tool's arguments
        /// (restricted dialect, top-level ``type: "object"``). A spec
        /// without a handler is still declared to the agent but cannot
        /// be executed — its invocation surfaces only as a
        /// ``RealtimeSession/Event/toolInvocation(_:)`` observability
        /// event.
        case client(
            name: String,
            description: String,
            parameters: [String: JSONValue],
            handler: ClientToolHandler? = nil
        )
        /// A client-executed tool whose work runs in the background. Declared
        /// and sent identically to ``client`` (same wire shape); the background
        /// behavior is entirely client-side. Its handler receives a
        /// ``ClientToolJob``: it acks the call immediately (``job.ack``) so the
        /// session isn't blocked, then delivers the result later
        /// (``job.complete`` / ``job.fail``). Use it for a tool whose execution
        /// can outlast the voice turn (an export, a scan, a wait for input).
        case backgroundClient(
            name: String,
            description: String,
            parameters: [String: JSONValue],
            handler: BackgroundClientToolHandler
        )
        /// Opt-in to the server-executed web-search tool. Zero-config —
        /// the server owns the model-facing declaration. Resolved-flow
        /// vocabulary; the legacy endpoint ignores it.
        case webSearch
        /// Opt-in to the server-executed frame-examination tool (reads the
        /// freshest camera/screen frame at full resolution). Zero-config;
        /// resolved-flow vocabulary.
        case examineImage
        /// Opt-in to the server-executed object locator that returns boxes.
        /// Pairs with a client renderer (`draw_after_detect`): the model
        /// picks one of the candidates and passes it on. Zero-config;
        /// resolved-flow vocabulary.
        case detect
        /// The point-returning sibling of ``detect``, pairing with
        /// `draw_after_point`.
        case point

        public var name: String {
            switch self {
            case let .client(name, _, _, _): return name
            case let .backgroundClient(name, _, _, _): return name
            case .webSearch: return "web_search"
            case .examineImage: return "examine_image"
            case .detect: return "cosmo_detect"
            case .point: return "cosmo_point"
            }
        }

        public static func == (lhs: Tool, rhs: Tool) -> Bool {
            switch (lhs, rhs) {
            case let (.client(ln, ld, lp, _), .client(rn, rd, rp, _)):
                // Handlers are local-only closures, excluded from
                // equality (and from the wire).
                return ln == rn && ld == rd && lp == rp
            case let (.backgroundClient(ln, ld, lp, _), .backgroundClient(rn, rd, rp, _)):
                return ln == rn && ld == rd && lp == rp
            case (.webSearch, .webSearch), (.examineImage, .examineImage),
                (.detect, .detect), (.point, .point):
                return true
            default:
                return false
            }
        }
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

    /// The ``session-config`` wire payload: the protocol version and only
    /// the fields the caller actually set. Agent-scoped knobs nest under
    /// ``RealtimeSessionConfig/agent``; session-scoped ones under
    /// ``RealtimeSessionConfig/session``. A sub-object with no set fields
    /// stays off the wire entirely, same as an unset leaf.
    func wirePayload() throws -> CosmoRealtimeAPI.Components.Schemas.RealtimeSessionConfig {
        let agent: CosmoRealtimeAPI.Components.Schemas.RealtimeSessionConfig.AgentPayload?
        if let agentName {
            // The catalog variant carries only per-run ride-alongs; a
            // stored-config field alongside the handle is a client-side
            // error, never silently dropped.
            let storedConfigFields: [(String, Bool)] = [
                ("model", model != nil),
                ("modelOptions", modelOptions != nil),
                ("voice", voice != nil),
                ("audioOutput", audioOutput != nil),
                ("instructions", instructions != nil),
                ("interruptionSensitivity", interruptionSensitivity != nil),
                ("noiseCancellationEnabled", noiseCancellationEnabled != nil),
                ("greeting", greeting != nil),
                ("hooks (server)", !(serverHooks ?? []).isEmpty),
            ]
            let offending = storedConfigFields.filter(\.1).map(\.0)
            guard offending.isEmpty else {
                throw RealtimeSessionError.invalidPayload(
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
                    speakingStyle: speakingStyle,
                    tools: wireTools,
                    _type: .catalog
                )
            )
        } else {
            // An explicit empty tool set and an unset one both serialize as
            // absent; the server applies its neutral default for absent.
            var wireTools = try tools.flatMap { specs in
                specs.isEmpty ? nil : try specs.map { try $0.inlineWirePayload() }
            }
            if declaresScreenInteraction {
                wireTools = (wireTools ?? []) + [
                    .screenInteraction(.init(kind: .screenInteraction))
                ]
            }
            let inline = CosmoRealtimeAPI.Components.Schemas.RealtimeInlineAgentConfig(
                audioOutput: audioOutput,
                greeting: greeting,
                hooks: serverHooks,
                instructions: instructions,
                interruptionSensitivity: interruptionSensitivity,
                model: model,
                modelOptions: modelOptions?.wire,
                noiseCancellationEnabled: noiseCancellationEnabled,
                speakingStyle: speakingStyle,
                tools: wireTools,
                _type: .inline,
                voice: voice
            )
            // An inline block carrying only its tag is the neutral default
            // agent — omit the block entirely.
            agent = inline == .init(_type: .inline) ? nil : .inline(inline)
        }
        let session = CosmoRealtimeAPI.Components.Schemas.RealtimeSessionParams(
            experimental: resumeSessionId.map { .init(resumeSessionId: $0) },
            maxSessionSeconds: maxSessionSeconds,
            storeRecording: storeRecording
        )
        return CosmoRealtimeAPI.Components.Schemas.RealtimeSessionConfig(
            agent: agent,
            session: session == .init() ? nil : session,
            _type: .sessionConfig,
            version: RealtimeSession.protocolVersion
        )
    }

    /// Client tools that carry a local handler, keyed by tool name. The
    /// transport registers an RPC method per entry so the agent can
    /// invoke them.
    func clientToolHandlers() -> [String: ClientToolHandler] {
        var handlers: [String: ClientToolHandler] = [:]
        for tool in tools ?? [] {
            if case let .client(name, _, _, handler) = tool, let handler {
                handlers[name] = handler
            }
        }
        return handlers
    }

    /// Background client tools that carry a handler, keyed by tool name. The
    /// transport registers a deferred RPC method per entry.
    func backgroundClientToolHandlers() -> [String: BackgroundClientToolHandler] {
        var handlers: [String: BackgroundClientToolHandler] = [:]
        for tool in tools ?? [] {
            if case let .backgroundClient(name, _, _, handler) = tool {
                handlers[name] = handler
            }
        }
        return handlers
    }
}

extension SessionConfig.Tool {
    // The generator emits a structurally-identical but distinct tools
    // payload type per agent variant, so each variant gets its own mapping.
    fileprivate func inlineWirePayload() throws
        -> CosmoRealtimeAPI.Components.Schemas.RealtimeInlineAgentConfig.ToolsPayloadPayload
    {
        switch self {
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
        case .detect:
            return .detect(.init(kind: .detect))
        case .point:
            return .point(.init(kind: .point))
        }
    }

    fileprivate func catalogWirePayload() throws
        -> CosmoRealtimeAPI.Components.Schemas.RealtimeCatalogAgentConfig.ToolsPayloadPayload
    {
        switch self {
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
        case .detect:
            return .detect(.init(kind: .detect))
        case .point:
            return .point(.init(kind: .point))
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
