import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Pure Vision wrapper for `detect_face_landmarks`: one still frame in, a typed
/// facial measurement out, via iOS 18's value-type `DetectFaceLandmarksRequest`.
/// No camera and no wire types — unit-testable with a fixture `CGImage`. The
/// dispatcher turns `Measurement` into the JSON tool-reply.
@available(iOS 18, macOS 15, *)
public enum FaceLandmarks {
    /// Normalized face box, **top-left origin** ([0,1], y increases downward) —
    /// converted from Vision's bottom-left `NormalizedRect` so it matches the
    /// screen/app coordinate convention a consumer expects.
    public struct Box: Sendable, Equatable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double

        /// Center within 15% of the frame midpoint on both axes — enough to coach
        /// "move left/right/up/down" without shipping the pixels.
        public var isRoughlyCentered: Bool {
            abs((x + width / 2) - 0.5) <= 0.15 && abs((y + height / 2) - 0.5) <= 0.15
        }
    }

    /// JSON-native facial measurement — numbers only, never the image.
    public struct Measurement: Sendable, Equatable {
        public var faceFound: Bool
        public var faceCount: Int
        public var boundingBox: Box?
        public var rollDegrees: Double?
        public var yawDegrees: Double?
        public var pitchDegrees: Double?
        public var landmarksAvailable: Bool
    }

    /// Measure the most prominent face in `image`. Returns `faceFound == false`
    /// (not an error) when Vision resolves no face, so the caller can coach a
    /// recapture rather than narrate a guess.
    public static func measure(
        _ image: CGImage,
        orientation: CGImagePropertyOrientation = .up
    ) async throws -> Measurement {
        let request = DetectFaceLandmarksRequest()
        let faces = try await request.perform(on: image, orientation: orientation)
        guard let face = largestFace(in: faces) else {
            return Measurement(
                faceFound: false, faceCount: 0, boundingBox: nil,
                rollDegrees: nil, yawDegrees: nil, pitchDegrees: nil,
                landmarksAvailable: false
            )
        }
        // Vision's NormalizedRect is bottom-left origin; flip y to top-left so
        // the reply reads like screen coordinates.
        let r = face.boundingBox
        let box = Box(x: r.origin.x, y: 1 - r.origin.y - r.height, width: r.width, height: r.height)
        return Measurement(
            faceFound: true,
            faceCount: faces.count,
            boundingBox: box,
            rollDegrees: face.roll.converted(to: .degrees).value,
            yawDegrees: face.yaw.converted(to: .degrees).value,
            pitchDegrees: face.pitch.converted(to: .degrees).value,
            landmarksAvailable: face.landmarks != nil
        )
    }

    private static func largestFace(in faces: [FaceObservation]) -> FaceObservation? {
        faces.max { a, b in area(a.boundingBox) < area(b.boundingBox) }
    }

    private static func area(_ r: NormalizedRect) -> Double { r.width * r.height }
}
