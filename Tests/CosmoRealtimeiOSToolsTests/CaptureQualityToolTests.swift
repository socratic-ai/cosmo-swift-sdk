import CoreGraphics
import CosmoRealtime
import Foundation
import ImageIO
import Testing

@testable import CosmoRealtimeiOSTools

@Suite struct CaptureQualityToolTests {
    @Test("wire name is the pinned, backend-legal value")
    func wireName() {
        // Pin the wire name: a rename is a wire break.
        #expect(CaptureQualityTool.name == "check_capture_quality")
        // Mirrors the backend regex `^[a-z][a-z0-9_]{2,63}$` from client_declared.py.
        let pattern = #/^[a-z][a-z0-9_]{2,63}$/#
        #expect(CaptureQualityTool.name.wholeMatch(of: pattern) != nil)
    }

    @Test("parametersJSON is a no-arg object schema")
    func parametersSchema() throws {
        let parsed = try JSONSerialization.jsonObject(
            with: Data(CaptureQualityTool.parametersJSON.utf8)
        )
        let object = try #require(parsed as? [String: Any])
        #expect(object["type"] as? String == "object")
        let properties = try #require(object["properties"] as? [String: Any])
        #expect(properties.isEmpty)
    }

    @Test("declaredTool carries a matching name")
    func declaration() {
        #expect(CaptureQualityTool.declaredTool().name == CaptureQualityTool.name)
    }

    @Test("a real face frame is usable with a [0,1] score and at least one face")
    func usableFrameScoresQuality() async throws {
        guard #available(macOS 15, iOS 18, *) else { return }

        let (image, orientation) = try loadFixture(named: "face", ext: "jpg")
        let reply = try await CaptureQualityTool.run(
            frame: image, args: [:], orientation: orientation
        )

        #expect(reply["usable"] == .bool(true))
        let score = try #require(doubleValue(reply["quality_score"]))
        #expect(score >= 0 && score <= 1)
        let count = try #require(intValue(reply["face_count"]))
        #expect(count >= 1)
        // A degraded reply carries `reason`; a usable one must not.
        #expect(reply["reason"] == nil)
    }

    @Test("a blank frame with no face degrades to usable:false")
    func blankFrameIsNotUsable() async throws {
        guard #available(macOS 15, iOS 18, *) else { return }

        let image = try #require(solidColorImage(width: 256, height: 256))
        let reply = try await CaptureQualityTool.run(
            frame: image, args: [:], orientation: .up
        )

        #expect(reply["usable"] == .bool(false))
        #expect(reply["reason"] != nil)
        // A degraded reply must not carry a score the model could trust.
        #expect(reply["quality_score"] == nil)
    }

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

    private func solidColorImage(width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func doubleValue(_ value: JSONValue?) -> Double? {
        if case let .double(d)? = value { return d }
        return nil
    }

    private func intValue(_ value: JSONValue?) -> Int? {
        if case let .int(i)? = value { return i }
        return nil
    }
}
