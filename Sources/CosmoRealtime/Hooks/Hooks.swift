#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import os

// MARK: - Outcome + Permission

/// How one client-tool call finished, as ``PostToolUse`` sees it. Switch on
/// the case — a denial is not an error.
public enum ToolOutcome: Sendable, Equatable {
    /// The tool ran and returned.
    case ok(result: [String: JSONValue]?)
    /// The tool threw, or the client reported a failure.
    case error(message: String)
    /// A ``preToolUse(matcher:handler:)`` hook refused the call, so the tool
    /// never ran.
    case denied(reason: String)
}

/// A ``PreToolUse`` hook's verdict on a tool call. Returning no permission
/// abstains and leaves the decision to the other hooks; any deny wins.
public enum HookPermission: Sendable, Equatable {
    /// State no objection to the call. Does not override another hook's deny.
    case allow
    /// Block the call. The handler never runs and the model is told why.
    case deny
}

// MARK: - Contexts

/// Passed to a ``sessionStart(handler:)`` hook, which runs before the session
/// config is sent. There is no session id yet — read it off ``ready``.
public struct SessionStartContext: Sendable {
    /// Names the seam, so one handler can serve several events.
    public let event: String = "SessionStart"

    /// Creates a context. The SDK builds these; you receive one.
    public init() {}
}

/// Passed to a ``preToolUse(matcher:handler:)`` hook, before the local handler
/// runs. Return a ``PreToolUseResult`` to deny the call or rewrite its
/// arguments.
public struct PreToolUseContext: Sendable {
    /// Names the seam, so one handler can serve several events.
    public let event: String = "PreToolUse"
    /// The tool about to run — what a matcher is tested against.
    public let toolName: String
    /// The model's arguments. Rewrite them by returning
    /// ``PreToolUseResult/updatedArguments``, not by mutating a copy.
    public let arguments: [String: JSONValue]
    /// The session the call belongs to.
    public let sessionId: String

    /// Creates a context. The SDK builds these; you receive one.
    public init(toolName: String, arguments: [String: JSONValue], sessionId: String) {
        self.toolName = toolName
        self.arguments = arguments
        self.sessionId = sessionId
    }
}

/// Passed to a ``postToolUse(matcher:handler:)`` hook once the local handler
/// settled. Observer-only: it cannot change the result. It is awaited before
/// the reply goes back to the model, so a slow hook delays the tool call —
/// keep it quick, or hand the work off.
public struct PostToolUseContext: Sendable {
    /// Names the seam, so one handler can serve several events.
    public let event: String = "PostToolUse"
    /// The tool that ran.
    public let toolName: String
    /// The arguments it ran with, after any ``PreToolUse`` rewrite.
    public let arguments: [String: JSONValue]
    /// How it finished. Switch on it — a denial is not an error.
    public let outcome: ToolOutcome
    /// The session the call belonged to.
    public let sessionId: String

    /// Creates a context. The SDK builds these; you receive one.
    public init(toolName: String, arguments: [String: JSONValue], outcome: ToolOutcome, sessionId: String) {
        self.toolName = toolName
        self.arguments = arguments
        self.outcome = outcome
        self.sessionId = sessionId
    }
}

/// Why a session reached its terminal state, as reported on
/// ``SessionEndContext``. Raw values are the cross-SDK reason slugs.
public enum DisconnectReason: String, Sendable, Equatable {
    /// This side ended the session deliberately, telling the server to tear
    /// down.
    case clientEnded = "client_ended"
    /// This side dropped the local half without telling the server — an
    /// explicit close, or a start cancelled before it finished.
    case clientClosed = "client_closed"
    /// The session never reached ready. Covers a refused start — the server
    /// rejecting session-start, or a local pre-flight check — and also any
    /// server or transport close before readiness, a failed room join and a
    /// ready timeout included: every pre-ready ending reports this reason.
    case handshakeFailed = "handshake_failed"
    /// The server ended it — a duration or silence cap, or its own teardown.
    case serverEnded = "server_ended"
    /// The media connection failed, either underneath a live session or on a
    /// join that never succeeded.
    case transportError = "transport_error"
}

/// Passed to a ``sessionEnd(handler:)`` hook at teardown, on every exit path.
public struct SessionEndContext: Sendable {
    /// Names the seam, so one handler can serve several events.
    public let event: String = "SessionEnd"
    /// Why the session ended — who ended it, and whether cleanly.
    public let reason: DisconnectReason
    /// Extra context on the ending when the server or transport supplied any.
    public let detail: String?
    /// The session that ended, or `nil` if it never became live.
    public let sessionId: String?

    /// Creates a context. The SDK builds these; you receive one.
    public init(reason: DisconnectReason, detail: String?, sessionId: String?) {
        self.reason = reason
        self.detail = detail
        self.sessionId = sessionId
    }
}

// MARK: - Results

/// What a ``sessionStart(handler:)`` hook may return to add context before
/// the session opens.
public struct SessionStartResult: Sendable {
    /// Text to add to the agent's instructions. Several hooks returning
    /// context are joined in registration order. Applies to an inline agent
    /// only — a catalog agent runs its stored config verbatim, so context
    /// returned here is dropped.
    public let additionalContext: String?

    /// Creates a result carrying context to inject.
    public init(additionalContext: String? = nil) {
        self.additionalContext = additionalContext
    }
}

/// What a ``preToolUse(matcher:handler:)`` hook may return. Return nothing to
/// let the call through unchanged.
public struct PreToolUseResult: Sendable {
    /// Deny to block the call, allow to state no objection. `nil` abstains
    /// and leaves the decision to the other hooks; any deny wins.
    public let permission: HookPermission?
    /// Why it was denied — surfaced to the model so it can say something
    /// useful instead of retrying blindly.
    public let reason: String?
    /// Replacement arguments for the call. `nil` leaves them untouched; the
    /// last hook to rewrite wins.
    public let updatedArguments: [String: JSONValue]?

    /// Creates a result. Every field is optional; omitting all of them is the
    /// same as returning nothing.
    public init(
        permission: HookPermission? = nil,
        reason: String? = nil,
        updatedArguments: [String: JSONValue]? = nil
    ) {
        self.permission = permission
        self.reason = reason
        self.updatedArguments = updatedArguments
    }
}

// MARK: - Hook typealiases

/// A hook run before the transport connects — which is what lets its return
/// value reach the agent. Return context to prepend to the agent's
/// instructions for this run, or `nil` to add nothing.
public typealias SessionStartHook = @Sendable (SessionStartContext) async throws -> SessionStartResult?
/// A hook run before a tool executes. Return a result to deny the call or
/// rewrite its arguments, or `nil` to let it proceed unchanged.
public typealias PreToolUseHook   = @Sendable (PreToolUseContext)   async throws -> PreToolUseResult?
/// An observer run after a tool returns. It cannot change the result.
public typealias PostToolUseHook  = @Sendable (PostToolUseContext)  async throws -> Void
/// An observer run once when the session ends, whatever ended it.
public typealias SessionEndHook         = @Sendable (SessionEndContext)         async throws -> Void

// MARK: - Declared hooks + the seam factories

/// One declared hook for the agent's unified ``hooks: [Hook]`` list — an
/// in-process client hook built by a seam factory (list order is fold
/// order), or a declarative server hook the SERVER executes
/// (``Hook/server(_:)`` wrapping a ``SilenceTimeout``).
public struct Hook: Sendable {
    enum Callback: Sendable {
        case sessionStart(SessionStartHook)
        case preToolUse(matcher: String?, PreToolUseHook)
        case postToolUse(matcher: String?, PostToolUseHook)
        case sessionEnd(SessionEndHook)
        case server(SilenceTimeout)
    }

    let callback: Callback

    /// A declarative server hook: wire config the server executes even if
    /// this process dies mid-call.
    public static func server(_ hook: SilenceTimeout) -> Hook {
        Hook(callback: .server(hook))
    }
}

/// Declare a ``SessionStart`` hook — may return a ``SessionStartResult`` to
/// inject ``additionalContext`` into the instructions.
public func sessionStart(_ hook: @escaping SessionStartHook) -> Hook {
    Hook(callback: .sessionStart(hook))
}

/// Declare a ``PreToolUse`` hook — may deny or rewrite a local client-tool
/// call. ``matcher`` restricts it to matching tool names (glob grammar); a
/// malformed matcher throws here, not at session start.
public func preToolUse(matcher: String? = nil, _ hook: @escaping PreToolUseHook) throws -> Hook {
    if let matcher { try validateMatcher(matcher) }
    return Hook(callback: .preToolUse(matcher: matcher, hook))
}

/// Declare a ``PostToolUse`` observer, fired with the final ``ToolOutcome``
/// of each local client-tool call.
public func postToolUse(matcher: String? = nil, _ hook: @escaping PostToolUseHook) throws -> Hook {
    if let matcher { try validateMatcher(matcher) }
    return Hook(callback: .postToolUse(matcher: matcher, hook))
}

/// Declare a ``SessionEnd`` observer, fired exactly once at teardown.
public func sessionEnd(_ hook: @escaping SessionEndHook) -> Hook {
    Hook(callback: .sessionEnd(hook))
}

/// Split one unified list into the in-process client hooks (an engine) and
/// the server hooks (wire config).
func splitHooks(_ hooks: [Hook]) -> (engine: HookEngine?, server: [SilenceTimeout]) {
    var server: [SilenceTimeout] = []
    var client: [Hook] = []
    for hook in hooks {
        if case .server(let s) = hook.callback { server.append(s) } else { client.append(hook) }
    }
    return (client.isEmpty ? nil : HookEngine(client), server)
}

// MARK: - HookEngine

private let log = Logger(subsystem: CosmoRealtimeLog.subsystem, category: "hooks")

// Every hook event blocks a session seam (see the design doc's firing-seams
// section) — a hook slower than this is user-visible, so surface it.
private let slowHookWarnThreshold: Duration = .milliseconds(200)

private func warnIfSlow<R>(
    _ event: StaticString,
    tool: String? = nil,
    _ body: () async throws -> R
) async rethrows -> R {
    let start = ContinuousClock.now
    defer {
        let elapsed = ContinuousClock.now - start
        if elapsed >= slowHookWarnThreshold {
            let ms = Int((elapsed / .milliseconds(1)).rounded())
            log.warning("slow \(event, privacy: .public) hook: \(ms)ms tool=\(tool ?? "-", privacy: .public)")
        }
    }
    return try await body()
}

/// Dispatch engine over one agent's declared client hooks. Immutable —
/// built from the resolved ``Hook`` list; fold semantics are pinned by the
/// shared hook-engine vectors.
struct HookEngine: Sendable {
    private var sessionStart: [SessionStartHook] = []
    private var preToolUse: [(matcher: String?, hook: PreToolUseHook)] = []
    private var postToolUse: [(matcher: String?, hook: PostToolUseHook)] = []
    private var sessionEnd: [SessionEndHook] = []

    init(_ hooks: [Hook]) {
        for hook in hooks {
            switch hook.callback {
            case .sessionStart(let h): sessionStart.append(h)
            case .preToolUse(let matcher, let h): preToolUse.append((matcher: matcher, hook: h))
            case .postToolUse(let matcher, let h): postToolUse.append((matcher: matcher, hook: h))
            case .sessionEnd(let h): sessionEnd.append(h)
            case .server: continue
            }
        }
    }

    // MARK: Run methods (called by session/dispatch wiring)

    func runSessionStart() async -> String? {
        let ctx = SessionStartContext()
        var parts: [String] = []
        for hook in sessionStart {
            do {
                if let result = try await warnIfSlow("sessionStart", { try await hook(ctx) }),
                   let text = result.additionalContext,
                   !text.isEmpty {
                    parts.append(text)
                }
            } catch {
                log.error("sessionStart hook threw: \(error, privacy: .public)")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    func runPreToolUse(
        toolName: String,
        arguments: [String: JSONValue],
        sessionId: String
    ) async -> PreToolUseOutcome {
        var current = arguments
        for entry in preToolUse {
            guard toolNameMatches(toolName, entry.matcher) else { continue }
            let ctx = PreToolUseContext(toolName: toolName, arguments: current, sessionId: sessionId)
            do {
                guard let result = try await warnIfSlow("preToolUse", tool: toolName, { try await entry.hook(ctx) }) else { continue }
                if result.permission == .deny {
                    // Empty-string reason folds to the default, matching the
                    // reference's `reason or "denied by hook"`.
                    let reason = result.reason.flatMap { $0.isEmpty ? nil : $0 } ?? "denied by hook"
                    log.info("preToolUse hook denied tool \(toolName, privacy: .public): \(reason, privacy: .public)")
                    return PreToolUseOutcome(denied: true, reason: reason, arguments: current)
                }
                if let updated = result.updatedArguments {
                    current = updated
                }
            } catch {
                log.error("preToolUse hook threw for \(toolName, privacy: .public): \(error, privacy: .public)")
            }
        }
        return PreToolUseOutcome(denied: false, reason: nil, arguments: current)
    }

    func runPostToolUse(_ ctx: PostToolUseContext) async {
        for entry in postToolUse {
            guard toolNameMatches(ctx.toolName, entry.matcher) else { continue }
            do {
                try await warnIfSlow("postToolUse", tool: ctx.toolName) { try await entry.hook(ctx) }
            } catch {
                log.error("postToolUse hook threw for \(ctx.toolName, privacy: .public): \(error, privacy: .public)")
            }
        }
    }

    func runSessionEnd(_ ctx: SessionEndContext) async {
        for hook in sessionEnd {
            do {
                try await warnIfSlow("sessionEnd") { try await hook(ctx) }
            } catch {
                log.error("sessionEnd hook threw: \(error, privacy: .public)")
            }
        }
    }
}

// MARK: - Internal outcome type

struct PreToolUseOutcome: Sendable {
    let denied: Bool
    let reason: String?
    let arguments: [String: JSONValue]
}

// MARK: - Matcher

/// Why a hook could not be registered.
///
/// Closed: every one is thrown when hooks are declared, so it changes only
/// when the SDK does. Every member is declared in every SDK even where that
/// SDK cannot reach the case, so a branch written against one ports unchanged.
public enum HookErrorCode: String, Sendable, Equatable {
    /// The matcher pattern does not parse — an unterminated `[` group.
    /// `fnmatch(3)` never errors on one, it just silently matches nothing,
    /// which for a deny matcher is a guard that never fires.
    case malformedMatcher = "malformed_matcher"
    /// A `hooks` element is neither a hook built by a seam factory nor a
    /// server hook. Not thrown by this SDK, whose type system rejects it
    /// first, but declared so a branch ports unchanged.
    case invalidHook = "invalid_hook"
    /// A server hook was passed to a catalog agent, which runs its stored
    /// configuration verbatim.
    case serverHookNotAllowed = "server_hook_not_allowed"
}

/// A hook could not be registered.
///
/// ``HookErrorCode/malformedMatcher`` and ``HookErrorCode/invalidHook`` are
/// thrown where the hook is declared — a matcher that would never fire is
/// refused up front rather than silently matching nothing.
/// ``HookErrorCode/serverHookNotAllowed`` is thrown when the session config
/// is assembled, which in this SDK is during ``RealtimeAgent/start``.
/// ``code`` names which — switch on it rather than matching the message.
public struct HookError: RealtimeError, LocalizedError, Sendable, Equatable {
    /// Why the hook was refused. A closed set this SDK throws — switch on it.
    public let code: HookErrorCode
    /// Human-readable explanation, for logs and display.
    public let message: String

    /// A hook rejection with its cross-SDK code and message.
    public init(code: HookErrorCode, message: String) {
        self.code = code
        self.message = message
    }

    /// The code and message, for `LocalizedError` presentation.
    public var errorDescription: String? { "\(code.rawValue): \(message)" }
}

/// Reject an unterminated ``[...]`` group at hook-registration time.
///
/// ``fnmatch(3)`` never errors on a malformed pattern — it treats a stray
/// ``[`` as a literal character, so e.g. ``matcher: "[delete_*"`` would
/// silently never match any real tool name instead of erroring. For a
/// ``PreToolUse`` deny matcher that is a silent fail-open (the guard never
/// fires), so this fails loud instead.
func validateMatcher(_ pattern: String) throws {
    let chars = Array(pattern)
    let n = chars.count
    var i = 0
    while i < n {
        if chars[i] == "[" {
            var j = i + 1
            if j < n, chars[j] == "!" { j += 1 }
            if j < n, chars[j] == "]" { j += 1 }
            while j < n, chars[j] != "]" { j += 1 }
            if j >= n {
                throw HookError(
                    code: .malformedMatcher,
                    message: "malformed hook matcher \"\(pattern)\": "
                        + "unterminated '[' at index \(i)"
                )
            }
            i = j + 1
        } else {
            i += 1
        }
    }
}

// Normative grammar is pinned by the shared hook-matcher vectors
// (shared with the Python suite); internal so the conformance test can
// execute the vectors directly.
func toolNameMatches(_ name: String, _ pattern: String?) -> Bool {
    guard let pattern else { return true }
    return name.withCString { n in pattern.withCString { p in fnmatch(p, n, 0) == 0 } }
}
