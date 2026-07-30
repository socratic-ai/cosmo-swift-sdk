import CoreGraphics
import CoreImage
import CoreVideo
import ImageIO

/// Converts a camera pixel buffer (e.g. ARKit's `ARFrame.capturedImage`) into an
/// **upright** `CGImage` the single-frame Vision tools can measure. The
/// `orientation` (native sensor → upright for the current interface) is baked in,
/// so the result is ready to hand to `VisionToolDispatcher.run` with no
/// orientation argument. Pure (no ARKit) — unit-tested off-device.
public enum ARFrameStillBridge {
    private static let context = CIContext()

    public static func uprightImage(
        from pixelBuffer: CVPixelBuffer,
        applying orientation: CGImagePropertyOrientation
    ) -> CGImage? {
        let image = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        return context.createCGImage(image, from: image.extent)
    }
}
