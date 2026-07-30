import simd

/// A device-independent snapshot of one ARKit face frame — the seam between the
/// live `ARSession` shell (which fills it from `ARFaceAnchor` / `ARCamera`) and
/// the pure projector. Holds no ARKit types, so the projection math runs and is
/// unit-tested on any platform.
public struct FaceAnchorSnapshot: Sendable {
    /// Selected face-mesh vertices in anchor-local space, keyed by region name.
    public var regionVertices: [String: [SIMD3<Float>]]
    /// Face anchor transform: anchor-local → world.
    public var anchorTransform: simd_float4x4
    /// Camera view matrix: world → camera/view space.
    public var viewMatrix: simd_float4x4
    /// Camera projection matrix: view → clip space.
    public var projectionMatrix: simd_float4x4

    public init(
        regionVertices: [String: [SIMD3<Float>]],
        anchorTransform: simd_float4x4,
        viewMatrix: simd_float4x4,
        projectionMatrix: simd_float4x4
    ) {
        self.regionVertices = regionVertices
        self.anchorTransform = anchorTransform
        self.viewMatrix = viewMatrix
        self.projectionMatrix = projectionMatrix
    }
}
