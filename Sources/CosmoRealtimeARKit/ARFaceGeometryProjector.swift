import Foundation
import simd

import CosmoRealtime

/// Turns a `FaceAnchorSnapshot` into the SDK's normalized `FaceGeometry`: head
/// pose + camera distance from the anchor transform, and `[0,1]` regions from
/// projecting the selected mesh vertices. Pure (no ARKit), so it runs and is
/// unit-tested on any platform.
public enum ARFaceGeometryProjector {
    public static func geometry(from snapshot: FaceAnchorSnapshot) -> FaceGeometry {
        let faceInView = snapshot.viewMatrix * snapshot.anchorTransform
        let pose = headPose(faceInView)
        let origin = faceInView.columns.3
        let distance = Double(simd_length(SIMD3<Float>(origin.x, origin.y, origin.z)))

        let mvp = snapshot.projectionMatrix * faceInView
        var regions: [String: NormalizedBox] = [:]
        for (name, vertices) in snapshot.regionVertices {
            if let box = boundingBox(of: vertices, mvp: mvp) {
                regions[name] = box
            }
        }
        return FaceGeometry(regions: regions, pose: pose, distanceMeters: distance)
    }

    /// Tait–Bryan angles of the face relative to the camera, in degrees. A pure
    /// rotation about one axis lands entirely on that axis's channel.
    private static func headPose(_ faceInView: simd_float4x4) -> FacePose {
        let r02 = faceInView.columns.2.x
        let r22 = faceInView.columns.2.z
        let r12 = faceInView.columns.2.y
        let r10 = faceInView.columns.0.y
        let r11 = faceInView.columns.1.y
        let yaw = atan2(r02, r22)
        let pitch = asin(max(-1, min(1, -r12)))
        let roll = atan2(r10, r11)
        let toDegrees = Float(180) / .pi
        return FacePose(
            rollDegrees: Double(roll * toDegrees),
            yawDegrees: Double(yaw * toDegrees),
            pitchDegrees: Double(pitch * toDegrees)
        )
    }

    /// Normalized `[0,1]` top-left bounding box of the vertices that project on
    /// screen and in front of the camera; `nil` when none do.
    private static func boundingBox(
        of vertices: [SIMD3<Float>], mvp: simd_float4x4
    ) -> NormalizedBox? {
        var minX = Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude
        var maxX = -Float.greatestFiniteMagnitude
        var maxY = -Float.greatestFiniteMagnitude
        var found = false
        for vertex in vertices {
            let clip = mvp * SIMD4<Float>(vertex.x, vertex.y, vertex.z, 1)
            guard clip.w > 0 else { continue }   // behind the camera
            let nx = (clip.x / clip.w) * 0.5 + 0.5
            let ny = 0.5 - (clip.y / clip.w) * 0.5   // flip y for top-left origin
            guard nx >= 0, nx <= 1, ny >= 0, ny <= 1 else { continue }   // off screen
            minX = min(minX, nx); maxX = max(maxX, nx)
            minY = min(minY, ny); maxY = max(maxY, ny)
            found = true
        }
        guard found else { return nil }
        return NormalizedBox(
            x: Double(minX), y: Double(minY),
            width: Double(maxX - minX), height: Double(maxY - minY)
        )
    }
}
