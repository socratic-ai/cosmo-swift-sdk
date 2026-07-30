import Foundation
import Testing
import simd

import CosmoRealtime
import CosmoRealtimeARKit

@Suite struct ARFaceGeometryProjectorTests {

    // MARK: - Matrix helpers (column-major, like ARKit/simd)

    private static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
        return m
    }

    private static func rotationX(_ radians: Float) -> simd_float4x4 {
        let c = cos(radians), s = sin(radians)
        return simd_float4x4(columns: (
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, c, s, 0),
            SIMD4<Float>(0, -s, c, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }

    private static func rotationY(_ radians: Float) -> simd_float4x4 {
        let c = cos(radians), s = sin(radians)
        return simd_float4x4(columns: (
            SIMD4<Float>(c, 0, -s, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(s, 0, c, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }

    private static func rotationZ(_ radians: Float) -> simd_float4x4 {
        let c = cos(radians), s = sin(radians)
        return simd_float4x4(columns: (
            SIMD4<Float>(c, s, 0, 0),
            SIMD4<Float>(-s, c, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }

    private static func rotatedSnapshot(_ rotation: simd_float4x4) -> FaceAnchorSnapshot {
        FaceAnchorSnapshot(
            regionVertices: [:],
            anchorTransform: translation(SIMD3<Float>(0, 0, -0.5)) * rotation,
            viewMatrix: matrix_identity_float4x4,
            projectionMatrix: perspective()
        )
    }

    /// Standard right-handed perspective (looking down -z), à la Metal/ARKit.
    private static func perspective(fovY: Float = .pi / 3, aspect: Float = 1,
                                    near: Float = 0.01, far: Float = 10) -> simd_float4x4 {
        let yScale = 1 / tan(fovY / 2)
        let xScale = yScale / aspect
        let zRange = far - near
        return simd_float4x4(columns: (
            SIMD4<Float>(xScale, 0, 0, 0),
            SIMD4<Float>(0, yScale, 0, 0),
            SIMD4<Float>(0, 0, -(far + near) / zRange, -1),
            SIMD4<Float>(0, 0, -2 * far * near / zRange, 0)
        ))
    }

    /// A face directly in front of the camera, 0.5 m away, facing it.
    private static func neutralSnapshot(
        regionVertices: [String: [SIMD3<Float>]] = [:]
    ) -> FaceAnchorSnapshot {
        FaceAnchorSnapshot(
            regionVertices: regionVertices,
            anchorTransform: translation(SIMD3<Float>(0, 0, -0.5)),
            viewMatrix: matrix_identity_float4x4,
            projectionMatrix: perspective()
        )
    }

    // MARK: - Tests

    @Test("camera-to-face distance comes from the view-space translation")
    func distanceFromTranslation() throws {
        let g = ARFaceGeometryProjector.geometry(from: Self.neutralSnapshot())
        let d = try #require(g.distanceMeters)
        #expect(abs(d - 0.5) < 1e-4)
    }

    @Test("a head facing the camera decodes to ~zero pose")
    func neutralPose() throws {
        let p = try #require(ARFaceGeometryProjector.geometry(from: Self.neutralSnapshot()).pose)
        #expect(abs(p.rollDegrees) < 0.5)
        #expect(abs(p.yawDegrees) < 0.5)
        #expect(abs(p.pitchDegrees) < 0.5)
    }

    @Test("a +20° yaw rotation lands on the yaw channel with the right sign")
    func yawDecodes() throws {
        let p = try #require(ARFaceGeometryProjector.geometry(from: Self.rotatedSnapshot(Self.rotationY(.pi / 9))).pose)
        #expect(abs(p.yawDegrees - 20) < 0.5)   // signed — a sign flip must fail
        #expect(abs(p.pitchDegrees) < 0.5)
        #expect(abs(p.rollDegrees) < 0.5)
    }

    @Test("a +15° pitch rotation lands on the pitch channel with the right sign")
    func pitchDecodes() throws {
        let p = try #require(ARFaceGeometryProjector.geometry(from: Self.rotatedSnapshot(Self.rotationX(.pi / 12))).pose)
        #expect(abs(p.pitchDegrees - 15) < 0.5)
        #expect(abs(p.yawDegrees) < 0.5)
        #expect(abs(p.rollDegrees) < 0.5)
    }

    @Test("a +15° roll rotation lands on the roll channel with the right sign")
    func rollDecodes() throws {
        let p = try #require(ARFaceGeometryProjector.geometry(from: Self.rotatedSnapshot(Self.rotationZ(.pi / 12))).pose)
        #expect(abs(p.rollDegrees - 15) < 0.5)
        #expect(abs(p.yawDegrees) < 0.5)
        #expect(abs(p.pitchDegrees) < 0.5)
    }

    @Test("the face-center vertex projects to the image center")
    func centerProjection() throws {
        let g = ARFaceGeometryProjector.geometry(
            from: Self.neutralSnapshot(regionVertices: ["c": [SIMD3<Float>(0, 0, 0)]])
        )
        let box = try #require(g.regions["c"])
        #expect(abs((box.x + box.width / 2) - 0.5) < 1e-3)
        #expect(abs((box.y + box.height / 2) - 0.5) < 1e-3)
    }

    @Test("an all-off-screen region is omitted")
    func offScreenOmitted() {
        let g = ARFaceGeometryProjector.geometry(
            from: Self.neutralSnapshot(regionVertices: ["off": [SIMD3<Float>(100, 0, 0)]])
        )
        #expect(g.regions["off"] == nil)
    }

    @Test("a region's box bounds its on-screen vertices")
    func boxBoundsVertices() throws {
        // Two vertices symmetric about the optical axis in x, at the face plane.
        let g = ARFaceGeometryProjector.geometry(
            from: Self.neutralSnapshot(regionVertices: [
                "span": [SIMD3<Float>(-0.05, 0, 0), SIMD3<Float>(0.05, 0, 0)]
            ])
        )
        let box = try #require(g.regions["span"])
        // xScale (60° fovY, aspect 1) = 1/tan(30°) ≈ 1.732; ndc.x = 1.732 * (±0.05)/0.5 = ±0.1732
        // normalized x = 0.5 ± 0.0866 → box.x ≈ 0.4134, width ≈ 0.1732
        #expect(abs(box.x - 0.4134) < 2e-3)
        #expect(abs(box.width - 0.1732) < 2e-3)
        #expect(abs((box.y + box.height / 2) - 0.5) < 1e-3)
    }
}
