// Sources/CosmoRealtime/MCP/McpStdioServer.swift
import Foundation

/// One local MCP server launched over stdio.
public struct McpStdioServer: Sendable, Equatable {
    /// How this server is identified. Must be unique across the agent's
    /// servers, or building the agent throws.
    public let name: String
    /// Executable to launch, spoken to over stdio.
    public let command: String
    /// Arguments passed to that executable.
    public let args: [String]
    /// Environment for the server process. `nil` does not inherit this
    /// process's environment — the MCP client builds a small allowlisted one,
    /// so a credential the server needs has to be passed here explicitly.
    public let env: [String: String]?
    /// Working directory to launch in. `nil` uses this process's.
    public let cwd: String?

    /// Creates a stdio server declaration.
    public init(
        name: String,
        command: String,
        args: [String] = [],
        env: [String: String]? = nil,
        cwd: String? = nil
    ) {
        self.name = name
        self.command = command
        self.args = args
        self.env = env
        self.cwd = cwd
    }
}

/// Stable codes clients match on to tell one MCP failure from another.
///
/// The set is closed: every one is raised by this SDK, never by the server,
/// so it changes only when the SDK does.
public enum McpErrorCode: String, Sendable, Equatable {
    /// The config path does not point at a file.
    case notAFile = "not_a_file"
    /// The config file exists but could not be read or decoded as UTF-8.
    case cannotRead = "cannot_read"
    /// The config file is not valid JSON.
    case invalidJson = "invalid_json"
    /// The config has no `mcpServers` object.
    case missingServers = "missing_servers"
    /// A server entry is not an object.
    case invalidServerEntry = "invalid_server_entry"
    /// A stdio server entry has no `command`.
    case missingCommand = "missing_command"
    /// `args` is not an array of strings or whole numbers.
    case invalidArgs = "invalid_args"
    /// `env` is not an object of string values.
    case invalidEnv = "invalid_env"
    /// `cwd` is not a string.
    case invalidCwd = "invalid_cwd"
    /// Two servers resolved to the same name, so a tool call would be
    /// ambiguous.
    case duplicateServerName = "duplicate_server_name"
    /// The server process could not be launched, or did not complete the MCP
    /// handshake.
    case connectionFailed = "connection_failed"
    /// The server answered in a shape this SDK could not read.
    case invalidResponse = "invalid_response"
    /// The server reported a protocol-level error.
    case serverError = "server_error"
    /// A tool call reached the server and the tool itself failed.
    case toolError = "tool_error"
}

/// An MCP server could not be configured, reached, or called: the config path
/// is not a file, the `.mcp.json` document is malformed, two servers share a
/// name, the connection failed, or a tool reported an error.
///
/// ``code`` names which of those it was — match on it rather than on the
/// message, which is written for a human and is not part of the contract.
public struct McpError: RealtimeError, LocalizedError, Equatable {
    /// Which failure it was. A closed set this SDK raises — switch on it
    /// rather than on the message.
    public let code: McpErrorCode
    /// Human-readable explanation, for logs and display.
    public let message: String

    /// Creates an MCP error.
    public init(code: McpErrorCode, message: String) {
        self.code = code
        self.message = message
    }

    /// The message, for `LocalizedError` presentation.
    /// The message, for `LocalizedError` presentation.
    /// The message, for `LocalizedError` presentation.
    public var errorDescription: String? { message }
}

private let remoteTypes: Set<String> = ["http", "sse"]

/// Parse a Claude-Code `.mcp.json` document. Returns the stdio servers plus
/// the names of remote entries skipped in v1.
///
/// Remote (`http`/`sse`) entries are reported rather than thrown — the file
/// stays shareable with harnesses that support them. Servers come back sorted
/// by name: a JSON object has no order once decoded into a dictionary.
func parseMcpConfig(_ text: String) throws -> (servers: [McpStdioServer], skippedRemote: [String]) {
    let root: JSONValue
    do {
        // Decoded as any JSON value, not as a dictionary: a well-formed
        // document whose root is an array or a scalar has no `mcpServers`,
        // which is a different failure from text that will not parse.
        root = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    } catch {
        throw McpError(
            code: .invalidJson,
            message: "`.mcp.json` is not valid JSON: \(error.localizedDescription)"
        )
    }
    guard case let .object(rootObject) = root,
          case let .object(raw)? = rootObject["mcpServers"]
    else {
        throw McpError(
            code: .missingServers,
            message: "`.mcp.json` must contain an object 'mcpServers'"
        )
    }
    var servers: [McpStdioServer] = []
    var skippedRemote: [String] = []
    for name in raw.keys.sorted() {
        guard case let .object(entry)? = raw[name] else {
            throw McpError(
                code: .invalidServerEntry,
                message: "server \(String(reflecting: name)) must be an object"
            )
        }
        if case let .string(url)? = entry["url"], !url.isEmpty {
            skippedRemote.append(name)
            continue
        }
        if case let .string(type)? = entry["type"], remoteTypes.contains(type) {
            skippedRemote.append(name)
            continue
        }
        guard case let .string(command)? = entry["command"], !command.isEmpty else {
            throw McpError(
                code: .missingCommand,
                message: "server \(String(reflecting: name)) must include a 'command'"
            )
        }
        servers.append(McpStdioServer(
            name: name,
            command: command,
            args: try parseArgs(entry["args"], server: name),
            env: try parseEnv(entry["env"], server: name),
            cwd: try parseCwd(entry["cwd"], server: name)
        ))
    }
    return (servers, skippedRemote)
}

/// An integer is accepted and stringified — a port written unquoted is the
/// common case — but nothing else numeric is. A bool would silently invent a
/// `"true"` argument nobody wrote, and a fractional or out-of-range number has
/// no spelling both SDKs agree on: `1.0` and `1` are indistinguishable once
/// decoded, and an integer past Int64 reaches argv in scientific notation.
/// Quote it and the text passes through untouched.
private func parseArgs(_ value: JSONValue?, server: String) throws -> [String] {
    guard let value, value != .null else { return [] }
    let malformed = McpError(
        code: .invalidArgs,
        message: "server \(String(reflecting: server)) 'args' must be an array of strings or whole numbers"
    )
    guard case let .array(elements) = value else { throw malformed }
    return try elements.map { element in
        switch element {
        case let .string(s): return s
        case let .int(i): return String(i)
        default: throw malformed
        }
    }
}

private func parseEnv(_ value: JSONValue?, server: String) throws -> [String: String]? {
    guard let value, value != .null else { return nil }
    let malformed = McpError(
        code: .invalidEnv,
        message: "server \(String(reflecting: server)) 'env' must be an object of string values"
    )
    guard case let .object(entries) = value else { throw malformed }
    return try entries.mapValues { entry in
        guard case let .string(s) = entry else { throw malformed }
        return s
    }
}

private func parseCwd(_ value: JSONValue?, server: String) throws -> String? {
    guard let value, value != .null else { return nil }
    guard case let .string(cwd) = value else {
        throw McpError(
            code: .invalidCwd,
            message: "server \(String(reflecting: server)) 'cwd' must be a string"
        )
    }
    return cwd
}

extension Array where Element == McpStdioServer {
    /// Servers read from a `.mcp.json` config file, for the `mcp:` argument —
    /// one file describes many servers. Mirrors the Python SDK, where the same
    /// path is handed to `mcp=` directly.
    ///
    ///     let agent = try client.agent(mcp: .configFile(configURL))
    ///     let agent = try client.agent(mcp: .configFile(url) + [inline])
    ///
    /// Remote (`http`/`sse`) entries are skipped with a warning, and a file
    /// yielding no servers returns empty — a config listing only remote
    /// servers is a valid state. A path that is not a file, one that cannot be
    /// read, and a malformed document each throw ``McpError``.
    public static func configFile(_ url: URL) throws -> [McpStdioServer] {
        try loadMcpServers(fromConfigFile: url)
    }
}

/// The file read behind ``Swift/Array/configFile(_:)``.
func loadMcpServers(fromConfigFile url: URL) throws -> [McpStdioServer] {
    var isDir: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
    if exists, isDir.boolValue {
        throw McpError(
            code: .notAFile,
            message: "mcp config path is not a file: \(url.path)"
        )
    }
    // `fileExists` cannot say why it answered false — a config inside a
    // directory the process cannot traverse reads as absent — so the read is
    // what classifies, and whether the path resolved at all separates the two
    // outcomes. A permission wall or bytes that are not UTF-8 is a read
    // failure; a path that does not resolve (absent, a symlink loop) is not a
    // file, which is what Python's `Path.is_file()` reports for the same paths.
    let text: String
    do {
        text = try String(contentsOf: url, encoding: .utf8)
    } catch let error as CocoaError where error.code == .fileReadNoPermission {
        throw McpError(
            code: .cannotRead,
            message: "\(url.path): cannot read: \(error.localizedDescription)"
        )
    } catch where exists {
        throw McpError(
            code: .cannotRead,
            message: "\(url.path): cannot read: not valid UTF-8"
        )
    } catch {
        throw McpError(
            code: .notAFile,
            message: "mcp config path is not a file: \(url.path)"
        )
    }
    let (servers, skippedRemote): ([McpStdioServer], [String])
    do {
        (servers, skippedRemote) = try parseMcpConfig(text)
    } catch let error as McpError {
        throw McpError(code: error.code, message: "\(url.path): \(error.message)")
    }
    for name in skippedRemote {
        McpLog.log.warning("MCP server '\(name)' skipped: remote servers are not supported")
    }
    if servers.isEmpty {
        McpLog.log.warning("No MCP servers found in \(url.path)")
    }
    return servers
}

/// Normalize an `mcp` array — duplicate server names throw when the agent is
/// built, not mid-call.
func resolveMcpServers(_ servers: [McpStdioServer]) throws -> [McpStdioServer] {
    var seen = Set<String>()
    for server in servers {
        guard seen.insert(server.name).inserted else {
            throw McpError(
                code: .duplicateServerName,
                message: "duplicate MCP server name: \(String(reflecting: server.name))"
            )
        }
    }
    return servers
}
