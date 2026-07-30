import Foundation

/// Injection seam for the turn-completion voice-activity monitor that drives
/// ``VoiceSessionModel``'s `onUserTurnComplete` hook. Kept as a protocol so the
/// published SDK stays free of the macOS-only `AudioToolbox` HAL implementation
/// (`HALVoiceActivityMonitor`), which conforms to this in the in-house
/// `RealtimeVAD` module. Hosts that want turn-context monitoring inject a
/// factory; everyone else (e.g. iOS) injects nothing.
public protocol VoiceActivityMonitoring: Sendable {
    /// Begin monitoring; yields ``VoiceActivityEvent``s until ``stop()``.
    /// Idempotent — repeat calls return the existing stream.
    func start() async throws -> AsyncStream<VoiceActivityEvent>

    /// Stop monitoring and finish the stream. Idempotent.
    func stop() async
}
