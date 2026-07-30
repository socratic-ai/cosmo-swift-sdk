import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CosmoRealtime
import Foundation
import ImageIO

/// Pure on-device lighting measurement: overall brightness, left/right evenness,
/// and a warm/cool cast for a still frame. No Vision request, no pixels out — just
/// numbers and labels. `MeasureLightingTool` adapts this to the wire contract.
public enum LightingAnalysis {
    public struct Reading: Sendable, Equatable {
        public let brightness: Int    // 0...100, mean Rec.709 luma Y′ (gamma-encoded — perceptual, not linear luminance)
        public let assessment: String // "too_dark" | "good" | "too_bright"
        public let evenness: Int      // 0...100, 100 == even left-to-right
        public let balance: String    // "even" | "brighter_left" | "brighter_right"
        public let warmth: String     // "warm" | "neutral" | "cool"
    }

    /// Measure the lighting of `image`, honoring `orientation`. Returns `nil` when
    /// the frame is too small to split into left/right halves.
    public static func measure(
        of image: CGImage,
        orientation: CGImagePropertyOrientation = .up
    ) -> Reading? {
        let oriented = CIImage(cgImage: image).oriented(orientation)
        let extent = oriented.extent
        guard extent.width >= 2, extent.height >= 1 else { return nil }
        let context = CIContext(options: [.workingColorSpace: NSNull()])

        let half = extent.width / 2
        let leftRect = CGRect(x: extent.origin.x, y: extent.origin.y, width: half, height: extent.height)
        let rightRect = CGRect(x: extent.origin.x + half, y: extent.origin.y, width: half, height: extent.height)
        guard let whole = averageRGB(oriented, extent, context),
              let left = averageRGB(oriented, leftRect, context),
              let right = averageRGB(oriented, rightRect, context) else { return nil }

        let brightness = Int((Double(luma(whole)) / 255 * 100).rounded())
        let assessment: String
        switch brightness {
        case ..<25: assessment = "too_dark"
        case 90...: assessment = "too_bright"
        default: assessment = "good"
        }

        let lL = luma(left), lR = luma(right)
        let imbalance = Double(abs(lL - lR)) / Double(max(lL, lR, 1))
        let evenness = Int(((1 - min(imbalance, 1)) * 100).rounded())
        let balance: String
        if imbalance < 0.15 { balance = "even" }
        else if lL > lR { balance = "brighter_left" }
        else { balance = "brighter_right" }

        // Intensity-invariant warm/cool: the ratio (r-b)/(r+b), not a raw r-b
        // diff, so the same colour temperature reads the same at any exposure.
        let redBlue = whole.r + whole.b
        let warmth: String
        if redBlue == 0 {
            warmth = "neutral"
        } else {
            let warmRatio = Double(whole.r - whole.b) / Double(redBlue)
            warmth = warmRatio > 0.10 ? "warm" : (warmRatio < -0.10 ? "cool" : "neutral")
        }

        return Reading(
            brightness: brightness, assessment: assessment,
            evenness: evenness, balance: balance, warmth: warmth
        )
    }

    private struct RGB { let r: Int; let g: Int; let b: Int }

    private static func averageRGB(_ image: CIImage, _ region: CGRect, _ context: CIContext) -> RGB? {
        let clipped = region.intersection(image.extent)
        guard clipped.width >= 1, clipped.height >= 1 else { return nil }
        let filter = CIFilter.areaAverage()
        filter.inputImage = image
        filter.extent = clipped
        guard let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            output, toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return RGB(r: Int(pixel[0]), g: Int(pixel[1]), b: Int(pixel[2]))
    }

    /// Rec.709 luma Y′ over gamma-encoded sRGB — the perceptual "how bright it
    /// looks" value, not linear luminance Y (which would need linearization first).
    private static func luma(_ c: RGB) -> Int {
        Int((0.2126 * Double(c.r) + 0.7152 * Double(c.g) + 0.0722 * Double(c.b)).rounded())
    }
}
