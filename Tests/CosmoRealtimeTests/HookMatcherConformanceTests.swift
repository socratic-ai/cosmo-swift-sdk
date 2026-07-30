import Foundation
import Testing
@testable import CosmoRealtime

/// Executes the shared hook-matcher conformance vectors
/// (``sdks/cosmo-realtime/contract/hook-matcher-vectors.json``) against the
/// Swift matcher. The Python suite consumes the same file, so both SDKs pin
/// one normative grammar.
@Suite struct HookMatcherConformanceTests {
    private struct VectorFile: Decodable {
        struct Vector: Decodable {
            let pattern: String
            let name: String
            let matches: Bool
        }
        struct RegistrationVector: Decodable {
            let pattern: String
            let outcome: String
        }
        let vectors: [Vector]
        let registrationVectors: [RegistrationVector]
    }

    @Test func matcherConformsToSharedVectors() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // CosmoRealtimeTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // swift/
            .deletingLastPathComponent()  // cosmo-realtime/
            .appendingPathComponent("contract/hook-matcher-vectors.json", isDirectory: false)
        let file = try JSONDecoder().decode(VectorFile.self, from: Data(contentsOf: url))
        #expect(!file.vectors.isEmpty)
        for vector in file.vectors {
            #expect(
                toolNameMatches(vector.name, vector.pattern) == vector.matches,
                "pattern \(vector.pattern.debugDescription) vs name \(vector.name.debugDescription): expected matches=\(vector.matches)"
            )
        }
    }

    @Test func registrationValidationConformsToSharedVectors() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // CosmoRealtimeTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // swift/
            .deletingLastPathComponent()  // cosmo-realtime/
            .appendingPathComponent("contract/hook-matcher-vectors.json", isDirectory: false)
        let file = try JSONDecoder().decode(VectorFile.self, from: Data(contentsOf: url))
        #expect(!file.registrationVectors.isEmpty)
        for vector in file.registrationVectors {
            var registry: [Hook] = []
            if vector.outcome == "reject" {
                #expect(throws: MalformedHookMatcherError.self, "pattern \(vector.pattern.debugDescription)") {
                    registry.append(try preToolUse(matcher: vector.pattern) { _ in nil })
                }
            } else {
                registry.append(try preToolUse(matcher: vector.pattern) { _ in nil })
            }
        }
    }
}
