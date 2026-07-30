import CosmoRealtime
import CoreGraphics
import Foundation
import ImageIO

/// `measure_lighting` — reads the lighting in the current camera frame: overall
/// brightness (and whether it's too dark or too bright), how even the light is
/// left-to-right (one-sided shadows), and whether the cast is warm or cool. The
/// pure measurement lives in `LightingAnalysis`; this type adapts it to the wire
/// contract. Numbers and labels only — never an image.
public enum MeasureLightingTool: VisionToolProviding {
    public static let name = "measure_lighting"

    public static var toolDescription: String {
        """
        Measure the lighting in the current camera frame: overall brightness (and whether it's \
        too dark or too bright to judge color or detail), how even the light is left-to-right \
        (a one-sided shadow on the face), and whether the cast is warm or cool. Use it to fix \
        lighting before judging a shade or fine detail. Numbers and labels only — never an image.
        """
    }

    public static var parametersJSON: String { #"{"type":"object","properties":{}}"# }

    /// CoreImage's area-average is available on every OS the SDK targets, so the
    /// lighting read is always offered — no iOS 18 floor like the Vision tools.
    public static var isSupported: Bool { true }

    public static func run(
        frame: CGImage,
        args: [String: JSONValue],
        orientation: CGImagePropertyOrientation
    ) async throws -> [String: JSONValue] {
        guard let reading = LightingAnalysis.measure(of: frame, orientation: orientation) else {
            return [
                "usable": .bool(false),
                "reason": .string("couldn't read the lighting — ask the user to fill the frame and try again"),
            ]
        }
        return [
            "usable": .bool(true),
            "brightness": .int(reading.brightness),
            "assessment": .string(reading.assessment),
            "evenness": .int(reading.evenness),
            "balance": .string(reading.balance),
            "warmth": .string(reading.warmth),
        ]
    }
}
