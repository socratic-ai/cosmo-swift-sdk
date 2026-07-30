import Foundation
import Testing
@testable import CosmoRealtime

/// Executes the shared client-tool schema-dialect vectors
/// (``sdks/cosmo-realtime/contract/client-tool-schema-vectors.json``) against
/// the Swift construction-time pipeline (normalize → dialect check). The
/// backend gate and the Python suite consume the same file, so every
/// implementation pins one normative dialect interpretation.
@Suite struct ToolSchemaConformanceTests {
    private struct VectorFile: Decodable {
        struct Valid: Decodable {
            let name: String
            let schema: JSONValue
            let normalized: JSONValue?
        }
        struct Invalid: Decodable {
            let name: String
            let schema: JSONValue
            let errorCode: String
        }
        let valid: [Valid]
        let invalid: [Invalid]
    }

    private static func loadVectors() throws -> VectorFile {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // CosmoRealtimeTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // swift/
            .deletingLastPathComponent()  // cosmo-realtime/
            .appendingPathComponent("contract/client-tool-schema-vectors.json", isDirectory: false)
        return try JSONDecoder().decode(VectorFile.self, from: Data(contentsOf: url))
    }

    @Test func pipelineAcceptsValidVectorsAndEmitsNormalizedForm() throws {
        let vectors = try Self.loadVectors()
        #expect(!vectors.valid.isEmpty)
        for entry in vectors.valid {
            guard case .object(let schema) = entry.schema else {
                Issue.record("\(entry.name): vector schema is not a JSON object")
                continue
            }
            let emitted = try ClientToolSchemaDialect.checkedParameters(schema)
            #expect(JSONValue.object(emitted) == (entry.normalized ?? entry.schema), "\(entry.name)")
        }
    }

    @Test func pipelineRejectsInvalidVectorsWithNamedCode() throws {
        let vectors = try Self.loadVectors()
        #expect(!vectors.invalid.isEmpty)
        for entry in vectors.invalid {
            guard case .object(let schema) = entry.schema else {
                Issue.record("\(entry.name): vector schema is not a JSON object")
                continue
            }
            do {
                _ = try ClientToolSchemaDialect.checkedParameters(schema)
                Issue.record("\(entry.name): expected rejection with code \(entry.errorCode)")
            } catch let error as ToolSchemaError {
                #expect(error.code == entry.errorCode, "\(entry.name)")
            }
        }
    }
}
