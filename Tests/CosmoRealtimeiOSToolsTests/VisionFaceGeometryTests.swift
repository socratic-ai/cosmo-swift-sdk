import CoreGraphics
import CosmoRealtime
import Foundation
import ImageIO
import Testing

@testable import CosmoRealtimeiOSTools

@MainActor
@Suite struct VisionFaceGeometryTests {
    @Test("a real face frame extracts normalized regions and leaves pose/contours empty")
    @available(macOS 15, iOS 18, *)
    func extractsFaceGeometry() async throws {
        let (image, orientation) = try Fixtures.image(named: "face", ext: "jpg")
        let geometry = try #require(
            try await VisionFaceGeometry.extract(from: image, orientation: orientation)
        )

        #expect(!geometry.regions.isEmpty)
        #expect(geometry.regions[FaceRegionKey.lips] != nil)
        #expect(geometry.regions[FaceRegionKey.leftEye] != nil)
        for (key, box) in geometry.regions {
            for value in [box.x, box.y, box.width, box.height] {
                #expect(value >= 0 && value <= 1, "region \(key) out of [0,1]: \(value)")
            }
        }
        // The baseline runs one Vision pass; pose/contours are left to richer backends.
        #expect(geometry.pose == nil)
        #expect(geometry.contours.isEmpty)
    }

    @Test("a blank frame resolves to nil (no face)")
    @available(macOS 15, iOS 18, *)
    func blankFrameIsNil() async throws {
        let image = try #require(Fixtures.blank(width: 256, height: 256))
        let geometry = try await VisionFaceGeometry.extract(from: image, orientation: .up)
        #expect(geometry == nil)
    }

    @Test("the source emits geometry for a delivered frame", .timeLimit(.minutes(1)))
    @available(macOS 15, iOS 18, *)
    func emitsGeometryForADeliveredFrame() async throws {
        let (image, orientation) = try Fixtures.image(named: "face", ext: "jpg")
        let manual = ManualFrameSource()
        let source = VisionFaceGeometrySource(frameSource: manual)

        source.start()
        manual.send(CameraFrame(image: image, orientation: orientation))
        var iterator = source.geometry.makeAsyncIterator()
        let element = try #require(await iterator.next())   // a value was emitted
        let geometry = try #require(element)                 // and it's non-nil
        #expect(!geometry.regions.isEmpty)
        source.stop()
    }

    @Test("a burst of frames coalesces to the newest — the stale middle is skipped", .timeLimit(.minutes(1)))
    @available(macOS 15, iOS 18, *)
    func backlogCoalescesToNewest() async throws {
        let (image, _) = try Fixtures.image(named: "face", ext: "jpg")
        let recorder = Recorder()
        let source = VisionFaceGeometrySource(
            frameSource: FiniteFrameSource([
                CameraFrame(image: image, orientation: .up),     // rawValue 1
                CameraFrame(image: image, orientation: .down),   // rawValue 3 — the stale middle
                CameraFrame(image: image, orientation: .left),   // rawValue 8 — the newest
            ]),
            extract: { _, orientation in
                // Hold the loop so the whole burst lands in the one-slot buffer and
                // the middle frame is overwritten before it can be processed.
                try? await Task.sleep(for: .milliseconds(20))
                await recorder.record(orientation.rawValue)
                return FaceGeometry()
            }
        )

        source.start()
        for await _ in source.geometry {}   // drain until the finite source completes

        let tags = await recorder.tags
        #expect(tags.last == CGImagePropertyOrientation.left.rawValue)       // newest is processed
        #expect(!tags.contains(CGImagePropertyOrientation.down.rawValue))    // stale middle skipped
    }

    @Test("a frame whose extract throws yields nil and the stream survives", .timeLimit(.minutes(1)))
    @available(macOS 15, iOS 18, *)
    func resilientToExtractFailure() async throws {
        let (image, orientation) = try Fixtures.image(named: "face", ext: "jpg")
        let manual = ManualFrameSource()
        let source = VisionFaceGeometrySource(frameSource: manual, extract: { _, _ in throw Boom() })

        source.start()
        var iterator = source.geometry.makeAsyncIterator()

        manual.send(CameraFrame(image: image, orientation: orientation))
        let first = try #require(await iterator.next())   // a value was emitted (stream not ended)
        #expect(first == nil)                              // and it's nil (extract threw)

        manual.send(CameraFrame(image: image, orientation: orientation))
        let second = try #require(await iterator.next())   // survived — still emitting
        #expect(second == nil)

        source.stop()
    }

    @Test("stop() finishes the stream and the source is single-use", .timeLimit(.minutes(1)))
    @available(macOS 15, iOS 18, *)
    func stopIsTerminalAndSingleUse() async throws {
        let (image, orientation) = try Fixtures.image(named: "face", ext: "jpg")
        let manual = ManualFrameSource()
        let source = VisionFaceGeometrySource(frameSource: manual)

        source.start()
        manual.send(CameraFrame(image: image, orientation: orientation))
        var iterator = source.geometry.makeAsyncIterator()
        _ = await iterator.next()                 // first geometry arrives
        source.stop()                             // terminal
        #expect(await iterator.next() == nil)     // stream finished

        source.start()                            // single-use → no-op
        manual.send(CameraFrame(image: image, orientation: orientation))
        #expect(await iterator.next() == nil)     // still finished; restart did nothing
    }

    // MARK: - Doubles

    private struct Boom: Error {}

    /// Thread-safe record of which frames the extractor actually processed.
    private actor Recorder {
        private(set) var tags: [UInt32] = []
        func record(_ tag: UInt32) { tags.append(tag) }
    }

    /// Yields a fixed list of frames, then finishes.
    private final class FiniteFrameSource: FrameSource {
        let frames: AsyncStream<CameraFrame>
        init(_ items: [CameraFrame]) {
            frames = AsyncStream { continuation in
                for item in items { continuation.yield(item) }
                continuation.finish()
            }
        }
    }

    /// Yields frames on demand and never finishes on its own — so only `stop()`
    /// ends the geometry stream.
    private final class ManualFrameSource: FrameSource {
        let frames: AsyncStream<CameraFrame>
        private let continuation: AsyncStream<CameraFrame>.Continuation
        init() { (frames, continuation) = AsyncStream<CameraFrame>.makeStream() }
        func send(_ frame: CameraFrame) { continuation.yield(frame) }
    }
}
