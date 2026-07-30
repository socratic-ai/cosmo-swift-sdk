import CosmoRealtime
import CoreGraphics
import Foundation
import ImageIO
import Vision

/// `read_text` — reads printed text in the current frame (labels, ingredients,
/// instructions) via iOS 18's value-type `RecognizeTextRequest`. The measurement
/// lives inline here: still frame in, the JSON `tool-reply` out (strings +
/// confidence + location), never an image. `usable:false` when nothing legible is
/// found, so the model asks the user to steady the label instead of guessing.
public enum ReadTextTool: VisionToolProviding {
    public static let name = "read_text"

    public static var toolDescription: String {
        """
        Read printed text in the current camera frame (labels, ingredients, instructions) and \
        return the recognized strings with their confidence and location, never an image. Call \
        it to ground feedback in what the label actually says instead of guessing; it returns \
        `usable:false` when nothing legible is found so you can ask the user to steady the label.
        """
    }

    public static var parametersJSON: String { #"{"type":"object","properties":{}}"# }

    public static var isSupported: Bool {
        if #available(iOS 18, macOS 15, *) { return true } else { return false }
    }

    /// At most this many lines ship in a reply: the `tool-reply` is capped at 64 KiB
    /// and the model only needs the visible label, so a long page of text truncates
    /// rather than blowing the budget.
    private static let maxLines: Int = 40

    public static func run(
        frame: CGImage,
        args: [String: JSONValue],
        orientation: CGImagePropertyOrientation
    ) async throws -> [String: JSONValue] {
        guard #available(iOS 18, macOS 15, *) else {
            throw VisionToolError("unsupported_tool: \(name) needs a newer OS")
        }
        let request = RecognizeTextRequest()
        let observations = try await request.perform(on: frame, orientation: orientation)

        var lines: [JSONValue] = []
        var strings: [String] = []
        for observation in observations.prefix(maxLines) {
            guard let candidate = observation.topCandidates(1).first else { continue }
            // Vision's NormalizedRect is bottom-left origin; flip y to top-left so
            // the reply reads like screen coordinates (see FaceLandmarks).
            let r = observation.boundingBox
            lines.append(.object([
                "text": .string(candidate.string),
                "confidence": .double(Double(candidate.confidence)),
                "box": .object([
                    "x": .double(Double(r.origin.x)),
                    "y": .double(Double(1 - r.origin.y - r.height)),
                    "width": .double(Double(r.width)),
                    "height": .double(Double(r.height)),
                ]),
            ]))
            strings.append(candidate.string)
        }

        guard !lines.isEmpty else {
            // Coachable degradation, not a failure: ok=true so the model speaks the
            // reason and asks for a recapture instead of treating it as an error.
            return [
                "usable": .bool(false),
                "reason": .string("no readable text — ask the user to hold the label steady and in focus"),
            ]
        }
        return [
            "usable": .bool(true),
            "lines": .array(lines),
            "text": .string(strings.joined(separator: "\n")),
        ]
    }
}
