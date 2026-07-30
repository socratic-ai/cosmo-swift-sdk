import CosmoRealtime
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Vision

/// `detect_foreground_subject` — a `VisionToolProviding` framing/composition tool:
/// it reports whether a clear foreground subject is present in the current frame
/// and how it's framed, via iOS 18's value-type `GenerateForegroundInstanceMaskRequest`.
///
/// The request yields a foreground-instance mask; this tool **derives numbers**
/// from that mask (coverage fraction, bounding box, centering) and never returns
/// the mask or any pixels — the reply is the same numbers/labels wire contract as
/// every other tool.
public enum ForegroundSubjectTool: VisionToolProviding {
    public static let name = "detect_foreground_subject"

    public static var toolDescription: String {
        """
        Report whether a clear foreground subject is present in the current camera frame and \
        how it's framed — coverage fraction, normalized bounding box, and whether it's centered \
        — as numbers, never an image. Call it to ground composition feedback in measurements; it \
        returns `usable:false` when no clear subject stands out from the background so you can ask \
        the user to reframe.
        """
    }

    public static var parametersJSON: String { #"{"type":"object","properties":{}}"# }

    public static var isSupported: Bool {
        if #available(iOS 18, macOS 15, *) { return true } else { return false }
    }

    /// A subject covering less than this fraction of the frame is noise, not a
    /// composed subject — treat the frame as "no clear subject" so the model
    /// coaches a reframe instead of measuring background speckle.
    private static let coverageThreshold = 0.01

    public static func run(
        frame: CGImage,
        args: [String: JSONValue],
        orientation: CGImagePropertyOrientation
    ) async throws -> [String: JSONValue] {
        guard #available(iOS 18, macOS 15, *) else {
            throw VisionToolError("unsupported_tool: \(name) needs a newer OS")
        }
        let request = GenerateForegroundInstanceMaskRequest()
        guard
            let observation = try await request.perform(on: frame, orientation: orientation),
            !observation.allInstances.isEmpty
        else {
            return degraded()
        }
        // Derive numbers from the subject mask — never the pixels. `generateMask`
        // returns a single-channel mask buffer covering all foreground instances.
        let mask = try observation.generateMask(for: observation.allInstances)
        guard let measure = measureMask(mask), measure.coverageFraction > coverageThreshold else {
            return degraded()
        }
        return [
            "usable": .bool(true),
            "subject_present": .bool(true),
            "coverage_fraction": .double(measure.coverageFraction),
            "bbox": .object([
                "x": .double(measure.box.x),
                "y": .double(measure.box.y),
                "width": .double(measure.box.width),
                "height": .double(measure.box.height),
            ]),
            "centered": .bool(measure.box.isRoughlyCentered),
        ]
    }

    /// Coachable degradation, not a failure: ok=true so the model speaks the reason
    /// and asks for a recapture instead of treating it as an error.
    private static func degraded() -> [String: JSONValue] {
        [
            "usable": .bool(false),
            "reason": .string("no clear subject — ask the user to frame a single subject against a simpler background"),
        ]
    }

    /// Normalized foreground bounding box, **top-left origin** ([0,1], y increases
    /// downward) — the mask buffer is already in top-left image space, so row 0 is
    /// the top. Matches the screen/app coordinate convention a consumer expects.
    private struct Box {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        /// Center within 15% of the frame midpoint on both axes — enough to coach
        /// "move left/right/up/down" without shipping the pixels.
        var isRoughlyCentered: Bool {
            abs((x + width / 2) - 0.5) <= 0.15 && abs((y + height / 2) - 0.5) <= 0.15
        }
    }

    private struct MaskMeasurement {
        let coverageFraction: Double
        let box: Box
    }

    /// Walk the single-channel mask buffer once: count foreground pixels (value
    /// above the midpoint) for the coverage fraction and track their min/max
    /// row/col for the normalized top-left bounding box. Returns nil when the mask
    /// is unreadable or has no foreground pixels.
    private static func measureMask(_ buffer: CVPixelBuffer) -> MaskMeasurement? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0, let base = CVPixelBufferGetBaseAddress(buffer) else {
            return nil
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let rowBase = base.assumingMemoryBound(to: UInt8.self)
        // Vision's foreground mask is 8-bit single-channel (`OneComponent8`);
        // 0 = background, ~255 = subject. Threshold at the midpoint so soft
        // antialiased edges count as foreground without admitting background noise.
        let foregroundThreshold: UInt8 = 128

        var foregroundCount = 0
        var minX = width, minY = height, maxX = -1, maxY = -1
        for row in 0..<height {
            let rowPointer = rowBase + row * bytesPerRow
            for col in 0..<width where rowPointer[col] >= foregroundThreshold {
                foregroundCount += 1
                if col < minX { minX = col }
                if col > maxX { maxX = col }
                if row < minY { minY = row }
                if row > maxY { maxY = row }
            }
        }
        guard foregroundCount > 0, maxX >= minX, maxY >= minY else { return nil }

        let total = Double(width * height)
        let coverage = Double(foregroundCount) / total
        // +1 so a single-pixel-wide subject has nonzero width/height; normalize to [0,1].
        let box = Box(
            x: Double(minX) / Double(width),
            y: Double(minY) / Double(height),
            width: Double(maxX - minX + 1) / Double(width),
            height: Double(maxY - minY + 1) / Double(height)
        )
        return MaskMeasurement(coverageFraction: coverage, box: box)
    }
}
