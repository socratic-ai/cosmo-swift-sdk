import CoreGraphics
import CosmoRealtime
import Foundation
import ImageIO
import Testing

import CosmoRealtimeiOSTools

/// Headless demo + regression test: runs `detect_face_landmarks` end-to-end
/// against an image and prints the JSON tool-reply the realtime model would
/// receive — no camera, session, or device, just the measurement path.
///
/// Explore with your own photos:
///   FACE_IMAGE=~/Desktop/me.jpg swift test --filter CosmoRealtimeiOSToolsTests
/// With no override it uses the bundled synthetic (StyleGAN) face, which is
/// what CI asserts on; an override is exploratory and skips the assertions.
@Suite struct FaceLandmarksDemoTests {
    @Test("detect_face_landmarks measures a real face and returns a JSON reply")
    func measuresFace() async throws {
        guard #available(macOS 15, iOS 18, *) else { return }

        let override = ProcessInfo.processInfo.environment["FACE_IMAGE"]
        let image: CGImage
        let orientation: CGImagePropertyOrientation
        if let override {
            (image, orientation) = try loadImage(at: URL(fileURLWithPath: (override as NSString).expandingTildeInPath))
        } else {
            (image, orientation) = try loadFixture(named: "face", ext: "jpg")
        }

        let reply = try await VisionToolDispatcher.run(
            name: FaceLandmarksTool.name,
            frame: image,
            orientation: orientation
        )

        // The demo: the exact tool-reply the model receives over the bridge.
        print("\n----- detect_face_landmarks reply -----\n\(try prettyJSON(reply))\n---------------------------------------\n")

        // Assert only the known-good fixture; an override is exploratory.
        if override == nil {
            #expect(reply["usable"] == .bool(true))
            #expect(reply["bounding_box"] != nil)
            if case let .int(count)? = reply["face_count"] {
                #expect(count >= 1)
            }
        }
    }

    private func loadFixture(named name: String, ext: String) throws -> (CGImage, CGImagePropertyOrientation) {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
        )
        return try loadImage(at: url)
    }

    /// Loads the image and its EXIF orientation, so a sideways-stored phone
    /// photo (`FACE_IMAGE=…`) is measured upright instead of as raw pixels.
    private func loadImage(at url: URL) throws -> (CGImage, CGImagePropertyOrientation) {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let raw = (props?[kCGImagePropertyOrientation] as? UInt32) ?? 1
        return (image, CGImagePropertyOrientation(rawValue: raw) ?? .up)
    }

    private func prettyJSON(_ value: [String: JSONValue]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
