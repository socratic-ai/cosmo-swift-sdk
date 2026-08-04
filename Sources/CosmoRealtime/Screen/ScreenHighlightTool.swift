import Foundation

/// One model request to spotlight a located element: which element, by the ref
/// `cosmo_screen_locate` minted for it, plus the tooltip to show beside it.
/// Decoded from a `cosmo_sdk_screen_highlight` invocation's arguments.
public struct ScreenHighlightRequest: Sendable, Equatable {
    public var ref: ScreenRef
    public var label: String
    public var placement: ScreenPlacement
    public var affordance: ScreenAffordance

    public init(
        ref: ScreenRef,
        label: String,
        placement: ScreenPlacement = .auto,
        affordance: ScreenAffordance = .click
    ) {
        self.ref = ref
        self.label = label
        self.placement = placement
        self.affordance = affordance
    }
}

/// A ``ScreenHighlightRequest`` whose ref resolved: the element to mark and the
/// capture it was located in, plus the tooltip to draw beside it.
public struct ScreenHighlight: Sendable {
    public let element: ScreenElement
    public let capture: ScreenCapture
    public let label: String
    public let placement: ScreenPlacement
    public let affordance: ScreenAffordance

    public init(
        element: ScreenElement,
        capture: ScreenCapture,
        label: String,
        placement: ScreenPlacement,
        affordance: ScreenAffordance
    ) {
        self.element = element
        self.capture = capture
        self.label = label
        self.placement = placement
        self.affordance = affordance
    }
}

/// `cosmo_sdk_screen_highlight` — the pointing sibling of ``ScreenClickTool``,
/// fed by the same `cosmo_screen_locate` refs. It marks the control and stops
/// there, so the user does the acting.
///
/// It reports no confidence: a ref addresses an element the locator picked out
/// of a real accessibility list, so there is nothing left to be imprecise
/// about. ``HighlightRegionTool`` — which takes the model's own estimate —
/// is where that distinction lives.
public enum ScreenHighlightTool {
    /// Wire name shipped in `tool-invocation` events; a rename is a wire break.
    /// Matches the backend regex `^[a-z][a-z0-9_]{2,63}$` (`client_declared.py`).
    public static let name = "cosmo_sdk_screen_highlight"

    /// Tool-group key for backend telemetry + brain-allowlisting.
    public static let group = "screen"

    public static var toolDescription: String {
        """
        Spotlight an element on the shared screen — point at it without acting on it. \
        Takes a ref from cosmo_screen_locate; pass one back exactly as you received it, \
        never one you constructed. Visual only: it never clicks.
        """
    }

    /// Args JSON-schema in the backend's restricted dialect.
    public static var parametersJSON: String {
        #"""
        {"type":"object","properties":{"ref":{"type":"object","description":"A ref exactly as cosmo_screen_locate returned it.","properties":{"capture_id":{"type":"string"},"element_idx":{"type":"integer","minimum":0}},"required":["capture_id","element_idx"]},"label":{"type":"string","maxLength":80,"description":"Tooltip text shown beside the spotlight."},"placement":{"type":"string","enum":["auto","top","bottom","left","right"],"description":"Which side of the target the tooltip sits on."},"interaction":{"type":"string","enum":["pointer","click","double_click","left_click","right_click","drag_show","press_hold","inform"],"description":"Which glyph the spotlight draws — the action being asked of the user."}},"required":["ref","label"]}
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

    /// Decode a `cosmo_sdk_screen_highlight` invocation's arguments into a typed
    /// request. Returns `nil` when the ref or the tooltip is absent or
    /// malformed; an unrecognized placement or glyph falls back instead, since a
    /// spotlight drawn with the wrong glyph still points at the right control.
    public static func request(from args: [String: JSONValue]) -> ScreenHighlightRequest? {
        guard let ref = ScreenRef.decode(args["ref"]) else { return nil }
        guard let label = args["label"]?.stringValue else { return nil }
        return ScreenHighlightRequest(
            ref: ref,
            label: label,
            placement: ScreenArgs.placement(args),
            affordance: ScreenArgs.affordance(args)
        )
    }
}

extension SessionConfig.Tool {
    /// The spotlight renderer, ready to add to ``SessionConfig/tools`` alongside
    /// the ``screenLocate(capture:)`` slot that feeds it. Same contract as
    /// ``screenClick(onClick:)`` — the SDK decodes and resolves the ref, your
    /// handler draws and answers honestly — with a ``DrawOutcome``, since a mark
    /// either shows or says why it could not.
    public static func screenHighlight(
        onHighlight: @escaping @Sendable (ScreenHighlight) async throws -> DrawOutcome
    ) -> SessionConfig.Tool {
        screenHighlight(cache: .shared, onHighlight: onHighlight)
    }

    /// Cache-injecting variant so tests can drive the pairing on their own clock.
    static func screenHighlight(
        cache: ScreenCaptureCache,
        onHighlight: @escaping @Sendable (ScreenHighlight) async throws -> DrawOutcome
    ) -> SessionConfig.Tool {
        .sdkClient(SDKClientTool(
            name: ScreenHighlightTool.name,
            description: ScreenHighlightTool.toolDescription,
            parameters: sdkToolParameters(fromJSON: ScreenHighlightTool.parametersJSON),
            handler: { args in
                guard let request = ScreenHighlightTool.request(from: args) else {
                    throw ScreenToolError(
                        message: "\(ScreenHighlightTool.name): pass ref {capture_id, element_idx} "
                            + "exactly as cosmo_screen_locate returned it, plus a label"
                    )
                }
                guard let resolved = cache.resolve(request.ref) else {
                    return DrawOutcome.notShown(unresolvableRefReason).toolResult
                }
                let highlight = ScreenHighlight(
                    element: resolved.element,
                    capture: resolved.capture,
                    label: request.label,
                    placement: request.placement,
                    affordance: request.affordance
                )
                return try await onHighlight(highlight).toolResult
            }
        ))
    }
}
