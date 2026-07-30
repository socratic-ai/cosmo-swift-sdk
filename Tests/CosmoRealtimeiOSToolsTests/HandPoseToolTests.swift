import CoreGraphics
import CosmoRealtime
import Foundation
import ImageIO
import Testing

@testable import CosmoRealtimeiOSTools

@Suite struct HandPoseToolTests {
    @Test("wire name is the pinned, backend-legal value")
    func wireName() {
        // Pin the wire name: a rename is a wire break.
        #expect(HandPoseTool.name == "detect_hand_pose")
        // Mirrors the backend regex `^[a-z][a-z0-9_]{2,63}$` from client_declared.py.
        let pattern = #/^[a-z][a-z0-9_]{2,63}$/#
        #expect(HandPoseTool.name.wholeMatch(of: pattern) != nil)
    }

    @Test("parametersJSON is a no-arg object schema")
    func parametersSchema() throws {
        let parsed = try JSONSerialization.jsonObject(
            with: Data(HandPoseTool.parametersJSON.utf8)
        )
        let object = try #require(parsed as? [String: Any])
        #expect(object["type"] as? String == "object")
        let properties = try #require(object["properties"] as? [String: Any])
        #expect(properties.isEmpty)
    }

    @Test("declaredTool carries a matching name")
    func declaration() {
        #expect(HandPoseTool.declaredTool().name == HandPoseTool.name)
    }

    @Test("a blank frame with no hands degrades to usable:false")
    func blankFrameIsNotUsable() async throws {
        guard #available(macOS 15, iOS 18, *) else { return }

        // TODO: positive-path fixture (hand photo) — assert usable:true with
        // hands; no bundled hand fixture exists yet, so this is a follow-up.
        let image = try #require(solidColorImage(width: 256, height: 256))
        let reply: [String: JSONValue]
        do {
            reply = try await HandPoseTool.run(frame: image, args: [:], orientation: .up)
        } catch let error where "\(error)".contains("compute device") {
            // Headless CI runners have no compute device for the hand-pose model
            // (Vision throws "No available compute device for VNComputeStageMain"),
            // so the request can't run there. Skip rather than assert on an
            // environment we can't exercise; covered on a real device.
            return
        }

        #expect(reply["usable"] == .bool(false))
        #expect(reply["reason"] != nil)
        // A degraded reply must not carry hands the model could trust.
        #expect(reply["hands"] == nil)
        #expect(reply["hand_count"] == nil)
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
}
