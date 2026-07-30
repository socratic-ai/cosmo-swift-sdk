import CosmoRealtime
import CoreGraphics
import Foundation
import ImageIO

/// `detect_face_landmarks` — the reference `VisionToolProviding` implementation
/// every other tool is modeled on. The pure Vision measurement lives in
/// `FaceLandmarks` (unit-testable with a fixture `CGImage`); this type adapts it
/// to the wire contract: metadata + the JSON `tool-reply`.
public enum FaceLandmarksTool: VisionToolProviding {
    public static let name = "detect_face_landmarks"

    public static var toolDescription: String {
        """
        Measure the face in the current camera frame: returns landmark geometry and head \
        orientation as numbers (bounding box, roll/yaw/pitch, whether landmarks resolved), \
        never an image. Call it to ground specific feedback in measurements instead of \
        describing what you see; it returns `usable:false` when no clear face is detected so \
        you can ask the user to reframe.
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
        let m = try await FaceLandmarks.measure(frame, orientation: orientation)
        guard m.faceFound, let box = m.boundingBox else {
            // Coachable degradation, not a failure: ok=true so the model speaks the
            // reason and asks for a recapture instead of treating it as an error.
            return [
                "usable": .bool(false),
                "reason": .string("no clear face detected — ask the user to face the camera in good light"),
            ]
        }
        var result: [String: JSONValue] = [
            "usable": .bool(true),
            "face_count": .int(m.faceCount),
            // normalized [0,1], top-left origin (see FaceLandmarks.Box)
            "bounding_box": .object([
                "x": .double(box.x),
                "y": .double(box.y),
                "width": .double(box.width),
                "height": .double(box.height),
            ]),
            "coverage_fraction": .double(box.width * box.height),
            "centered": .bool(box.isRoughlyCentered),
            "landmarks_available": .bool(m.landmarksAvailable),
        ]
        if let roll = m.rollDegrees { result["roll_degrees"] = .double(roll) }
        if let yaw = m.yawDegrees { result["yaw_degrees"] = .double(yaw) }
        if let pitch = m.pitchDegrees { result["pitch_degrees"] = .double(pitch) }
        return result
    }
}
