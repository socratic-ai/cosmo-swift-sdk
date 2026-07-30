import CosmoRealtime
import CoreGraphics
import Foundation
import ImageIO
import Vision

/// `classify_image` — the generic "what am I looking at" tool. It classifies the
/// current frame via iOS 18's value-type `ClassifyImageRequest`, returning the
/// top scene/object labels with confidence as numbers (never an image) so the
/// model can ground itself in what the camera actually sees. It returns
/// `usable:false` when nothing is identified so the model can ask the user to
/// fill the frame with the object.
public enum ClassifyImageTool: VisionToolProviding {
    public static let name = "classify_image"

    public static var toolDescription: String {
        """
        Identify what the current camera frame shows: returns the top scene/object labels \
        with their confidence so you can ground feedback in what the camera actually sees \
        instead of guessing. It returns `usable:false` when nothing is identified so you can \
        ask the user to fill the frame with the object.
        """
    }

    public static var parametersJSON: String { #"{"type":"object","properties":{}}"# }

    public static var isSupported: Bool {
        if #available(iOS 18, macOS 15, *) { return true } else { return false }
    }

    /// At most this many labels ship in a reply: Vision returns its classifications
    /// sorted by confidence, and the model only needs the most likely few to name
    /// the scene, so the long tail is dropped.
    private static let maxLabels: Int = 5

    public static func run(
        frame: CGImage,
        args: [String: JSONValue],
        orientation: CGImagePropertyOrientation
    ) async throws -> [String: JSONValue] {
        guard #available(iOS 18, macOS 15, *) else {
            throw VisionToolError("unsupported_tool: \(name) needs a newer OS")
        }
        let request = ClassifyImageRequest()
        let observations = try await request.perform(on: frame, orientation: orientation)

        let labels: [JSONValue] = observations.prefix(maxLabels).map { observation in
            .object([
                "identifier": .string(observation.identifier),
                "confidence": .double(Double(observation.confidence)),
            ])
        }

        guard !labels.isEmpty else {
            // Coachable degradation, not a failure: ok=true so the model speaks the
            // reason and asks for a recapture instead of treating it as an error.
            return [
                "usable": .bool(false),
                "reason": .string("couldn't identify the scene — ask the user to fill the frame with the object"),
            ]
        }
        return [
            "usable": .bool(true),
            "labels": .array(labels),
        ]
    }
}
