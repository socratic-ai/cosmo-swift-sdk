import Foundation

/// Application-level connection lifecycle for a voice session, produced by
/// ``VoiceSession`` by translating the SDK transport-level ``ConnectionState``.
/// Distinct from ``ConnectionState``: carries the session/conversation ids
/// and an app-facing ``ConnectionCloseReason``.
@frozen public enum VoiceConnectionState: Sendable, Equatable {
    case idle
    case connecting
    case connected(sessionId: String)
    /// Transient LiveKit-driven recovery — the existing session is
    /// attempting an in-room reconnect. Followed by ``.reconnected`` or ``.closed``.
    case reconnecting
    /// LiveKit recovered from a transient drop; session continues.
    case reconnected
    case closed(reason: ConnectionCloseReason)
}
