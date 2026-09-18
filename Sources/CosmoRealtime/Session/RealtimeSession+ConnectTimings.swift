import CosmoRealtimeAPI
import Foundation

/// The client's half of the connect waterfall, reported to the worker once
/// per session. The server times its own phases; only the client can see the
/// start request, the media join and the microphone, so without this report
/// the waterfall stops at the worker's edge.
extension RealtimeSession {

    /// Send the report once both halves are in hand: the transport's connect
    /// phases and a readiness signal. Called from whichever lands last.
    /// ``ready_ms`` rides along only when the ``ready`` frame was the signal —
    /// a session that loses it still reports the phases it measured.
    /// Best-effort — a session is not worth failing over a telemetry frame.
    func _reportConnectTimings() {
        guard !didReportConnectTimings, didObserveReadiness else { return }
        let timings = connectTimings
        guard let requestMs = timings.wsMs else { return }
        didReportConnectTimings = true

        let frame = CosmoRealtimeAPI.Components.Schemas.ClientConnectTimings(
            micMs: timings.micMs.map { Int($0.rounded()) },
            readyMs: timings.readyMs.map { Int($0.rounded()) },
            requestMs: Int(requestMs.rounded()),
            roomMs: timings.roomMs.map { Int($0.rounded()) },
            server: timings.serverTimings.map { .init($0) },
            _type: .connectTimings
        )
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self._publish(frame)
            } catch {
                Self.log.warning(
                    "connect-timings publish failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
