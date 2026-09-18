// Tests/CosmoRealtimeTests/MCPConfigTests.swift
import Foundation
import Testing
@testable import CosmoRealtime

/// The code of the ``McpError`` `body` throws.
private func mcpErrorCode(_ body: () throws -> Void) -> McpErrorCode? {
    #expect(throws: McpError.self) { try body() }?.code
}

@Suite("MCP config parsing")
struct MCPConfigTests {
    @Test func parsesStdioServer() throws {
        let json = #"{"mcpServers":{"fs":{"command":"npx","args":["-y","server-fs","/tmp"]}}}"#
        let (servers, skipped) = try parseMcpConfig(json)
        #expect(skipped.isEmpty)
        #expect(servers == [McpStdioServer(name: "fs", command: "npx", args: ["-y", "server-fs", "/tmp"])])
    }

    @Test func parsesEnvAndCwd() throws {
        let json = #"{"mcpServers":{"fs":{"command":"x","env":{"K":"V"},"cwd":"/tmp"}}}"#
        let (servers, _) = try parseMcpConfig(json)
        #expect(servers == [McpStdioServer(name: "fs", command: "x", env: ["K": "V"], cwd: "/tmp")])
    }

    @Test func skipsRemoteEntries() throws {
        let json = #"{"mcpServers":{"local":{"command":"npx","args":["x"]},"r1":{"url":"https://x/mcp"},"r2":{"type":"http","command":"ignored"}}}"#
        let (servers, skipped) = try parseMcpConfig(json)
        #expect(servers.map(\.name) == ["local"])
        #expect(Set(skipped) == ["r1", "r2"])
    }

    @Test func rejectsInvalidJson() {
        #expect(mcpErrorCode { _ = try parseMcpConfig("{not json") } == .invalidJson)
    }

    @Test func rejectsMissingMcpServers() {
        #expect(mcpErrorCode { _ = try parseMcpConfig(#"{"servers":{}}"#) } == .missingServers)
    }

    @Test func rejectsNonObjectServerEntry() {
        #expect(mcpErrorCode { _ = try parseMcpConfig(#"{"mcpServers":{"bad":5}}"#) } == .invalidServerEntry)
    }

    @Test func rejectsServerWithoutCommand() {
        #expect(mcpErrorCode { _ = try parseMcpConfig(#"{"mcpServers":{"bad":{"args":["x"]}}}"#) } == .missingCommand)
    }

    // The four below were silently tolerated before this suite: `args` was
    // coerced through `String(describing:)` and a malformed `env`/`cwd` was
    // dropped by a failed cast, so a server launched without the environment
    // it was configured with and failed later for an unrelated reason.

    @Test func rejectsStringArgs() {
        // A bare string would otherwise iterate per-character into argv.
        #expect(mcpErrorCode { _ = try parseMcpConfig(#"{"mcpServers":{"bad":{"command":"npx","args":"-y pkg"}}}"#) } == .invalidArgs)
    }

    @Test func rejectsNonScalarArgsElements() {
        #expect(mcpErrorCode { _ = try parseMcpConfig(#"{"mcpServers":{"bad":{"command":"npx","args":[{"flag":true}]}}}"#) } == .invalidArgs)
    }

    @Test func rejectsBooleanArgsElements() {
        #expect(mcpErrorCode { _ = try parseMcpConfig(#"{"mcpServers":{"bad":{"command":"npx","args":[true]}}}"#) } == .invalidArgs)
    }

    @Test func coercesNumericArgs() throws {
        let (servers, _) = try parseMcpConfig(#"{"mcpServers":{"ok":{"command":"srv","args":["--port",8080]}}}"#)
        #expect(servers[0].args == ["--port", "8080"])
    }

    @Test func rejectsMalformedEnv() {
        #expect(mcpErrorCode { _ = try parseMcpConfig(#"{"mcpServers":{"bad":{"command":"x","env":"PATH=1"}}}"#) } == .invalidEnv)
        #expect(mcpErrorCode { _ = try parseMcpConfig(#"{"mcpServers":{"bad":{"command":"x","env":{"A":1}}}}"#) } == .invalidEnv)
    }

    @Test func rejectsMalformedCwd() {
        #expect(mcpErrorCode { _ = try parseMcpConfig(#"{"mcpServers":{"bad":{"command":"x","cwd":5}}}"#) } == .invalidCwd)
    }

    @Test func rejectsDuplicateServerNames() {
        // A `.mcp.json` object cannot hold duplicate keys, so this is reachable
        // only by composing sources — `.configFile(url) + [inline]`.
        let servers = [
            McpStdioServer(name: "fs", command: "x"),
            McpStdioServer(name: "fs", command: "y"),
        ]
        #expect(mcpErrorCode { _ = try resolveMcpServers(servers) } == .duplicateServerName)
    }
}

@Suite("MCP config files")
struct MCPConfigFileTests {
    private func withTempDir(_ body: (URL) throws -> Void) throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mcp-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    @Test func readsAConfigFile() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("mcp.json")
            try #"{"mcpServers":{"fs":{"command":"npx"}}}"#.write(to: url, atomically: true, encoding: .utf8)
            #expect(try [McpStdioServer].configFile(url) == [McpStdioServer(name: "fs", command: "npx")])
        }
    }

    @Test func rejectsAPathThatIsNotAFile() throws {
        try withTempDir { dir in
            #expect(mcpErrorCode { _ = try [McpStdioServer].configFile(dir) } == .notAFile)
        }
    }

    @Test func rejectsAnAbsentPath() throws {
        try withTempDir { dir in
            let absent = dir.appendingPathComponent("absent.json")
            #expect(mcpErrorCode { _ = try [McpStdioServer].configFile(absent) } == .notAFile)
        }
    }

    @Test func unreadableFileIsCannotRead() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("mcp.json")
            try #"{"mcpServers":{}}"#.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
            #expect(mcpErrorCode { _ = try [McpStdioServer].configFile(url) } == .cannotRead)
        }
    }

    @Test func configInAnUntraversableDirectoryIsCannotRead() throws {
        // `fileExists` answers false for EACCES exactly as it does for ENOENT,
        // so before the read classified the failure this reported notAFile
        // about a file that is there.
        try withTempDir { dir in
            let walled = dir.appendingPathComponent("walled")
            try FileManager.default.createDirectory(at: walled, withIntermediateDirectories: true)
            let url = walled.appendingPathComponent("mcp.json")
            try #"{"mcpServers":{}}"#.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: walled.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: walled.path) }
            #expect(mcpErrorCode { _ = try [McpStdioServer].configFile(url) } == .cannotRead)
        }
    }

    @Test func nonUtf8FileIsCannotRead() throws {
        // The file is there; its bytes are not text. Reporting notAFile would
        // say the opposite, and Python raised a bare UnicodeDecodeError here.
        try withTempDir { dir in
            let url = dir.appendingPathComponent("mcp.json")
            try #"{"mcpServers":{}}"#.data(using: .utf16)!.write(to: url)
            #expect(mcpErrorCode { _ = try [McpStdioServer].configFile(url) } == .cannotRead)
        }
    }

    @Test func symlinkLoopIsNotAFile() throws {
        // Python's `Path.is_file()` swallows ELOOP and answers false, so this
        // stays notAFile rather than becoming a read failure.
        try withTempDir { dir in
            let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b")
            try FileManager.default.createSymbolicLink(at: a, withDestinationURL: b)
            try FileManager.default.createSymbolicLink(at: b, withDestinationURL: a)
            #expect(mcpErrorCode { _ = try [McpStdioServer].configFile(a) } == .notAFile)
        }
    }

    @Test func malformedDocumentKeepsItsCodeAndNamesTheFile() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("mcp.json")
            try #"{"mcpServers":{"bad":{}}}"#.write(to: url, atomically: true, encoding: .utf8)
            let error = #expect(throws: McpError.self) { _ = try [McpStdioServer].configFile(url) }
            #expect(error?.code == .missingCommand)
            #expect(error?.message.contains(url.path) == true)
        }
    }

    @Test func composesWithInlineServers() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("mcp.json")
            try #"{"mcpServers":{"fs":{"command":"npx"}}}"#.write(to: url, atomically: true, encoding: .utf8)
            let servers = try [McpStdioServer].configFile(url) + [McpStdioServer(name: "inline", command: "x")]
            #expect(servers.map(\.name) == ["fs", "inline"])
        }
    }
}
