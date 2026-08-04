import Foundation
import Observation
import os

/// Observable view-model owning one ``VoiceSession`` lifecycle. Audio
/// metering lives in the sibling ``LevelMeterModel``.
@available(macOS 14, iOS 17, *)
@Observable
@MainActor
public final class VoiceSessionModel {
    private static let log = Logger(subsystem: CosmoRealtimeLog.subsystem, category: "session-model")

    // MARK: - Observable state

    public private(set) var state: VoiceSessionState = .idle
    public private(set) var transcript: [TranscriptLine] = []

    /// Finalized user lines only, excluding one still being revised
    /// (``TranscriptReducer/inProgressUserLineId``). Append-only, so a consumer
    /// that must not act on volatile hypotheses — e.g. dictation typing into a
    /// field — can read and diff this instead of ``transcript``.
    public var committedUserTranscript: String {
        reducer.lines
            .filter { $0.kind == .user && $0.id != reducer.inProgressUserLineId }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Cumulative per-modality token usage for the live session (nil until the
    /// first usage update arrives).
    public private(set) var usage: UsageBreakdown?
    public private(set) var isMuted: Bool = false
    public private(set) var audioDiagnostics: Diagnostics = Diagnostics()

    /// Tool calls the server has dispatched that haven't reported a
    /// matching ``ToolResult`` yet. Driven by the same `.toolCall` /
    /// `.toolResult` event pair the transcript reducer consumes — keyed
    /// by ``ToolCall.callId`` so dropped or reordered results don't
    /// strand entries. Cleared on session end and on transition out of
    /// ``.live``.
    public private(set) var inFlightTools: [InFlightTool] = []

    /// Bumped by everything that supersedes an in-flight connect: ``start``,
    /// ``end``, and ``closeForRetry``. The connect awaits the transport, and that
    /// await is long enough for the user to cancel, retry, or start again — so a
    /// stale connect must be able to tell that it no longer owns this model,
    /// rather than resurrecting as live or raising its error over the session
    /// that replaced it. Miss a path back to idle and that path gets a second
    /// agent in the room.
    private var startGeneration = 0


    public struct InFlightTool: Identifiable, Sendable, Equatable {
        public let id: String
        public let name: String
        public let startedAt: Date

        public init(id: String, name: String, startedAt: Date) {
            self.id = id
            self.name = name
            self.startedAt = startedAt
        }
    }

    /// Mic + speaker RMS history and "is anyone speaking" decisions.
    /// Views bind through this instead of through the session model so
    /// metering updates don't invalidate the rest of the session UI.
    public let levels: LevelMeterModel

    private let settings: VoiceSettingsStore

    /// Host-supplied replacement for the default opening line. Set before
    /// ``start``; nil keeps the default, empty opens silently.
    public var connectGreetingOverride: String?

    /// Preferred name Cosmo addresses the user by. Reaches the model through
    /// the persona on every session, and by first name in ``connectGreeting``
    /// on the sessions that actually greet — a dictation session gets neither.
    public var userDisplayName: String?

    /// The opening line the server voices verbatim at model-session open.
    var connectGreeting: String {
        ConnectGreeting.openingLine(userDisplayName: userDisplayName)
    }

    public var geminiVoice: GeminiVoice {
        didSet { settings.voice = geminiVoice }
    }

    // MARK: - Lifecycle hooks (analytics, host-side concerns)

    public struct LifecycleHooks: Sendable {
        public var onConnecting: (@MainActor () -> Void)?
        public var onLive: (@MainActor (_ sessionId: String, _ connectDurationMs: Int?) -> Void)?
        /// The session's opening line has been heard: a greeting rode the config
        /// *and* the agent's audio became audible. Fires at most once per
        /// session, never for a resume, a silent override, a session opened by
        /// typing, or a registry agent. A host that spends a one-shot intro on
        /// the first session gates on this — neither the override it passed in
        /// nor reaching ``.live`` survives contact with the ways an opening line
        /// goes unspoken.
        public var onGreetingSpoken: (@MainActor () -> Void)?
        public var onError: (@MainActor (_ presentation: AppErrorPresentation) -> Void)?
        public var onEnded: (@MainActor (_ durationSeconds: Int, _ toolCallCount: Int, _ transportState: String?, _ qoe: SessionQoESnapshot?) -> Void)?
        public var onMuteToggled: (@MainActor (_ muted: Bool) -> Void)?
        public var onToolCall: (@MainActor (_ name: String) -> Void)?
        /// Sleep phrase detected in a live user transcript.
        public var onSleepDetected: (@MainActor () -> Void)?
        /// Forwarded server-issued `tool-invocation` events. The host wires
        /// this to its platform-specific tool dispatcher (e.g. desktop
        /// tools on macOS).
        public var onToolInvocation: (@MainActor (_ session: VoiceSession, _ invocation: ToolInvocation) -> Void)?
        /// Fired once per coalesced "user turn complete" from the HAL
        /// VAD pipeline. Host collects + sends per-turn context here.
        public var onUserTurnComplete: (@MainActor () async -> Void)?

        /// A text turn never reached the model — the wire send failed, or it was
        /// still queued when the session went terminal. Its echoed bubble is
        /// flagged ``deliveryFailed``. Hosts that put UI behind a sent turn (the
        /// Mac's learn-prompt Done spinner waits on the reply to one) bind here,
        /// or they wait forever for an answer to a question that was never asked.
        public var onTextTurnDeliveryFailed: (@MainActor () -> Void)?
        /// Fired on every ``.connecting`` transition before
        /// ``onConnecting``. Hosts use it to clear per-session caches.
        public var onSessionReset: (@MainActor () -> Void)?
        /// Fired once per session when the agent's audio first becomes
        /// audible: the joined startup waterfall (server start phases +
        /// client connect phases + first-audio arrival), keyed by
        /// session_id. Hosts route to analytics.
        public var onStartupWaterfall: (@MainActor (_ sessionId: String, _ connectToFirstAudioMs: Int, _ qoe: SessionQoESnapshot?) -> Void)?

        public init() {}
    }

    public var hooks = LifecycleHooks()

    /// Client-tool RPC config (P6): the method names this client can service
    /// plus the handler that resolves the worker's ``perform_rpc`` calls. Set
    /// by the host app before ``start``; forwarded into every ``VoiceSession``
    /// (including reconnects) so client tools work on the worker-pool path.
    public var clientTool: (methods: [String], handler: @Sendable (String, String) async -> String)?

    /// Client tools that carry their own handler — the SDK-shipped ones a host
    /// wires with a closure (``SessionConfig/Tool/drawBox(onDraw:)`` and
    /// friends). Unlike ``clientTool`` these need no method roster and no
    /// name routing: the handler rides on the spec. Set before ``start``;
    /// forwarded into every ``VoiceSession``, reconnects included.
    public var clientTools: [SessionConfig.Tool] = []

    /// Background (deferred) client-tool handlers keyed by tool name. A declared
    /// tool named here executes on the ack-now/deliver-later path — the handler
    /// acks the call, then delivers its terminal result later over
    /// ``tool_job_result`` — instead of the synchronous ``clientTool``
    /// dispatcher. Set by the host app before ``start``; forwarded into every
    /// ``VoiceSession`` (including reconnects).
    public var backgroundClientTools: [String: BackgroundClientToolHandler]?

    // MARK: - Internals

    private var reducer = TranscriptReducer()

    // MARK: Assistant caption pacing
    //
    // The model generates the assistant transcript several times faster than
    // the TTS audio plays it, so rendering each wire delta the instant it
    // arrives races the caption ahead of the voice. Feed the assistant line
    // through a ``TranscriptRevealer`` that reveals word-by-word at a
    // per-voice cadence (``RevealCadence``), decoupled from the chunky,
    // ahead-of-audio wire cadence. The user's own transcript is left immediate.
    // The reducer stays the source of truth for structure (which line, tools,
    // ordering); only the still-revealing assistant line's *displayed text* is
    // the paced prefix. This fixes the same race the Mac app and SDK adopters
    // hit (they all render straight from the reducer).
    private var asstRevealer: TranscriptRevealer?
    private var asstRevealTask: Task<Void, Never>?
    /// Serializes ``TranscriptRevealer/setTarget(_:isFinal:)`` calls in the
    /// order deltas arrive. Each delta must hop to the revealer actor (an async
    /// call from this sync `@MainActor` context); dispatching an independent
    /// `Task` per delta lets them run out of order under load, so a stale
    /// shorter target could clobber a newer longer one and stall the reveal
    /// short of the final. Chaining each call after the previous one preserves
    /// submission order.
    private var asstSetTargetChain: Task<Void, Never>?
    /// Reducer line id of the assistant line currently being revealed, or nil
    /// between assistant turns.
    private var asstRevealLineId: UUID?
    /// Latest word-aligned prefix the revealer has emitted for that line.
    private var asstRevealedPrefix = ""
    /// The turn's final (longest) cumulative text, once the wire final has
    /// arrived. The reveal keeps pacing toward it and finishes only when the
    /// paced prefix catches it — never snapping, since the wire final lands
    /// well before the voice finishes and snapping would dump the tail early.
    private var asstFinalText: String?
    /// Bumped on every new session so a straggling reveal task from a prior
    /// session can't write into the new session's transcript.
    private var sessionGeneration = 0

    /// Output silence, after the wire final has landed, that means the voice is
    /// done rather than mid-sentence. Longer than an inter-sentence pause.
    private static let tailFlushSilence: TimeInterval = 0.7
    /// Cadence the remaining words drain at once the voice has stopped — fast
    /// enough to settle within about half a second, slow enough to read as a
    /// completion rather than a dump.
    private static let tailFlushInterval: Duration = .milliseconds(40)

    /// Test seam: when set, overrides the per-voice ``RevealCadence`` so unit
    /// tests can pace the reveal fast enough to assert on. Nil in production.
    internal var assistantRevealIntervalOverride: Duration?

    /// Test seam: the in-flight reveal, so a test can await the paced line
    /// settling instead of polling a wall clock it cannot bound on a loaded
    /// machine. Completes once the reveal has caught the final text.
    internal var assistantRevealTask: Task<Void, Never>? { asstRevealTask }

    /// User text turns submitted before the session is live, echoed into the
    /// transcript immediately and flushed to the wire on ``.ready``. Each keeps
    /// the echoed line's id so a failed flush can flag that bubble.
    private var pendingTexts: [(id: UUID, text: String)] = []

    private var session: VoiceSession?
    private var eventsTask: Task<Void, Never>?
    private var connectionStateTask: Task<Void, Never>?
    private var levelMeterTasks: [Task<Void, Never>] = []
    private var diagnosticsTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    /// In-flight teardown task — the next ``startTurnCompleteMonitor``
    /// awaits it so a fast restart can't race the old monitor's
    /// ``enable=0`` against the new monitor's ``enable=1``.
    private var pendingTeardown: Task<Void, Never>?
    private var activeMonitor: (any VoiceActivityMonitoring)?

    private var sessionLiveStartedAt: Date?
    /// Whether this session's config carries an opening line.
    private var greetingSentThisSession = false
    /// Latches once ``onGreetingSpoken`` has fired for this session.
    private var greetingSpokenLogged = false
    private var sessionToolCallCount = 0
    private var connectingStartedAt: Date?
    private var lastTransportStateLabel: String?
    /// Final QoE snapshot captured before the session reference is dropped
    /// (``end()`` nils ``session`` before the ``.idle`` transition reaches
    /// ``endLiveSessionIfNeeded``). The spontaneous-disconnect path still has
    /// a live ``session`` and reads it directly.
    private var lastQoESnapshot: SessionQoESnapshot?

    /// Whether a VPIO warm is currently held.
    private var micWarmHeld = false

    /// ``micWarmHeld`` sampled when the connect began. Logged on the `.live`
    /// transition so a `mic_ms` reading is attributable to a warm or cold
    /// engine. Sampled rather than read live because a host can drop the warm
    /// mid-connect (macOS collapses its dock on a press), which would
    /// otherwise relabel a warm connect as cold.
    private var micWarmAtConnect = false

    /// Credentials from the most recent ``start`` (or the prepared-session
    /// refresh), re-used to prime a parked prepared session between sessions.
    private var lastStartCredentials: Credentials?

    /// Client options from the most recent ``start`` (or the prepared-session
    /// refresh), so a parked prepared session is opened with the same client
    /// identity and timeouts a real start would use.
    private var lastClientOptions = ClientOptions()

    /// Injected turn-completion VAD monitor factory — the macOS HAL impl
    /// lives in core. `nil` ⇒ no turn-context monitor (e.g. iOS).
    private let voiceActivityMonitorFactory: (@MainActor () -> any VoiceActivityMonitoring)?
    private var sleepMatcher = PhraseMatcher(phrase: "sleep cosmo")

    /// Captured on ``.live``.
    private var currentLiveSessionId: String?

    // Client-perceived latency telemetry, reset per session in the ``.live``
    // transition. The first agent audio that becomes audible
    // (``LevelMeterModel.onSpeakerBecameAudible``) closes both the connect
    // (first-audio arrival) and the first-turn measurement — the latter timed
    // against the user's last mic activity, so it never depends on the optional
    // HAL VAD turn monitor.
    private var firstAudioLogged = false
    private var firstTurnLogged = false

    public init(
        settings: VoiceSettingsStore = VoiceSettingsStore(),
        levels: LevelMeterModel? = nil,
        voiceActivityMonitorFactory: (@MainActor () -> any VoiceActivityMonitoring)? = nil
    ) {
        self.settings = settings
        self.levels = levels ?? LevelMeterModel()
        self.voiceActivityMonitorFactory = voiceActivityMonitorFactory
        self.geminiVoice = settings.voice
    }

    // MARK: - State machine

    /// Begin a session against an already-resolved ``Credentials``. The
    /// host (`AppModel` on macOS) supplies the credentials and the
    /// platform-specific tool preset; this method owns the wire-up.
    public func start(
        credentials: Credentials,
        tools: [String]? = nil,
        declaredTools: [DeclaredClientTool]? = nil,
        resumeFromCallId: String? = nil,
        providerPreference: String? = nil,
        systemPrompt: String? = nil,
        agentName: String? = nil,
        dictation: Bool = false,
        micMuted: Bool = false,
        options: ClientOptions = .init()
    ) {
        // Manual Talk button from idle, or a retry from a failed connect —
        // `.error` is a terminal state whose session was already torn down,
        // and the dock hotkey routes it here.
        switch state {
        case .idle, .error:
            break
        default:
            Self.log.warning("start refused: state=\(Self.stateName(self.state), privacy: .public) — only idle/error can start")
            return
        }

        // Kick the capture engine's spin-up at the press so it overlaps the
        // REST + signaling legs instead of landing in the join's pc_created
        // phase. Not VPIO's cold-build specifically anymore — capture now
        // runs software processing (see ``RealtimeSession/audioCaptureOptions``)
        // — but removing this and letting the real publish be the sole
        // capture-open point (tested directly) made no difference to the
        // residual connecting-time transient, so it stayed disabled for no
        // benefit. Restored: it's still a legitimate latency overlap.
        touchMicWarmWindow()

        let voiceName = self.geminiVoice.rawValue

        // Cache the credentials so a prepared session can be re-primed between
        // sessions (see ``refreshPreparedSessionNow``).
        lastStartCredentials = credentials
        lastClientOptions = options

        // Preserve any text turns queued while idle (type-before-you-talk):
        // ``sendText`` echoed their bubbles and queued them FOR this session, so
        // they must survive the reset below and still flush on .ready. Terminal
        // states (``failPendingTexts``) clear the queue, so this holds only the
        // texts queued for the session about to start.
        let queuedTexts = pendingTexts

        transition(to: .connecting)
        reducer.reset()
        beginNewTranscriptGeneration()   // bumps the generation; clears the queue
        pendingTexts = queuedTexts       // ...which we restore for this session
        // Start-muted (type-before-you-talk): the session comes up with the mic
        // gated, so the UI reflects it immediately and the mic track publishes
        // muted. A toggle during connect only moves ``isMuted``; it's reconciled
        // onto the published track on the .live transition (``applyMuteOnLive``).
        isMuted = micMuted
        sleepMatcher = PhraseMatcher(phrase: "sleep cosmo")
        // Re-echo the queued user bubbles into the fresh reducer under their
        // original ids (so a later failed flush still flags the right bubble),
        // then show them beneath the connecting banner.
        for item in queuedTexts {
            reducer.appendUserText(item.text, id: item.id)
        }
        let banner = TranscriptLine(kind: .system, text: "Connecting...")
        transcript = [banner] + reducer.lines
        // A session opened with a typed question must not be answered with a
        // self-introduction: suppress the connect greeting when text is queued
        // (an empty greeting opens silently, so the model answers the question).
        let suppressGreeting = !queuedTexts.isEmpty
        let greeting = suppressGreeting ? "" : (connectGreetingOverride ?? self.connectGreeting)
        greetingSentThisSession = VoiceSession.configGreeting(
            connectGreeting: greeting,
            resumeFromCallId: resumeFromCallId,
            agentName: agentName
        ) != nil

        startGeneration &+= 1
        let generation = startGeneration

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                Self.log.info(
                    "start backend=\(credentials.apiURL.host() ?? "?", privacy: .public) resumeFromCallId=\(resumeFromCallId ?? "nil", privacy: .public)"
                )
                let session = try await VoiceSession.start(
                    credentials: credentials,
                    tools: tools,
                    declaredTools: declaredTools,
                    clientTools: clientTools,
                    backgroundClientToolHandlers: backgroundClientTools,
                    voiceName: voiceName,
                    resumeFromCallId: resumeFromCallId,
                    providerPreference: providerPreference,
                    noiseCancellationEnabled: self.settings.noiseCancellationPreference,
                    storeRecording: self.settings.storeServerRecording,
                    interruptionSensitivity: self.settings.reducedInterruptionSensitivity ? "low" : nil,
                    thinkingLevel: self.settings.thinkingLevel,
                    connectGreeting: greeting,
                    systemPrompt: systemPrompt,
                    speakingStyle: ConnectGreeting.nameDirective(
                        userDisplayName: self.userDisplayName, dictation: dictation
                    ),
                    agentName: agentName,
                    dictation: dictation,
                    micMuted: micMuted,
                    clientToolMethods: clientTool?.methods ?? [],
                    clientToolHandler: clientTool?.handler,
                    options: options
                )
                // Ended or restarted while the transport was connecting. The room
                // is up regardless, so tear it down rather than drop it on the
                // floor — an orphaned session keeps a live LiveKit room and a
                // billed agent running with nothing attached to it.
                guard generation == self.startGeneration else {
                    Self.log.info("start superseded mid-connect; tearing down the orphaned session")
                    await session.end()
                    return
                }
                self.session = session
                self.startEventLoop(for: session)
                self.startConnectionStateLoop(for: session)
                self.startLevelMeterPump(for: session)
            } catch let err as VoiceClientError {
                Self.log.error("start failed (typed): \(String(describing: err), privacy: .public)")
                guard generation == self.startGeneration else { return }
                let presentation = ErrorPresentationMapper.presentation(
                    err,
                    heardTranscript: self.lastUserTranscript()
                )
                self.transition(to: .error(presentation))
            } catch {
                Self.log.error("start failed: \(error.localizedDescription, privacy: .public)")
                // A superseded connect's failure is not the live session's
                // failure: raising it here would drop the flow that replaced us
                // into `.error` and run its teardown.
                guard generation == self.startGeneration else { return }
                let presentation = AppErrorPresentation(
                    headline: "Couldn't start session",
                    message: error.localizedDescription,
                    heardTranscript: self.lastUserTranscript(),
                    actions: [.retry, .revealLogs]
                )
                self.transition(to: .error(presentation))
            }
        }
    }

    /// Tear down the active session. Idempotent.
    public func end() {
        switch state {
        case .idle:
            return
        default:
            break
        }
        Self.log.info("end()")
        // Orphan any connect still in flight: ending during `.connecting` means
        // the transport may still be coming up, and without this its task lands
        // afterwards and re-adopts the session the user just cancelled.
        startGeneration &+= 1
        let s = session
        lastQoESnapshot = s?.qoeSnapshot
        transition(to: .ending)
        cancelTasks()
        levels.reset()
        session = nil
        isMuted = false
        Task { @MainActor [weak self] in
            await s?.end()
            guard let self else { return }
            self.transition(to: .idle)
            self.appendTranscript(kind: .system, text: "Session ended.")
        }
    }

    /// Fully close the current session before a silent connect retry: shut the
    /// transport (so the backend reaps any agent the failed attempt dispatched)
    /// and return to a startable state. Unlike ``end()`` it is awaitable — so a
    /// retry can guarantee the prior session is gone before the next ``start``,
    /// never leaving two agents in one room — and it does not append the
    /// user-facing "Session ended." transcript line.
    public func closeForRetry() async {
        // Orphan any connect still awaiting the transport, exactly as ``end()``
        // does. Without this the generation never moves, so a connect that is
        // still in ``VoiceSession.start`` sails through the staleness check and
        // installs itself *after* the retry closed — which is the two-agents-in-
        // one-room this method exists to prevent.
        startGeneration &+= 1
        let s = session
        session = nil
        cancelTasks()
        levels.reset()
        isMuted = false
        await s?.end()
        if case .idle = state { return }
        transition(to: .idle)
    }

    public func toggleMute() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.setMuted(!self.isMuted)
        }
    }

    /// Set the mic mute state. ``VoiceSessionModel`` owns ``isMuted`` — the
    /// single source of truth every host binds to. When the session is live the
    /// local mic track is gated immediately (``VoiceSession/setMuted(_:)`` gates
    /// locally first, so the trust guarantee holds regardless of the wire hint);
    /// before the session is live the intent is staged into ``isMuted`` and
    /// applied to the track on the .live transition (``applyMuteOnLive``). Hosts
    /// route their mute button here instead of poking the raw session, so the
    /// observable ``isMuted`` can never go stale under the UI.
    public func setMuted(_ muted: Bool) async {
        guard isMuted != muted else { return }
        isMuted = muted
        Self.log.info("setMuted -> \(muted, privacy: .public)")
        hooks.onMuteToggled?(muted)
        guard let session, state.isLive else { return }
        await session.setMuted(muted)
    }

    /// Reconcile the mute intent onto the freshly-published mic track. The
    /// initial ``micMuted`` was baked into the connect, but a mute/unmute *during*
    /// connect only moved ``isMuted``; apply the current value now the track
    /// exists so a during-connect toggle isn't silently lost.
    private func applyMuteOnLive() {
        guard let session else { return }
        let muted = isMuted
        Task { @MainActor in await session.setMuted(muted) }
    }

    /// Map an error-presentation action to the right behavior. The host
    /// wraps this with platform-specific bits (opening the credentials
    /// file in Finder, opening URLs, revealing log dirs).
    public func handleRetry() {
        if case .error = state {
            transition(to: .idle)
        }
    }

    /// Direct access to the live session for callers that need to send
    /// out-of-band frames (screen-share track publication, tool replies).
    /// Returns `nil` outside `.live`.
    public var currentSession: VoiceSession? { session }

    /// Append a system-kind transcript line directly. Hosts use this for
    /// platform-specific status messages (e.g. "Sharing screen with the
    /// assistant." on macOS).
    public func appendSystem(_ text: String) {
        appendTranscript(kind: .system, text: text)
    }

    /// Publish a binary client-tool payload over a LiveKit byte stream on
    /// the live session. Throws when no session is connected.
    public func sendBytes(_ data: Data, topic: String) async throws {
        guard let session else {
            throw CosmoRealtimeError.notConnected
        }
        try await session.sendBytes(data, topic: topic)
    }

    /// Send a user text turn (composer send). The text is echoed into the
    /// transcript immediately. When the session is live it goes to the wire
    /// now; otherwise it's queued and flushed on ``.ready`` — the host is
    /// responsible for having started (or being about to start) a session,
    /// typically ``start(micMuted: true)`` for type-before-you-talk. A failed
    /// wire send flags the echoed bubble ``deliveryFailed`` so the user knows
    /// the model never received it.
    public func sendText(_ content: String) {
        let lineId = reducer.appendUserText(content)
        publishTranscript()

        guard case .live = state, let session else {
            // Queued before live: the model has no floor to hold yet. The flush
            // hands it over.
            pendingTexts.append((lineId, content))
            return
        }
        Task { @MainActor [weak self] in
            do {
                try await session.sendText(content)
            } catch {
                Self.log.error("text turn send failed: \(error.localizedDescription, privacy: .public)")
                self?.reducer.markDeliveryFailed(id: lineId)
                self?.publishTranscript()
                self?.hooks.onTextTurnDeliveryFailed?()
            }
        }
    }

    /// Flush any text turns queued before the session went live. Called once the
    /// session is live (``.ready``). One task, one sequential loop: the turns were
    /// typed in order and must hit the wire in order — dispatching a task per turn
    /// lets two messages arrive reversed. A per-turn failure flags its echoed
    /// bubble ``deliveryFailed``.
    private func flushPendingTexts() {
        guard case .live = state, let session, !pendingTexts.isEmpty else { return }
        let pending = pendingTexts
        pendingTexts.removeAll()
        Task { @MainActor [weak self] in
            for item in pending {
                do {
                    try await session.sendText(item.text)
                } catch {
                    Self.log.error("queued text flush failed: \(error.localizedDescription, privacy: .public)")
                    self?.reducer.markDeliveryFailed(id: item.id)
                    self?.publishTranscript()
                    self?.hooks.onTextTurnDeliveryFailed?()
                }
            }
        }
    }

    /// Flag every still-queued (never-flushed) text turn ``deliveryFailed`` and
    /// drop the queue. Called on terminal transitions (``.error`` / ``.ending``)
    /// so a typed-before-connect bubble that never reached the model is marked
    /// failed — and a never-live queue can't leak into the next session's start,
    /// which snapshots ``pendingTexts`` to preserve type-before-you-talk.
    private func failPendingTexts() {
        guard !pendingTexts.isEmpty else { return }
        for item in pendingTexts {
            reducer.markDeliveryFailed(id: item.id)
        }
        pendingTexts.removeAll()
        publishTranscript()
        hooks.onTextTurnDeliveryFailed?()
    }

    /// Warm the mic capture engine (LiveKit's VoiceProcessingIO) so a
    /// connect skips the ~1–1.5s VPIO cold build inside ``pc_created``.
    /// A live VPIO unit makes macOS route the speaker through the voice-comm
    /// path and audibly degrades playback, so the warm must be bounded to a
    /// genuine connect intent and dropped once idle — ``releaseMicWarm``
    /// does so on the return to idle/error.
    public func touchMicWarmWindow() {
        Self.log.info("mic warm enabled")
        micWarmHeld = true
        MicPrewarmCoordinator.set(true)
    }

    /// Drop the VPIO warm so an idle app holds no input device (and the
    /// speaker leaves the voice-comm path). Idempotent.
    public func releaseMicWarm() {
        Self.log.info("mic warm released")
        micWarmHeld = false
        MicPrewarmCoordinator.set(false)
    }

    /// Drop the VPIO warm and wait for the queued teardown to complete. For
    /// callers about to open the input device through another engine (the
    /// note-taker's passive tap): a live VPIO unit in this process leaves the
    /// device in the voice-comm configuration and starves a plain tap on it.
    public func releaseMicWarmAndSettle() async {
        releaseMicWarm()
        await MicPrewarmCoordinator.settle()
    }

    private var preparedSessionRefreshTask: Task<Void, Never>?

    /// Begin keeping a prepared session parked: prime now and refresh on a
    /// ~20-min cadence so a press after an idle period still joins on a held
    /// token. The interval is comfortably under the prepared join-token TTL
    /// (server: 30 min, matching the room) so the held token is always
    /// mid-life — the SDK additionally discards a parked session older than its
    /// max-age guard and falls back, so a missed tick is never fatal. The
    /// longer cadence (vs the token TTL) keeps room/token churn low. Call on
    /// sign-in once credentials exist. Caches credentials for the loop and for
    /// teardown / wake re-priming. Idempotent.
    public func startPreparedSessionRefresh(
        credentials: Credentials,
        options: ClientOptions = .init()
    ) {
        lastStartCredentials = credentials
        lastClientOptions = options
        preparedSessionRefreshTask?.cancel()
        preparedSessionRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.refreshPreparedSessionNow()
                try? await Task.sleep(for: .seconds(1200))
            }
        }
    }

    /// Stop the prepared-session refresh loop (e.g. sign-out). Also drops the
    /// VPIO warm so a signed-out app holds no input device, and the parked
    /// prepared session — its room grant is bound to the signing-out user.
    public func stopPreparedSessionRefresh() {
        preparedSessionRefreshTask?.cancel()
        preparedSessionRefreshTask = nil
        RealtimeSession.discardPreparedSession()
        releaseMicWarm()
    }

    /// Prime a prepared session once using the cached credentials. Safe on
    /// wake / teardown; no-op before sign-in (connect falls back to the
    /// synchronous path). Best-effort — failures are logged, not surfaced.
    public func refreshPreparedSessionNow() {
        guard let credentials = lastStartCredentials else { return }
        let options = lastClientOptions
        Task.detached(priority: .utility) {
            do {
                try await VoiceSession.prepareSession(
                    credentials: credentials,
                    options: options
                )
            } catch {
                // Local logger: ``Self.log`` is main-actor-isolated and this
                // runs on a detached task.
                Logger(subsystem: CosmoRealtimeLog.subsystem, category: "session-model")
                    .info("prepared session refresh failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    public func markPreflightError(_ presentation: AppErrorPresentation) {
        // The `.error` transition fires `onError` itself; firing here too
        // double-delivered every preflight failure to the host. The direct
        // fire remains only for a repeat of the identical failure, where the
        // transition would no-op yet the new occurrence must still reach the
        // host (per-attempt analytics, mode cleanup).
        if state == .error(presentation) {
            hooks.onError?(presentation)
            return
        }
        transition(to: .error(presentation))
    }

    // MARK: - Internals

    private func transition(to newState: VoiceSessionState) {
        guard state != newState else { return }
        Self.log.info("state: \(Self.stateName(self.state), privacy: .public) -> \(Self.stateName(newState), privacy: .public)")
        let previous = state
        state = newState
        switch newState {
        case .connecting:
            cancelTasksIfLeftOver(previous: previous)
            connectingStartedAt = Date()
            micWarmAtConnect = micWarmHeld
            lastTransportStateLabel = nil
            // Fire reset BEFORE onConnecting so hosts can clear their
            // per-session caches (e.g. context-hook diff state) before
            // any analytics-side onConnecting work runs.
            hooks.onSessionReset?()
            hooks.onConnecting?()
        case .live(let sid):
            sessionLiveStartedAt = Date()
            sessionToolCallCount = 0
            currentLiveSessionId = sid
            firstAudioLogged = false
            firstTurnLogged = false
            greetingSpokenLogged = false
            levels.onSpeakerBecameAudible = { [weak self] in
                self?.onFirstAgentAudioAudible()
            }
            let connectDurationMs = connectingStartedAt.map {
                Int((Date().timeIntervalSince($0) * 1000).rounded())
            }
            connectingStartedAt = nil
            // .notice (persisted, unlike the .info transitions above) so the
            // button→server-ready latency survives in `log show` even when
            // PostHog capture is off — e.g. local dev against a localhost API.
            let phases = session?.qoeSnapshot
            Self.log.notice("connect complete session_id=\(sid, privacy: .public) connect_duration_ms=\(connectDurationMs ?? -1, privacy: .public) ws_ms=\(Self.msField(phases?.wsMs), privacy: .public) room_ms=\(Self.msField(phases?.roomMs), privacy: .public) mic_ms=\(Self.msField(phases?.micMs), privacy: .public) total_ms=\(Self.msField(phases?.totalConnectMs), privacy: .public) mic_warm=\(self.micWarmAtConnect, privacy: .public) greeting_sent=\(self.greetingSentThisSession, privacy: .public)")
            startTurnCompleteMonitor()
            // Reconcile a during-connect mute/unmute onto the now-live track.
            applyMuteOnLive()
            hooks.onLive?(sid, connectDurationMs)
        case .error(let presentation):
            hooks.onError?(presentation)
            endLiveSessionIfNeeded()
            tearDownMonitorIfNeeded()
            releaseMicWarm()
            failPendingTexts()
        case .ending:
            tearDownMonitorIfNeeded()
            failPendingTexts()
        case .idle:
            endLiveSessionIfNeeded()
            tearDownMonitorIfNeeded()
            // Drop the VPIO warm now that the session is over so the idle
            // app stops routing the speaker through the voice-comm path.
            // Only the LiveKit signaling path is kept warm for a likely
            // back-to-back session; VPIO comes back up on the next press.
            releaseMicWarm()
            Task.detached(priority: .utility) {
                await RealtimeSession.prewarmConnection(origin: .teardown)
            }
            // Park a prepared session (room + pre-minted token) so the next
            // press joins on the held token without waiting on /session/start.
            refreshPreparedSessionNow()
        }
    }

    private func cancelTasksIfLeftOver(previous: VoiceSessionState) {
        switch previous {
        case .live, .ending:
            cancelTasks()
        default:
            break
        }
    }

    private func cancelTasks() {
        eventsTask?.cancel(); eventsTask = nil
        connectionStateTask?.cancel(); connectionStateTask = nil
        for task in levelMeterTasks { task.cancel() }
        levelMeterTasks.removeAll()
        levels.onSpeakerBecameAudible = nil
        diagnosticsTask?.cancel(); diagnosticsTask = nil
    }

    /// Spawn the turn-completion VAD monitor + coalescer task. Idempotent.
    /// No-op unless a ``voiceActivityMonitorFactory`` was injected (the macOS
    /// HAL impl lives in core; iOS injects nothing).
    private func startTurnCompleteMonitor() {
        guard activeMonitor == nil,
              hooks.onUserTurnComplete != nil,
              let monitor = voiceActivityMonitorFactory?() else { return }
        let priorTeardown = pendingTeardown
        pendingTeardown = nil
        activeMonitor = monitor
        monitorTask = Task { @MainActor [weak self, monitor, priorTeardown] in
            if let priorTeardown { _ = await priorTeardown.value }
            guard let self else { return }
            let coalescer = TurnCompleteCoalescer(onTurnComplete: { [weak self] in
                await self?.hooks.onUserTurnComplete?()
            })
            let events: AsyncStream<VoiceActivityEvent>
            do {
                events = try await monitor.start()
            } catch {
                Self.log.warning("HAL VAD unavailable; turn-context hook idle until device change: \(String(describing: error), privacy: .public)")
                return
            }
            for await event in events {
                coalescer.ingest(event)
            }
        }
    }

    /// Tear down the HAL monitor + coalescer task. The teardown is
    /// parked in ``pendingTeardown`` so a subsequent restart awaits it.
    /// Order matters: ``stop()`` finishes the AsyncStream, which lets
    /// the consumer's for-await loop exit; cancel-then-await alone
    /// would deadlock.
    private func tearDownMonitorIfNeeded() {
        guard activeMonitor != nil || monitorTask != nil else { return }
        let task = self.monitorTask
        let monitor = self.activeMonitor
        self.monitorTask = nil
        self.activeMonitor = nil
        pendingTeardown = Task { @MainActor in
            await monitor?.stop()
            task?.cancel()
            _ = await task?.value
        }
    }

    private func endLiveSessionIfNeeded() {
        guard let startedAt = sessionLiveStartedAt else { return }
        let duration = Int(Date().timeIntervalSince(startedAt).rounded())
        let qoe = session?.qoeSnapshot ?? lastQoESnapshot
        hooks.onEnded?(duration, sessionToolCallCount, lastTransportStateLabel, qoe)
        sessionLiveStartedAt = nil
        sessionToolCallCount = 0
        inFlightTools.removeAll()
        if !reducer.closeDanglingToolLines().isEmpty {
            publishTranscript()
        }
        lastTransportStateLabel = nil
        lastQoESnapshot = nil
        currentLiveSessionId = nil
    }

    private func startEventLoop(for session: VoiceSession) {
        eventsTask = Task { @MainActor [weak self] in
            for await event in session.events {
                guard let self else { return }
                self.handle(event, session: session)
            }
            guard let self else { return }
            if case .live = self.state {
                self.transition(to: .idle)
                self.appendTranscript(kind: .system, text: "Disconnected.")
            }
        }
    }

    private func startConnectionStateLoop(for session: VoiceSession) {
        connectionStateTask = Task { @MainActor [weak self] in
            for await s in session.connectionState {
                guard let self else { return }
                self.handle(connectionState: s)
            }
        }
    }

    /// Agent audio becoming audible on this device. Emits two once-per-session
    /// client-perceived measurements the server can't see, both timed off the
    /// always-on mic meter (``lastMicActivityAt`` — no dependency on the optional
    /// HAL VAD monitor), tagged with ``session_id`` to join the server events:
    ///   • ``voice.client.first_audio``: connect → first agent audio arrival.
    ///   • ``voice.client.first_turn``: the user's last speech → first agent
    ///     audio audible (felt first-response latency), with the QoE split
    ///     (``rtt_ms`` = client↔SFU round trip, ``jitter_buffer_ms`` = downlink
    ///     playout). Per-session, not per-turn — the latency profile is stable
    ///     within a session, so first-turn + session-end is the right
    ///     granularity (per-turn would multiply log volume for no added signal).
    private func onFirstAgentAudioAudible() {
        guard let sid = currentLiveSessionId else { return }
        let now = Date()
        // The opening line only counts as heard once agent audio is actually
        // audible: a greeting on the config can still go unvoiced (buffered as
        // context by the provider, dropped server-side, or cut off by a
        // connection that dies right after readiness).
        if greetingSentThisSession, !greetingSpokenLogged {
            greetingSpokenLogged = true
            Self.log.notice("voice.client.greeting_spoken session_id=\(sid, privacy: .public)")
            hooks.onGreetingSpoken?()
        }
        if !firstAudioLogged, let liveAt = sessionLiveStartedAt {
            firstAudioLogged = true
            let ms = Int((now.timeIntervalSince(liveAt) * 1000).rounded())
            Self.log.notice(
                "voice.client.first_audio session_id=\(sid, privacy: .public) connect_to_first_audio_ms=\(ms, privacy: .public)"
            )
            hooks.onStartupWaterfall?(sid, ms, session?.qoeSnapshot)
        }
        guard !firstTurnLogged, levels.micHasBeenAudible else { return }
        firstTurnLogged = true
        let ms = Int((now.timeIntervalSince(levels.lastMicActivityAt) * 1000).rounded())
        let q = session?.qoeSnapshot
        Self.log.notice(
            "voice.client.first_turn session_id=\(sid, privacy: .public) response_latency_ms=\(ms, privacy: .public) rtt_ms=\(Self.qoeField(q?.roundTripMs), privacy: .public) jitter_ms=\(Self.qoeField(q?.jitterMs), privacy: .public) jitter_buffer_ms=\(Self.qoeField(q?.jitterBufferMs), privacy: .public) qoe_samples=\(q?.sampleCount ?? 0, privacy: .public)"
        )
    }

    /// p50 of a QoE metric summary as an integer-ms string, or "n/a" when no
    /// samples have been collected yet (stats poll at ~1 Hz, so an early first
    /// turn may have few or none).
    private static func qoeField(_ summary: SessionQoEMetricSummary?) -> String {
        guard let summary, summary.count > 0 else { return "n/a" }
        return String(Int(summary.p50.rounded()))
    }

    /// A connect-phase duration as an integer-ms string, or "n/a" before the
    /// phase has been recorded.
    private static func msField(_ ms: Double?) -> String {
        guard let ms else { return "n/a" }
        return String(Int(ms.rounded()))
    }

    private func startLevelMeterPump(for session: VoiceSession) {
        levelMeterTasks = levels.startPump(for: session)
        diagnosticsTask = Task { @MainActor [weak self] in
            while self?.state.isLive == true {
                try? await Task.sleep(for: .milliseconds(1000))
                guard let self else { return }
                self.audioDiagnostics = session.diagnostics
            }
        }
    }

    private func handle(connectionState s: VoiceConnectionState) {
        lastTransportStateLabel = Self.transportStateLabel(s)
        switch s {
        case .idle:
            Self.log.debug("connection state: idle")
        case .connecting:
            Self.log.debug("connection state: connecting")
        case .connected(let sid):
            Self.log.info("connection state: connected sessionId=\(sid, privacy: .public)")
        case .reconnecting:
            Self.log.info("connection state: reconnecting")
        case .reconnected:
            Self.log.info("connection state: reconnected")
        case .closed(let reason):
            let description = ErrorPresentationMapper.describe(reason)
            Self.log.info("connection state: closed reason=\(description, privacy: .public)")
            // Stop any in-flight reveal and snap the paced assistant line to its
            // full reduced text before rebuilding the reducer from the transcript.
            cancelAssistantReveal()
            transcript = reducer.lines
            reducer = TranscriptReducer(lines: transcript)
            switch reason {
            case .clientEnded, .clientClosed:
                appendTranscript(kind: .system, text: "Session ended.")
                transition(to: .idle)
            case .pingTimeout:
                // A session that's gone quiet (the Mac slept, a network blip,
                // idle for a while) isn't a failure to report — it's a stale
                // connection ending the same as a deliberate one, not
                // something the user did anything wrong to cause or can act
                // on. Treated like `.clientEnded`/`.clientClosed`: a plain
                // transcript note and back to idle, no error toast or chime.
                appendTranscript(kind: .system, text: "Session timed out.")
                transition(to: .idle)
            case .voiceDisabled, .serverClosed, .transportError, .agentNotReady, .decodeError, .handshakeFailed:
                let pres = ErrorPresentationMapper.presentation(reason, heardTranscript: lastUserTranscript())
                appendTranscript(kind: .error, text: "\(pres.headline) — \(pres.message)")
                transition(to: .error(pres))
            }
        }
    }

    private static func transportStateLabel(_ s: VoiceConnectionState) -> String {
        switch s {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .reconnecting: return "reconnecting"
        case .reconnected: return "reconnected"
        case .closed(let reason):
            switch reason {
            case .clientEnded: return "closed_client_ended"
            case .clientClosed: return "closed_client"
            case .pingTimeout: return "closed_ping_timeout"
            case .voiceDisabled: return "closed_voice_disabled"
            case .serverClosed: return "closed_server"
            case .transportError: return "closed_transport_error"
            case .agentNotReady: return "closed_agent_not_ready"
            case .decodeError: return "closed_decode_error"
            case .handshakeFailed: return "closed_handshake_failed"
            }
        }
    }

    private func handle(_ event: ServerEvent, session: VoiceSession) {
        if case .toolInvocation(let inv) = event {
            hooks.onToolInvocation?(session, inv)
            return
        }
        ingest(event)
    }

    /// Apply a server event to the observable state. Visible to tests
    /// (via `@testable`) so the tool-lifecycle, transcript, and ready
    /// transitions can be exercised without spinning up a transport.
    /// ``.toolInvocation`` is handled by the outer dispatcher because
    /// it needs the live ``VoiceSession`` to send a reply.
    internal func ingest(_ event: ServerEvent) {
        // TODO(v0.5+): assigning `transcript = reducer.lines` on every
        // event copies the full array (cheap COW, but invalidates the
        // @Observable property each time). For long sessions consider
        // diffing the reducer's returned line ids and applying just the
        // delta, or exposing `transcript` as a computed view over the
        // reducer's internal storage.
        switch event {
        case .ready(let r):
            transition(to: .live(sessionId: r.sessionId))
            _ = reducer.reduce(.ready(r))
            publishTranscript()
            // Session is live — drain any text typed before connect.
            flushPendingTexts()
        case .transcript(let t):
            checkSleepPhrase(t)
            _ = reducer.reduce(event)
            if t.role == .assistant {
                // Paced, word-by-word (see MARK: Assistant caption pacing).
                applyAssistantPacing(t)
            } else {
                publishTranscript()
            }
        case .toolCall(let c):
            sessionToolCallCount += 1
            inFlightTools.append(InFlightTool(id: c.callId, name: c.name, startedAt: Date()))
            hooks.onToolCall?(c.name)
            _ = reducer.reduce(event)
            publishTranscript()
        case .toolResult(let r):
            inFlightTools.removeAll { $0.id == r.callId }
            _ = reducer.reduce(event)
            publishTranscript()
        case .toolInvocation:
            break
        case .usage(let breakdown):
            usage = breakdown
        case .turnComplete, .error,
             .pong, .unknown:
            _ = reducer.reduce(event)
            publishTranscript()
        }
    }

    // MARK: - Assistant caption pacing

    /// Publish ``reducer.lines`` to the observable ``transcript``, substituting
    /// the paced prefix for the assistant line that's still revealing. While a
    /// line has revealed nothing yet it's hidden (no empty bubble, no early
    /// full-text leak); once the first word reveals it appears and grows.
    private func publishTranscript() {
        guard let lineId = asstRevealLineId,
              let idx = reducer.lines.firstIndex(where: { $0.id == lineId }) else {
            transcript = reducer.lines
            return
        }
        var lines = reducer.lines
        if asstRevealedPrefix.isEmpty {
            lines.remove(at: idx)
        } else {
            lines[idx] = TranscriptLine(id: lineId, kind: .assistant, text: asstRevealedPrefix)
        }
        transcript = lines
    }

    /// Route one assistant transcript delta (already reduced) through the
    /// word-by-word revealer.
    private func applyAssistantPacing(_ t: Transcript) {
        // Backend's intentional empty-final = line-close for a suppressed
        // (garbled / silent) turn. The reducer already removed the line; tear
        // the pacer down and mirror the reducer directly — routing an empty
        // target through the revealer would just stall.
        if t.isFinal, t.text.isEmpty {
            cancelAssistantReveal()
            transcript = reducer.lines
            return
        }
        // The reducer just wrote the assistant line: it's the in-progress line
        // on a partial, or the last assistant line on a non-empty final (which
        // clears the in-progress id).
        guard let lineId = reducer.inProgressAssistantLineId
                ?? reducer.lines.last(where: { $0.kind == .assistant })?.id,
              let idx = reducer.lines.firstIndex(where: { $0.id == lineId }) else {
            transcript = reducer.lines
            return
        }
        let cumulative = reducer.lines[idx].text
        if asstRevealLineId != lineId {
            beginAssistantReveal(lineId: lineId)
        }
        if t.isFinal {
            asstFinalText = cumulative
        }
        let revealer = asstRevealer
        // Always non-final to the revealer: the wire final lands early, so keep
        // pacing toward the target and let the reveal task finish once the paced
        // prefix actually reaches ``asstFinalText``. Chained after the prior
        // setTarget so deltas apply in order (see ``asstSetTargetChain``).
        let prior = asstSetTargetChain
        asstSetTargetChain = Task { @MainActor [weak self] in
            await prior?.value
            await revealer?.setTarget(cumulative, isFinal: false)
            // The paced prefix can already have caught this target — the reveal
            // outran a slow final. Then the revealer has no further word to
            // yield, so the consumer never sees a prefix to compare against
            // ``asstFinalText`` and the line would stay bound to a reveal that
            // is already done. Close it here; the consumer covers the opposite
            // order, where the prefix arrives after the final is known.
            guard let self, self.asstRevealLineId == lineId,
                  let final = self.asstFinalText, self.asstRevealedPrefix == final
            else { return }
            await revealer?.finish()
        }
        publishTranscript()
    }

    /// Start a fresh revealer + consumer task for a new assistant line.
    private func beginAssistantReveal(lineId: UUID) {
        asstRevealTask?.cancel()
        asstSetTargetChain?.cancel()
        asstSetTargetChain = nil
        asstRevealLineId = lineId
        asstRevealedPrefix = ""
        asstFinalText = nil
        let generation = sessionGeneration
        let revealer = TranscriptRevealer(
            wordInterval: assistantRevealIntervalOverride
                ?? RevealCadence.perWord(for: geminiVoice),
            maxLagWords: .max  // pure cadence: never rush to catch a far-ahead target
        )
        asstRevealer = revealer
        asstRevealTask = Task { @MainActor [weak self] in
            for await prefix in revealer.revealed {
                guard let self, self.sessionGeneration == generation,
                      self.asstRevealLineId == lineId else { return }
                self.asstRevealedPrefix = prefix
                self.publishTranscript()
                // Paced reveal has caught the final target → finish the stream.
                if let final = self.asstFinalText, prefix == final {
                    await revealer.finish()
                } else if self.asstFinalText != nil,
                          Date().timeIntervalSince(self.levels.lastSpeakerActivityAt) > Self.tailFlushSilence {
                    // The whole reason for pacing is not to outrun the voice.
                    // Once the wire final has arrived and playout has gone
                    // quiet, there is nothing left to outrun — so drain the
                    // tail instead of crawling on after Cosmo has stopped. The
                    // final-arrived gate keeps a mid-turn thinking pause from
                    // triggering it; the window clears inter-sentence pauses.
                    await revealer.accelerate(to: Self.tailFlushInterval)
                }
            }
            // Reveal finished (caught the final target or was cancelled). Snap
            // to the reducer's full text and release the reveal binding so the
            // next turn starts a fresh line. Guarded against a stale session.
            guard let self, self.sessionGeneration == generation,
                  self.asstRevealLineId == lineId else { return }
            self.asstRevealLineId = nil
            self.asstRevealer = nil
            self.asstFinalText = nil
            self.transcript = self.reducer.lines
        }
    }

    /// Tear down any in-flight reveal without publishing (caller decides what
    /// to show next).
    private func cancelAssistantReveal() {
        asstRevealTask?.cancel()
        asstRevealTask = nil
        asstSetTargetChain?.cancel()
        asstSetTargetChain = nil
        let revealer = asstRevealer
        asstRevealer = nil
        asstRevealLineId = nil
        asstRevealedPrefix = ""
        asstFinalText = nil
        if let revealer { Task { await revealer.finish() } }
    }

    /// New-session boundary: invalidate stragglers from the prior session and
    /// reset the pacer.
    private func beginNewTranscriptGeneration() {
        sessionGeneration &+= 1
        cancelAssistantReveal()
        pendingTexts.removeAll()
    }

    /// Sleep-phrase match over user transcripts during ``live``.
    /// Runs on partials — backend doesn't emit ``isFinal`` for user.
    private func checkSleepPhrase(_ t: Transcript) {
        guard case .live = state else { return }
        guard t.role == .user else { return }
        guard sleepMatcher.check(transcript: t.text) else { return }
        Self.log.info("sleep phrase detected — ending session")
        hooks.onSleepDetected?()
        end()
    }

    private func appendTranscript(kind: TranscriptLine.Kind, text: String) {
        let line = TranscriptLine(kind: kind, text: text)
        transcript.append(line)
        reducer = TranscriptReducer(lines: transcript)
    }

    private func lastUserTranscript() -> String? {
        transcript.last(where: { $0.kind == .user })?.text
    }

    private static func stateName(_ s: VoiceSessionState) -> String {
        switch s {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .live(let sid): return "live(\(sid.prefix(8)))"
        case .ending: return "ending"
        case .error: return "error"
        }
    }
}
