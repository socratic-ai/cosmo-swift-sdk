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
    /// ``start(_:config:micMuted:)`` doesn't pay a cold VPIO start-up.
    /// Best-effort; silently no-ops when mic permission isn't yet authorized,
    /// so gate the call on the platform permission state. While enabled, macOS
    /// shows the system mic-active indicator — scope it to a "ready to start"
    /// window, not the whole app lifetime.
    public static func setRecordingAlwaysPrepared(_ enabled: Bool) async throws {
        try await AudioManager.shared.setRecordingAlwaysPreparedMode(enabled)
    }
}
