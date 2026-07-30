import CosmoRealtime
import CoreGraphics
import Foundation
import ImageIO

/// `detect_face_regions` — locates the user's facial regions (eyes, brows, nose,
/// lips, cheeks, forehead, face outline) as normalized boxes, so the model can
/// reference or point at a specific makeup zone. The pure Vision measurement
/// lives in `FaceRegions`; this type adapts it to the wire contract: metadata +
/// the JSON `tool-reply`. Numbers only — never an image.
public enum FaceRegionsTool: VisionToolProviding {
    public static let name = "detect_face_regions"

    public static var toolDescription: String {
        """
        Locate the user's facial regions (eyes, brows, nose, lips, cheeks, forehead, face \
        outline) in the current camera frame, each as a normalized box, so you can reference \
        or point at a specific makeup zone. Returns `usable:false` when no clear face is \
        detected so you can ask the user to reframe.
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
        let result = try await FaceRegions.detect(frame, orientation: orientation)
        guard result.faceFound, !result.boxes.isEmpty else {
            // Coachable degradation, not a failure: ok=true so the model speaks the
            // reason and asks for a recapture instead of treating it as an error.
            return [
                "usable": .bool(false),
                "reason": .string("no clear face detected — ask the user to face the camera in good light"),
            ]
        }
        // region key → normalized [0,1], top-left box (see FaceLandmarks.Box).
        let regions = result.boxes.mapValues { box in
            JSONValue.object([
                "x": .double(box.x),
                "y": .double(box.y),
                "width": .double(box.width),
                "height": .double(box.height),
            ])
        }
        return [
            "usable": .bool(true),
            "regions": .object(regions),
        ]
    }
}
