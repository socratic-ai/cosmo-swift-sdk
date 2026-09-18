import Foundation

/// A tool declaration is invalid — a bad name, a missing or overlong
/// description, or an input schema that cannot be expressed in the restricted
/// dialect the realtime backend accepts.
///
/// Thrown when the tool is constructed, never at session connect. ``code``
/// names which — switch on it rather than matching the message.
public struct ToolDefinitionError: RealtimeError, Sendable, Equatable, LocalizedError {
    /// What is wrong with the declaration. A closed set this SDK raises —
    /// switch on it.
    public let code: ToolDefinitionErrorCode
    /// What was rejected, naming the offending key, depth or field.
    public let message: String

    /// A rejection with the given code and explanation.
    public init(code: ToolDefinitionErrorCode, message: String) {
        self.code = code
        self.message = message
    }

    /// The code and message, for `LocalizedError` presentation.
    public var errorDescription: String? { "\(code.rawValue): \(message)" }
}

/// Mirrors the backend's restricted JSON-schema dialect for client-declared
/// tools. A declaration whose `parametersJSON` carries a key outside this set
/// is rejected at the backend and **dropped** — the model never sees the
/// tool. The interpretation (depth counted from 1 at the top-level node, a
/// global property cap) is pinned against the shared cross-SDK schema
/// vectors; a mismatch here means the backend has changed and this mirror
/// must be updated.
enum ClientToolSchemaDialect {
    static let allowedKeys: Set<String> = [
        "type", "properties", "required", "items", "enum",
        "description", "anyOf", "default", "maxLength", "minLength",
        "maximum", "minimum",
    ]

    static let allowedTypes: Set<String> = [
        "object", "string", "number", "integer", "boolean", "array", "null",
    ]

    static let maxDepth = 6
    static let maxProperties = 64

    private static let numericKeys: Set<String> = [
        "maxLength", "minLength", "maximum", "minimum",
    ]

    /// The first sanitization violation in `value`, or `nil` if clean.
    /// Mirrors the backend's `text_sanitize`: control characters and forged
    /// `---` prompt-section fences are rejected there, so catch them at
    /// construction instead of at connect.
    static func textViolation(_ value: String, allowNewlines: Bool) -> String? {
        for scalar in value.unicodeScalars {
            if scalar.value == 0x7F
                || (scalar.value < 0x20 && !(allowNewlines && scalar.value == 0x0A))
            {
                return "contains a control character"
            }
        }
        for line in value.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("---") {
                return "contains a prompt section delimiter"
            }
        }
        return nil
    }

    /// Strict builder pipeline for an authored schema: normalize (drop
    /// `title`/`$schema`, drop `additionalProperties: true`, rewrite `const`
    /// as a one-value `enum`) → dialect check. `additionalProperties: false`
    /// and schema-valued `additionalProperties` throw — dropping them would
    /// tell the model extra keys are fine while validation rejects them.
    /// Returns the wire-ready parameters object.
    static func checkedParameters(_ schema: [String: JSONValue]) throws -> [String: JSONValue] {
        guard case .object(let normalized) = try normalize(.object(schema)) else {
            throw ToolDefinitionError(code: .nodeNotObject, message: "schema node is not an object")
        }
        guard normalized["type"] == .string("object") else {
            throw ToolDefinitionError(
                code: .topLevelNotObject,
                message: "parameters must declare top-level type 'object'"
            )
        }
        var propertyCount = 0
        try checkNode(.object(normalized), depth: 1, propertyCount: &propertyCount)
        return normalized
    }

    /// The first dialect violation in `schemaJSON`, or `nil` if it is legal.
    /// Walks the schema the way the backend does: every key of a schema node must
    /// be allowed, `type` must be an allowed type, and `properties` / `items` /
    /// `anyOf` recurse into their child schemas. Property *names* are arbitrary
    /// and are not checked against the keyword allowlist.
    static func firstViolation(inSchemaJSON schemaJSON: String) -> String? {
        guard let parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(schemaJSON.utf8)) else {
            return "schema is not valid JSON"
        }
        var propertyCount = 0
        do {
            try checkNode(parsed, depth: 1, propertyCount: &propertyCount)
            return nil
        } catch {
            return (error as? ToolDefinitionError)?.message ?? String(describing: error)
        }
    }

    private static func normalize(_ node: JSONValue) throws -> JSONValue {
        switch node {
        case .array(let items):
            return .array(try items.map(normalize))
        case .object(let object):
            var out: [String: JSONValue] = [:]
            var constValue: JSONValue?
            for (key, value) in object {
                switch key {
                case "title", "$schema":
                    continue
                case "additionalProperties":
                    if value == .bool(true) { continue }
                    let detail = value == .bool(false)
                        ? "'additionalProperties: false' (a strict/extra-forbid schema)"
                        : "schema-valued 'additionalProperties' (a map type)"
                    throw ToolDefinitionError(
                        code: .additionalPropertiesForbidden,
                        message: "\(detail) cannot be expressed in the tool-schema dialect"
                    )
                case "const":
                    constValue = value
                case "properties":
                    if case .object(let properties) = value {
                        out[key] = .object(try properties.mapValues(normalize))
                    } else {
                        out[key] = value
                    }
                case "items":
                    out[key] = try normalize(value)
                case "anyOf":
                    if case .array(let variants) = value {
                        out[key] = .array(try variants.map(normalize))
                    } else {
                        out[key] = value
                    }
                default:
                    out[key] = value
                }
            }
            if let constValue, out["enum"] == nil { out["enum"] = .array([constValue]) }
            return .object(out)
        default:
            return node
        }
    }

    private static func checkNode(
        _ node: JSONValue, depth: Int, propertyCount: inout Int
    ) throws {
        guard depth <= maxDepth else {
            throw ToolDefinitionError(
                code: .maxDepthExceeded,
                message: "schema nesting exceeds depth \(maxDepth)"
            )
        }
        guard case .object(let object) = node else {
            throw ToolDefinitionError(code: .nodeNotObject, message: "schema node is not an object")
        }
        for (key, value) in object {
            guard allowedKeys.contains(key) else {
                throw ToolDefinitionError(
                    code: .forbiddenKey, message: "schema key '\(key)' is not allowed"
                )
            }
            switch key {
            case "type":
                guard case .string(let type) = value else {
                    throw ToolDefinitionError(
                        code: .forbiddenType, message: "schema 'type' is not a string"
                    )
                }
                guard allowedTypes.contains(type) else {
                    throw ToolDefinitionError(
                        code: .forbiddenType, message: "schema type '\(type)' is not allowed"
                    )
                }
            case "description":
                guard case .string(let text) = value else {
                    throw ToolDefinitionError(
                        code: .invalidText, message: "schema description is not a string"
                    )
                }
                if let reason = textViolation(text, allowNewlines: true) {
                    throw ToolDefinitionError(
                        code: .invalidText, message: "schema description \(reason)"
                    )
                }
            case "required":
                guard case .array(let items) = value,
                    items.allSatisfy({ if case .string = $0 { return true } else { return false } })
                else {
                    throw ToolDefinitionError(
                        code: .invalidRequired,
                        message: "schema 'required' is not a list of strings"
                    )
                }
            case "enum":
                guard case .array(let items) = value, items.allSatisfy(isScalar) else {
                    throw ToolDefinitionError(
                        code: .invalidEnum, message: "schema 'enum' is not a list of scalars"
                    )
                }
            case "properties":
                guard case .object(let properties) = value else {
                    throw ToolDefinitionError(
                        code: .invalidProperties,
                        message: "schema 'properties' is not an object"
                    )
                }
                propertyCount += properties.count
                guard propertyCount <= maxProperties else {
                    throw ToolDefinitionError(
                        code: .maxPropertiesExceeded,
                        message: "schema exceeds \(maxProperties) properties"
                    )
                }
                for (name, child) in properties {
                    if textViolation(name, allowNewlines: false) != nil {
                        throw ToolDefinitionError(
                            code: .invalidText,
                            message: "schema property name is not a clean string"
                        )
                    }
                    try checkNode(child, depth: depth + 1, propertyCount: &propertyCount)
                }
            case "items":
                try checkNode(value, depth: depth + 1, propertyCount: &propertyCount)
            case "anyOf":
                guard case .array(let variants) = value else {
                    throw ToolDefinitionError(
                        code: .invalidAnyOf, message: "schema 'anyOf' is not a list"
                    )
                }
                for variant in variants {
                    try checkNode(variant, depth: depth + 1, propertyCount: &propertyCount)
                }
            case "default":
                switch value {
                case .string(let text):
                    if let reason = textViolation(text, allowNewlines: false) {
                        throw ToolDefinitionError(
                            code: .invalidText, message: "schema default \(reason)"
                        )
                    }
                case .int, .double, .bool, .null:
                    break
                case .array, .object:
                    throw ToolDefinitionError(
                        code: .invalidDefault, message: "schema 'default' must be a scalar"
                    )
                }
            default:
                if numericKeys.contains(key) {
                    switch value {
                    case .int, .double:
                        break
                    default:
                        throw ToolDefinitionError(
                            code: .invalidBound, message: "schema '\(key)' is not a number"
                        )
                    }
                }
            }
        }
    }

    private static func isScalar(_ value: JSONValue) -> Bool {
        switch value {
        case .string, .int, .double, .bool: return true
        case .null, .array, .object: return false
        }
    }
}

/// What is wrong with a tool declaration.
///
/// Closed: every one is raised when a tool is constructed, so it changes only
/// when the SDK does. Every member is declared in every SDK even where that
/// SDK cannot reach the case, so a branch written against one ports unchanged.
public enum ToolDefinitionErrorCode: String, Sendable, Equatable {
    /// ``additionalProperties`` is set to a value the dialect refuses.
    case additionalPropertiesForbidden = "additional_properties_forbidden"
    /// The schema uses a keyword the dialect does not accept — `$ref`, `format`, `oneOf`, `pattern` and friends.
    case forbiddenKey = "forbidden_key"
    /// The schema declares a type outside the accepted set.
    case forbiddenType = "forbidden_type"
    /// `anyOf` is present but is not a list of schemas.
    case invalidAnyOf = "invalid_any_of"
    /// A numeric bound (`minimum`, `maxLength`, …) is not a number.
    case invalidBound = "invalid_bound"
    /// `default` is present but is not a scalar.
    case invalidDefault = "invalid_default"
    /// `enum` is present but its members are not scalars.
    case invalidEnum = "invalid_enum"
    /// `properties` is present but is not a map of names to schemas.
    case invalidProperties = "invalid_properties"
    /// `required` is not a list of property names.
    case invalidRequired = "invalid_required"
    /// A description or other model-facing string carries a control character. Also raised for the tool's own description.
    case invalidText = "invalid_text"
    /// The schema nests deeper than the dialect allows.
    case maxDepthExceeded = "max_depth_exceeded"
    /// The schema declares more properties than the dialect allows.
    case maxPropertiesExceeded = "max_properties_exceeded"
    /// A nested schema node is not an object.
    case nodeNotObject = "node_not_object"
    /// The schema refers to itself. Not raised by this SDK, whose walker cannot reach the case, but declared so a `switch` ports unchanged.
    case recursiveSchema = "recursive_schema"
    /// The top-level schema is not an object. A tool's input is always a set of named parameters.
    case topLevelNotObject = "top_level_not_object"
    /// The tool's name does not match the required pattern.
    case invalidToolName = "invalid_tool_name"
    /// The tool has no description. It is model-facing and required.
    case missingDescription = "missing_description"
    /// The tool's description is longer than the protocol allows.
    case descriptionTooLong = "description_too_long"
    /// A schema and the type it decodes into disagree, found by ``ToolSchemaConsistencyCheck``.
    case schemaTypeMismatch = "schema_type_mismatch"
}
