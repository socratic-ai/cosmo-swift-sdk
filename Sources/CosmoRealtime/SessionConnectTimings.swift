import CosmoRealtimeAPI
import Foundation

/// Server-side phase breakdown of session start (milliseconds).
///
/// Mirrors the ``starter_*`` fields of the "realtime session dispatched"
/// log line. Echoed to the client so it can emit one joined
/// startup-waterfall event (server + client phases) keyed by session_id,
/// instead of leaving the join to log archaeology.
///
/// The server produces these on ``/session/start``; the same shape comes
/// back untrusted on ``connect-timings``, so the bounds hold on both paths.
public struct RealtimeSessionStartTimings: Codable, Hashable, Sendable {
    /// Recording the session row.
    public var dbInsertMs: Swift.Int
    /// Dispatching the agent to the room. Reports ``0`` when dispatch runs
    /// after the response, where it costs the client nothing.
    public var dispatchMs: Swift.Int
    /// Minting the room join token.
    public var mintTokensMs: Swift.Int
    /// Resolving and authorizing the calling project.
    public var projectCheckMs: Swift.Int
    /// Choosing the model provider and confirming it is available here.
    public var providerResolveMs: Swift.Int
    /// Version check, project, provider, tools and limits, resolved
    /// together and reported as one number. The phases folded into it report
    /// ``0`` in their own fields rather than a fabricated split, and
    /// ``dispatch_ms`` reports ``0`` too — dispatch runs after the response, so
    /// it costs the client nothing.
    public var resolveMs: Swift.Int?
    /// The whole server-side start, end to end. Not the sum of the phases
    /// above — phases folded into ``resolve_ms`` report ``0`` individually.
    public var totalMs: Swift.Int
    /// Checking the client's SDK version against the supported floor.
    public var versionCheckMs: Swift.Int
    init(
        dbInsertMs: Swift.Int,
        dispatchMs: Swift.Int,
        mintTokensMs: Swift.Int,
        projectCheckMs: Swift.Int,
        providerResolveMs: Swift.Int,
        resolveMs: Swift.Int? = nil,
        totalMs: Swift.Int,
        versionCheckMs: Swift.Int
    ) {
        self.dbInsertMs = dbInsertMs
        self.dispatchMs = dispatchMs
        self.mintTokensMs = mintTokensMs
        self.projectCheckMs = projectCheckMs
        self.providerResolveMs = providerResolveMs
        self.resolveMs = resolveMs
        self.totalMs = totalMs
        self.versionCheckMs = versionCheckMs
    }
    enum CodingKeys: String, CodingKey {
        case dbInsertMs = "db_insert_ms"
        case dispatchMs = "dispatch_ms"
        case mintTokensMs = "mint_tokens_ms"
        case projectCheckMs = "project_check_ms"
        case providerResolveMs = "provider_resolve_ms"
        case resolveMs = "resolve_ms"
        case totalMs = "total_ms"
        case versionCheckMs = "version_check_ms"
    }
}

/// Per-session connect-latency snapshot: the client-measured phases of the
/// connect plus the server's own breakdown of session start. Sink-agnostic —
/// the SDK builds it; consumers decide where to report it. Every field is
/// `nil` until ``connect()`` completes.
public struct SessionConnectTimings: Sendable, Equatable {
    // Client-measured connect phases (milliseconds). `ws` is the REST
    // session-start, `room` the transport join (a LiveKit room join or
    // WebSocket upgrade), `mic` the mic-publish or activation (0 for a muted
    // join), `total` the whole connect through connect-ready. The phases do
    // not necessarily sum to `total`: when a room was created ahead of the
    // start, `ws` and `room` overlap.
    /// The REST session-start round trip.
    public let wsMs: Double?
    /// Joining the transport — a room join or a WebSocket upgrade.
    public let roomMs: Double?
    /// Publishing or activating the microphone. `0` for a muted join.
    public let micMs: Double?
    /// The whole connect, through connect-ready. Not the sum of the phases
    /// above: when a room was prepared ahead of the start, `ws` and `room`
    /// overlap.
    public let totalConnectMs: Double?

    /// Milliseconds from the start of the connect to the agent's
    /// ``RealtimeSessionEvent/ready(_:)`` frame. It lands after ``connect()``
    /// returns, so it is `nil` on a snapshot taken from the start onward
    /// until the frame arrives.
    public let readyMs: Double?

    /// Server-side session-start phases from the start response; `nil` on
    /// older backends.
    public let serverTimings: RealtimeSessionStartTimings?

    /// Timings assembled from each measured leg of the connect.
    public init(
        wsMs: Double?,
        roomMs: Double?,
        micMs: Double?,
        totalConnectMs: Double?,
        readyMs: Double? = nil,
        serverTimings: RealtimeSessionStartTimings? = nil
    ) {
        self.wsMs = wsMs
        self.roomMs = roomMs
        self.micMs = micMs
        self.totalConnectMs = totalConnectMs
        self.readyMs = readyMs
        self.serverTimings = serverTimings
    }
}
