import Foundation
import Testing
@testable import CosmoRealtime

/// Executes the shared hook-engine vectors
/// (``sdks/cosmo-realtime/contract/hook-engine-vectors.json``): scripted
/// hooks are registered on the real ``HookRegistry`` and the fold/dispatch
/// outcome is asserted. Python and TypeScript run the same file, so an
/// engine-semantics drift fails CI in whichever SDK disagrees.
@Suite struct HookEngineConformanceTests {

    private struct DenySpec: Decodable, Sendable {
        let reason: String?
    }

    private struct ScriptedHook: Decodable, Sendable {
        let matcher: String?
        let context: String?
        let none: Bool?
        let throwFlag: Bool?
        let deny: DenySpec?
        let mergeArguments: [String: String]?
        let allow: Bool?

        enum CodingKeys: String, CodingKey {
            case matcher, context, none, deny, mergeArguments, allow
            case throwFlag = "throw"
        }
    }

    private struct SessionStartExpect: Decodable { let context: String?; let invoked: [Int] }
    private struct SessionStartVector: Decodable {
        let name: String
        let hooks: [ScriptedHook]
        let expect: SessionStartExpect
    }

    private struct PreCall: Decodable { let tool: String; let args: [String: String] }
    private struct PreExpect: Decodable {
        let denied: Bool
        let reason: String?
        let arguments: [String: String]
        let invoked: [Int]
    }
    private struct PreVector: Decodable {
        let name: String
        let hooks: [ScriptedHook]
        let call: PreCall
        let expect: PreExpect
    }

    private struct PostCall: Decodable { let tool: String }
    private struct PostExpect: Decodable { let invoked: [Int] }
    private struct PostVector: Decodable {
        let name: String
        let hooks: [ScriptedHook]
        let call: PostCall
        let expect: PostExpect
    }

    private struct VectorFile: Decodable {
        let sessionStart: [SessionStartVector]
        let preToolUse: [PreVector]
        let postToolUse: [PostVector]
    }

    private struct Scripted: Error {}

    private actor Recorder {
        private(set) var invoked: [Int] = []
        func record(_ index: Int) { invoked.append(index) }
    }

    private static func loadVectors() throws -> VectorFile {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // CosmoRealtimeTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // swift/
            .deletingLastPathComponent()  // cosmo-realtime/
            .appendingPathComponent("contract/hook-engine-vectors.json", isDirectory: false)
        return try JSONDecoder().decode(VectorFile.self, from: Data(contentsOf: url))
    }

    @Test func sessionStartFoldConformsToSharedVectors() async throws {
        let file = try Self.loadVectors()
        #expect(!file.sessionStart.isEmpty)
        for vector in file.sessionStart {
            var registry: [Hook] = []
            let recorder = Recorder()
            for (index, spec) in vector.hooks.enumerated() {
                registry.append(sessionStart { _ in
                    await recorder.record(index)
                    if spec.throwFlag == true { throw Scripted() }
                    if let context = spec.context {
                        return SessionStartResult(additionalContext: context)
                    }
                    return nil
                })
            }
            let result = await HookEngine(registry).runSessionStart()
            #expect(result == vector.expect.context, "vector \(vector.name)")
            #expect(await recorder.invoked == vector.expect.invoked, "vector \(vector.name)")
        }
    }

    @Test func preToolUseFoldConformsToSharedVectors() async throws {
        let file = try Self.loadVectors()
        #expect(!file.preToolUse.isEmpty)
        for vector in file.preToolUse {
            var registry: [Hook] = []
            let recorder = Recorder()
            for (index, spec) in vector.hooks.enumerated() {
                registry.append(try preToolUse(matcher: spec.matcher) { ctx in
                    await recorder.record(index)
                    if spec.throwFlag == true { throw Scripted() }
                    if let deny = spec.deny {
                        return PreToolUseResult(permission: .deny, reason: deny.reason)
                    }
                    if let merge = spec.mergeArguments {
                        var args = ctx.arguments
                        for (key, value) in merge { args[key] = .string(value) }
                        return PreToolUseResult(updatedArguments: args)
                    }
                    if spec.allow == true {
                        return PreToolUseResult(permission: .allow)
                    }
                    return nil
                })
            }
            let args = Dictionary(
                uniqueKeysWithValues: vector.call.args.map { ($0.key, JSONValue.string($0.value)) }
            )
            let outcome = await HookEngine(registry).runPreToolUse(
                toolName: vector.call.tool, arguments: args, sessionId: "vec"
            )
            let expectedArgs = Dictionary(
                uniqueKeysWithValues: vector.expect.arguments.map { ($0.key, JSONValue.string($0.value)) }
            )
            #expect(outcome.denied == vector.expect.denied, "vector \(vector.name)")
            #expect(outcome.reason == vector.expect.reason, "vector \(vector.name)")
            #expect(outcome.arguments == expectedArgs, "vector \(vector.name)")
            #expect(await recorder.invoked == vector.expect.invoked, "vector \(vector.name)")
        }
    }

    @Test func postToolUseDispatchConformsToSharedVectors() async throws {
        let file = try Self.loadVectors()
        #expect(!file.postToolUse.isEmpty)
        for vector in file.postToolUse {
            var registry: [Hook] = []
            let recorder = Recorder()
            for (index, spec) in vector.hooks.enumerated() {
                registry.append(try postToolUse(matcher: spec.matcher) { _ in
                    await recorder.record(index)
                    if spec.throwFlag == true { throw Scripted() }
                })
            }
            await HookEngine(registry).runPostToolUse(PostToolUseContext(
                toolName: vector.call.tool,
                arguments: [:],
                outcome: .ok([:]),
                sessionId: "vec"
            ))
            #expect(await recorder.invoked == vector.expect.invoked, "vector \(vector.name)")
        }
    }
}
