import Foundation
import LiveKit
import os

extension RealtimeSession {

    private static let prewarmLog = Logger(
        subsystem: CosmoRealtimeLog.subsystem, category: "session-prewarm"
    )

    /// Where a prewarm was requested from. Logged so a slow next connect is
    /// attributable to its origin (teardown-time prewarms race the previous
    /// session's transport cleanup).
    public enum PrewarmOrigin: String, Sendable {
        case launch
        case teardown
        case other
    }

    /// Pre-warm the LiveKit signaling connection (TLS handshake + Cloud edge
    /// selection) using the URL from the most recent session, so the next
    /// ``start(_:config:)``'s room-join phase is shorter. Best-effort; no-op on
    /// the first ever start (no cached URL). Call at app launch and when the
    /// user is about to start a session (e.g. popover open), before they connect.
    ///
    /// Token-less: ``Room/prepareConnection(url:token:)`` without a token is a
    /// fire-and-forget TLS warm that stores nothing on the ``Room``, so there is
    /// no prepared instance to hand off to the next start. Edge resolution
    /// (which needs a token) is not warmed here.
    public static func prewarmConnection(origin: PrewarmOrigin = .other) async {
        guard let url = PrewarmCache.lastLiveKitURL() else { return }
        do {
            try await Room().prepareConnection(url: url)
            prewarmLog.info(
                "prewarmConnection warmed LiveKit signaling origin=\(origin.rawValue, privacy: .public)"
            )
        } catch {
            prewarmLog.debug(
                "prewarmConnection failed origin=\(origin.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Pre-warm the OS audio engine so the mic publish on the next
    /// ``start(_:config:micMuted:)`` doesn't pay a cold start-up. Best-effort;
    /// silently no-ops when mic permission isn't yet authorized, so gate the
    /// call on the platform permission state. Applies ``audioProcessingOptions``
    /// so the warmed engine is already configured the same way the session's
    /// own capture will be — an unmatched warm would stand up one processing
    /// pipeline and then reconfigure to another the moment the session
    /// actually publishes, which is its own audible glitch independent of
    /// which pipeline either one uses.
    public static func setRecordingAlwaysPrepared(_ enabled: Bool) async throws {
        try await AudioManager.shared.setRecordingAlwaysPreparedMode(
            enabled, audioProcessingOptions: audioProcessingOptions
        )
    }

    /// The mode Cosmo requests for each voice-processing component, applied
    /// everywhere the mic is touched — the warm (above) and the session's own
    /// capture (``makeSessionRoom()``'s ``RoomOptions/defaultAudioCaptureOptions``)
    /// — so the two never disagree.
    ///
    /// On macOS this forces WebRTC's own software echo cancellation / gain
    /// control / noise suppression instead of Apple's platform Voice
    /// Processing I/O (the SDK's own ``EchoCancellationMode/automatic``
    /// default prefers platform processing whenever it's available, which on
    /// macOS is always). A live platform VPIO unit takes over the *shared
    /// system audio device*: it reroutes every app's output — not just
    /// Cosmo's — through the voice-comm path for as long as it's engaged,
    /// which is what made a bare notch hover audibly duck unrelated playback
    /// (fixed by not warming on hover at all) and still ducks/dims playback
    /// for the full duration of any genuine session (Talk press, dictation,
    /// Learn An App) — a cost inherent to the platform unit, not any one
    /// feature's wiring, so it can't be fixed by tuning any one feature.
    /// Software processing is in-process DSP over already-captured samples;
    /// it never touches the device route, so unrelated playback is never
    /// touched either — this is the actual fix, not `duckingLevel` tuning,
    /// which only ever narrowed how much platform VPIO ducks, not whether it
    /// takes the device over in the first place.
    static var audioProcessingOptions: AudioProcessingOptions {
        #if os(macOS)
        AudioProcessingOptions(
            echoCancellationMode: .software,
            autoGainControlMode: .software,
            noiseSuppressionMode: .software
        )
        #else
        AudioProcessingOptions()
        #endif
    }

    /// ``audioProcessingOptions``, in the shape ``RoomOptions/defaultAudioCaptureOptions``
    /// takes at track-creation time. Two types because LiveKit asks for the
    /// same three modes through two different APIs, not two different
    /// policies — keep both in sync with ``audioProcessingOptions``.
    static var audioCaptureOptions: AudioCaptureOptions {
        #if os(macOS)
        AudioCaptureOptions(
            echoCancellationMode: .software,
            autoGainControlMode: .software,
            noiseSuppressionMode: .software
        )
        #else
        AudioCaptureOptions()
        #endif
    }
}
