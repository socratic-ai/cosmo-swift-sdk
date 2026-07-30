import CoreGraphics
import CosmoRealtime
import Foundation
import ImageIO
import Testing

@testable import CosmoRealtimeiOSTools

@Suite struct CompareToReferenceToolTests {
    @Test("wire name is the pinned, backend-legal value")
    func wireName() {
        #expect(CompareToReferenceTool.name == "compare_to_reference")
        let pattern = #/^[a-z][a-z0-9_]{2,63}$/#
        #expect(CompareToReferenceTool.name.wholeMatch(of: pattern) != nil)
    }

    @Test("parametersJSON requires a subject and a reference box")
    func parametersSchema() throws {
        let parsed = try JSONSerialization.jsonObject(with: Data(CompareToReferenceTool.parametersJSON.utf8))
        let object = try #require(parsed as? [String: Any])
        #expect(object["type"] as? String == "object")
        let required = try #require(object["required"] as? [String])
        #expect(Set(required) == ["subject", "reference"])
        let properties = try #require(object["properties"] as? [String: Any])
        for key in ["subject", "reference"] {
            let region = try #require(properties[key] as? [String: Any])
            #expect(region["type"] as? String == "object")
            let regionRequired = try #require(region["required"] as? [String])
            #expect(Set(regionRequired) == ["x", "y", "width", "height"])
        }
    }

    @Test("the tool is registered for dispatch")
    func registered() {
        let names = VisionToolRegistry.all.map { $0.name }
        #expect(names.contains(CompareToReferenceTool.name))
    }

    @Test("a region compared to itself scores near-identical")
    @available(macOS 15, iOS 18, *)
    func selfComparisonIsNearIdentical() async throws {
        let (image, orientation) = try loadFixture(named: "face", ext: "jpg")

        let reply = try await VisionToolDispatcher.run(
            name: CompareToReferenceTool.name,
            args: ["subject": box(0.3, 0.15, 0.4, 0.2), "reference": box(0.3, 0.15, 0.4, 0.2)],
            frame: image, orientation: orientation
        )

        #expect(reply["usable"] == .bool(true))
        let similarity = try #require(doubleValue(reply["similarity"]))
        let distance = try #require(doubleValue(reply["distance"]))
        // Identical crops feature-print to distance 0 → similarity 1.
        #expect(similarity > 0.99)
        #expect(distance < 0.01)
    }

    @Test("two different regions score strictly lower than a self-match")
    @available(macOS 15, iOS 18, *)
    func differentRegionsScoreLower() async throws {
        let (image, orientation) = try loadFixture(named: "face", ext: "jpg")

        let upper = box(0.3, 0.12, 0.4, 0.2)
        let lower = box(0.3, 0.6, 0.4, 0.2)

        let selfReply = try await CompareToReferenceTool.run(
            frame: image, args: ["subject": upper, "reference": upper], orientation: orientation
        )
        let crossReply = try await CompareToReferenceTool.run(
            frame: image, args: ["subject": upper, "reference": lower], orientation: orientation
        )

        let selfSim = try #require(doubleValue(selfReply["similarity"]))
        let crossSim = try #require(doubleValue(crossReply["similarity"]))
        #expect(crossSim < selfSim)
        #expect(crossSim >= 0 && crossSim <= 1)
    }

    @Test("a missing region degrades to usable:false")
    @available(macOS 15, iOS 18, *)
    func missingRegionIsNotUsable() async throws {
        let (image, orientation) = try loadFixture(named: "face", ext: "jpg")

        let reply = try await CompareToReferenceTool.run(
            frame: image, args: ["subject": box(0.3, 0.15, 0.4, 0.2)], orientation: orientation
        )
        #expect(reply["usable"] == .bool(false))
        #expect(reply["reason"] != nil)
        #expect(reply["similarity"] == nil)
    }

    @Test("a region too small to feature-print degrades to usable:false")
    @available(macOS 15, iOS 18, *)
    func tinyRegionIsNotUsable() async throws {
        let (image, orientation) = try loadFixture(named: "face", ext: "jpg")

        let reply = try await CompareToReferenceTool.run(
            frame: image,
            args: ["subject": box(0.5, 0.5, 0, 0), "reference": box(0.3, 0.15, 0.4, 0.2)],
            orientation: orientation
        )
        #expect(reply["usable"] == .bool(false))
        #expect(reply["reason"] != nil)
    }

    @Test("a box hanging mostly off-frame degrades to usable:false")
    @available(macOS 15, iOS 18, *)
    func offFrameRegionIsNotUsable() async throws {
        let (image, orientation) = try loadFixture(named: "face", ext: "jpg")

        // Origin pinned to the right edge: only a sub-pixel sliver is on-frame,
        // so it must be rejected — not silently cropped to that sliver. (The
        // size guard runs on the rect clamped to the image bounds.)
        let reply = try await CompareToReferenceTool.run(
            frame: image,
            args: ["subject": box(0.999, 0.3, 0.5, 0.4), "reference": box(0.3, 0.15, 0.4, 0.2)],
            orientation: orientation
        )
        #expect(reply["usable"] == .bool(false))
        #expect(reply["reason"] != nil)
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

    private func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> JSONValue {
        .object(["x": .double(x), "y": .double(y), "width": .double(w), "height": .double(h)])
    }

    private func doubleValue(_ value: JSONValue?) -> Double? {
        switch value {
        case let .double(d): return d
        case let .int(i): return Double(i)
        default: return nil
        }
    }
}
