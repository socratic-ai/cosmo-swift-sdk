import CosmoRealtime
import CoreGraphics
import Foundation
import ImageIO
import Vision

/// `is_camera_level` — the framing gate. Measures the camera's tilt against the
/// detected horizon in the current frame via iOS 18's value-type
/// `DetectHorizonRequest`, adapting the Vision result to the wire contract
/// (metadata + the JSON `tool-reply`). It returns `usable:false` when no horizon
/// reference is found so the model asks the user to point at a scene with a clear
/// horizontal line instead of guessing.
public enum CameraLevelTool: VisionToolProviding {
    public static let name = "is_camera_level"

    public static var toolDescription: String {
        """
        Report the camera's tilt against the detected horizon in the current frame as a \
        roll angle in degrees, so you can tell the user to straighten up. Returns \
        `level:true` when the tilt is within a few degrees, and `usable:false` when no \
        horizon reference is found so you can ask the user to point at a clear horizontal line.
        """
    }

    public static var parametersJSON: String { #"{"type":"object","properties":{}}"# }

    public static var isSupported: Bool {
        if #available(iOS 18, macOS 15, *) { return true } else { return false }
    }

    /// A tilt within this many degrees of horizontal reads as level to the user.
    private static let levelToleranceDegrees: Double = 3

    public static func run(
        frame: CGImage,
        args: [String: JSONValue],
        orientation: CGImagePropertyOrientation
    ) async throws -> [String: JSONValue] {
        guard #available(iOS 18, macOS 15, *) else {
            throw VisionToolError("unsupported_tool: \(name) needs a newer OS")
        }
        let request = DetectHorizonRequest()
        guard let observation = try await request.perform(on: frame, orientation: orientation) else {
            // Coachable degradation, not a failure: ok=true so the model speaks the
            // reason and asks for a recapture instead of treating it as an error.
            return [
                "usable": .bool(false),
                "reason": .string("can't find a horizon reference — point the camera at a scene with a clear horizontal line"),
            ]
        }
        let deg = observation.angle.converted(to: .degrees).value
        return [
            "usable": .bool(true),
            "angle_degrees": .double(deg),
            "level": .bool(abs(deg) <= levelToleranceDegrees),
        ]
    }
}
