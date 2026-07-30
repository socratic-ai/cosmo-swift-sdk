import Foundation

/// Voice-activity transition from ``HALVoiceActivityMonitor``.
/// Debounced into "turn complete" by ``TurnCompleteCoalescer``.
public enum VoiceActivityEvent: Sendable, Equatable {
    case userSpeaking
    case userSilent
}
