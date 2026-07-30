import Foundation
import Testing
@testable import CosmoRealtime

@Suite("Client-tool dispatch")
struct ClientToolDispatchTests {

    private func decode(_ envelope: String) -> [String: JSONValue] {
        guard
            case .object(let fields)? = try? JSONDecoder().decode(
                JSONValue.self, from: Data(envelope.utf8)
            )
        else {
            Issue.record("reply envelope was not a JSON object: \(envelope)")
            return [:]
        }
        return fields
    }

    @Test("a successful handler maps to {ok: true, result}")
    func successEnvelope() async {
        let handler: ClientToolHandler = { args in
            #expect(args["q"] == .string("now"))
            return ["iso": .string("2026-06-23T10:00:00Z")]
        }
        let reply = await invokeClientToolHandler(
            handler, tool: "test_tool", payload: #"{"q":"now"}"#, hooks: nil, sessionId: nil
        )
        let fields = decode(reply)
        #expect(fields["ok"] == .bool(true))
        #expect(fields["result"] == .object(["iso": .string("2026-06-23T10:00:00Z")]))
        #expect(fields["error"] == .null)
    }

    @Test("an empty payload runs the handler with empty args")
    func emptyPayloadIsEmptyArgs() async {
        let handler: ClientToolHandler = { args in
            #expect(args.isEmpty)
            return ["ok": .bool(true)]
        }
        let fields = decode(await invokeClientToolHandler(
            handler, tool: "test_tool", payload: "", hooks: nil, sessionId: nil
        ))
        #expect(fields["ok"] == .bool(true))
    }

    @Test("non-JSON args fail closed without running the handler")
    func nonJsonArgs() async {
        let handler: ClientToolHandler = { _ in
            Issue.record("handler must not run on undecodable args")
            return [:]
        }
        let fields = decode(await invokeClientToolHandler(
            handler, tool: "test_tool", payload: "not json", hooks: nil, sessionId: nil
        ))
        #expect(fields["ok"] == .bool(false))
        if case .string(let message)? = fields["error"] {
            #expect(message.contains("valid JSON"))
        } else {
            Issue.record("expected an error string")
        }
    }

    @Test("non-object args fail closed")
    func nonObjectArgs() async {
        let handler: ClientToolHandler = { _ in [:] }
        let fields = decode(await invokeClientToolHandler(
            handler, tool: "test_tool", payload: "[1,2,3]", hooks: nil, sessionId: nil
        ))
        #expect(fields["ok"] == .bool(false))
        if case .string(let message)? = fields["error"] {
            #expect(message.contains("JSON object"))
        } else {
            Issue.record("expected an error string")
        }
    }

    @Test("a throwing handler maps to {ok: false, error}")
    func throwingHandler() async {
        struct ToolError: Error, LocalizedError {
            var errorDescription: String? { "tool blew up" }
        }
        let handler: ClientToolHandler = { _ in throw ToolError() }
        let fields = decode(await invokeClientToolHandler(
            handler, tool: "test_tool", payload: "{}", hooks: nil, sessionId: nil
        ))
        #expect(fields["ok"] == .bool(false))
        #expect(fields["error"] == .string("tool blew up"))
    }

    @Test("an oversized success result fails closed as an error reply")
    func oversizedResult() async {
        let big = String(repeating: "x", count: 20 * 1024)
        let handler: ClientToolHandler = { _ in ["blob": .string(big)] }
        let fields = decode(await invokeClientToolHandler(
            handler, tool: "test_tool", payload: "{}", hooks: nil, sessionId: nil
        ))
        #expect(fields["ok"] == .bool(false))
        if case .string(let message)? = fields["error"] {
            #expect(message.contains("reply size limit"))
        } else {
            Issue.record("expected an error string")
        }
    }

    @Test("only the matching agent participant may invoke a client tool")
    func callerGuardAuthorizesOnlyTheAgent() {
        // The agent whose identity matches the caller is authorized.
        #expect(
            isAuthorizedClientToolCaller(
                callerIdentity: "agent-1",
                participants: [("agent-1", true)]
            )
        )
        // A matching identity that is not an agent is rejected.
        #expect(
            !isAuthorizedClientToolCaller(
                callerIdentity: "human-1",
                participants: [("human-1", false)]
            )
        )
        // No participants (e.g. room torn down) authorizes no one.
        #expect(!isAuthorizedClientToolCaller(callerIdentity: "agent-1", participants: []))
        // An agent is present but the caller is a different identity.
        #expect(
            !isAuthorizedClientToolCaller(
                callerIdentity: "human-1",
                participants: [("agent-1", true)]
            )
        )
        // The caller identity matches a NON-agent while a different agent
        // exists — must not authorize (the same participant must be both
        // the caller and an agent).
        #expect(
            !isAuthorizedClientToolCaller(
                callerIdentity: "shared",
                participants: [("shared", false), ("agent-1", true)]
            )
        )
        // Mixed room: the matching agent among several participants is
        // authorized.
        #expect(
            isAuthorizedClientToolCaller(
                callerIdentity: "agent-1",
                participants: [("human-1", false), ("agent-1", true), ("human-2", false)]
            )
        )
    }

    @Test("an oversized error message is truncated to fit the reply cap")
    func errorTruncation() {
        let reply = clientToolErrorReply(String(repeating: "e", count: 30 * 1024))
        #expect(reply.utf8.count <= 15 * 1024)
        let fields = decode(reply)
        #expect(fields["ok"] == .bool(false))
        if case .string(let message)? = fields["error"] {
            #expect(message.hasSuffix("… [truncated]"))
        } else {
            Issue.record("expected a truncated error string")
        }
    }

    // MARK: – Hook integration

    @Test("PreToolUse deny skips handler and PostToolUse fires with .denied")
    func hookDenySkipsHandlerAndFiresPostDenied() async throws {
        let handlerCalled = CaptureBox<Bool>()
        let handler: ClientToolHandler = { _ in
            await handlerCalled.set(true)
            return [:]
        }
        let postOutcomeBox = CaptureBox<ToolOutcome>()
        var registry: [Hook] = []
        registry.append(try preToolUse { _ in PreToolUseResult(permission: .deny, reason: "blocked") })
        registry.append(try postToolUse { ctx in await postOutcomeBox.set(ctx.outcome) })

        let fields = decode(await invokeClientToolHandler(
            handler, tool: "my_tool", payload: "{}", hooks: HookEngine(registry), sessionId: "s1"
        ))
        #expect(fields["ok"] == .bool(false))
        if case .string(let msg)? = fields["error"] {
            #expect(msg == "blocked")
        } else {
            Issue.record("expected error string 'blocked'")
        }
        #expect(await handlerCalled.value == nil)
        let postOutcome = await postOutcomeBox.value
        #expect(postOutcome == .denied("blocked"))
    }

    @Test("PreToolUse rewrite reaches handler with updated args")
    func hookRewriteReachesHandler() async throws {
        let receivedArgsBox = CaptureBox<[String: JSONValue]>()
        let handler: ClientToolHandler = { args in
            await receivedArgsBox.set(args)
            return [:]
        }
        var registry: [Hook] = []
        registry.append(try preToolUse { ctx in
            var args = ctx.arguments
            args["injected"] = .string("yes")
            return PreToolUseResult(updatedArguments: args)
        })

        _ = await invokeClientToolHandler(
            handler, tool: "my_tool", payload: #"{"original":true}"#, hooks: HookEngine(registry), sessionId: "s1"
        )
        let received = await receivedArgsBox.value
        #expect(received?["injected"] == .string("yes"))
        #expect(received?["original"] == .bool(true))
    }

    @Test("successful call fires PostToolUse with .ok(result)")
    func hookPostToolUseSuccess() async throws {
        let handler: ClientToolHandler = { _ in ["answer": .string("42")] }
        let postOutcomeBox = CaptureBox<ToolOutcome>()
        var registry: [Hook] = []
        registry.append(try postToolUse { ctx in await postOutcomeBox.set(ctx.outcome) })

        _ = await invokeClientToolHandler(
            handler, tool: "my_tool", payload: "{}", hooks: HookEngine(registry), sessionId: "s1"
        )
        let outcome = await postOutcomeBox.value
        if case .ok(let result)? = outcome {
            #expect(result?["answer"] == .string("42"))
        } else {
            Issue.record("expected .ok outcome, got \(String(describing: outcome))")
        }
    }

    @Test("oversized result fires PostToolUse with .error (not .ok)")
    func hookPostToolUseOversizedIsError() async throws {
        let big = String(repeating: "x", count: 20 * 1024)
        let handler: ClientToolHandler = { _ in ["blob": .string(big)] }
        let postOutcomeBox = CaptureBox<ToolOutcome>()
        var registry: [Hook] = []
        registry.append(try postToolUse { ctx in await postOutcomeBox.set(ctx.outcome) })

        let fields = decode(await invokeClientToolHandler(
            handler, tool: "my_tool", payload: "{}", hooks: HookEngine(registry), sessionId: "s1"
        ))
        #expect(fields["ok"] == .bool(false))
        let outcome = await postOutcomeBox.value
        if case .error(let msg)? = outcome {
            #expect(msg.contains("reply size limit"))
        } else {
            Issue.record("expected .error outcome for oversized result, got \(String(describing: outcome))")
        }
    }

    @Test("nil hooks does not change behavior (no-hooks path)")
    func nilHooksNoChange() async {
        let handler: ClientToolHandler = { _ in ["val": .bool(true)] }
        let fields = decode(await invokeClientToolHandler(
            handler, tool: "my_tool", payload: "{}", hooks: nil, sessionId: nil
        ))
        #expect(fields["ok"] == .bool(true))
    }

    @Test("hooks are skipped when there is no session id")
    func hooksSkippedWithoutSessionId() async throws {
        let handlerCalled = CaptureBox<Bool>()
        let handler: ClientToolHandler = { _ in
            await handlerCalled.set(true)
            return [:]
        }
        let preFired = CaptureBox<Bool>()
        var registry: [Hook] = []
        registry.append(try preToolUse { _ in
            await preFired.set(true)
            return PreToolUseResult(permission: .deny, reason: "blocked")
        })

        let fields = decode(await invokeClientToolHandler(
            handler, tool: "my_tool", payload: "{}", hooks: HookEngine(registry), sessionId: nil
        ))

        #expect(fields["ok"] == .bool(true))
        #expect(await handlerCalled.value == true)
        #expect(await preFired.value == nil)
    }
}
