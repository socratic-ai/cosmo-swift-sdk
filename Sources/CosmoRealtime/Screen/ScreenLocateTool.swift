import Foundation
import os.lock

/// The unadvertised half of the screen surface: the host's answer to "show me
/// the screen". `cosmo_screen_locate` drives it over RPC — the model never
/// picks it from a tool list — and the SDK keeps every snapshot it yields in a
/// short-TTL cache, so the handle the locator mints against that snapshot still
/// resolves when the model passes it to a renderer.
///
/// Declaring it is what turns the locator on: a config carrying one emits
/// `{kind: "screen_locate"}` and the server offers `cosmo_screen_locate` for
/// the session. There is no public initializer — construct it through
/// ``AgentTool/screenLocate(capture:)``.
final class ScreenLocateTool: @unchecked Sendable {
    /// Server→client RPC method the locator calls; a rename is a wire break.
    static let rpcMethod = "screen_capture"

    /// Byte-stream topic the capture payload is published on. Matches the
    /// backend's ``SCREEN_CAPTURE_TOPIC``.
    static let byteStreamTopic = "screen_capture"

    /// Descriptor budgets, matching the backend's `ScreenElement`. A descriptor
    /// is a *name* for a click target, so anything longer is a document that
    /// the screenshot already shows; `value` is content rather than identity
    /// and is held tighter. The backend clamps too — capping here keeps the
    /// bytes off the wire rather than guarding validation.
    static let roleMaxChars = 64
    static let labelMaxChars = 512
    static let valueMaxChars = 256

    private let onCapture: ScreenCaptureHandler
    private let cache: ScreenCaptureCache

    private let publish =
        OSAllocatedUnfairLock<(@Sendable (Data, String) async throws -> Void)?>(
            initialState: nil
        )

    init(cache: ScreenCaptureCache, onCapture: @escaping ScreenCaptureHandler) {
        self.cache = cache
        self.onCapture = onCapture
    }

    /// Bind the byte-stream publish to the live session. Set once, right after
    /// the transport comes up — the payload can only fire once the locator
    /// calls, well after connect, so the late bind never races.
    func bindPublish(_ publish: @escaping @Sendable (Data, String) async throws -> Void) {
        self.publish.withLock { $0 = publish }
    }

    /// The capture RPC as a handler, registered by wire method name without
    /// being advertised.
    func handler() -> ClientToolHandler {
        { [self] args in try await run(args) }
    }

    private func run(_ args: [String: JSONValue]) async throws -> [String: JSONValue] {
        guard let captureID = args["capture_id"]?.stringValue, !captureID.isEmpty else {
            throw ScreenToolError(message: "\(Self.rpcMethod): missing required 'capture_id'")
        }
        let capture: ScreenCapture
        do {
            capture = try await onCapture(ScreenCaptureRequest())
        } catch let unavailable as ScreenCaptureUnavailable {
            return ["captured": .bool(false), "message": .string(unavailable.message)]
        }
        cache.put(captureID, capture)
        let payload = try Self.encodePayload(captureID: captureID, capture: capture)
        guard let publish = self.publish.withLock({ $0 }) else {
            throw ScreenToolError(message: "\(Self.rpcMethod): byte-stream publish not bound")
        }
        do {
            try await publish(payload, Self.byteStreamTopic)
        } catch {
            throw ScreenToolError(
                message: "\(Self.rpcMethod): failed to publish capture stream: \(error.localizedDescription)"
            )
        }
        return ["captured": .bool(true)]
    }

    /// Truncates to `limit` Unicode scalars — the clamp unit every SDK
    /// shares (and the one the reply shrinker already counts), so the same
    /// descriptor clamps to the same text in all three. `prefix(_:)` would
    /// cut on grapheme clusters and disagree with the sibling SDKs.
    static func clamp(_ text: String, to limit: Int) -> String {
        let scalars = text.unicodeScalars
        guard scalars.count > limit else { return text }
        return String(String.UnicodeScalarView(scalars.prefix(limit)))
    }

    private static func names(_ descriptor: String?) -> Bool {
        guard let descriptor else { return false }
        return !descriptor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// JSON byte-stream payload the locator's ``ScreenCapturePayload``
    /// parses: `{capture_id, image_b64, mime_type, elements}`.
    static func encodePayload(captureID: String, capture: ScreenCapture) throws -> Data {
        struct ElementPayload: Encodable {
            let idx: Int
            let role: String
            let title: String?
            let label: String?
            let value: String?
            let frame: [Double]  // [x, y, w, h] in screen points
        }
        struct Payload: Encodable {
            let capture_id: String
            let image_b64: String
            let mime_type: String
            let elements: [ElementPayload]
        }
        let elements = capture.elements.map { el -> ElementPayload in
            let title = el.title.map { clamp($0, to: labelMaxChars) }
            let label = el.label.map { clamp($0, to: labelMaxChars) }
            // Carried only where it is the element's sole name: the grounder
            // reads the screenshot, so a named element's content is a second
            // copy of pixels it can already see. A blank descriptor names
            // nothing.
            let named = names(title) || names(label)
            let value = named ? nil : el.value.map { clamp($0, to: valueMaxChars) }
            return ElementPayload(
                idx: el.index,
                role: clamp(el.role, to: roleMaxChars),
                title: title,
                label: label,
                value: value,
                frame: [
                    Double(el.frame.origin.x),
                    Double(el.frame.origin.y),
                    Double(el.frame.size.width),
                    Double(el.frame.size.height),
                ]
            )
        }
        return try JSONEncoder().encode(
            Payload(
                capture_id: captureID,
                image_b64: capture.imageJPEG.base64EncodedString(),
                mime_type: "image/jpeg",
                elements: elements
            )
        )
    }
}

extension AgentTool {
    /// The screen the agent may look at, ready to add to ``RealtimeAgent/tools``
    /// alongside the renderers that act on what it finds:
    ///
    /// ```swift
    /// tools: [
    ///     .screenLocate { _ in try await screenshotAndAccessibilityList() },
    ///     .screenClickElement { request in … },
    ///     .screenHighlightElement { request in … },
    /// ]
    /// ```
    ///
    /// Unlike every other tool here it is never advertised: the model cannot
    /// call it, `cosmo_screen_locate` does. Declaring it is what asks for the
    /// locator, and the SDK owns everything wire-facing behind it — the capture
    /// cache, the payload encoding, the byte-stream publish, and the ack.
    /// Your handler owns only the snapshot; throw
    /// ``ScreenCaptureUnavailable`` to decline one benignly.
    static func screenLocate(
        capture: @escaping ScreenCaptureHandler
    ) -> AgentTool {
        screenLocate(cache: .shared, capture: capture)
    }

    /// Cache-injecting variant so tests can drive the pairing on their own clock.
    static func screenLocate(
        cache: ScreenCaptureCache,
        capture: @escaping ScreenCaptureHandler
    ) -> AgentTool {
        .screenLocate(ScreenLocateTool(cache: cache, onCapture: capture))
    }
}
