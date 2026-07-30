import CoreGraphics
import CoreText
import CosmoRealtime
import Foundation
import ImageIO
import Testing

@testable import CosmoRealtimeiOSTools

@Suite struct ReadTextToolTests {
    @Test("wire name is the pinned, backend-legal value")
    func wireName() {
        // Pin the wire name: a rename is a wire break.
        #expect(ReadTextTool.name == "read_text")
        // Mirrors the backend regex `^[a-z][a-z0-9_]{2,63}$` from client_declared.py.
        let pattern = #/^[a-z][a-z0-9_]{2,63}$/#
        #expect(ReadTextTool.name.wholeMatch(of: pattern) != nil)
    }

    @Test("parametersJSON is a no-arg object schema")
    func parametersSchema() throws {
        let parsed = try JSONSerialization.jsonObject(
            with: Data(ReadTextTool.parametersJSON.utf8)
        )
        let object = try #require(parsed as? [String: Any])
        #expect(object["type"] as? String == "object")
        let properties = try #require(object["properties"] as? [String: Any])
        #expect(properties.isEmpty)
    }

    @Test("declaredTool carries a matching name")
    func declaration() {
        #expect(ReadTextTool.declaredTool().name == ReadTextTool.name)
    }

    @Test("a frame of rendered text is usable and returns the recognized strings")
    func renderedTextIsReadable() async throws {
        guard #available(macOS 15, iOS 18, *) else { return }

        let image = try #require(textImage("HELLO WORLD 12345"))
        let reply = try await ReadTextTool.run(
            frame: image, args: [:], orientation: .up
        )

        #expect(reply["usable"] == .bool(true))
        let text = try #require(stringValue(reply["text"]))
        #expect(text.localizedCaseInsensitiveContains("HELLO"))
        #expect(text.contains("12345"))
        // A usable reply carries the per-line array, not a degradation reason.
        if case let .array(lines)? = reply["lines"] {
            #expect(!lines.isEmpty)
        } else {
            Issue.record("usable reply must include a non-empty lines array")
        }
        #expect(reply["reason"] == nil)
    }

    @Test("a blank frame with no text degrades to usable:false")
    func blankFrameIsNotUsable() async throws {
        guard #available(macOS 15, iOS 18, *) else { return }

        let image = try #require(blankImage(width: 256, height: 256))
        let reply = try await ReadTextTool.run(
            frame: image, args: [:], orientation: .up
        )

        #expect(reply["usable"] == .bool(false))
        #expect(reply["reason"] != nil)
        // A degraded reply must not carry strings the model could read out.
        #expect(reply["text"] == nil)
        #expect(reply["lines"] == nil)
    }

    /// Renders `string` as large black text on a white background into a `CGImage`,
    /// so the positive path has a synthetic input with no binary fixture.
    private func textImage(_ string: String) -> CGImage? {
        let font = CTFontCreateWithName("Helvetica" as CFString, 80, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        guard let attributed = CFAttributedStringCreate(
            nil, string as CFString, attributes as CFDictionary
        ) else { return nil }
        let line = CTLineCreateWithAttributedString(attributed)

        // Size the canvas to the measured line + margins so no glyph clips at the
        // edges (a clipped frame makes the recognizer read a truncated string).
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let margin: CGFloat = 48
        let width = Int((lineWidth + margin * 2).rounded(.up))
        let height = Int((ascent + descent + margin * 2).rounded(.up))

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

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.textPosition = CGPoint(x: margin, y: margin + descent)
        CTLineDraw(line, context)
        return context.makeImage()
    }

    private func blankImage(width: Int, height: Int) -> CGImage? {
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
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func stringValue(_ value: JSONValue?) -> String? {
        if case let .string(s)? = value { return s }
        return nil
    }
}
