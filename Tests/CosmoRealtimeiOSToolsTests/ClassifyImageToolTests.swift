import CoreGraphics
import CosmoRealtime
import Foundation
import ImageIO
import Testing

@testable import CosmoRealtimeiOSTools

@Suite struct ClassifyImageToolTests {
    @Test("wire name is the pinned, backend-legal value")
    func wireName() {
        // Pin the wire name: a rename is a wire break.
        #expect(ClassifyImageTool.name == "classify_image")
        // Mirrors the backend regex `^[a-z][a-z0-9_]{2,63}$` from client_declared.py.
        let pattern = #/^[a-z][a-z0-9_]{2,63}$/#
        #expect(ClassifyImageTool.name.wholeMatch(of: pattern) != nil)
    }

    @Test("parametersJSON is a no-arg object schema")
    func parametersSchema() throws {
        let parsed = try JSONSerialization.jsonObject(
            with: Data(ClassifyImageTool.parametersJSON.utf8)
        )
        let object = try #require(parsed as? [String: Any])
        #expect(object["type"] as? String == "object")
        let properties = try #require(object["properties"] as? [String: Any])
        #expect(properties.isEmpty)
    }

    @Test("declaredTool carries a matching name")
    func declaration() {
        #expect(ClassifyImageTool.declaredTool().name == ClassifyImageTool.name)
    }

    @Test("a real photo frame is usable with at most 5 labels in [0,1]")
    func usableFrameReturnsLabels() async throws {
        guard #available(macOS 15, iOS 18, *) else { return }

        let (image, orientation) = try loadFixture(named: "face", ext: "jpg")
        let reply: [String: JSONValue]
        do {
            reply = try await ClassifyImageTool.run(
                frame: image, args: [:], orientation: orientation
            )
        } catch let error where "\(error)".contains("compute device") {
            // Headless CI runners have no compute device for the classification model
            // (Vision throws "No available compute device for VNComputeStageMain"),
            // so this heavy ML model can't run there. Skip rather than assert on an
            // environment we can't exercise; covered on a real device.
            return
        }

        #expect(reply["usable"] == .bool(true))
        let labels = try #require(arrayValue(reply["labels"]))
        #expect(!labels.isEmpty)
        #expect(labels.count <= 5)
        for label in labels {
            let fields = try #require(objectValue(label))
            #expect(stringValue(fields["identifier"]) != nil)
            let confidence = try #require(doubleValue(fields["confidence"]))
            #expect(confidence >= 0 && confidence <= 1)
        }
        // A usable reply must not carry a degradation reason.
        #expect(reply["reason"] == nil)
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

    private func arrayValue(_ value: JSONValue?) -> [JSONValue]? {
        if case let .array(a)? = value { return a }
        return nil
    }

    private func objectValue(_ value: JSONValue?) -> [String: JSONValue]? {
        if case let .object(o)? = value { return o }
        return nil
    }

    private func stringValue(_ value: JSONValue?) -> String? {
        if case let .string(s)? = value { return s }
        return nil
    }

    private func doubleValue(_ value: JSONValue?) -> Double? {
        if case let .double(d)? = value { return d }
        return nil
    }
}
