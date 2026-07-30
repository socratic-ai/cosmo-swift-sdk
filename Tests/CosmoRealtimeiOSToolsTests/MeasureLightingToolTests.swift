import CoreGraphics
import CosmoRealtime
import Foundation
import ImageIO
import Testing

@testable import CosmoRealtimeiOSTools

@Suite struct MeasureLightingToolTests {
    @Test("wire name is the pinned, backend-legal value")
    func wireName() {
        #expect(MeasureLightingTool.name == "measure_lighting")
        let pattern = #/^[a-z][a-z0-9_]{2,63}$/#
        #expect(MeasureLightingTool.name.wholeMatch(of: pattern) != nil)
    }

    @Test("parametersJSON is a no-arg object schema")
    func parametersSchema() throws {
        let parsed = try JSONSerialization.jsonObject(with: Data(MeasureLightingTool.parametersJSON.utf8))
        let object = try #require(parsed as? [String: Any])
        #expect(object["type"] as? String == "object")
        let properties = try #require(object["properties"] as? [String: Any])
        #expect(properties.isEmpty)
    }

    @Test("the tool is registered for dispatch")
    func registered() {
        let names = VisionToolRegistry.all.map { $0.name }
        #expect(names.contains(MeasureLightingTool.name))
    }

    @Test("an evenly-lit mid-gray frame reads good, even, and neutral")
    func uniformMidGray() async throws {
        let image = try makeImage { _, _ in (128, 128, 128) }
        let reply = try await VisionToolDispatcher.run(name: MeasureLightingTool.name, frame: image)

        #expect(reply["usable"] == .bool(true))
        #expect(intValue(reply["brightness"]) == 50)
        #expect(stringValue(reply["assessment"]) == "good")
        #expect(intValue(reply["evenness"]) == 100)
        #expect(stringValue(reply["balance"]) == "even")
        #expect(stringValue(reply["warmth"]) == "neutral")
    }

    @Test("brightness assessment flags blown-out and underexposed frames")
    func brightnessAssessment() async throws {
        let white = try await MeasureLightingTool.run(
            frame: makeImage { _, _ in (255, 255, 255) }, args: [:], orientation: .up
        )
        #expect(intValue(white["brightness"]) == 100)
        #expect(stringValue(white["assessment"]) == "too_bright")

        let black = try await MeasureLightingTool.run(
            frame: makeImage { _, _ in (0, 0, 0) }, args: [:], orientation: .up
        )
        #expect(intValue(black["brightness"]) == 0)
        #expect(stringValue(black["assessment"]) == "too_dark")
    }

    @Test("one-sided lighting is detected as a left/right imbalance")
    func sideLightingDetected() async throws {
        // Left half bright, right half in shadow.
        let image = try makeImage { x, _ in x < 32 ? (240, 240, 240) : (20, 20, 20) }
        let reply = try await MeasureLightingTool.run(frame: image, args: [:], orientation: .up)

        #expect(stringValue(reply["balance"]) == "brighter_left")
        #expect((intValue(reply["evenness"]) ?? 100) < 30)
    }

    @Test("a warm cast and a cool cast are distinguished")
    func warmAndCoolCast() async throws {
        let warm = try await MeasureLightingTool.run(
            frame: makeImage { _, _ in (210, 150, 90) }, args: [:], orientation: .up
        )
        #expect(stringValue(warm["warmth"]) == "warm")

        let cool = try await MeasureLightingTool.run(
            frame: makeImage { _, _ in (90, 150, 210) }, args: [:], orientation: .up
        )
        #expect(stringValue(cool["warmth"]) == "cool")
    }

    @Test("brightness assessment switches exactly at the 25 and 90 boundaries")
    func brightnessAssessmentBoundaries() async throws {
        // Uniform gray g → brightness round(g/255*100) (Rec.709 coeffs sum to 1):
        // 62→24 (too_dark) | 64→25 (good) | 228→89 (good) | 230→90 (too_bright).
        let cases: [(gray: UInt8, brightness: Int, assessment: String)] = [
            (62, 24, "too_dark"),
            (64, 25, "good"),
            (228, 89, "good"),
            (230, 90, "too_bright"),
        ]
        for c in cases {
            let reply = try await MeasureLightingTool.run(
                frame: makeImage { _, _ in (c.gray, c.gray, c.gray) }, args: [:], orientation: .up
            )
            #expect(intValue(reply["brightness"]) == c.brightness, "gray \(c.gray)")
            #expect(stringValue(reply["assessment"]) == c.assessment, "gray \(c.gray)")
        }
    }

    @Test("warm/cool uses an intensity-invariant ratio, not a raw r-b diff")
    func warmthIsIntensityInvariant() async throws {
        // warmth keys off (r - b)/(r + b): > 0.10 warm, < -0.10 cool, else neutral.
        let cases: [(rgb: (UInt8, UInt8, UInt8), warmth: String, note: String)] = [
            ((111, 100, 89), "warm", "ratio +0.11, just over"),
            ((109, 100, 91), "neutral", "ratio +0.09, just under"),
            ((89, 100, 111), "cool", "ratio -0.11, just over"),
            ((91, 100, 109), "neutral", "ratio -0.09, just under"),
            // Intensity invariance: the same temperature (ratio 0.15) at two very
            // different exposures must read the same. The old raw r-b rule split
            // them — bright r-b=60 (>20) warm, dim r-b=12 (<20) neutral.
            ((230, 200, 170), "warm", "bright, r-b=60, ratio 0.15"),
            ((46, 40, 34), "warm", "dim, r-b=12, ratio 0.15 — old rule said neutral"),
        ]
        for c in cases {
            let reply = try await MeasureLightingTool.run(
                frame: makeImage { _, _ in c.rgb }, args: [:], orientation: .up
            )
            #expect(stringValue(reply["warmth"]) == c.warmth, "rgb \(c.rgb): \(c.note)")
        }
    }

    @Test("a frame too small to split degrades to usable:false")
    func degenerateFrameIsNotUsable() async throws {
        let image = try makeImage(width: 1, height: 8) { _, _ in (128, 128, 128) }
        let reply = try await MeasureLightingTool.run(frame: image, args: [:], orientation: .up)

        #expect(reply["usable"] == .bool(false))
        #expect(reply["reason"] != nil)
        #expect(reply["brightness"] == nil)
    }

    // MARK: - Helpers

    /// Build a CGImage from a raw RGBA buffer (row 0 = top scanline, column 0 = left).
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

    private func intValue(_ value: JSONValue?) -> Int? {
        if case let .int(i)? = value { return i }
        return nil
    }

    private func stringValue(_ value: JSONValue?) -> String? {
        if case let .string(s)? = value { return s }
        return nil
    }
}
