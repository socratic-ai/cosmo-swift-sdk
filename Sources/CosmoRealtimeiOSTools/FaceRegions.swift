import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Stable wire keys for the facial regions `detect_face_regions` reports — the
/// makeup zones a coach points at. Kept out of the `@available` type so an app
/// can build the tool declaration / vocabulary on the SDK's iOS 16 floor without
/// OS gating.
public enum FaceRegionKey {
    public static let faceContour = "face_contour"
    public static let leftEye = "left_eye"
    public static let rightEye = "right_eye"
    public static let leftEyebrow = "left_eyebrow"
    public static let rightEyebrow = "right_eyebrow"
    public static let nose = "nose"
    public static let lips = "lips"
    public static let forehead = "forehead"
    public static let leftCheek = "left_cheek"
    public static let rightCheek = "right_cheek"

    /// The full vocabulary advertised to the model.
    public static let all = [
        faceContour, leftEye, rightEye, leftEyebrow, rightEyebrow,
        nose, lips, forehead, leftCheek, rightCheek,
    ]
}

/// Pure Vision wrapper for `detect_face_regions`: one still frame in, a normalized
/// box per facial region out, via iOS 18's value-type `DetectFaceLandmarksRequest`.
/// Landmark regions (eyes, brows, nose, lips, contour) come straight from Vision;
/// the soft zones (forehead, cheeks) are derived from the feature boxes + face
/// box. No camera and no image — unit-testable with a fixture `CGImage`; the
/// dispatcher turns `Result` into the JSON tool-reply and the consuming app draws.
@available(iOS 18, macOS 15, *)
public enum FaceRegions {

    public struct Result: Sendable, Equatable {
        public var faceFound: Bool
        /// region key → normalized [0,1] top-left box.
        public var boxes: [String: FaceLandmarks.Box]
    }

    /// Locate the regions of the most prominent face in `image`. Returns
    /// `faceFound == false` (not an error) when Vision resolves no face, so the
    /// caller can coach a recapture rather than narrate a guess.
    public static func detect(
        _ image: CGImage,
        orientation: CGImagePropertyOrientation = .up
    ) async throws -> Result {
        let request = DetectFaceLandmarksRequest()
        let faces = try await request.perform(on: image, orientation: orientation)
        guard let face = largestFace(in: faces), let lm = face.landmarks else {
            return Result(faceFound: false, boxes: [:])
        }

        var boxes: [String: FaceLandmarks.Box] = [:]
        func put(_ key: String, _ region: FaceObservation.Landmarks2D.Region) {
            if let box = Self.box(of: region) { boxes[key] = box }
        }
        put(FaceRegionKey.faceContour, lm.faceContour)
        put(FaceRegionKey.leftEye, lm.leftEye)
        put(FaceRegionKey.rightEye, lm.rightEye)
        put(FaceRegionKey.leftEyebrow, lm.leftEyebrow)
        put(FaceRegionKey.rightEyebrow, lm.rightEyebrow)
        put(FaceRegionKey.nose, lm.nose)
        put(FaceRegionKey.lips, lm.outerLips)

        // Soft zones Vision doesn't label — derived from features + face box.
        let faceBox = Self.topLeftBox(of: face.boundingBox)
        if let forehead = Self.forehead(brL: boxes[FaceRegionKey.leftEyebrow],
                                        brR: boxes[FaceRegionKey.rightEyebrow],
                                        face: faceBox) {
            boxes[FaceRegionKey.forehead] = forehead
        }
        if let cheek = Self.cheek(.left, eye: boxes[FaceRegionKey.leftEye],
                                  nose: boxes[FaceRegionKey.nose],
                                  lips: boxes[FaceRegionKey.lips], face: faceBox) {
            boxes[FaceRegionKey.leftCheek] = cheek
        }
        if let cheek = Self.cheek(.right, eye: boxes[FaceRegionKey.rightEye],
                                  nose: boxes[FaceRegionKey.nose],
                                  lips: boxes[FaceRegionKey.lips], face: faceBox) {
            boxes[FaceRegionKey.rightCheek] = cheek
        }
        return Result(faceFound: true, boxes: boxes)
    }

    // MARK: - Geometry

    /// Normalized top-left bounding box of a landmark region's points. Vision's
    /// region points are image-normalized, so `pointsInImageCoordinates` with a
    /// unit size + upper-left origin yields top-left [0,1] points directly.
    private static func box(of region: FaceObservation.Landmarks2D.Region) -> FaceLandmarks.Box? {
        let pts = region.pointsInImageCoordinates(CGSize(width: 1, height: 1), origin: .upperLeft)
        guard !pts.isEmpty,
              let minX = pts.map(\.x).min(), let maxX = pts.map(\.x).max(),
              let minY = pts.map(\.y).min(), let maxY = pts.map(\.y).max() else { return nil }
        return FaceLandmarks.Box(x: Double(minX), y: Double(minY),
                                 width: Double(maxX - minX), height: Double(maxY - minY))
    }

    /// Vision's face boundingBox is bottom-left; flip y to top-left (matches Box).
    private static func topLeftBox(of r: NormalizedRect) -> FaceLandmarks.Box {
        FaceLandmarks.Box(x: r.origin.x, y: 1 - r.origin.y - r.height, width: r.width, height: r.height)
    }

    private enum Side { case left, right }

    /// Above the brows, up to the top of the face box.
    private static func forehead(brL: FaceLandmarks.Box?, brR: FaceLandmarks.Box?,
                                 face: FaceLandmarks.Box) -> FaceLandmarks.Box? {
        guard let brL, let brR else { return nil }
        let minX = min(brL.x, brR.x)
        let maxX = max(brL.x + brL.width, brR.x + brR.width)
        let bottom = min(brL.y, brR.y)   // top edge of the brows
        let top = face.y                  // face box top
        guard bottom > top, maxX > minX else { return nil }
        return FaceLandmarks.Box(x: minX, y: top, width: maxX - minX, height: bottom - top)
    }

    /// Below the eye, between the nose and the face edge, down to the lip line.
    private static func cheek(_ side: Side, eye: FaceLandmarks.Box?, nose: FaceLandmarks.Box?,
                              lips: FaceLandmarks.Box?, face: FaceLandmarks.Box) -> FaceLandmarks.Box? {
        guard let eye, let nose, let lips else { return nil }
        let top = eye.y + eye.height
        let bottom = lips.y
        guard bottom > top else { return nil }
        let a: Double, b: Double
        switch side {
        case .left:  a = face.x;               b = nose.x                  // image-left
        case .right: a = nose.x + nose.width;  b = face.x + face.width
        }
        let minX = min(a, b), maxX = max(a, b)
        guard maxX > minX else { return nil }
        return FaceLandmarks.Box(x: minX, y: top, width: maxX - minX, height: bottom - top)
    }

    private static func largestFace(in faces: [FaceObservation]) -> FaceObservation? {
        faces.max { a, b in
            a.boundingBox.width * a.boundingBox.height < b.boundingBox.width * b.boundingBox.height
        }
    }
}
