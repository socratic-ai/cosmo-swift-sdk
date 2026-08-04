import Foundation
import Testing
@testable import CosmoRealtime

/// Executes the shared SDK-client-tool vectors
/// (``sdks/cosmo-realtime/contract/sdk-client-tool-vectors.json``) against the
/// Swift renderers. A locator's description names the renderer it feeds, so
/// the three SDKs have to declare the same names, the same model-facing text,
/// and the same schemas — a divergence breaks the locate-then-draw chain on
/// one surface only, which is invisible from any single SDK's tests.
/// TypeScript: ``src/tool/__tests__/draw.test.ts``.
@Suite("SDK client-tool contract vectors")
struct SDKClientToolConformanceTests {
    private struct VectorFile: Decodable {
        /// One tool's reply shapes. A renderer answers in its own vocabulary
        /// (`clicked` vs `shown`) and only the region spotlight reports where
        /// its mark landed, so every field is optional here and each tool's
        /// case reads the ones it owns.
        struct Outcome: Decodable {
            let shown: Bool?
            let clicked: Bool?
            let reason: String?
            let landedExactly: Bool?
        }
        struct Reply: Decodable {
            let name: String
            let outcome: Outcome
            let result: JSONValue
        }
        struct DecodeCase: Decodable {
            let name: String
            let args: [String: JSONValue]
            let request: JSONValue
        }
        struct Tool: Decodable {
            let name: String
            let description: String
            let parameters: JSONValue
            let decode: [DecodeCase]
            /// Absent when the tool answers in the file-level shape.
            let reply: [Reply]?
        }
        let reservedPrefix: String
        let reply: [Reply]
        let tools: [Tool]
    }

    private static func loadVectors() throws -> VectorFile {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // CosmoRealtimeTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // swift/
            .deletingLastPathComponent()  // cosmo-realtime/
            .appendingPathComponent("contract/sdk-client-tool-vectors.json", isDirectory: false)
        return try JSONDecoder().decode(VectorFile.self, from: Data(contentsOf: url))
    }

    private static func declaration(named name: String) -> DeclaredClientTool? {
        switch name {
        case DrawBoxTool.name: return DrawBoxTool.declaredTool()
        case DrawPointTool.name: return DrawPointTool.declaredTool()
        case ScreenClickTool.name: return ScreenClickTool.declaredTool()
        case ScreenHighlightTool.name: return ScreenHighlightTool.declaredTool()
        case HighlightRegionTool.name: return HighlightRegionTool.declaredTool()
        default: return nil
        }
    }

    @Test("every vector tool is declared with the pinned text and schema")
    func declarationsMatchTheVectors() throws {
        let vectors = try Self.loadVectors()
        #expect(!vectors.tools.isEmpty)
        for tool in vectors.tools {
            guard let declared = Self.declaration(named: tool.name) else {
                Issue.record("\(tool.name): no Swift declaration for this vector tool")
                continue
            }
            #expect(declared.name == tool.name)
            #expect(declared.description == tool.description, "\(tool.name) description")
            let parameters = try JSONDecoder().decode(
                JSONValue.self, from: Data(declared.parametersJSON.utf8)
            )
            #expect(parameters == tool.parameters, "\(tool.name) parameters")
        }
    }

    @Test("the SDK's own tools live under the reserved prefix")
    func namesCarryTheReservedPrefix() throws {
        let vectors = try Self.loadVectors()
        #expect(SessionConfig.sdkToolNamePrefix == vectors.reservedPrefix)
        for tool in vectors.tools {
            #expect(tool.name.hasPrefix(vectors.reservedPrefix))
        }
    }

    @Test("model arguments decode — or are rejected — the same way everywhere")
    func decodeMatchesTheVectors() throws {
        let vectors = try Self.loadVectors()
        for tool in vectors.tools {
            #expect(!tool.decode.isEmpty, "\(tool.name) has no decode vectors")
            for vector in tool.decode {
                let label = "\(tool.name): \(vector.name)"
                let expected = vector.request
                switch tool.name {
                case DrawBoxTool.name:
                    let decoded = DrawBoxTool.request(from: vector.args)
                    guard case let .object(fields) = expected else {
                        #expect(decoded == nil, "\(label)")
                        continue
                    }
                    #expect(decoded?.box == NormalizedBox(json: fields["box"]), "\(label)")
                    #expect(decoded?.label == fields["label"]?.asString, "\(label)")
                case DrawPointTool.name:
                    let decoded = DrawPointTool.request(from: vector.args)
                    guard case let .object(fields) = expected else {
                        #expect(decoded == nil, "\(label)")
                        continue
                    }
                    #expect(decoded?.point == NormalizedPoint(json: fields["point"]), "\(label)")
                    #expect(decoded?.label == fields["label"]?.asString, "\(label)")
                case ScreenClickTool.name:
                    let decoded = ScreenClickTool.request(from: vector.args)
                    guard case let .object(fields) = expected else {
                        #expect(decoded == nil, "\(label)")
                        continue
                    }
                    #expect(decoded?.ref == ScreenRef.decode(fields["ref"]), "\(label)")
                    #expect(
                        decoded?.action.button.rawValue == fields["button"]?.asString, "\(label)")
                    #expect(decoded?.action.double == fields["double"]?.asBool, "\(label)")
                case ScreenHighlightTool.name:
                    let decoded = ScreenHighlightTool.request(from: vector.args)
                    guard case let .object(fields) = expected else {
                        #expect(decoded == nil, "\(label)")
                        continue
                    }
                    #expect(decoded?.ref == ScreenRef.decode(fields["ref"]), "\(label)")
                    #expect(decoded?.label == fields["label"]?.asString, "\(label)")
                    #expect(decoded?.placement.rawValue == fields["placement"]?.asString, "\(label)")
                    #expect(
                        decoded?.affordance.rawValue == fields["interaction"]?.asString, "\(label)")
                case HighlightRegionTool.name:
                    let decoded = HighlightRegionTool.request(from: vector.args)
                    guard case let .object(fields) = expected else {
                        #expect(decoded == nil, "\(label)")
                        continue
                    }
                    #expect(decoded?.region == ScreenRegion(json: fields["region"]), "\(label)")
                    #expect(decoded?.label == fields["label"]?.asString, "\(label)")
                    #expect(decoded?.element == ScreenElementHint(json: fields["element"]), "\(label)")
                    #expect(decoded?.placement.rawValue == fields["placement"]?.asString, "\(label)")
                    #expect(
                        decoded?.affordance.rawValue == fields["interaction"]?.asString, "\(label)")
                default:
                    Issue.record("\(tool.name): no Swift decoder for this vector tool")
                }
            }
        }
    }

    @Test("an outcome reaches the model in the pinned shape")
    func repliesMatchTheVectors() throws {
        let vectors = try Self.loadVectors()
        #expect(!vectors.reply.isEmpty)
        for vector in vectors.reply {
            let outcome: DrawOutcome =
                vector.outcome.shown == true ? .shown : .notShown(vector.outcome.reason ?? "")
            #expect(JSONValue.object(outcome.toolResult) == vector.result, "\(vector.name)")
        }
        for tool in vectors.tools {
            guard let replies = tool.reply else { continue }
            #expect(!replies.isEmpty, "\(tool.name) declares an empty reply set")
            for vector in replies {
                let label = "\(tool.name): \(vector.name)"
                let result: [String: JSONValue]
                switch tool.name {
                case ScreenClickTool.name:
                    let outcome: ScreenClickOutcome =
                        vector.outcome.clicked == true
                        ? .clicked : .notClicked(vector.outcome.reason ?? "")
                    result = outcome.toolResult
                case ScreenHighlightTool.name:
                    let outcome: DrawOutcome =
                        vector.outcome.shown == true
                        ? .shown : .notShown(vector.outcome.reason ?? "")
                    result = outcome.toolResult
                case HighlightRegionTool.name:
                    let outcome: HighlightRegionOutcome
                    if vector.outcome.shown == true {
                        outcome =
                            vector.outcome.landedExactly == true ? .landedExactly : .landedOnEstimate
                    } else {
                        outcome = .notShown(vector.outcome.reason ?? "")
                    }
                    result = outcome.toolResult
                default:
                    Issue.record("\(tool.name): no Swift outcome for this vector tool")
                    continue
                }
                #expect(JSONValue.object(result) == vector.result, "\(label)")
            }
        }
    }
}

private extension JSONValue {
    var asString: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var asBool: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }
}

private extension ScreenRegion {
    /// The vectors nest the box under `region`; absent means the case expects
    /// no decoded request at all, which the caller has already handled.
    init?(json: JSONValue?) {
        guard case let .object(fields)? = json,
            let x = fields["x"]?.asDouble, let y = fields["y"]?.asDouble,
            let width = fields["width"]?.asDouble, let height = fields["height"]?.asDouble
        else { return nil }
        self.init(x: x, y: y, width: width, height: height)
    }
}

private extension ScreenElementHint {
    init?(json: JSONValue?) {
        guard case let .object(fields)? = json, let title = fields["title"]?.asString
        else { return nil }
        self.init(title: title, role: fields["role"]?.asString)
    }
}

private extension JSONValue {
    var asDouble: Double? {
        switch self {
        case let .double(value): return value
        case let .int(value): return Double(value)
        default: return nil
        }
    }
}
