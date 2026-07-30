import Foundation
import Observation

/// Observable RMS level meters + waveform history for one voice session.
/// Extracted from ``VoiceSessionModel`` so the lifecycle / transcript
/// layer doesn't have to own audio-meter plumbing too.
///
/// Two AsyncStreams (input + output level) feed into rolling history
/// buffers; views read the per-frame RMS via ``waveformAmplitude(_:)``
/// or the raw history arrays. A silence threshold gates the
/// "is the user / assistant actually speaking" decisions.
@available(macOS 14, iOS 17, *)
@Observable
@MainActor
public final class LevelMeterModel {
    /// Number of slots in the rolling RMS history; controls the visual
    /// width of the waveform.
    public static let historyLength = 80

    /// RMS below this is treated as silence (no waveform animation, no
    /// "user is speaking" decision). Empirically tuned for LiveKit's
    /// Opus output gain.
    public static let silenceThreshold: Float = 0.005

    /// RMS floor for "the user is clearly speaking" — above ambient noise
    /// (typically 0.005–0.01) but below normal conversational speech (0.02–0.05).
    /// Used by idle-timeout logic so a quiet room never counts as voice activity.
    public static let speechThreshold: Float = 0.02

    /// Window over which "recent" speaker activity decays. Drives the
    /// "is Cosmo speaking?" boolean for the waveform tint.
    public static let silenceWindow: TimeInterval = 5.0

    public private(set) var liveInputLevel: Float = 0
    public private(set) var liveOutputLevel: Float = 0

    /// Raw RMS is in the 0.01–0.05 range for normal speech; multiply by
    /// the same `*20` constant used elsewhere (``waveformAmplitude(_:)``,
    /// ``LevelBar``) so audio-reactive UI gets a usable 0–1 envelope.
    public var liveInputLevelNormalized: Float { min(1, liveInputLevel * 20) }
    public var liveOutputLevelNormalized: Float { min(1, liveOutputLevel * 20) }

    public private(set) var micRMSHistory: [Float] = Array(repeating: 0, count: LevelMeterModel.historyLength)
    public private(set) var speakerRMSHistory: [Float] = Array(repeating: 0, count: LevelMeterModel.historyLength)
    public private(set) var lastMicActivityAt: Date = Date()
    /// Last time the mic crossed ``speechThreshold`` — noise-immune user-presence
    /// signal for idle-timeout. Updated client-side with no server round-trip.
    public private(set) var lastAudibleMicAt: Date = .distantPast
    public private(set) var lastSpeakerActivityAt: Date = Date()
    /// True once the user's mic has crossed ``silenceThreshold`` this session.
    /// Gates first-turn latency so it's only measured after the user spoke.
    public private(set) var micHasBeenAudible = false

    /// Fired (main actor) on each silence → audible transition of the agent's
    /// output level. ``VoiceSessionModel`` uses it to time first-audio arrival
    /// and first-turn response latency. The owner sets/clears it per session.
    public var onSpeakerBecameAudible: (@MainActor () -> Void)?
    private var speakerAudible = false

    public enum WaveformKind: Sendable { case mic, speaker }

    public init() {}

    public func waveformAmplitude(_ kind: WaveformKind) -> Float {
        let history = kind == .mic ? micRMSHistory : speakerRMSHistory
        let lastActivity = kind == .mic ? lastMicActivityAt : lastSpeakerActivityAt
        let timeSinceActivity = Date().timeIntervalSince(lastActivity)
        let decay: Float = max(0, Float(1 - timeSinceActivity / Self.silenceWindow))
        return (history.last ?? 0) * 20 * decay
    }

    public var isCosmoSpeaking: Bool {
        Date().timeIntervalSince(lastSpeakerActivityAt) < 0.4
    }

    public var isMicActiveForDisplay: Bool {
        Date().timeIntervalSince(lastMicActivityAt) < Self.silenceWindow ||
        isCosmoSpeaking
    }

    /// Subscribe to the session's `inputLevel` + `outputLevel` streams.
    /// Returns the consumer tasks so the owner can cancel them on
    /// session teardown.
    public func startPump(for session: VoiceSession) -> [Task<Void, Never>] {
        let inputTask = Task { @MainActor [weak self] in
            for await level in session.inputLevel {
                guard let self else { return }
                self.recordInput(level)
            }
        }
        let outputTask = Task { @MainActor [weak self] in
            for await level in session.outputLevel {
                guard let self else { return }
                self.recordOutput(level)
            }
        }
        return [inputTask, outputTask]
    }

    /// Zero out levels and history. Call on session teardown so the
    /// waveform doesn't appear to keep moving after the mic is gone.
    public func reset() {
        liveInputLevel = 0
        liveOutputLevel = 0
        micRMSHistory = Array(repeating: 0, count: Self.historyLength)
        speakerRMSHistory = Array(repeating: 0, count: Self.historyLength)
        lastAudibleMicAt = .distantPast
        lastSpeakerActivityAt = .distantPast
        speakerAudible = false
        micHasBeenAudible = false
    }

    // MARK: - Internals

    private func recordInput(_ level: Float) {
        liveInputLevel = level
        // TODO(v0.5+): replace O(n) `removeFirst()` on the 80-slot Array
        // with a ring buffer / `Deque` from swift-collections. At ~50Hz
        // we shift the array ~4000×/sec; harmless but wasteful.
        if !micRMSHistory.isEmpty {
            micRMSHistory.removeFirst()
        }
        micRMSHistory.append(level)
        if level > Self.silenceThreshold {
            lastMicActivityAt = Date()
            micHasBeenAudible = true
        }
        if level > Self.speechThreshold {
            lastAudibleMicAt = Date()
        }
    }

    private func recordOutput(_ level: Float) {
        liveOutputLevel = level
        // TODO(v0.5+): same ring-buffer note as recordInput.
        if !speakerRMSHistory.isEmpty {
            speakerRMSHistory.removeFirst()
        }
        speakerRMSHistory.append(level)
        if level > Self.silenceThreshold {
            lastSpeakerActivityAt = Date()
            if !speakerAudible {
                speakerAudible = true
                onSpeakerBecameAudible?()
            }
        } else {
            speakerAudible = false
        }
    }
}
