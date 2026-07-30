import CoreGraphics
import CosmoRealtime
import Foundation
import ImageIO
import Testing

@testable import CosmoRealtimeiOSTools

@Suite struct ForegroundSubjectToolTests {
    @Test("wire name is the pinned, backend-legal value")
    func wireName() {
        // Pin the wire name: a rename is a wire break.
        #expect(ForegroundSubjectTool.name == "detect_foreground_subject")
        // Mirrors the backend regex `^[a-z][a-z0-9_]{2,63}$` from client_declared.py.
        let pattern = #/^[a-z][a-z0-9_]{2,63}$/#
        #expect(ForegroundSubjectTool.name.wholeMatch(of: pattern) != nil)
    }

    @Test("parametersJSON is a no-arg object schema")
    func parametersSchema() throws {
        let parsed = try JSONSerialization.jsonObject(
            with: Data(ForegroundSubjectTool.parametersJSON.utf8)
        )
        let object = try #require(parsed as? [String: Any])
        #expect(object["type"] as? String == "object")
        let properties = try #require(object["properties"] as? [String: Any])
        #expect(properties.isEmpty)
    }

    @Test("declaredTool carries a matching name")
    func declaration() {
        #expect(ForegroundSubjectTool.declaredTool().name == ForegroundSubjectTool.name)
    }

    @Test("a real subject frame is usable with a [0,1] coverage and only numeric fields")
    func usableFrameHasSubject() async throws {
        guard #available(macOS 15, iOS 18, *) else { return }

        let (image, orientation) = try loadFixture(named: "face", ext: "jpg")
        let reply: [String: JSONValue]
        do {
            reply = try await ForegroundSubjectTool.run(
                frame: image, args: [:], orientation: orientation
            )
        } catch let error where "\(error)".contains("compute device") {
            // Headless CI runners have no compute device for the foreground-mask
            // model (Vision throws "No available compute device for
            // VNComputeStageMain"), so the request can't run there. Skip rather
            // than assert on an environment we can't exercise; covered on a real device.
            return
        }

        // A face is a clear foreground subject.
        #expect(reply["usable"] == .bool(true))
        #expect(reply["subject_present"] == .bool(true))
        let coverage = try #require(doubleValue(reply["coverage_fraction"]))
        #expect(coverage > 0 && coverage <= 1)
        // A usable reply must not carry the degradation reason.
        #expect(reply["reason"] == nil)

        // The mask trap: the reply must be numbers/labels only — never the mask or
        // any raw image data. Every value is a primitive or a flat numeric object.
        for (key, value) in reply {
            switch value {
            case .bool, .double, .int, .string:
                continue
            case let .object(fields):
                #expect(key == "bbox")
                for (_, field) in fields { #expect(doubleValue(field) != nil) }
            case .array, .null:
                Issue.record("reply field \(key) carries non-scalar data")
            }
        }
    }

    @Test("a blank frame with no subject degrades to usable:false")
    func blankFrameIsNotUsable() async throws {
        guard #available(macOS 15, iOS 18, *) else { return }

        let image = try #require(solidColorImage(width: 256, height: 256))
        let reply: [String: JSONValue]
        do {
            reply = try await ForegroundSubjectTool.run(frame: image, args: [:], orientation: .up)
        } catch let error where "\(error)".contains("compute device") {
            // Same headless-CI skip as the positive path: the heavy mask model has
            // no compute device on CI runners. Covered on a real device.
            return
        }

        #expect(reply["usable"] == .bool(false))
        #expect(reply["reason"] != nil)
        // A degraded reply must not carry framing numbers the model could trust.
        #expect(reply["subject_present"] == nil)
        #expect(reply["coverage_fraction"] == nil)
        #expect(reply["bbox"] == nil)
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
}
