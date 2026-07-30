import CosmoRealtimeAPI
import Foundation
import OpenAPIRuntime

/// Developer-facing names for the generated voice-sessions REST types.
/// ``VoiceSessionSummary`` renames the spec's ``VoiceSession`` record to
/// avoid colliding with the live ``VoiceSession`` actor.
public typealias VoiceSessionSummary = CosmoRealtimeAPI.Components.Schemas.VoiceSession
public typealias VoiceSessionTranscriptTurn = CosmoRealtimeAPI.Components.Schemas
    .VoiceSessionTranscriptTurn
public typealias RealtimeProviderCapabilities = CosmoRealtimeAPI.Components.Schemas
    .RealtimeProviderCapabilities

extension VoiceSessionSummary: Identifiable {}

extension VoiceSessionTranscriptTurn: Identifiable {
    public var id: String { "\(ts)-\(role.rawValue)" }
}

/// A dedicated error type for the voice-sessions data-out calls, following
/// ``MintTokenError``.
public enum VoiceSessionsError: Error, LocalizedError, Equatable {
    /// The session does not exist (or is outside the credential's scope).
    case notFound
    /// The server refused the request (HTTP ≥ 400). ``code`` is the protocol
    /// error slug when the rejection carried one.
    case rejected(code: String?, detail: String)
    /// A network or transport failure before a server verdict.
    case transport(message: String)
    /// The server replied 2xx but the body could not be decoded.
    case invalidResponse(message: String)

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "Voice session not found"
        case .rejected(let code, let detail):
            if let code { return "\(code): \(detail)" }
            return detail
        case .transport(let message):
            return "Voice sessions request failed: \(message)"
        case .invalidResponse(let message):
            return "Voice sessions response decode failed: \(message)"
        }
    }
}

/// Data-out surface for past voice sessions (list/get/transcript/delete)
/// plus the workspace's provider capabilities.
extension RealtimeClient {
    /// List past sessions, newest first. `beforeStartedAt` pages backwards
    /// from a previous page's oldest ``VoiceSessionSummary/startedAt``.
    public func listVoiceSessions(
        limit: Int? = nil,
        beforeStartedAt: Double? = nil
    ) async throws -> [VoiceSessionSummary] {
        let output = try await _run {
            try await _apiClient().listVoiceSessions(
                query: .init(limit: limit, beforeStartedAt: beforeStartedAt)
            )
        }
        switch output {
        case .ok(let ok):
            return try ok.body.json
        case .unprocessableContent(let err):
            throw Self._rejected(try? err.body.json)
        case .undocumented(let statusCode, let payload):
            throw await Self._undocumented(statusCode, payload)
        }
    }

    public func voiceSession(sessionId: String) async throws -> VoiceSessionSummary {
        let output = try await _run {
            try await _apiClient().getVoiceSession(path: .init(sessionId: sessionId))
        }
        switch output {
        case .ok(let ok):
            return try ok.body.json
        case .unprocessableContent(let err):
            throw Self._rejected(try? err.body.json)
        case .undocumented(let statusCode, let payload):
            throw await Self._undocumented(statusCode, payload)
        }
    }

    public func voiceSessionTranscript(
        sessionId: String
    ) async throws -> [VoiceSessionTranscriptTurn] {
        let output = try await _run {
            try await _apiClient().getVoiceSessionTranscript(
                path: .init(sessionId: sessionId)
            )
        }
        switch output {
        case .ok(let ok):
            return try ok.body.json
        case .unprocessableContent(let err):
            throw Self._rejected(try? err.body.json)
        case .undocumented(let statusCode, let payload):
            throw await Self._undocumented(statusCode, payload)
        }
    }

    /// Which realtime model providers this credential's workspace may select
    /// per session.
    public func realtimeCapabilities() async throws -> RealtimeProviderCapabilities {
        let output = try await _run {
            try await _apiClient().getRealtimeCapabilities()
        }
        switch output {
        case .ok(let ok):
            return try ok.body.json
        case .undocumented(let statusCode, let payload):
            throw await Self._undocumented(statusCode, payload)
        }
    }

    /// Delete a past session. Throws ``VoiceSessionsError/notFound`` when the
    /// session is already gone.
    public func deleteVoiceSession(sessionId: String) async throws {
        let output = try await _run {
            try await _apiClient().deleteVoiceSession(path: .init(sessionId: sessionId))
        }
        switch output {
        case .noContent:
            return
        case .unprocessableContent(let err):
            throw Self._rejected(try? err.body.json)
        case .undocumented(let statusCode, let payload):
            throw await Self._undocumented(statusCode, payload)
        }
    }

    private func _run<Output>(
        _ call: () async throws -> Output
    ) async throws -> Output {
        try await _run(as: VoiceSessionsError.self, call)
    }

    private static func _undocumented(
        _ statusCode: Int,
        _ payload: OpenAPIRuntime.UndocumentedPayload
    ) async -> VoiceSessionsError {
        if statusCode == 404 { return .notFound }
        return await _undocumented(as: VoiceSessionsError.self, statusCode, payload)
    }

    private static func _rejected(
        _ envelope: Components.Schemas.RealtimeErrorEnvelope?
    ) -> VoiceSessionsError {
        _rejected(as: VoiceSessionsError.self, envelope)
    }
}
