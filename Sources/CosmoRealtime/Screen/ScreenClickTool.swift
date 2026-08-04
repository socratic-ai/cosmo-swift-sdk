import Foundation

/// One model request to click a located element: which element, by the ref
/// `cosmo_screen_locate` minted for it, and how to click it. Decoded from a
/// `cosmo_sdk_screen_click` invocation's arguments.
public struct ScreenClickRequest: Sendable, Equatable {
    public var ref: ScreenRef
    public var action: ScreenAction

    public init(ref: ScreenRef, action: ScreenAction) {
        self.ref = ref
        self.action = action
    }
}

/// A ``ScreenClickRequest`` whose ref resolved: the element to click, the
/// capture it was located in (a host re-reads
/// ``ScreenCapture/context`` from it to check the screen hasn't moved on), and
/// the click to perform.
public struct ScreenClick: Sendable {
    public let element: ScreenElement
    public let capture: ScreenCapture
    public let action: ScreenAction

    public init(element: ScreenElement, capture: ScreenCapture, action: ScreenAction) {
        self.element = element
        self.capture = capture
        self.action = action
    }
}

/// What a ``SessionConfig/Tool/screenClick(onClick:)`` handler reports back to
/// the model.
///
/// Clicking can fail for reasons the model must hear about — the user switched
/// apps, the window scrolled, the call ended. Answering "clicked" regardless
/// would have it narrate something that never happened. The reason travels with
/// the refusal so it can say something useful instead of guessing.
public struct ScreenClickOutcome: Sendable, Equatable {
    /// The click landed.
    public static let clicked = ScreenClickOutcome(clicked: true, reason: nil)

    /// Nothing was clicked. ``reason`` is model-facing: it is what the agent
    /// tells the user, so write it as an instruction ("the window moved —
    /// locate it again"), not as an error code.
    public static func notClicked(_ reason: String) -> ScreenClickOutcome {
        ScreenClickOutcome(clicked: false, reason: reason)
    }

    public let clicked: Bool
    public let reason: String?

    private init(clicked: Bool, reason: String?) {
        self.clicked = clicked
        self.reason = reason
    }

    /// The tool result the model receives.
    var toolResult: [String: JSONValue] {
        var result: [String: JSONValue] = ["clicked": .bool(clicked)]
        if let reason { result["reason"] = .string(reason) }
        return result
    }
}

/// `cosmo_sdk_screen_click` — the acting half of the locate-then-act pair.
/// `cosmo_screen_locate` captures the shared screen, resolves the model's
/// description against it, and returns candidates each carrying a ref; the
/// model picks the one it meant and passes that ref here.
///
/// It locates nothing — it carries the model's choice to the host, which owns
/// the click itself. The SDK owns the contract (declaration, typed decode, and
/// resolving the ref back to the element it addresses).
public enum ScreenClickTool {
    /// Wire name shipped in `tool-invocation` events; a rename is a wire break.
    /// Matches the backend regex `^[a-z][a-z0-9_]{2,63}$` (`client_declared.py`).
    public static let name = "cosmo_sdk_screen_click"

    /// Tool-group key for backend telemetry + brain-allowlisting.
    public static let group = "screen"

    public static var toolDescription: String {
        """
        Click an element on the shared screen. Takes a ref from cosmo_screen_locate — \
        pass one back exactly as you received it. Do not construct a ref or edit its \
        fields; an invented one points at a real control the user did not ask you to click.
        """
    }

    /// Args JSON-schema in the backend's restricted dialect.
    public static var parametersJSON: String {
        #"""
        {"type":"object","properties":{"ref":{"type":"object","description":"A ref exactly as cosmo_screen_locate returned it.","properties":{"capture_id":{"type":"string"},"element_idx":{"type":"integer","minimum":0}},"required":["capture_id","element_idx"]},"button":{"type":"string","enum":["left","right"],"description":"'right' opens context menus."},"double":{"type":"boolean","description":"True for a double-click (open a file, select a word)."}},"required":["ref"]}
        """#
    }

    /// The declaration advertised at connect.
    public static func declaredTool() -> DeclaredClientTool {
        DeclaredClientTool(
            name: name,
            description: toolDescription,
            parametersJSON: parametersJSON,
            group: group
        )
    }

    /// Decode a `cosmo_sdk_screen_click` invocation's arguments into a typed
    /// request. Returns `nil` when the ref is absent or malformed, or the button
    /// is one this SDK has no gesture for — unlike a spotlight's glyph, an
    /// unrecognized button has no harmless fallback, since guessing which button
    /// to press is guessing what happens to the user's machine.
    public static func request(from args: [String: JSONValue]) -> ScreenClickRequest? {
        guard let ref = ScreenRef.decode(args["ref"]) else { return nil }
        let button: ScreenButton
        if let raw = args["button"]?.stringValue {
            guard let parsed = ScreenButton(rawValue: raw) else { return nil }
            button = parsed
        } else {
            button = .left
        }
        return ScreenClickRequest(
            ref: ref,
            action: ScreenAction(button: button, double: args["double"]?.boolValue ?? false)
        )
    }
}

extension SessionConfig.Tool {
    /// The click renderer, ready to add to ``SessionConfig/tools`` alongside the
    /// ``screenLocate(capture:)`` slot that feeds it:
    ///
    /// ```swift
    /// tools: [.screenLocate { … }, .screenClick { target in
    ///     guard stillFocused(target.capture) else {
    ///         return .notClicked("the foreground app changed — locate it again")
    ///     }
    ///     try press(target.element.frame, target.action)
    ///     return .clicked
    /// }]
    /// ```
    ///
    /// The SDK decodes the arguments and resolves the model's ref back to the
    /// element it addresses; your handler owns the click and the honest answer
    /// about whether it landed. A ref that no longer resolves — a capture the
    /// session never took, or one older than ``ScreenCaptureCache/maxAge`` —
    /// declines before reaching your code, since acting on a snapshot the SDK
    /// cannot produce would be acting blind.
    public static func screenClick(
        onClick: @escaping @Sendable (ScreenClick) async throws -> ScreenClickOutcome
    ) -> SessionConfig.Tool {
        screenClick(cache: .shared, onClick: onClick)
    }

    /// Cache-injecting variant so tests can drive the pairing on their own clock.
    static func screenClick(
        cache: ScreenCaptureCache,
        onClick: @escaping @Sendable (ScreenClick) async throws -> ScreenClickOutcome
    ) -> SessionConfig.Tool {
        .sdkClient(SDKClientTool(
            name: ScreenClickTool.name,
            description: ScreenClickTool.toolDescription,
            parameters: sdkToolParameters(fromJSON: ScreenClickTool.parametersJSON),
            handler: { args in
                guard let request = ScreenClickTool.request(from: args) else {
                    throw ScreenToolError(
                        message: "\(ScreenClickTool.name): pass ref {capture_id, element_idx} "
                            + "exactly as cosmo_screen_locate returned it"
                    )
                }
                guard let resolved = cache.resolve(request.ref) else {
                    return ScreenClickOutcome.notClicked(unresolvableRefReason).toolResult
                }
                let click = ScreenClick(
                    element: resolved.element,
                    capture: resolved.capture,
                    action: request.action
                )
                return try await onClick(click).toolResult
            }
        ))
    }
}
