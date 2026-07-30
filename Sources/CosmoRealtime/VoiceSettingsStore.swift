import Foundation

/// Persists the user's chosen Gemini Live voice. Backed by ``UserDefaults``
/// so the picker survives app restarts. Extracted into a library target
/// so the read/write/fallback logic is unit-testable without spinning up
/// the AppKit executable.
public struct VoiceSettingsStore {
    public static let defaultVoice: GeminiVoice = .aoede
    public static let userDefaultsKey: String = "geminiVoice"
    public static let noiseCancellationKey: String = "noiseCancellationEnabled"
    public static let reducedInterruptionSensitivityKey: String =
        "reducedInterruptionSensitivity"
    public static let storeServerRecordingKey: String = "storeServerRecording"
    public static let thinkingLevelKey: String = "thinkingLevel"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var voice: GeminiVoice {
        get {
            defaults.string(forKey: Self.userDefaultsKey)
                .flatMap(GeminiVoice.init(rawValue:)) ?? Self.defaultVoice
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Self.userDefaultsKey)
        }
    }

    /// Server-side background-voice cancellation (LiveKit BVC) on the mic
    /// path. Off by default; read at session start, so a change applies to
    /// the next session. Backs the settings toggle, which is always an
    /// on/off — use ``noiseCancellationPreference`` at session start.
    public var noiseCancellationEnabled: Bool {
        get { defaults.bool(forKey: Self.noiseCancellationKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.noiseCancellationKey) }
    }

    /// The user's explicit background-voice-cancellation choice, or ``nil``
    /// when they have never set it. Read at session start: ``nil`` leaves the
    /// field off the wire so the server's per-surface default applies (the
    /// first-party mobile app defaults it on server-side), while an explicit
    /// choice is sent and always wins.
    public var noiseCancellationPreference: Bool? {
        defaults.object(forKey: Self.noiseCancellationKey) == nil
            ? nil : defaults.bool(forKey: Self.noiseCancellationKey)
    }

    /// Raises the provider's speech-start threshold so ambient noise is less
    /// likely to barge in over the assistant. Off by default; read at
    /// session start.
    public var reducedInterruptionSensitivity: Bool {
        get { defaults.bool(forKey: Self.reducedInterruptionSensitivityKey) }
        nonmutating set {
            defaults.set(newValue, forKey: Self.reducedInterruptionSensitivityKey)
        }
    }

    /// Whether Cosmo may persist this session's recording artifacts
    /// (audio/video/transcript/tool events) to its servers. **Off by default**
    /// — the Mac app is privacy-first, so a fresh install stores nothing
    /// durable server-side. Read at session start into
    /// ``RealtimeClientInit.storeRecording``.
    public var storeServerRecording: Bool {
        get { defaults.bool(forKey: Self.storeServerRecordingKey) }
        nonmutating set {
            defaults.set(newValue, forKey: Self.storeServerRecordingKey)
        }
    }

    /// Reasoning depth for the Gemini realtime model — one of ``minimal`` /
    /// ``low`` / ``medium`` / ``high`` (the ``RealtimeThinkingLevel`` wire
    /// values). ``nil`` (default, "Auto") sends no override so the backend's
    /// per-participation-mode default applies. Read at session start into
    /// ``RealtimeClientInit.thinkingLevel``; a change applies next session.
    public var thinkingLevel: String? {
        get { defaults.string(forKey: Self.thinkingLevelKey) }
        nonmutating set {
            if let newValue {
                defaults.set(newValue, forKey: Self.thinkingLevelKey)
            } else {
                defaults.removeObject(forKey: Self.thinkingLevelKey)
            }
        }
    }
}
