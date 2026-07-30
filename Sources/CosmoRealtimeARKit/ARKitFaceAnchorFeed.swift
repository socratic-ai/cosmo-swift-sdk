#if os(iOS)
import ARKit
import CoreGraphics
import CosmoRealtime
import Foundation
import ImageIO
import os
import simd
import UIKit

extension ARKitFaceGeometrySource {
    /// True when the device has a front TrueDepth camera for ARKit face tracking.
    public static var isSupported: Bool { ARFaceTrackingConfiguration.isSupported }

    /// A source backed by a live front-camera `ARSession`. `viewportSize` is the
    /// preview view's size in points — it sets the projection so the normalized
    /// regions land on that preview.
    public convenience init(viewportSize: CGSize, orientation: UIInterfaceOrientation = .portrait) {
        self.init(feed: ARKitFaceAnchorFeed(viewportSize: viewportSize, orientation: orientation))
    }
}

/// Live face-anchor feed: runs an `ARFaceTrackingConfiguration` session and turns
/// each tracked `ARFaceAnchor` into a device-independent `FaceAnchorSnapshot`.
/// Device-only (no simulator / CI) and intentionally thin — the math it feeds is
/// covered by `ARFaceGeometryProjectorTests` / `FaceRegionLayoutTests`.
final class ARKitFaceAnchorFeed: NSObject, FaceAnchorFeed, ARSessionDelegate {
    let snapshots: AsyncStream<FaceAnchorSnapshot?>

    private let continuation: AsyncStream<FaceAnchorSnapshot?>.Continuation
    private let session = ARSession()
    private let viewportSize: CGSize
    private let orientation: UIInterfaceOrientation
    private static let log = Logger(subsystem: CosmoRealtimeLog.subsystem, category: "face-tracking")
    private var loggedFailure = false

    init(viewportSize: CGSize, orientation: UIInterfaceOrientation) {
        self.viewportSize = viewportSize
        self.orientation = orientation
        (snapshots, continuation) =
            AsyncStream<FaceAnchorSnapshot?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        super.init()
        session.delegate = self
    }

    deinit {
        // Don't leave the TrueDepth camera running if the feed is dropped
        // without an explicit stop().
        session.pause()
        continuation.finish()
    }

    func start() {
        guard ARFaceTrackingConfiguration.isSupported else {
            Self.log.error("ARKit face tracking is unsupported on this device")
            continuation.finish()
            return
        }
        session.run(ARFaceTrackingConfiguration(), options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        session.pause()
        continuation.finish()
    }

    func currentImage() -> CGImage? {
        guard let pixelBuffer = session.currentFrame?.capturedImage else { return nil }
        return ARFrameStillBridge.uprightImage(from: pixelBuffer, applying: stillOrientation)
    }

    /// `CGImagePropertyOrientation` that rights the front-camera capture for the
    /// current interface orientation. Coarse defaults — validate on a device.
    private var stillOrientation: CGImagePropertyOrientation {
        switch orientation {
        case .portrait: return .right
        case .portraitUpsideDown: return .left
        case .landscapeLeft: return .down
        case .landscapeRight: return .up
        default: return .right
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let faceAnchor = frame.anchors.lazy.compactMap({ $0 as? ARFaceAnchor }).first,
              faceAnchor.isTracked else {
            continuation.yield(nil)   // no tracked face this update
            return
        }
        loggedFailure = false   // a tracked frame means the session recovered
        let regionVertices = FaceRegionLayout.regionVertices(
            leftEye: faceAnchor.leftEyeTransform.translation,
            rightEye: faceAnchor.rightEyeTransform.translation
        )
        continuation.yield(
            FaceAnchorSnapshot(
                regionVertices: regionVertices,
                anchorTransform: faceAnchor.transform,
                viewMatrix: frame.camera.viewMatrix(for: orientation),
                projectionMatrix: frame.camera.projectionMatrix(
                    for: orientation, viewportSize: viewportSize, zNear: 0.001, zFar: 10
                )
            )
        )
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        if !loggedFailure {
            Self.log.error("ARKit face session failed: \(error.localizedDescription, privacy: .public)")
            loggedFailure = true
        }
        continuation.yield(nil)   // clear the overlay's last face
        continuation.finish()     // terminal — mirror the unsupported-device path
    }
}

private extension simd_float4x4 {
    var translation: SIMD3<Float> { SIMD3(columns.3.x, columns.3.y, columns.3.z) }
}
#endif
