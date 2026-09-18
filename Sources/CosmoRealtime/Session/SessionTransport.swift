import AVFAudio
import CoreMedia
import CosmoRealtimeAPI
import Foundation

/// Internal name for the generated room-start response. Only the room
/// transport consumes its join credentials.
typealias RealtimeSessionResponse =
    CosmoRealtimeAPI.Components.Schemas.SessionResponse

/// Transport-neutral result of a successful session start.
struct SessionStartInfo: Sendable {
    let sessionId: String
}

/// Typed start failures a transport can raise from
/// ``SessionTransport/connect(configFrame:callbacks:)``.
/// ``RealtimeSession`` maps them onto ``SessionStartError`` and the
/// terminal lifecycle state.
enum SessionStartFailure: Error, Sendable {
    /// The server refused the session (HTTP rejection or a scripted
    /// handshake ``error`` frame). ``status`` is the HTTP status of the
    /// rejection when it came from a real REST verdict (nil for a scripted
    /// handshake-frame rejection); ``code`` is the protocol error code when
    /// one could be extracted (e.g. ``"version_mismatch"``).
    case rejected(
        status: Int?,
        code: String?,
        detail: String,
        retryAfterSeconds: Int? = nil,
        /// The server's structured reason, parsed where the raw body was
        /// still in hand. ``detail`` is rendered for humans and may carry a
        /// status prefix, so it cannot be re-parsed as JSON downstream.
        rejection: SessionStartRejection? = nil
    )
    /// The start never reached a server verdict — a network failure or a
    /// timeout. Nothing happened server-side.
    case transport(message: String)
    /// The server answered 2xx but not with a body this SDK could read, so a
    /// session may already exist. Distinct from ``transport``: retrying this
    /// can orphan the one that was created.
    case invalidResponse(message: String)
    /// The server accepted the session but the transport could not join the
    /// room. Distinct from ``transport``: the start itself succeeded, so this
    /// carries no verdict from the server.
    case joinFailed(message: String)
    /// The active transport does not offer a capability the caller asked for.
    /// No server was involved, so there is no status — the slug is the whole
    /// verdict, and the session reports it as a config refusal the way the
    /// other SDKs do.
    case unsupportedCapability(code: String, detail: String)
    /// The join failed on the microphone it was publishing. Carried
    /// separately because the default join publishes inside ``Room.connect``,
    /// so this is where a refused capture surfaces — the session raises it as
    /// ``AudioUnavailableError`` rather than an opaque transport failure.
    case captureUnavailable(code: AudioUnavailableErrorCode, message: String)
    /// The room went down while the join was still in flight — a boot that
    /// failed fast and deleted it. Distinct from ``transport`` because the
    /// session turns it into the window's handshake failure rather than a
    /// raw join error: the close is what actually explains the failure.
    case roomLostDuringJoin(reason: RealtimeSession.CloseReason)
    /// The credential could not be resolved before the request went out —
    /// a ``TokenSource`` fetch failed in the auth middleware. Carried
    /// un-erased so ``RealtimeSession`` can rethrow the ``TokenSourceError``
    /// (and its code) to the ``start`` caller, matching the other SDKs.
    case credential(TokenSourceError)
}

/// How a transport reports asynchronous activity back to the session.
/// All closures hop onto the session actor; the transport must deliver
/// ``onFrame`` calls in wire arrival order (awaiting each call before
/// the next preserves it).
struct SessionTransportCallbacks: Sendable {
    let onFrame: @Sendable (Data) async -> Void
    let onClosed: @Sendable (RealtimeSession.CloseReason) async -> Void
    let onReconnecting: @Sendable () async -> Void
    let onReconnected: @Sendable () async -> Void
    /// The transport observed the agent go live. Fired at most once per
    /// session. On LiveKit that is the agent publishing a media track — a
    /// race-free signal independent of the server ``ready`` data frame, which
    /// can be lost to the pre-data-channel broadcast race (published before
    /// this client's data channel was up, never replayed). On the websocket
    /// transport it is the first ``ready`` frame, which that lane delivers
    /// reliably. A transport with neither (the contract-trace fake) simply
    /// never calls it; readiness then rides the ``ready`` frame as before.
    let onAgentLive: @Sendable () async -> Void
}

/// Protocol-agnostic transport under ``RealtimeSession``: carries
/// opaque JSON frames both ways and owns the audio path. Production is
/// ``LiveKitSessionTransport``; the contract-trace suite drives the
/// session through an in-memory fake.
protocol SessionTransport: Sendable {
    /// Start the session: deliver ``configFrame`` (the serialized
    /// ``session-config``) to the server and bring up the media
    /// transport. ``clientToolHandlers`` are the local handlers the agent
    /// drives over the transport (LiveKit RPC), keyed by tool name.
    /// Returns once the transport is live; server events then flow through
    /// ``callbacks.onFrame``.
    ///
    /// When ``micMuted`` is `true` the transport joins WITHOUT publishing
    /// the microphone — nothing is captured or sent until the first
    /// ``setMicrophoneEnabled(true)``. Privacy contract: a session the host
    /// presents as "muted" must never stream audio during the connect
    /// window (the agent is already in the room by then).
    /// ``hookExemptMethods`` names entries in ``clientToolHandlers`` that are
    /// wire plumbing rather than model-invoked tools (the capture RPC,
    /// caller-registered RPC methods): hook dispatch skips them — hooks fire
    /// for tool calls, and these are not.
    func connect(
        configFrame: Data,
        callbacks: SessionTransportCallbacks,
        clientToolHandlers: [String: ClientToolHandler],
        backgroundClientToolHandlers: [String: BackgroundClientToolHandler],
        clientToolJobSink: ClientToolJobSink?,
        hooks: HookEngine?,
        hookExemptMethods: Set<String>,
        micMuted: Bool
    ) async throws -> SessionStartInfo
    /// Publish one already-chunked wire packet, in order.
    func send(frame: Data) async throws
    /// Stream raw bytes to the agent on a named ``topic``, out of band from
    /// the JSON control channel — for large binary client-tool payloads (a
    /// screenshot + accessibility dump, etc.). Delivered only to the agent
    /// participant.
    func sendBytes(_ data: Data, topic: String) async throws
    /// Whether the transport carries byte streams (see the extension default).
    nonisolated var supportsByteStreams: Bool { get }
    /// Toggle microphone capture. For a muted join this is where the mic
    /// first publishes, so it can throw (e.g. denied capture permission);
    /// ``RealtimeSession/setMuted(_:)`` surfaces that rather than reporting a
    /// false success while no track is published.
    func setMicrophoneEnabled(_ enabled: Bool) async throws
    /// Tear down the media transport. Idempotent.
    func close() async

    // MARK: Audio levels

    /// Per-buffer microphone RMS (0…1), latest-value: a slow consumer
    /// drops intermediate samples rather than accumulating them. Yields
    /// while a local audio track is published; finishes at ``close()``.
    nonisolated var inputLevels: AsyncStream<Float> { get }
    /// Per-buffer agent-audio RMS (0…1), latest-value like
    /// ``inputLevels``. Yields while the remote agent audio track is
    /// subscribed; finishes at ``close()``.
    nonisolated var outputLevels: AsyncStream<Float> { get }

    /// Set software playback gain (0…1) for the agent's audio: `0` mutes,
    /// `1` is unity. Applied to the subscribed agent track and re-applied
    /// when a later track attaches. Default no-op (see the extension) — only
    /// the production LiveKit transport attenuates a real track.
    nonisolated func setAgentPlaybackVolume(_ volume: Double)

    // MARK: Screen share

    /// Begin a screen-share publish. Creates the video track immediately
    /// but defers the SFU publish until the first
    /// ``pushScreenShareFrame`` arrives, since the capturer cannot
    /// resolve frame dimensions before one sample buffer is captured.
    /// Idempotent: any prior share is stopped first.
    func startScreenShare() async throws
    /// Push one captured frame into the active screen-share publish.
    /// Safe to call from a capture thread. The first call triggers the
    /// deferred publish; later calls feed the publishing track. No-op
    /// when no share is active.
    nonisolated func pushScreenShareFrame(_ sampleBuffer: CMSampleBuffer)
    /// Stop the active screen-share publish. Idempotent.
    func stopScreenShare() async
    /// Install or clear a frame processor run inside
    /// ``pushScreenShareFrame`` before each frame reaches the capturer.
    /// Pass ``nil`` to remove a previously-installed processor.
    nonisolated func setScreenShareFrameProcessor(_ processor: ScreenShareFrameProcessor?)
    /// Register a callback fired when the deferred screen-share publish
    /// fails (SFU rejection, codec mismatch, network blip). Share state
    /// is cleared before the callback fires, so the handler may restart
    /// the share. Returns a ``Cancellable`` to drop the listener.
    nonisolated func onScreenShareFailed(_ handler: @escaping @Sendable (Error) -> Void) -> Cancellable

    // MARK: Video streams

    /// Begin a non-screen video publish (camera, file, any pixels-only
    /// stream) and return its pushable handle, on the same
    /// deferred-publish contract as ``startScreenShare``. One video
    /// publish at a time: throws
    /// ``SessionStateError`` while any
    /// video publish is live.
    func addVideoStream() async throws -> VideoStreamHandle
    /// Remove a video stream added by ``addVideoStream``. Identity-keyed
    /// and idempotent: a stale handle is a no-op.
    func removeVideoStream(_ handle: VideoStreamHandle) async

    // MARK: Audio streams

    /// Take the session's voice for a caller-owned audio publish. Publishes
    /// the local audio track if it is not already publishing and silences the
    /// device microphone for the duration, so the agent hears exactly the
    /// pushed buffers. Throws
    /// ``SessionStateError`` while one is running.
    func startAudioStream() async throws
    /// Push one buffer into the running stream; inert when none is. May
    /// synchronously convert and copy the buffer.
    nonisolated func pushAudioBuffer(_ buffer: AVAudioPCMBuffer)
    /// Put back what the stream displaced, reporting whether the microphone
    /// holds the voice afterwards. Idempotent.
    @discardableResult
    func stopAudioStream() async -> Bool

    // MARK: Connect timings

    /// Where the connect phases are recorded. The transport writes the marks
    /// it measures itself; the session adds the ones only it sees, on frames
    /// that arrive after the connect returns.
    nonisolated var timings: SessionConnectTimingsRecorder { get }
}

extension SessionTransport {
    /// Transports without a real audio path (the contract-trace fake) have
    /// nothing to attenuate, so playback gain is a no-op for them.
    nonisolated func setAgentPlaybackVolume(_ volume: Double) {}

    /// Connect-latency breakdown: the client-measured connect phases plus
    /// the server's own session-start timings.
    nonisolated var connectTimings: SessionConnectTimings { timings.snapshot() }

    func sendBytes(_ data: Data, topic: String) async throws {
        throw SessionStateError(code: .invalidPayload, message: 
            "active transport does not carry byte streams"
        )
    }

    /// Whether the transport carries byte streams — the channel the screen
    /// locator's capture payload needs. Defaults to true; the websocket
    /// carrier overrides it, and session start refuses a ``screen_locate``
    /// declaration it could never serve.
    nonisolated var supportsByteStreams: Bool { true }

    func startScreenShare() async throws {
        throw SessionStartError(
            code: .config,
            message: "This transport carries no video; use the WebRTC transport for camera or screen input.",
            serverCode: "video_unsupported"
        )
    }

    nonisolated func pushScreenShareFrame(_ sampleBuffer: CMSampleBuffer) {}
    func stopScreenShare() async {}
    nonisolated func setScreenShareFrameProcessor(_ processor: ScreenShareFrameProcessor?) {}

    nonisolated func onScreenShareFailed(
        _ handler: @escaping @Sendable (Error) -> Void
    ) -> Cancellable {
        Cancellable {}
    }

    func addVideoStream() async throws -> VideoStreamHandle {
        throw SessionStartError(
            code: .config,
            message: "This transport carries no video; use the WebRTC transport for camera or screen input.",
            serverCode: "video_unsupported"
        )
    }

    func removeVideoStream(_ handle: VideoStreamHandle) async {}
}
