import CosmoRealtime
import CoreGraphics
import Foundation
import ImageIO

/// `analyze_color` — reads the average color of the current camera frame, or of a
/// region the model passes as a normalized box (e.g. the `lips` box from
/// `detect_face_regions`, to name a lipstick shade). The pure measurement lives in
/// `ColorAnalysis`; this type adapts it to the wire contract. Numbers only — never
/// an image.
public enum AnalyzeColorTool: VisionToolProviding {
    public static let name = "analyze_color"

    public static var toolDescription: String {
        """
        Measure the average color of the current camera frame, or of a region you pass as a \
        normalized box ([0,1], top-left origin) — e.g. the lips box from detect_face_regions to \
        read a lipstick shade. Returns the color as hex, RGB, and HSB so you can name the shade \
        yourself. Numbers only — never an image.
        """
    }

    public static var parametersJSON: String {
        #"""
        {"type":"object","properties":{"box":{"type":"object","description":"Optional region to sample, normalized to the frame you were shown: [0,1], top-left origin. Omit to average the whole frame.","properties":{"x":{"type":"number","minimum":0,"maximum":1},"y":{"type":"number","minimum":0,"maximum":1},"width":{"type":"number","minimum":0,"maximum":1},"height":{"type":"number","minimum":0,"maximum":1}},"required":["x","y","width","height"]}}}
        """#
    }

    /// CoreImage's area-average is available on every OS the SDK targets, so the
    /// color read is always offered — no iOS 18 floor like the Vision tools.
    public static var isSupported: Bool { true }

    public static func run(
        frame: CGImage,
        args: [String: JSONValue],
        orientation: CGImagePropertyOrientation
    ) async throws -> [String: JSONValue] {
        let box = NormalizedBox(json: args["box"])
        guard let color = ColorAnalysis.averageColor(of: frame, in: box, orientation: orientation) else {
            // Coachable degradation, not a failure: the region clamped to nothing.
            return [
                "usable": .bool(false),
                "reason": .string("could not read a color there — ask the user to fill the frame and try again"),
            ]
        }
        return [
            "usable": .bool(true),
            "hex": .string(color.hex),
            "rgb": .object(["r": .int(color.r), "g": .int(color.g), "b": .int(color.b)]),
            "hsb": .object(["h": .int(color.hue), "s": .int(color.saturation), "b": .int(color.brightness)]),
        ]
    }
}
