import CosmoRealtime
import CoreGraphics
import Foundation
import ImageIO
import Vision

/// `check_capture_quality` — the PERCEIVE quality gate. Measures how usable the
/// current camera frame is for face analysis via iOS 18's value-type
/// `DetectFaceCaptureQualityRequest`, which scores the most prominent face on a
/// [0,1] capture-quality scale. The model calls it before trusting other face
/// measurements so it can ask for better lighting/framing first; a frame with no
/// clear face returns `usable:false` (coachable degradation, not an error).
public enum CaptureQualityTool: VisionToolProviding {
    public static let name = "check_capture_quality"

    public static var toolDescription: String {
        """
        Measure how usable the current camera frame is for face analysis: returns a \
        0–1 capture-quality score for the most prominent face so you can ask for better \
        lighting or framing before trusting other face measurements. Returns \
        `usable:false` when no clear face is detected so you can ask the user to reframe.
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
        let request = DetectFaceCaptureQualityRequest()
        let faces = try await request.perform(on: frame, orientation: orientation)
        guard let face = largestFace(in: faces) else {
            // Coachable degradation, not a failure: ok=true so the model speaks the
            // reason and asks for a recapture instead of treating it as an error.
            return [
                "usable": .bool(false),
                "reason": .string("no clear face detected — ask the user to face the camera in good light"),
            ]
        }
        // captureQuality is optional; a resolved face without a score is still a real
        // face, so report it as usable with a 0 score rather than degrading.
        let score = Double(face.captureQuality?.score ?? 0)
        return [
            "usable": .bool(true),
            "quality_score": .double(score),
            "face_count": .int(faces.count),
        ]
    }

    @available(iOS 18, macOS 15, *)
    private static func largestFace(in faces: [FaceObservation]) -> FaceObservation? {
        faces.max { a, b in area(a.boundingBox) < area(b.boundingBox) }
    }

    @available(iOS 18, macOS 15, *)
    private static func area(_ r: NormalizedRect) -> Double { r.width * r.height }
}
