import CoreGraphics
import Foundation

/// The server→client RPCs behind the screen-interaction capability. Three form
/// the grounded choreography: the worker RPCs ``capture``, receives the
/// screenshot + AX list over a byte stream, grounds in-process, then RPCs
/// ``activate`` (or ``highlightElement``). ``highlightRegion`` stands apart —
/// its caller already has coordinates, so it skips capture and grounding.
/// Not model-facing tools — never advertised in the session's tool list, only
/// registered as RPC methods (see ``ScreenInteractionBridge``).
public enum ScreenInteractionRPC: String, CaseIterable, Sendable {
    case capture = "screen_interaction_capture"
    case activate = "screen_interaction_activate"
    case highlightElement = "screen_interaction_highlight"
    case highlightRegion = "screen_interaction_highlight_region"

    /// Byte-stream topic the capture payload is published on. Matches the
    /// backend's ``SCREEN_INTERACTION_CAPTURE_TOPIC``.
    public static let captureTopic = "screen_interaction_capture"
}

// MARK: - Capability value types (mirror the Python SDK's ScreenInteraction)

/// Which button/gesture to use on the grounded element. `primary` is a left
/// click on desktop / tap on touch; `secondary` a right click / long-press.
public enum ScreenButton: String, Sendable {
    case primary
    case secondary
}

/// How to act on the grounded element: which button/gesture and whether it's a
/// double. The wire distinguishes only single vs double, so `double` is a bool.
public struct ScreenAction: Sendable {
    public let button: ScreenButton
    public let double: Bool

    public init(button: ScreenButton = .primary, double: Bool = false) {
        self.button = button
        self.double = double
    }
}

/// Which side of the target the tooltip sits on. `auto` picks the side with
/// the most room.
public enum ScreenPlacement: String, Sendable, CaseIterable {
    case auto, top, bottom, left, right
}

/// Which affordance to draw on a highlight, matched to the action being asked
/// of the user. Describes the glyph only — a highlight never acts (see
/// ``ScreenAction`` for that).
public enum ScreenAffordance: String, Sendable, CaseIterable {
    case pointer
    case click
    case doubleClick = "double_click"
    case leftClick = "left_click"
    case rightClick = "right_click"
    case dragShow = "drag_show"
    case pressHold = "press_hold"
    case inform
}

/// A rectangle the caller located itself, as fractions of the shared surface
/// — the shared window's live bounds when a window is shared, else the
/// display: `x`/`y` are the top-left corner (0 = left/top edge), all four in
/// `0...1`.
///
/// Deliberately not a ``CGRect``: ``ScreenElement/frame`` is also a rectangle
/// but in screen points, and the two spaces are not interchangeable. A distinct
/// type makes mixing them a compile error rather than a spotlight drawn in the
/// top-left one percent of the screen.
public struct ScreenRegion: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// What the caller believes the target is *called*, alongside where it thinks
/// it is. A conformer with a platform accessibility tree can ask the OS for
/// that control's exact frame — a far better answer than any estimate — and
/// one without a usable tree ignores this and falls back to the region.
///
/// ``title`` is the control's own visible text ("Files changed"), not the
/// tooltip the highlight displays; those are different strings and the tooltip
/// travels separately as `label`.
public struct ScreenElementHint: Sendable, Equatable {
    public let title: String
    /// Platform role to disambiguate a title that appears more than once
    /// (e.g. `"AXButton"`). `nil` matches on title alone.
    public let role: String?

    public init(title: String, role: String? = nil) {
        self.title = title
        self.role = role
    }
}

/// One interactive on-screen element the grounder may select. `index` is
/// 0-based and contiguous within one ``ScreenCapture``; `frame` is in screen
/// points (top-left origin) so a conformer can act on its center.
public struct ScreenElement: Sendable {
    public let index: Int
    public let role: String
    public let title: String?
    public let label: String?
    public let value: String?
    public let frame: CGRect

    public init(
        index: Int,
        role: String,
        title: String?,
        label: String?,
        value: String?,
        frame: CGRect
    ) {
        self.index = index
        self.role = role
        self.title = title
        self.label = label
        self.value = value
        self.frame = frame
    }
}

/// Opaque per-capture state a conformer stashes at capture time and reads back
/// at action time to validate freshness before it acts. The SDK never inspects
/// it; the platform conformer defines what "still fresh" means.
public struct ScreenCaptureContext: Sendable {
    /// Frontmost app PID at capture time — a conformer may re-check it before
    /// acting so a stale grounding result can't land in a window the user
    /// switched to.
    public let appPID: pid_t?
    /// Focused-window frame (top-left global points); nil when unavailable.
    public let windowFrame: CGRect?

    public init(appPID: pid_t?, windowFrame: CGRect?) {
        self.appPID = appPID
        self.windowFrame = windowFrame
    }
}

/// A snapshot the grounder works from: the image plus the pickable elements,
/// plus the freshness context the conformer reads back at action time.
public struct ScreenCapture: Sendable {
    public let imageJPEG: Data
    public let elements: [ScreenElement]
    public let context: ScreenCaptureContext

    public init(imageJPEG: Data, elements: [ScreenElement], context: ScreenCaptureContext) {
        self.imageJPEG = imageJPEG
        self.elements = elements
        self.context = context
    }
}

/// Result of an ``ScreenInteraction/activate`` or a highlight: whether it acted,
/// plus an optional message the model narrates when it safely declined.
///
/// ``landedExactly`` answers a question only a highlight raises: the mark is
/// showing, but is it *on* the thing? A conformer that resolved the target to a
/// real control reports `true`; one that could only use the caller's estimate
/// reports `false`, which is the caller's cue to re-target through a more
/// precise route rather than leave a marker sitting next to the control. `nil`
/// where the distinction doesn't apply (``activate``, or a decline).
public struct ScreenActionOutcome: Sendable {
    public let ok: Bool
    public let message: String?
    public let landedExactly: Bool?

    public init(_ ok: Bool, message: String? = nil, landedExactly: Bool? = nil) {
        self.ok = ok
        self.message = message
        self.landedExactly = landedExactly
    }
}

/// Thrown by ``ScreenInteraction/capture`` when the screen can't be captured for
/// a benign reason (call ended, sharing off). The bridge maps it to
/// `captured:false` + the message; any other error surfaces as a tool error.
public struct ScreenCaptureUnavailable: Error, Sendable {
    public let message: String
    public init(message: String) {
        self.message = message
    }
}

/// A screen the agent can see and act on. A conforming type provides only the
/// platform pieces (screenshot, click, spotlight); ``ScreenInteractionBridge``
/// owns the transport plumbing (cache, byte-stream publish, RPC wiring). The
/// conformer is platform-specific and lives in the host app; this protocol and
/// the bridge are platform-agnostic and live in the SDK.
public protocol ScreenInteraction: Sendable {
    /// Snapshot the current screen. Throw ``ScreenCaptureUnavailable`` to decline
    /// benignly; any other throw is an unexpected failure.
    func capture() async throws -> ScreenCapture

    /// Act on the grounded element, from the same `capture` it was chosen in.
    /// Return `ScreenActionOutcome(false, …)` for a safe decline (the model can
    /// retry); throw only on an unexpected failure.
    func activate(
        element: ScreenElement,
        capture: ScreenCapture,
        action: ScreenAction
    ) async throws -> ScreenActionOutcome

    /// Mark/point at the grounded element instead of acting on it. Same
    /// decline-vs-throw contract as ``activate``.
    func highlightElement(
        element: ScreenElement,
        capture: ScreenCapture,
        label: String,
        placement: ScreenPlacement,
        affordance: ScreenAffordance
    ) async throws -> ScreenActionOutcome

    /// Mark/point at a region the caller located itself — no capture, no
    /// grounding round trip, so it draws immediately. The caller owns the
    /// coordinates and their accuracy. Same decline-vs-throw contract as
    /// ``activate``.
    ///
    /// Marking is offered this way and acting is not: a stale region draws a
    /// ring in the wrong place, while a stale click lands on the wrong control.
    /// Only the harmless one may skip the freshness check that grounding
    /// against a ``ScreenCapture`` provides.
    func highlightRegion(
        region: ScreenRegion,
        element: ScreenElementHint?,
        label: String,
        placement: ScreenPlacement,
        affordance: ScreenAffordance
    ) async throws -> ScreenActionOutcome
}

// MARK: - Capture cache

/// Short-TTL cache pairing a ``screen_interaction_capture`` with the later
/// ``screen_interaction_activate``/`highlight`: the worker grounds against the
/// streamed screenshot + AX list and sends back an element index; the follow-up
/// RPC resolves it here against the *same* snapshot. Keyed by capture id (capped
/// at ``maxEntries``) so concurrent captures don't evict each other.
public final class ScreenCaptureCache: @unchecked Sendable {
    /// A click against an older capture is grounded on a screen the user has
    /// likely scrolled or navigated away from.
    public static let maxAge: TimeInterval = 30
    /// More than enough for the few captures that can be in flight at once.
    public static let maxEntries = 4

    private struct Entry {
        let capture: ScreenCapture
        let createdAt: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let clock: @Sendable () -> Date

    /// ``now`` injects the clock for tests (e.g. the shared conformance vectors'
    /// TTL step); production uses the wall clock.
    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = now
    }

    public func put(_ captureID: String, _ capture: ScreenCapture, now: Date? = nil) {
        let now = now ?? clock()
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { now.timeIntervalSince($0.value.createdAt) <= Self.maxAge }
        entries[captureID] = Entry(capture: capture, createdAt: now)
        while entries.count > Self.maxEntries {
            guard let oldest = entries.min(by: { $0.value.createdAt < $1.value.createdAt }) else { break }
            entries.removeValue(forKey: oldest.key)
        }
    }

    /// The capture for ``captureID`` if present and not older than ``maxAge``.
    public func get(_ captureID: String, now: Date? = nil) -> ScreenCapture? {
        let now = now ?? clock()
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[captureID] else { return nil }
        guard now.timeIntervalSince(entry.createdAt) <= Self.maxAge else { return nil }
        return entry.capture
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        entries = [:]
    }
}
