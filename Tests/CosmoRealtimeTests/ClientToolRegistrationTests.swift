import Foundation
import Testing
@testable import CosmoRealtime

/// The advertise-vs-register matrix for client tools. A tool is either:
///   - advertised AND RPC-handled (an ``AgentTool.client``, which carries its handler), or
///   - RPC-handled but NOT advertised (the grounding RPCs — passed via ``rpcHandlers``).
///
/// The second is the one a naive "handlers = declared tools" mapping silently drops,
/// breaking the server-orchestrated grounding flow on-device. These tests pin that the
/// register-only ``rpcHandlers`` path reaches the transport's RPC registration while staying
/// off the advertised wire config. Advertised-but-unhandled is not a third case: a client
/// tool carries its handler, so it cannot be declared without one.
@Suite("Client-tool registration")
struct ClientToolRegistrationTests {

    @Test("rpcHandlers register without advertising; handler tools advertise + register")
    func advertiseRegisterMatrix() async throws {
        let transport = FakeSessionTransport()
        let session = RealtimeSession(transport: transport)

        let config = SessionConfig(
            tools: [
                // advertised AND RPC-handled
                .client(name: "handled_tool", description: "runs locally",
                        parameters: ["type": .string("object")],
                        handler: { _ in [:] }),
                // advertised server tool (typed opt-in)
                .webSearchTool(),
            ]
        )
        try await session._start(
            config: config,
            rpcHandlers: [
                // RPC-handled but NEVER advertised
                "grounding_capture": { _ in [:] },
                "grounding_click": { _ in [:] },
            ]
        )

        // Registered = client tools ∪ rpcHandlers. The typed server opt-in
        // registers nothing — the server runs it.
        let registered = await transport.registeredToolHandlers
        #expect(Set(registered.keys) == ["handled_tool", "grounding_capture", "grounding_click"])

        // Advertised (on the wire) = every client/server tool; the register-only
        // grounding RPCs are absent.
        let frame = try #require(await transport.sent.first)
        let advertised = Self.advertisedToolNames(frame)
        // Name-bearing specs are the client tools; the typed server opt-in
        // carries only its kind (zero-config), so it has no name to advertise.
        #expect(advertised == ["handled_tool"])
        #expect(Self.advertisedToolKinds(frame).contains("web_search"))
    }

    @Test("wire plumbing is hook-exempt: the capture RPC and rpcHandlers, never client tools")
    func hookExemptionCoversPlumbingOnly() async throws {
        let transport = FakeSessionTransport()
        let session = RealtimeSession(transport: transport)
        let config = SessionConfig(
            tools: [
                .client(name: "handled_tool", description: "runs locally",
                        parameters: ["type": .string("object")],
                        handler: { _ in [:] }),
                .screenLocateTool { _ in ScreenCapture(imageJPEG: Data([0xff, 0xd8])) },
            ]
        )
        try await session._start(
            config: config,
            rpcHandlers: [
                "grounding_capture": { _ in [:] },
                // A caller override of an advertised tool name: the model can
                // still invoke it, so it must keep hooks.
                "handled_tool": { _ in [:] },
            ]
        )

        // Hooks fire for tool calls; the capture RPC and register-only RPC
        // methods are wire plumbing, not tools — but an advertised name is
        // never exempt, whoever supplied its handler.
        let exempt = await transport.registeredHookExemptMethods
        #expect(exempt == ["screen_capture", "grounding_capture"])
    }

    @Test("screen_locate on a transport without byte streams refuses at start")
    func screenLocateRefusesWithoutByteStreams() async throws {
        let transport = FakeSessionTransport(supportsByteStreams: false)
        let session = RealtimeSession(transport: transport)
        let config = SessionConfig(
            tools: [.screenLocateTool { _ in ScreenCapture(imageJPEG: Data([0xff, 0xd8])) }]
        )

        do {
            try await session._start(config: config)
            Issue.record("start must refuse — the capture payload has no channel")
        } catch let error as SessionStartError {
            #expect(error.code == .config)
            #expect(error.serverCode == "screen_locate_unsupported")
            #expect(error.message == "screen_locate is not supported on the websocket transport")
        }
    }

    @Test("no rpcHandlers is the default and registers nothing extra")
    func noRpcHandlersRegistersNothingExtra() async throws {
        let transport = FakeSessionTransport()
        let session = RealtimeSession(transport: transport)
        try await session._start(config: SessionConfig())

        let registered = await transport.registeredToolHandlers
        #expect(registered.isEmpty)
    }

    /// Pull `agent.tools[].name` out of the serialized ``session-config`` frame
    /// without depending on the generated wire types.
    private static func advertisedToolKinds(_ frame: Data) -> Set<String> {
        guard
            let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
            let agent = object["agent"] as? [String: Any],
            let tools = agent["tools"] as? [[String: Any]]
        else { return [] }
        return Set(tools.compactMap { $0["kind"] as? String })
    }

    private static func advertisedToolNames(_ frame: Data) -> Set<String> {
        guard
            let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
            let agent = object["agent"] as? [String: Any],
            let tools = agent["tools"] as? [[String: Any]]
        else { return [] }
        return Set(tools.compactMap { $0["name"] as? String })
    }
}
