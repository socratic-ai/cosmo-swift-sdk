import CoreGraphics
import Foundation
import OSLog

/// The capture an element was found in and its index there, split back out of
/// a `found_element` handle. Internal: a renderer's handler is given the
/// resolved ``ScreenElement``, never the token's parts, so nothing downstream
/// can address an element the locator did not pick.
struct FoundElement: Sendable, Equatable {
    let captureID: String
    let elementIndex: Int
}

/// The `found_element` handle `cosmo_screen_locate` mints and a renderer
/// spends. Opaque to the model — it passes one along, it never builds one.
///
/// The format is a two-party contract with the backend's
/// `encode_found_element`, pinned by `sdk-client-tool-vectors.json`
/// (`foundElement`). It has to be pinned: an unresolvable handle is a benign
/// decline by design, so a separator that disagreed with the backend would
/// degrade into a session where every renderer quietly declines and the model
/// re-locates forever, failing nothing.
public enum FoundElementHandle {
    static let separator: Character = "#"

    /// Mint a handle the way the backend does. The SDK never calls this in
    /// production — the locator is the only minter — but the format lives in
    /// code so both sides can be checked against the same vectors.
    static func encode(captureID: String, elementIndex: Int) -> String {
        "\(captureID)\(separator)\(elementIndex)"
    }

    /// Split a handle into its parts; `nil` when it is not one this SDK minted
    /// the shape of. The rightmost separator binds, so a capture id containing
    /// one survives the round trip.
    static func decode(_ handle: String) -> FoundElement? {
        guard let cut = handle.lastIndex(of: separator) else { return nil }
        let captureID = String(handle[handle.startIndex..<cut])
        let index = handle[handle.index(after: cut)...]
        guard !captureID.isEmpty, !index.isEmpty,
              index.allSatisfy(\.isASCII), index.allSatisfy(\.isNumber),
              let elementIndex = Int(index)
        else { return nil }
        return FoundElement(captureID: captureID, elementIndex: elementIndex)
    }
}

/// Which mouse button a click uses. `right` is the context-menu button.
public enum ScreenButton: String, Sendable, CaseIterable {
    /// The primary button — a left click on desktop, a tap on touch.
    case left
    /// The context-menu button — a right click, or a long press on touch.
    case right
}

/// How to click the located element: which button, and whether it's a double.
/// The wire distinguishes only single vs double, so `double` is a bool.
public struct ScreenAction: Sendable, Equatable {
    /// Which button or gesture to use.
    public let button: ScreenButton
    /// Whether it is a double click. Orthogonal to ``button``.
    public let double: Bool

    /// Creates a click action; the defaults are a single left click.
    public init(button: ScreenButton = .left, double: Bool = false) {
        self.button = button
        self.double = double
    }
}

/// Which side of the target the tooltip sits on. `auto` picks the side with
/// the most room.
public enum ScreenPlacement: String, Sendable, CaseIterable {
    /// Let the renderer pick the side with the most room.
    case auto
    /// Above the target.
    case top
    /// Below the target.
    case bottom
    /// To the left of the target.
    case left
    /// To the right of the target.
    case right
}

/// Which affordance to draw on a highlight, matched to the action being asked
/// of the user. Describes the glyph only — a highlight never acts (see
/// ``ScreenAction`` for that).
public enum ScreenAffordance: String, Sendable, CaseIterable {
    /// A plain pointer, drawing attention without naming an action.
    case pointer
    /// Asks for a click, without specifying which button.
    case click
    /// Asks for a double click.
    case doubleClick = "double_click"
    /// Asks specifically for a left click.
    case leftClick = "left_click"
    /// Asks specifically for a right click.
    case rightClick = "right_click"
    /// Shows a drag, for a target the user must move rather than press.
    case dragShow = "drag_show"
    /// Asks for a press and hold.
    case pressHold = "press_hold"
    /// Points something out with no action asked of the user.
    case inform
}

/// A rectangle the caller located itself, as fractions of the shared surface
/// — the shared window's live bounds when a window is shared, else the
/// display: `x`/`y` are the top-left corner (0 = left/top edge), all four in
/// `0...1`.
///
/// Deliberately not a ``CGRect``: ``ScreenElement/frame`` is also a rectangle
/// but in screen points, and the two spaces are not interchangeable. A distinct
/// type makes mixing them a compile error rather than a highlight drawn in the
/// top-left one percent of the screen.
public struct ScreenBox: Sendable, Equatable {
    /// Left edge, `0...1` across the shared surface.
    public let x: Double
    /// Top edge, `0...1` down the shared surface.
    public let y: Double
    /// Width as a fraction of the surface's width.
    public let width: Double
    /// Height as a fraction of the surface's height.
    public let height: Double

    /// Creates a normalized box over the shared surface.
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// What the caller believes the target is *called*, alongside where it thinks
/// it is. A host with a platform accessibility tree can ask the OS for that
/// control's exact frame — a far better answer than any estimate — and one
/// without a usable tree ignores this and falls back to the box.
///
/// ``title`` is the control's own visible text ("Files changed"), not the
/// tooltip the highlight displays; those are different strings and the tooltip
/// travels separately as `label`.
public struct ScreenElementHint: Sendable, Equatable {
    /// What the model believes the target is called — its visible text, not
    /// the tooltip.
    public let title: String
    /// Platform role to disambiguate a title that appears more than once
    /// (e.g. `"AXButton"`). `nil` matches on title alone.
    public let role: String?

    /// Creates a hint the renderer may use to snap a box onto a real control.
    public init(title: String, role: String? = nil) {
        self.title = title
        self.role = role
    }
}

/// One interactive on-screen element the locator may select. `index` is
/// 0-based and contiguous within one ``ScreenCapture``; `frame` is in screen
/// points (top-left origin) so a host can act on its center.
public struct ScreenElement: Sendable {
    /// Position in this capture's element list, 0-based and contiguous. The
    /// model refers to an element by this.
    public let index: Int
    /// What kind of control it is, in the platform's own vocabulary.
    public let role: String
    /// Its visible title, when it has one.
    public let title: String?
    /// Its accessibility label, when it has one.
    public let label: String?
    /// Its current value — the text in a field, a control's setting.
    public let value: String?
    /// Where it sits, in screen points. Not interchangeable with
    /// ``ScreenBox``, which is normalized to the shared surface.
    public let frame: CGRect

    /// Creates an element for a capture you are returning to the locator.
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

/// A snapshot the locator works from: the image plus the pickable elements.
public struct ScreenCapture: Sendable {
    /// The screenshot the model reasons over, JPEG-encoded.
    public let imageJPEG: Data
    /// The elements the locator may pick from. It grounds a handle against
    /// these, so returning none leaves it nothing to resolve.
    public let elements: [ScreenElement]
    /// Opaque state you may stash and read back at click time — the SDK never
    /// inspects it. Use it to check the capture is still current, e.g. that
    /// the same app is still frontmost.
    public let context: (any Sendable)?

    /// Creates a capture to hand back to the locator.
    public init(
        imageJPEG: Data, elements: [ScreenElement] = [], context: (any Sendable)? = nil
    ) {
        self.imageJPEG = imageJPEG
        self.elements = elements
        self.context = context
    }
}

/// The capture being asked for. It carries no options today; any future
/// capture option lands here, inside the parameter every handler already
/// accepts.
public struct ScreenCaptureRequest: Sendable, Equatable {
    /// Creates a capture request. The SDK builds these; you receive one.
    public init() {}
}

/// Snapshot the current screen. Throw ``ScreenCaptureUnavailable`` to decline
/// benignly; any other throw is an unexpected failure.
public typealias ScreenCaptureHandler = @Sendable (ScreenCaptureRequest) async throws ->
    ScreenCapture

/// Thrown by a ``AgentTool/screenLocate(capture:)`` handler when the
/// screen can't be captured for a benign reason (call ended, sharing off). The
/// SDK maps it to `captured:false` + the message; any other error surfaces as a
/// tool error.
public struct ScreenCaptureUnavailable: RealtimeError, Sendable {
    /// Why the screen could not be captured — model-facing prose the agent
    /// says out loud, not an error code.
    public let message: String
    /// Creates a refusal carrying the reason to tell the user.
    public init(message: String) {
        self.message = message
    }
}

/// An unexpected failure servicing a screen tool (missing/invalid args,
/// byte-stream publish failure). Surfaces as an `{ok:false,error}` envelope via
/// ``ClientToolDispatch``; a handle that no longer resolves is a benign decline
/// (`clicked:false` / `shown:false`) rather than one of these.
struct ScreenToolError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Capture cache

/// Short-TTL cache pairing a capture with the renderer call that follows it:
/// `cosmo_screen_locate` drives the capture RPC, grounds the model's
/// description against the streamed screenshot + AX list, and mints handles; a
/// renderer resolves one here against the *same* snapshot. Keyed by capture id
/// (capped at ``maxEntries``) so concurrent captures don't evict each other.
final class ScreenCaptureCache: @unchecked Sendable {
    /// Every screen tool a host wires shares this one, which is what lets a
    /// handle minted during ``AgentTool/screenLocate(capture:)`` resolve
    /// inside a renderer declared separately. Capture ids are server-minted per
    /// capture, so entries never collide; ``maxAge`` and ``maxEntries`` bound it.
    static let shared = ScreenCaptureCache()

    static let log = Logger(subsystem: CosmoRealtimeLog.subsystem, category: "screen")

    /// A click against an older capture is grounded on a screen the user has
    /// likely scrolled or navigated away from.
    static let maxAge: TimeInterval = 30
    /// More than enough for the few captures that can be in flight at once.
    static let maxEntries = 4

    private struct Entry {
        let capture: ScreenCapture
        let createdAt: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let clock: @Sendable () -> Date

    /// ``now`` injects the clock for tests; production uses the wall clock.
    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = now
    }

    /// Store a capture under its id so a later handle can resolve against
    /// it. Evicts entries past the cache's age and size limits.
    func put(_ captureID: String, _ capture: ScreenCapture, now: Date? = nil) {
        let now = now ?? clock()
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { now.timeIntervalSince($0.value.createdAt) < Self.maxAge }
        entries[captureID] = Entry(capture: capture, createdAt: now)
        while entries.count > Self.maxEntries {
            guard let oldest = entries.min(by: { $0.value.createdAt < $1.value.createdAt }) else { break }
            entries.removeValue(forKey: oldest.key)
        }
    }

    /// The capture for ``captureID`` if present and not older than ``maxAge``.
    func get(_ captureID: String, now: Date? = nil) -> ScreenCapture? {
        let now = now ?? clock()
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[captureID] else { return nil }
        guard now.timeIntervalSince(entry.createdAt) < Self.maxAge else { return nil }
        return entry.capture
    }

    /// The element a handle names, with the capture it was found in. `nil` for
    /// any unresolvable handle — a token that does not parse, an unknown capture
    /// id, an expired entry, or an index past the elements that capture carried.
    ///
    /// A token that does not parse is the same miss to the model but not the
    /// same event: the locator only ever mints well-formed handles, so it means
    /// either this SDK drifted from the backend's encoder or the model invented
    /// one. Neither can throw — a fabricated handle is model output, not a
    /// broken invariant — so it is logged instead.
    func resolve(
        _ foundElement: String,
        now: Date? = nil
    ) -> (element: ScreenElement, capture: ScreenCapture)? {
        guard let parts = FoundElementHandle.decode(foundElement) else {
            Self.log.warning(
                "unparseable found_element handle: \(foundElement, privacy: .public)"
            )
            return nil
        }
        guard let capture = get(parts.captureID, now: now) else { return nil }
        guard capture.elements.indices.contains(parts.elementIndex) else { return nil }
        return (capture.elements[parts.elementIndex], capture)
    }

}

// MARK: - JSONValue conveniences (internal to the SDK)

extension JSONValue {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d == d.rounded(): return Int(d)
        default: return nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
}

/// Model-facing: a handle the cache can no longer resolve is a benign decline,
/// not an error — the model's move is to locate again, not to retry.
let unresolvableHandleReason =
    "that found_element is no longer valid — call cosmo_screen_locate again for a fresh one"

// MARK: - Shared arg decoding

enum ScreenArgs {
    /// Unknown placement/affordance values fall back rather than reject: they
    /// mean the caller is newer than this SDK, and a highlight with the wrong
    /// glyph still points the user at the right control, whereas a rejection
    /// points them at nothing.
    static func placement(_ args: [String: JSONValue]) -> ScreenPlacement {
        guard let raw = args["placement"]?.stringValue else { return .auto }
        return ScreenPlacement(rawValue: raw) ?? .auto
    }

    /// Wire name is `interaction`; the Swift parameter is `affordance` to keep
    /// it distinct from ``ScreenAction``, which is what a click actually does.
    static func affordance(_ args: [String: JSONValue]) -> ScreenAffordance {
        guard let raw = args["interaction"]?.stringValue else { return .click }
        return ScreenAffordance(rawValue: raw) ?? .click
    }

    static func clamp01(_ value: Double) -> Double { min(1, max(0, value)) }
}
