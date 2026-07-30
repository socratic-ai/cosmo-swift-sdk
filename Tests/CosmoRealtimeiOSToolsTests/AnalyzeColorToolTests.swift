import CoreGraphics
import CosmoRealtime
import Foundation
import ImageIO
import Testing

@testable import CosmoRealtimeiOSTools

@Suite struct AnalyzeColorToolTests {
    @Test("wire name is the pinned, backend-legal value")
    func wireName() {
        #expect(AnalyzeColorTool.name == "analyze_color")
        let pattern = #/^[a-z][a-z0-9_]{2,63}$/#
        #expect(AnalyzeColorTool.name.wholeMatch(of: pattern) != nil)
    }

    @Test("parametersJSON exposes an optional box region")
    func parametersSchema() throws {
        let parsed = try JSONSerialization.jsonObject(with: Data(AnalyzeColorTool.parametersJSON.utf8))
        let object = try #require(parsed as? [String: Any])
        #expect(object["type"] as? String == "object")
        // box is optional — no top-level `required`.
        #expect(object["required"] == nil)
        let properties = try #require(object["properties"] as? [String: Any])
        let box = try #require(properties["box"] as? [String: Any])
        #expect(box["type"] as? String == "object")
        let boxRequired = try #require(box["required"] as? [String])
        #expect(Set(boxRequired) == ["x", "y", "width", "height"])
    }

    @Test("the tool is registered for dispatch")
    func registered() {
        let names = VisionToolRegistry.all.map { $0.name }
        #expect(names.contains(AnalyzeColorTool.name))
    }

    @Test("derives hex and HSB from raw channels")
    func derivesHexAndHsb() {
        let red = ColorAnalysis.color(r: 255, g: 0, b: 0)
        #expect(red.hex == "#FF0000")
        #expect(red.hue == 0)
        #expect(red.saturation == 100)
        #expect(red.brightness == 100)

        #expect(ColorAnalysis.color(r: 0, g: 255, b: 0).hue == 120)
        #expect(ColorAnalysis.color(r: 0, g: 0, b: 255).hue == 240)
        #expect(ColorAnalysis.color(r: 255, g: 255, b: 255).hex == "#FFFFFF")
        #expect(ColorAnalysis.color(r: 255, g: 255, b: 255).saturation == 0)
        #expect(ColorAnalysis.color(r: 0, g: 0, b: 0).brightness == 0)
    }

    @Test("a solid frame averages to that exact color")
    func solidFrameAverages() async throws {
        let image = try makeImage { _, _ in (255, 0, 0) }
        let reply = try await VisionToolDispatcher.run(name: AnalyzeColorTool.name, frame: image)

        #expect(reply["usable"] == .bool(true))
        #expect(stringValue(reply["hex"]) == "#FF0000")
        let rgb = try #require(objectValue(reply["rgb"]))
        #expect(intValue(rgb["r"]) == 255)
        #expect(intValue(rgb["g"]) == 0)
        #expect(intValue(rgb["b"]) == 0)
    }

    @Test("a box samples the requested vertical region (top-left y origin)")
    func boxSamplesVerticalRegion() async throws {
        // Top half red, bottom half blue (y=0 is the top row).
        let image = try makeImage { _, y in y < 32 ? (255, 0, 0) : (0, 0, 255) }

        let top = try await AnalyzeColorTool.run(
            frame: image, args: ["box": box(0, 0, 1, 0.5)], orientation: .up
        )
        let topRGB = try #require(objectValue(top["rgb"]))
        #expect((intValue(topRGB["r"]) ?? 0) > 200)
        #expect((intValue(topRGB["b"]) ?? 255) < 60)

        let bottom = try await AnalyzeColorTool.run(
            frame: image, args: ["box": box(0, 0.5, 1, 0.5)], orientation: .up
        )
        let bottomRGB = try #require(objectValue(bottom["rgb"]))
        #expect((intValue(bottomRGB["b"]) ?? 0) > 200)
        #expect((intValue(bottomRGB["r"]) ?? 255) < 60)
    }

    @Test("a box samples the requested horizontal region")
    func boxSamplesHorizontalRegion() async throws {
        // Left half red, right half blue.
        let image = try makeImage { x, _ in x < 32 ? (255, 0, 0) : (0, 0, 255) }

        let left = try await AnalyzeColorTool.run(
            frame: image, args: ["box": box(0, 0, 0.5, 1)], orientation: .up
        )
        let leftRGB = try #require(objectValue(left["rgb"]))
        #expect((intValue(leftRGB["r"]) ?? 0) > 200)
        #expect((intValue(leftRGB["b"]) ?? 255) < 60)

        let right = try await AnalyzeColorTool.run(
            frame: image, args: ["box": box(0.5, 0, 0.5, 1)], orientation: .up
        )
        let rightRGB = try #require(objectValue(right["rgb"]))
        #expect((intValue(rightRGB["b"]) ?? 0) > 200)
        #expect((intValue(rightRGB["r"]) ?? 255) < 60)
    }

    @Test("a degenerate (zero-area) box degrades to usable:false")
    func degenerateBoxIsNotUsable() async throws {
        let image = try makeImage { _, _ in (10, 20, 30) }
        let reply = try await AnalyzeColorTool.run(
            frame: image, args: ["box": box(0.5, 0.5, 0, 0.2)], orientation: .up
        )
        #expect(reply["usable"] == .bool(false))
        #expect(reply["reason"] != nil)
        #expect(reply["rgb"] == nil)
    }

    // MARK: - Helpers

    /// Build a CGImage from a raw RGBA buffer so row 0 is unambiguously the TOP
    /// scanline (CGImage raster order) — independent of any CGContext y-flip.
    private func makeImage(
        width: Int = 64,
        height: Int = 64,
        _ colorAt: (Int, Int) -> (UInt8, UInt8, UInt8)
    ) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = colorAt(x, y)
                let i = (y * width + x) * 4
                bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b; bytes[i + 3] = 255
            }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
    }

    private func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> JSONValue {
        .object(["x": .double(x), "y": .double(y), "width": .double(w), "height": .double(h)])
    }

    private func objectValue(_ value: JSONValue?) -> [String: JSONValue]? {
        if case let .object(o)? = value { return o }
        return nil
    }

    private func intValue(_ value: JSONValue?) -> Int? {
        if case let .int(i)? = value { return i }
        return nil
    }

    private func stringValue(_ value: JSONValue?) -> String? {
        if case let .string(s)? = value { return s }
        return nil
    }
}
