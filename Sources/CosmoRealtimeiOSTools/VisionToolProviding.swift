import CosmoRealtime
import CoreGraphics
import Foundation
import ImageIO

/// One on-device Vision/ARKit measurement tool, self-describing so the kit grows
/// by adding a file — not by editing a central switch. A conforming type lives in
/// its own file under `Tools/` and is listed once in `VisionToolRegistry`.
///
/// Contract (see `docs/realtime/coach-app-tool-plan.md` §5 + `phase1-vision-tools-buildout.md`):
/// - The model talks and judges; a tool **measures**. A reply is a JSON object
///   ≤64 KiB of numbers/labels derived from the pixels (landmarks, ratios,
///   coverage, bboxes) — never a mask or image.
/// - Capability-gate via `isSupported`: a tool the device/OS can't run is never
///   advertised (`VisionToolRegistry.declaredTools()`) nor dispatched.
/// - Coachable degradation is `ok:true, {usable:false, reason}` so the model asks
///   for a recapture; a thrown error is a real failure, not "no face in frame".
public protocol VisionToolProviding: Sendable {
    /// Wire name shipped in `tool-invocation` events. A rename is a wire break.
    /// Must match the backend regex `^[a-z][a-z0-9_]{2,63}$` (`client_declared.py`).
    static var name: String { get }

    /// Model-facing description, 1–3 sentences. Failure recovery rides on
    /// the reply's `usable:false`/`reason`, not on prose here.
    static var toolDescription: String { get }

    /// Args JSON-schema in the backend's restricted dialect
    /// (`type/properties/required/items/enum/description/anyOf/default` + bounds);
    /// top-level `type:"object"`. A no-arg measure tool is `{"type":"object","properties":{}}`.
    static var parametersJSON: String { get }

    /// Tool-group key for backend telemetry + brain-allowlisting. Defaults to "vision".
    static var group: String { get }

    /// Whether this device/OS can run the tool right now — gates advertising and
    /// dispatch. Implementations targeting the iOS 18 value-type Vision API return
    /// `false` below their floor so the model never sees an unfulfillable capability.
    static var isSupported: Bool { get }

    /// Measure one still `frame` → the JSON `tool-reply` payload. `args` is decoded
    /// from the invocation against `parametersJSON`. Throw only on a real error;
    /// return `{usable:false, reason}` for a coachable bad frame.
    static func run(
        frame: CGImage,
        args: [String: JSONValue],
        orientation: CGImagePropertyOrientation
    ) async throws -> [String: JSONValue]

    /// The declaration advertised at connect (`VoiceSession.start(declaredTools:)`).
    /// A default builds it from the metadata above; a tool rarely overrides this.
    static func declaredTool() -> DeclaredClientTool
}

public extension VisionToolProviding {
    static var group: String { "vision" }

    /// Maps the tool's metadata to the SDK's app-facing declaration type.
    /// `parametersJSON` is carried as text on both sides, so this is a direct,
    /// non-throwing construction; the schema is validated server-side and any
    /// rejection is echoed on `RealtimeServerReady.rejected_tools`.
    static func declaredTool() -> DeclaredClientTool {
        DeclaredClientTool(
            name: name,
            description: toolDescription,
            parametersJSON: parametersJSON,
            group: group
        )
    }
}
