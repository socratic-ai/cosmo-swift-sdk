import CosmoRealtime
import CoreGraphics
import Foundation
import ImageIO

/// `detect_face_contours` — returns the point outline of each facial feature
/// (lips, eyes, brows, nose, pupils, face edge) so the model can trace exactly
/// where to apply: a lip line, a brow shape, an eyeliner wing. The precise-outline
/// complement to `detect_face_regions` (which returns boxes). The pure measurement
/// lives in `FaceContours`; this adapts it to the wire contract. Numbers only —
/// never an image.
public enum FaceContoursTool: VisionToolProviding {
    public static let name = "detect_face_contours"

    public static var toolDescription: String {
        """
        Return the point outline of each facial feature (lips, eyes, brows, nose, pupils, face \
        edge) in the current frame, normalized [0,1], so you can trace exactly where to apply — a \
        lip line, brow shape, or eyeliner wing — by passing the points to draw_path. Returns \
        `usable:false` when no clear face is detected so you can ask the user to reframe.
        """
    }

    public static var parametersJSON: String { #"{"type":"object","properties":{}}"# }

    public static var isSupported: Bool {
        if #available(iOS 18, macOS 15, *) { return true } else { return false }
    }

    public static func run(
        frame: CGImage,
        args: [String: JSONValue],
        orientation: CGImagePropertyOrientation
    ) async throws -> [String: JSONValue] {
        guard #available(iOS 18, macOS 15, *) else {
            throw VisionToolError("unsupported_tool: \(name) needs a newer OS")
        }
        let result = try await FaceContours.detect(frame, orientation: orientation)
        guard result.faceFound, !result.contours.isEmpty else {
            // Coachable degradation, not a failure: ok=true so the model speaks the
            // reason and asks for a recapture instead of treating it as an error.
            return [
                "usable": .bool(false),
                "reason": .string("no clear face detected — ask the user to face the camera in good light"),
            ]
        }
        // region key → ordered [{x,y}] outline (normalized [0,1], top-left).
        let contours = result.contours.mapValues { points in
            JSONValue.array(points.map { point in
                JSONValue.object(["x": .double(point.x), "y": .double(point.y)])
            })
        }
        return [
            "usable": .bool(true),
            "contours": .object(contours),
        ]
    }
}
