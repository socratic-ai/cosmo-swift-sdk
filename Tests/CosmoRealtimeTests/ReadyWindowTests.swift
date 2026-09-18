import Foundation
import Testing

@testable import CosmoRealtime

/// The join→ready window contract.
///
/// ``RealtimeAgent/start`` resolves at ready, and the window has exactly four
/// exits: the sign resolves it, a pre-ready close throws the enriched
/// handshake failure, silence past the bound throws the timeout, and task
/// cancellation tears the session down and throws ``CancellationError``.
/// TypeScript's `agent_start.test.ts` ("start resolves at ready") and
/// Python's `test_ready_window.py` are the sibling suites.
@Suite("Ready window contract")
struct ReadyWindowTests {

    private static let readyFrame = Data(
        #"{"type":"ready","session_id":"sess-test"}"#.utf8
    )

    private static func errorFrame(fatal: Bool = true) -> Data {
        Data(
            #"{"type":"error","code":"internal_error","message":"boot failed: no model credentials","fatal":\#(fatal)}"#
                .utf8
        )
    }

    /// A session parked on the ready gate, plus the task awaiting it.
    private func startedSession() async throws -> (RealtimeSession, FakeSessionTransport) {
        let transport = FakeSessionTransport()
        let session = RealtimeSession(transport: transport)
        try await session._start(config: SessionConfig())
        return (session, transport)
    }

    @Test("the sign resolves the gate, and the session is usable")
    func signResolvesTheGate() async throws {
        let (session, transport) = try await startedSession()
        await transport.inject(Self.readyFrame)

        try await session._awaitReady()

        // Usable the instant the gate opens — no readiness ritual.
        try await session.send(text: "usable immediately")
        let sent = await transport.sent
        #expect(sent.count >= 2)
        await session.end()
    }

    @Test("the gate stays parked until the handshake lands")
    func gateStaysParked() async throws {
        let (session, transport) = try await startedSession()
        let gate = Task { try await session._awaitReady() }

        // Nothing has landed: the gate must still be parked.
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(!gate.isCancelled)

        await transport.inject(Self.readyFrame)
        try await gate.value
        await session.end()
    }

    @Test("a second ready reaches no surface")
    func readyIsDeduped() async throws {
        let (session, transport) = try await startedSession()
        let events = Task {
            var readies = 0
            for try await event in session.events {
                if case .ready = event { readies += 1 }
            }
            return readies
        }

        // Both deliveries of the sign — the attribute and the frame — carry
        // the same payload; the second reaches no surface.
        await transport.inject(Self.readyFrame)
        await transport.inject(Self.readyFrame)
        try await session._awaitReady()
        await session.end()

        #expect(try await events.value == 1)
    }

    @Test("a pre-ready close throws the enriched handshake failure")
    func preReadyCloseIsEnriched() async throws {
        let (session, transport) = try await startedSession()
        await transport.inject(Self.errorFrame())
        await transport.simulateClose(.serverEnded(reason: "ROOM_DELETED"))

        await #expect {
            try await session._awaitReady()
        } throws: { error in
            guard let error = error as? SessionStartError,
                error.code == .handshakeFailed
            else { return false }
            // The server's own frame is the enrichment the close delivers —
            // its slug on `serverCode`, and no `status`, because no HTTP
            // exchange failed. Python and TypeScript report the same.
            return error.status == nil
                && error.serverCode == "internal_error"
                && error.message.contains("no model credentials")
        }
    }

    @Test("a pre-ready close with no frame still throws typed")
    func preReadyCloseWithoutFrame() async throws {
        let (session, transport) = try await startedSession()
        await transport.simulateClose(.transportError(message: "ICE failed"))

        await #expect {
            try await session._awaitReady()
        } throws: { error in
            guard let error = error as? SessionStartError,
                error.code == .handshakeFailed
            else { return false }
            // No frame, so no server verdict to report: `serverCode` stays
            // absent rather than carrying a slug the server never sent.
            return error.serverCode == nil && error.status == nil
        }
    }

    @Test("a pre-ready error frame alone settles nothing")
    func errorFrameAloneSettlesNothing() async throws {
        let (session, transport) = try await startedSession()
        let gate = Task { try await session._awaitReady() }

        await transport.inject(Self.errorFrame())
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(!gate.isCancelled)

        // The close is the authoritative signal; ready can still arrive.
        await transport.inject(Self.readyFrame)
        try await gate.value
        await session.end()
    }

    @Test("a handshake that never arrives times out and tears down")
    func readyTimeoutTearsDown() async throws {
        let (session, transport) = try await startedSession()

        await #expect {
            try await session._awaitReady(timeout: 0.05)
        } throws: { error in
            guard let error = error as? SessionStartError,
                error.code == .readyTimeout
            else { return false }
            return true
        }
        // Teardown precedes settling: the transport is already closed at the
        // instant the throw is observed, not merely closed eventually. A
        // caller that retries immediately must not race the outgoing session
        // for the microphone or the workspace's session slot.
        #expect(await transport.closed)
        // Torn down, not left half-open.
        let state = await session.state
        guard case .disconnected(let reason, _) = state else {
            Issue.record("expected a disconnected session, got \(state)")
            return
        }
        #expect(reason == .handshakeFailed)
    }

    @Test("cancelling the wait tears the session down and throws CancellationError")
    func cancellationTearsDown() async throws {
        let (session, transport) = try await startedSession()
        let gate = Task { try await session._awaitReady() }

        try await Task.sleep(nanoseconds: 20_000_000)
        gate.cancel()

        await #expect(throws: CancellationError.self) { try await gate.value }
        // Checked before ``waitUntilEnded`` on purpose: the transport must be
        // released by the time the cancellation surfaces, not merely by the
        // time the session finishes. An app cancelling a parked start (the
        // readiness watchdog does exactly this) offers the user a retry the
        // moment the throw lands, and that retry must not race the outgoing
        // session for the microphone or the session slot.
        #expect(await transport.closed)
        await session.waitUntilEnded()
    }

    @Test("the cancellation exit does not surface until teardown has finished")
    func cancellationSettlesAfterTeardown() async throws {
        // The contract's shared invariant, at the one moment it is
        // observable: while the transport is still closing, the parked start
        // must NOT have thrown. Settling first would let an app retry — the
        // readiness watchdog cancels and offers exactly that — while the room,
        // the microphone, and the session slot are still held.
        let (session, transport) = try await startedSession()
        await transport.suspendClose()

        let surfaced = SettleProbe()
        let gate = Task {
            defer { surfaced.mark() }
            try await session._awaitReady()
        }
        try await Task.sleep(nanoseconds: 20_000_000)

        gate.cancel()
        // Teardown has begun and is parked inside the transport.
        while await transport.closeIsSuspended() == false {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(await transport.closed == false)
        try await Task.sleep(nanoseconds: 50_000_000)
        // The throw has not surfaced, because teardown has not finished.
        #expect(surfaced.didSurface == false)

        await transport.resumeClose()
        await #expect(throws: CancellationError.self) { try await gate.value }
        #expect(await transport.closed)
    }

    @Test("the status is a field, never rendered into the message")
    func syntheticStatusIsNotHttp() {
        // The synthetic status 0 used to reach a consumer showing
        // localizedDescription as "HTTP 0". The status is its own field now,
        // so no rendering can invent one.
        let boot = SessionStartError(
            code: .handshakeFailed, message: "boot failed", status: 0,
            serverCode: "handshake_disconnect"
        )
        let described = boot.errorDescription ?? ""
        #expect(!described.contains("HTTP"))
        #expect(described.contains("boot failed"))
        #expect(boot.status == 0)

        // A real rejection carries its status the same way — readable, and
        // not glued into the prose.
        let busy = SessionStartError(
            code: .busy, message: "at the concurrent-session limit", status: 429,
            serverCode: "concurrent_session_limit", retryAfterSeconds: 3
        )
        #expect(busy.status == 429)
        #expect(busy.retryAfterSeconds == 3)
        #expect(!(busy.errorDescription ?? "").contains("HTTP"))
    }

    @Test("a pre-ready close reports handshake_failed on every surface")
    func terminalReasonIsCoherent() async throws {
        let (session, transport) = try await startedSession()
        // LiveKit labels this a deliberate server end, but pre-ready it is a
        // failed boot: one terminal reason, whatever the surface.
        await transport.simulateClose(.serverEnded(reason: "ROOM_DELETED"))

        await #expect(throws: (any Error).self) { try await session._awaitReady() }
        let state = await session.state
        guard case .disconnected(let reason, _) = state else {
            Issue.record("expected a disconnected session, got \(state)")
            return
        }
        #expect(reason == .handshakeFailed)
    }
}

/// The sign's decode contract, pinned without a live room: what the transport
/// will and will not treat as readiness on an agent's attributes.
/// Records whether the ready gate's outcome has reached its caller yet.
final class SettleProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var surfaced = false

    func mark() {
        lock.lock(); surfaced = true; lock.unlock()
    }

    var didSurface: Bool {
        lock.lock(); defer { lock.unlock() }
        return surfaced
    }
}

@Suite("Ready attribute decode")
struct ReadyAttributeDecodeTests {

    @Test("a ready frame in the attribute decodes to its payload")
    func decodesReadyFrame() {
        let json = #"{"type":"ready","session_id":"sess-test"}"#
        let payload = SessionRoomDelegate.readyPayload(in: ["cosmo.ready": json])
        #expect(payload == Data(json.utf8))
    }

    @Test("an absent or empty attribute is not a sign")
    func absentAttribute() {
        #expect(SessionRoomDelegate.readyPayload(in: [:]) == nil)
        #expect(SessionRoomDelegate.readyPayload(in: ["cosmo.ready": ""]) == nil)
        #expect(
            SessionRoomDelegate.readyPayload(in: ["lk.agent.state": "listening"]) == nil
        )
    }

    @Test("an unreadable attribute is refused, never fed to the session")
    func unreadableAttribute() {
        #expect(SessionRoomDelegate.readyPayload(in: ["cosmo.ready": "not json"]) == nil)
        #expect(
            SessionRoomDelegate.readyPayload(
                in: ["cosmo.ready": #"{"type":"transcript","text":"hi"}"#]
            ) == nil
        )
    }
}
