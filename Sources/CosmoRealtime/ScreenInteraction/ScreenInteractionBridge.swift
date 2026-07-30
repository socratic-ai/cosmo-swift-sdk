import Foundation

/// An unexpected failure servicing a screen-interaction RPC (missing/invalid
/// args, out-of-range index, byte-stream publish failure). Surfaces as an
/// `{ok:false,error}` envelope via ``ClientToolDispatch``; a benign decline
/// (cache miss, conformer says no) returns a `{…:false}` reply instead.
struct ScreenInteractionError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Owns the screen-interaction capture cache and byte-stream publish, and turns
/// a ``ScreenInteraction`` conformer into the three server→client RPC handlers
/// the worker drives (`capture` / `activate` / `highlight`). Mirrors the Python
/// SDK's `ScreenInteractionBridge`: the conformer provides only the platform
/// pieces; everything wire-facing (arg parsing, cache pairing, reply shape,
/// payload encoding) lives here. Registered via ``handlers()`` on the same
/// register-without-advertise RPC path the client-tool dispatcher uses.
final class ScreenInteractionBridge: @unchecked Sendable {
    private let conformer: ScreenInteraction
    /// Internal (not private) so bridge tests can seed a capture without
    /// running the real conformer.
    let cache: ScreenCaptureCache

    private let lock = NSLock()
    private var _sendBytes: (@Sendable (Data, String) async throws -> Void)?

    init(conformer: ScreenInteraction, cache: ScreenCaptureCache = ScreenCaptureCache()) {
        self.conformer = conformer
        self.cache = cache
    }

    /// Bind the byte-stream publish. Set once, right after the session's
    /// transport comes up (the capture payload can only fire once the model
    /// calls `capture`, well after connect), so the late bind never races.
    func bindSendBytes(_ send: @escaping @Sendable (Data, String) async throws -> Void) {
        lock.lock(); _sendBytes = send; lock.unlock()
    }

    /// The three screen-interaction RPCs as register-without-advertise
    /// ``ClientToolHandler``s, keyed by wire method name — merge into the
    /// session's `rpcHandlers` (parity with Python's `bridge.handlers()`).
    func handlers() -> [String: ClientToolHandler] {
        var out: [String: ClientToolHandler] = [:]
        for rpc in ScreenInteractionRPC.allCases {
            out[rpc.rawValue] = { [self] args in try await handle(rpc, args: args) }
        }
        return out
    }

    func handle(_ rpc: ScreenInteractionRPC, args: [String: JSONValue]) async throws -> [String: JSONValue] {
        switch rpc {
        case .capture:          return try await runCapture(args: args)
        case .activate:         return try await runActivate(args: args)
        case .highlightElement: return try await runHighlightElement(args: args)
        case .highlightRegion:  return try await runHighlightRegion(args: args)
        }
    }

    // MARK: Handlers

    private func runCapture(args: [String: JSONValue]) async throws -> [String: JSONValue] {
        let captureID = try Self.requiredString(args, "capture_id", tool: "screen_interaction_capture")
        let capture: ScreenCapture
        do {
            capture = try await conformer.capture()
        } catch let unavailable as ScreenCaptureUnavailable {
            return ["captured": .bool(false), "message": .string(unavailable.message)]
        }
        cache.put(captureID, capture)
        let payload = try Self.encodeCapturePayload(captureID: captureID, capture: capture)
        do {
            try await sendBytes(payload, ScreenInteractionRPC.captureTopic)
        } catch {
            throw ScreenInteractionError(
                message: "screen_interaction_capture: failed to publish capture stream: \(error.localizedDescription)"
            )
        }
        return ["captured": .bool(true)]
    }

    private func runActivate(args: [String: JSONValue]) async throws -> [String: JSONValue] {
        guard let (element, capture) = resolve(args) else {
            return [
                "activated": .bool(false),
                "message": .string("The screen changed before the click could fire — try again."),
            ]
        }
        let action = try Self.parseAction(args)
        let outcome = try await conformer.activate(element: element, capture: capture, action: action)
        var reply: [String: JSONValue] = ["activated": .bool(outcome.ok)]
        if let message = outcome.message { reply["message"] = .string(message) }
        return reply
    }

    private func runHighlightElement(args: [String: JSONValue]) async throws -> [String: JSONValue] {
        guard let (element, capture) = resolve(args) else {
            return [
                "shown": .bool(false),
                "message": .string("The screen changed before the spotlight could land — try again."),
            ]
        }
        let tool = ScreenInteractionRPC.highlightElement.rawValue
        let outcome = try await conformer.highlightElement(
            element: element, capture: capture,
            label: try Self.requiredString(args, "label", tool: tool),
            placement: try Self.parsePlacement(args, tool: tool),
            affordance: try Self.parseAffordance(args, tool: tool)
        )
        return Self.highlightReply(outcome, method: "grounded")
    }

    private func runHighlightRegion(args: [String: JSONValue]) async throws -> [String: JSONValue] {
        let tool = ScreenInteractionRPC.highlightRegion.rawValue
        let outcome = try await conformer.highlightRegion(
            region: try Self.parseRegion(args, tool: tool),
            element: Self.parseElementHint(args),
            label: try Self.requiredString(args, "label", tool: tool),
            placement: try Self.parsePlacement(args, tool: tool),
            affordance: try Self.parseAffordance(args, tool: tool)
        )
        return Self.highlightReply(outcome, method: "direct")
    }

    private static func highlightReply(
        _ outcome: ScreenActionOutcome, method: String
    ) -> [String: JSONValue] {
        var reply: [String: JSONValue] = ["shown": .bool(outcome.ok)]
        if outcome.ok { reply["method"] = .string(method) }
        if let message = outcome.message { reply["message"] = .string(message) }
        if let landedExactly = outcome.landedExactly {
            reply["confidence"] = .string(landedExactly ? "high" : "low")
        }
        return reply
    }

    // MARK: Wire helpers

    private func sendBytes(_ data: Data, _ topic: String) async throws {
        lock.lock(); let send = _sendBytes; lock.unlock()
        guard let send else {
            throw ScreenInteractionError(message: "screen_interaction_capture: byte-stream publish not bound")
        }
        try await send(data, topic)
    }

    /// Resolve `capture_id` + `element_idx` to `(element, capture)` against the
    /// cache. Returns nil for any unresolvable reference — a missing/invalid
    /// `capture_id` or `element_idx`, a cache miss/expiry, or an out-of-range
    /// index — so the caller declines. A stale or malformed grounded action is a
    /// benign retry, not a hard error; this matches the shared screen-interaction
    /// conformance vectors and the Python/TS bridges.
    private func resolve(
        _ args: [String: JSONValue]
    ) -> (ScreenElement, ScreenCapture)? {
        guard let captureID = args["capture_id"]?.stringValue, !captureID.isEmpty else { return nil }
        guard let idx = args["element_idx"]?.intValue else { return nil }
        guard let capture = cache.get(captureID) else { return nil }
        guard idx >= 0, idx < capture.elements.count else { return nil }
        return (capture.elements[idx], capture)
    }

    private static func parseAction(_ args: [String: JSONValue]) throws -> ScreenAction {
        // The wire carries the neutral button; the conformer maps it to a
        // platform gesture.
        let buttonString = args["button"]?.stringValue ?? "primary"
        let button: ScreenButton
        switch buttonString {
        case "primary": button = .primary
        case "secondary": button = .secondary
        default:
            throw ScreenInteractionError(
                message: "screen_interaction_activate: invalid button '\(buttonString)'; expected primary|secondary"
            )
        }
        return ScreenAction(button: button, double: args["double"]?.boolValue ?? false)
    }

    /// Normalized rectangle off the wire. Throws when a component is missing or
    /// non-numeric — that is a malformed caller, not a stale one. Range is the
    /// backend's to enforce; a conformer clamps to its own display.
    private static func parseRegion(
        _ args: [String: JSONValue], tool: String
    ) throws -> ScreenRegion {
        func component(_ key: String) throws -> Double {
            guard let value = args[key]?.doubleValue else {
                throw ScreenInteractionError(message: "\(tool): missing or non-numeric '\(key)'")
            }
            return value
        }
        return ScreenRegion(
            x: try component("x"),
            y: try component("y"),
            width: try component("width"),
            height: try component("height")
        )
    }

    /// The optional "what it's called" hint. Absent or blank means the caller
    /// could not read a name off the target, which is normal — it is a bonus
    /// signal, never a requirement, so it declines rather than throws.
    private static func parseElementHint(_ args: [String: JSONValue]) -> ScreenElementHint? {
        guard let title = args["element_title"]?.stringValue,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let role = args["element_role"]?.stringValue
        return ScreenElementHint(
            title: title,
            role: (role?.isEmpty == false) ? role : nil
        )
    }

    /// Unknown placement/affordance values fall back rather than throw: they
    /// mean the caller is newer than this SDK, and a spotlight with the wrong
    /// glyph still points the user at the right control, whereas a thrown error
    /// points them at nothing. Malformed structure still throws (see
    /// ``parseRegion``) — that is a broken caller, not a newer one.
    private static func parsePlacement(
        _ args: [String: JSONValue], tool: String
    ) throws -> ScreenPlacement {
        guard let raw = args["placement"]?.stringValue else { return .auto }
        return ScreenPlacement(rawValue: raw) ?? .auto
    }

    /// Wire name is `interaction`; the Swift parameter is `affordance` to keep
    /// it distinct from ``ScreenAction``, which is what a click actually does.
    private static func parseAffordance(
        _ args: [String: JSONValue], tool: String
    ) throws -> ScreenAffordance {
        guard let raw = args["interaction"]?.stringValue else { return .click }
        return ScreenAffordance(rawValue: raw) ?? .click
    }

    private static func requiredString(
        _ args: [String: JSONValue], _ key: String, tool: String
    ) throws -> String {
        guard let value = args[key]?.stringValue, !value.isEmpty else {
            throw ScreenInteractionError(message: "\(tool): missing required '\(key)'")
        }
        return value
    }

    /// JSON byte-stream payload the worker's ``ScreenInteractionCapturePayload``
    /// parses: `{capture_id, image_b64, mime_type, ax_elements}`.
    private static func encodeCapturePayload(captureID: String, capture: ScreenCapture) throws -> Data {
        struct AXElementPayload: Encodable {
            let idx: Int
            let role: String
            let title: String?
            let label: String?
            let value: String?
            let frame: [Double]  // [x, y, w, h] in screen points
        }
        struct Payload: Encodable {
            let capture_id: String
            let image_b64: String
            let mime_type: String
            let ax_elements: [AXElementPayload]
        }
        let ax = capture.elements.map { el -> AXElementPayload in
            AXElementPayload(
                idx: el.index,
                role: el.role,
                title: el.title,
                label: el.label,
                value: el.value,
                frame: [
                    Double(el.frame.origin.x),
                    Double(el.frame.origin.y),
                    Double(el.frame.size.width),
                    Double(el.frame.size.height),
                ]
            )
        }
        return try JSONEncoder().encode(
            Payload(
                capture_id: captureID,
                image_b64: capture.imageJPEG.base64EncodedString(),
                mime_type: "image/jpeg",
                ax_elements: ax
            )
        )
    }
}

// MARK: - JSONValue conveniences (internal to the SDK)

extension JSONValue {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d == d.rounded(): return Int(d)
        default: return nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
}
