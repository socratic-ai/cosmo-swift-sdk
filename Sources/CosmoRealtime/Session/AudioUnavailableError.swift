import Foundation
/// OS audio could not be initialized: the capture device would not open.
///
/// ``code`` names which of those it was — branch on it rather than on the
/// message. This SDK names ``AudioUnavailableErrorCode/micDenied`` when the
/// platform reports a refused permission and
/// ``AudioUnavailableErrorCode/micNotFound`` when the input node offers no
/// usable format. Every other capture fault is
/// ``AudioUnavailableErrorCode/audioUnavailable`` — the audio device module
/// does not separate them.
///
/// Raised from both paths that publish a microphone — the join, which is where
/// a default ``start()`` publishes it, and ``setMuted(_:)`` for a session that
/// joined muted. Only a failure whose own type names the device is raised this
/// way; anything else is passed through unchanged, so a transport fault never
/// arrives dressed as a microphone problem — including from
/// ``startAudioStream()``, which publishes audio the SDK did not capture and
/// often runs on a host with no microphone at all.
public struct AudioUnavailableError: RealtimeError, Sendable, Equatable, LocalizedError {
    /// Which audio failure occurred. A closed set this SDK raises — switch on it.
    public let code: AudioUnavailableErrorCode
    /// Human-readable explanation, for logs and display.
    public let message: String

    /// An audio failure with its cross-SDK code and message.
    public init(message: String, code: AudioUnavailableErrorCode = .audioUnavailable) {
        self.message = message
        self.code = code
    }

    /// The code and message, for `LocalizedError` presentation.
    public var errorDescription: String? { "\(code.rawValue): \(message)" }
}

/// Which audio failure occurred.
///
/// Closed: every one is raised by this SDK, so it changes only when the SDK
/// does. Each SDK reports the ones its platform can tell apart — a member
/// absent from one platform's vocabulary is still declared, so a `switch`
/// written against it stays exhaustive everywhere.
public enum AudioUnavailableErrorCode: String, Sendable, Equatable {
    /// The host refused microphone permission. Nothing retries around it —
    /// the user grants access, or the session runs without a microphone.
    case micDenied = "mic_denied"
    /// No input device exists to open.
    case micNotFound = "mic_not_found"
    /// An input device exists but another process holds it exclusively.
    case micInUse = "mic_in_use"
    /// Audio could not be initialized and the platform did not say which of
    /// the above it was.
    case audioUnavailable = "audio_unavailable"
}
