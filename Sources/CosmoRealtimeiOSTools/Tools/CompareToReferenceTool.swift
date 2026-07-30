import CosmoRealtime
import CoreGraphics
import Foundation
import ImageIO

/// `compare_to_reference` — a COARSE perceptual likeness check between two regions
/// of the current frame, via Vision image feature prints. It answers a rough "do
/// these two regions look alike?" (e.g. the user's two eyes) as a relative,
/// rank-only score — not a geometric symmetry measurement, and not a percentage.
/// The pure measurement lives in `ReferenceComparison`; this type adapts it to the
/// wire contract. Numbers only.
///
/// Single-frame and stateless by design: comparing against an out-of-frame
/// reference (a saved "after" shot, a tutorial still) needs app-held state and is
/// a recipe pattern, not an SDK capability.
public enum CompareToReferenceTool: VisionToolProviding {
    public static let name = "compare_to_reference"

    public static var toolDescription: String {
        """
        Roughly compare how alike two regions of the current frame look — a coarse "do these \
        resemble each other?" check (e.g. the user's two eyes). Returns a relative, rank-only \
        closeness score (higher means more alike) plus a raw distance; compare scores against \
        each other, not as an absolute percentage or an exact symmetry measure. Numbers only.
        """
    }

    public static var parametersJSON: String {
        #"""
        {"type":"object","properties":{"subject":{"type":"object","description":"The region being checked, e.g. the side in progress. Normalized [0,1], top-left origin.","properties":{"x":{"type":"number","minimum":0,"maximum":1},"y":{"type":"number","minimum":0,"maximum":1},"width":{"type":"number","minimum":0,"maximum":1},"height":{"type":"number","minimum":0,"maximum":1}},"required":["x","y","width","height"]},"reference":{"type":"object","description":"The region to match against, e.g. the side that already looks right. Normalized [0,1], top-left origin.","properties":{"x":{"type":"number","minimum":0,"maximum":1},"y":{"type":"number","minimum":0,"maximum":1},"width":{"type":"number","minimum":0,"maximum":1},"height":{"type":"number","minimum":0,"maximum":1}},"required":["x","y","width","height"]}},"required":["subject","reference"]}
        """#
    }

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
        guard let subject = NormalizedBox(json: args["subject"]),
              let reference = NormalizedBox(json: args["reference"]) else {
            return [
                "usable": .bool(false),
                "reason": .string("pass a subject and a reference region to compare"),
            ]
        }
        guard let result = try await ReferenceComparison.compare(
            subject, to: reference, in: frame, orientation: orientation
        ) else {
            // Coachable degradation: the regions clamped too small to feature-print.
            return [
                "usable": .bool(false),
                "reason": .string("those regions are too small to compare — ask the user to move closer or use larger boxes"),
            ]
        }
        return [
            "usable": .bool(true),
            "similarity": .double(result.similarity),
            "distance": .double(result.distance),
        ]
    }
}
