import AVFAudio
import CoreMedia
import Foundation
import os

enum WebSocketMessage: Sendable {
    case text(String)
    case data(Data)
}

protocol WebSocketConnection: Sendable {
    var closeCode: URLSessionWebSocketTask.CloseCode { get async }
    var closeReason: Data? { get async }
    func resume()
    func receive() async throws -> WebSocketMessage
    func send(_ message: WebSocketMessage) async throws
    func close()
}

protocol WebSocketAudioHandling: Sendable {
    func prepare(
        inputSampleRate: Int,
        outputSampleRate: Int,
        microphoneEnabled: Bool,
        sendAudio: @escaping @Sendable (Data) -> Void
    ) async throws
    func setMicrophoneEnabled(_ enabled: Bool) async throws
    func play(_ data: Data) async
    func flushPlayback() async
    func setVolume(_ volume: Double) async
    func close() async
}

final class URLSessionWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    var closeCode: URLSessionWebSocketTask.CloseCode { task.closeCode }

    var closeReason: Data? { task.closeReason }

    func resume() {
        task.resume()
    }

    func receive() async throws -> WebSocketMessage {
        switch try await task.receive() {
        case .string(let text): return .text(text)
        case .data(let data): return .data(data)
        @unknown default:
            throw SessionStartError(code: .transport, message: "websocket returned an unknown message")
        }
    }

    func send(_ message: WebSocketMessage) async throws {
        switch message {
        case .text(let text): try await task.send(.string(text))
        case .data(let data): try await task.send(.data(data))
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

final class WebSocketAudioSendQueue: Sendable {
    struct Packet: Sendable {
        let generation: UInt64
        let data: Data
    }

    private static let log = Logger(
        subsystem: CosmoRealtimeLog.subsystem,
        category: "session-websocket-audio"
    )

    let stream: AsyncStream<Packet>
    private let continuation: AsyncStream<Packet>.Continuation

    init(capacity: Int = 32) {
        let pair = AsyncStream<Packet>.makeStream(
            bufferingPolicy: .bufferingNewest(capacity)
        )
        stream = pair.stream
        continuation = pair.continuation
    }

    func enqueue(_ packet: Packet) {
        if case .dropped = continuation.yield(packet) {
            Self.log.warning("outbound audio queue dropped its oldest buffer")
        }
    }

    func finish() {
        continuation.finish()
    }
}

final class WebSocketAudioGeneration: Sendable {
    private let value = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    func packet(_ data: Data) -> WebSocketAudioSendQueue.Packet {
        WebSocketAudioSendQueue.Packet(
            generation: value.withLock { $0 },
            data: data
        )
    }

    func advance() {
        value.withLock { $0 &+= 1 }
    }

    func advanceAndCurrent() -> UInt64 {
        value.withLock {
            $0 &+= 1
            return $0
        }
    }

    func contains(_ packet: WebSocketAudioSendQueue.Packet) -> Bool {
        value.withLock { $0 == packet.generation }
    }
}

actor WebSocketSessionTransport: SessionTransport {
    struct StartResponse: Decodable, Sendable {
        let sessionId: String
        let websocketURL: URL
        let subprotocolName: String
        let timings: RealtimeSessionStartTimings?

        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case websocketURL = "ws_url"
            case subprotocolName = "ws_subprotocol"
            case timings
        }
    }

    private struct AudioFormat: Decodable {
        let type: String
        let inputSampleRate: Int
        let outputSampleRate: Int
        let channelCount: Int

        enum CodingKeys: String, CodingKey {
            case type
            case inputSampleRate = "input_sample_rate_hz"
            case outputSampleRate = "output_sample_rate_hz"
            case channelCount = "num_channels"
        }
    }

    private struct FrameKind: Decodable {
        let type: String
    }

    private struct RPCRequest: Decodable {
        let requestId: String
        let method: String
        let payload: String

        enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case method, payload
        }
    }

    private struct RPCCancel: Decodable {
        let requestId: String

        enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
        }
    }

    private struct RPCResponse: Encodable {
        let type = "rpc-response"
        let requestId: String
        let payload: String?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case type
            case requestId = "request_id"
            case payload, error
        }
    }

    private static let log = Logger(
        subsystem: CosmoRealtimeLog.subsystem,
        category: "session-websocket"
    )

    private let client: RealtimeClient
    nonisolated let timings = SessionConnectTimingsRecorder()
    private let inputRate = OSAllocatedUnfairLock<Int>(initialState: 0)
    private let audioStreamOwner = OSAllocatedUnfairLock<UInt64?>(initialState: nil)
    private let inputLevelsContinuation: AsyncStream<Float>.Continuation
    private let outputLevelsContinuation: AsyncStream<Float>.Continuation
    private let audio: any WebSocketAudioHandling
    private let audioSendQueue = WebSocketAudioSendQueue()
    private let audioGeneration = WebSocketAudioGeneration()
    private let callerAudioConverter = WebSocketAudio.StreamConverter()
    private let playbackVolumeUpdates: AsyncStream<Double>
    private let playbackVolumeContinuation: AsyncStream<Double>.Continuation
    private let startOverride: (@Sendable (Data) async throws -> StartResponse)?
    private let connectionFactory: @Sendable (
        StartResponse,
        URLSession
    ) -> any WebSocketConnection
    nonisolated let inputLevels: AsyncStream<Float>
    nonisolated let outputLevels: AsyncStream<Float>
    private var urlSession: URLSession?
    private var connection: (any WebSocketConnection)?
    private var reader: Task<Void, Never>?
    private var audioSender: Task<Void, Never>?
    private var playbackVolumeSetter: Task<Void, Never>?
    private var callbacks: SessionTransportCallbacks?
    private var toolHandlers: [String: ClientToolHandler] = [:]
    private var rpcRuns: [String: Task<Void, Never>] = [:]
    private var hooks: HookEngine?
    private var hookExemptMethods: Set<String> = []
    private var sessionId: String?
    private var agentLiveSignaled = false
    private var closing = false
    private var microphoneEnabled = false
    private var restoreMicrophoneAfterStream = false

    init(client: RealtimeClient) {
        self.init(
            client: client,
            startOverride: nil,
            connectionFactory: { started, session in
                URLSessionWebSocketConnection(
                    task: session.webSocketTask(
                        with: started.websocketURL,
                        protocols: [started.subprotocolName]
                    )
                )
            },
            audioFactory: { input, output in
                WebSocketAudio(
                    inputLevelsContinuation: input,
                    outputLevelsContinuation: output
                )
            }
        )
    }

    init(
        client: RealtimeClient,
        startOverride: (@Sendable (Data) async throws -> StartResponse)?,
        connectionFactory: @escaping @Sendable (
            StartResponse,
            URLSession
        ) -> any WebSocketConnection,
        audioFactory: (
            AsyncStream<Float>.Continuation,
            AsyncStream<Float>.Continuation
        ) -> any WebSocketAudioHandling
    ) {
        self.client = client
        self.startOverride = startOverride
        self.connectionFactory = connectionFactory
        let input = AsyncStream<Float>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let output = AsyncStream<Float>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let playbackVolume = AsyncStream<Double>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        inputLevels = input.stream
        outputLevels = output.stream
        playbackVolumeUpdates = playbackVolume.stream
        playbackVolumeContinuation = playbackVolume.continuation
        inputLevelsContinuation = input.continuation
        outputLevelsContinuation = output.continuation
        audio = audioFactory(input.continuation, output.continuation)
    }

    nonisolated var supportsByteStreams: Bool { false }

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
        guard backgroundClientToolHandlers.isEmpty else {
            throw SessionStartFailure.unsupportedCapability(
                code: "background_tools_unsupported",
                detail: "background client tools are not supported on the websocket transport"
            )
        }
        let startedAt = Date()
        timings.setHandshakeStart(startedAt)
        let started: StartResponse
        if let startOverride {
            started = try await startOverride(configFrame)
        } else {
            started = try await startSession(configFrame: configFrame)
        }
        let restReadyAt = Date()
        if let serverTimings = started.timings {
            timings.setServerTimings(serverTimings)
        }
        guard Self.isSupportedWebSocketURL(started.websocketURL) else {
            throw SessionStartFailure.transport(
                message: "websocket start returned an insecure remote socket URL (remote hosts require wss)"
            )
        }
        let session = makeWebSocketSession(for: started.websocketURL)
        let connection = connectionFactory(started, session)
        self.urlSession = session
        self.connection = connection
        self.callbacks = callbacks
        self.toolHandlers = clientToolHandlers
        self.hooks = hooks
        self.hookExemptMethods = hookExemptMethods
        sessionId = started.sessionId
        do {
            let socketStartedAt = Date()
            connection.resume()

            let first: WebSocketMessage
            do {
                first = try await _withConnectTimeout(
                    seconds: client.connectTimeout,
                    operation: { try await connection.receive() },
                    onLateSettlement: { connection.close() }
                )
            } catch is ConnectTimeoutReached {
                throw SessionStartFailure.transport(
                    message: "websocket connect timed out after \(client.connectTimeout)s"
                )
            } catch {
                throw SessionStartFailure.transport(
                    message: "websocket session was refused: \(error.localizedDescription)"
                )
            }
            let format = try decodeAudioFormat(first)
            inputRate.withLock { $0 = format.inputSampleRate }
            let socketReadyAt = Date()
            audioSender = Task { [weak self, stream = audioSendQueue.stream, audioGeneration] in
                for await packet in stream {
                    guard !Task.isCancelled else { return }
                    guard audioGeneration.contains(packet) else { continue }
                    await self?.sendAudio(packet.data)
                }
            }
            do {
                try await audio.prepare(
                    inputSampleRate: format.inputSampleRate,
                    outputSampleRate: format.outputSampleRate,
                    microphoneEnabled: !micMuted,
                    sendAudio: { [audioSendQueue, audioGeneration] data in
                        audioSendQueue.enqueue(audioGeneration.packet(data))
                    }
                )
            } catch let unavailable as AudioUnavailableError {
                // Carry it across the transport boundary the way the WebRTC
                // carrier does, so `catch AudioUnavailableError` around
                // `start()` means the same thing on both.
                throw SessionStartFailure.captureUnavailable(
                    code: unavailable.code, message: unavailable.message
                )
            } catch {
                throw SessionStartFailure.transport(
                    message: "websocket audio could not start: \(error.localizedDescription)"
                )
            }
            microphoneEnabled = !micMuted
            let readyAt = Date()
            let phases = Self.connectPhases(
                startedAt: startedAt,
                restReadyAt: restReadyAt,
                socketStartedAt: socketStartedAt,
                socketReadyAt: socketReadyAt,
                readyAt: readyAt,
                micMuted: micMuted
            )
            timings.setConnectPhases(
                wsMs: phases.wsMs,
                roomMs: phases.roomMs,
                micMs: phases.micMs,
                totalMs: phases.totalMs
            )
            playbackVolumeSetter = Task { [audio, stream = playbackVolumeUpdates] in
                for await volume in stream {
                    guard !Task.isCancelled else { return }
                    await audio.setVolume(volume)
                }
            }
            reader = Task { [weak self] in await self?.readLoop() }
            return SessionStartInfo(sessionId: started.sessionId)
        } catch {
            await close()
            throw error
        }
    }

    func send(frame: Data) async throws {
        guard let connection, let text = String(data: frame, encoding: .utf8) else {
            throw SessionStateError(code: .notConnected, message: "RealtimeSession is not connected.")
        }
        try await connection.send(.text(text))
    }

    func setMicrophoneEnabled(_ enabled: Bool) async throws {
        if audioStreamOwner.withLock({ $0 }) != nil {
            microphoneEnabled = false
            return
        }
        try await audio.setMicrophoneEnabled(enabled)
        audioGeneration.advance()
        microphoneEnabled = enabled
    }

    func close() async {
        guard !closing else { return }
        closing = true
        reader?.cancel()
        reader = nil
        audioSender?.cancel()
        audioSender = nil
        audioSendQueue.finish()
        playbackVolumeSetter?.cancel()
        playbackVolumeSetter = nil
        playbackVolumeContinuation.finish()
        for task in rpcRuns.values { task.cancel() }
        rpcRuns.removeAll()
        connection?.close()
        connection = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        await audio.close()
        callbacks = nil
        toolHandlers.removeAll()
        inputLevelsContinuation.finish()
        outputLevelsContinuation.finish()
        audioStreamOwner.withLock { $0 = nil }
    }

    nonisolated func setAgentPlaybackVolume(_ volume: Double) {
        playbackVolumeContinuation.yield(min(max(volume, 0), 1))
    }

    func startAudioStream() async throws {
        guard audioStreamOwner.withLock({ $0 == nil }) else {
            throw SessionStateError(code: .audioPublishAlreadyActive, message: "An audio stream is already active on this session; remove it before starting another.")
        }
        let owner = audioGeneration.advanceAndCurrent()
        audioStreamOwner.withLock { $0 = owner }
        restoreMicrophoneAfterStream = microphoneEnabled
        do {
            if microphoneEnabled {
                try await audio.setMicrophoneEnabled(false)
                microphoneEnabled = false
            }
        } catch {
            audioStreamOwner.withLock { $0 = nil }
            audioGeneration.advance()
            throw error
        }
    }

    nonisolated func pushAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let owner = audioStreamOwner.withLock({ $0 }) else { return }
        let rate = inputRate.withLock { $0 }
        guard rate > 0,
              let data = try? callerAudioConverter.convert(buffer, sampleRate: rate)
        else { return }
        audioSendQueue.enqueue(.init(generation: owner, data: data))
    }

    @discardableResult
    func stopAudioStream() async -> Bool {
        let wasActive = audioStreamOwner.withLock { owner -> Bool in
            guard owner != nil else { return false }
            owner = nil
            return true
        }
        guard wasActive else { return false }
        audioGeneration.advance()
        let restoreMicrophone = restoreMicrophoneAfterStream
        restoreMicrophoneAfterStream = false
        guard restoreMicrophone else { return false }
        do {
            try await audio.setMicrophoneEnabled(true)
            microphoneEnabled = true
            return true
        } catch {
            Self.log.error(
                "audio stream stopped but the microphone could not be restored: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    func startScreenShare() async throws {
        throw Self.videoUnsupported()
    }

    nonisolated func pushScreenShareFrame(_ sampleBuffer: CMSampleBuffer) {
        Self.logVideoRefusal("pushScreenShareFrame")
    }

    func stopScreenShare() async {
        Self.logVideoRefusal("stopScreenShare")
    }

    nonisolated func setScreenShareFrameProcessor(_ processor: ScreenShareFrameProcessor?) {
        // Clearing (nil) is teardown housekeeping, not a video attempt.
        guard processor != nil else { return }
        Self.logVideoRefusal("setScreenShareFrameProcessor")
    }

    func addVideoStream() async throws -> VideoStreamHandle {
        throw Self.videoUnsupported()
    }

    func removeVideoStream(_ handle: VideoStreamHandle) async {
        Self.logVideoRefusal("removeVideoStream")
    }

    private static func videoUnsupported() -> SessionStartFailure {
        .unsupportedCapability(
            code: "video_unsupported",
            detail: "video and screen share are not supported by the websocket transport"
        )
    }

    private nonisolated static func logVideoRefusal(_ entryPoint: String) {
        log.warning(
            "\(entryPoint, privacy: .public) refused code=video_unsupported: the websocket transport does not carry video"
        )
    }

    static func connectPhases(
        startedAt: Date,
        restReadyAt: Date,
        socketStartedAt: Date,
        socketReadyAt: Date,
        readyAt: Date,
        micMuted: Bool
    ) -> (wsMs: Double, roomMs: Double, micMs: Double, totalMs: Double) {
        (
            wsMs: restReadyAt.timeIntervalSince(startedAt) * 1_000,
            roomMs: socketReadyAt.timeIntervalSince(socketStartedAt) * 1_000,
            micMs: micMuted ? 0 : readyAt.timeIntervalSince(socketReadyAt) * 1_000,
            totalMs: readyAt.timeIntervalSince(startedAt) * 1_000
        )
    }

    static func isSupportedWebSocketURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host else {
            return false
        }
        if scheme == "wss" { return true }
        return scheme == "ws" && LocalHost.isLocal(host)
    }

    private func startSession(configFrame: Data) async throws -> StartResponse {
        let token: String
        do {
            token = try await client.bearerToken()
        } catch let error as TokenSourceError {
            throw SessionStartFailure.credential(error)
        } catch {
            throw SessionStartFailure.transport(message: error.localizedDescription)
        }
        let request = Self.startRequest(
            url: client.baseURL.appending(
                path: "api/v1/external/realtime/session/ws-start"
            ),
            configFrame: configFrame,
            bearerToken: token
        )

        let session = makeRequestSession()
        defer { session.finishTasksAndInvalidate() }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SessionStartFailure.transport(message: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SessionStartFailure.transport(message: "websocket start returned no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw SessionStartFailure.rejected(
                status: http.statusCode,
                code: rejectionCode(inBody: detail),
                detail: detail,
                retryAfterSeconds: retryAfterSeconds(
                    header: http.value(forHTTPHeaderField: "Retry-After")),
                rejection: SessionStartRejection.from(body: data)
            )
        }
        do {
            return try JSONDecoder().decode(StartResponse.self, from: data)
        } catch {
            throw SessionStartFailure.transport(
                message: "websocket start response decode failed: \(error.localizedDescription)"
            )
        }
    }

    static func startRequest(
        url: URL,
        configFrame: Data,
        bearerToken: String
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = configFrame
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(
            sdkIdentityHeaderValue,
            forHTTPHeaderField: "X-Cosmo-SDK"
        )
        return request
    }

    private func makeRequestSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = client.requestTimeout
        configuration.timeoutIntervalForResource = client.requestTimeout
        return makeSession(configuration: configuration)
    }

    private func makeWebSocketSession(for url: URL) -> URLSession {
        makeSession(configuration: .default, host: url.host)
    }

    private func makeSession(
        configuration: URLSessionConfiguration,
        host: String? = nil
    ) -> URLSession {
        return makeRESTSession(
            configuration: configuration,
            verifyTLS: client.verifyTLS,
            host: host ?? client.baseURL.host
        )
    }

    private func decodeAudioFormat(
        _ message: WebSocketMessage
    ) throws -> AudioFormat {
        let data: Data
        switch message {
        case .text(let text): data = Data(text.utf8)
        case .data:
            throw SessionStartFailure.transport(
                message: "websocket audio preamble was not text"
            )
        @unknown default:
            throw SessionStartFailure.transport(
                message: "websocket audio preamble was unknown"
            )
        }
        let format: AudioFormat
        do {
            format = try JSONDecoder().decode(AudioFormat.self, from: data)
        } catch {
            throw SessionStartFailure.transport(
                message: "websocket audio preamble was malformed"
            )
        }
        guard
            format.type == "ws-audio-format",
            format.inputSampleRate > 0,
            format.outputSampleRate > 0,
            format.channelCount == 1
        else {
            throw SessionStartFailure.transport(
                message: "websocket audio preamble has unsupported geometry"
            )
        }
        return format
    }

    private func readLoop() async {
        guard let connection, let callbacks else { return }
        do {
            while !Task.isCancelled {
                let message = try await connection.receive()
                switch message {
                case .data(let data):
                    await audio.play(data)
                case .text(let text):
                    await handleText(Data(text.utf8), callbacks: callbacks)
                }
            }
        } catch {
            await failConnection(endReason(for: error, connection: connection))
        }
    }

    private func endReason(
        for error: any Error,
        connection: any WebSocketConnection
    ) async -> RealtimeSession.CloseReason {
        let code = await connection.closeCode
        let reason = (await connection.closeReason)
            .flatMap { String(data: $0, encoding: .utf8) }
            .flatMap { $0.isEmpty ? nil : $0 }
        switch code {
        case .normalClosure, .goingAway, .noStatusReceived:
            return .serverEnded(reason: reason)
        case .invalid:
            return .transportError(message: error.localizedDescription)
        default:
            let detail = reason.map { ": \($0)" } ?? ""
            return .transportError(
                message: "websocket closed (\(code.rawValue))\(detail)"
            )
        }
    }

    private func handleText(
        _ data: Data,
        callbacks: SessionTransportCallbacks
    ) async {
        guard let kind = try? JSONDecoder().decode(FrameKind.self, from: data) else {
            await callbacks.onFrame(data)
            return
        }
        switch kind.type {
        case "rpc-request":
            guard let request = try? JSONDecoder().decode(RPCRequest.self, from: data) else {
                return
            }
            let task: Task<Void, Never> = Task { [weak self] in
                guard let self else { return }
                await self.runRPC(request)
            }
            rpcRuns[request.requestId] = task
        case "rpc-cancel":
            guard let cancel = try? JSONDecoder().decode(RPCCancel.self, from: data) else {
                return
            }
            rpcRuns.removeValue(forKey: cancel.requestId)?.cancel()
        case "ws-audio-format":
            return
        case "turn-complete":
            // The socket lane has no dedicated interrupt frame. The server
            // publishes the assistant turn-complete after playout on a normal
            // turn (only a sub-threshold latency tail is left unplayed) and
            // immediately after clearing its own buffer on an interruption —
            // the large scheduled backlog is what the flush cuts.
            if let turn = try? JSONDecoder().decode(TurnCompleteEvent.self, from: data),
               turn.role == .assistant {
                await audio.flushPlayback()
            }
            await callbacks.onFrame(data)
        default:
            await callbacks.onFrame(data)
            // The socket has no participant model, so the server's `ready`
            // frame is this lane's agent-is-live signal, delivered after the
            // frame so its readiness handling runs first.
            if kind.type == "ready", !agentLiveSignaled {
                agentLiveSignaled = true
                await callbacks.onAgentLive()
            }
        }
    }

    private func runRPC(_ request: RPCRequest) async {
        defer { rpcRuns.removeValue(forKey: request.requestId) }
        guard let handler = toolHandlers[request.method] else {
            await sendRPC(
                requestId: request.requestId,
                payload: nil,
                error: "no handler for \(request.method)"
            )
            return
        }
        let payload = await invokeClientToolHandler(
            handler,
            tool: request.method,
            payload: request.payload,
            // Wire plumbing is not a tool call, so hooks skip it.
            hooks: hookExemptMethods.contains(request.method) ? nil : hooks,
            sessionId: sessionId
        )
        guard !Task.isCancelled else { return }
        await sendRPC(
            requestId: request.requestId,
            payload: payload,
            error: nil
        )
    }

    private func sendRPC(
        requestId: String,
        payload: String?,
        error: String?
    ) async {
        guard
            let connection,
            let data = try? JSONEncoder().encode(
                RPCResponse(
                    requestId: requestId,
                    payload: payload,
                    error: error
                )
            ),
            let text = String(data: data, encoding: .utf8)
        else { return }
        do {
            try await connection.send(.text(text))
        } catch {
            Self.log.warning(
                "RPC reply could not be sent: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func sendAudio(_ data: Data) async {
        guard let connection, !closing else { return }
        do {
            try await connection.send(.data(data))
        } catch {
            Self.log.error(
                "audio send failed: \(error.localizedDescription, privacy: .public)"
            )
            // A send racing the remote close fails before the read loop
            // observes it, so the close frame decides the reason here too.
            await failConnection(endReason(for: error, connection: connection))
        }
    }

    private func failConnection(_ reason: RealtimeSession.CloseReason) async {
        guard !closing, let callbacks else { return }
        await close()
        await callbacks.onClosed(reason)
    }
}
