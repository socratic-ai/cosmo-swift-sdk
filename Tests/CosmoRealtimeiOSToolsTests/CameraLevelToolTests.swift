import CoreGraphics
import CosmoRealtime
import Foundation
import ImageIO
import Testing

@testable import CosmoRealtimeiOSTools

@Suite struct CameraLevelToolTests {
    @Test("wire name is the pinned, backend-legal value")
    func wireName() {
        // Pin the wire name: a rename is a wire break.
        #expect(CameraLevelTool.name == "is_camera_level")
        // Mirrors the backend regex `^[a-z][a-z0-9_]{2,63}$` from client_declared.py.
        let pattern = #/^[a-z][a-z0-9_]{2,63}$/#
        #expect(CameraLevelTool.name.wholeMatch(of: pattern) != nil)
    }

    @Test("parametersJSON is a no-arg object schema")
    func parametersSchema() throws {
        let parsed = try JSONSerialization.jsonObject(
            with: Data(CameraLevelTool.parametersJSON.utf8)
        )
        let object = try #require(parsed as? [String: Any])
        #expect(object["type"] as? String == "object")
        let properties = try #require(object["properties"] as? [String: Any])
        #expect(properties.isEmpty)
    }

    @Test("declaredTool carries a matching name")
    func declaration() {
        #expect(CameraLevelTool.declaredTool().name == CameraLevelTool.name)
    }

    @Test("a solid-color frame with no horizon degrades to usable:false")
    func solidColorFrameIsNotUsable() async throws {
        guard #available(macOS 15, iOS 18, *) else { return }

        // TODO: positive-path fixture (a real scene with a horizon) — a synthetic
        // 2-tone split image does not reliably trigger horizon detection, so this
        // only covers the degradation path.
        let image = try #require(solidColorImage(width: 256, height: 256))
        let reply = try await CameraLevelTool.run(frame: image, args: [:], orientation: .up)

        #expect(reply["usable"] == .bool(false))
        #expect(reply["reason"] != nil)
        // A degraded reply must not carry an angle the model could read out.
        #expect(reply["angle_degrees"] == nil)
        #expect(reply["level"] == nil)
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
