import Foundation

/// The wake phrase that a detector signals. Only one phrase is used in
/// the V1 Mac strict-mode loop (``.wake`` triggers a session start); the
/// type is left as an enum so callers can extend with sleep / cancel
/// phrases later behind the same protocol.
public enum WakePhrase: Sendable, Equatable {
    case wake
}

/// Listens to the microphone for the wake phrase.
///
/// A detector owns its own audio capture pipeline so it can hear the
/// wake phrase while no voice session is active. This is the
/// **session-boundary** wake-word design: the detector runs only in the
/// armed state, between sessions, and is stopped completely before a
/// LiveKit session opens. macOS allows a single Voice-Processing IO
/// consumer per input device — two coexisting VPIO engines fight for
/// the HAL — so we never run the detector and a LiveKit session at the
/// same time. See PR description for the why.
///
/// The detection engine is swappable: ``AppleSpeechWakeWordDetector``
/// uses Apple's on-device speech recognition today; a purpose-trained
/// wake-word model can drop in later behind this same protocol.
public protocol WakeWordDetector: Sendable {
    /// Start listening. ``onDetect`` is invoked once per recognized
    /// phrase. Throws if microphone or speech-recognition permission is
    /// missing, or if on-device recognition is unavailable.
    func start(onDetect: @escaping @Sendable (WakePhrase) -> Void) async throws

    /// Stop listening and release the microphone. Idempotent.
    func stop() async
}

/// Failure modes a ``WakeWordDetector`` can report from
/// ``WakeWordDetector/start(onDetect:)``.
public enum WakeWordDetectorError: Error, Sendable {
    /// On-device speech recognition is not available on this device/locale.
    case onDeviceSpeechUnavailable
    /// The user denied (or has not granted) speech-recognition permission.
    case speechAuthDenied
    /// A usable microphone capture format could not be constructed.
    case audioFormatUnavailable
}
