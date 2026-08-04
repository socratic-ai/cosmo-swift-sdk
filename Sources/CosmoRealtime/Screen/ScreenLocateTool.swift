import Foundation

/// The unadvertised half of the screen surface: the host's answer to "show me
/// the screen". `cosmo_screen_locate` drives it over RPC — the model never
/// picks it from a tool list — and the SDK keeps every snapshot it yields in a
/// short-TTL cache, so the ref the locator mints against that snapshot still
/// resolves when the model passes it to a renderer.
///
/// Declaring it is what turns the locator on: a config carrying one emits
/// `{kind: "screen_locate"}` and the server offers `cosmo_screen_locate` for
/// the session. There is no public initializer — construct it through
/// ``SessionConfig/Tool/screenLocate(capture:)``.
public final class ScreenLocateTool: @unchecked Sendable {
    /// Server→client RPC method the locator calls; a rename is a wire break.
    public static let rpcMethod = "screen_capture"

    /// Byte-stream topic the capture payload is published on. Matches the
    /// backend's ``SCREEN_CAPTURE_TOPIC``.
    public static let byteStreamTopic = "screen_capture"

    /// Snapshot the current screen. Throw ``ScreenCaptureUnavailable`` to
    /// decline benignly; any other throw is an unexpected failure.
    public typealias Handler = @Sendable () async throws -> ScreenCapture

    private let onCapture: Handler
    private let cache: ScreenCaptureCache

    private let lock = NSLock()
    private var publish: (@Sendable (Data, String) async throws -> Void)?

    init(cache: ScreenCaptureCache, onCapture: @escaping Handler) {
        self.cache = cache
        self.onCapture = onCapture
    }

    /// Bind the byte-stream publish to the live session. Set once, right after
    /// the transport comes up — the payload can only fire once the locator
    /// calls, well after connect, so the late bind never races.
    func bindPublish(_ publish: @escaping @Sendable (Data, String) async throws -> Void) {
        lock.lock(); self.publish = publish; lock.unlock()
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
            capture = try await onCapture()
        } catch let unavailable as ScreenCaptureUnavailable {
            return ["captured": .bool(false), "message": .string(unavailable.message)]
        }
        cache.put(captureID, capture)
        let payload = try Self.encodePayload(captureID: captureID, capture: capture)
        lock.lock(); let publish = self.publish; lock.unlock()
        guard let publish else {
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

    /// JSON byte-stream payload the locator's ``ScreenCapturePayload``
    /// parses: `{capture_id, image_b64, mime_type, ax_elements}`.
    static func encodePayload(captureID: String, capture: ScreenCapture) throws -> Data {
        struct AXElementPayload: Encodable {
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
            let ax_elements: [AXElementPayload]
        }
        let ax = capture.elements.map { el -> AXElementPayload in
            AXElementPayload(
                idx: el.index,
                role: el.role,
                title: el.title,
                label: el.label,
                value: el.value,
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
                ax_elements: ax
            )
        )
    }
}

extension SessionConfig.Tool {
    /// The screen the agent may look at, ready to add to ``SessionConfig/tools``
    /// alongside the renderers that act on what it finds:
    ///
    /// ```swift
    /// tools: [
    ///     .screenLocate { try await screenshotAndAccessibilityList() },
    ///     .screenClick { click in … },
    ///     .screenHighlight { highlight in … },
    /// ]
    /// ```
    ///
    /// Unlike every other tool here it is never advertised: the model cannot
    /// call it, `cosmo_screen_locate` does. Declaring it is what asks for the
    /// locator, and the SDK owns everything wire-facing behind it — the capture
    /// cache, the payload encoding, the byte-stream publish, and the ack.
    /// Your handler owns only the snapshot; throw
    /// ``ScreenCaptureUnavailable`` to decline one benignly.
    public static func screenLocate(
        capture: @escaping ScreenLocateTool.Handler
    ) -> SessionConfig.Tool {
        screenLocate(cache: .shared, capture: capture)
    }

    /// Cache-injecting variant so tests can drive the pairing on their own clock.
    static func screenLocate(
        cache: ScreenCaptureCache,
        capture: @escaping ScreenLocateTool.Handler
    ) -> SessionConfig.Tool {
        .screenLocate(ScreenLocateTool(cache: cache, onCapture: capture))
    }
}
