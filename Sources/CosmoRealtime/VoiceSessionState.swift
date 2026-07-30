import Foundation

/// UI-facing lifecycle of a voice session.
public enum VoiceSessionState: Equatable, Sendable {
    case idle
    case connecting
    case live(sessionId: String)
    case ending
    case error(AppErrorPresentation)

    public var isLive: Bool {
        if case .live = self { return true } else { return false }
    }

    /// A session holds the input device, or is on its way to holding it —
    /// connecting, live, or tearing down.
    ///
    /// ``isLive`` is too narrow for anything guarding the mic or the session
    /// slot: a start is only accepted from `idle` / `error`, and local capture
    /// begun mid-connect lands a second consumer on the single input device
    /// the moment the room joins.
    public var isCallActive: Bool {
        switch self {
        case .connecting, .live, .ending: return true
        case .idle, .error:               return false
        }
    }
}
