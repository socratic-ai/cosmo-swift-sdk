import Foundation
import OSLog

enum McpLog {
    static let log = Logger(subsystem: CosmoRealtimeLog.subsystem, category: "mcp")
}

typealias MCPTransportFactory = @Sendable (McpStdioServer) throws -> MCPTransport

/// A per-session live MCP handle: the proxy tools and idempotent teardown of
/// every server connection.
actor ConnectedMcp {
    let tools: [AgentTool]
    let skipped: [SkippedTool]
    private let connections: [MCPConnection]
    private var closed = false

    init(tools: [AgentTool], skipped: [SkippedTool], connections: [MCPConnection]) {
        self.tools = tools
        self.skipped = skipped
        self.connections = connections
    }

    func aclose() async {
        if closed { return }
        closed = true
        for connection in connections { await connection.close() }
    }
}

/// Open every server, list + build tools, and return a cleanup-safe handle. A
/// server that fails to start is skipped rather than failing the session.
func connectMcp(
    _ servers: [McpStdioServer],
    reservedNames: Set<String>,
    transportFactory: MCPTransportFactory
) async -> ConnectedMcp {
    var connections: [MCPConnection] = []
    var built: [BuiltServer] = []
    for server in servers {
        let transport: MCPTransport
        do {
            transport = try transportFactory(server)
        } catch {
            McpLog.log.warning("MCP server '\(server.name)' (command: \(server.command), args: \(server.args.count)) skipped: transport failed: \(error)")
            continue
        }
        let connection = MCPConnection(transport: transport, serverName: server.name)
        do {
            try await connection.initialize()
            let listed = try await connection.listTools()
            connections.append(connection)
            built.append(BuiltServer(name: server.name, tools: listed, call: { name, argsJSON in
                try await connection.callTool(name: name, argsJSON: argsJSON)
            }))
        } catch {
            McpLog.log.warning("MCP server '\(server.name)' (command: \(server.command), args: \(server.args.count)) skipped: initialization failed: \(error)")
            await connection.close()
        }
    }
    let (tools, skipped) = buildMCPTools(built, reservedNames: reservedNames)
    return ConnectedMcp(tools: tools, skipped: skipped, connections: connections)
}
