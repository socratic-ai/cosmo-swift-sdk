import CoreGraphics
import Foundation
import ImageIO

/// Shared test fixtures for the iOS-tools suite — load a bundled image or
/// synthesize a blank frame, instead of copy-pasting the loader into every suite.
enum Fixtures {
    struct MissingFixture: Error { let name: String }

    /// Load a bundled image (`Tests/.../Fixtures/<name>.<ext>`) + its EXIF orientation.
    static func image(named name: String, ext: String) throws -> (CGImage, CGImagePropertyOrientation) {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw MissingFixture(name: "\(name).\(ext)")
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let raw = (props?[kCGImagePropertyOrientation] as? UInt32) ?? 1
        return (image, CGImagePropertyOrientation(rawValue: raw) ?? .up)
    }

    /// A solid-white frame — stands in for "a frame with no face".
    static func blank(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
