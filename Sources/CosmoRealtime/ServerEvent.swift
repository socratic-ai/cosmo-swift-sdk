import Foundation

public enum ServerEvent: Sendable, Equatable {
    case ready(Ready)
    case transcript(Transcript)
    case turnComplete(role: Role)
    case toolCall(ToolCall)
    case toolResult(ToolResult)
    case toolInvocation(ToolInvocation)
    /// Cumulative per-modality token usage for the live session.
    case usage(UsageBreakdown)
    case error(ServerError)
    case pong
    case unknown(type: String, raw: [String: JSONValue])
}

extension ServerEvent {
    /// Narrow one ``RealtimeSession/Event`` — what ``RealtimeSession/events``
    /// yields — to the transcript vocabulary. ``nil`` for events with no
    /// transcript representation, which callers fold as a no-op.
    public init?(_ event: RealtimeSession.Event) {
        switch event {
        case .ready(let ready):
            self = .ready(Ready(sessionId: ready.sessionId))
        case .transcript(let delta):
            self = .transcript(Transcript(
                role: delta.role == .user ? .user : .assistant,
                text: delta.text,
                isFinal: delta.isFinal
            ))
        case .turnComplete(let turn):
            self = .turnComplete(role: turn.role == .user ? .user : .assistant)
        case .toolCall(let call):
            self = .toolCall(ToolCall(callId: call.toolCallId, name: call.name))
        case .toolResult(let result):
            self = .toolResult(ToolResult(
                callId: result.toolCallId, ok: result.ok, summary: result.summary
            ))
        case .error(let err):
            self = .error(ServerError(code: err.code.rawValue, message: err.message))
        case .pong:
            self = .pong
        case .modelText, .userStartedSpeaking, .userStoppedSpeaking,
             .botStartedSpeaking, .botStoppedSpeaking, .botLlmStarted,
             .botLlmStopped, .botTtsStarted, .botTtsStopped,
             .toolDispatchStarted, .toolInvocation, .reconnecting, .cosmo,
             .userSpeechTimeout, .sessionEnded, .unknown:
            return nil
        }
    }
}

/// Cumulative token usage for a live session, split by direction and modality.
/// Decodes from the wire `usage` message; absent fields default to 0. Gemini
/// Live bills screen-share video frames as image tokens (no separate video).
public struct UsageBreakdown: Sendable, Equatable, Decodable {
    public let inputText: Int
    public let inputImage: Int
    public let inputAudio: Int
    public let inputCached: Int
    public let outputText: Int
    public let outputAudio: Int
    public let total: Int

    public init(
        inputText: Int = 0,
        inputImage: Int = 0,
        inputAudio: Int = 0,
        inputCached: Int = 0,
        outputText: Int = 0,
        outputAudio: Int = 0,
        total: Int = 0
    ) {
        self.inputText = inputText
        self.inputImage = inputImage
        self.inputAudio = inputAudio
        self.inputCached = inputCached
        self.outputText = outputText
        self.outputAudio = outputAudio
        self.total = total
    }

    private enum CodingKeys: String, CodingKey {
        case inputText = "input_text_tokens"
        case inputImage = "input_image_tokens"
        case inputAudio = "input_audio_tokens"
        case inputCached = "input_cached_tokens"
        case outputText = "output_text_tokens"
        case outputAudio = "output_audio_tokens"
        case total = "total_tokens"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func int(_ key: CodingKeys) -> Int { (try? c.decode(Int.self, forKey: key)) ?? 0 }
        inputText = int(.inputText)
        inputImage = int(.inputImage)
        inputAudio = int(.inputAudio)
        inputCached = int(.inputCached)
        outputText = int(.outputText)
        outputAudio = int(.outputAudio)
        total = int(.total)
    }
}

extension ServerEvent: Decodable {
    private enum TypeKey: String, CodingKey { case type }

    public init(from decoder: Decoder) throws {
        let typeContainer = try decoder.container(keyedBy: TypeKey.self)
        let type = try typeContainer.decode(String.self, forKey: .type)

        let singleValue = try decoder.singleValueContainer()
        switch type {
        case "ready":
            self = .ready(try singleValue.decode(Ready.self))
        case "transcript":
            self = .transcript(try singleValue.decode(Transcript.self))
        case "turn_complete":
            let payload = try singleValue.decode(TurnCompletePayload.self)
            self = .turnComplete(role: payload.role)
        case "tool_call":
            self = .toolCall(try singleValue.decode(ToolCall.self))
        case "tool_result":
            self = .toolResult(try singleValue.decode(ToolResult.self))
        case "error":
            self = .error(try singleValue.decode(ServerError.self))
        case "pong":
            self = .pong
        case "usage":
            self = .usage(try singleValue.decode(UsageBreakdown.self))

        // Backend wire-protocol aliases (snake_case on the wire is rare —
        // realtime_protocol.py uses dashes). These let us decode the
        // canonical names the LiveKit data channel actually delivers.
        case "bot-ready":
            self = .ready(try singleValue.decode(Ready.self))
        case "turn-complete":
            let payload = try? singleValue.decode(TurnCompletePayload.self)
            // `turn-complete` carries a role in the new protocol; fall
            // back to assistant when it's omitted (Pipecat-era frames).
            self = .turnComplete(role: payload?.role ?? .assistant)
        case "tool-call":
            self = .toolCall(try singleValue.decode(ToolCallDashed.self).asToolCall())
        case "tool-result":
            self = .toolResult(try singleValue.decode(ToolResultDashed.self).asToolResult())
        case "tool-invocation":
            self = .toolInvocation(try singleValue.decode(ToolInvocation.self))

        default:
            let raw = try singleValue.decode([String: JSONValue].self)
            self = .unknown(type: type, raw: raw)
        }
    }

    private struct TurnCompletePayload: Decodable { let role: Role }

    /// The dashed-protocol shape uses `toolCallId` instead of `call_id`.
    /// We keep the public ``ToolCall`` API stable and map at the seam.
    private struct ToolCallDashed: Decodable {
        let toolCallId: String
        let name: String

        func asToolCall() -> ToolCall {
            ToolCall(callId: toolCallId, name: name)
        }
    }

    private struct ToolResultDashed: Decodable {
        let toolCallId: String
        let ok: Bool
        let summary: String?

        func asToolResult() -> ToolResult {
            ToolResult(callId: toolCallId, ok: ok, summary: summary)
        }
    }
}
