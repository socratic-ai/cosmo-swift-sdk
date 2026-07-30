import CoreGraphics
import CosmoRealtime
import Foundation
import ImageIO
import os

/// One camera still + its orientation — the unit a `FrameSource` delivers.
/// `@unchecked Sendable`: the live camera produces frames on a capture queue and
/// hands them to the `@MainActor` source, so the value crosses an actor boundary —
/// safe because `CGImage` is immutable.
public struct CameraFrame: @unchecked Sendable {
    public let image: CGImage
    public let orientation: CGImagePropertyOrientation

    public init(image: CGImage, orientation: CGImagePropertyOrientation) {
        self.image = image
        self.orientation = orientation
    }
}

/// Where frames come from — the PERCEIVE seam. The live camera implements this on
/// device; tests feed fixtures. The source coalesces to the newest frame, so a
/// fast camera never backlogs the (slower) per-frame Vision pass.
public protocol FrameSource: AnyObject {
    var frames: AsyncStream<CameraFrame> { get }
}

/// Resolve one frame to normalized face geometry — the per-frame transform the
/// source runs in its loop. Injectable so tests can drive the failure-resilience
/// and freshness paths without a real Vision request.
public typealias FaceGeometryExtractor =
    @Sendable (CGImage, CGImagePropertyOrientation) async throws -> FaceGeometry?

/// Device-universal `FaceGeometrySource`: runs the Vision tools over the newest
/// frame a `FrameSource` delivers and emits normalized geometry — the baseline the
/// ARKit mesh source upgrades on TrueDepth devices.
///
/// `@MainActor`-isolated (it drives an overlay) so its lifecycle state is race-free.
/// **Single-use:** one `start()` / `stop()`; `stop()` finishes the stream and
/// further `start()`s are no-ops — construct a fresh source per screen appearance.
/// Both the input and the `geometry` output keep only the newest snapshot, so a
/// fast camera or a briefly-busy overlay never builds a stale backlog.
@available(iOS 18, macOS 15, *)
@MainActor
public final class VisionFaceGeometrySource: FaceGeometrySource {
    public let geometry: AsyncStream<FaceGeometry?>

    private static let log = Logger(subsystem: CosmoRealtimeLog.subsystem, category: "face-tracking")

    private let frameSource: FrameSource
    private let extract: FaceGeometryExtractor
    private let continuation: AsyncStream<FaceGeometry?>.Continuation
    private var task: Task<Void, Never>?
    private var finished = false

    public init(
        frameSource: FrameSource,
        extract: @escaping FaceGeometryExtractor = { try await VisionFaceGeometry.extract(from: $0, orientation: $1) }
    ) {
        self.frameSource = frameSource
        self.extract = extract
        (geometry, continuation) = AsyncStream<FaceGeometry?>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    deinit {
        // The task captures the continuation, not self — so without this it would
        // outlive a source the owner dropped without calling stop().
        task?.cancel()
        continuation.finish()
    }

    public func start() {
        guard task == nil, !finished else { return }
        let frames = frameSource.frames
        let extract = self.extract
        let continuation = continuation
        task = Task {
            // Coalesce to the newest frame: a cheap ingest pumps the camera into a
            // one-slot buffer (dropping stale frames), and the Vision loop pulls only
            // the latest — so a slow pass never runs detection on a superseded frame.
            let (latest, latestContinuation) =
                AsyncStream<CameraFrame>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let ingest = Task {
                for await frame in frames { latestContinuation.yield(frame) }
                latestContinuation.finish()
            }

            var loggedFailure = false
            for await frame in latest {
                if Task.isCancelled { break }
                let geometry: FaceGeometry?
                do {
                    geometry = try await extract(frame.image, frame.orientation)
                    loggedFailure = false
                } catch {
                    // Surface the first failure of a streak (a persistent bad pixel
                    // format / model-load error is worth seeing) without flooding the
                    // log at frame rate.
                    if !loggedFailure {
                        Self.log.error("face geometry extract failed: \(error.localizedDescription, privacy: .public)")
                        loggedFailure = true
                    }
                    geometry = nil
                }
                continuation.yield(geometry)
            }
            ingest.cancel()
            continuation.finish()
        }
    }

    public func stop() {
        finished = true
        task?.cancel()
        task = nil
        continuation.finish()
    }
}
