import Foundation
import Testing

@testable import CosmoRealtime

@Suite("RealtimeSession cosmo sends")
struct SessionCosmoSendTests {

    private func startedSession() async throws -> (RealtimeSession, FakeSessionTransport) {
        let transport = FakeSessionTransport()
        let session = RealtimeSession(transport: transport)
        try await session._start(config: SessionConfig())
        return (session, transport)
    }

    private func sentSends(_ transport: FakeSessionTransport) async -> [ObservedEvent] {
        // Drop the leading ``session-config`` and the ``bind-input`` frame the
        // session emits on start (this client is the voice), like
        // ``SessionMediaSendTests``.
        await transport.sent
            .dropFirst()
            .map(observeSentFrame)
            .filter { $0.type != "bind-input" }
    }

    @Test("cosmo.sendTurnContext records a wire-compatible turn-context frame")
    func turnContext() async throws {
        let (session, transport) = try await startedSession()
        try await session.cosmo.sendTurnContext(
            cursor: .init(x: 12.5, y: 34.5),
            frontmostApp: "com.apple.Terminal",
            openApps: ["com.apple.Terminal", "com.apple.Safari"],
            clientTurnSeq: 3,
            extras: ["k": "v"]
        )

        let frame = try #require(await sentSends(transport).first)
        // The wire type + field names mirror the internal turn-context the
        // backend boundary parses inbound.
        #expect(frame.type == "turn-context")
        #expect(frame.fields["frontmost_app"] == .string("com.apple.Terminal"))
        #expect(
            frame.fields["open_apps"]
                == .array([.string("com.apple.Terminal"), .string("com.apple.Safari")])
        )
        #expect(frame.fields["client_turn_seq"] == .int(3))
        #expect(frame.fields["cursor"] == .object(["x": .double(12.5), "y": .double(34.5)]))
        #expect(frame.fields["extras"] == .object(["k": .string("v")]))
    }

    @Test("cosmo.sendVisualContext records a wire-compatible visual-context frame")
    func visualContext() async throws {
        let (session, transport) = try await startedSession()
        let payload = VisualContextPayload(
            reason: .focusChange,
            timestampMs: 1234,
            activeDisplay: "display-1",
            focusedApp: "com.apple.Safari",
            focusedWindow: FocusedWindowInfo(
                app: "com.apple.Safari", title: "Docs", url: "https://x", display: "display-1"
            ),
            cursor: CursorPoint(x: 5.5, y: 6.5),
            cursorDisplay: "display-1",
            displays: [
                VisualDisplayInfo(
                    id: "display-1", role: "active", focused: true,
                    visibleApps: ["com.apple.Safari"], visibleWindows: ["w1"]
                )
            ],
            imageRefs: [
                VisualImageRef(
                    id: "img-1", kind: "active_display", streamId: "video.input.default",
                    display: "display-1", app: nil, windowTitle: nil
                )
            ],
            extras: ["k": "v"]
        )
        try await session.cosmo.sendVisualContext(payload)

        let frame = try #require(await sentSends(transport).first)
        #expect(frame.type == "visual-context")
        #expect(frame.fields["reason"] == .string("focus_change"))
        #expect(frame.fields["active_display"] == .string("display-1"))
        #expect(frame.fields["focused_app"] == .string("com.apple.Safari"))
        #expect(frame.fields["client_seq"] == .int(1))
        #expect(frame.fields["cursor"] == .object(["x": .double(5.5), "y": .double(6.5)]))
        #expect(frame.fields["extras"] == .object(["k": .string("v")]))
        // Nested display + image-ref use snake_case wire names.
        guard case .array(let displays)? = frame.fields["displays"],
            case .object(let d0)? = displays.first
        else {
            Issue.record("expected a displays array of objects")
            return
        }
        #expect(d0["id"] == .string("display-1"))
        #expect(d0["visible_apps"] == .array([.string("com.apple.Safari")]))
        guard case .array(let refs)? = frame.fields["image_refs"],
            case .object(let r0)? = refs.first
        else {
            Issue.record("expected an image_refs array of objects")
            return
        }
        #expect(r0["stream_id"] == .string("video.input.default"))
        #expect(r0["kind"] == .string("active_display"))
    }

    @Test("cosmo sends throw notConnected before start")
    func rejectBeforeStart() async {
        let session = RealtimeSession(transport: FakeSessionTransport())
        await #expect(throws: RealtimeSessionError.notConnected) {
            try await session.cosmo.sendTurnContext(frontmostApp: "x")
        }
    }
}
