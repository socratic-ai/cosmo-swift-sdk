import AVFAudio
import CoreMedia
import Foundation
import os
@testable import CosmoRealtime

// MARK: - Fake transport

/// In-memory ``SessionTransport``: records every frame the session
/// hands it (the serialized ``session-config`` plus all sends) and
/// lets tests inject raw server frames through the same ``onFrame``
/// path the LiveKit transport uses.
actor FakeSessionTransport: SessionTransport {
    private(set) var sent: [Data] = []
    private(set) var micEnabled: Bool?
    private(set) var connectedMicMuted: Bool?
    private(set) var registeredToolHandlers: [String: ClientToolHandler] = [:]
    var registeredHookExemptMethods: Set<String> = []
    nonisolated let supportsByteStreams: Bool

    init(supportsByteStreams: Bool = true) {
        self.supportsByteStreams = supportsByteStreams
    }

    private(set) var registeredBackgroundToolHandlers: [String: BackgroundClientToolHandler] = [:]
    private(set) var clientToolJobSink: ClientToolJobSink?
    private var callbacks: SessionTransportCallbacks?
    private var scriptedRejection: SessionStartFailure?
    private var scriptedMicError: Error?
    private var scriptedSendError: Error?
    private var scriptedConnectFrames: [Data] = []
    private var scriptedConnectPhases: (ws: Double, room: Double, mic: Double, total: Double)?
    private var suspendNextAudioStreamStart = false
    private var audioStreamStartContinuation: CheckedContinuation<Void, Never>?
    private var suspendNextAudioStreamStop = false
    private var audioStreamStopContinuation: CheckedContinuation<Void, Never>?

    /// The fake measures no phases of its own; it starts the handshake clock
    /// and records the server breakdown off the start response, so the marks
    /// the session adds later measure from a real origin.
    nonisolated let timings = SessionConnectTimingsRecorder()

    /// Start response the fake reports; its server breakdown stays nil so
    /// tests that care opt in by overriding the response. Lock-backed so a
    /// nonisolated caller can read it.
    nonisolated let startResponseBox = OSAllocatedUnfairLock(
        initialState: RealtimeSessionResponse(
            livekitUrl: "ws://fake.invalid",
            roomName: "trace-room",
            sessionId: "trace-session",
            token: "trace-token"
        )
    )

    func setStartResponse(_ response: RealtimeSessionResponse) {
        startResponseBox.withLock { $0 = response }
    }

    func scriptRejection(_ failure: SessionStartFailure) {
        scriptedRejection = failure
    }

    func scriptMicError(_ error: Error) {
        scriptedMicError = error
    }

    func suspendAudioStreamStart() {
        suspendNextAudioStreamStart = true
    }

    func audioStreamStartIsSuspended() -> Bool {
        audioStreamStartContinuation != nil
    }

    func resumeAudioStreamStart() {
        audioStreamStartContinuation?.resume()
        audioStreamStartContinuation = nil
    }

    func suspendAudioStreamStop() {
        suspendNextAudioStreamStop = true
    }

    func audioStreamStopIsSuspended() -> Bool {
        audioStreamStopContinuation != nil
    }

    func resumeAudioStreamStop() {
        audioStreamStopContinuation?.resume()
        audioStreamStopContinuation = nil
    }

    /// Fail the next wire send — the path ``setMuted`` rides, so a test can
    /// refuse the mute gate without touching the microphone.
    func scriptSendError(_ error: Error) {
        scriptedSendError = error
    }

    /// Deliver a server frame from inside ``connect``, before it returns — the
    /// window in which a frame can beat the connect phases onto the recorder.
    func scriptFrameDuringConnect(_ frame: Data) {
        scriptedConnectFrames.append(frame)
    }

    /// Record connect phases the way the real transport does: at the end of
    /// ``connect``, after any frame the join already delivered.
    func scriptConnectPhases(ws: Double, room: Double, mic: Double, total: Double) {
        scriptedConnectPhases = (ws, room, mic, total)
    }

    func connect(
        configFrame: Data,
        callbacks: SessionTransportCallbacks,
        clientToolHandlers: [String: ClientToolHandler],
        backgroundClientToolHandlers: [String: BackgroundClientToolHandler],
        clientToolJobSink: ClientToolJobSink?,
        hooks: HookEngine?,
        hookExemptMethods: Set<String>,
        micMuted: Bool
    ) async throws -> SessionStartInfo {
        timings.setHandshakeStart(Date())
        sent.append(configFrame)
        connectedMicMuted = micMuted
        // The real transport publishes the microphone during the join unless
        // the session asked to start muted (``ConnectOptions.enableMicrophone``).
        micEnabled = !micMuted
        if let scriptedRejection {
            throw scriptedRejection
        }
        self.callbacks = callbacks
        self.registeredToolHandlers = clientToolHandlers
        self.registeredHookExemptMethods = hookExemptMethods
        self.registeredBackgroundToolHandlers = backgroundClientToolHandlers
        self.clientToolJobSink = clientToolJobSink
        for frame in scriptedConnectFrames {
            await callbacks.onFrame(frame)
        }
        if let phases = scriptedConnectPhases {
            timings.setConnectPhases(
                wsMs: phases.ws, roomMs: phases.room, micMs: phases.mic, totalMs: phases.total
            )
        }
        let response = startResponseBox.withLock { $0 }
        if let serverTimings = response.timings {
            timings.setServerTimings(RealtimeSessionStartTimings(serverTimings))
        }
        return SessionStartInfo(sessionId: response.sessionId)
    }

    func send(frame: Data) async throws {
        if let scriptedSendError {
            self.scriptedSendError = nil
            throw scriptedSendError
        }
        sent.append(frame)
    }

    private(set) var sentBytes: [(data: Data, topic: String)] = []
    func sendBytes(_ data: Data, topic: String) async throws {
        sentBytes.append((data, topic))
    }

    func setMicrophoneEnabled(_ enabled: Bool) async throws {
        if let scriptedMicError {
            throw scriptedMicError
        }
        micEnabled = enabled
    }

    private(set) var closed = false
    /// Set the moment ``close`` is entered, before it suspends — so a test
    /// can tell "teardown started" from "teardown finished".
    private(set) var closeStarted = false
    private var suspendNextClose = false
    private var closeGate: CheckedContinuation<Void, Never>?

    /// Hold the next ``close`` open until ``resumeClose``. Lets a test pin
    /// what may and may not be observable while teardown is still running.
    func suspendClose() {
        suspendNextClose = true
    }

    func closeIsSuspended() -> Bool {
        closeGate != nil
    }

    func resumeClose() {
        closeGate?.resume()
        closeGate = nil
    }

    func close() async {
        closeStarted = true
        if suspendNextClose {
            suspendNextClose = false
            await withCheckedContinuation { continuation in
                closeGate = continuation
            }
        }
        closed = true
    }

    // No test exercises audio levels; an empty finished stream satisfies
    // the protocol and keeps the suite compiling.
    nonisolated let inputLevels: AsyncStream<Float> = AsyncStream { $0.finish() }
    nonisolated let outputLevels: AsyncStream<Float> = AsyncStream { $0.finish() }

    // No test exercises screen share through this fake, so these stubs
    // only satisfy the protocol and keep the suite compiling.
    private(set) var screenShareStarted = false

    func startScreenShare() async throws { screenShareStarted = true }
    nonisolated func pushScreenShareFrame(_ sampleBuffer: CMSampleBuffer) {}
    func stopScreenShare() async { screenShareStarted = false }
    nonisolated func setScreenShareFrameProcessor(_ processor: ScreenShareFrameProcessor?) {}
    nonisolated func onScreenShareFailed(_ handler: @escaping @Sendable (Error) -> Void) -> Cancellable {
        Cancellable {}
    }

    // No test exercises video streams through this fake either.
    private(set) var videoStreamActive = false

    func addVideoStream() async throws -> VideoStreamHandle {
        videoStreamActive = true
        return VideoStreamHandle(streamID: UUID()) { _ in }
    }
    func removeVideoStream(_ handle: VideoStreamHandle) async { videoStreamActive = false }

    private(set) var audioStreamActive = false
    /// Mirrors the real transport: the stream publishes the local audio track,
    /// and stopping puts back whatever was there before.
    private var micWasPublishingBeforeStream = false

    func startAudioStream() async throws {
        micWasPublishingBeforeStream = micEnabled ?? false
        try await setMicrophoneEnabled(true)
        audioStreamActive = true
        if suspendNextAudioStreamStart {
            suspendNextAudioStreamStart = false
            await withCheckedContinuation { continuation in
                audioStreamStartContinuation = continuation
            }
        }
    }
    nonisolated func pushAudioBuffer(_ buffer: AVAudioPCMBuffer) {}
    @discardableResult
    func stopAudioStream() async -> Bool {
        if suspendNextAudioStreamStop {
            suspendNextAudioStreamStop = false
            await withCheckedContinuation { continuation in
                audioStreamStopContinuation = continuation
            }
        }
        guard audioStreamActive else { return false }
        audioStreamActive = false
        guard micWasPublishingBeforeStream else {
            try? await setMicrophoneEnabled(false)
            return false
        }
        return true
    }

    /// Deliver one raw server frame, awaiting the session's handling so
    /// injection order is processing order.
    func simulateClose(_ reason: RealtimeSession.CloseReason) async {
        await callbacks?.onClosed(reason)
    }

    func inject(_ data: Data) async {
        await callbacks?.onFrame(data)
    }

    /// Drive the transport-drop callbacks the way the real transport does: a
    /// reconnecting notice followed by the recovered connection.
    func simulateReconnect() async {
        await callbacks?.onReconnecting()
        await callbacks?.onReconnected()
    }

    /// Fire the agent-track readiness signal (what the LiveKit transport calls
    /// when the agent publishes its track), so tests can exercise readiness
    /// without a real room.
    func signalAgentLive() async {
        await callbacks?.onAgentLive()
    }
}

// MARK: - Observation

/// One SDK-emitted event (or sent frame) normalized to the wire
/// vocabulary: the wire ``type`` discriminator plus the JSON fields.
struct ObservedEvent: Sendable {
    let type: String
    let fields: [String: JSONValue]
}

func observeSentFrame(_ data: Data) -> ObservedEvent {
    guard case .object(let fields)? = try? JSONDecoder().decode(JSONValue.self, from: data) else {
        return ObservedEvent(type: "<unparseable>", fields: [:])
    }
    guard case .string(let type)? = fields["type"] else {
        return ObservedEvent(type: "<untyped>", fields: fields)
    }
    return ObservedEvent(type: type, fields: fields)
}

// MARK: - Waiting

func waitUntil(deadline: TimeInterval, _ condition: @Sendable () -> Bool) async {
    let end = Date().addingTimeInterval(deadline)
    while !condition() && Date() < end {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}
