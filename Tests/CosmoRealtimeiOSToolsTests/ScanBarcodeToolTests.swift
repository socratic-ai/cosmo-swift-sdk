import CoreGraphics
import CoreImage
import CosmoRealtime
import Foundation
import ImageIO
import Testing

@testable import CosmoRealtimeiOSTools

@Suite struct ScanBarcodeToolTests {
    @Test("wire name is the pinned, backend-legal value")
    func wireName() {
        // Pin the wire name: a rename is a wire break.
        #expect(ScanBarcodeTool.name == "scan_barcode")
        // Mirrors the backend regex `^[a-z][a-z0-9_]{2,63}$` from client_declared.py.
        let pattern = #/^[a-z][a-z0-9_]{2,63}$/#
        #expect(ScanBarcodeTool.name.wholeMatch(of: pattern) != nil)
    }

    @Test("parametersJSON is a no-arg object schema")
    func parametersSchema() throws {
        let parsed = try JSONSerialization.jsonObject(
            with: Data(ScanBarcodeTool.parametersJSON.utf8)
        )
        let object = try #require(parsed as? [String: Any])
        #expect(object["type"] as? String == "object")
        let properties = try #require(object["properties"] as? [String: Any])
        #expect(properties.isEmpty)
    }

    @Test("declaredTool carries a matching name")
    func declaration() {
        #expect(ScanBarcodeTool.declaredTool().name == ScanBarcodeTool.name)
    }

    @Test("a synthesized QR frame is usable and returns the encoded payload")
    func qrCodeIsReadable() async throws {
        guard #available(macOS 15, iOS 18, *) else { return }

        let message = "COSMO-12345"
        let image = try #require(qrImage(encoding: message))
        let reply = try await ScanBarcodeTool.run(
            frame: image, args: [:], orientation: .up
        )

        #expect(reply["usable"] == .bool(true))
        let barcodes = try #require(arrayValue(reply["barcodes"]))
        #expect(!barcodes.isEmpty)
        // The decoded payload of at least one code must be the message we encoded.
        let payloads = barcodes.compactMap { code -> String? in
            guard case let .object(fields) = code else { return nil }
            return stringValue(fields["payload"])
        }
        #expect(payloads.contains(message))
        // Every reported code carries a symbology label; the synthetic code is a QR.
        let symbologies = barcodes.compactMap { code -> String? in
            guard case let .object(fields) = code else { return nil }
            return stringValue(fields["symbology"])
        }
        #expect(symbologies.contains("qr"))
        // A usable reply must not carry a degradation reason.
        #expect(reply["reason"] == nil)
    }

    @Test("a blank frame with no code degrades to usable:false")
    func blankFrameIsNotUsable() async throws {
        guard #available(macOS 15, iOS 18, *) else { return }

        let image = try #require(blankImage(width: 256, height: 256))
        let reply = try await ScanBarcodeTool.run(
            frame: image, args: [:], orientation: .up
        )

        #expect(reply["usable"] == .bool(false))
        #expect(reply["reason"] != nil)
        // A degraded reply must not carry codes the model could act on.
        #expect(reply["barcodes"] == nil)
    }

    /// Encodes `message` as a QR code with `CIQRCodeGenerator`, scales the tiny
    /// generator output up ~10× with nearest-neighbor (no smoothing, so the module
    /// edges stay crisp), and renders it onto a white canvas with a quiet-zone
    /// border into a `CGImage` — a synthetic positive input with no binary fixture.
    private func qrImage(encoding message: String) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(message.utf8), forKey: "inputMessage")
        // High error correction keeps the code readable under the scaling/border.
        filter.setValue("H", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        let scale: CGFloat = 10
        // Nearest-neighbor up-scale: CIAffineTransform interpolates, so use the
        // sampler-free `samplingNearest()` before transforming to keep hard edges.
        let scaled = output
            .samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // Pad with a white quiet zone so the detector can isolate the code.
        let quietZone: CGFloat = scale * 4
        let padded = scaled.extent.insetBy(dx: -quietZone, dy: -quietZone)
        let background = CIImage(color: .white).cropped(to: padded)
        let composited = scaled.composited(over: background)

        let context = CIContext()
        return context.createCGImage(composited, from: composited.extent)
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

    private func arrayValue(_ value: JSONValue?) -> [JSONValue]? {
        if case let .array(a)? = value { return a }
        return nil
    }

    private func stringValue(_ value: JSONValue?) -> String? {
        if case let .string(s)? = value { return s }
        return nil
    }
}
