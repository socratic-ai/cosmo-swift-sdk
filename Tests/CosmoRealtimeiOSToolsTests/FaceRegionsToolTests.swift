import CoreGraphics
import CosmoRealtime
import Foundation
import ImageIO
import Testing

@testable import CosmoRealtimeiOSTools

@Suite struct FaceRegionsToolTests {
    @Test("wire name is the pinned, backend-legal value")
    func wireName() {
        // Pin the wire name: a rename is a wire break.
        #expect(FaceRegionsTool.name == "detect_face_regions")
        // Mirrors the backend regex `^[a-z][a-z0-9_]{2,63}$` from client_declared.py.
        let pattern = #/^[a-z][a-z0-9_]{2,63}$/#
        #expect(FaceRegionsTool.name.wholeMatch(of: pattern) != nil)
    }

    @Test("parametersJSON is a no-arg object schema")
    func parametersSchema() throws {
        let parsed = try JSONSerialization.jsonObject(
            with: Data(FaceRegionsTool.parametersJSON.utf8)
        )
        let object = try #require(parsed as? [String: Any])
        #expect(object["type"] as? String == "object")
        let properties = try #require(object["properties"] as? [String: Any])
        #expect(properties.isEmpty)
    }

    @Test("the tool is registered for dispatch")
    func registered() {
        let names = VisionToolRegistry.all.map { $0.name }
        #expect(names.contains(FaceRegionsTool.name))
    }

    @Test("a real face frame returns normalized region boxes")
    func measuresFaceRegions() async throws {
        guard #available(macOS 15, iOS 18, *) else { return }

        let (image, orientation) = try loadFixture(named: "face", ext: "jpg")
        let reply = try await VisionToolDispatcher.run(
            name: FaceRegionsTool.name, frame: image, orientation: orientation
        )

        #expect(reply["usable"] == .bool(true))
        // A degraded reply would carry a reason instead of regions.
        #expect(reply["reason"] == nil)

        let regions = try #require(objectValue(reply["regions"]))
        #expect(!regions.isEmpty)
        // Eyes and lips are direct Vision landmark regions — they must resolve on
        // a clear, front-facing face.
        #expect(regions[FaceRegionKey.lips] != nil)
        #expect(regions[FaceRegionKey.leftEye] != nil)
        #expect(regions[FaceRegionKey.rightEye] != nil)
        // Reported keys are all from the advertised vocabulary.
        for key in regions.keys { #expect(FaceRegionKey.all.contains(key)) }

        // Every box is a well-formed normalized [0,1] rect.
        for (key, value) in regions {
            let box = try #require(objectValue(value), "region \(key) must be an object")
            for axis in ["x", "y", "width", "height"] {
                let v = try #require(doubleValue(box[axis]), "region \(key) missing \(axis)")
                #expect(v >= 0 && v <= 1, "region \(key).\(axis) out of [0,1]: \(v)")
            }
        }
    }

    @Test("a blank frame with no face degrades to usable:false")
    func blankFrameIsNotUsable() async throws {
        guard #available(macOS 15, iOS 18, *) else { return }

        let image = try #require(blankImage(width: 256, height: 256))
        let reply = try await FaceRegionsTool.run(frame: image, args: [:], orientation: .up)

        #expect(reply["usable"] == .bool(false))
        #expect(reply["reason"] != nil)
        // A degraded reply must not carry geometry the model could read out.
        #expect(reply["regions"] == nil)
    }

    // MARK: - Helpers

    private func loadFixture(named name: String, ext: String) throws -> (CGImage, CGImagePropertyOrientation) {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
        )
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let raw = (props?[kCGImagePropertyOrientation] as? UInt32) ?? 1
        return (image, CGImagePropertyOrientation(rawValue: raw) ?? .up)
    }

    private func blankImage(width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func objectValue(_ value: JSONValue?) -> [String: JSONValue]? {
        if case let .object(o)? = value { return o }
        return nil
    }

    private func doubleValue(_ value: JSONValue?) -> Double? {
        switch value {
        case let .double(d): return d
        case let .int(i): return Double(i)
        default: return nil
        }
    }
}
