import CoreGraphics
import CosmoRealtimeAPI
import Foundation
import OpenAPIRuntime
import os

/// The session state machine, shared across the Cosmo SDKs
/// (``idle → connecting → connected ↔ reconnecting → disconnected``).
/// Read the current value as ``RealtimeSession/state``; observe every
/// transition — from ``idle`` on — with the ``onStateChange`` handler on
/// ``RealtimeAgent/start(resumeSessionId:maxSessionSeconds:storeRecording:storeAudio:storeTranscript:storeVideo:micMuted:rpcHandlers:onStateChange:)``.
/// Distinct from the application-level ``RealtimeSessionEvent/ready(_:)``
/// event. A transient recovery re-enters ``connected``.
@frozen
public enum SessionState: Sendable, Equatable {
    /// Not started, and not yet connecting.
    case idle
    /// Joining the room and waiting for the server to report readiness.
    case connecting
    /// The transport has joined. ``start(_:config:)`` does not return until
    /// the server also reports readiness, so a session you were handed is
    /// past this point — but an `onStateChange` observer sees this state
    /// first, while the agent may still be starting up.
    case connected
    /// The transport is recovering from a transient drop; the session
    /// re-enters ``connected`` if it succeeds.
    case reconnecting
    /// Terminal. The ``RealtimeSession/events`` stream is finished.
    /// ``reason`` is the cross-SDK ``DisconnectReason`` slug; ``detail``
    /// carries the server's end slug or a transport message when one
    /// exists — the same pair the sibling SDKs put on their state value.
    case disconnected(reason: DisconnectReason, detail: String?)
}

/// A live realtime voice session speaking the published developer
/// protocol. An agent's
/// ``RealtimeAgent/start(resumeSessionId:maxSessionSeconds:storeRecording:storeAudio:storeTranscript:storeVideo:micMuted:rpcHandlers:onStateChange:)``
/// opens it; consumption is a single typed event stream:
///
/// ```swift
/// let client = RealtimeClient(apiKey: "key")
/// let agent = try client.agent(instructions: "You are a terse assistant.")
/// let session = try await agent.start()
/// for try await event in session.events {
///     switch event {
///     case .ready(let ready): print("live, session:", ready.sessionId)
///     case .transcript(let delta): print(delta.text)
///     case .sessionEnded(let ended): print("over:", ended.reason ?? "")
///     case .unknown(let rawType, _): print("unrecognized event:", rawType ?? "?")
///     default: break
///     }
/// }
/// ```
///
/// Single-attempt: a session that ends — by ``end()``, by the server's
/// ``session-ended``, or by a transport failure — is terminal. Start a new
/// one to reconnect.
///
/// ``events`` is single-consumer: iterate it from exactly one task.
public actor RealtimeSession {

    static let log = Logger(subsystem: CosmoRealtimeLog.subsystem, category: "session")

    /// The SwiftPM package name. Moved to the module's ``sdkName``, since it
    /// describes the package rather than a session.
    @available(*, deprecated, renamed: "sdkName")
    public static let sdkName = CosmoRealtime.sdkName

    /// The package version. Moved to the module's ``sdkVersion``, since it
    /// describes the package rather than a session.
    @available(*, deprecated, renamed: "sdkVersion")
    public static let sdkVersion = CosmoRealtime.sdkVersion

    /// Hard ceiling on a base64 image payload, mirroring the server-side
    /// ingress bound (`_MAX_IMAGE_B64_LEN`) so a frame the server would refuse
    /// never leaves the client — and never gets chunked across the control
    /// channel on its way to being refused.
    public static let maxImageBase64Length = 12_000_000

    /// Bound on the wait between the transport joining and the server's
    /// ``ready`` handshake. Deliberately longer than the server's own 30s
    /// boot deadline — which fails a stuck boot as an ``error`` frame plus a
    /// room close — so a failed boot arrives as that informative close
    /// rather than this blind timeout; only genuine infra loss lands here.
    static let readyTimeout: Double = 40

    /// Payload size at which a frame is decoded to check its pixel dimensions.
    ///
    /// The bound we care about is on pixels, but reading pixels means decoding,
    /// and decoding every frame would tax callers who are already well-behaved.
    /// This floor is set so a compliant frame is forwarded without a decode
    /// while an over-resolution one still gets inspected: a 2704x1756 desktop
    /// screenshot measured 165K base64 chars at 1280px and 295K at 1920px.
    /// Calibrated on desktop UI content — photographic or noisy frames compress
    /// far worse and may cross it while already within the pixel bound, which
    /// costs them one decode and no re-encode.
    static let imageBase64InspectThreshold = 200_000

    /// A caller streaming stills re-encodes every frame; warn once, not 3,600
    /// times an hour.
    private var didWarnImageReencode = false

    private func emitState(_ next: SessionState) {
        currentState = next
        onStateChange?(next)
    }

    /// Internal teardown vocabulary: the ``DisconnectReason`` slug plus the
    /// payload each path carries. Lowered onto the public state and the
    /// SessionEnd hook context via ``sessionDisconnectReason``.
    enum CloseReason: Sendable, Equatable {
        case clientEnded
        case clientClosed
        case handshakeFailed(status: Int?, detail: String?)
        case serverEnded(reason: String?)
        case transportError(message: String)
    }

    private enum Lifecycle {
        case idle
        case connecting
        case connected
        case reconnecting
        case closed
    }

    // MARK: State

    // Read by the screen-share extension (forwards onto the transport,
    // which owns the screen-share state); only assigned in ``init``.
    let transport: any SessionTransport
    // The client retained for post-start REST calls that reuse the session's
    // backend, credential, and TLS policy (e.g. ``dial``, ``usage``), so
    // polling a session does not stand up a URLSession per call. ``nil`` when
    // the session was constructed directly over a fake transport in tests.
    let client: RealtimeClient?
    private let reassembler = EnvelopeReassembler()
    private var lifecycle: Lifecycle = .idle
    private var hooks: HookEngine?
    // Reason latched from the server's best-effort ``session-ended`` frame;
    // consulted only on the unsolicited transport-close path.
    private var serverDisconnectReason: String?
    private var serverEndGraceTask: Task<Void, Never>?
    /// Grace between a ``session-ended`` frame and a forced teardown when the
    /// expected transport close never follows. Per-session so a test can shorten
    /// its own without reaching into every other session in the process.
    let serverEndGraceNanos: UInt64
    static let defaultServerEndGraceNanos: UInt64 = 5_000_000_000
    /// Last mute state this client asserted; re-asserted on reconnect the same
    /// way the input binding is.
    private var lastSetMuted: Bool?
    var audioStreamOperationRunning = false
    var audioStreamOperationWaiters: [CheckedContinuation<Void, Never>] = []
    // Owns background client-tool jobs (a BackgroundClientTool acks fast + delivers
    // later); cancelled on teardown so in-flight jobs don't outlive the session.
    private var clientToolJobSink: ClientToolJobSink?

    // One connect-timings report per session. Not private: the report itself
    // lives in the sibling extension file.
    var didReportConnectTimings = false

    // Whether anything has shown the agent to be live: the ``ready`` frame,
    // its track publishing, or it speaking. ``ready`` is a one-shot data
    // frame a prepared-room session can miss, so it is not the only seam.
    var didObserveReadiness = false

    /// The transport-neutral result kept after start.
    private var startedSessionId: String?

    /// Server-minted session identifier, set once the start succeeds.
    public var sessionId: String? { startedSessionId }



    /// Typed server events in arrival order. Every terminal path of a live
    /// session — graceful ``end()``, server teardown, or a transport drop —
    /// ends with a locally synthesized ``RealtimeSessionEvent/sessionEnded(_:)`` as the
    /// final element, after which the sequence finishes; the stream does
    /// **not** throw (the underlying transport cannot distinguish a clean
    /// server close from an abnormal drop, so neither does the stream). The
    /// terminal reason is on ``SessionEndedEvent/reason`` and on
    /// ``state`` (``SessionState/disconnected(reason:)``). Start failures throw
    /// from ``start(_:config:)`` instead. Single consumer.
    public nonisolated let events: AsyncThrowingStream<RealtimeSessionEvent, Error>
    private nonisolated let eventsContinuation: AsyncThrowingStream<RealtimeSessionEvent, Error>.Continuation

    /// The session state machine's current value; the terminal
    /// ``SessionState/disconnected(reason:)`` stays readable after the
    /// session ends. The full transition history — from
    /// ``SessionState/idle`` on — is delivered to the ``onStateChange``
    /// handler passed at start.
    public var state: SessionState { currentState }
    private var currentState: SessionState = .idle
    private var onStateChange: (@Sendable (SessionState) -> Void)?

    /// Fires once when the transport observes the agent live — its published
    /// track on WebRTC (race-free), the first `ready` frame on the websocket.
    /// Distinct from the wire ``RealtimeSessionEvent/ready(_:)``
    /// frame and deliberately not a substitute for it: only ``ready`` carries
    /// the session id, the rejected-tool list, and the effective duration cap.
    ///
    /// Use it to drive a "connecting…" spinner without gating that spinner on
    /// a data frame. Prefer ``waitUntilAgentLive()`` unless you need the
    /// stream. The wire-facing ``events`` stream is unchanged — this never
    /// fabricates a ``ready`` event on it.
    public nonisolated let agentLive: AsyncStream<Void>
    private nonisolated let agentLiveContinuation: AsyncStream<Void>.Continuation
    private var didSignalAgentLive = false

    /// Coalesced conversation state, folded from the transcript and
    /// turn-complete streams. Survives teardown so ``transcript`` stays
    /// readable after the session ends.
    private var transcriptStore = TranscriptStore()

    /// The coalesced conversation so far — one item per turn, folded by
    /// the session from its own transcript stream.
    /// ``RealtimeSessionEvent/transcriptUpdated(_:)`` is yielded on
    /// ``events`` with the new value on every change. Survives ``end()``,
    /// so the full conversation stays readable after the session ends.
    public var transcript: [TranscriptItem] {
        transcriptStore.current
    }

    /// Tasks parked in ``waitUntilEnded()``, all resumed once by ``_close``.
    private var endWaiters: [CheckedContinuation<Void, Never>] = []

    /// Tasks parked in ``waitUntilAgentLive()``. Resumed by the agent-track
    /// signal, or by ``_close`` so a session that dies first never hangs them.
    private var agentLiveWaiters: [CheckedContinuation<Void, Never>] = []
    /// Waiters on the ready handshake — ``start()``'s own gate. Resumed with
    /// success by ``ready`` (either delivery) and with the window's typed
    /// failure by any terminal transition.
    private var readyWaiters: [CheckedContinuation<Result<Void, any Error>, Never>] = []
    /// True once the sign has been read, from either delivery. The second
    /// arrival reaches no surface.
    private var didObserveReady = false
    /// Pre-ready ``error`` frame, stashed as enrichment: a failed boot closes
    /// the room, and this upgrades that close's thrown error with the
    /// server's own code and message.
    private var pendingHandshakeError: (code: String, message: String)?
    /// The outcome the ready gate should settle with, set by an exit that has
    /// a more specific verdict than the close itself carries (the timeout, a
    /// cancellation). ``_close`` is the one place that settles, and it settles
    /// last — so an exit records its verdict here rather than resuming the
    /// waiter early and letting ``start`` throw mid-teardown.
    private var pendingReadyOutcome: Result<Void, any Error>?

    /// Resource teardown bound to this session's lifetime, run once by
    /// ``_close`` before any end-waiter wakes.
    private var onClose: (@Sendable () async -> Void)?

    /// Bind teardown to this session's close. Runs once — immediately if the
    /// session has already closed.
    func _attachOnClose(_ handler: @escaping @Sendable () async -> Void) async {
        if case .closed = lifecycle {
            await handler()
            return
        }
        onClose = handler
    }

    // MARK: Audio levels

    /// Microphone RMS level (0…1), latest-value (a slow consumer drops
    /// intermediate samples). Yields while the local audio track is
    /// published and the consumer iterates; finishes when the session
    /// ends. Render-callback driven by the transport — no timer.
    public nonisolated var inputLevels: AsyncStream<Float> {
        transport.inputLevels
    }

    /// Agent audio RMS level (0…1), latest-value like ``inputLevels``.
    /// Yields while the remote agent audio track is subscribed; finishes
    /// when the session ends.
    public nonisolated var outputLevels: AsyncStream<Float> {
        transport.outputLevels
    }

    /// Software playback gain for the agent's audio: `0` mutes, `1` is unity.
    /// Values outside 0…1 are clamped. Takes effect immediately on the current
    /// agent track and is re-applied to any track that attaches later (late
    /// agent join, reconnect).
    ///
    /// Voice sessions live in iOS's call-volume domain, whose hardware slider
    /// bottoms out *above* silence (a call can't be rocker-muted). A host that
    /// wants "slider at the floor = silent" observes `AVAudioSession.outputVolume`
    /// and drives this.
    public nonisolated func setAgentPlaybackVolume(_ volume: Double) {
        transport.setAgentPlaybackVolume(volume)
    }

    // MARK: Connect timings

    /// Connect-latency breakdown: the client-measured connect phases plus
    /// the server's own session-start timings. Safe to read once the start
    /// completes. Sink-agnostic — the SDK does not report it anywhere.
    public nonisolated var connectTimings: SessionConnectTimings {
        transport.connectTimings
    }

    // MARK: Init + start

    init(
        transport: any SessionTransport,
        client: RealtimeClient? = nil,
        serverEndGraceNanos: UInt64 = defaultServerEndGraceNanos
    ) {
        self.transport = transport
        self.client = client
        self.serverEndGraceNanos = serverEndGraceNanos
        let eventStream = AsyncThrowingStream<RealtimeSessionEvent, Error>.makeStream(bufferingPolicy: .unbounded)
        self.events = eventStream.stream
        self.eventsContinuation = eventStream.continuation
        let agentLiveStream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.agentLive = agentLiveStream.stream
        self.agentLiveContinuation = agentLiveStream.continuation
    }

    /// The transport observed the agent go live. Signal readiness
    /// once (idempotent); the app wrapper latches on it. Never yields on the
    /// wire-facing ``events`` stream, so the external-protocol contract is
    /// unchanged.
    private func _agentBecameLive() {
        guard !didSignalAgentLive else { return }
        didSignalAgentLive = true
        didObserveReadiness = true
        _reportConnectTimings()
        Self.log.info("realtime.agent_live_observed — readiness signalled from the transport")
        agentLiveContinuation.yield(())
        let waiters = agentLiveWaiters
        agentLiveWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// Start a session: one REST session-start + media-transport join.
    /// Returns once the transport is live — the ready gate is
    /// ``_awaitReady(timeout:)``, which ``RealtimeAgent/start`` holds for
    /// before handing a session back.
    /// - Parameter micMuted: when `true`, the session joins WITHOUT
    ///   publishing the microphone — nothing is captured or sent until the
    ///   first ``setMuted(false)``. A session the host presents as "muted"
    ///   must never stream audio during the connect window.
    /// - Parameter rpcHandlers: client-tool handlers registered by method name
    ///   but **not** advertised to the agent — for server-orchestrated tools the
    ///   server invokes over RPC directly (never chosen from the tool list).
    ///   Advertised-and-handled tools belong in ``RealtimeAgent/tools`` as a
    ///   ``AgentTool/client(name:description:parameters:handler:)``;
    ///   these are the register-only complement. On a name collision the
    ///   ``rpcHandlers`` entry wins.
    static func start(
        _ client: RealtimeClient,
        config: SessionConfig = SessionConfig(),
        micMuted: Bool = false,
        rpcHandlers: [String: ClientToolHandler] = [:],
        onStateChange: (@Sendable (SessionState) -> Void)? = nil
    ) async throws -> RealtimeSession {
        guard Self.isSecureBaseURL(client.baseURL) else {
            throw CredentialsError(
                code: .insecureBaseURL,
                message: "Realtime base URL must use https "
                    + "(http allowed only for localhost): \(client.baseURL.absoluteString)"
            )
        }
        let transport: any SessionTransport
        switch client.sessionTransport {
        case .webrtc, .livekit:
            transport = LiveKitSessionTransport(client: client)
        case .websocket:
            transport = WebSocketSessionTransport(client: client)
        }
        let session = RealtimeSession(transport: transport, client: client)
        do {
            try await session._start(
                config: config,
                micMuted: micMuted,
                rpcHandlers: rpcHandlers,
                onStateChange: onStateChange
            )
        } catch {
            // Cancellation during the REST start or the room join reaches
            // those layers as whatever they throw — a URLSession cancel, a
            // LiveKit abort — and the mapping above turns it into a start
            // failure. A cancelled task is not a failed session: report the
            // window's cancel exit for the whole of ``start``, not only its
            // ready wait. The mapping already tore the session down before
            // throwing, so the invariant holds on this path too.
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        // ``start`` resolves at ready: a returned session is usable, and a
        // handshake that never completes is a start failure rather than a
        // live-looking object whose every send throws.
        try await session._awaitReady()
        return session
    }

    /// A bearer credential must not travel over cleartext. `https` is
    /// always allowed; plain `http` only for loopback hosts.
    static func isSecureBaseURL(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "https" { return true }
        return isLoopbackHost(url.host)
    }

    static func isLoopbackHost(_ host: String?) -> Bool {
        guard let host else { return false }
        return localHosts.contains(host.lowercased())
    }

    private static let localHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    /// Internal start so tests can drive a session over a fake
    /// transport while observing the same state machine the public
    /// ``start(_:config:)`` exercises.
    func _start(
        config: SessionConfig,
        micMuted: Bool = false,
        rpcHandlers: [String: ClientToolHandler] = [:],
        onStateChange: (@Sendable (SessionState) -> Void)? = nil
    ) async throws {
        guard case .idle = lifecycle else {
            throw SessionStateError(code: .alreadyStarted, message: "RealtimeSession.start already ran for this session; start a new session instead.")
        }
        self.onStateChange = onStateChange
        emitState(.idle)
        lifecycle = .connecting
        emitState(.connecting)

        var config = config
        self.hooks = config.hookEngine
        if let hooks = self.hooks, let extra = await hooks.runSessionStart() {
            if config.agentName != nil {
                Self.log.warning("a catalog agent runs its stored config verbatim — SessionStart additionalContext is not injected")
            } else {
                config.instructions = config.instructions.map { "\($0)\n\n\(extra)" } ?? extra
                Self.log.info("sessionStart hook context folded added_chars=\(extra.count, privacy: .public)")
            }
        }

        let configFrame: Data
        do {
            configFrame = try JSONEncoder().encode(config.wirePayload())
        } catch {
            let message = "session-config encode failed: \(error.localizedDescription)"
            Self.log.error("\(message, privacy: .public)")
            await _close(reason: .transportError(message: message))
            throw SessionStartError(code: .config, message: message)
        }

        let callbacks = SessionTransportCallbacks(
            onFrame: { [weak self] data in await self?._receiveFrame(data) },
            onClosed: { [weak self] reason in await self?._transportClosed(reason) },
            onReconnecting: { [weak self] in await self?._transportReconnecting() },
            onReconnected: { [weak self] in await self?._transportReconnected() },
            onAgentLive: { [weak self] in await self?._agentBecameLive() }
        )

        let info: SessionStartInfo
        do {
            let sink = ClientToolJobSink(
                deliver: { [weak self] result in
                    try await self?._sendToolJobResult(result)
                },
                isOpen: { [weak self] in await self?._isSendable() ?? false }
            )
            self.clientToolJobSink = sink
            // The locator's capture payload travels as a byte stream, a
            // channel the single-socket carrier does not have — refusing
            // here means the capture handler never runs.
            if !config.screenLocateTools.isEmpty, !transport.supportsByteStreams {
                throw SessionStartFailure.unsupportedCapability(
                    code: "screen_locate_unsupported",
                    detail: "screen_locate is not supported on the websocket transport"
                )
            }
            let rpcOnlyHandlers = config.rpcOnlyHandlers()
            let advertisedToolHandlers = config.clientToolHandlers()
            info = try await transport.connect(
                configFrame: configFrame,
                callbacks: callbacks,
                clientToolHandlers: advertisedToolHandlers
                    .merging(rpcOnlyHandlers) { _, rpcOnly in rpcOnly }
                    .merging(rpcHandlers) { _, registerOnly in registerOnly },
                backgroundClientToolHandlers: config.backgroundClientToolHandlers(),
                clientToolJobSink: sink,
                hooks: config.hookEngine,
                // An advertised name is a tool call whatever supplied its
                // handler, so a caller-registered override never exempts it.
                hookExemptMethods: Set(rpcOnlyHandlers.keys)
                    .union(rpcHandlers.keys)
                    .subtracting(advertisedToolHandlers.keys),
                micMuted: micMuted
            )
        } catch let failure as SessionStartFailure {
            switch failure {
            case .rejected(let status, let code, let detail, let retryAfter, let rejection):
                Self.log.error("session start rejected status=\(status.map(String.init) ?? "nil", privacy: .public) code=\(code ?? "nil", privacy: .public) detail=\(detail, privacy: .public)")
                if status == 401, let client, case .tokenSource(let source) = client.credential {
                    // Rejected despite the refresh skew — revoked, or clocks
                    // disagree: drop the cache so the next start fetches fresh.
                    await source.invalidate()
                }
                await _close(reason: .handshakeFailed(status: status, detail: detail))
                // One construction for every rejection: the code is the only
                // thing that varies, so status, slug and body ride along
                // whatever it turns out to be.
                let rejectionCode: SessionStartErrorCode =
                    code == "version_mismatch"
                    ? .versionMismatch
                    : classifyStartRejection(serverCode: code, status: status)
                throw SessionStartError(
                    code: rejectionCode,
                    message: status == 503
                        ? "Realtime voice is temporarily unavailable."
                        : detail,
                    status: status,
                    serverCode: code,
                    retryAfterSeconds: retryAfter,
                    detail: rejection
                )
            case .unsupportedCapability(let code, let detail):
                Self.log.error("session start refused capability code=\(code, privacy: .public)")
                await _close(reason: .handshakeFailed(status: nil, detail: detail))
                throw SessionStartError(code: .config, message: detail, serverCode: code)
            case .credential(let error):
                Self.log.error("session start credential resolution failed: \(error.localizedDescription, privacy: .public)")
                await _close(reason: .transportError(message: error.localizedDescription))
                // Un-erased on purpose: the caller branches on the
                // token-source code, matching the TypeScript and Python SDKs.
                throw error
            case .roomLostDuringJoin(let reason):
                // The room went down mid-join: a boot that failed fast. The
                // close it reported — plus any error frame the session
                // stashed before the data channel went — is the verdict, not
                // the join's own error.
                Self.log.error("session start: room lost during join reason=\(String(describing: reason), privacy: .public)")
                let failure = _handshakeFailure()
                await _close(reason: reason)
                throw failure
                    ?? SessionStartError(
                        code: .handshakeFailed,
                        message: "the room closed before the session was ready"
                    )
            case .transport(let message):
                Self.log.error("session start transport failure: \(message, privacy: .public)")
                await _close(reason: .transportError(message: message))
                throw SessionStartError(code: .transport, message: message)
            case .invalidResponse(let message):
                Self.log.error("session start invalid response: \(message, privacy: .public)")
                await _close(reason: .transportError(message: message))
                throw SessionStartError(code: .invalidResponse, message: message)
            case .joinFailed(let message):
                Self.log.error("session start join failure: \(message, privacy: .public)")
                await _close(reason: .transportError(message: message))
                throw SessionStartError(code: .joinFailed, message: message)
            case .captureUnavailable(let code, let message):
                Self.log.error("session start capture failure code=\(code.rawValue, privacy: .public) \(message, privacy: .public)")
                await _close(reason: .transportError(message: message))
                throw AudioUnavailableError(message: message, code: code)
            }
        } catch {
            Self.log.error("session start failed: \(error.localizedDescription, privacy: .public)")
            await _close(reason: .transportError(message: error.localizedDescription))
            // Nothing here reached a server verdict — a typed rejection would
            // have been caught by the arm above.
            throw SessionStartError(code: .transport, message: error.localizedDescription)
        }

        guard case .connecting = lifecycle else {
            // A concurrent ``end()`` raced the connect; the transport
            // teardown already ran via ``_close``.
            throw SessionStateError(code: .notConnected, message: "RealtimeSession is not connected.")
        }
        startedSessionId = info.sessionId
        lifecycle = .connected
        emitState(.connected)
        // A capture only fires once the locator calls, well after this, so the
        // late bind never races. Weak because the transport retains the
        // handlers, which retain the capture slot — binding self strongly
        // would close the loop back into the session.
        for capture in config.screenLocateTools {
            capture.bindPublish { [weak self] data, topic in
                guard let self else {
                    throw ScreenToolError(
                        message: "\(ScreenLocateTool.rpcMethod): session ended before publish"
                    )
                }
                try await self.send(bytes: data, topic: topic)
            }
        }
        // The transport publishes the mic during connect, so this client is the
        // human voice: bind the agent's input.
        await _sendBindInput()
        // Covers the ordering where a readiness signal landed before the
        // transport finished recording its phases; the ordinary order is
        // covered from the signal itself.
        _reportConnectTimings()
        Self.log.info("session started sessionId=\(info.sessionId, privacy: .public)")
    }

    // MARK: Sends

    /// Send a text turn to the agent. The agent replies in whatever modality
    /// the session runs in.
    ///
    /// The sent text lands in ``transcript`` as its own closed user turn
    /// (the server does not echo typed input back); an in-progress speech
    /// transcription is untouched. Pass `transcript: false` to keep it out.
    public func send(text: String, transcript: Bool = true) async throws {
        try _assertSendable()
        try await _publish(
            CosmoRealtimeAPI.Components.Schemas.ClientText(
                content: text,
                _type: .sendText
            )
        )
        // The echo is a complete turn of its own — never folded through the
        // wire-final path, which would replace an in-progress speech bubble.
        if transcript {
            let changed = transcriptStore.appendClosed(role: .user, text: text)
            eventsContinuation.yield(
                .transcript(TranscriptDeltaEvent(isFinal: true, role: .user, text: text, _type: .transcript))
            )
            if changed {
                eventsContinuation.yield(
                    .transcriptUpdated(TranscriptUpdatedEvent(items: transcriptStore.current))
                )
            }
        }
    }

    /// Give the agent context without asking it anything.
    ///
    /// The note lands in the model's context for its next reply and never
    /// becomes a turn of its own: no spoken response, no assistant message,
    /// no interruption of what the agent is saying. For live application
    /// state; ``send(text:)`` is the opposite, it asks.
    public func send(context: String) async throws {
        try _assertSendable()
        try await _publish(
            CosmoRealtimeAPI.Components.Schemas.ClientContext(
                content: context,
                _type: .sendContext
            )
        )
    }

    /// Hand the model background it keeps to itself and draws on when
    /// relevant. `delegationId` names the
    /// ``RealtimeSessionEvent/delegationCreated(_:)`` this answers; `nil`
    /// steers the session as a whole.
    public func appendThinking(_ content: String, delegationId: String? = nil) async throws {
        try await _appendDelegation(.thinking, content: content, delegationId: delegationId)
    }

    /// Give the model something to say now, in its own words rather than
    /// verbatim. `delegationId` names the
    /// ``RealtimeSessionEvent/delegationCreated(_:)`` this answers; `nil`
    /// steers the session as a whole.
    public func appendCommentary(_ content: String, delegationId: String? = nil) async throws {
        try await _appendDelegation(.commentary, content: content, delegationId: delegationId)
    }

    /// Change how the model behaves from here on. `delegationId` names the
    /// ``RealtimeSessionEvent/delegationCreated(_:)`` this answers; `nil`
    /// steers the session as a whole.
    public func appendInstructions(_ content: String, delegationId: String? = nil) async throws {
        try await _appendDelegation(.instructions, content: content, delegationId: delegationId)
    }

    private func _appendDelegation(
        _ channel: DelegationChannel, content: String, delegationId: String?
    ) async throws {
        try _assertSendable()
        try await _publish(
            CosmoRealtimeAPI.Components.Schemas.DelegationAppend(
                channel: .init(channel),
                content: content,
                delegationId: delegationId,
                _type: .delegationAppend
            )
        )
    }

    /// Mute or unmute the microphone. Sends the wire ``mute`` frame
    /// (so the agent can update VAD state) and toggles local capture.
    /// Throws if the capture toggle fails — notably a denied-permission
    /// first publish when unmuting a session that joined muted, which
    /// surfaces as ``AudioUnavailableError`` carrying the reason.
    public func setMuted(_ muted: Bool) async throws {
        await beginAudioStreamOperation()
        defer { endAudioStreamOperation() }
        try await _setMuted(muted)
    }

    func _setMuted(_ muted: Bool) async throws {
        try _assertSendable()
        try await _publish(
            CosmoRealtimeAPI.Components.Schemas.ClientMute(muted: muted, _type: .mute)
        )
        try await transport.setMicrophoneEnabled(!muted)
        lastSetMuted = muted
    }

    /// Keep-alive; the server replies with ``RealtimeSessionEvent/pong``.
    public func ping() async throws {
        try _assertSendable()
        try await _publish(
            CosmoRealtimeAPI.Components.Schemas.ClientPing(_type: .ping)
        )
    }

    /// Send a single image frame to the agent, downscaled to `maxLongEdge`.
    ///
    /// Preferred over the base64 overload: bounding happens here, before the
    /// pixels are ever encoded or base64-inflated, so an oversized capture
    /// costs nothing to discard. See ``ImageDownscale`` for why the default
    /// ceiling is 1280 and when to raise it.
    public func send(
        image: CGImage,
        maxLongEdge: Int = ImageDownscale.recommendedMaxLongEdge,
        quality: Double = ImageDownscale.recommendedQuality,
        streamId: String = "video.input.default"
    ) async throws {
        try _assertSendable()
        let encoded = try ImageDownscale.encodeJPEG(
            image: image,
            maxLongEdge: maxLongEdge,
            quality: quality
        )
        // Publish directly rather than routing through the base64 overload:
        // this frame is already bounded to the caller's `maxLongEdge`, and
        // that path would re-clamp it to the default and undo a deliberately
        // raised ceiling.
        try await _publishImage(
            base64: encoded.base64,
            mimeType: encoded.mimeType,
            streamId: streamId
        )
    }

    /// Send a single image frame to the agent as base64 JSON.
    ///
    /// ``data`` is the base64-encoded image bytes (not raw bytes). Use this
    /// for one-shot captures (a photo, a screenshot, a sampled frame) where
    /// publishing a continuous video track would be overkill. Oversized
    /// frames are split into ``envelope-chunk`` packets transparently by
    /// ``_publish(_:)``; the server reassembles before dispatch.
    ///
    /// A payload past ``imageBase64InspectThreshold`` is decoded, and re-encoded
    /// at ``ImageDownscale/recommendedMaxLongEdge`` if its long edge exceeds it.
    /// This is a guard against egregiously oversized frames, not a categorical
    /// resolution bound: an over-resolution frame that compresses below the
    /// threshold is forwarded unchanged, because reading its dimensions would
    /// mean decoding every frame every caller sends. For a guaranteed bound
    /// (and no lossy re-encode), use
    /// ``send(image:maxLongEdge:quality:streamId:)``.
    public func send(
        image data: String,
        mimeType: String = "image/jpeg",
        streamId: String = "video.input.default"
    ) async throws {
        try _assertSendable()
        var payload = data
        var payloadMimeType = mimeType
        if data.count > Self.imageBase64InspectThreshold {
            var reencode: ReencodeNote?
            payload = try Self._bounded(
                base64: data,
                originalLength: data.count,
                mimeType: &payloadMimeType,
                reencode: &reencode
            )
            if let note = reencode, !didWarnImageReencode {
                didWarnImageReencode = true
                Self.log.warning(
                    "send(image:) re-encoded an oversized frame base64_len=\(note.from, privacy: .public)->\(note.to, privacy: .public) dims=\(note.width, privacy: .public)x\(note.height, privacy: .public) — encode at \(ImageDownscale.recommendedMaxLongEdge, privacy: .public)px to avoid this round trip (logged once per session)"
                )
            }
        }
        try await _publishImage(
            base64: payload,
            mimeType: payloadMimeType,
            streamId: streamId
        )
    }

    private func _publishImage(
        base64: String,
        mimeType: String,
        streamId: String
    ) async throws {
        try await _publish(
            CosmoRealtimeAPI.Components.Schemas.ClientImage(
                data: base64,
                mimeType: mimeType,
                streamId: streamId,
                _type: .sendImage
            )
        )
    }

    /// Downscale an oversized base64 frame, or fail with the measured size and
    /// the recommended dimension. Only reached for payloads already past
    /// ``imageBase64InspectThreshold``.
    static func _bounded(
        base64: String,
        originalLength: Int,
        mimeType: inout String,
        reencode: inout ReencodeNote?
    ) throws -> String {
        // Downscaling is attempted before the hard limit is enforced: a
        // full-resolution capture well past the limit usually lands far under
        // it once bounded, and rejecting it first would refuse a frame we can
        // trivially make sendable.
        let downscaled: ImageDownscale.Encoded?
        do {
            downscaled = try ImageDownscale.downscaleBase64(base64)
        } catch let error as ImageDownscale.Error {
            guard originalLength > maxImageBase64Length else {
                // Sendable size, just not downscalable (an unrecognized
                // encoding). The server bound still applies; send as given.
                log.warning(
                    "send(image:) could not downscale frame base64_len=\(originalLength, privacy: .public): \(error.description, privacy: .public)"
                )
                return base64
            }
            log.error(
                "send(image:) rejected oversized frame base64_len=\(originalLength, privacy: .public) limit=\(maxImageBase64Length, privacy: .public): \(error.description, privacy: .public)"
            )
            throw Self._tooLarge(originalLength)
        }

        guard let encoded = downscaled else {
            // Within the pixel ceiling but over the byte threshold — a
            // low-compression or lossless encode. Re-encoding buys nothing.
            guard originalLength > maxImageBase64Length else { return base64 }
            log.error(
                "send(image:) rejected frame within the pixel bound but over the byte limit base64_len=\(originalLength, privacy: .public)"
            )
            throw Self._tooLarge(originalLength)
        }

        guard encoded.base64.count <= maxImageBase64Length else {
            log.error(
                "send(image:) frame still over the byte limit after downscaling base64_len=\(encoded.base64.count, privacy: .public)"
            )
            throw Self._tooLarge(encoded.base64.count)
        }

        mimeType = encoded.mimeType
        reencode = ReencodeNote(
            from: originalLength,
            to: encoded.base64.count,
            width: encoded.width,
            height: encoded.height
        )
        return encoded.base64
    }

    /// One re-encode, for the caller to log. A caller that streams stills is
    /// re-encoding every frame, so this is reported once per session rather
    /// than once per frame.
    struct ReencodeNote {
        let from: Int
        let to: Int
        let width: Int
        let height: Int
    }

    private static func _tooLarge(_ length: Int) -> ImageDownscale.Error {
        .payloadTooLarge(
            base64Length: length,
            limit: maxImageBase64Length,
            recommendedLongEdge: ImageDownscale.recommendedMaxLongEdge
        )
    }

    /// Stream raw bytes to the agent on a named ``topic``, out of band from
    /// the JSON control channel. For large binary client-tool payloads — a
    /// grounding screenshot plus its accessibility dump, say — that would be
    /// wasteful to base64 onto the control channel. Delivered only to the
    /// agent participant. Internal: the screen tools' capture publish is the
    /// consumer, matching the Python/TypeScript SDKs, which keep byte-stream
    /// sending inside their tool plumbing.
    func send(bytes data: Data, topic: String) async throws {
        try _assertSendable()
        try await transport.sendBytes(data, topic: topic)
    }

    /// Signal manual-VAD end-of-turn: the user's "I'm done speaking" hint
    /// for turn-taking modes where silence detection is off. Unlike
    /// ``setMuted(_:)`` this has no microphone-capture side effect.
    public func sendActivityEnd() async throws {
        try _assertSendable()
        try await _publish(
            CosmoRealtimeAPI.Components.Schemas.ClientActivityEnd(_type: .activityEnd)
        )
    }

    /// Resume every waiter on the ready gate, once per outcome.
    private func _settleReadyWaiters(_ outcome: Result<Void, any Error>) {
        let waiters = readyWaiters
        readyWaiters = []
        for waiter in waiters { waiter.resume(returning: outcome) }
    }

    /// The window's close exit as a typed error, when the evidence for one
    /// exists: the server's stashed pre-ready ``error`` frame (enrichment),
    /// or a session already closed before ``ready``. ``nil`` when neither.
    private func _handshakeFailure() -> SessionStartError? {
        if didObserveReady { return nil }
        // A close is the authoritative failure; a stashed error frame only
        // supplies its detail. The frame alone settles nothing — the session
        // may still be coming up.
        guard case .closed = lifecycle else { return nil }
        // Synthetic status ``0``: no HTTP exchange failed — the room closed
        // before ready, and the server's frame is the detail when it sent one.
        if let stashed = pendingHandshakeError {
            return SessionStartError(
                code: .handshakeFailed,
                message: stashed.message,
                serverCode: stashed.code
            )
        }
        return SessionStartError(
            code: .handshakeFailed,
            message: serverDisconnectReason ?? "the session ended before ready"
        )
    }

    /// Hold ``start`` until the server's ready handshake lands, so a returned
    /// session is usable. The window contract's four exits: the sign
    /// (attribute or frame) resolves it; a pre-ready close throws
    /// ``SessionStartError`` carrying
    /// any stashed enrichment; silence past ``readyTimeout`` throws
    /// ``SessionStartError``; and task cancellation
    /// tears the session down and throws ``CancellationError``.
    func _awaitReady(timeout: Double = RealtimeSession.readyTimeout) async throws {
        if didObserveReady { return }
        if let failure = _handshakeFailure() { throw failure }
        let deadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if Task.isCancelled { return }
            await self?._readyDeadlineReached(timeout: timeout)
        }
        defer { deadline.cancel() }
        let outcome: Result<Void, any Error> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if didObserveReady {
                    continuation.resume(returning: .success(()))
                } else if let failure = _handshakeFailure() {
                    continuation.resume(returning: .failure(failure))
                } else {
                    readyWaiters.append(continuation)
                }
            }
        } onCancel: {
            // Cooperative: a parked continuation ignores a cancelled task
            // unless something resumes it. The teardown that follows releases
            // the room, the microphone, and the session slot.
            Task { [weak self] in await self?._readyWaitCancelled() }
        }
        try outcome.get()
    }

    private func _readyDeadlineReached(timeout: Double) async {
        guard !didObserveReady, !readyWaiters.isEmpty else { return }
        let failure = SessionStartError(code: .readyTimeout, message: "The server's ready handshake did not arrive within \(Int(timeout))s.")
        pendingReadyOutcome = .failure(failure)
        await _close(
            reason: .handshakeFailed(status: nil, detail: failure.localizedDescription)
        )
    }

    private func _readyWaitCancelled() async {
        guard !didObserveReady else { return }
        pendingReadyOutcome = .failure(CancellationError())
        await _close(reason: .clientClosed)
    }

    /// Suspend until the transport has observed the agent live — its media
    /// track on WebRTC, the first `ready` frame on the websocket — or the
    /// session ends first. Returns immediately if it already has.
    ///
    /// This is liveness, not readiness: it proves an agent is on the other
    /// end, and carries no session metadata. Keep awaiting
    /// ``RealtimeSessionEvent/ready(_:)`` on ``events`` for the session id, rejected tools,
    /// and the effective duration cap.
    public func waitUntilAgentLive() async {
        if didSignalAgentLive { return }
        if case .closed = lifecycle { return }
        await withCheckedContinuation { continuation in
            agentLiveWaiters.append(continuation)
        }
    }

    /// Suspend until the session has ended, for any reason — ``end()``, a
    /// server-side stop, or a transport drop. Returns immediately if it
    /// already has. Any number of tasks may wait.
    ///
    /// This is the supported way to hold a process open for the length of a
    /// call. It does not consume ``events``, so a separate task can drain the
    /// stream while the main path awaits this.
    public func waitUntilEnded() async {
        if case .closed = lifecycle { return }
        await withCheckedContinuation { continuation in
            endWaiters.append(continuation)
        }
    }

    /// Gracefully end the session: best-effort wire ``end`` frame, then
    /// terminal teardown with ``DisconnectReason/clientEnded``. Idempotent.
    /// Teardown is immediate — events still in flight are dropped, so
    /// consume the turn's final transcript event before ending if you
    /// need it.
    public func end() async {
        let canSend: Bool
        switch lifecycle {
        case .connected, .reconnecting: canSend = true
        default: canSend = false
        }
        if canSend {
            do {
                try await _publish(
                    CosmoRealtimeAPI.Components.Schemas.ClientEnd(_type: .end)
                )
            } catch {
                // Best-effort: the transport may already be gone. Record it
                // and tear down regardless.
                Self.log.warning(
                    "end frame publish failed; closing anyway: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        await _close(reason: .clientEnded)
    }

    /// Abrupt local teardown without the wire ``end`` frame. The stream
    /// finishes with reason ``client_closed``. Idempotent.
    public func close() async {
        await _close(reason: .clientClosed)
    }

    // Internal (not private) so the sibling send extensions in this module
    // reuse the one send path.
    func _assertSendable() throws {
        switch lifecycle {
        case .connected, .reconnecting:
            break
        default:
            throw SessionStateError(code: .notConnected, message: "RealtimeSession is not connected.")
        }
    }

    /// Whether an outbound cosmo message can be sent right now — the sink checks
    /// this before publishing a terminal ``tool_job_result``.
    func _isSendable() -> Bool {
        switch lifecycle {
        case .connected, .reconnecting: return true
        default: return false
        }
    }

    func _publish<Frame: Encodable>(_ frame: Frame) async throws {
        let data = try JSONEncoder().encode(frame)
        let outbound = buildOutboundPackets(data)
        guard !outbound.packets.isEmpty else {
            throw SessionStateError(code: .invalidPayload, message: 
                "refusing to nest envelope-chunk inside another envelope"
            )
        }
        for packet in outbound.packets {
            try await transport.send(frame: packet)
        }
    }

    // MARK: Inbound

    func _receiveFrame(_ data: Data) async {
        if case .closed = lifecycle { return }
        switch Self.classifyFrame(data) {
        case .envelopeChunk(let envelopeId, let seq, let total, let chunkData):
            let result = await reassembler.consume(
                envelopeId: envelopeId,
                seq: seq,
                total: total,
                data: chunkData
            )
            switch result {
            case .pending:
                break
            case .complete(let assembled):
                await _receiveFrame(assembled)
            case .invalid(let reason):
                // Tolerant posture: a broken envelope can't be trusted
                // but must not kill the session — surface it on the
                // forward-compatibility variant and keep going.
                Self.log.warning("envelope invalid: \(reason, privacy: .public); surfacing as unknown event")
                eventsContinuation.yield(.unknown(rawType: "server-envelope-chunk", payload: data))
            }
        case .serverSessionEnded(let reason):
            serverDisconnectReason = reason
            _armServerEndGrace()
        case .event(let event):
            var transcriptChanged = false
            switch event {
            case .ready(let ready):
                // ``ready`` arrives on two channels — the agent's participant
                // attribute (room state, read by late joiners) and the
                // data-channel frame. First delivery wins; the echo reaches
                // no surface.
                if didObserveReady { return }
                didObserveReady = true
                for rejected in ready.rejectedTools {
                    Self.log.warning(
                        "server rejected tool spec \"\(rejected.name, privacy: .public)\": \(rejected.reason, privacy: .public)"
                    )
                }
                transport.timings.markReady()
                didObserveReadiness = true
                _reportConnectTimings()
                _settleReadyWaiters(.success(()))
            case .botStartedSpeaking:
                // Readiness for the connect-timings report only: a prepared-room
                // session can miss the one-shot ``ready`` frame, and the agent
                // speaking proves it came up. It is not a window exit — the
                // sign is, and ``_settleReadyWaiters`` stays with it.
                didObserveReadiness = true
                _reportConnectTimings()
            case .error(let error):
                // Before ready, an error frame is enrichment for the room
                // close a failed boot sends next — stashed so that close
                // throws with the server's own code and message. The frame
                // itself settles nothing: the close is authoritative.
                if !didObserveReady {
                    pendingHandshakeError = (
                        code: error.code.rawValue, message: error.message
                    )
                }
            case .transcript(let delta):
                // Fold into the session-owned transcript before the event
                // is yielded, so a consumer reading ``transcript`` on any
                // event always sees this delta applied.
                transcriptChanged = transcriptStore.applyDelta(
                    role: delta.role, text: delta.text, isFinal: delta.isFinal
                )
            case .turnComplete(let complete):
                transcriptChanged = transcriptStore.applyTurnComplete(role: complete.role)
            default:
                break
            }
            eventsContinuation.yield(event)
            if transcriptChanged {
                eventsContinuation.yield(
                    .transcriptUpdated(TranscriptUpdatedEvent(items: transcriptStore.current))
                )
            }
        }
    }

    private func _transportReconnecting() {
        guard case .connected = lifecycle else { return }
        lifecycle = .reconnecting
        emitState(.reconnecting)
    }

    private func _transportReconnected() {
        guard case .reconnecting = lifecycle else { return }
        lifecycle = .connected
        emitState(.connected)
        // The one-shot bind doesn't survive a transport drop; this surface is
        // always the voice (it publishes the mic during connect), so re-assert
        // the input binding on the recovered connection.
        Task { [weak self] in await self?._sendBindInput() }
        // The server-side mic gate is session-server state that may reset with
        // the transport; re-assert the last state this client set. Best-effort.
        if lastSetMuted != nil {
            Task { [weak self] in await self?._resendMute() }
        }
    }

    /// Rides the audio-operation queue and reads ``lastSetMuted`` once inside
    /// it, so a mute in flight at reconnect time finishes first and the
    /// re-assert can never bury a newer frame under a stale one.
    private func _resendMute() async {
        await beginAudioStreamOperation()
        defer { endAudioStreamOperation() }
        guard let muted = lastSetMuted else { return }
        do {
            try await _publish(
                CosmoRealtimeAPI.Components.Schemas.ClientMute(muted: muted, _type: .mute)
            )
        } catch {
            Self.log.warning("mute re-assert after reconnect failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Tell the server this client is the human voice — bind the agent's input
    /// to us. Best-effort: a transient data-channel hiccup must not fail an
    /// otherwise-live session.
    private func _sendBindInput() async {
        do {
            try await _publish(
                CosmoRealtimeAPI.Components.Schemas.ClientBindInput(_type: .bindInput)
            )
        } catch {
            Self.log.warning(
                "bind-input publish failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: Teardown

    /// Unsolicited transport teardown: a latched server ``session-ended``
    /// reason wins over the transport's own classification of the same
    /// close. Client-initiated paths call ``_close`` directly and ignore
    /// the latch.
    private func _transportClosed(_ reason: CloseReason) async {
        await _close(reason: serverDisconnectReason.map { .serverEnded(reason: $0) } ?? reason)
    }

    /// ``session-ended`` is normally followed by the transport closing; if
    /// that close never arrives, finish after a grace so iteration doesn't
    /// hang forever.
    private func _armServerEndGrace() {
        guard serverEndGraceTask == nil else { return }
        let grace = serverEndGraceNanos
        serverEndGraceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: grace)
            await self?._serverEndGraceFired()
        }
    }

    private func _serverEndGraceFired() async {
        serverEndGraceTask = nil
        if case .closed = lifecycle { return }
        guard let reason = serverDisconnectReason else { return }
        Self.log.warning("session-ended without a transport close — forcing teardown")
        await _close(reason: .serverEnded(reason: reason))
    }

    /// Single terminal teardown path. Idempotent; synthesizes the
    /// terminal ``RealtimeSessionEvent/sessionEnded(_:)`` sentinel as the final event of
    /// a session that reached the live stream, finishes both streams, and
    /// closes the transport.
    private func _close(reason: CloseReason) async {
        if case .closed = lifecycle { return }
        // One ending, one reason: a close before ``ready`` is the window's
        // handshake failure on every surface — what ``start`` throws, the
        // state ``onStateChange`` reports, the stream's terminal item, and
        // the SessionEnd hook. The server-ended and transport-error reasons
        // describe a session that lived.
        var reason = reason
        if !didObserveReady {
            switch reason {
            case .serverEnded(let detail):
                reason = .handshakeFailed(
                    status: nil, detail: detail ?? serverDisconnectReason
                )
            case .transportError(let message):
                reason = .handshakeFailed(status: nil, detail: message)
            default:
                break
            }
        }
        serverEndGraceTask?.cancel()
        serverEndGraceTask = nil
        let wasLive: Bool
        switch lifecycle {
        case .connected, .reconnecting: wasLive = true
        default: wasLive = false
        }
        lifecycle = .closed
        // Cancel any in-flight background client-tool jobs; their results have
        // nowhere to land once the session is torn down.
        await clientToolJobSink?.close()
        clientToolJobSink = nil
        Self.log.info("session closed reason=\(String(describing: reason), privacy: .public)")
        if let hooks {
            let (hookReason, detail) = reason.sessionDisconnectReason
            await hooks.runSessionEnd(
                SessionEndContext(reason: hookReason, detail: detail, sessionId: self.sessionId)
            )
        }
        // The transport close is the terminal signal (the server's
        // best-effort ``session-ended`` frame only latches a reason). A
        // session that reached the live stream ends with a locally
        // synthesized terminal sentinel as its final event; start-time
        // failures (never live) just finish. Mirrors the reference SDK.
        // Close any still-open bubble before the terminal sentinel, so a
        // consumer draining to the end sees finals only; the current value
        // stays readable on ``transcript`` after the stream finishes.
        if transcriptStore.closeOpen() {
            eventsContinuation.yield(
                .transcriptUpdated(TranscriptUpdatedEvent(items: transcriptStore.current))
            )
        }
        if wasLive {
            eventsContinuation.yield(.sessionEnded(SessionEndedEvent(reason: reason.endedReason)))
        }
        let (slug, detail) = reason.sessionDisconnectReason
        emitState(.disconnected(reason: slug, detail: detail))
        onStateChange = nil
        eventsContinuation.finish()
        agentLiveContinuation.finish()
        await transport.close()
        if let onClose {
            self.onClose = nil
            await onClose()
        }
        // The ready gate settles with the window's typed close exit: a caller
        // parked in ``start`` learns the handshake failed rather than waiting
        // out the ready budget on a session that is already gone.
        if !didObserveReady {
            let outcome = pendingReadyOutcome
            pendingReadyOutcome = nil
            _settleReadyWaiters(
                outcome
                    ?? .failure(
                        _handshakeFailure()
                            ?? SessionStartError(
                                code: .handshakeFailed,
                                message: "the session ended before ready"
                            )
                    )
            )
        }
        // Last: a waiter that wakes up sees a fully torn-down session. The
        // agent-live waiters are released too — the agent never showed, and
        // leaving them parked would hang the caller past the session.
        let live = agentLiveWaiters
        agentLiveWaiters = []
        for waiter in live { waiter.resume() }
        let waiters = endWaiters
        endWaiters = []
        for waiter in waiters { waiter.resume() }
    }
}

extension RealtimeClient {
    /// The middleware stack every generated-client construction shares: bearer
    /// auth, and the room ref when a prepared room was taken.
    func _apiMiddlewares(
        prepared: PreparedRoom?
    ) -> [any ClientMiddleware] {
        var middlewares: [any ClientMiddleware] = [
            BearerAuthMiddleware(credential: credential)
        ]
        if let prepared {
            middlewares.append(PreparedRoomHeaderMiddleware(
                roomName: prepared.roomName, roomGrant: prepared.roomGrant
            ))
        }
        return middlewares
    }
}

extension RealtimeSession.CloseReason {
    /// Informational reason string carried on the synthesized
    /// ``RealtimeSessionEvent/sessionEnded(_:)`` sentinel.
    var endedReason: String? {
        switch self {
        case .clientEnded: return "client_ended"
        case .clientClosed: return "client_closed"
        case .serverEnded(let reason): return reason
        case .handshakeFailed(_, let detail): return detail
        case .transportError(let message): return message
        }
    }

    /// Typed ``(reason, detail)`` pair for the ``SessionEndContext``.
    var sessionDisconnectReason: (reason: DisconnectReason, detail: String?) {
        switch self {
        case .clientEnded: return (.clientEnded, nil)
        case .clientClosed: return (.clientClosed, nil)
        case .handshakeFailed(_, let detail): return (.handshakeFailed, detail)
        case .serverEnded(let reason): return (.serverEnded, reason)
        case .transportError(let message): return (.transportError, message)
        }
    }
}

// MARK: - Errors

/// Why the session could not serve the call.
///
/// Closed: every one is thrown by this SDK, so it changes only when the SDK
/// does. Every member is declared in every SDK even where that SDK cannot
/// reach the case, so a branch written against one ports unchanged.
public enum SessionStateErrorCode: String, Sendable, Equatable {
    /// The session is not live. Either it has not reached ``ready`` yet — wait
    /// for it — or it has already ended, in which case start a new one.
    case notConnected = "not_connected"
    /// The session was already started. ``RealtimeSession`` is single-attempt;
    /// build a new one rather than restarting this one.
    case alreadyStarted = "already_started"
    /// A second audio publish was requested while one was live. A session
    /// carries one voice — the microphone or a caller-owned stream.
    case audioPublishAlreadyActive = "audio_publish_already_active"
    /// A second video publish was requested while one was live, so a camera
    /// stream and a screen share cannot run together.
    case videoPublishAlreadyActive = "video_publish_already_active"
    /// Screen capture could not be started by the platform.
    case screenShareUnavailable = "screen_share_unavailable"
    /// A caller-supplied payload would violate a wire-protocol invariant.
    case invalidPayload = "invalid_payload"
}

/// The session cannot serve this call in its current state.
///
/// Thrown from a live-session method rather than at start: a send before
/// ``ready`` or after the session ended, a second publish on a track that
/// carries one, a restart of a single-attempt session. ``code`` names which —
/// switch on it rather than matching the message.
public struct SessionStateError: RealtimeError, LocalizedError, Sendable, Equatable {
    /// Why the session refused. A closed set this SDK throws — switch on it.
    public let code: SessionStateErrorCode
    /// Human-readable explanation, for logs and display.
    public let message: String

    /// A state refusal with its cross-SDK code and message.
    public init(code: SessionStateErrorCode, message: String) {
        self.code = code
        self.message = message
    }

    /// The message, for `LocalizedError` presentation.
    public var errorDescription: String? { message }
}

