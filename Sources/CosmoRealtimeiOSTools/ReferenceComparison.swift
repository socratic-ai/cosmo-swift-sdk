import CoreGraphics
import CoreImage
import CosmoRealtime
import Foundation
import ImageIO
import Vision

/// Pure on-device likeness measurement: a coarse perceptual comparison of how
/// closely two regions of one still frame resemble each other, via Vision image
/// feature prints. No pixels out — just a distance and a rank-only similarity
/// score. `CompareToReferenceTool` adapts this to the wire contract.
@available(iOS 18, macOS 15, *)
public enum ReferenceComparison {
    public struct Result: Sendable, Equatable {
        public let similarity: Double // 0...1, rank-only: 1 == identical, higher == more alike
        public let distance: Double   // raw feature-print distance, >= 0
    }

    /// Compare the `subject` region against the `reference` region of `image`
    /// (boxes normalized `[0,1]`, top-left origin), honoring `orientation`.
    /// Returns `nil` when either region is too small to feature-print.
    public static func compare(
        _ subject: NormalizedBox,
        to reference: NormalizedBox,
        in image: CGImage,
        orientation: CGImagePropertyOrientation = .up
    ) async throws -> Result? {
        guard let baked = orient(image, orientation),
              let subjectCrop = crop(baked, subject),
              let referenceCrop = crop(baked, reference) else { return nil }

        // Pin the revision: feature-print distances are not comparable across
        // revisions, so the score scale must not silently shift with the OS.
        let request = GenerateImageFeaturePrintRequest(.revision2)
        let subjectPrint = try await request.perform(on: subjectCrop, orientation: .up)
        let referencePrint = try await request.perform(on: referenceCrop, orientation: .up)

        let distance = Double(try subjectPrint.distance(to: referencePrint))
        // Feature-print distance is unbounded and 0 for a perfect match; fold it
        // into a 0...1 relative closeness score (1 == identical). The scale is
        // uncalibrated — meaningful for ranking two checks, not as a percentage.
        return Result(similarity: 1 / (1 + distance), distance: distance)
    }

    /// Bake `orientation` into the pixels so a normalized box (reported in the
    /// upright, displayed space by the Vision tools) crops the region the user
    /// actually sees. A no-op for `.up`.
    private static func orient(_ image: CGImage, _ orientation: CGImagePropertyOrientation) -> CGImage? {
        if orientation == .up { return image }
        let ciImage = CIImage(cgImage: image).oriented(orientation)
        return CIContext().createCGImage(ciImage, from: ciImage.extent)
    }

    /// Crop `box` from `image` in top-left pixel space. The requested rect is
    /// clamped to the image bounds *before* the size check, so a box that hangs
    /// mostly off-frame is judged on the sliver that actually survives — and
    /// rejected (`nil`) when that's smaller than a feature print can describe.
    private static func crop(_ image: CGImage, _ box: NormalizedBox) -> CGImage? {
        let w = Double(image.width), h = Double(image.height)
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        let rect = CGRect(
            x: clamp01(box.x) * w,
            y: clamp01(box.y) * h,
            width: clamp01(box.width) * w,
            height: clamp01(box.height) * h
        ).integral.intersection(bounds)
        guard rect.width >= 8, rect.height >= 8 else { return nil }
        return image.cropping(to: rect)
    }

    private static func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }
}
