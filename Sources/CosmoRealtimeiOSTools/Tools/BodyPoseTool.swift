import CosmoRealtime
import CoreGraphics
import Foundation
import ImageIO
import Vision

/// `detect_body_pose` — a `VisionToolProviding` tool for the exercise/PT
/// verticals: it measures the most prominent person's body-pose joints in the
/// current frame via iOS 18's value-type `DetectHumanBodyPoseRequest`, adapting
/// the Vision result to the wire contract (metadata + the JSON `tool-reply`).
public enum BodyPoseTool: VisionToolProviding {
    public static let name = "detect_body_pose"

    public static var toolDescription: String {
        """
        Measure the person's body-pose joints in the current camera frame: returns each \
        detected joint's position and confidence as numbers (never an image) so you can \
        ground form feedback in measurements instead of describing what you see. It returns \
        `usable:false` when no person is detected so you can ask the user to reframe.
        """
    }

    public static var parametersJSON: String { #"{"type":"object","properties":{}}"# }

    public static var isSupported: Bool {
        if #available(iOS 18, macOS 15, *) { return true } else { return false }
    }

    /// Joints below this confidence are noisy guesses, not measurements — drop
    /// them so the model never coaches off a phantom limb.
    private static let confidenceThreshold: Float = 0.1

    public static func run(
        frame: CGImage,
        args: [String: JSONValue],
        orientation: CGImagePropertyOrientation
    ) async throws -> [String: JSONValue] {
        guard #available(iOS 18, macOS 15, *) else {
            throw VisionToolError("unsupported_tool: \(name) needs a newer OS")
        }
        let request = DetectHumanBodyPoseRequest()
        let observations = try await request.perform(on: frame, orientation: orientation)
        guard let person = observations.max(by: { $0.confidence < $1.confidence }) else {
            // Coachable degradation, not a failure: ok=true so the model speaks the
            // reason and asks for a recapture instead of treating it as an error.
            return [
                "usable": .bool(false),
                "reason": .string("no person detected — ask the user to step back so their upper body is in frame"),
            ]
        }
        var joints: [String: JSONValue] = [:]
        for (jointName, joint) in person.allJoints() where joint.confidence > confidenceThreshold {
            // Vision's NormalizedPoint is bottom-left origin; flip y to top-left so
            // the reply reads like screen coordinates.
            joints[jointName.rawValue] = .object([
                "x": .double(Double(joint.location.x)),
                "y": .double(1 - Double(joint.location.y)),
                "confidence": .double(Double(joint.confidence)),
            ])
        }
        guard !joints.isEmpty else {
            return [
                "usable": .bool(false),
                "reason": .string("no person detected — ask the user to step back so their upper body is in frame"),
            ]
        }
        return [
            "usable": .bool(true),
            "joint_count": .int(joints.count),
            "joints": .object(joints),
        ]
    }
}
