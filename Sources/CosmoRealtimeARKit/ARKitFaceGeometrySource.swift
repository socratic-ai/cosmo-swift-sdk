import CoreGraphics
import CosmoRealtime
import Foundation

/// Where face-anchor snapshots come from — the ARKit analog of `FrameSource`,
/// with one deliberate difference: it has `start()` / `stop()` because the live
/// feed *owns* its `ARSession`, whereas Vision's `FrameSource` is a passive stream
/// the app's camera drives. The live feed implements this on TrueDepth devices;
/// tests feed synthetic snapshots. A `nil` element means "no face this update".
public protocol FaceAnchorFeed: AnyObject {
    var snapshots: AsyncStream<FaceAnchorSnapshot?> { get }
    func start()
    func stop()
    /// The current camera still as an upright `CGImage`, or `nil` when the camera
    /// has no frame yet — the session owner already has the pixels, so the still
    /// path rides the same feed as the geometry.
    func currentImage() -> CGImage?
}

/// ARKit `FaceGeometrySource`: projects the face anchor a `FaceAnchorFeed`
/// delivers into normalized geometry — the TrueDepth upgrade to the device-
/// universal Vision baseline (`VisionFaceGeometrySource`). Pose and distance come
/// straight from the continuously-tracked `ARFaceAnchor`, so a pinned highlight
/// glides instead of jittering frame to frame.
///
/// `@MainActor`-isolated (it drives an overlay). **Single-use:** one `start()` /
/// `stop()`; `stop()` pauses the feed and finishes the stream, and further
/// `start()`s are no-ops — construct a fresh source per screen appearance. The
/// `geometry` output keeps only the newest snapshot, so a slow overlay tracks the
/// latest face position rather than a stale backlog.
@MainActor
public final class ARKitFaceGeometrySource: FaceGeometrySource, CameraStillProviding {
    public let geometry: AsyncStream<FaceGeometry?>

    private let feed: FaceAnchorFeed
    private let continuation: AsyncStream<FaceGeometry?>.Continuation
    private var task: Task<Void, Never>?
    private var finished = false

    public init(feed: FaceAnchorFeed) {
        self.feed = feed
        (geometry, continuation) =
            AsyncStream<FaceGeometry?>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    deinit {
        // The task captures the continuation, not self — cancel so it can't
        // outlive a source the owner dropped without calling stop().
        task?.cancel()
        continuation.finish()
    }

    public func start() {
        guard task == nil, !finished else { return }
        feed.start()
        let snapshots = feed.snapshots
        let continuation = continuation
        task = Task {
            for await snapshot in snapshots {
                if Task.isCancelled { break }
                continuation.yield(snapshot.map(ARFaceGeometryProjector.geometry(from:)))
            }
            continuation.finish()
        }
    }

    public func stop() {
        finished = true
        feed.stop()
        task?.cancel()
        task = nil
        continuation.finish()
    }

    /// The current camera still (upright `CGImage`) for the single-frame Vision
    /// tools — so the same ARKit session that tracks the face also feeds the
    /// measurement tools, with no second camera.
    public func currentFrame() -> CGImage? { feed.currentImage() }
}
