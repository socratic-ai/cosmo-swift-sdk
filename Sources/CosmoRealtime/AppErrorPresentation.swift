import Foundation

/// Display-ready summary of an error the user sees in the session UI. Pure
/// value type — no AppKit / UIKit dependency, so it can be produced by the
/// shared `VoiceSessionModel` and rendered identically on macOS and iOS.
public struct AppErrorPresentation: Equatable, Hashable, Sendable {
    public let headline: String
    public let message: String
    public let heardTranscript: String?
    public let actions: [Action]
    /// Structured cause of the failure, so a consumer can classify it without
    /// parsing `message` — e.g. silently retry a transient `.transport` /
    /// `.timeout` connect failure but surface `.auth` / `.permission` /
    /// `.rateLimited` immediately. Defaults to `.other`, so every existing
    /// construction (and every consumer that ignores it) is unaffected.
    public let kind: ConnectFailureKind

    public init(
        headline: String,
        message: String,
        heardTranscript: String?,
        actions: [Action],
        kind: ConnectFailureKind = .other
    ) {
        self.headline = headline
        self.message = message
        self.heardTranscript = heardTranscript
        self.actions = actions
        self.kind = kind
    }

    /// Classifies a session failure by recovery strategy. `.transport` /
    /// `.timeout` are transient network failures and safe to retry with a fresh
    /// session; `.agentUnready` (the agent didn't become ready in time),
    /// `.auth` / `.permission` / `.rateLimited` must not be retried silently
    /// (retrying a slow agent restarts dispatch and can double it; retrying the
    /// others reuses the same rejected credential / denied grant / spent quota).
    /// `.other` is the conservative default: not silently retried.
    public enum ConnectFailureKind: Sendable, Equatable, Hashable {
        case transport
        case timeout
        case agentUnready
        case auth
        case permission
        case rateLimited
        case other
    }

    public enum Action: Equatable, Hashable, Sendable {
        case retry
        case signBackIn
        case learnMore(URL)
        case revealLogs

        public var title: String {
            switch self {
            case .retry: return "Try again"
            case .signBackIn: return "Sign back in"
            case .learnMore: return "Learn more"
            case .revealLogs: return "Reveal logs"
            }
        }
    }
}
