import Foundation
import Testing
@testable import CosmoRealtime

@Suite("Agent + Skills")
struct AgentSkillsTests {
    private func fakeRealtime(_ cfg: SessionConfig) async throws -> RealtimeSession {
        let s = RealtimeSession(transport: FakeSessionTransport())
        try await s._start(config: cfg)
        return s
    }

    private func hotSkill(_ name: String, _ desc: String = "d") -> Skill {
        Skill(name: name, description: desc, body: "BODY \(name)")
    }

    private func clientToolNames(_ cfg: SessionConfig) -> [String] {
        (cfg.tools ?? []).compactMap { if case let .client(n, _, _, _) = $0 { return n }; return nil }
    }

    private let refundsMenu =
        "## Skills\nCall load_skill(name) to load private instructions when the conversation reaches the matching path:\n- refunds: handle refunds"

    @Test func injectsLoadSkillToolAndAppendsMenuToInstructions() async throws {
        let agent = try Agent(skills: [hotSkill("refunds", "handle refunds")])
        var names: [String] = []
        var instructions: String?
        let s = try await agent.start(
            config: SessionConfig(instructions: "You are terse."),
            transportFactory: { _ in FakeMCPTransport() }
        ) { cfg in
            names = self.clientToolNames(cfg)
            instructions = cfg.instructions
            return try await self.fakeRealtime(cfg)
        }
        #expect(names == ["load_skill"])
        #expect(instructions == "You are terse.\n\n\(refundsMenu)")
        await s.end()
    }

    @Test func menuBecomesInstructionsWhenNoneSet() async throws {
        let agent = try Agent(skills: [hotSkill("refunds", "handle refunds")])
        var instructions: String?
        let s = try await agent.start(config: SessionConfig(), transportFactory: { _ in FakeMCPTransport() }) { cfg in
            instructions = cfg.instructions
            return try await self.fakeRealtime(cfg)
        }
        #expect(instructions == refundsMenu)
        await s.end()
    }

    @Test func emptyInstructionsBecomesMenuAlone() async throws {
        // Empty (not nil) instructions must not produce leading blank lines —
        // mirrors Python treating "" as falsy.
        let agent = try Agent(skills: [hotSkill("refunds", "handle refunds")])
        var instructions: String?
        let s = try await agent.start(config: SessionConfig(instructions: ""), transportFactory: { _ in FakeMCPTransport() }) { cfg in
            instructions = cfg.instructions
            return try await self.fakeRealtime(cfg)
        }
        #expect(instructions == refundsMenu)
        await s.end()
    }

    @Test func configPersonaAndToolsPreservedUnderSkills() async throws {
        // A skill must augment — not replace — instructions/tools the caller
        // supplied on the config.
        let defaultTool = SessionConfig.Tool.client(
            name: "web_search", description: "d", parameters: ["type": .string("object")], handler: { _ in [:] }
        )
        let agent = try Agent(skills: [hotSkill("refunds", "handle refunds")])
        var names: [String] = []
        var instructions: String?
        let s = try await agent.start(
            config: SessionConfig(instructions: "You are Cosmo.", tools: [defaultTool]),
            transportFactory: { _ in FakeMCPTransport() }
        ) { cfg in
            names = self.clientToolNames(cfg)
            instructions = cfg.instructions
            return try await self.fakeRealtime(cfg)
        }
        #expect(instructions == "You are Cosmo.\n\n\(refundsMenu)")
        #expect(names == ["web_search", "load_skill"])
        await s.end()
    }

    @Test func noSkillsAddsNoToolAndLeavesConfigUntouched() async throws {
        let agent = try Agent(skills: [])
        var tools: [SessionConfig.Tool]?
        var instructions: String?
        let s = try await agent.start(
            config: SessionConfig(instructions: "persona"),
            transportFactory: { _ in FakeMCPTransport() }
        ) { cfg in
            tools = cfg.tools
            instructions = cfg.instructions
            return try await self.fakeRealtime(cfg)
        }
        #expect(tools == nil)
        #expect(instructions == "persona")
        await s.end()
    }

    @Test func loadSkillHandlerReturnsBodyInPrivateEnvelope() async throws {
        let agent = try Agent(skills: [hotSkill("refunds")])
        var handler: ClientToolHandler?
        let s = try await agent.start(config: SessionConfig(), transportFactory: { _ in FakeMCPTransport() }) { cfg in
            if case let .client(_, _, _, h)? = (cfg.tools ?? []).first { handler = h }
            return try await self.fakeRealtime(cfg)
        }
        let out = try await handler?(["name": .string("refunds")])
        #expect(out?["instructions"] == .string(privateInstructionsPrefix + "BODY refunds"))
        await s.end()
    }

    @Test func skillsCallerToolsAndMcpAllMerge() async throws {
        let caller = SessionConfig.Tool.client(
            name: "caller", description: "d", parameters: ["type": .string("object")], handler: { _ in [:] }
        )
        let agent = try Agent(
            tools: [caller],
            skills: [hotSkill("refunds")],
            mcp: McpRegistry(servers: [McpStdioServer(name: "fs", command: "x")])
        )
        let mcpFactory: MCPTransportFactory = { _ in
            FakeMCPTransport(responses: ["tools/list": #"{"tools":[{"name":"read","inputSchema":{"type":"object"}}]}"#])
        }
        var names: [String] = []
        let agentSession = try await agent.start(config: SessionConfig(), transportFactory: mcpFactory) { cfg in
            names = self.clientToolNames(cfg)
            return try await self.fakeRealtime(cfg)
        }
        #expect(names == ["caller", "load_skill", "mcp__fs__read"])
        await agentSession.end()
    }

    @Test func reservedNamesDropCollidingMcpTool() async throws {
        // The reserved set (caller + skill tool names) must flow into mcp.connect:
        // an MCP tool whose exposed name collides with a caller tool is dropped.
        let caller = SessionConfig.Tool.client(
            name: "mcp__fs__read", description: "d", parameters: ["type": .string("object")], handler: { _ in [:] }
        )
        let agent = try Agent(
            tools: [caller],
            skills: [hotSkill("refunds")],
            mcp: McpRegistry(servers: [McpStdioServer(name: "fs", command: "x")])
        )
        let mcpFactory: MCPTransportFactory = { _ in
            FakeMCPTransport(responses: ["tools/list": #"{"tools":[{"name":"read","inputSchema":{"type":"object"}}]}"#])
        }
        var names: [String] = []
        let s = try await agent.start(config: SessionConfig(), transportFactory: mcpFactory) { cfg in
            names = self.clientToolNames(cfg)
            return try await self.fakeRealtime(cfg)
        }
        #expect(names == ["mcp__fs__read", "load_skill"])  // the MCP read is dropped (name collision)
        await s.end()
    }

    @Test func configToolReservesNameAgainstMcp() async throws {
        // A tool on the config — not just Agent.tools — must reserve its name
        // so a colliding MCP tool is dropped.
        let defaultTool = SessionConfig.Tool.client(
            name: "mcp__fs__read", description: "d", parameters: ["type": .string("object")], handler: { _ in [:] }
        )
        let agent = try Agent(mcp: McpRegistry(servers: [McpStdioServer(name: "fs", command: "x")]))
        let mcpFactory: MCPTransportFactory = { _ in
            FakeMCPTransport(responses: ["tools/list": #"{"tools":[{"name":"read","inputSchema":{"type":"object"}}]}"#])
        }
        var names: [String] = []
        let s = try await agent.start(
            config: SessionConfig(tools: [defaultTool]),
            transportFactory: mcpFactory
        ) { cfg in
            names = self.clientToolNames(cfg)
            return try await self.fakeRealtime(cfg)
        }
        #expect(names == ["mcp__fs__read"])  // inherited tool kept; colliding MCP read dropped
        await s.end()
    }

    @Test func callerToolNamedLoadSkillIsNotDuplicated() async throws {
        // If the caller already declares a `load_skill` tool, the auto-generated
        // skill tool must not add a second entry under the same name.
        let caller = SessionConfig.Tool.client(
            name: loadSkillToolName, description: "caller's own", parameters: ["type": .string("object")], handler: { _ in [:] }
        )
        let agent = try Agent(tools: [caller], skills: [hotSkill("refunds")])
        var names: [String] = []
        let s = try await agent.start(config: SessionConfig(), transportFactory: { _ in FakeMCPTransport() }) { cfg in
            names = self.clientToolNames(cfg)
            return try await self.fakeRealtime(cfg)
        }
        #expect(names == [loadSkillToolName])  // single entry; no duplicate reaches the wire
        await s.end()
    }
}
