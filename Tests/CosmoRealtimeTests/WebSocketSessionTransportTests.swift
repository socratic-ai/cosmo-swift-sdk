import AVFAudio
import Foundation
import Testing
import os
@testable import CosmoRealtime

private enum FakeWebSocketAudioError: Error {
    case prepare
}

private actor FakeWebSocketConnection: WebSocketConnection {
    private var inbound: [WebSocketMessage]
    private var waiter: CheckedContinuation<WebSocketMessage, Error>?
    private(set) var sent: [WebSocketMessage] = []
    private(set) var resumed = false
    private(set) var closed = false
    private(set) var closeCode: URLSessionWebSocketTask.CloseCode = .invalid
    private(set) var closeReason: Data?
    private var failed = false
    private var sendFailure: Error?

    init(_ inbound: [WebSocketMessage]) {
        self.inbound = inbound
    }

    nonisolated func resume() {
        Task { await self.markResumed() }
    }

    func receive() async throws -> WebSocketMessage {
        if !inbound.isEmpty { return inbound.removeFirst() }
        if failed { throw CancellationError() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func send(_ message: WebSocketMessage) async throws {
        if let sendFailure { throw sendFailure }
        sent.append(message)
    }

    nonisolated func close() {
        Task { await self.markClosed() }
    }

    func push(_ message: WebSocketMessage) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: message)
        } else {
            inbound.append(message)
        }
    }

    func fail() {
        failed = true
        waiter?.resume(throwing: CancellationError())
        waiter = nil
    }

    func closeFromServer(
        code: URLSessionWebSocketTask.CloseCode,
        reason: Data? = nil
    ) {
        closeCode = code
        closeReason = reason
        fail()
    }

    /// The remote close reaches an in-flight send before the parked read
    /// sees it: the close frame has landed, sends fail, receive is untouched.
    func closeFromServerDuringSend(code: URLSessionWebSocketTask.CloseCode) {
        closeCode = code
        sendFailure = CancellationError()
    }

    private func markResumed() {
        resumed = true
    }

    private func markClosed() {
        closed = true
        waiter?.resume(throwing: CancellationError())
        waiter = nil
    }
}

private actor FakeWebSocketAudio: WebSocketAudioHandling {
    private(set) var prepared: (input: Int, output: Int, microphone: Bool)?
    private(set) var microphoneStates: [Bool] = []
    private(set) var played: [Data] = []
    private(set) var playbackFlushes = 0
    private(set) var volume: Double?
    private(set) var closed = false
    private var sendAudio: (@Sendable (Data) -> Void)?
    private let prepareError: Error?

    init(failPrepare: Bool = false, prepareError: Error? = nil) {
        self.prepareError = prepareError ?? (failPrepare ? FakeWebSocketAudioError.prepare : nil)
    }

    func prepare(
        inputSampleRate: Int,
        outputSampleRate: Int,
        microphoneEnabled: Bool,
        sendAudio: @escaping @Sendable (Data) -> Void
    ) throws {
        if let prepareError { throw prepareError }
        prepared = (inputSampleRate, outputSampleRate, microphoneEnabled)
        self.sendAudio = sendAudio
    }

    func setMicrophoneEnabled(_ enabled: Bool) {
        microphoneStates.append(enabled)
    }

    func play(_ data: Data) {
        played.append(data)
    }

    func flushPlayback() {
        playbackFlushes += 1
    }

    func setVolume(_ volume: Double) {
        self.volume = volume
    }

    func close() {
        closed = true
    }

    func capture(_ data: Data) {
        sendAudio?(data)
    }
}

private actor WebSocketCallbackRecorder {
    private(set) var frames: [Data] = []
    private(set) var closes: [RealtimeSession.CloseReason] = []
    private(set) var agentLiveSignals = 0

    func callbacks() -> SessionTransportCallbacks {
        SessionTransportCallbacks(
            onFrame: { [weak self] data in await self?.record(data) },
            onClosed: { [weak self] reason in await self?.record(reason) },
            onReconnecting: {},
            onReconnected: {},
            onAgentLive: { [weak self] in await self?.recordAgentLive() }
        )
    }

    private func record(_ data: Data) {
        frames.append(data)
    }

    private func record(_ reason: RealtimeSession.CloseReason) {
        closes.append(reason)
    }

    private func recordAgentLive() {
        agentLiveSignals += 1
    }
}

@Suite("WebSocket session transport")
struct WebSocketSessionTransportTests {
    private let preamble = WebSocketMessage.text(
        #"{"type":"ws-audio-format","input_sample_rate_hz":16000,"output_sample_rate_hz":24000,"num_channels":1}"#
    )

    @Test("client stores the websocket transport selection")
    func clientSelection() {
        let client = RealtimeClient(
            apiKey: "test-key",
            transport: .websocket
        )
        #expect(client.sessionTransport == .websocket)
    }

    @Test("WebRTC is the default transport name")
    func defaultTransportName() {
        let client = RealtimeClient(apiKey: "test-key")
        #expect(client.sessionTransport == .webrtc)
    }

    @Test("usage fails locally without making a managed REST request")
    func usageUnsupported() async {
        let client = RealtimeClient(
            apiKey: "test-key",
            transport: .websocket
        )
        await #expect(throws: UsageError.self) {
            _ = try await client.sessionUsage(sessionId: "session-1")
        }
    }

    @Test("connect waits for the audio preamble and forwards external frames")
    func connectAndForward() async throws {
        let connection = FakeWebSocketConnection([preamble])
        let audio = FakeWebSocketAudio()
        let recorder = WebSocketCallbackRecorder()
        let transport = makeTransport(connection: connection, audio: audio)

        let info = try await transport.connect(
            configFrame: Data(#"{"type":"session-config"}"#.utf8),
            callbacks: await recorder.callbacks(),
            clientToolHandlers: [:],
            backgroundClientToolHandlers: [:],
            clientToolJobSink: nil,
            hooks: nil,
            hookExemptMethods: [],
            micMuted: true
        )
        #expect(info.sessionId == "session-1")
        let prepared = await audio.prepared
        #expect(prepared?.input == 16_000)
        #expect(prepared?.output == 24_000)
        #expect(prepared?.microphone == false)

        let ready = Data(#"{"type":"ready","session_id":"session-1"}"#.utf8)
        await connection.push(.text(String(decoding: ready, as: UTF8.self)))
        await eventually { await recorder.frames == [ready] }

        try await transport.send(frame: Data(#"{"type":"ping"}"#.utf8))
        let sent = await connection.sent
        #expect(sent.contains { message in
            if case .text(#"{"type":"ping"}"#) = message { return true }
            return false
        })
        await transport.close()
    }

    @Test("the first ready frame signals agent liveness exactly once")
    func readySignalsAgentLive() async throws {
        let connection = FakeWebSocketConnection([preamble])
        let recorder = WebSocketCallbackRecorder()
        let transport = makeTransport(
            connection: connection,
            audio: FakeWebSocketAudio()
        )
        _ = try await transport.connect(
            configFrame: Data(#"{"type":"session-config"}"#.utf8),
            callbacks: await recorder.callbacks(),
            clientToolHandlers: [:],
            backgroundClientToolHandlers: [:],
            clientToolJobSink: nil,
            hooks: nil,
            hookExemptMethods: [],
            micMuted: true
        )
        #expect(await recorder.agentLiveSignals == 0)

        let ready = #"{"type":"ready","session_id":"session-1"}"#
        await connection.push(.text(ready))
        await eventually { await recorder.agentLiveSignals == 1 }
        #expect(await recorder.frames.count == 1)

        await connection.push(.text(ready))
        await eventually { await recorder.frames.count == 2 }
        #expect(await recorder.agentLiveSignals == 1)
        await transport.close()
    }

    @Test("binary frames play and ordinary client tools reply over socket RPC")
    func audioAndRPC() async throws {
        let connection = FakeWebSocketConnection([preamble])
        let audio = FakeWebSocketAudio()
        let recorder = WebSocketCallbackRecorder()
        let transport = makeTransport(connection: connection, audio: audio)
        let handler: ClientToolHandler = { args in
            ["echo": args["value"] ?? .null]
        }
        _ = try await transport.connect(
            configFrame: Data(#"{"type":"session-config"}"#.utf8),
            callbacks: await recorder.callbacks(),
            clientToolHandlers: ["echo": handler],
            backgroundClientToolHandlers: [:],
            clientToolJobSink: nil,
            hooks: nil,
            hookExemptMethods: [],
            micMuted: true
        )

        let pcm = Data([0, 1, 2, 3])
        await connection.push(.data(pcm))
        await connection.push(.text(
            #"{"type":"rpc-request","request_id":"r1","method":"echo","payload":"{\"value\":\"ok\"}"}"#
        ))
        await eventually { await audio.played == [pcm] }
        await eventually { await !connection.sent.isEmpty }
        let sent = await connection.sent
        let responseText = try #require(sent.compactMap { message -> String? in
            guard case .text(let text) = message else { return nil }
            return text
        }.last)
        let response = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(responseText.utf8)
        )
        guard case .object(let fields) = response else {
            Issue.record("RPC response had the wrong envelope")
            return
        }
        guard case .string(let requestId)? = fields["request_id"], requestId == "r1" else {
            Issue.record("RPC response had the wrong request id")
            return
        }
        guard case .string(let payload)? = fields["payload"] else {
            Issue.record("RPC response had no payload")
            return
        }
        let reply = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(payload.utf8)
        )
        #expect(reply == JSONValue.object([
            "ok": JSONValue.bool(true),
            "result": JSONValue.object(["echo": JSONValue.string("ok")]),
            "error": JSONValue.null
        ]))
        await transport.close()
    }

    @Test("assistant turn-complete flushes playback and still forwards the frame")
    func assistantTurnCompleteFlushesPlayback() async throws {
        let connection = FakeWebSocketConnection([preamble])
        let audio = FakeWebSocketAudio()
        let recorder = WebSocketCallbackRecorder()
        let transport = makeTransport(connection: connection, audio: audio)
        _ = try await transport.connect(
            configFrame: Data(#"{"type":"session-config"}"#.utf8),
            callbacks: await recorder.callbacks(),
            clientToolHandlers: [:],
            backgroundClientToolHandlers: [:],
            clientToolJobSink: nil,
            hooks: nil,
            hookExemptMethods: [],
            micMuted: true
        )

        let frame = Data(#"{"type":"turn-complete","role":"ASSISTANT"}"#.utf8)
        await connection.push(.text(String(decoding: frame, as: UTF8.self)))
        await eventually { await audio.playbackFlushes == 1 }
        await eventually { await recorder.frames == [frame] }
        await transport.close()
    }

    @Test("user turn-complete forwards without flushing playback")
    func userTurnCompleteDoesNotFlushPlayback() async throws {
        let connection = FakeWebSocketConnection([preamble])
        let audio = FakeWebSocketAudio()
        let recorder = WebSocketCallbackRecorder()
        let transport = makeTransport(connection: connection, audio: audio)
        _ = try await transport.connect(
            configFrame: Data(#"{"type":"session-config"}"#.utf8),
            callbacks: await recorder.callbacks(),
            clientToolHandlers: [:],
            backgroundClientToolHandlers: [:],
            clientToolJobSink: nil,
            hooks: nil,
            hookExemptMethods: [],
            micMuted: true
        )

        let frame = Data(#"{"type":"turn-complete","role":"USER"}"#.utf8)
        await connection.push(.text(String(decoding: frame, as: UTF8.self)))
        await eventually { await recorder.frames == [frame] }
        #expect(await audio.playbackFlushes == 0)
        await transport.close()
    }

    @Test("malformed preamble fails the start")
    func malformedPreamble() async {
        let connection = FakeWebSocketConnection([
            .text(#"{"type":"ready","session_id":"session-1"}"#)
        ])
        let audio = FakeWebSocketAudio()
        let transport = makeTransport(
            connection: connection,
            audio: audio
        )
        await #expect(throws: SessionStartFailure.self) {
            _ = try await transport.connect(
                configFrame: Data(#"{"type":"session-config"}"#.utf8),
                callbacks: await WebSocketCallbackRecorder().callbacks(),
                clientToolHandlers: [:],
                backgroundClientToolHandlers: [:],
                clientToolJobSink: nil,
                hooks: nil,
                hookExemptMethods: [],
                micMuted: true
            )
        }
        await eventually {
            let connectionClosed = await connection.closed
            let audioClosed = await audio.closed
            return connectionClosed && audioClosed
        }
    }

    @Test("remote websocket endpoints require wss")
    func websocketEndpointTrust() async {
        #expect(WebSocketSessionTransport.isSupportedWebSocketURL(
            URL(string: "ws://localhost:8080/connect")!
        ))
        #expect(WebSocketSessionTransport.isSupportedWebSocketURL(
            URL(string: "wss://127.0.0.1:8080/connect")!
        ))
        #expect(WebSocketSessionTransport.isSupportedWebSocketURL(
            URL(string: "ws://[::1]:8080/connect")!
        ))
        #expect(WebSocketSessionTransport.isSupportedWebSocketURL(
            URL(string: "wss://remote.example/connect")!
        ))
        #expect(!WebSocketSessionTransport.isSupportedWebSocketURL(
            URL(string: "ws://remote.example/connect")!
        ))
        #expect(!WebSocketSessionTransport.isSupportedWebSocketURL(
            URL(string: "http://localhost:8080/connect")!
        ))

        let connection = FakeWebSocketConnection([preamble])
        let transport = makeTransport(
            connection: connection,
            audio: FakeWebSocketAudio(),
            websocketURL: URL(string: "ws://remote.example/connect")!
        )
        await #expect(throws: SessionStartFailure.self) {
            _ = try await transport.connect(
                configFrame: Data(#"{"type":"session-config"}"#.utf8),
                callbacks: await WebSocketCallbackRecorder().callbacks(),
                clientToolHandlers: [:],
                backgroundClientToolHandlers: [:],
                clientToolJobSink: nil,
                hooks: nil,
                hookExemptMethods: [],
                micMuted: true
            )
        }
        #expect(await !connection.resumed)
    }

    @Test("an audio failure at start survives the transport boundary")
    func audioFailureSurvivesTheBoundary() async {
        // The WebRTC carrier reports a capture failure as
        // `.captureUnavailable`, which the session re-raises as
        // `AudioUnavailableError`. A bare catch here flattened every audio
        // failure to `.transport`, so the same failure had a different type
        // depending on which carrier the caller picked.
        let audio = FakeWebSocketAudio(
            prepareError: AudioUnavailableError(
                message: "no usable microphone input format", code: .micNotFound))
        let transport = makeTransport(
            connection: FakeWebSocketConnection([preamble]), audio: audio)

        await #expect {
            _ = try await transport.connect(
                configFrame: Data(#"{"type":"session-config"}"#.utf8),
                callbacks: await WebSocketCallbackRecorder().callbacks(),
                clientToolHandlers: [:],
                backgroundClientToolHandlers: [:],
                clientToolJobSink: nil,
                hooks: nil,
                hookExemptMethods: [],
                micMuted: false
            )
        } throws: { error in
            guard case SessionStartFailure.captureUnavailable(let code, _) = error else {
                return false
            }
            return code == .micNotFound
        }
    }

    @Test("audio prepare failure closes opened resources")
    func audioPrepareFailureClosesResources() async {
        let connection = FakeWebSocketConnection([preamble])
        let audio = FakeWebSocketAudio(failPrepare: true)
        let transport = makeTransport(connection: connection, audio: audio)

        // Asserts the arm, not just the type: the audio-failure catch added
        // above this one must not shadow the general wrap, or an engine or
        // AVAudioSession error would leave `connect()` raw and un-coded.
        await #expect {
            _ = try await transport.connect(
                configFrame: Data(#"{"type":"session-config"}"#.utf8),
                callbacks: await WebSocketCallbackRecorder().callbacks(),
                clientToolHandlers: [:],
                backgroundClientToolHandlers: [:],
                clientToolJobSink: nil,
                hooks: nil,
                hookExemptMethods: [],
                micMuted: false
            )
        } throws: { error in
            guard case SessionStartFailure.transport = error else { return false }
            return true
        }
        await eventually {
            let connectionClosed = await connection.closed
            let audioClosed = await audio.closed
            return connectionClosed && audioClosed
        }
    }

    @Test("connect timeout bounds the websocket preamble")
    func connectTimeout() async {
        let connection = FakeWebSocketConnection([])
        let transport = makeTransport(
            connection: connection,
            audio: FakeWebSocketAudio(),
            connectTimeout: 0.01
        )
        await #expect(throws: SessionStartFailure.self) {
            _ = try await transport.connect(
                configFrame: Data(#"{"type":"session-config"}"#.utf8),
                callbacks: await WebSocketCallbackRecorder().callbacks(),
                clientToolHandlers: [:],
                backgroundClientToolHandlers: [:],
                clientToolJobSink: nil,
                hooks: nil,
                hookExemptMethods: [],
                micMuted: true
            )
        }
        await eventually { await connection.closed }
    }

    @Test("live websocket does not inherit the REST resource timeout")
    func websocketResourceTimeout() async throws {
        let resourceTimeout = OSAllocatedUnfairLock<TimeInterval?>(initialState: nil)
        let connection = FakeWebSocketConnection([preamble])
        let transport = makeTransport(
            connection: connection,
            audio: FakeWebSocketAudio(),
            requestTimeout: 0.01,
            onSession: { session in
                resourceTimeout.withLock {
                    $0 = session.configuration.timeoutIntervalForResource
                }
            }
        )
        _ = try await transport.connect(
            configFrame: Data(#"{"type":"session-config"}"#.utf8),
            callbacks: await WebSocketCallbackRecorder().callbacks(),
            clientToolHandlers: [:],
            backgroundClientToolHandlers: [:],
            clientToolJobSink: nil,
            hooks: nil,
            hookExemptMethods: [],
            micMuted: true
        )
        let actual = try #require(resourceTimeout.withLock { $0 })
        #expect(actual > 0.01)
        await transport.close()
    }

    @Test("outbound microphone buffers keep capture order")
    func orderedMicrophoneBuffers() async throws {
        let connection = FakeWebSocketConnection([preamble])
        let audio = FakeWebSocketAudio()
        let transport = makeTransport(connection: connection, audio: audio)
        _ = try await transport.connect(
            configFrame: Data(#"{"type":"session-config"}"#.utf8),
            callbacks: await WebSocketCallbackRecorder().callbacks(),
            clientToolHandlers: [:],
            backgroundClientToolHandlers: [:],
            clientToolJobSink: nil,
            hooks: nil,
            hookExemptMethods: [],
            micMuted: false
        )
        let first = Data([1, 2])
        let second = Data([3, 4])
        await audio.capture(first)
        await audio.capture(second)
        await eventually {
            await connection.sent.compactMap { message -> Data? in
                guard case .data(let data) = message else { return nil }
                return data
            } == [first, second]
        }
        await transport.close()
    }

    @Test("stopping caller audio restores the displaced microphone locally")
    func stopAudioStreamRestoresMicrophone() async throws {
        let connection = FakeWebSocketConnection([preamble])
        let audio = FakeWebSocketAudio()
        let transport = makeTransport(connection: connection, audio: audio)
        _ = try await transport.connect(
            configFrame: Data(#"{"type":"session-config"}"#.utf8),
            callbacks: await WebSocketCallbackRecorder().callbacks(),
            clientToolHandlers: [:],
            backgroundClientToolHandlers: [:],
            clientToolJobSink: nil,
            hooks: nil,
            hookExemptMethods: [],
            micMuted: false
        )

        try await transport.startAudioStream()
        let restored = await transport.stopAudioStream()

        #expect(restored)
        #expect(await audio.microphoneStates == [false, true])
        await transport.close()
    }

    @Test("outbound audio queue is bounded and keeps the newest buffers")
    func boundedAudioQueue() async {
        let queue = WebSocketAudioSendQueue(capacity: 2)
        let generation = WebSocketAudioGeneration()
        queue.enqueue(generation.packet(Data([1])))
        queue.enqueue(generation.packet(Data([2])))
        queue.enqueue(generation.packet(Data([3])))
        queue.finish()
        var values: [Data] = []
        for await value in queue.stream { values.append(value.data) }
        #expect(values == [Data([2]), Data([3])])
    }

    @Test("audio ownership changes invalidate queued buffers")
    func audioGeneration() {
        let generation = WebSocketAudioGeneration()
        let microphone = generation.packet(Data([1]))
        generation.advance()
        let caller = generation.packet(Data([2]))

        #expect(!generation.contains(microphone))
        #expect(generation.contains(caller))
    }

    @Test("connection failure closes transport resources before the callback")
    func failureClosesBeforeCallback() async throws {
        let connection = FakeWebSocketConnection([preamble])
        let audio = FakeWebSocketAudio()
        let closedBeforeCallback = OSAllocatedUnfairLock<Bool>(initialState: false)
        let callbacks = SessionTransportCallbacks(
            onFrame: { _ in },
            onClosed: { _ in
                let closed = await audio.closed
                closedBeforeCallback.withLock { $0 = closed }
            },
            onReconnecting: {},
            onReconnected: {},
            onAgentLive: {}
        )
        let transport = makeTransport(connection: connection, audio: audio)
        _ = try await transport.connect(
            configFrame: Data(#"{"type":"session-config"}"#.utf8),
            callbacks: callbacks,
            clientToolHandlers: [:],
            backgroundClientToolHandlers: [:],
            clientToolJobSink: nil,
            hooks: nil,
            hookExemptMethods: [],
            micMuted: true
        )

        await connection.fail()

        await eventually { closedBeforeCallback.withLock { $0 } }
        #expect(closedBeforeCallback.withLock { $0 })
    }

    @Test(
        "a clean close reports a server end, not a transport error",
        arguments: [
            URLSessionWebSocketTask.CloseCode.normalClosure,
            .goingAway,
            .noStatusReceived,
        ]
    )
    func cleanCloseIsServerEnded(code: URLSessionWebSocketTask.CloseCode) async throws {
        let connection = FakeWebSocketConnection([preamble])
        let recorder = WebSocketCallbackRecorder()
        let transport = makeTransport(connection: connection, audio: FakeWebSocketAudio())
        _ = try await transport.connect(
            configFrame: Data(#"{"type":"session-config"}"#.utf8),
            callbacks: await recorder.callbacks(),
            clientToolHandlers: [:],
            backgroundClientToolHandlers: [:],
            clientToolJobSink: nil,
            hooks: nil,
            hookExemptMethods: [],
            micMuted: true
        )

        await connection.closeFromServer(code: code)

        await eventually { await !recorder.closes.isEmpty }
        #expect(await recorder.closes == [.serverEnded(reason: nil)])
    }

    @Test("a clean close that fails an in-flight send is still a server end")
    func cleanCloseRacingASendIsServerEnded() async throws {
        let connection = FakeWebSocketConnection([preamble])
        let audio = FakeWebSocketAudio()
        let recorder = WebSocketCallbackRecorder()
        let transport = makeTransport(connection: connection, audio: audio)
        _ = try await transport.connect(
            configFrame: Data(#"{"type":"session-config"}"#.utf8),
            callbacks: await recorder.callbacks(),
            clientToolHandlers: [:],
            backgroundClientToolHandlers: [:],
            clientToolJobSink: nil,
            hooks: nil,
            hookExemptMethods: [],
            micMuted: false
        )

        await connection.closeFromServerDuringSend(code: .normalClosure)
        await audio.capture(Data([1, 2]))

        await eventually { await !recorder.closes.isEmpty }
        #expect(await recorder.closes == [.serverEnded(reason: nil)])
    }

    @Test("a policy-violation close surfaces the code and reason as a transport error")
    func policyViolationIsTransportError() async throws {
        let connection = FakeWebSocketConnection([preamble])
        let recorder = WebSocketCallbackRecorder()
        let transport = makeTransport(connection: connection, audio: FakeWebSocketAudio())
        _ = try await transport.connect(
            configFrame: Data(#"{"type":"session-config"}"#.utf8),
            callbacks: await recorder.callbacks(),
            clientToolHandlers: [:],
            backgroundClientToolHandlers: [:],
            clientToolJobSink: nil,
            hooks: nil,
            hookExemptMethods: [],
            micMuted: true
        )

        await connection.closeFromServer(
            code: .policyViolation,
            reason: Data("origin refused".utf8)
        )

        await eventually { await !recorder.closes.isEmpty }
        let closes = await recorder.closes
        guard case .transportError(let message)? = closes.first else {
            Issue.record("expected a transport error, got \(closes)")
            return
        }
        #expect(message == "websocket closed (1008): origin refused")
    }

    @Test("a failure without a close frame stays a transport error")
    func failureWithoutCloseFrameIsTransportError() async throws {
        let connection = FakeWebSocketConnection([preamble])
        let recorder = WebSocketCallbackRecorder()
        let transport = makeTransport(connection: connection, audio: FakeWebSocketAudio())
        _ = try await transport.connect(
            configFrame: Data(#"{"type":"session-config"}"#.utf8),
            callbacks: await recorder.callbacks(),
            clientToolHandlers: [:],
            backgroundClientToolHandlers: [:],
            clientToolJobSink: nil,
            hooks: nil,
            hookExemptMethods: [],
            micMuted: true
        )

        await connection.fail()

        await eventually { await !recorder.closes.isEmpty }
        let closes = await recorder.closes
        guard case .transportError? = closes.first else {
            Issue.record("expected a transport error, got \(closes)")
            return
        }
    }

    @Test("connect timings keep REST, socket, and microphone phases separate")
    func connectTimingPhases() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let rest = Date(timeIntervalSinceReferenceDate: 1)
        let socketStart = Date(timeIntervalSinceReferenceDate: 1.5)
        let socketReady = Date(timeIntervalSinceReferenceDate: 3)
        let ready = Date(timeIntervalSinceReferenceDate: 5)

        let unmuted = WebSocketSessionTransport.connectPhases(
            startedAt: start,
            restReadyAt: rest,
            socketStartedAt: socketStart,
            socketReadyAt: socketReady,
            readyAt: ready,
            micMuted: false
        )
        #expect(unmuted.wsMs == 1_000)
        #expect(unmuted.roomMs == 1_500)
        #expect(unmuted.micMs == 2_000)
        #expect(unmuted.totalMs == 5_000)

        let muted = WebSocketSessionTransport.connectPhases(
            startedAt: start,
            restReadyAt: rest,
            socketStartedAt: socketStart,
            socketReadyAt: socketReady,
            readyAt: ready,
            micMuted: true
        )
        #expect(muted.micMs == 0)
    }

    @Test("start response decodes the optional server timings")
    func startResponseTimingsDecode() throws {
        let with = try JSONDecoder().decode(
            WebSocketSessionTransport.StartResponse.self,
            from: Data(#"""
            {"session_id":"session-1",
             "ws_url":"ws://localhost:8080/connect",
             "ws_subprotocol":"one-time-capability",
             "timings":{"version_check_ms":1,"project_check_ms":2,
                        "provider_resolve_ms":3,"db_insert_ms":4,
                        "mint_tokens_ms":5,"dispatch_ms":6,"total_ms":7}}
            """#.utf8)
        )
        #expect(with.timings?.versionCheckMs == 1)
        #expect(with.timings?.dispatchMs == 6)
        #expect(with.timings?.totalMs == 7)
        #expect(with.timings?.resolveMs == nil)

        let without = try JSONDecoder().decode(
            WebSocketSessionTransport.StartResponse.self,
            from: Data(#"""
            {"session_id":"session-1",
             "ws_url":"ws://localhost:8080/connect",
             "ws_subprotocol":"one-time-capability"}
            """#.utf8)
        )
        #expect(without.timings == nil)
    }

    @Test("connect records the handshake origin and the server breakdown")
    func connectRecordsOriginAndServerTimings() async throws {
        let connection = FakeWebSocketConnection([preamble])
        let transport = makeTransport(
            connection: connection,
            audio: FakeWebSocketAudio(),
            timings: RealtimeSessionStartTimings(
                dbInsertMs: 4,
                dispatchMs: 6,
                mintTokensMs: 5,
                projectCheckMs: 2,
                providerResolveMs: 3,
                totalMs: 7,
                versionCheckMs: 1
            )
        )
        let before = Date()
        _ = try await transport.connect(
            configFrame: Data(#"{"type":"session-config"}"#.utf8),
            callbacks: await WebSocketCallbackRecorder().callbacks(),
            clientToolHandlers: [:],
            backgroundClientToolHandlers: [:],
            clientToolJobSink: nil,
            hooks: nil,
            hookExemptMethods: [],
            micMuted: true
        )

        let connected = transport.connectTimings
        #expect(connected.serverTimings?.totalMs == 7)
        #expect(connected.serverTimings?.versionCheckMs == 1)
        #expect(connected.readyMs == nil)

        transport.timings.markReady(at: before.addingTimeInterval(5))
        let marked = try #require(transport.connectTimings.readyMs)
        #expect(marked > 0)
        #expect(marked <= 5_000)
        await transport.close()
    }

    @Test("server timings stay nil when the start response carries none")
    func connectWithoutServerTimings() async throws {
        let connection = FakeWebSocketConnection([preamble])
        let transport = makeTransport(connection: connection, audio: FakeWebSocketAudio())
        _ = try await transport.connect(
            configFrame: Data(#"{"type":"session-config"}"#.utf8),
            callbacks: await WebSocketCallbackRecorder().callbacks(),
            clientToolHandlers: [:],
            backgroundClientToolHandlers: [:],
            clientToolJobSink: nil,
            hooks: nil,
            hookExemptMethods: [],
            micMuted: true
        )

        #expect(transport.connectTimings.serverTimings == nil)
        await transport.close()
    }

    @Test("playback volume applies the newest queued value")
    func newestPlaybackVolume() async throws {
        let connection = FakeWebSocketConnection([preamble])
        let audio = FakeWebSocketAudio()
        let transport = makeTransport(connection: connection, audio: audio)
        transport.setAgentPlaybackVolume(0.2)
        transport.setAgentPlaybackVolume(0.8)

        _ = try await transport.connect(
            configFrame: Data(#"{"type":"session-config"}"#.utf8),
            callbacks: await WebSocketCallbackRecorder().callbacks(),
            clientToolHandlers: [:],
            backgroundClientToolHandlers: [:],
            clientToolJobSink: nil,
            hooks: nil,
            hookExemptMethods: [],
            micMuted: true
        )

        await eventually { await audio.volume == 0.8 }
        #expect(await audio.volume == 0.8)
        await transport.close()
    }

    @Test("background tools fail before the start request")
    func backgroundToolsFailBeforeStart() async {
        let starts = OSAllocatedUnfairLock<Int>(initialState: 0)
        let connection = FakeWebSocketConnection([preamble])
        let transport = makeTransport(
            connection: connection,
            audio: FakeWebSocketAudio(),
            onStart: { starts.withLock { $0 += 1 } }
        )
        let background: BackgroundClientToolHandler = { _, _ in }
        await #expect(throws: SessionStartFailure.self) {
            _ = try await transport.connect(
                configFrame: Data(#"{"type":"session-config"}"#.utf8),
                callbacks: await WebSocketCallbackRecorder().callbacks(),
                clientToolHandlers: [:],
                backgroundClientToolHandlers: ["slow": background],
                clientToolJobSink: nil,
                hooks: nil,
                hookExemptMethods: [],
                micMuted: true
            )
        }
        #expect(starts.withLock { $0 } == 0)
    }

    @Test("screen share refuses with video_unsupported")
    func screenShareRefused() async {
        let transport = makeTransport(
            connection: FakeWebSocketConnection([preamble]),
            audio: FakeWebSocketAudio()
        )
        await #expect {
            try await transport.startScreenShare()
        } throws: { error in
            guard case SessionStartFailure.unsupportedCapability(let code, _) = error else {
                return false
            }
            return code == "video_unsupported"
        }
    }

    @Test("video streams refuse with video_unsupported")
    func videoStreamRefused() async {
        let transport = makeTransport(
            connection: FakeWebSocketConnection([preamble]),
            audio: FakeWebSocketAudio()
        )
        await #expect {
            _ = try await transport.addVideoStream()
        } throws: { error in
            guard case SessionStartFailure.unsupportedCapability(let code, _) = error else {
                return false
            }
            return code == "video_unsupported"
        }
    }

    @Test("session surfaces the socket video refusal as a public error")
    func videoRefusalSurfacesPublicly() async {
        let transport = makeTransport(
            connection: FakeWebSocketConnection([preamble]),
            audio: FakeWebSocketAudio()
        )
        let session = RealtimeSession(transport: transport)
        // The slug is machine-readable on `serverCode`, not spelled into the
        // message — the same shape Python and TypeScript refuse video with.
        let refusal = SessionStartError(
            code: .config,
            message: "video and screen share are not supported by the websocket transport",
            serverCode: "video_unsupported"
        )
        await #expect(throws: refusal) {
            try await session.startScreenShare()
        }
        await #expect(throws: refusal) {
            _ = try await session.addVideoStream()
        }
    }

    @Test("fire-and-forget video calls stay inert on the socket")
    func fireAndForgetVideoCallsAreInert() async throws {
        let connection = FakeWebSocketConnection([preamble])
        let transport = makeTransport(
            connection: connection,
            audio: FakeWebSocketAudio()
        )
        _ = try await transport.connect(
            configFrame: Data(#"{"type":"session-config"}"#.utf8),
            callbacks: await WebSocketCallbackRecorder().callbacks(),
            clientToolHandlers: [:],
            backgroundClientToolHandlers: [:],
            clientToolJobSink: nil,
            hooks: nil,
            hookExemptMethods: [],
            micMuted: true
        )

        await transport.stopScreenShare()
        transport.setScreenShareFrameProcessor { buffer in buffer }
        transport.setScreenShareFrameProcessor(nil)
        await transport.removeVideoStream(
            VideoStreamHandle(streamID: UUID()) { _ in }
        )

        #expect(await connection.sent.isEmpty)
        #expect(await !connection.closed)
        await transport.close()
    }

    @Test("websocket start carries bearer and SDK identity headers")
    func startRequestHeaders() {
        let body = Data(#"{"type":"session-config"}"#.utf8)
        let request = WebSocketSessionTransport.startRequest(
            url: URL(string: "http://localhost:8080/api/v1/external/realtime/session/ws-start")!,
            configFrame: body,
            bearerToken: "local-key"
        )

        #expect(request.httpMethod == "POST")
        #expect(request.httpBody == body)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer local-key")
        #expect(
            request.value(forHTTPHeaderField: "X-Cosmo-SDK")
                == sdkIdentityHeaderValue
        )
    }

    @Test("caller PCM is converted to the server rate")
    func pcmConversion() throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 480
        ))
        buffer.frameLength = 480
        let channel = try #require(buffer.floatChannelData?[0])
        for index in 0..<480 {
            channel[index] = sin(Float(index) / 10)
        }

        let data = try WebSocketAudio.pcm16Data(from: buffer, sampleRate: 16_000)
        #expect(data.count >= 318 && data.count <= 322)
        #expect(data.contains { $0 != 0 })
    }

    @Test("reusable microphone conversion remains open across buffers")
    func streamingPCMConversion() throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let buffers = try (0..<2).map { offset in
            let buffer = try #require(AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: 480
            ))
            buffer.frameLength = 480
            let channel = try #require(buffer.floatChannelData?[0])
            for index in 0..<480 {
                channel[index] = sin(Float(index + offset * 480) / 10)
            }
            return buffer
        }

        let chunks = try WebSocketAudio.streamingPCM16Data(
            from: buffers,
            sampleRate: 16_000
        )
        #expect(chunks.count == 2)
        #expect(chunks.allSatisfy { !$0.isEmpty })
    }

    @Test("microphone activation restores output after a failed start")
    func microphoneActivationRollback() {
        enum Failure: Error { case start }
        let events = OSAllocatedUnfairLock<[String]>(initialState: [])
        let starts = OSAllocatedUnfairLock<Int>(initialState: 0)

        #expect(throws: Failure.self) {
            try WebSocketAudio.activateMicrophone(
                stopEngine: { events.withLock { $0.append("stop") } },
                installTap: { events.withLock { $0.append("install") } },
                startEngine: {
                    events.withLock { $0.append("start") }
                    let attempt = starts.withLock {
                        $0 += 1
                        return $0
                    }
                    if attempt == 1 { throw Failure.start }
                },
                removeTap: { events.withLock { $0.append("remove") } },
                disableVoiceProcessing: { events.withLock { $0.append("processing=false") } }
            )
        }
        #expect(
            events.withLock { $0 }
                == ["stop", "install", "start", "remove", "processing=false", "start"]
        )
    }

    @Test("a microphone that never captured leaves no voice processing engaged")
    func microphoneActivationDisablesProcessingOnTapFailure() {
        enum Failure: Error { case install }
        let events = OSAllocatedUnfairLock<[String]>(initialState: [])

        #expect(throws: Failure.self) {
            try WebSocketAudio.activateMicrophone(
                stopEngine: { events.withLock { $0.append("stop") } },
                installTap: {
                    // The tap engages voice processing before the format and
                    // converter steps that can fail.
                    events.withLock { $0.append("processing=true") }
                    throw Failure.install
                },
                startEngine: { events.withLock { $0.append("start") } },
                removeTap: { events.withLock { $0.append("remove") } },
                disableVoiceProcessing: { events.withLock { $0.append("processing=false") } }
            )
        }
        #expect(
            events.withLock { $0 }
                == ["stop", "processing=true", "processing=false", "start"]
        )
    }

    @Test("a disable failure in the rollback still restores output")
    func microphoneActivationRollbackSurvivesADisableFailure() {
        enum Failure: Error { case install, disable }
        let events = OSAllocatedUnfairLock<[String]>(initialState: [])

        #expect(throws: Failure.self) {
            try WebSocketAudio.activateMicrophone(
                stopEngine: { events.withLock { $0.append("stop") } },
                installTap: { throw Failure.install },
                startEngine: { events.withLock { $0.append("start") } },
                removeTap: { events.withLock { $0.append("remove") } },
                disableVoiceProcessing: { throw Failure.disable }
            )
        }
        #expect(events.withLock { $0 } == ["stop", "start"])
    }

    @Test("voice processing enables the canceller once, then disables AGC and ducking", arguments: [
        (false, ["processing=true", "agc=false", "ducking"]),
        (true, ["agc=false", "ducking"]),
    ])
    func voiceProcessingConfiguration(isEnabled: Bool, expected: [String]) throws {
        let events = OSAllocatedUnfairLock<[String]>(initialState: [])
        try WebSocketAudio.configureVoiceProcessing(
            isEnabled: isEnabled,
            setEnabled: { enabled in events.withLock { $0.append("processing=\(enabled)") } },
            setAGCEnabled: { enabled in events.withLock { $0.append("agc=\(enabled)") } },
            minimizeOtherAudioDucking: { events.withLock { $0.append("ducking") } }
        )
        #expect(events.withLock { $0 } == expected)
    }

    @Test("voice processing enable failure propagates before any policy applies")
    func voiceProcessingConfigurationFailure() {
        enum Failure: Error { case enable }
        let events = OSAllocatedUnfairLock<[String]>(initialState: [])
        #expect(throws: Failure.self) {
            try WebSocketAudio.configureVoiceProcessing(
                isEnabled: false,
                setEnabled: { _ in throw Failure.enable },
                setAGCEnabled: { enabled in events.withLock { $0.append("agc=\(enabled)") } },
                minimizeOtherAudioDucking: { events.withLock { $0.append("ducking") } }
            )
        }
        #expect(events.withLock { $0 } == [])
    }

    @Test("disabling voice processing needs the stopped-engine window")
    func voiceProcessingDeactivation() throws {
        let events = OSAllocatedUnfairLock<[String]>(initialState: [])
        try WebSocketAudio.deactivateVoiceProcessing(
            isEnabled: true,
            stopEngine: { events.withLock { $0.append("stop") } },
            setEnabled: { enabled in events.withLock { $0.append("processing=\(enabled)") } },
            startEngine: { events.withLock { $0.append("start") } }
        )
        #expect(events.withLock { $0 } == ["stop", "processing=false", "start"])
    }

    @Test("nothing to disable still leaves the engine running")
    func voiceProcessingDeactivationRestartsAStoppedEngine() throws {
        let events = OSAllocatedUnfairLock<[String]>(initialState: [])
        // What a retry looks like: the previous attempt disabled processing
        // and then failed to restart, so this one has nothing to disable and
        // an engine that is still stopped.
        try WebSocketAudio.deactivateVoiceProcessing(
            isEnabled: false,
            stopEngine: { events.withLock { $0.append("stop") } },
            setEnabled: { enabled in events.withLock { $0.append("processing=\(enabled)") } },
            startEngine: { events.withLock { $0.append("start") } }
        )
        #expect(events.withLock { $0 } == ["start"])
    }

    @Test("a failed voice processing disable still restarts the engine")
    func voiceProcessingDeactivationDisableFailure() throws {
        enum Failure: Error { case disable }
        let events = OSAllocatedUnfairLock<[String]>(initialState: [])
        try WebSocketAudio.deactivateVoiceProcessing(
            isEnabled: true,
            stopEngine: { events.withLock { $0.append("stop") } },
            setEnabled: { _ in throw Failure.disable },
            startEngine: { events.withLock { $0.append("start") } }
        )
        #expect(events.withLock { $0 } == ["stop", "start"])
    }

    @Test("a failed engine restart after disabling voice processing propagates")
    func voiceProcessingDeactivationRestartFailure() {
        enum Failure: Error { case start }
        let disabled = OSAllocatedUnfairLock<Bool>(initialState: false)
        #expect(throws: Failure.self) {
            try WebSocketAudio.deactivateVoiceProcessing(
                isEnabled: true,
                stopEngine: {},
                setEnabled: { _ in disabled.withLock { $0 = true } },
                startEngine: { throw Failure.start }
            )
        }
        #expect(disabled.withLock { $0 })
    }

    @Test("playback flush requires a beyond-threshold unplayed backlog", arguments: [
        // 300 ms backlog at 24 kHz — the interruption case.
        (scheduled: Int64(7_200), played: Int64?.some(0), rate: 24_000.0, flushes: true),
        // Exactly the 100 ms threshold stays.
        (scheduled: Int64(2_400), played: .some(0), rate: 24_000.0, flushes: false),
        // A 50 ms turn tail mid-stream stays.
        (scheduled: Int64(50_000), played: .some(48_800), rate: 24_000.0, flushes: false),
        // The timeline overran the queue (silence between turns).
        (scheduled: Int64(2_400), played: .some(4_800), rate: 24_000.0, flushes: false),
        // Player stopped or timeline unavailable: backlog counts as zero.
        (scheduled: Int64(7_200), played: nil, rate: 24_000.0, flushes: false),
        // No output rate to convert with.
        (scheduled: Int64(7_200), played: .some(0), rate: 0.0, flushes: false),
    ] as [(scheduled: Int64, played: Int64?, rate: Double, flushes: Bool)])
    func playbackFlushThreshold(
        _ vector: (scheduled: Int64, played: Int64?, rate: Double, flushes: Bool)
    ) {
        #expect(
            WebSocketAudio.shouldFlushPlayback(
                scheduledFrames: vector.scheduled,
                playedFrames: vector.played,
                sampleRate: vector.rate
            ) == vector.flushes
        )
    }

    @Test("an app that owns the audio session keeps it untouched")
    func audioSessionLeftToItsOwner() throws {
        let events = OSAllocatedUnfairLock<[String]>(initialState: [])
        let activated = try WebSocketAudio.activateAudioSession(
            managed: false,
            setCategory: { events.withLock { $0.append("category") } },
            setActive: { events.withLock { $0.append("active") } }
        )
        #expect(activated == false)
        #expect(events.withLock { $0 } == [])
    }

    @Test("the SDK configures the session before activating it")
    func audioSessionConfiguredThenActivated() throws {
        let events = OSAllocatedUnfairLock<[String]>(initialState: [])
        let activated = try WebSocketAudio.activateAudioSession(
            managed: true,
            setCategory: { events.withLock { $0.append("category") } },
            setActive: { events.withLock { $0.append("active") } }
        )
        #expect(activated == true)
        #expect(events.withLock { $0 } == ["category", "active"])
    }

    @Test("a session that never went active is not reported as ours")
    func audioSessionActivationFailureIsNotOwned() {
        enum Failure: Error { case active }
        #expect(throws: Failure.self) {
            _ = try WebSocketAudio.activateAudioSession(
                managed: true,
                setCategory: {},
                setActive: { throw Failure.active }
            )
        }
    }

    @Test("PCM frames require complete 16-bit samples")
    func pcmFrameValidation() {
        #expect(!WebSocketAudio.isCompletePCM16Frame(Data()))
        #expect(!WebSocketAudio.isCompletePCM16Frame(Data([0])))
        #expect(WebSocketAudio.isCompletePCM16Frame(Data([0, 1])))
        #expect(!WebSocketAudio.isCompletePCM16Frame(Data([0, 1, 2])))
    }

    @Test("microphone levels measure raw float buffers")
    func microphoneLevel() throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 4
        ))
        buffer.frameLength = 4
        let samples = try #require(buffer.floatChannelData?[0])
        samples[0] = 0.5
        samples[1] = -0.5
        samples[2] = 0.5
        samples[3] = -0.5

        #expect(abs(WebSocketAudio.rms(buffer) - 0.5) < 0.0001)
    }

    private func makeTransport(
        connection: FakeWebSocketConnection,
        audio: FakeWebSocketAudio,
        connectTimeout: TimeInterval = 30,
        requestTimeout: TimeInterval = 45,
        websocketURL: URL = URL(string: "ws://localhost:8080/connect")!,
        timings: RealtimeSessionStartTimings? = nil,
        onStart: @escaping @Sendable () -> Void = {},
        onSession: @escaping @Sendable (URLSession) -> Void = { _ in }
    ) -> WebSocketSessionTransport {
        let client = RealtimeClient(
            apiKey: "test-key",
            baseURL: URL(string: "http://localhost:8080")!,
            connectTimeout: connectTimeout,
            requestTimeout: requestTimeout,
            transport: .websocket
        )
        return WebSocketSessionTransport(
            client: client,
            startOverride: { _ in
                onStart()
                return WebSocketSessionTransport.StartResponse(
                    sessionId: "session-1",
                    websocketURL: websocketURL,
                    subprotocolName: "one-time-capability",
                    timings: timings
                )
            },
            connectionFactory: { _, session in
                onSession(session)
                return connection
            },
            audioFactory: { _, _ in audio }
        )
    }

    private func eventually(
        _ predicate: @escaping @Sendable () async -> Bool
    ) async {
        for _ in 0..<100 {
            if await predicate() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("condition did not become true")
    }
}
