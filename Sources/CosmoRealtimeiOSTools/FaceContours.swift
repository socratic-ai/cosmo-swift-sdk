import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Stable wire keys for the contours `detect_face_contours` reports that aren't
/// already in `FaceRegionKey` — kept out of the `@available` type so the
/// vocabulary builds on the SDK's lower floor without OS gating.
public enum FaceContourKey {
    public static let innerLips = "inner_lips"
    public static let leftPupil = "left_pupil"
    public static let rightPupil = "right_pupil"
}

/// Pure Vision wrapper for `detect_face_contours`: one still frame in, a normalized
/// point outline per facial feature out, via iOS 18's value-type
/// `DetectFaceLandmarksRequest`. The points are the same ones `FaceRegions` reduces
/// to boxes — here we return the outline itself so the model can trace it with
/// `draw_path`. No camera and no image — unit-testable with a fixture `CGImage`.
@available(iOS 18, macOS 15, *)
public enum FaceContours {
    /// One outline point, normalized `[0,1]`, top-left origin.
    public struct Point: Sendable, Equatable {
        public let x: Double
        public let y: Double
    }

    public struct Result: Sendable, Equatable {
        public var faceFound: Bool
        /// region key → ordered outline points, normalized [0,1] top-left.
        public var contours: [String: [Point]]
    }

    /// Outline the most prominent face in `image`. Returns `faceFound == false`
    /// (not an error) when Vision resolves no face, so the caller can coach a
    /// recapture rather than narrate a guess.
    public static func detect(
        _ image: CGImage,
        orientation: CGImagePropertyOrientation = .up
    ) async throws -> Result {
        let request = DetectFaceLandmarksRequest()
        let faces = try await request.perform(on: image, orientation: orientation)
        guard let face = largestFace(in: faces), let lm = face.landmarks else {
            return Result(faceFound: false, contours: [:])
        }

        var contours: [String: [Point]] = [:]
        func put(_ key: String, _ region: FaceObservation.Landmarks2D.Region) {
            let pts = points(of: region)
            if !pts.isEmpty { contours[key] = pts }
        }
        put(FaceRegionKey.faceContour, lm.faceContour)
        put(FaceRegionKey.leftEye, lm.leftEye)
        put(FaceRegionKey.rightEye, lm.rightEye)
        put(FaceRegionKey.leftEyebrow, lm.leftEyebrow)
        put(FaceRegionKey.rightEyebrow, lm.rightEyebrow)
        put(FaceRegionKey.nose, lm.nose)
        put(FaceRegionKey.lips, lm.outerLips)
        put(FaceContourKey.innerLips, lm.innerLips)
        put(FaceContourKey.leftPupil, lm.leftPupil)
        put(FaceContourKey.rightPupil, lm.rightPupil)
        return Result(faceFound: true, contours: contours)
    }

    /// Vision's region points are image-normalized, so `pointsInImageCoordinates`
    /// with a unit size + upper-left origin yields top-left [0,1] points directly
    /// (mirrors `FaceRegions.box`).
    private static func points(of region: FaceObservation.Landmarks2D.Region) -> [Point] {
        region.pointsInImageCoordinates(CGSize(width: 1, height: 1), origin: .upperLeft)
            .map { Point(x: Double($0.x), y: Double($0.y)) }
    }

    private static func largestFace(in faces: [FaceObservation]) -> FaceObservation? {
        faces.max { a, b in
            a.boundingBox.width * a.boundingBox.height < b.boundingBox.width * b.boundingBox.height
        }
    }
}
