import Foundation

/// One field-level violation on a tool call's arguments. Built from
/// structured fields only — the submitted value never appears here.
public struct ToolInputIssue: Sendable, Equatable {
    /// Dotted path to the offending field (`address.city`, `items[2].sku`), or
    /// `(root)` when the whole argument object was rejected.
    public let path: String
    /// The validator's stable issue code (`key_not_found`, `value_not_found`,
    /// `type_mismatch`, `data_corrupted`).
    public let code: String
    /// The violated constraint (`required`, `expected a string`, …).
    public let constraint: String

    /// One violation, already sanitized.
    public init(path: String, code: String, constraint: String) {
        self.path = path
        self.code = code
        self.constraint = constraint
    }
}

/// The model's arguments failed to decode inside a builder-synthesized tool
/// handler. ``message`` follows the normalized `INVALID_INPUT` shape shared
/// across the SDKs and is built from structured issue fields only — submitted
/// values never appear, in the message or in ``issues``.
public struct ToolInputValidationError: RealtimeError, Sendable, Equatable, LocalizedError {
    /// Every violation found, so a caller can report them all at once
    /// rather than one per round trip.
    public let issues: [ToolInputIssue]
    /// Every violation rendered into one model-facing string.
    public let message: String
    /// The message, for `LocalizedError` presentation.
    public var errorDescription: String? { message }

    init(toolName: String, issues: [ToolInputIssue]) {
        self.issues = issues
        self.message = Self.formatMessage(toolName: toolName, issues: issues)
    }

    private static let maxIssueLines = 5
    private static let maxMessageBytes = 1024

    static func formatMessage(toolName: String, issues: [ToolInputIssue]) -> String {
        let header = "INVALID_INPUT: \(toolName) rejected parameters:"
        let footer = "Fix the input and retry."
        var shown = min(issues.count, maxIssueLines)
        while true {
            var lines = issues.prefix(shown).map { "- \($0.path): \($0.constraint)" }
            let hidden = issues.count - shown
            if hidden > 0 { lines.append("- … and \(hidden) more") }
            let message = ([header] + lines + [footer]).joined(separator: "\n")
            if message.utf8.count <= maxMessageBytes || shown == 0 { return message }
            shown -= 1
        }
    }

    // Issues are derived from the DecodingError's structure only; its
    // debugDescription can embed the submitted value and is never used.
    static func issues(from error: DecodingError) -> [ToolInputIssue] {
        switch error {
        case .keyNotFound(let key, let context):
            return [
                ToolInputIssue(
                    path: path(context.codingPath + [key]),
                    code: "key_not_found",
                    constraint: "required"
                )
            ]
        case .valueNotFound(_, let context):
            return [
                ToolInputIssue(
                    path: path(context.codingPath),
                    code: "value_not_found",
                    constraint: "required"
                )
            ]
        case .typeMismatch(let type, let context):
            return [
                ToolInputIssue(
                    path: path(context.codingPath),
                    code: "type_mismatch",
                    constraint: "expected \(typeWord(type))"
                )
            ]
        case .dataCorrupted(let context):
            return [
                ToolInputIssue(
                    path: path(context.codingPath),
                    code: "data_corrupted",
                    constraint: "not an allowed value"
                )
            ]
        @unknown default:
            return [ToolInputIssue(path: "(root)", code: "unknown", constraint: "invalid")]
        }
    }

    private static func path(_ codingPath: [CodingKey]) -> String {
        var parts: [String] = []
        for key in codingPath {
            if let index = key.intValue {
                parts.append("[\(index)]")
            } else if parts.isEmpty {
                parts.append(key.stringValue)
            } else {
                parts.append(".\(key.stringValue)")
            }
        }
        return parts.isEmpty ? "(root)" : parts.joined()
    }

    private static func typeWord(_ type: Any.Type) -> String {
        if type == String.self { return "a string" }
        if type == Bool.self { return "a boolean" }
        if type == Int.self || type == Int8.self || type == Int16.self
            || type == Int32.self || type == Int64.self || type == UInt.self
        {
            return "an integer"
        }
        if type == Double.self || type == Float.self { return "a number" }
        let name = String(describing: type)
        if name.hasPrefix("Array") { return "an array" }
        if name.hasPrefix("Dictionary") { return "an object" }
        return "a \(name)"
    }
}

private let toolNamePattern = "^[a-z][a-z0-9_]{2,63}$"
private let toolMaxDescriptionLength = 2048

func decodeToolArguments<Args: Decodable>(
    _ args: [String: JSONValue], toolName: String
) throws -> Args {
    let data = try JSONEncoder().encode(JSONValue.object(args))
    do {
        return try JSONDecoder().decode(Args.self, from: data)
    } catch let error as DecodingError {
        throw ToolInputValidationError(
            toolName: toolName, issues: ToolInputValidationError.issues(from: error)
        )
    }
}

extension AgentTool {
    /// Build a ``client(name:description:parameters:handler:)`` tool whose
    /// handler receives typed arguments: the incoming args are decoded into
    /// `Args` via `JSONDecoder` before user code runs, and a decode failure
    /// becomes a ``ToolInputValidationError`` whose sanitized `INVALID_INPUT`
    /// message the dispatch layer reports to the model.
    ///
    /// This is typed decoding, not schema inference: `input` and `Args` are
    /// written separately and nothing forces them to agree — pin the pair
    /// with ``ToolSchemaConsistencyCheck`` in your unit tests. A schema
    /// `default` is model guidance only (`Decodable` does not apply it; an
    /// omitted field decodes as `nil` — fall back in code, `args.unit ?? .c`),
    /// and schema bounds are not runtime-enforced.
    ///
    /// Throws ``ToolDefinitionError`` at construction
    /// for a declaration the server would reject at session start.
    static func define<Args: Decodable & Sendable>(
        name: String,
        description: String,
        input: ToolSchema,
        handler: @escaping @Sendable (Args) async throws -> [String: JSONValue]
    ) throws -> AgentTool {
        let parameters = try validatedParameters(name: name, description: description, input: input)
        return .client(
            name: name,
            description: description,
            parameters: parameters,
            handler: { args in
                try await handler(decodeToolArguments(args, toolName: name))
            }
        )
    }

    /// The ``backgroundClient(name:description:parameters:handler:)`` variant
    /// of ``define(name:description:input:handler:)``: same declaration
    /// checks and typed decoding, with the handler driving a
    /// ``ClientToolJob`` (`ack` / `complete` / `fail`).
    static func defineBackground<Args: Decodable & Sendable>(
        name: String,
        description: String,
        input: ToolSchema,
        handler: @escaping @Sendable (Args, ClientToolJob) async throws -> Void
    ) throws -> AgentTool {
        let parameters = try validatedParameters(name: name, description: description, input: input)
        return .backgroundClient(
            name: name,
            description: description,
            parameters: parameters,
            handler: { args, job in
                try await handler(decodeToolArguments(args, toolName: name), job)
            }
        )
    }

    private static func validatedParameters(
        name: String, description: String, input: ToolSchema
    ) throws -> [String: JSONValue] {
        guard name.range(of: toolNamePattern, options: .regularExpression) != nil else {
            throw ToolDefinitionError(
                code: .invalidToolName,
                message: "tool name '\(name)' must match \(toolNamePattern)"
            )
        }
        guard !description.isEmpty else {
            throw ToolDefinitionError(
                code: .missingDescription,
                message: "tool '\(name)' has no description — the description is model-facing and required"
            )
        }
        guard description.count <= toolMaxDescriptionLength else {
            throw ToolDefinitionError(
                code: .descriptionTooLong,
                message: "tool '\(name)' description is \(description.count) characters; "
                    + "the protocol limit is \(toolMaxDescriptionLength)"
            )
        }
        if let reason = ClientToolSchemaDialect.textViolation(description, allowNewlines: true) {
            throw ToolDefinitionError(
                code: .invalidText, message: "tool '\(name)' description \(reason)"
            )
        }
        do {
            return try ClientToolSchemaDialect.checkedParameters(input.lowered())
        } catch let error as ToolDefinitionError {
            throw ToolDefinitionError(code: error.code, message: "\(name): \(error.message)")
        }
    }
}

/// Test helper for tool authors: verifies that schema-derived sample
/// arguments decode into `Args`, catching the drift `Tool.define` cannot —
/// the schema and the `Decodable` type are written separately, so a schema
/// declaring `"city": .string` next to `let city: Int` would fail every
/// model-valid call at runtime. Run it in your own unit tests for each
/// defined tool. Two samples are checked: required-only (catches a field the
/// schema leaves optional but the type requires) and all-properties.
public enum ToolSchemaConsistencyCheck {
    /// Check a schema against the type it is meant to decode into, throwing
    /// ``ToolDefinitionError`` when they disagree. Two samples are tried: required-only,
    /// which catches a field the schema leaves optional but the type
    /// requires, and all-properties.
    public static func verify<Args: Decodable>(
        input: ToolSchema, decodesInto _: Args.Type
    ) throws {
        guard case .object = input.node else {
            throw ToolDefinitionError(code: .schemaTypeMismatch, message: "input must be a top-level .object schema")
        }
        for includeOptional in [false, true] {
            let sample = input.sampleValue(includeOptionalProperties: includeOptional)
            let data = try JSONEncoder().encode(sample)
            do {
                _ = try JSONDecoder().decode(Args.self, from: data)
            } catch {
                let kind = includeOptional ? "all-properties" : "required-only"
                throw ToolDefinitionError(
                    code: .schemaTypeMismatch,
                    message: "schema-derived \(kind) sample "
                        + String(decoding: data, as: UTF8.self)
                        + " does not decode into \(Args.self): \(error)"
                )
            }
        }
    }
}
