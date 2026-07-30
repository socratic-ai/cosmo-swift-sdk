import CoreGraphics
import CosmoRealtime
import Foundation
import ImageIO

/// Per-frame face geometry via the on-device Vision tools — the building block of
/// the device-universal `VisionFaceGeometrySource` baseline. Reuses `FaceRegions`
/// for feature boxes; it deliberately does NOT run a second Vision pass for pose
/// or contours — those `FaceGeometry` fields are filled by richer backends (ARKit
/// supplies an accurate 3D pose; contour outlines arrive with `detect_face_contours`).
/// Fixture-testable; no camera, no pixels out.
@available(iOS 18, macOS 15, *)
public enum VisionFaceGeometry {
    /// Resolve `image` to normalized face geometry, or `nil` when no clear face is
    /// found — the per-frame transform a `FaceGeometrySource` runs in its loop. One
    /// Vision request per frame.
    public static func extract(
        from image: CGImage,
        orientation: CGImagePropertyOrientation = .up
    ) async throws -> FaceGeometry? {
        let detected = try await FaceRegions.detect(image, orientation: orientation)
        guard detected.faceFound else { return nil }

        let regions = detected.boxes.mapValues { NormalizedBox($0) }
        return FaceGeometry(regions: regions)
    }
}

@available(iOS 18, macOS 15, *)
extension NormalizedBox {
    /// Adopt a Vision tool's `FaceLandmarks.Box` — same normalized top-left fields.
    init(_ box: FaceLandmarks.Box) {
        self.init(x: box.x, y: box.y, width: box.width, height: box.height)
    }
}
