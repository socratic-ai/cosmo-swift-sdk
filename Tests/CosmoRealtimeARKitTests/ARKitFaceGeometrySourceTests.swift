import CoreGraphics
import Foundation
import Testing
import simd

import CosmoRealtime
import CosmoRealtimeARKit

@MainActor
@Suite struct ARKitFaceGeometrySourceTests {

    /// A face anchor `distanceZ` metres in front of the camera (identity view +
    /// projection), so the projected `distanceMeters` is `|distanceZ|`.
    private static func snapshot(distanceZ: Float = -0.5) -> FaceAnchorSnapshot {
        var anchor = matrix_identity_float4x4
        anchor.columns.3 = SIMD4<Float>(0, 0, distanceZ, 1)
        return FaceAnchorSnapshot(
            regionVertices: [:],
            anchorTransform: anchor,
            viewMatrix: matrix_identity_float4x4,
            projectionMatrix: matrix_identity_float4x4
        )
    }

    @Test("emits projected geometry for a delivered snapshot", .timeLimit(.minutes(1)))
    func emitsGeometry() async throws {
        let feed = ManualAnchorFeed()
        let source = ARKitFaceGeometrySource(feed: feed)

        source.start()
        feed.send(Self.snapshot(distanceZ: -0.5))
        var iterator = source.geometry.makeAsyncIterator()
        let element = try #require(await iterator.next())   // a value was emitted
        let geometry = try #require(element)                 // and it's non-nil
        #expect(abs((geometry.distanceMeters ?? 0) - 0.5) < 1e-4)
        #expect(feed.started)
        source.stop()
    }

    @Test("a nil snapshot (no face) passes through as nil", .timeLimit(.minutes(1)))
    func noFacePassesThroughNil() async throws {
        let feed = ManualAnchorFeed()
        let source = ARKitFaceGeometrySource(feed: feed)

        source.start()
        feed.send(nil)
        var iterator = source.geometry.makeAsyncIterator()
        let element = try #require(await iterator.next())   // a value was emitted
        #expect(element == nil)                              // and it's nil (no face)
        source.stop()
    }

    @Test("stop() finishes the stream, stops the feed, and the source is single-use", .timeLimit(.minutes(1)))
    func stopIsTerminalAndSingleUse() async throws {
        let feed = ManualAnchorFeed()
        let source = ARKitFaceGeometrySource(feed: feed)

        source.start()
        feed.send(Self.snapshot())
        var iterator = source.geometry.makeAsyncIterator()
        _ = await iterator.next()
        source.stop()
        #expect(feed.stopped)
        #expect(await iterator.next() == nil)   // stream finished

        source.start()                          // single-use → no-op
        feed.send(Self.snapshot())
        #expect(await iterator.next() == nil)   // still finished
    }

    @Test("the feed finishing on its own finishes the geometry stream", .timeLimit(.minutes(1)))
    func feedFinishFinishesStream() async throws {
        let feed = ManualAnchorFeed()
        let source = ARKitFaceGeometrySource(feed: feed)

        source.start()
        feed.send(Self.snapshot())
        var iterator = source.geometry.makeAsyncIterator()
        _ = try #require(await iterator.next())   // the one geometry
        feed.finish()                              // feed ends on its own (e.g. session stopped)
        #expect(await iterator.next() == nil)      // the geometry stream finishes too
    }

    @Test("currentFrame() forwards the feed's current still")
    func currentFrameForwardsStill() {
        let feed = ManualAnchorFeed()
        feed.stillImage = Self.makeImage(width: 3, height: 5)
        let source = ARKitFaceGeometrySource(feed: feed)
        #expect(source.currentFrame()?.width == 3)
        #expect(source.currentFrame()?.height == 5)
    }

    @Test("currentFrame() is nil when the camera has no still")
    func currentFrameNilWhenEmpty() {
        #expect(ARKitFaceGeometrySource(feed: ManualAnchorFeed()).currentFrame() == nil)
    }

    // MARK: - Doubles

    /// Yields snapshots on demand; only `stop()` ends the stream.
    private final class ManualAnchorFeed: FaceAnchorFeed {
        let snapshots: AsyncStream<FaceAnchorSnapshot?>
        private let continuation: AsyncStream<FaceAnchorSnapshot?>.Continuation
        private(set) var started = false
        private(set) var stopped = false
        init() { (snapshots, continuation) = AsyncStream<FaceAnchorSnapshot?>.makeStream() }
        func start() { started = true }
        func stop() { stopped = true; continuation.finish() }
        func send(_ snapshot: FaceAnchorSnapshot?) { continuation.yield(snapshot) }
        func finish() { continuation.finish() }
        var stillImage: CGImage?
        func currentImage() -> CGImage? { stillImage }
    }

    private static func makeImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }
}
