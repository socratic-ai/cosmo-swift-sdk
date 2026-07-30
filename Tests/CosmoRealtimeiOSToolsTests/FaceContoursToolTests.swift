import CoreGraphics
import CosmoRealtime
import Foundation
import ImageIO
import Testing

@testable import CosmoRealtimeiOSTools

@Suite struct FaceContoursToolTests {
    @Test("wire name is the pinned, backend-legal value")
    func wireName() {
        #expect(FaceContoursTool.name == "detect_face_contours")
        let pattern = #/^[a-z][a-z0-9_]{2,63}$/#
        #expect(FaceContoursTool.name.wholeMatch(of: pattern) != nil)
    }

    @Test("parametersJSON is a no-arg object schema")
    func parametersSchema() throws {
        let parsed = try JSONSerialization.jsonObject(with: Data(FaceContoursTool.parametersJSON.utf8))
        let object = try #require(parsed as? [String: Any])
        #expect(object["type"] as? String == "object")
        let properties = try #require(object["properties"] as? [String: Any])
        #expect(properties.isEmpty)
    }

    @Test("the tool is registered for dispatch")
    func registered() {
        let names = VisionToolRegistry.all.map { $0.name }
        #expect(names.contains(FaceContoursTool.name))
    }

    @Test("a real face frame returns feature outlines as point polylines")
    @available(macOS 15, iOS 18, *)
    func tracesFaceContours() async throws {
        let (image, orientation) = try loadFixture(named: "face", ext: "jpg")
        let reply = try await VisionToolDispatcher.run(
            name: FaceContoursTool.name, frame: image, orientation: orientation
        )

        #expect(reply["usable"] == .bool(true))
        // A degraded reply would carry a reason instead of contours.
        #expect(reply["reason"] == nil)

        let contours = try #require(objectValue(reply["contours"]))
        #expect(!contours.isEmpty)
        // Lips and both eyes are direct Vision landmark outlines — they must
        // resolve on a clear, front-facing face, each as a real polyline.
        for key in [FaceRegionKey.lips, FaceRegionKey.leftEye, FaceRegionKey.rightEye] {
            let points = try #require(arrayValue(contours[key]), "missing contour \(key)")
            #expect(points.count >= 3, "contour \(key) should be a polyline")
            for value in points {
                let p = try #require(objectValue(value), "contour \(key) point not an object")
                let x = try #require(doubleValue(p["x"]))
                let y = try #require(doubleValue(p["y"]))
                #expect(x >= 0 && x <= 1, "contour \(key).x out of [0,1]: \(x)")
                #expect(y >= 0 && y <= 1, "contour \(key).y out of [0,1]: \(y)")
            }
        }
    }

    @Test("a blank frame with no face degrades to usable:false")
    @available(macOS 15, iOS 18, *)
    func blankFrameIsNotUsable() async throws {
        let image = try #require(blankImage(width: 256, height: 256))
        let reply = try await FaceContoursTool.run(frame: image, args: [:], orientation: .up)

        #expect(reply["usable"] == .bool(false))
        #expect(reply["reason"] != nil)
        // A degraded reply must not carry geometry the model could read out.
        #expect(reply["contours"] == nil)
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

    private func arrayValue(_ value: JSONValue?) -> [JSONValue]? {
        if case let .array(a)? = value { return a }
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
