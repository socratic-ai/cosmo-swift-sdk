import CoreMedia
import Foundation
import os.lock
@testable import CosmoRealtime

// MARK: - Fake transport

/// In-memory ``SessionTransport``: records every frame the session
/// hands it (the serialized ``session-config`` plus all sends) and
/// lets the trace driver inject raw server frames through the same
/// ``onFrame`` path the LiveKit transport uses.
actor FakeSessionTransport: SessionTransport {
    private(set) var sent: [Data] = []
    private(set) var micEnabled: Bool?
    private(set) var connectedMicMuted: Bool?
    private(set) var registeredToolHandlers: [String: ClientToolHandler] = [:]
    private(set) var registeredBackgroundToolHandlers: [String: BackgroundClientToolHandler] = [:]
    private(set) var clientToolJobSink: ClientToolJobSink?
    private var callbacks: SessionTransportCallbacks?
    private var scriptedRejection: SessionStartFailure?
    private var scriptedMicError: Error?

    func scriptRejection(_ failure: SessionStartFailure) {
        scriptedRejection = failure
    }

    func scriptMicError(_ error: Error) {
        scriptedMicError = error
    }

    func connect(
        configFrame: Data,
        callbacks: SessionTransportCallbacks,
        clientToolHandlers: [String: ClientToolHandler],
        backgroundClientToolHandlers: [String: BackgroundClientToolHandler],
        clientToolJobSink: ClientToolJobSink?,
        hooks: HookEngine?,
        micMuted: Bool
    ) async throws -> SessionStartInfo {
        sent.append(configFrame)
        connectedMicMuted = micMuted
        if let scriptedRejection {
            throw scriptedRejection
        }
        self.callbacks = callbacks
        self.registeredToolHandlers = clientToolHandlers
        self.registeredBackgroundToolHandlers = backgroundClientToolHandlers
        self.clientToolJobSink = clientToolJobSink
        return SessionStartInfo(sessionId: "trace-session")
    }

    func send(frame: Data) async throws {
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

    func close() async {}

    // No contract trace exercises audio levels; an empty finished
    // stream satisfies the protocol and keeps the suite compiling.
    nonisolated let inputLevels: AsyncStream<Float> = AsyncStream { $0.finish() }
    nonisolated let outputLevels: AsyncStream<Float> = AsyncStream { $0.finish() }

    // No contract trace exercises screen share, so these stubs only
    // satisfy the protocol and keep the suite compiling.
    private(set) var screenShareStarted = false

    func startScreenShare() async throws { screenShareStarted = true }
    nonisolated func pushScreenShareFrame(_ sampleBuffer: CMSampleBuffer) {}
    func stopScreenShare() async { screenShareStarted = false }
    nonisolated func setScreenShareFrameProcessor(_ processor: ScreenShareFrameProcessor?) {}
    nonisolated func onScreenShareFailed(_ handler: @escaping @Sendable (Error) -> Void) -> Cancellable {
        Cancellable {}
    }

    // No contract trace exercises QoE; an all-nil snapshot satisfies the
    // protocol and keeps the suite compiling.
    nonisolated var qoeSnapshot: SessionQoESnapshot {
        SessionQoESnapshot(
            wsMs: nil, roomMs: nil, micMs: nil, totalConnectMs: nil,
            jitterMs: nil, roundTripMs: nil, jitterBufferMs: nil,
            screenShareFps: nil, screenShareEncodeMs: nil,
            screenShareCpuLimitedMs: nil, screenShareBandwidthLimitedMs: nil,
            packetsLost: nil, concealmentEvents: nil,
            connectionQuality: nil, sampleCount: 0
        )
    }

    /// Deliver one raw server frame, awaiting the session's handling so
    /// injection order is processing order.
    func simulateClose(_ reason: RealtimeSession.EndReason) async {
        await callbacks?.onClosed(reason)
    }

    func inject(_ data: Data) async {
        await callbacks?.onFrame(data)
    }

    /// Fire the agent-track readiness signal (what the LiveKit transport calls
    /// when the agent publishes its track), so tests can exercise readiness
    /// without a real room.
    func signalAgentLive() async {
        await callbacks?.onAgentLive()
    }
}

// MARK: - Observation

/// One SDK-emitted event (or sent frame) normalized to the trace
/// vocabulary: the wire ``type`` discriminator plus the JSON fields.
struct ObservedEvent: Sendable {
    let type: String
    let fields: [String: JSONValue]
}

/// Normalize an SDK event to the trace vocabulary, or `nil` for the
/// local terminal sentinel ``RealtimeSession/Event/sessionEnded(_:)`` —
/// it is not a wire event, so (like the reference adapter) the runner
/// never surfaces it among observed events.
func observe(_ event: RealtimeSession.Event) -> ObservedEvent? {
    switch event {
    case .sessionEnded: return nil
    case .userSpeechTimeout(let payload): return encodedEvent("user-speech-timeout", payload)
    case .ready(let payload): return encodedEvent("ready", payload)
    case .transcript(let payload): return encodedEvent("transcript", payload)
    case .modelText(let payload): return encodedEvent("model-text", payload)
    case .turnComplete(let payload): return encodedEvent("turn-complete", payload)
    case .userStartedSpeaking: return ObservedEvent(type: "user-started-speaking", fields: [:])
    case .userStoppedSpeaking: return ObservedEvent(type: "user-stopped-speaking", fields: [:])
    case .botStartedSpeaking: return ObservedEvent(type: "bot-started-speaking", fields: [:])
    case .botStoppedSpeaking: return ObservedEvent(type: "bot-stopped-speaking", fields: [:])
    case .botLlmStarted: return ObservedEvent(type: "bot-llm-started", fields: [:])
    case .botLlmStopped: return ObservedEvent(type: "bot-llm-stopped", fields: [:])
    case .botTtsStarted: return ObservedEvent(type: "bot-tts-started", fields: [:])
    case .botTtsStopped: return ObservedEvent(type: "bot-tts-stopped", fields: [:])
    case .toolCall(let payload): return encodedEvent("tool-call", payload)
    case .toolDispatchStarted(let payload): return encodedEvent("tool-dispatch-started", payload)
    case .toolResult(let payload): return encodedEvent("tool-result", payload)
    case .toolInvocation(let payload): return encodedEvent("tool-invocation", payload)
    case .reconnecting(let payload): return encodedEvent("reconnecting", payload)
    case .cosmo(let cosmo):
        switch cosmo {
        case .usage(let payload): return encodedEvent("cosmo.usage", payload)
        }
    case .error(let payload): return encodedEvent("error", payload)
    case .pong: return ObservedEvent(type: "pong", fields: [:])
    case .unknown(let rawType, let payload):
        var fields: [String: JSONValue] = ["raw_type": rawType.map(JSONValue.string) ?? .null]
        if let value = try? JSONDecoder().decode(JSONValue.self, from: payload) {
            fields["payload"] = value
        } else {
            fields["payload"] = .string(String(decoding: payload, as: UTF8.self))
        }
        return ObservedEvent(type: "unknown", fields: fields)
    }
}

/// Round-trip a typed payload back to its wire JSON so matchers compare
/// against wire field names, exactly like the Python/TS runners.
private func encodedEvent<Payload: Encodable>(_ type: String, _ payload: Payload) -> ObservedEvent {
    guard
        let data = try? JSONEncoder().encode(payload),
        case .object(let fields)? = try? JSONDecoder().decode(JSONValue.self, from: data)
    else {
        return ObservedEvent(type: type, fields: [:])
    }
    return ObservedEvent(type: type, fields: fields)
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

func stateString(_ state: RealtimeSession.State) -> String {
    switch state {
    case .idle: return "idle"
    case .connecting: return "connecting"
    case .connected: return "connected"
    case .reconnecting: return "reconnecting"
    case .reconnected: return "reconnected"
    case .disconnected(let reason):
        switch reason {
        case .clientEnded: return "disconnected:clientEnded"
        case .clientClosed: return "disconnected:clientClosed"
        case .handshakeFailed: return "disconnected:handshakeFailed"
        case .serverEnded: return "disconnected:serverEnded"
        case .transportError: return "disconnected:transportError"
        }
    }
}

func thrownName(_ error: RealtimeSessionError) -> String {
    switch error {
    case .versionMismatch: return "versionMismatch"
    case .voiceDisabled: return "voiceDisabled"
    case .handshakeFailed: return "handshakeFailed"
    case .sessionStartFailed: return "sessionStartFailed"
    case .alreadyStarted: return "alreadyStarted"
    case .notConnected: return "notConnected"
    case .transportError: return "transportError"
    case .invalidPayload: return "invalidPayload"
    case .screenShareUnavailable: return "screenShareUnavailable"
    case .insecureBaseURL: return "insecureBaseURL"
    }
}

func thrownDetail(_ error: RealtimeSessionError) -> String? {
    switch error {
    case .versionMismatch(let detail): return detail
    case .handshakeFailed(_, _, let detail): return detail
    case .sessionStartFailed(let message): return message
    case .transportError(let message): return message
    case .invalidPayload(let detail): return detail
    case .insecureBaseURL(let url): return url
    case .voiceDisabled, .alreadyStarted, .notConnected, .screenShareUnavailable: return nil
    }
}

// MARK: - Matching engine
//
// Same semantics as the Python runner's ``assertions.py``: ordered
// subsequence, null-matches-absent, deep equality on JSON values
// (with int/double numeric equivalence across the Codable round-trip).

func jsonEquals(_ a: JSONValue, _ b: JSONValue) -> Bool {
    if a == b { return true }
    switch (a, b) {
    case (.int(let i), .double(let d)), (.double(let d), .int(let i)):
        return Double(i) == d
    case (.array(let xs), .array(let ys)):
        return xs.count == ys.count && zip(xs, ys).allSatisfy(jsonEquals)
    case (.object(let xo), .object(let yo)):
        return xo.keys == yo.keys && xo.allSatisfy { key, value in
            yo[key].map { jsonEquals(value, $0) } ?? false
        }
    default:
        return false
    }
}

func fieldsMatch(_ expected: [String: JSONValue]?, _ actual: [String: JSONValue]) -> Bool {
    guard let expected else { return true }
    for (key, expectedValue) in expected {
        if case .null = expectedValue {
            if let actualValue = actual[key], actualValue != .null { return false }
        } else {
            guard let actualValue = actual[key], jsonEquals(expectedValue, actualValue) else {
                return false
            }
        }
    }
    return true
}

/// Ordered-subsequence check; returns a failure message or nil.
func subsequenceFailure(
    matchers: [ExternalTrace.EventMatcher],
    events: [ObservedEvent],
    label: String
) -> String? {
    var position = 0
    for (index, matcher) in matchers.enumerated() {
        while position < events.count,
              !(matcher.type == events[position].type
                && fieldsMatch(matcher.match, events[position].fields))
        {
            position += 1
        }
        if position == events.count {
            let observed = events.map(\.type).joined(separator: " → ")
            return "\(label)[\(index)] \(matcher.type) (match=\(matcher.match ?? [:])) "
                + "not found in order; observed: \(observed.isEmpty ? "<none>" : observed)"
        }
        position += 1
    }
    return nil
}

// MARK: - Recorders + waiting

/// Drains a stream into a buffer; ``awaitAtLeast`` polls with a hard
/// deadline so a short trace never hangs the suite (assertions report
/// the shortfall).
actor TraceRecorder<Element: Sendable> {
    private(set) var items: [Element] = []

    func append(_ item: Element) {
        items.append(item)
    }

    func awaitAtLeast(_ target: Int, deadline: TimeInterval = 2.0) async {
        let end = Date().addingTimeInterval(deadline)
        while items.count < target && Date() < end {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

final class CompletionFlag: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<Bool>(initialState: false)
    func set() { lock.withLock { $0 = true } }
    var isSet: Bool { lock.withLock { $0 } }
}

func waitUntil(deadline: TimeInterval, _ condition: @Sendable () -> Bool) async {
    let end = Date().addingTimeInterval(deadline)
    while !condition() && Date() < end {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

// MARK: - Trace-step bridges

enum TraceDriverError: Error, CustomStringConvertible {
    case unsupported(String)

    var description: String {
        switch self {
        case .unsupported(let what): return "trace driver: unsupported \(what)"
        }
    }
}

/// Build a ``SessionConfig`` from a trace's raw ``start.config`` dict.
/// Unknown keys throw so a future trace exercising config surface this
/// adapter doesn't map fails loudly instead of silently dropping it.
func sessionConfig(fromTrace config: [String: JSONValue]) throws -> SessionConfig {
    var result = SessionConfig()
    for (key, value) in config {
        switch (key, value) {
        case ("model", .string(let v)): result.model = v
        case ("voice", .object(let fields)):
            var voice = SessionConfig.Voice()
            if case .string(let name)? = fields["name"] { voice.name = name }
            if case .string(let style)? = fields["speaking_style"] {
                voice.speakingStyle = style
            }
            result.voice = voice
        case ("instructions", .string(let v)): result.instructions = v
        case ("resume_session_id", .string(let v)): result.resumeSessionId = v
        case ("audio", .object(let fields)):
            var audio = SessionConfig.Audio()
            if case .bool(let output)? = fields["output"] { audio.output = output }
            if case .bool(let cancellation)? = fields["noise_cancellation"] {
                audio.noiseCancellation = cancellation
            }
            result.audio = audio
        case ("interruption_sensitivity", .string(let v)):
            guard let sensitivity = SessionConfig.InterruptionSensitivity(rawValue: v) else {
                throw TraceDriverError.unsupported("interruption_sensitivity \(v)")
            }
            result.interruptionSensitivity = sensitivity
        case ("tools", .array(let specs)):
            result.tools = try specs.map(traceTool(from:))
        default:
            throw TraceDriverError.unsupported("config key \(key)=\(value)")
        }
    }
    return result
}

private func traceTool(from value: JSONValue) throws -> SessionConfig.Tool {
    guard case .object(let spec) = value, case .string(let kind)? = spec["kind"] else {
        throw TraceDriverError.unsupported("tool spec \(value)")
    }
    switch kind {
    case "web_search":
        return .webSearch
    case "examine_image":
        return .examineImage
    case "client":
        guard
            case .string(let name)? = spec["name"],
            case .string(let description)? = spec["description"],
            case .object(let parameters)? = spec["parameters"]
        else {
            throw TraceDriverError.unsupported("client tool spec \(value)")
        }
        return .client(name: name, description: description, parameters: parameters)
    default:
        throw TraceDriverError.unsupported("tool kind \(kind)")
    }
}

/// Drive the SDK send that corresponds to a ``client_send`` step.
func performClientSend(_ message: [String: JSONValue], on session: RealtimeSession) async throws {
    guard case .string(let type)? = message["type"] else {
        throw TraceDriverError.unsupported("client_send without type")
    }
    switch type {
    case "send-text":
        guard case .string(let content)? = message["content"] else {
            throw TraceDriverError.unsupported("send-text message \(message)")
        }
        try await session.send(text: content)
    case "send-context":
        guard case .string(let content)? = message["content"] else {
            throw TraceDriverError.unsupported("send-context message \(message)")
        }
        try await session.send(context: content)
    case "mute":
        guard case .bool(let muted)? = message["muted"] else {
            throw TraceDriverError.unsupported("mute message \(message)")
        }
        try await session.setMuted(muted)
    case "ping":
        try await session.ping()
    default:
        throw TraceDriverError.unsupported("client_send type \(type)")
    }
}

/// Map scripted handshake frames onto the transport-level start
/// verdict: the first ``error`` frame rejects the start (mirrors the
/// reference adapter); remaining frames are delivered as inbound after
/// a successful start.
func scriptedRejection(fromHandshake frames: [ExternalTrace.Frame]) -> SessionStartFailure? {
    for frame in frames {
        guard case .object(let fields) = frame, case .string("error")? = fields["type"] else {
            continue
        }
        var code: String?
        if case .string(let value)? = fields["code"] { code = value }
        var message = ""
        if case .string(let value)? = fields["message"] { message = value }
        return .rejected(status: nil, code: code, detail: "\(code ?? "error"): \(message)")
    }
    return nil
}
