import Foundation
import LiveKit
import OpenAPIRuntime
import OpenAPIURLSession
import os

/// Room options shared by ``RealtimeSession/prepareSession(_:)`` and
/// ``LiveKitSessionTransport``'s join — prepared signaling state lives on the
/// ``Room``, so both must build identical instances.
func makeSessionRoom() -> Room {
    Room(roomOptions: RoomOptions(
        defaultAudioCaptureOptions: RealtimeSession.audioCaptureOptions,
        adaptiveStream: true,
        dynacast: true
    ))
}

extension RealtimeSession {

    private static let prepareLog = Logger(
        subsystem: CosmoRealtimeLog.subsystem, category: "session-prewarm"
    )

    /// A room + pre-minted join token (edge-resolved) parked by
    /// ``prepareSession(_:)`` so the next ``start(_:config:)`` joins
    /// immediately on the held token while ``/session/start`` runs in
    /// parallel. Single process-global slot, like the legacy surface's parked
    /// session — the refresh loop re-parks it from outside any session.
    struct PreparedSessionHandle {
        let roomName: String
        let roomGrant: String
        let token: String
        let livekitURL: String
        let room: Room
        let preparedAt: Date
        /// The backend this handle was prepared against. A start pointed at a
        /// different ``Options/baseURL`` must not consume it — the room and
        /// grant only exist on the preparing backend.
        let baseURL: URL
    }

    private static let _preparedSessionLock = NSLock()
    nonisolated(unsafe) private static var _preparedSession: PreparedSessionHandle?
    /// Bumped by ``discardPreparedSession`` so a prepare that was already in
    /// flight when the discard happened (e.g. the refresh loop racing a
    /// sign-out) can't park a handle for the previous identity afterwards.
    nonisolated(unsafe) private static var _preparedSessionEpoch = 0

    /// Max age of a parked session that a start will consume. Kept comfortably
    /// under the prepared join-token TTL (server: 30 min, matching the room)
    /// so a press never joins on a near-expired token — an older handle is
    /// discarded and the start falls back to the serialized path. The refresh
    /// loop (~20 min) re-parks well inside this, so the fallback is the rare
    /// case (app suspended past a refresh tick, etc.).
    static let _preparedSessionMaxAge: TimeInterval = 26 * 60

    static func _preparedSessionCurrentEpoch() -> Int {
        _preparedSessionLock.lock()
        defer { _preparedSessionLock.unlock() }
        return _preparedSessionEpoch
    }

    /// Park ``prepared``, unless a ``discardPreparedSession`` happened after
    /// ``epoch`` was snapshotted. Returns whether the handle was parked; a
    /// displaced or rejected handle's room is handed back for cleanup.
    static func _storePreparedSession(
        _ prepared: PreparedSessionHandle, epoch: Int
    ) -> Bool {
        let displaced: Room?
        let stored: Bool
        _preparedSessionLock.lock()
        if epoch == _preparedSessionEpoch {
            displaced = _preparedSession?.room
            _preparedSession = prepared
            stored = true
        } else {
            displaced = prepared.room
            stored = false
        }
        _preparedSessionLock.unlock()
        _disconnectDroppedRoom(displaced)
        return stored
    }

    /// Consume the parked session when it targets the same backend and is
    /// young enough to trust its token. A non-matching or stale handle is
    /// dropped (single slot — the next refresh re-parks) and the caller falls
    /// back to the serialized start path.
    static func _takePreparedSession(baseURL: URL) -> PreparedSessionHandle? {
        _preparedSessionLock.lock()
        let prepared = _preparedSession
        _preparedSession = nil
        _preparedSessionLock.unlock()
        guard let prepared else { return nil }
        guard
            prepared.baseURL == baseURL,
            Date().timeIntervalSince(prepared.preparedAt) <= _preparedSessionMaxAge
        else {
            Self.prepareLog.info(
                "prepared session discarded at take room=\(prepared.roomName, privacy: .public) age_s=\(Int(Date().timeIntervalSince(prepared.preparedAt)), privacy: .public)"
            )
            _disconnectDroppedRoom(prepared.room)
            return nil
        }
        return prepared
    }

    /// Drop any parked prepared session. Call on sign-out or account switch —
    /// the room grant is bound to the preparing user, so a handle held across
    /// an identity change would be rejected (403) at start. Also fences out
    /// any prepare already in flight (epoch bump).
    public static func discardPreparedSession() {
        _preparedSessionLock.lock()
        let dropped = _preparedSession?.room
        _preparedSession = nil
        _preparedSessionEpoch += 1
        _preparedSessionLock.unlock()
        _disconnectDroppedRoom(dropped)
    }

    /// A dropped handle's ``Room`` holds a pre-warmed signaling connection;
    /// close it instead of waiting for deinit / LiveKit's own expiry.
    private static func _disconnectDroppedRoom(_ room: Room?) {
        guard let room else { return }
        Task { await room.disconnect() }
    }

    /// Pre-create a room + mint the join token off the press path
    /// (first-party instant-connect). Call at sign-in / wake / on a refresh
    /// cadence. The next ``start(_:config:)`` against the same
    /// ``Options/baseURL`` consumes the parked session: it joins the room
    /// immediately on the held token while ``/session/start`` (carrying the
    /// room ref) runs in parallel. An absent or stale parked session degrades
    /// to the serialized start path.
    public static func prepareSession(
        _ options: Options
    ) async throws {
        let prepareStarted = Date()
        let epoch = _preparedSessionCurrentEpoch()
        // prepare-room is a first-party instant-connect fast-path, deliberately
        // absent from the external developer spec (`CosmoRealtimeAPI`). It's the
        // one session-surface call issued as a direct REST request (no generated
        // client) so the surviving stack doesn't depend on the retiring
        // first-party OpenAPI surface.
        let prepared = try await _postPrepareRoom(options: options)

        // Token-bearing prepare resolves + parks the best Cloud edge on the
        // Room, which the joining start consumes to shrink ws_open.
        // Best-effort: a failure still parks the handle — the join then pays
        // full signaling but keeps the pre-minted token + parallel start.
        let room = makeSessionRoom()
        do {
            try await room.prepareConnection(url: prepared.livekitUrl, token: prepared.token)
        } catch {
            Self.prepareLog.info(
                "prepared-session edge prepare failed: \(error.localizedDescription, privacy: .public)"
            )
        }
        let parked = _storePreparedSession(
            PreparedSessionHandle(
                roomName: prepared.roomName,
                roomGrant: prepared.roomGrant,
                token: prepared.token,
                livekitURL: prepared.livekitUrl,
                room: room,
                preparedAt: Date(),
                baseURL: options.baseURL
            ),
            epoch: epoch
        )
        guard parked else {
            Self.prepareLog.notice(
                "prepared session dropped — identity discarded mid-prepare room=\(prepared.roomName, privacy: .public)"
            )
            return
        }
        PrewarmCache.storeLastLiveKitURL(prepared.livekitUrl)
        let prepMs = Int(Date().timeIntervalSince(prepareStarted) * 1000)
        Self.prepareLog.notice(
            "prepared session parked room=\(prepared.roomName, privacy: .public) prep_ms=\(prepMs, privacy: .public)"
        )
    }

    /// Minimal decode of the first-party `POST /session/prepare-room` response.
    struct PrepareRoomResponse: Decodable {
        let livekitUrl: String
        let token: String
        let roomName: String
        let roomGrant: String
        enum CodingKeys: String, CodingKey {
            case livekitUrl = "livekit_url"
            case token
            case roomName = "room_name"
            case roomGrant = "room_grant"
        }
    }

    /// Build the first-party prepare-room POST request. Split out from
    /// ``_postPrepareRoom`` so the wire serialization — endpoint path, bearer
    /// auth header, and the empty JSON body — is unit-testable without a
    /// network round-trip (guards against silent drift now that the generated
    /// client no longer enforces the shape).
    static func _makePrepareRoomRequest(options: Options) throws -> URLRequest {
        var request = URLRequest(
            url: options.baseURL.appending(path: "api/v1/external/realtime/session/prepare-room")
        )
        request.httpMethod = "POST"
        request.setValue("Bearer \(options.credential.bearerValue)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        options.clientIdentity?.apply(to: &request)
        request.httpBody = Data("{}".utf8)
        return request
    }

    /// Issue the first-party prepare-room REST call directly (no generated
    /// client) so the surviving stack has no dependency on the retiring
    /// first-party OpenAPI surface. Mirrors ``makeRESTSession``'s loopback-TLS
    /// policy and the options' request timeout, and maps failures onto the same
    /// ``RealtimeSessionError`` cases the generated path used.
    private static func _postPrepareRoom(
        options: Options
    ) async throws -> PrepareRoomResponse {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = options.requestTimeout
        configuration.timeoutIntervalForResource = options.requestTimeout
        let session = makeRESTSession(
            configuration: configuration,
            verifyTLS: options.verifyTLS,
            host: options.baseURL.host
        )
        let request: URLRequest
        do {
            request = try _makePrepareRoomRequest(options: options)
        } catch {
            throw RealtimeSessionError.sessionStartFailed(message: error.localizedDescription)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RealtimeSessionError.sessionStartFailed(message: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw RealtimeSessionError.sessionStartFailed(message: "prepare-room: non-HTTP response")
        }
        switch http.statusCode {
        case 200..<300:
            do {
                return try JSONDecoder().decode(PrepareRoomResponse.self, from: data)
            } catch {
                throw RealtimeSessionError.sessionStartFailed(
                    message: "prepare-room response decode failed: \(error.localizedDescription)"
                )
            }
        case 422:
            let detail = String(data: data, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 }
            throw RealtimeSessionError.handshakeFailed(
                status: 422,
                code: detail.flatMap { rejectionCode(inBody: $0) },
                detail: detail ?? "Unprocessable content"
            )
        default:
            throw RealtimeSessionError.handshakeFailed(status: http.statusCode, code: nil, detail: nil)
        }
    }
}
