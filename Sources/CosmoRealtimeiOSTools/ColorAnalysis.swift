import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CosmoRealtime
import Foundation
import ImageIO

/// Pure on-device color measurement: the average color of a region of a still
/// frame, plus derived HSB. No Vision request, no pixels out — just numbers;
/// `AnalyzeColorTool` adapts this to the wire contract. The average is
/// approximate/perceptual — computed in gamma-encoded sRGB, not linearized — so
/// it reflects "how it looks", not a colorimetric mean.
public enum ColorAnalysis {
    public struct Color: Sendable, Equatable {
        public let r: Int          // 0...255
        public let g: Int
        public let b: Int
        public let hue: Int        // 0...359
        public let saturation: Int // 0...100
        public let brightness: Int // 0...100
        public let hex: String     // "#RRGGBB"
    }

    /// Average color over `box` (normalized `[0,1]`, top-left origin) of `image`,
    /// honoring `orientation`. `box == nil` averages the whole frame. Returns
    /// `nil` when the region is empty after clamping to the frame.
    public static func averageColor(
        of image: CGImage,
        in box: NormalizedBox? = nil,
        orientation: CGImagePropertyOrientation = .up
    ) -> Color? {
        let oriented = CIImage(cgImage: image).oriented(orientation)
        let extent = oriented.extent
        guard extent.width >= 1, extent.height >= 1 else { return nil }

        let region: CGRect
        if let box {
            let x = clamp01(box.x), y = clamp01(box.y)
            let w = clamp01(box.width), h = clamp01(box.height)
            // Normalized top-left → CoreImage's bottom-left extent space (y up).
            region = CGRect(
                x: extent.origin.x + x * extent.width,
                y: extent.origin.y + (1 - y - h) * extent.height,
                width: w * extent.width,
                height: h * extent.height
            ).intersection(extent)
        } else {
            region = extent
        }
        guard region.width >= 1, region.height >= 1 else { return nil }

        let filter = CIFilter.areaAverage()
        filter.inputImage = oriented
        filter.extent = region
        guard let output = filter.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        context.render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        )
        return color(r: Int(pixel[0]), g: Int(pixel[1]), b: Int(pixel[2]))
    }

    static func color(r: Int, g: Int, b: Int) -> Color {
        let (h, s, v) = hsb(r: r, g: g, b: b)
        return Color(
            r: r, g: g, b: b,
            hue: h, saturation: s, brightness: v,
            hex: String(format: "#%02X%02X%02X", r, g, b)
        )
    }

    private static func hsb(r: Int, g: Int, b: Int) -> (Int, Int, Int) {
        let rf = Double(r) / 255, gf = Double(g) / 255, bf = Double(b) / 255
        let maxv = max(rf, gf, bf), minv = min(rf, gf, bf)
        let delta = maxv - minv
        var h = 0.0
        if delta > 0 {
            if maxv == rf {
                h = 60 * (((gf - bf) / delta).truncatingRemainder(dividingBy: 6))
            } else if maxv == gf {
                h = 60 * ((bf - rf) / delta + 2)
            } else {
                h = 60 * ((rf - gf) / delta + 4)
            }
        }
        if h < 0 { h += 360 }
        let s = maxv == 0 ? 0.0 : delta / maxv
        return (Int(h.rounded()) % 360, Int((s * 100).rounded()), Int((maxv * 100).rounded()))
    }

    private static func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }
}
