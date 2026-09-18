import Foundation
import Testing

@testable import CosmoRealtime

/// The session state machine's public surface: the ``onStateChange`` handler
/// delivers every transition from ``.idle`` on, a transient recovery
/// re-enters ``.connected``, and ``state`` stays readable — terminal value
/// included — after the session ends.
@Suite("RealtimeSession state")
struct SessionStateTests {

    /// Lock-guarded recorder: the handler is synchronous, so appends keep
    /// transition order without an actor hop.
    final class StateRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [SessionState] = []
        func append(_ state: SessionState) {
            lock.lock()
            defer { lock.unlock() }
            recorded.append(state)
        }
        var states: [SessionState] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }
    }

    @Test("onStateChange sees the full prefix and recovery re-enters connected")
    func handlerSeesEveryTransition() async throws {
        let transport = FakeSessionTransport()
        let session = RealtimeSession(transport: transport)
        let recorder = StateRecorder()
        try await session._start(
            config: SessionConfig(),
            onStateChange: { recorder.append($0) }
        )

        #expect(await session.state == .connected)

        await transport.simulateReconnect()
        #expect(await session.state == .connected)

        await session.end()

        #expect(recorder.states == [
            .idle,
            .connecting,
            .connected,
            .reconnecting,
            .connected,
            .disconnected(reason: .clientEnded, detail: nil),
        ])
    }

    @Test("state stays readable after the session ends, latched at the terminal value")
    func terminalStateReadableAfterEnd() async throws {
        let transport = FakeSessionTransport()
        let session = RealtimeSession(transport: transport)
        try await session._start(config: SessionConfig())

        await session.end()

        #expect(await session.state == .disconnected(reason: .clientEnded, detail: nil))
    }
}
