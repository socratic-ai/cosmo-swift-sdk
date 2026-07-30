import CoreMedia
import CosmoRealtimeAPI
import Foundation
import os

/// Session-lifecycle wrapper backed by the public ``CosmoRealtime`` SDK's
/// ``RealtimeSession``.
///
/// Exposes ``events`` / ``connectionState`` / ``inputLevel`` /
/// ``outputLevel`` AsyncStreams plus send/screen-share methods so the
/// macOS app and other consumers (``VoiceSessionModel``, ``AppModel``,
/// ``ClientToolDispatcher``) get a small, stable Swift surface over
/// the generated SDK types.
public actor VoiceSession {
    private static let log = Logger(subsystem: CosmoRealtimeLog.subsystem, category: "voice-session")

    /// The backing session. ``RealtimeSession/start(_:config:micMuted:)``
    /// creates it asynchronously inside ``_connect``, so it lives in a
    /// nonisolated lock-box rather than a plain stored property — that lets the
    /// `nonisolated` level/QoE accessors forward to it without hopping the
    /// actor. Those accessors are only touched after the session is live, so
    /// the pre-connect fallback (empty stream / zero snapshot) is never observed.
    private let sessionBox = OSAllocatedUnfairLock<RealtimeSession?>(initialState: nil)
    private let credentials: Credentials
    private let options: ClientOptions
    private let engine: VoiceAudioEngine

    private let eventsStream: AsyncStream<ServerEvent>
    private nonisolated let eventsContinuation: AsyncStream<ServerEvent>.Continuation
    private let connectionStateStream: AsyncStream<VoiceConnectionState>
    private nonisolated let connectionStateContinuation: AsyncStream<VoiceConnectionState>.Continuation

    private var eventLoop: Task<Void, Never>?
    private var stateLoop: Task<Void, Never>?
    /// Drains ``RealtimeSession/agentLive`` — the agent-track readiness signal —
    /// so a lost/late ``ready`` frame no longer strands an otherwise-live agent.
    private var agentLiveLoop: Task<Void, Never>?
    /// Session id captured at transport-up, so the agent-track readiness path
    /// can synthesize the app-facing ``ready`` without a server frame.
    private var currentSessionId = ""
    /// Non-nil once any teardown path runs. Doubles as the once-only gate (skip
    /// when already set) and the typed reason the connect-failure catch
    /// translates into a ``VoiceClientError`` (preserves ``.voiceDisabled`` /
    /// ``.handshakeFailed(status:)`` so ``ErrorPresentationMapper`` can branch
    /// on typed cases instead of a generic ``.transport``).
    private var closeReason: ConnectionCloseReason?

    /// Closes the session with a ``transportError`` if the agent never sends
    /// ``ready`` within ``readinessTimeout`` of the transport coming up.
    /// ``RealtimeSession/start`` returns on transport-up and delivers readiness
    /// as an async event with no timeout of its own, and the backend dispatches
    /// the agent fire-and-forget and (by design) relies on THIS client watchdog
    /// to surface a dead/slow agent — without it a failed dispatch leaves the UI
    /// stuck at "connecting" indefinitely. Mirrors the legacy client's watchdog.
    private var readinessWatchdog: Task<Void, Never>?
    private var didBecomeReady = false

    /// How long after transport-up to wait for the agent's ``ready`` before
    /// closing for retry. Matches the legacy client's default readiness window.
    private static let readinessTimeout: TimeInterval = 20

    public static func start(
        credentials: Credentials,
        tools: [String]? = nil,
        declaredTools: [DeclaredClientTool]? = nil,
        backgroundClientToolHandlers: [String: BackgroundClientToolHandler]? = nil,
        voiceName: String? = nil,
        resumeFromCallId: String? = nil,
        providerPreference: String? = nil,
        noiseCancellationEnabled: Bool? = nil,
        storeRecording: Bool = true,
        interruptionSensitivity: String? = nil,
        thinkingLevel: String? = nil,
        connectGreeting: String? = nil,
        systemPrompt: String? = nil,
        agentName: String? = nil,
        dictation: Bool = false,
        micMuted: Bool = false,
        clientToolMethods: [String] = [],
        clientToolHandler: (@Sendable (String, String) async -> String)? = nil,
        screenInteraction: ScreenInteraction? = nil,
        options: ClientOptions = .init()
    ) async throws -> VoiceSession {
        let session = VoiceSession(credentials: credentials, options: options)
        try await session._connect(
            tools: tools,
            declaredTools: declaredTools,
            backgroundClientToolHandlers: backgroundClientToolHandlers,
            voiceName: voiceName,
            resumeFromCallId: resumeFromCallId,
            providerPreference: providerPreference,
            noiseCancellationEnabled: noiseCancellationEnabled,
            storeRecording: storeRecording,
            interruptionSensitivity: interruptionSensitivity,
            thinkingLevel: thinkingLevel,
            connectGreeting: connectGreeting,
            systemPrompt: systemPrompt,
            agentName: agentName,
            dictation: dictation,
            micMuted: micMuted,
            clientToolMethods: clientToolMethods,
            clientToolHandler: clientToolHandler,
            screenInteraction: screenInteraction
        )
        return session
    }

    /// Pre-create a room + mint the join token off the press path so the next
    /// ``start`` joins immediately on the held token while ``/session/start``
    /// runs in parallel. Call at sign-in / wake / on a refresh cadence; an
    /// absent or stale parked session degrades to the serialized start path.
    public static func prepareSession(
        credentials: Credentials,
        options: ClientOptions = .init()
    ) async throws {
        try await RealtimeSession.prepareSession(
            makeOptions(credentials: credentials, clientOptions: options)
        )
    }

    private init(credentials: Credentials, options: ClientOptions) {
        self.credentials = credentials
        self.options = options
        self.engine = VoiceAudioEngine()

        let events = AsyncStream<ServerEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        self.eventsStream = events.stream
        self.eventsContinuation = events.continuation

        let conn = AsyncStream<VoiceConnectionState>.makeStream(bufferingPolicy: .bufferingNewest(8))
        self.connectionStateStream = conn.stream
        self.connectionStateContinuation = conn.continuation

        connectionStateContinuation.yield(.idle)
    }

    // MARK: - Public surface

    public nonisolated var events: AsyncStream<ServerEvent> { eventsStream }
    public nonisolated var connectionState: AsyncStream<VoiceConnectionState> { connectionStateStream }
    public nonisolated var inputLevel: AsyncStream<Float> {
        sessionBox.withLock { $0?.inputLevels } ?? Self.emptyFloatStream
    }
    public nonisolated var outputLevel: AsyncStream<Float> {
        sessionBox.withLock { $0?.outputLevels } ?? Self.emptyFloatStream
    }
    public nonisolated var diagnostics: Diagnostics { engine.diagnostics }

    /// Software playback gain for the agent's audio: `0` mutes, `1` is unity.
    /// Values outside 0…1 are clamped. No-op before the backing session
    /// exists; once live it applies immediately and is re-applied across
    /// reconnects. See ``RealtimeSession/setAgentPlaybackVolume(_:)``.
    public nonisolated func setAgentPlaybackVolume(_ volume: Double) {
        sessionBox.withLock { $0 }?.setAgentPlaybackVolume(volume)
    }

    /// Per-session WebRTC quality aggregated by the SDK. Read at session end
    /// for the final rollup; the underlying aggregator survives transport
    /// close, so the snapshot stays valid after the session stops.
    public nonisolated var qoeSnapshot: SessionQoESnapshot {
        sessionBox.withLock { $0?.qoeSnapshot } ?? Self.emptyQoESnapshot
    }

    /// Send a user text turn. `audioResponse: false` requests a text-only reply
    /// (e.g. a tool-only turn like a recap request) — no spoken audio.
    public func sendText(_ content: String, audioResponse: Bool = true) async throws {
        try await requireSession().send(text: content, audioResponse: audioResponse)
    }

    public func sendMute(_ muted: Bool) async throws {
        try await requireSession().setMuted(muted)
    }

    /// Mute the local mic AND best-effort notify the server. Local gating
    /// runs first (cheap, guarantees no further audio bytes leave the
    /// device); the wire frame is a hint and may fail if the transport is
    /// mid-teardown — not fatal since the local gate already applied.
    public func setMuted(_ muted: Bool) async {
        await engine.setMicMuted(muted)
        guard let session = sessionBox.withLock({ $0 }) else { return }
        do {
            try await session.setMuted(muted)
        } catch {
            NSLog("[VoiceSession] setMuted(%@) wire frame failed: %@",
                  muted ? "true" : "false", error.localizedDescription)
        }
    }

    /// Signal manual-VAD end-of-turn (`WAKE_WORD_WINDOW` mode).
    public func sendActivityEnd() async throws {
        try await requireSession().sendActivityEnd()
    }

    /// Send per-turn client context. Forwards to the cosmo send namespace.
    public func sendTurnContext(
        cursor: CursorPoint? = nil,
        frontmostApp: String? = nil,
        openApps: [String] = [],
        extras: [String: String] = [:]
    ) async throws {
        try await requireSession().cosmo.sendTurnContext(
            cursor: cursor.map { .init(x: $0.x, y: $0.y) },
            frontmostApp: frontmostApp,
            openApps: openApps,
            extras: extras
        )
    }

    /// Send labeled screen-state metadata to the agent.
    public func sendVisualContext(_ payload: VisualContextPayload) async throws {
        try await requireSession().cosmo.sendVisualContext(payload)
    }

    public func end() async {
        await engine.stop()
        if let session = sessionBox.withLock({ $0 }) {
            await session.end()
        }
        await teardown(reason: .clientEnded)
    }

    public func sendImage(base64: String, mimeType: String = "image/jpeg", streamId: String) async throws {
        try await requireSession().send(image: base64, mimeType: mimeType, streamId: streamId)
    }

    /// Publish a binary client-tool payload over a LiveKit byte stream
    /// (e.g. the grounding screenshot + AX list).
    public func sendBytes(_ data: Data, topic: String) async throws {
        try await requireSession().send(bytes: data, topic: topic)
    }

    /// Publish a LiveKit screen-share video track. The caller pushes captured
    /// CMSampleBuffers via ``pushScreenShareFrame``; LiveKit handles encoding
    /// and RTP transport.
    public func startScreenShare() async throws {
        try await requireSession().startScreenShare()
    }

    /// Push one screen frame into the active screen-share track. No-op if
    /// ``startScreenShare`` hasn't run.
    public nonisolated func pushScreenShareFrame(_ sampleBuffer: CMSampleBuffer) {
        sessionBox.withLock { $0 }?.pushScreenShareFrame(sampleBuffer)
    }

    /// Unpublish the screen-share track. Idempotent.
    public func stopScreenShare() async {
        guard let session = sessionBox.withLock({ $0 }) else { return }
        await session.stopScreenShare()
    }

    /// Register a callback fired when the deferred screen-share publish fails
    /// (SFU rejection, codec mismatch, network blip); the handler may restart
    /// the share via ``startScreenShare()``. Forwards to the backing session.
    /// Register it after ``start`` returns — a no-op ``Cancellable`` is returned
    /// if no session exists yet. See ``RealtimeSession/onScreenShareFailed(_:)``.
    public nonisolated func onScreenShareFailed(
        _ handler: @escaping @Sendable (Error) -> Void
    ) -> Cancellable {
        sessionBox.withLock { $0 }?.onScreenShareFailed(handler) ?? Cancellable {}
    }

    // MARK: - Connect + teardown

    private func requireSession() throws -> RealtimeSession {
        guard let session = sessionBox.withLock({ $0 }) else {
            throw VoiceClientError.notConnected
        }
        return session
    }

    private func _connect(
        tools: [String]?,
        declaredTools: [DeclaredClientTool]?,
        backgroundClientToolHandlers: [String: BackgroundClientToolHandler]?,
        voiceName: String?,
        resumeFromCallId: String?,
        providerPreference: String?,
        noiseCancellationEnabled: Bool?,
        storeRecording: Bool,
        interruptionSensitivity: String?,
        thinkingLevel: String?,
        connectGreeting: String?,
        systemPrompt: String?,
        agentName: String?,
        dictation: Bool,
        micMuted: Bool,
        clientToolMethods: [String],
        clientToolHandler: (@Sendable (String, String) async -> String)?,
        screenInteraction: ScreenInteraction?
    ) async throws {
        connectionStateContinuation.yield(.connecting)

        // Wrapped in do/catch in case the engine's ``throws`` contract ever
        // fires; today it's a no-op shell.
        do {
            try await engine.start()
        } catch {
            await teardown(reason: .transportError(message: "audio engine start failed: \(error.localizedDescription)"))
            throw VoiceClientError.audioEngineFailed(message: error.localizedDescription)
        }

        let sessionOptions = Self.makeOptions(credentials: credentials, clientOptions: options)
        // The legacy `tools` server-tool-name roster is intentionally NOT
        // forwarded. On the external protocol client tools flow via
        // `declaredTools` (`.client`), and background / desktop-registry tools
        // are resolved server-side. Forwarding the roster as `.server` 422s the
        // whole start — every desktop tool name is an unknown server tool to
        // the external boundary.
        let config = try Self.makeConfig(
            declaredTools: declaredTools,
            backgroundClientToolHandlers: backgroundClientToolHandlers,
            voiceName: voiceName,
            resumeFromCallId: resumeFromCallId,
            providerPreference: providerPreference,
            noiseCancellationEnabled: noiseCancellationEnabled,
            storeRecording: storeRecording,
            interruptionSensitivity: interruptionSensitivity,
            thinkingLevel: thinkingLevel,
            connectGreeting: connectGreeting,
            systemPrompt: systemPrompt,
            agentName: agentName,
            dictation: dictation,
            screenInteractionEnabled: screenInteraction != nil
        )
        if config.greeting != nil {
            Self.log.notice("voice.client.connect_greeting in session-config")
        }
        var rpcHandlers = Self.makeRpcHandlers(
            methods: clientToolMethods,
            handler: clientToolHandler
        )
        // Register-without-advertise the three screen-interaction RPCs when the
        // host injected a conformer (the app decides inclusion at session start).
        // The bridge's byte-stream publish is bound after `start` returns.
        let screenInteractionBridge: ScreenInteractionBridge? = screenInteraction.map {
            ScreenInteractionBridge(conformer: $0)
        }
        if let screenInteractionBridge {
            rpcHandlers.merge(screenInteractionBridge.handlers()) { _, screenInteraction in screenInteraction }
        }

        let session: RealtimeSession
        let startedAt = Date()
        do {
            session = try await RealtimeSession.start(
                sessionOptions, config: config, micMuted: micMuted, rpcHandlers: rpcHandlers
            )
        } catch {
            // ``RealtimeSession.start`` throws a typed ``RealtimeSessionError``
            // on a server rejection; map it to the wrapper reason so
            // ``ErrorPresentationMapper`` keeps its ``.voiceDisabled`` /
            // ``.handshakeFailed`` branches. Any other error (raw transport /
            // DNS) falls through to ``.transport``.
            let reason = Self.mapStartError(error)
            await teardown(reason: reason ?? .transportError(message: error.localizedDescription))
            throw Self.typedError(for: closeReason, underlying: error)
        }
        sessionBox.withLock { $0 = session }
        // Bind the capture byte-stream publish to the live session. Weak so the
        // session's registered RPC handlers (which retain the bridge) don't
        // retain the session back into a cycle.
        screenInteractionBridge?.bindSendBytes { [weak session] data, topic in
            guard let session else {
                throw ScreenInteractionError(message: "screen_interaction_capture: session ended before publish")
            }
            try await session.send(bytes: data, topic: topic)
        }
        let sessionId = await session.sessionId ?? ""
        currentSessionId = sessionId
        let elapsedMs = Int((Date().timeIntervalSince(startedAt) * 1000).rounded())
        Self.log.notice("sdk.connect ok elapsed_ms=\(elapsedMs, privacy: .public) session_id=\(sessionId, privacy: .public)")

        // Drain the new surface's two streams onto the wrapper's own streams.
        // Events first so a ``ready`` that lands immediately isn't missed.
        startEventLoop(session)
        startStateLoop(session)
        startAgentLiveLoop(session)

        // Yield ``.connected`` on transport-up (start returned) rather than
        // waiting for the ``ready`` event — UI depends on this transition
        // firing before agent dispatch lands.
        if closeReason == nil {
            connectionStateContinuation.yield(.connected(sessionId: sessionId))
            armReadinessWatchdog()
        }
    }

    /// Latch readiness on the agent-track signal too, not only the ``ready``
    /// data frame. The frame is a one-shot broadcast the SFU does not replay to
    /// a client whose data channel came up after it was sent — so a prepared-room
    /// agent that publishes ``ready`` before this client is listening loses it,
    /// and the 20s watchdog then kills an agent that is in fact live and
    /// publishing audio. The track publication is LiveKit's race-free readiness
    /// signal; whichever lands first wins (``markAgentReady`` is idempotent).
    private func startAgentLiveLoop(_ session: RealtimeSession) {
        agentLiveLoop = Task { [weak self] in
            for await _ in session.agentLive {
                await self?.markAgentReady()
                return
            }
        }
    }

    /// The agent published its track before (or without) the ``ready`` frame.
    /// Go live now; a frame that still arrives is absorbed by ``handleReady``,
    /// which stays idempotent.
    private func markAgentReady() {
        guard !didBecomeReady, closeReason == nil else { return }
        didBecomeReady = true
        readinessWatchdog?.cancel()
        readinessWatchdog = nil
        Self.log.notice("readiness via agent track — no ready frame yet; session live")
        yieldEvent(.ready(Ready(sessionId: currentSessionId)))
    }

    /// Arm the readiness watchdog: if the agent's ``ready`` event doesn't arrive
    /// within ``readinessTimeout`` of transport-up, close the session with a
    /// ``transportError`` so the UI leaves "connecting" and can retry — instead
    /// of hanging on a dead/slow agent dispatch the backend won't backstop.
    private func armReadinessWatchdog() {
        readinessWatchdog?.cancel()
        readinessWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.readinessTimeout * 1_000_000_000))
            await self?.fireReadinessTimeoutIfPending()
        }
    }

    private func fireReadinessTimeoutIfPending() async {
        guard !didBecomeReady, closeReason == nil else { return }
        Self.log.error("readiness watchdog fired — no agent ready within \(Self.readinessTimeout, format: .fixed(precision: 1), privacy: .public)s; surfacing")
        await teardown(reason: .agentNotReady(afterSeconds: Int(Self.readinessTimeout)))
    }

    private func startEventLoop(_ session: RealtimeSession) {
        eventLoop = Task { [weak self] in
            do {
                for try await event in session.events {
                    guard let self else { return }
                    if case .sessionEnded = event {
                        // Terminal handled via the state stream's
                        // ``.disconnected``; stop draining.
                        return
                    }
                    await self.handleSessionEvent(event)
                }
            } catch {
                // ``events`` is documented not to throw (mid-session drops end
                // with ``.sessionEnded`` + finish). Treat an unexpected throw as
                // a transport failure so teardown still runs.
                await self?.teardown(reason: .transportError(message: error.localizedDescription))
            }
        }
    }

    private func startStateLoop(_ session: RealtimeSession) {
        stateLoop = Task { [weak self] in
            for await state in session.states {
                guard let self else { return }
                switch state {
                case .reconnecting:
                    await self.yieldConnectionState(.reconnecting)
                case .reconnected:
                    await self.yieldConnectionState(.reconnected)
                case .disconnected(let reason):
                    await self.teardown(reason: Self.mapEndReason(reason))
                case .idle, .connecting, .connected:
                    // The wrapper yields its own application-level
                    // ``.connected`` from ``_connect`` after start returns; the
                    // transport's earlier states are not surfaced.
                    continue
                }
            }
        }
    }

    private func yieldConnectionState(_ state: VoiceConnectionState) {
        guard closeReason == nil else { return }
        connectionStateContinuation.yield(state)
    }

    private func handleSessionEvent(_ event: RealtimeSession.Event) async {
        switch event {
        case .ready(let ready):
            handleReady(ready)
        case .transcript(let delta):
            yieldEvent(.transcript(Self.mapTranscript(delta)))
        case .turnComplete(let turn):
            let role: Role = turn.role == .user ? .user : .assistant
            yieldEvent(.turnComplete(role: role))
        case .toolCall(let call):
            yieldEvent(.toolCall(ToolCall(callId: call.toolCallId, name: call.name)))
        case .toolResult(let result):
            yieldEvent(.toolResult(ToolResult(
                callId: result.toolCallId,
                ok: result.ok,
                summary: result.summary
            )))
        case .toolInvocation(let invocation):
            yieldEvent(.toolInvocation(ToolInvocation(
                requestId: invocation.requestId,
                toolCallId: invocation.toolCallId,
                name: invocation.name,
                args: Self.jsonValueObject(from: invocation.args),
                executable: invocation.executable ?? true
            )))
        case .cosmo(.usage(let usage)):
            yieldEvent(.usage(Self.mapUsage(usage)))
        case .error(let err):
            yieldEvent(.error(ServerError(
                code: err.code.rawValue,
                message: err.message
            )))
        case .pong:
            yieldEvent(.pong)
        case .modelText, .userStartedSpeaking, .userStoppedSpeaking,
             .botStartedSpeaking, .botStoppedSpeaking, .botLlmStarted,
             .botLlmStopped, .botTtsStarted, .botTtsStopped,
             .toolDispatchStarted, .reconnecting, .userSpeechTimeout,
             .unknown:
            // Lifecycle / speaking / model-text events the existing app didn't
            // subscribe to are intentionally dropped (previous behavior).
            break
        case .sessionEnded:
            break
        }
    }

    private func handleReady(_ ready: RealtimeSession.Ready) {
        // Agent is ready — disarm the watchdog so it can't close a live session.
        // The agent-track signal (``markAgentReady``) may have already latched
        // readiness and yielded ``.ready``; if so, don't re-yield it.
        let alreadyReady = didBecomeReady
        didBecomeReady = true
        readinessWatchdog?.cancel()
        readinessWatchdog = nil
        if !alreadyReady {
            yieldEvent(.ready(Ready(sessionId: ready.sessionId)))
        }
    }

    /// Idempotent via ``closeReason``. Yields ``.closed`` before awaiting
    /// ``RealtimeSession/end`` cleanup so consumers see the terminal event
    /// without waiting on SFU teardown.
    ///
    /// Always brings the underlying session down — including the readiness-
    /// watchdog and event-loop-error paths, which previously only tore down
    /// the wrapper and left the LiveKit room (and its billed worker) running.
    /// A watchdog timeout on a genuinely dead agent must still close the room
    /// so the worker exits instead of running until the provider's own session
    /// cap (~10 min). ``RealtimeSession/end`` is idempotent, so the ``end()``
    /// path that already closed is a no-op here.
    private func teardown(reason: ConnectionCloseReason) async {
        guard closeReason == nil else { return }
        closeReason = reason
        readinessWatchdog?.cancel()
        readinessWatchdog = nil
        eventLoop?.cancel()
        eventLoop = nil
        stateLoop?.cancel()
        stateLoop = nil
        agentLiveLoop?.cancel()
        agentLiveLoop = nil
        connectionStateContinuation.yield(.closed(reason: reason))
        connectionStateContinuation.finish()
        eventsContinuation.finish()
        if let session = sessionBox.withLock({ $0 }) {
            await session.end()
        }
    }

    private nonisolated func yieldEvent(_ event: ServerEvent) {
        eventsContinuation.yield(event)
    }

    // MARK: - Config mappers

    static func makeOptions(
        credentials: Credentials,
        clientOptions: ClientOptions
    ) -> RealtimeSession.Options {
        RealtimeSession.Options(
            apiKey: credentials.apiKey,
            baseURL: credentials.apiURL,
            connectTimeout: clientOptions.openTimeout,
            clientIdentity: clientOptions.clientIdentity
        )
    }

    /// The session-config greeting for a start. The opening line rides the
    /// config so the server voices it as soon as the model session opens —
    /// no post-``ready`` client round-trip. A resume never re-greets
    /// mid-conversation, an empty/whitespace greeting means "open
    /// silently" (e.g. dictation, where the agent must wait for the user and
    /// never speak first), and a registry agent runs its stored config
    /// verbatim, so no inline opener rides along.
    ///
    /// This is the whole rule: callers that need to know whether an opening
    /// line will be on the wire ask here rather than re-deriving any part of it.
    static func configGreeting(
        connectGreeting: String?, resumeFromCallId: String?, agentName: String?
    ) -> String? {
        guard
            resumeFromCallId == nil,
            agentName == nil,
            let greeting = connectGreeting,
            !greeting.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return greeting
    }


    static func makeConfig(
        declaredTools: [DeclaredClientTool]?,
        backgroundClientToolHandlers: [String: BackgroundClientToolHandler]?,
        voiceName: String?,
        resumeFromCallId: String?,
        providerPreference: String?,
        noiseCancellationEnabled: Bool?,
        storeRecording: Bool,
        interruptionSensitivity: String?,
        thinkingLevel: String?,
        connectGreeting: String?,
        systemPrompt: String?,
        agentName: String?,
        dictation: Bool,
        screenInteractionEnabled: Bool
    ) throws -> SessionConfig {
        let sensitivity = interruptionSensitivity.flatMap {
            SessionConfig.InterruptionSensitivity(rawValue: $0)
        }
        let thinking = thinkingLevel.flatMap {
            SessionConfig.ThinkingLevel(rawValue: $0)
        }
        let greeting = Self.configGreeting(
            connectGreeting: connectGreeting,
            resumeFromCallId: resumeFromCallId,
            agentName: agentName
        )
        // ``providerPreference`` reshapes onto ``model``: the external boundary
        // maps ``agent.model`` back to the internal ``upstream_preference``.
        var toolSpecs = try makeTools(declared: declaredTools, background: backgroundClientToolHandlers) ?? []
        // Typed server-tool opt-ins ride every session — the app always
        // wants them (e.g. screen share can begin mid-session). The old
        // generic ``cosmo.*`` name references are legacy-endpoint
        // vocabulary; the resolved flow rejects them. The former meta-tool
        // opt-ins are gone entirely — toolkit presentation is server-side
        // policy now.
        toolSpecs.append(.webSearch)
        toolSpecs.append(.examineImage)
        // The locators behind the app's draw_after_detect / draw_after_point
        // renderers — requested here so pointing needs no particular agent.
        toolSpecs.append(.detect)
        toolSpecs.append(.point)
        // Dictation is not a wire concept: it composes from the generic
        // primitives — an empty tool set so the model can only listen, plus
        // ``audioOutput=false`` so it never speaks. The host supplies the
        // silent-microphone instructions and the empty greeting.
        if dictation { toolSpecs = [] }
        // A registry reference runs the stored agent config verbatim — the
        // server rejects stored-config agent fields alongside ``agent.name``,
        // so only the exempt client tools ride along.
        let inline = agentName == nil
        var config = SessionConfig(
            agentName: agentName,
            model: inline ? providerPreference : nil,
            modelOptions: inline ? thinking.map { .gemini(thinkingLevel: $0) } : nil,
            voice: inline ? voiceName : nil,
            audioOutput: dictation ? false : nil,
            instructions: inline ? systemPrompt : nil,
            tools: toolSpecs.isEmpty ? nil : toolSpecs,
            interruptionSensitivity: inline ? sensitivity : nil,
            noiseCancellationEnabled: inline ? noiseCancellationEnabled : nil,
            greeting: greeting,
            resumeSessionId: resumeFromCallId,
            storeRecording: storeRecording
        )
        // The capability is never an authorable tool: the SDK declares it
        // mechanically iff the host supplied a screen-interaction
        // implementation (whose RPC handlers it registers alongside).
        // Dictation strips it with the rest of the tool surface.
        config.declaresScreenInteraction = screenInteractionEnabled && !dictation
        return config
    }

    /// The client tools **advertised** to the agent — one spec per
    /// client-declared desktop tool. A declared tool whose name is in
    /// ``background`` is emitted as a ``.backgroundClient`` spec carrying its
    /// handler (the deferred ack-now/deliver-later path); every other declared
    /// tool is a ``.client`` spec advertised without a handler (execution is
    /// registered separately via ``makeRpcHandlers``, keyed by
    /// ``clientToolMethods``). The opt-in server tools (web search, frame
    /// inspection, the desktop-control tier) are appended as typed opt-in
    /// specs (``.webSearch`` / ``.examineImage`` / ``.detect`` / ``.point``)
    /// in ``makeConfig``, not here, and registry tools are resolved
    /// server-side. The legacy tool-name roster is not forwarded (see
    /// ``_connect``).
    static func makeTools(
        declared: [DeclaredClientTool]?,
        background: [String: BackgroundClientToolHandler]?
    ) throws -> [SessionConfig.Tool]? {
        var specs: [SessionConfig.Tool] = []
        for tool in declared ?? [] {
            let parameters = try JSONDecoder().decode(
                [String: JSONValue].self, from: Data(tool.parametersJSON.utf8)
            )
            if let handler = background?[tool.name] {
                specs.append(.backgroundClient(
                    name: tool.name,
                    description: tool.description,
                    parameters: parameters,
                    handler: handler
                ))
            } else {
                specs.append(.client(
                    name: tool.name,
                    description: tool.description,
                    parameters: parameters,
                    handler: nil
                ))
            }
        }
        return specs.isEmpty ? nil : specs
    }

    /// Register-only RPC handlers keyed by method name — the
    /// ``clientToolMethods`` the app services over RPC — each bridging the
    /// single string-based dispatcher `(method, payload) -> reply` to the SDK's
    /// typed ``ClientToolHandler``. Not advertised (see ``makeTools``); empty
    /// when there is no dispatcher. This is the register-without-advertising
    /// half the legacy ``setClientToolHandler(methods:_:)`` provided — required
    /// by the server-orchestrated grounding RPCs, which are handled but never
    /// listed as agent tools.
    private static func makeRpcHandlers(
        methods: [String],
        handler: (@Sendable (String, String) async -> String)?
    ) -> [String: ClientToolHandler] {
        guard let handler else { return [:] }
        var handlers: [String: ClientToolHandler] = [:]
        for method in methods {
            handlers[method] = { args in
                let payload = String(decoding: try JSONEncoder().encode(args), as: UTF8.self)
                let result = await handler(method, payload)
                return (try? JSONDecoder().decode(
                    [String: JSONValue].self, from: Data(result.utf8)
                )) ?? [:]
            }
        }
        return handlers
    }

    // MARK: - Event mappers

    private static func mapTranscript(_ delta: RealtimeSession.TranscriptDelta) -> Transcript {
        let role: Role = delta.role == .user ? .user : .assistant
        return Transcript(role: role, text: delta.text, isFinal: delta.isFinal)
    }

    private static func mapUsage(_ usage: RealtimeSession.CosmoUsage) -> UsageBreakdown {
        UsageBreakdown(
            inputText: usage.inputTextTokens ?? 0,
            inputImage: usage.inputImageTokens ?? 0,
            inputAudio: usage.inputAudioTokens ?? 0,
            inputCached: usage.inputCachedTokens ?? 0,
            outputText: usage.outputTextTokens ?? 0,
            outputAudio: usage.outputAudioTokens ?? 0,
            total: usage.totalTokens ?? 0
        )
    }

    private static func jsonValueObject(
        from container: RealtimeSession.ToolInvocation.ArgsPayload?
    ) -> [String: JSONValue] {
        guard let container else { return [:] }
        let raw = container.additionalProperties.value
        guard
            let data = try? JSONSerialization.data(withJSONObject: raw, options: []),
            let object = try? JSONDecoder().decode([String: JSONValue].self, from: data)
        else { return [:] }
        return object
    }

    // MARK: - Error mappers

    /// ``RealtimeSession.start`` throw → wrapper ``ConnectionCloseReason``.
    /// Returns nil for errors that don't carry a typed server verdict (raw
    /// transport / DNS failures) so the caller falls back to ``.transport``.
    private static func mapStartError(_ error: Error) -> ConnectionCloseReason? {
        guard let sessionError = error as? RealtimeSessionError else { return nil }
        switch sessionError {
        case .voiceDisabled:
            return .voiceDisabled
        case .handshakeFailed(let status, _, _):
            return .handshakeFailed(status: status)
        case .versionMismatch, .sessionStartFailed, .transportError,
             .alreadyStarted, .notConnected, .invalidPayload,
             .screenShareUnavailable, .insecureBaseURL:
            return nil
        }
    }

    /// New ``RealtimeSession.EndReason`` → wrapper ``ConnectionCloseReason``.
    private static func mapEndReason(_ reason: RealtimeSession.EndReason) -> ConnectionCloseReason {
        switch reason {
        case .clientEnded:                    return .clientEnded
        case .clientClosed:                   return .clientClosed
        case .handshakeFailed(let status, _): return .handshakeFailed(status: status ?? 0)
        case .serverEnded(let reason):        return .serverClosed(code: 0, reason: reason)
        case .transportError(let message):    return .transportError(message: message)
        }
    }

    /// Captured ``ConnectionCloseReason`` → typed ``VoiceClientError``.
    /// ``VoiceSessionModel`` and ``ErrorPresentationMapper`` branch on the typed
    /// cases for upsell + auth-failed UI; opaque ``.transport(underlying:)``
    /// would defeat that.
    private static func typedError(for reason: ConnectionCloseReason?, underlying: Error) -> VoiceClientError {
        guard let reason else {
            return .transport(underlying: underlying)
        }
        switch reason {
        case .voiceDisabled:
            return .voiceDisabled
        case .handshakeFailed(let status):
            return .handshakeFailed(status: status, body: nil)
        case .serverClosed(let code, let reason):
            return .closedByServer(code: code, reason: reason)
        case .transportError(let message):
            return .transport(underlying: NSError(
                domain: "ai.socratic.cosmo-realtime",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: message]
            ))
        case .agentNotReady(let seconds):
            return .transport(underlying: NSError(
                domain: "ai.socratic.cosmo-realtime",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "no agent ready within \(seconds)s"]
            ))
        case .decodeError, .pingTimeout, .clientEnded, .clientClosed:
            // Unreachable from a connect-failure catch. Arms kept explicit so a
            // future case addition trips compile-time exhaustiveness here.
            return .transport(underlying: underlying)
        }
    }

    // MARK: - Pre-connect fallbacks (never observed: accessors touched post-live)

    private static var emptyFloatStream: AsyncStream<Float> {
        AsyncStream { $0.finish() }
    }

    private static let emptyQoESnapshot = SessionQoESnapshot(
        wsMs: nil, roomMs: nil, micMs: nil, totalConnectMs: nil,
        serverTimings: nil, jitterMs: nil, roundTripMs: nil, jitterBufferMs: nil,
        screenShareFps: nil, screenShareEncodeMs: nil,
        screenShareCpuLimitedMs: nil, screenShareBandwidthLimitedMs: nil,
        packetsLost: nil, concealmentEvents: nil, connectionQuality: nil,
        sampleCount: 0
    )
}
