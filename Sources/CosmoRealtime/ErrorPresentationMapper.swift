import Foundation

/// Translates raw SDK errors into UI-ready ``AppErrorPresentation``s.
///
/// Lives in `RealtimeCore` (not the SDK) because the chosen copy /
/// `Action`s reflect product decisions, not SDK behavior. macOS and a
/// future iOS app share the same mapping so error UX stays consistent.
public enum ErrorPresentationMapper {
    public static let voiceDocsURL = URL(string: "https://docs.askcosmo.ai/voice")!

    public static func presentation(
        _ err: VoiceClientError,
        heardTranscript: String? = nil
    ) -> AppErrorPresentation {
        switch err {
        case .notConnected:
            return AppErrorPresentation(
                headline: "Not connected",
                message: "The session isn't active. Try again.",
                heardTranscript: heardTranscript,
                actions: [.retry],
                kind: .other
            )
        case .invalidURL(let reason):
            return AppErrorPresentation(
                headline: "Invalid voice URL",
                message: reason,
                heardTranscript: heardTranscript,
                actions: [.revealLogs],
                kind: .other
            )
        case .handshakeFailed(let status, _):
            return handshakePresentation(status: status, heardTranscript: heardTranscript)
        case .voiceDisabled:
            return AppErrorPresentation(
                headline: "Voice disabled",
                message: "Voice is disabled for this workspace.",
                heardTranscript: heardTranscript,
                actions: [.retry, .learnMore(voiceDocsURL)],
                kind: .permission
            )
        case .closedByServer(let code, let reason):
            return AppErrorPresentation(
                headline: "Server closed the session",
                message: "Close code \(code)\(reason.map { ": \($0)" } ?? "").",
                heardTranscript: heardTranscript,
                actions: [.retry],
                kind: .other
            )
        case .transport(let underlying):
            return AppErrorPresentation(
                headline: "Couldn't connect",
                message: underlying.localizedDescription,
                heardTranscript: heardTranscript,
                actions: [.retry],
                kind: .transport
            )
        case .decode:
            return AppErrorPresentation(
                headline: "Unexpected server message",
                message: "This is a bug — please report it.",
                heardTranscript: heardTranscript,
                actions: [.revealLogs],
                kind: .other
            )
        case .micPermissionDenied:
            return AppErrorPresentation(
                headline: "Microphone access denied",
                message: "Enable under System Settings → Privacy & Security → Microphone.",
                heardTranscript: heardTranscript,
                actions: [],
                kind: .permission
            )
        case .audioEngineFailed(let message):
            return AppErrorPresentation(
                headline: "Audio engine failed",
                message: message,
                heardTranscript: heardTranscript,
                actions: [.retry],
                kind: .other
            )
        }
    }

    public static func presentation(
        _ reason: ConnectionCloseReason,
        heardTranscript: String? = nil
    ) -> AppErrorPresentation {
        switch reason {
        case .clientEnded:
            return AppErrorPresentation(
                headline: "Session ended",
                message: "The session was ended.",
                heardTranscript: heardTranscript,
                actions: [.retry],
                kind: .other
            )
        case .clientClosed:
            return AppErrorPresentation(
                headline: "Connection closed",
                message: "The connection was closed.",
                heardTranscript: heardTranscript,
                actions: [.retry],
                kind: .other
            )
        case .pingTimeout:
            return AppErrorPresentation(
                headline: "Connection timed out",
                message: "The server stopped responding.",
                heardTranscript: heardTranscript,
                actions: [.retry],
                kind: .timeout
            )
        case .voiceDisabled:
            return AppErrorPresentation(
                headline: "Voice disabled",
                message: "Voice is disabled for this workspace.",
                heardTranscript: heardTranscript,
                actions: [.retry, .learnMore(voiceDocsURL)],
                kind: .permission
            )
        case .serverClosed(let code, let r):
            return AppErrorPresentation(
                headline: "Server closed the session",
                message: "Close code \(code)\(r.map { ": \($0)" } ?? "").",
                heardTranscript: heardTranscript,
                actions: [.retry],
                kind: .other
            )
        case .transportError(let m):
            return AppErrorPresentation(
                headline: "Couldn't connect",
                message: m,
                heardTranscript: heardTranscript,
                actions: [.retry],
                kind: .transport
            )
        case .agentNotReady:
            return AppErrorPresentation(
                headline: "Couldn't connect",
                message: "The assistant didn't respond in time. Please try again.",
                heardTranscript: heardTranscript,
                actions: [.retry],
                kind: .agentUnready
            )
        case .decodeError(let m):
            return AppErrorPresentation(
                headline: "Unexpected server message",
                message: m,
                heardTranscript: heardTranscript,
                actions: [.revealLogs],
                kind: .other
            )
        case .handshakeFailed(let status):
            return handshakePresentation(status: status, heardTranscript: heardTranscript)
        }
    }

    /// Human description of a close reason, used for log lines and the
    /// transient "Disconnected." banner.
    public static func describe(_ reason: ConnectionCloseReason) -> String {
        switch reason {
        case .clientEnded:                        return "Session ended."
        case .clientClosed:                       return "Connection closed."
        case .pingTimeout:                        return "Connection timed out (no response from server)."
        case .voiceDisabled:                      return "Voice is disabled for this workspace."
        case .serverClosed(let code, let r):      return "Server closed (\(code))\(r.map { ": \($0)" } ?? "")."
        case .transportError(let m):              return "Connection error: \(m)"
        case .agentNotReady(let s):               return "No agent ready within \(s)s."
        case .decodeError(let m):                 return "Bad frame from server: \(m)"
        case .handshakeFailed(422):               return "Session request rejected (HTTP 422)."
        case .handshakeFailed(let status):        return "Auth failed (HTTP \(status))."
        }
    }

    private static func handshakePresentation(
        status: Int,
        heardTranscript: String?
    ) -> AppErrorPresentation {
        switch status {
        case 401:
            return AppErrorPresentation(
                headline: "Sign-in expired",
                message: "Your Cosmo sign-in was rejected. Sign in again to keep using voice.",
                heardTranscript: heardTranscript,
                // Sign-in expired: only re-auth can recover — retry would
                // reconnect with the same rejected credential and loop.
                actions: [.signBackIn],
                kind: .auth
            )
        case 403:
            return AppErrorPresentation(
                headline: "Voice not enabled",
                message: "This workspace isn't allowed to use voice. Ask an admin, or sign in with a different account.",
                heardTranscript: heardTranscript,
                actions: [.learnMore(voiceDocsURL), .signBackIn],
                kind: .permission
            )
        case 422:
            // Request validation, not auth: the server rejected the session
            // request as malformed. Signing back in re-sends the same bad
            // request and loops — offer retry/report instead.
            return AppErrorPresentation(
                headline: "Couldn't start the session",
                message: "The server rejected the session request (HTTP 422). Try again — if it keeps happening, this is a bug; please report it.",
                heardTranscript: heardTranscript,
                actions: [.retry, .revealLogs],
                kind: .other
            )
        case 429:
            return AppErrorPresentation(
                headline: "Too many requests",
                message: "You've hit the rate limit. Wait a moment, then try again.",
                heardTranscript: heardTranscript,
                actions: [.retry],
                kind: .rateLimited
            )
        default:
            return AppErrorPresentation(
                headline: "Couldn't authenticate",
                message: "The server rejected the connection (HTTP \(status)). Try again, or sign in again if it keeps happening.",
                heardTranscript: heardTranscript,
                actions: [.retry, .signBackIn],
                // A refused handshake is an auth-class failure — surface it, do
                // not silently retry with the same rejected credential.
                kind: .auth
            )
        }
    }
}
