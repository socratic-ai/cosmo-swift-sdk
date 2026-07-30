import CosmoRealtime
import CoreGraphics
import Foundation
import ImageIO
import Vision

/// `scan_barcode` — reads barcodes and QR codes in the current frame via iOS 18's
/// value-type `DetectBarcodesRequest`. The measurement lives inline here: still
/// frame in, the JSON `tool-reply` out (decoded payload + symbology per code),
/// never an image. `usable:false` when no code is found, so the model asks the
/// user to center the barcode instead of guessing the product.
public enum ScanBarcodeTool: VisionToolProviding {
    public static let name = "scan_barcode"

    public static var toolDescription: String {
        """
        Read barcodes and QR codes in the current camera frame and return each code's decoded \
        payload string and symbology (qr, code128, ean13, …), never an image. Call it to identify \
        a product or follow a QR link from what the camera actually sees; it returns `usable:false` \
        when no code is found so you can ask the user to center the barcode and hold steady.
        """
    }

    public static var parametersJSON: String { #"{"type":"object","properties":{}}"# }

    public static var isSupported: Bool {
        if #available(iOS 18, macOS 15, *) { return true } else { return false }
    }

    public static func run(
        frame: CGImage,
        args: [String: JSONValue],
        orientation: CGImagePropertyOrientation
    ) async throws -> [String: JSONValue] {
        guard #available(iOS 18, macOS 15, *) else {
            throw VisionToolError("unsupported_tool: \(name) needs a newer OS")
        }
        let request = DetectBarcodesRequest()
        let observations = try await request.perform(on: frame, orientation: orientation)

        var barcodes: [JSONValue] = []
        for observation in observations {
            // A code the detector located but couldn't decode has no payload; it is
            // not usable to the model, so skip it rather than report an empty string.
            guard let payload = observation.payloadString else { continue }
            barcodes.append(.object([
                "payload": .string(payload),
                // BarcodeSymbology is a plain Swift enum with no raw value; its case
                // name (qr, code128, ean13, …) is the stable wire label.
                "symbology": .string(String(describing: observation.symbology)),
            ]))
        }

        guard !barcodes.isEmpty else {
            // Coachable degradation, not a failure: ok=true so the model speaks the
            // reason and asks for a recapture instead of treating it as an error.
            return [
                "usable": .bool(false),
                "reason": .string("no barcode detected — ask the user to center the barcode and hold steady"),
            ]
        }
        return [
            "usable": .bool(true),
            "barcodes": .array(barcodes),
        ]
    }
}
