import CosmoRealtime
import CoreGraphics
import Foundation
import ImageIO
import Vision

/// `detect_hand_pose` — a `VisionToolProviding` tool for the cooking/repair/sign
/// verticals: it measures every detected hand's joint positions in the current
/// frame via iOS 18's value-type `DetectHumanHandPoseRequest`, adapting the Vision
/// result to the wire contract (metadata + the JSON `tool-reply`).
public enum HandPoseTool: VisionToolProviding {
    public static let name = "detect_hand_pose"

    public static var toolDescription: String {
        """
        Measure each hand's joint positions in the current camera frame: returns every \
        detected hand's chirality and per-joint position and confidence as numbers (never \
        an image) so you can ground guidance in measurements instead of describing what you \
        see. It returns `usable:false` when no hands are detected so you can ask the user to \
        bring their hands into frame.
        """
    }

    public static var parametersJSON: String { #"{"type":"object","properties":{}}"# }

    public static var isSupported: Bool {
        if #available(iOS 18, macOS 15, *) { return true } else { return false }
    }

    /// Joints below this confidence are noisy guesses, not measurements — drop
    /// them so the model never coaches off a phantom finger.
    private static let confidenceThreshold: Float = 0.1

    public static func run(
        frame: CGImage,
        args: [String: JSONValue],
        orientation: CGImagePropertyOrientation
    ) async throws -> [String: JSONValue] {
        guard #available(iOS 18, macOS 15, *) else {
            throw VisionToolError("unsupported_tool: \(name) needs a newer OS")
        }
        let request = DetectHumanHandPoseRequest()
        let observations = try await request.perform(on: frame, orientation: orientation)
        var hands: [JSONValue] = []
        for hand in observations {
            var landmarks: [String: JSONValue] = [:]
            for (jointName, joint) in hand.allJoints() where joint.confidence > confidenceThreshold {
                // Vision's NormalizedPoint is bottom-left origin; flip y to top-left so
                // the reply reads like screen coordinates.
                landmarks[jointName.rawValue] = .object([
                    "x": .double(Double(joint.location.x)),
                    "y": .double(1 - Double(joint.location.y)),
                    "confidence": .double(Double(joint.confidence)),
                ])
            }
            guard !landmarks.isEmpty else { continue }
            hands.append(.object([
                "chirality": .string(chirality(hand.chirality)),
                "landmarks": .object(landmarks),
            ]))
        }
        guard !hands.isEmpty else {
            // Coachable degradation, not a failure: ok=true so the model speaks the
            // reason and asks for a recapture instead of treating it as an error.
            return [
                "usable": .bool(false),
                "reason": .string("no hands detected — ask the user to bring their hands into frame"),
            ]
        }
        return [
            "usable": .bool(true),
            "hand_count": .int(hands.count),
            "hands": .array(hands),
        ]
    }

    @available(iOS 18, macOS 15, *)
    private static func chirality(_ value: HumanHandPoseObservation.Chirality?) -> String {
        switch value {
        case .left: return "left"
        case .right: return "right"
        case nil: return "unknown"
        }
    }
}
