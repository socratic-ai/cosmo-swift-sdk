import simd

/// Derives the coarse makeup-zone regions (forehead, cheeks) from ARKit's
/// documented eye transforms. ARKit's 1220-vertex face mesh is unlabeled, so we
/// anchor the zones to the stable eye landmarks instead of guessing vertex
/// indices: the inputs don't drift across iOS/device versions, and only the
/// offset multipliers below want a quick on-device tune. Pure (no ARKit) so the
/// geometry is unit-tested off-device.
enum FaceRegionLayout {
    // Wire keys — mirror the cross-backend region vocabulary (FaceRegionKey in
    // CosmoRealtimeiOSTools) so an overlay treats the ARKit and Vision backends
    // identically. Renaming any of these is a wire break.
    static let forehead = "forehead"
    static let leftCheek = "left_cheek"
    static let rightCheek = "right_cheek"

    // Offsets are expressed in interocular distances (the eye-to-eye span), so
    // they scale with face size and camera distance. Coarse by design — tune on
    // a real device.
    private static let foreheadRise: Float = 0.75
    private static let cheekDrop: Float = 0.6
    private static let halfExtent: Float = 0.22

    /// Region corner points in anchor-local space, from the user's left/right eye
    /// positions (also anchor-local). Each region is a small quad the projector
    /// bounds into a normalized box.
    static func regionVertices(
        leftEye: SIMD3<Float>, rightEye: SIMD3<Float>
    ) -> [String: [SIMD3<Float>]] {
        let midpoint = (leftEye + rightEye) / 2
        let interocular = simd_length(rightEye - leftEye)
        let up = SIMD3<Float>(0, 1, 0)
        let half = interocular * halfExtent

        return [
            forehead: quad(center: midpoint + up * (interocular * foreheadRise), half: half),
            leftCheek: quad(center: leftEye - up * (interocular * cheekDrop), half: half),
            rightCheek: quad(center: rightEye - up * (interocular * cheekDrop), half: half),
        ]
    }

    /// Four corners of an axis-aligned square in the anchor-local x-y plane.
    private static func quad(center: SIMD3<Float>, half: Float) -> [SIMD3<Float>] {
        [
            center + SIMD3<Float>(-half, -half, 0),
            center + SIMD3<Float>(half, -half, 0),
            center + SIMD3<Float>(half, half, 0),
            center + SIMD3<Float>(-half, half, 0),
        ]
    }
}
