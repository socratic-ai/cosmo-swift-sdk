import Foundation
import LiveKit
import os

// Binds client-tool handlers (the public ``SessionConfig.Tool.client``
// surface carries no transport vocabulary) to the LiveKit RPC transport.
// The agents runtime drives client tools over
// ``localParticipant.registerRpcMethod`` / ``performRpc``: each handler
// becomes an RPC method whose request payload is the JSON-encoded args
// and whose reply is the JSON envelope ``{ok, result, error}``.
//
// Mirrors the reference SDK's ``_client_tools.py`` — keep the two in sync.

private let clientToolLog = Logger(subsystem: CosmoRealtimeLog.subsystem, category: "client-tools")

private let clientToolTruncationSuffix = "… [truncated]"

/// An ``{ok: false}`` envelope whose serialized form fits the size cap,
/// truncating the error text if needed.
func clientToolErrorReply(_ message: String) -> String {
    let envelope = ClientToolReply.envelope(ok: false, error: message)
    if envelope.utf8.count <= ClientToolReply.maxBytes { return envelope }
    // JSON-escaping and the multi-byte suffix make the encoded size hard
    // to predict from the message length, so shrink the kept prefix until
    // the full envelope fits.
    var keep = message.count
    while keep > 0 {
        let truncated = String(message.prefix(keep)) + clientToolTruncationSuffix
        let candidate = ClientToolReply.envelope(ok: false, error: truncated)
        let size = candidate.utf8.count
        if size <= ClientToolReply.maxBytes { return candidate }
        keep -= max(size - ClientToolReply.maxBytes, 1)
    }
    return ClientToolReply.envelope(ok: false, error: clientToolTruncationSuffix)
}

/// Decode the RPC request, run the handler, and build the reply envelope.
/// A non-object args payload, a handler throw, or an oversized success
/// result all map to an ``{ok: false}`` envelope; a successful handler
/// maps to ``{ok: true, result: <object>}``.
/// When ``hooks`` is non-nil and a ``sessionId`` exists, fires
/// ``PreToolUse`` before the handler (and may skip it on deny) and
/// ``PostToolUse`` after (mirrors the reference ``_invoke_handler`` in
/// ``_client_tools.py``, including its skip-without-session-id gate).
func invokeClientToolHandler(
    _ handler: ClientToolHandler,
    tool toolName: String,
    payload: String,
    hooks: HookEngine?,
    sessionId: String?
) async -> String {
    var args: [String: JSONValue]
    if payload.isEmpty {
        args = [:]
    } else {
        guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8)) else {
            clientToolLog.warning("client tool args were not valid JSON tool=\(toolName, privacy: .public)")
            return clientToolErrorReply("client tool args were not valid JSON")
        }
        guard case .object(let object) = decoded else {
            clientToolLog.warning("client tool args must be a JSON object tool=\(toolName, privacy: .public)")
            return clientToolErrorReply("client tool args must be a JSON object")
        }
        args = object
    }

    var argsRewritten = false
    if let hooks, let sessionId {
        let outcome = await hooks.runPreToolUse(toolName: toolName, arguments: args, sessionId: sessionId)
        if outcome.denied {
            let reason = outcome.reason ?? "denied by hook"
            let reply = clientToolErrorReply(reason)
            await hooks.runPostToolUse(PostToolUseContext(
                toolName: toolName,
                arguments: outcome.arguments,
                outcome: .denied(reason),
                sessionId: sessionId
            ))
            return reply
        }
        argsRewritten = outcome.arguments != args
        args = outcome.arguments
    }

    let reply: String
    let toolOutcome: ToolOutcome
    do {
        let result = try await handler(args)
        let envelope = ClientToolReply.envelope(ok: true, result: result)
        if envelope.utf8.count > ClientToolReply.maxBytes {
            clientToolLog.warning("client tool result exceeded the reply size limit tool=\(toolName, privacy: .public)")
            let msg = "client tool result exceeded the reply size limit"
            reply = clientToolErrorReply(msg)
            toolOutcome = .error(msg)
        } else {
            reply = envelope
            toolOutcome = .ok(result)
        }
    } catch {
        clientToolLog.error("client tool handler failed tool=\(toolName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        warnIfHookRewriteBrokeValidation(error, toolName: toolName, argsRewritten: argsRewritten)
        let message = error.localizedDescription.isEmpty
            ? String(describing: type(of: error))
            : error.localizedDescription
        reply = clientToolErrorReply(message)
        toolOutcome = .error(message)
    }

    if let hooks, let sessionId {
        await hooks.runPostToolUse(PostToolUseContext(
            toolName: toolName,
            arguments: args,
            outcome: toolOutcome,
            sessionId: sessionId
        ))
    }
    return reply
}

/// Authorization predicate for a client-tool RPC: only the session's
/// agent participant (``kind == .agent``) whose identity matches the
/// caller may invoke a client tool — they type, click, and read the
/// user's screen, so a non-agent caller is rejected. Pure over a snapshot
/// of the room's remote participants so the security boundary is
/// unit-testable without a live room. Fails closed: an empty snapshot
/// (e.g. the room was torn down) authorizes no one.
func isAuthorizedClientToolCaller(
    callerIdentity: String,
    participants: [(identity: String, isAgent: Bool)]
) -> Bool {
    participants.contains { $0.identity == callerIdentity && $0.isAgent }
}

/// A client tool declared in ``SessionConfig`` could not be bound to the
/// transport. The tool was already advertised to the server, so the start
/// fails closed rather than running with a tool the agent can call but
/// this client cannot service.
struct ClientToolRegistrationError: Error, LocalizedError {
    let tool: String
    let underlying: Error
    var errorDescription: String? {
        "client tool '\(tool)' could not be registered: \(underlying.localizedDescription)"
    }
}

/// Register one RPC method per client tool that carries a handler. Only
/// the session's agent participant may invoke a client tool; an
/// invocation from any non-agent caller is rejected before the handler
/// runs so LiveKit surfaces an error to the caller.
///
/// ``sessionId`` is resolved per invocation, not captured at registration:
/// methods bind before the room joins (closing the join→register race), when
/// the server-minted id may not have arrived yet.
///
/// Throws ``ClientToolRegistrationError`` if any tool fails to bind: the
/// spec is already on the wire in ``session-config``, so failing the start
/// is preferable to advertising a tool whose every invocation would error.
func registerClientToolHandlers(
    on room: Room,
    handlers: [String: ClientToolHandler],
    hooks: HookEngine?,
    sessionId: @escaping @Sendable () async -> String?
) async throws {
    for (name, handler) in handlers {
        do {
            try await room.registerRpcMethod(name) { [weak room] data in
                // Client tools type, click, and read the user's screen —
                // only the session agent may drive them.
                let participants = (room?.remoteParticipants.values).map { values in
                    values.compactMap { p -> (identity: String, isAgent: Bool)? in
                        guard let id = p.identity?.stringValue else { return nil }
                        return (identity: id, isAgent: p.kind == .agent)
                    }
                } ?? []
                let callerIsAgent = isAuthorizedClientToolCaller(
                    callerIdentity: data.callerIdentity.stringValue,
                    participants: participants
                )
                guard callerIsAgent else {
                    clientToolLog.error(
                        "client-tool RPC rejected: caller \(data.callerIdentity.stringValue, privacy: .public) is not the session agent tool=\(name, privacy: .public)"
                    )
                    throw NonAgentRpcCallerError()
                }
                return await invokeClientToolHandler(
                    handler,
                    tool: name,
                    payload: data.payload,
                    hooks: hooks,
                    sessionId: await sessionId()
                )
            }
        } catch {
            clientToolLog.error(
                "client-tool RPC register failed tool=\(name, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            throw ClientToolRegistrationError(tool: name, underlying: error)
        }
        clientToolLog.info("client tool registered tool=\(name, privacy: .public)")
    }
}

/// Thrown from the client-tool RPC handler when the caller is not the session
/// agent — the agent-only caller guard. Relocated from the retired legacy
/// client, which shared the same LiveKit RPC registration path.
struct NonAgentRpcCallerError: Error {}

// MARK: - Background client tools (deferred path)

/// The deferred-ack reply envelope: ``{ok:true, deferred:true, job_id, result:{note}}``.
/// The worker registers the job from ``job_id`` and injects the terminal result
/// (delivered later via ``tool_job_result``) into the live session.
func clientToolDeferredReply(jobId: String, note: String) -> String {
    let object: [String: JSONValue] = [
        "ok": .bool(true),
        "result": .object(note.isEmpty ? [:] : ["note": .string(note)]),
        "error": .null,
        "deferred": .bool(true),
        "job_id": .string(jobId),
    ]
    guard let data = try? JSONEncoder().encode(object) else {
        return #"{"ok":false,"result":null,"error":"reply encode failed"}"#
    }
    return String(decoding: data, as: UTF8.self)
}

private func decodeClientToolArgs(_ payload: String, tool toolName: String) -> [String: JSONValue]? {
    if payload.isEmpty { return [:] }
    guard let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8)) else {
        clientToolLog.warning("client tool args were not valid JSON tool=\(toolName, privacy: .public)")
        return nil
    }
    guard case .object(let object) = decoded else {
        clientToolLog.warning("client tool args must be a JSON object tool=\(toolName, privacy: .public)")
        return nil
    }
    return object
}

/// Drive a background handler: decode, PreToolUse, then run it on a sink-owned
/// task and race two outcomes — the handler calling ``job.ack`` (a deferred
/// reply, the task kept alive) versus the handler finishing/raising before it
/// acks (an error reply now). PostToolUse fires at the terminal signal for a
/// deferred call (in ``ClientToolJob``), or here for a pre-ack failure.
/// Mirrors the reference ``_invoke_deferred_handler`` in ``_client_tools.py``.
func invokeBackgroundClientToolHandler(
    _ handler: @escaping BackgroundClientToolHandler,
    tool toolName: String,
    payload: String,
    sink: ClientToolJobSink,
    hooks: HookEngine?,
    sessionId: String?
) async -> String {
    guard let decoded = decodeClientToolArgs(payload, tool: toolName) else {
        return clientToolErrorReply("client tool args must be a JSON object")
    }
    var args = decoded

    var argsRewritten = false
    if let hooks, let sessionId {
        let outcome = await hooks.runPreToolUse(toolName: toolName, arguments: args, sessionId: sessionId)
        if outcome.denied {
            let reason = outcome.reason ?? "denied by hook"
            await hooks.runPostToolUse(PostToolUseContext(
                toolName: toolName, arguments: outcome.arguments,
                outcome: .denied(reason), sessionId: sessionId
            ))
            return clientToolErrorReply(reason)
        }
        argsRewritten = outcome.arguments != args
        args = outcome.arguments
    }
    let resolvedArgs = args
    let resolvedArgsRewritten = argsRewritten

    let job = ClientToolJob(
        jobId: UUID().uuidString,
        toolName: toolName,
        sink: sink,
        hooks: hooks,
        sessionId: sessionId,
        arguments: resolvedArgs
    )
    await sink.spawn {
        await runBackgroundHandler(
            handler, resolvedArgs, job, tool: toolName, argsRewritten: resolvedArgsRewritten
        )
    }

    switch await job.awaitOutcome() {
    case .acked(let note):
        // Deferred: the task keeps running (the sink owns it); the terminal
        // result + PostToolUse arrive later via job.complete / job.fail.
        clientToolLog.info("client tool deferred tool=\(toolName, privacy: .public) job_id=\(job.jobId, privacy: .public)")
        return clientToolDeferredReply(jobId: job.jobId, note: note)
    case .finishedWithoutAck:
        let message = "background client tool returned without acking or completing"
        clientToolLog.warning("realtime.client_tool_job.finished_without_ack tool=\(toolName, privacy: .public)")
        await firePostToolUse(hooks, sessionId, toolName, resolvedArgs, .error(message))
        return clientToolErrorReply(message)
    case .failedBeforeAck(let message):
        await firePostToolUse(hooks, sessionId, toolName, resolvedArgs, .error(message))
        return clientToolErrorReply(message)
    }
}

/// Run a background handler. A raise after ``ack`` becomes ``job.fail`` (the
/// deferred reply already went out); a raise before ``ack`` — or a clean return
/// without acking — settles the dispatcher's reply race so it can build the
/// inline reply.
private func runBackgroundHandler(
    _ handler: @escaping BackgroundClientToolHandler,
    _ args: [String: JSONValue],
    _ job: ClientToolJob,
    tool toolName: String,
    argsRewritten: Bool
) async {
    do {
        try await handler(args, job)
        await job.settleUnacked(.finishedWithoutAck)
        if await job.acked, await !job.settled {
            // An acked job the handler abandoned (returned without
            // complete/fail): settle it as a failure so the server-side call
            // is not left waiting forever.
            clientToolLog.warning("realtime.client_tool_job.abandoned tool=\(toolName, privacy: .public) job_id=\(job.jobId, privacy: .public)")
            do {
                try await job.fail(error: "background client tool returned without completing")
            } catch {
                clientToolLog.error("realtime.client_tool_job.failure_undeliverable tool=\(toolName, privacy: .public)")
            }
        }
    } catch {
        let message = error.localizedDescription.isEmpty
            ? String(describing: type(of: error))
            : error.localizedDescription
        if await job.acked {
            clientToolLog.error("client tool background handler failed after ack tool=\(toolName, privacy: .public): \(message, privacy: .public)")
            do {
                try await job.fail(error: message)
            } catch {
                // Sink-owned tasks are settle-only: an undeliverable failure
                // result is logged, never rethrown into the tracked task.
                clientToolLog.error("client tool job failure result undeliverable tool=\(toolName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        } else {
            clientToolLog.error("client tool background handler failed before ack tool=\(toolName, privacy: .public): \(message, privacy: .public)")
            warnIfHookRewriteBrokeValidation(error, toolName: toolName, argsRewritten: argsRewritten)
            await job.settleUnacked(.failedBeforeAck(message: message))
        }
    }
}

/// A PreToolUse hook can rewrite valid model args into invalid handler args;
/// the resulting INVALID_INPUT envelope would wrongly tell the model to
/// retry. Only this layer knows a rewrite happened, so surface it as a
/// structured event (the envelope is unchanged).
private func warnIfHookRewriteBrokeValidation(
    _ error: Error,
    toolName: String,
    argsRewritten: Bool
) {
    if argsRewritten, error is ToolInputValidationError {
        clientToolLog.warning("realtime.client_tool_validation_failed_after_hook_rewrite tool=\(toolName, privacy: .public)")
    }
}

private func firePostToolUse(
    _ hooks: HookEngine?,
    _ sessionId: String?,
    _ toolName: String,
    _ args: [String: JSONValue],
    _ outcome: ToolOutcome
) async {
    guard let hooks, let sessionId else { return }
    await hooks.runPostToolUse(PostToolUseContext(
        toolName: toolName, arguments: args, outcome: outcome, sessionId: sessionId
    ))
}

/// Register one RPC method per background client tool, guarded to the session
/// agent, dispatching through the deferred path with ``sink``. ``sessionId``
/// resolves per invocation, like ``registerClientToolHandlers``.
func registerBackgroundClientToolHandlers(
    on room: Room,
    handlers: [String: BackgroundClientToolHandler],
    sink: ClientToolJobSink,
    hooks: HookEngine?,
    sessionId: @escaping @Sendable () async -> String?
) async throws {
    for (name, handler) in handlers {
        do {
            try await room.registerRpcMethod(name) { [weak room] data in
                let participants = (room?.remoteParticipants.values).map { values in
                    values.compactMap { p -> (identity: String, isAgent: Bool)? in
                        guard let id = p.identity?.stringValue else { return nil }
                        return (identity: id, isAgent: p.kind == .agent)
                    }
                } ?? []
                guard isAuthorizedClientToolCaller(
                    callerIdentity: data.callerIdentity.stringValue,
                    participants: participants
                ) else {
                    clientToolLog.error(
                        "client-tool RPC rejected: caller \(data.callerIdentity.stringValue, privacy: .public) is not the session agent tool=\(name, privacy: .public)"
                    )
                    throw NonAgentRpcCallerError()
                }
                return await invokeBackgroundClientToolHandler(
                    handler, tool: name, payload: data.payload,
                    sink: sink, hooks: hooks, sessionId: await sessionId()
                )
            }
        } catch {
            clientToolLog.error(
                "background client-tool RPC register failed tool=\(name, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            throw ClientToolRegistrationError(tool: name, underlying: error)
        }
        clientToolLog.info("background client tool registered tool=\(name, privacy: .public)")
    }
}
