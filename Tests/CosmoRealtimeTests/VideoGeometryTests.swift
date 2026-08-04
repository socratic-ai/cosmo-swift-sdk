import CoreGraphics
import Foundation
import Testing
@testable import CosmoRealtime

/// The mapping every preview overlay depends on. These pin the two
/// corrections a normalized box needs before it can be drawn — the content
/// mode's crop/letterbox and the preview's mirroring — because getting either
/// wrong puts the mark somewhere the model never pointed.
@Suite("Normalized coordinate mapping")
struct VideoGeometryTests {

    // A portrait frame in a landscape container: fill crops the sides, fit
    // letterboxes them. 400x800 into 200x200 → fill scale 0.5 (shown 200x400,
    // 100 cropped top and bottom), fit scale 0.25 (shown 100x200, 50 bars).
    private let frame = CGSize(width: 400, height: 800)
    private let container = CGSize(width: 200, height: 200)

    @Test("fill scales by the larger ratio and crops symmetrically")
    func fillCropsSymmetrically() {
        let box = NormalizedBox(x: 0, y: 0, width: 1, height: 1)
        let rect = box.rect(in: container, frameSize: frame, contentMode: .fill)
        #expect(rect.origin.x == 0)
        #expect(rect.origin.y == -100, "the frame overflows the container equally above and below")
        #expect(rect.width == 200)
        #expect(rect.height == 400)
    }

    @Test("fit scales by the smaller ratio and letterboxes symmetrically")
    func fitLetterboxesSymmetrically() {
        let box = NormalizedBox(x: 0, y: 0, width: 1, height: 1)
        let rect = box.rect(in: container, frameSize: frame, contentMode: .fit)
        #expect(rect.origin.x == 50, "bars of equal width on each side")
        #expect(rect.origin.y == 0)
        #expect(rect.width == 100)
        #expect(rect.height == 200)
    }

    @Test("mirroring reflects the box about the container's vertical midline")
    func mirroringReflectsAboutMidline() {
        // A box on the left quarter of the frame lands on the right quarter.
        let box = NormalizedBox(x: 0, y: 0.25, width: 0.25, height: 0.25)
        let plain = box.rect(in: container, frameSize: frame, contentMode: .fill)
        let mirrored = box.rect(in: container, frameSize: frame, contentMode: .fill, mirrored: true)
        #expect(mirrored.width == plain.width, "mirroring never resizes")
        #expect(mirrored.height == plain.height)
        #expect(mirrored.origin.y == plain.origin.y, "mirroring is horizontal only")
        #expect(mirrored.maxX == container.width - plain.minX)
        #expect(mirrored.minX == container.width - plain.maxX)
    }

    @Test("matches the hand-rolled aspect-fill math it replaces")
    func matchesLegacyAspectFillMath() {
        // The arithmetic the iOS app used before this moved into the SDK.
        func legacyRect(_ box: NormalizedBox, container: CGSize, frameSize: CGSize, mirrored: Bool) -> CGRect {
            let scale = max(container.width / frameSize.width, container.height / frameSize.height)
            let shownWidth = frameSize.width * scale
            let shownHeight = frameSize.height * scale
            let offsetX = (container.width - shownWidth) / 2
            let offsetY = (container.height - shownHeight) / 2
            var rect = CGRect(
                x: offsetX + box.x * shownWidth,
                y: offsetY + box.y * shownHeight,
                width: box.width * shownWidth,
                height: box.height * shownHeight
            )
            if mirrored { rect.origin.x = container.width - rect.maxX }
            return rect
        }

        let boxes = [
            NormalizedBox(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            NormalizedBox(x: 0, y: 0, width: 1, height: 1),
            NormalizedBox(x: 0.75, y: 0.75, width: 0.25, height: 0.25),
        ]
        let sizes: [(CGSize, CGSize)] = [
            (CGSize(width: 390, height: 844), CGSize(width: 1080, height: 1920)),
            (CGSize(width: 200, height: 200), CGSize(width: 400, height: 800)),
            (CGSize(width: 800, height: 400), CGSize(width: 640, height: 480)),
        ]
        for box in boxes {
            for (container, frameSize) in sizes {
                for mirrored in [false, true] {
                    #expect(
                        box.rect(in: container, frameSize: frameSize, contentMode: .fill, mirrored: mirrored)
                            == legacyRect(box, container: container, frameSize: frameSize, mirrored: mirrored)
                    )
                }
            }
        }
    }

    @Test("a point maps to the centre the same box math would give it")
    func pointAgreesWithBoxMath() {
        let point = NormalizedPoint(x: 0.25, y: 0.5)
        let mapped = point.point(in: container, frameSize: frame, contentMode: .fill)
        let degenerate = NormalizedBox(x: 0.25, y: 0.5, width: 0, height: 0)
        let rect = degenerate.rect(in: container, frameSize: frame, contentMode: .fill)
        #expect(mapped == rect.origin)

        let mirrored = point.point(in: container, frameSize: frame, contentMode: .fill, mirrored: true)
        #expect(mirrored.x == container.width - mapped.x)
        #expect(mirrored.y == mapped.y)
    }

    // MARK: - Shared vectors

    private struct VectorFile: Decodable {
        struct Size: Decodable { let width: Double; let height: Double }
        struct Rect: Decodable { let x, y, width, height: Double }
        struct Point: Decodable { let x, y: Double }
        struct BoxCase: Decodable {
            let name: String
            let container: Size
            let frameSize: Size
            let contentMode: String?
            let mirrored: Bool?
            let box: Rect
            let rect: Rect
        }
        struct PointCase: Decodable {
            let name: String
            let container: Size
            let frameSize: Size
            let contentMode: String?
            let mirrored: Bool?
            let point: Point
            let position: Point
        }
        let cases: [BoxCase]
        let points: [PointCase]
    }

    private static func loadVectors() throws -> VectorFile {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // CosmoRealtimeTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // swift/
            .deletingLastPathComponent()  // cosmo-realtime/
            .appendingPathComponent("contract/video-geometry-vectors.json", isDirectory: false)
        return try JSONDecoder().decode(VectorFile.self, from: Data(contentsOf: url))
    }

    private static func mode(_ raw: String?) -> VideoContentMode {
        raw == "fit" ? .fit : .fill
    }

    @Test("the shared vectors map to the same rects here as in every other SDK")
    func boxVectorsMatch() throws {
        let vectors = try Self.loadVectors()
        #expect(!vectors.cases.isEmpty)
        for vector in vectors.cases {
            let rect = NormalizedBox(
                x: vector.box.x, y: vector.box.y,
                width: vector.box.width, height: vector.box.height
            ).rect(
                in: CGSize(width: vector.container.width, height: vector.container.height),
                frameSize: CGSize(width: vector.frameSize.width, height: vector.frameSize.height),
                contentMode: Self.mode(vector.contentMode),
                mirrored: vector.mirrored ?? false
            )
            #expect(
                rect == CGRect(
                    x: vector.rect.x, y: vector.rect.y,
                    width: vector.rect.width, height: vector.rect.height
                ),
                "\(vector.name)"
            )
        }
    }

    @Test("the shared point vectors agree too")
    func pointVectorsMatch() throws {
        let vectors = try Self.loadVectors()
        #expect(!vectors.points.isEmpty)
        for vector in vectors.points {
            let mapped = NormalizedPoint(x: vector.point.x, y: vector.point.y).point(
                in: CGSize(width: vector.container.width, height: vector.container.height),
                frameSize: CGSize(width: vector.frameSize.width, height: vector.frameSize.height),
                contentMode: Self.mode(vector.contentMode),
                mirrored: vector.mirrored ?? false
            )
            #expect(mapped == CGPoint(x: vector.position.x, y: vector.position.y), "\(vector.name)")
        }
    }

    @Test("degenerate frame or container maps to zero rather than NaN")
    func degenerateInputsAreZero() {
        let box = NormalizedBox(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        let point = NormalizedPoint(x: 0.5, y: 0.5)
        #expect(box.rect(in: container, frameSize: .zero) == .zero)
        #expect(box.rect(in: .zero, frameSize: frame) == .zero)
        #expect(point.point(in: container, frameSize: .zero) == .zero)
        #expect(point.point(in: .zero, frameSize: frame) == .zero)
    }
}
