import CosmoRealtimeAPI
import Foundation

/// First-party Cosmo sends, namespaced behind ``RealtimeSession/cosmo``. They
/// ride the published external transport but carry Cosmo product payloads
/// (per-turn desktop context, background-agent updates) wire-compatible with the
/// internal protocol; external integrations never use them.
extension RealtimeSession {

    /// Namespace for the first-party cosmo client messages.
    public var cosmo: CosmoSends { CosmoSends(session: self) }

    public struct CosmoSends: Sendable {
        let session: RealtimeSession

        /// Cursor position in screen coordinates (AppKit bottom-left origin).
        public typealias CursorPoint =
            CosmoRealtimeAPI.Components.Schemas.RealtimeCosmoCursorPoint

        /// Attach per-turn desktop context (cursor, frontmost app, open apps)
        /// to the user's current turn. Silent — no spoken response.
        public func sendTurnContext(
            cursor: CursorPoint? = nil,
            frontmostApp: String? = nil,
            openApps: [String] = [],
            clientTurnSeq: Int? = nil,
            extras: [String: String] = [:]
        ) async throws {
            try await session._sendCosmoTurnContext(
                cursor: cursor,
                frontmostApp: frontmostApp,
                openApps: openApps,
                clientTurnSeq: clientTurnSeq,
                extras: extras
            )
        }

        /// Send labeled screen-state metadata to the agent proactively (not
        /// gated on a user turn) — the model seeds it silently. Each send is
        /// stamped with a monotonic per-session sequence so the server can
        /// drop frames that lose the data-channel-vs-audio race.
        public func sendVisualContext(_ payload: VisualContextPayload) async throws {
            try await session._sendCosmoVisualContext(payload)
        }
    }

    func _sendCosmoTurnContext(
        cursor: CosmoSends.CursorPoint?,
        frontmostApp: String?,
        openApps: [String],
        clientTurnSeq: Int?,
        extras: [String: String]
    ) async throws {
        try _assertSendable()
        try await _publish(
            CosmoRealtimeAPI.Components.Schemas.RealtimeCosmoTurnContext(
                clientTurnSeq: clientTurnSeq,
                cursor: cursor,
                extras: extras.isEmpty
                    ? nil
                    : .init(additionalProperties: extras),
                frontmostApp: frontmostApp,
                openApps: openApps,
                _type: .turnContext
            )
        )
    }

    /// Deliver a background client tool's terminal result to the agent. The
    /// worker resolves the original tool call from ``jobId`` and injects the
    /// outcome. Called by ``ClientToolJobSink`` when a job completes/fails.
    func _sendCosmoToolJobResult(_ result: BackgroundToolResult) async throws {
        try _assertSendable()
        let resultPayload: CosmoRealtimeAPI.Components.Schemas.RealtimeCosmoToolJobResult.ResultPayload?
        if let object = result.result {
            resultPayload = .init(additionalProperties: try objectContainer(from: object))
        } else {
            resultPayload = nil
        }
        try await _publish(
            CosmoRealtimeAPI.Components.Schemas.RealtimeCosmoToolJobResult(
                error: result.error,
                jobId: result.jobId,
                result: resultPayload,
                status: result.status == .completed ? .completed : .failed,
                summary: result.summary,
                toolName: result.toolName,
                _type: .toolJobResult
            )
        )
    }

    func _sendCosmoVisualContext(_ payload: VisualContextPayload) async throws {
        try _assertSendable()
        visualContextSeq += 1
        let frame = CosmoVisualContextFrame(
            reason: payload.reason.rawValue,
            timestampMs: payload.timestampMs,
            activeDisplay: payload.activeDisplay,
            focusedApp: payload.focusedApp,
            focusedWindow: payload.focusedWindow.map {
                .init(app: $0.app, title: $0.title, url: $0.url, display: $0.display)
            },
            cursor: payload.cursor.map { .init(x: $0.x, y: $0.y) },
            cursorDisplay: payload.cursorDisplay,
            displays: payload.displays.map {
                .init(
                    id: $0.id, role: $0.role, focused: $0.focused,
                    visibleApps: $0.visibleApps, visibleWindows: $0.visibleWindows
                )
            },
            imageRefs: payload.imageRefs.map {
                .init(
                    id: $0.id, kind: $0.kind, streamId: $0.streamId,
                    display: $0.display, app: $0.app, windowTitle: $0.windowTitle
                )
            },
            clientSeq: visualContextSeq,
            extras: payload.extras.isEmpty ? nil : payload.extras
        )
        try await _publish(frame)
    }
}

/// Internal-wire-compatible ``visual-context`` frame. Hand-built rather than a
/// generated type so the cosmo surface carries no dependency on the legacy
/// spec (which retires in Phase 4); the backend parses inbound client messages
/// against the internal union, so only field/type fidelity matters. Snake_case
/// wire names via ``CodingKeys``; nil optionals are omitted (synthesized
/// ``encodeIfPresent``), matching the internal defaults.
private struct CosmoVisualContextFrame: Encodable {
    let type = "visual-context"
    let reason: String
    let timestampMs: Int?
    let activeDisplay: String?
    let focusedApp: String?
    let focusedWindow: Window?
    let cursor: Cursor?
    let cursorDisplay: String?
    let displays: [Display]
    let imageRefs: [ImageRef]
    let clientSeq: Int
    let extras: [String: String]?

    struct Cursor: Encodable {
        let x: Double
        let y: Double
    }
    struct Window: Encodable {
        let app: String?
        let title: String?
        let url: String?
        let display: String?
    }
    struct Display: Encodable {
        let id: String
        let role: String
        let focused: Bool
        let visibleApps: [String]
        let visibleWindows: [String]
        enum CodingKeys: String, CodingKey {
            case id, role, focused
            case visibleApps = "visible_apps"
            case visibleWindows = "visible_windows"
        }
    }
    struct ImageRef: Encodable {
        let id: String
        let kind: String
        let streamId: String
        let display: String?
        let app: String?
        let windowTitle: String?
        enum CodingKeys: String, CodingKey {
            case id, kind, display, app
            case streamId = "stream_id"
            case windowTitle = "window_title"
        }
    }
    enum CodingKeys: String, CodingKey {
        case type, reason, cursor, displays, extras
        case timestampMs = "timestamp_ms"
        case activeDisplay = "active_display"
        case focusedApp = "focused_app"
        case focusedWindow = "focused_window"
        case cursorDisplay = "cursor_display"
        case imageRefs = "image_refs"
        case clientSeq = "client_seq"
    }
}
