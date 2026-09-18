import Foundation
import os

/// Collects the connect-phase timings the transport measures and the
/// server-side breakdown from the start response, then hands back a
/// ``SessionConnectTimings`` on demand. Lock-guarded and ``Sendable``
/// because it's written during connect and read at terminal close.
final class SessionConnectTimingsRecorder: Sendable {
    private struct State {
        var handshakeStart: Date?
        var wsMs: Double?
        var roomMs: Double?
        var micMs: Double?
        var totalMs: Double?
        var readyMs: Double?
        var serverTimings: RealtimeSessionStartTimings?
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    /// Origin of every elapsed figure here — the instant the connect began.
    /// The marks that land after connect returns measure from it, so they
    /// share the origin ``wsMs`` uses.
    func setHandshakeStart(_ instant: Date) {
        state.withLock { $0.handshakeStart = instant }
    }

    func setConnectPhases(wsMs: Double, roomMs: Double, micMs: Double, totalMs: Double) {
        // The server's own breakdown lands earlier in the same connect, so read
        // it back here: the traced line is the whole breakdown or it is not
        // worth grepping for.
        let serverMs = state.withLock {
            $0.wsMs = wsMs
            $0.roomMs = roomMs
            $0.micMs = micMs
            $0.totalMs = totalMs
            return $0.serverTimings?.totalMs
        }
        CosmoRealtimeLog.trace(
            .debug,
            "connect",
            "timings ws_ms=\(Int(wsMs)) room_ms=\(Int(roomMs))"
                + " mic_ms=\(Int(micMs)) total_ms=\(Int(totalMs))"
                + " server_ms=\(serverMs.map(String.init) ?? "-")"
        )
    }

    /// Mark the agent's ``ready`` frame. First mark wins.
    func markReady(at instant: Date = Date()) {
        let marked = state.withLock { s -> Double? in
            guard let start = s.handshakeStart, s.readyMs == nil else { return nil }
            let ms = instant.timeIntervalSince(start) * 1000
            s.readyMs = ms
            return ms
        }
        guard let ms = marked else { return }
        CosmoRealtimeLog.trace(.debug, "connect", "timings ready_ms=\(Int(ms))")
    }

    func setServerTimings(_ timings: RealtimeSessionStartTimings) {
        state.withLock { $0.serverTimings = timings }
    }

    func snapshot() -> SessionConnectTimings {
        state.withLock { s in
            SessionConnectTimings(
                wsMs: s.wsMs,
                roomMs: s.roomMs,
                micMs: s.micMs,
                totalConnectMs: s.totalMs,
                readyMs: s.readyMs,
                serverTimings: s.serverTimings
            )
        }
    }
}
