import Foundation

/// A normalized point in `[0,1]`, **top-left origin** (y increases downward) —
/// the same convention as ``NormalizedBox`` and the on-device Vision tools.
public struct NormalizedPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// How a drawn path is capped. `.stroke` is a plain line; `.arrow` puts an
/// arrowhead on the final point to show a direction ("swipe up and out").
public enum DrawPathStyle: String, Sendable, Equatable {
    case stroke
    case arrow
}

/// One model request to draw a freehand path on the user's screen: an ordered
/// list of points, whether it closes into an outline, a cap style, and an
/// optional short caption. Decoded from a `draw_path` invocation's arguments.
public struct DrawPathRequest: Sendable, Equatable {
    public var points: [NormalizedPoint]
    public var closed: Bool
    public var style: DrawPathStyle
    public var label: String?

    public init(
        points: [NormalizedPoint],
        closed: Bool = false,
        style: DrawPathStyle = .stroke,
        label: String? = nil
    ) {
        self.points = points
        self.closed = closed
        self.style = style
        self.label = label
    }
}

/// `draw_path` — a model-directed UI annotation tool, the freehand sibling of
/// ``DrawBoxTool``. The model decides, on its own initiative, *when* and
/// *where* to trace a line or outline; the app renders it and acks. Like the box
/// tool it measures nothing — it carries the model's intent to the client UI. The
/// SDK owns the contract (declaration + typed decode of the arguments); the app
/// owns the drawing, including any smoothing of the polyline.
///
/// For a path that follows a facial feature, the model can call `face_landmarks`
/// first and pass a subset of the points it returns; otherwise it estimates them
/// from the frame it was shown. Either way the points are normalized to that
/// frame, so the app maps them onto the preview the same way it maps a box.
public enum DrawPathTool {
    /// Wire name shipped in `tool-invocation` events; a rename is a wire break.
    /// Matches the backend regex `^[a-z][a-z0-9_]{2,63}$` (`client_declared.py`).
    public static let name = "draw_path"

    /// Tool-group key for backend telemetry + brain-allowlisting.
    public static let group = "ui"

    public static var toolDescription: String {
        """
        Draw a freehand line or outline on the user's screen to show a direction or contour a box \
        can't — pass an ordered list of points normalized to the frame you were shown ([0,1], \
        top-left origin), e.g. to trace where to sweep blush. For a path that follows a facial \
        feature, first call face_landmarks and pass a subset of its points. Visual only — it \
        measures nothing and changes nothing.
        """
    }

    /// Args JSON-schema in the backend's restricted dialect.
    public static var parametersJSON: String {
        #"""
        {"type":"object","properties":{"points":{"type":"array","description":"Ordered points along the path (2 to 48), normalized to the frame you were shown: [0,1], top-left origin.","items":{"type":"object","properties":{"x":{"type":"number","minimum":0,"maximum":1},"y":{"type":"number","minimum":0,"maximum":1}},"required":["x","y"]}},"closed":{"type":"boolean","default":false,"description":"Close the path into an outline."},"style":{"type":"string","enum":["stroke","arrow"],"default":"stroke","description":"'arrow' puts an arrowhead on the last point to show direction."},"label":{"type":"string","maxLength":40,"description":"Short caption shown on the path, e.g. 'blend up & out'."}},"required":["points"]}
        """#
    }

    /// The declaration advertised at connect (`VoiceSession.start(declaredTools:)`).
    public static func declaredTool() -> DeclaredClientTool {
        DeclaredClientTool(
            name: name,
            description: toolDescription,
            parametersJSON: parametersJSON,
            group: group
        )
    }

    /// Decode a `draw_path` invocation's arguments into a typed request. Returns
    /// `nil` when fewer than two valid points survive — a boundary check on model
    /// output, not an invariant. Coordinates are clamped to `[0,1]` so a model
    /// that overshoots the edge still yields a drawable path; an individual
    /// malformed point is dropped rather than failing the whole stroke.
    public static func request(from args: [String: JSONValue]) -> DrawPathRequest? {
        guard case let .array(rawPoints)? = args["points"] else { return nil }
        let points: [NormalizedPoint] = rawPoints.compactMap { value in
            guard case let .object(fields) = value,
                  let x = fields["x"]?.asDouble,
                  let y = fields["y"]?.asDouble else { return nil }
            return NormalizedPoint(x: clamp01(x), y: clamp01(y))
        }
        // The backend schema dialect can't carry an array-length bound, so the
        // cap is enforced here: keep at most `maxPoints`, require at least two.
        let bounded = Array(points.prefix(maxPoints))
        guard bounded.count >= 2 else { return nil }

        var closed = false
        if case let .bool(b)? = args["closed"] { closed = b }

        var style = DrawPathStyle.stroke
        if case let .string(s)? = args["style"], let parsed = DrawPathStyle(rawValue: s) {
            style = parsed
        }

        var label: String?
        if case let .string(s)? = args["label"] { label = s }

        return DrawPathRequest(points: bounded, closed: closed, style: style, label: label)
    }

    /// Upper bound on points, enforced in the decoder because the backend schema
    /// dialect has no `maxItems`. A coarse freehand stroke needs far fewer.
    private static let maxPoints = 48

    private static func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }
}
