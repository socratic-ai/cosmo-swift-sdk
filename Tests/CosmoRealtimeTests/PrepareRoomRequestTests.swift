import Foundation
import Testing
@testable import CosmoRealtime

/// Wire serialization of the hand-rolled first-party prepare-room REST call
/// (``RealtimeSession/_makePrepareRoomRequest``), which replaced the generated
/// client in the retirement. The generated path was correct-by-construction;
/// these pin the endpoint path, bearer auth, and the snake_case response keys
/// so a future backend field rename can't drift silently.
@Suite("prepare-room request serialization")
struct PrepareRoomRequestTests {

    private func options(
        key: String = "cosmo_secret",
        base: String = "https://api.example.com",
        clientIdentity: ClientIdentity? = nil
    ) -> RealtimeSession.Options {
        var options = RealtimeSession.Options(apiKey: key, clientIdentity: clientIdentity)
        options.baseURL = URL(string: base)!
        return options
    }

    @Test("POSTs to the first-party prepare-room path with bearer auth + JSON content-type")
    func requestShape() throws {
        let req = try RealtimeSession._makePrepareRoomRequest(options: options())
        #expect(req.httpMethod == "POST")
        #expect(req.url?.absoluteString == "https://api.example.com/api/v1/external/realtime/session/prepare-room")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer cosmo_secret")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test("body is an empty JSON object — the server resolves the project from the credential")
    func bodyIsEmptyObject() throws {
        let req = try RealtimeSession._makePrepareRoomRequest(options: options())
        let json = try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]
        #expect(json?.isEmpty == true)
    }

    @Test("response decodes the snake_case wire keys")
    func responseDecode() throws {
        let wire = #"{"livekit_url":"wss://lk.example/room","token":"jwt-abc","room_name":"r-1","room_grant":"grant-xyz"}"#
        let resp = try JSONDecoder().decode(RealtimeSession.PrepareRoomResponse.self, from: Data(wire.utf8))
        #expect(resp.livekitUrl == "wss://lk.example/room")
        #expect(resp.token == "jwt-abc")
        #expect(resp.roomName == "r-1")
        #expect(resp.roomGrant == "grant-xyz")
    }

    @Test("carries the client identity headers when one is set")
    func prepareRoomSendsClientIdentity() throws {
        let req = try RealtimeSession._makePrepareRoomRequest(
            options: options(
                clientIdentity: ClientIdentity(client: "cosmo-mac", marketingVersion: "1.0.0", build: "42")
            )
        )
        #expect(req.value(forHTTPHeaderField: "X-Cosmo-Client") == "cosmo-mac")
        #expect(req.value(forHTTPHeaderField: "X-Cosmo-Client-Version") == "1.0.0")
        #expect(req.value(forHTTPHeaderField: "X-Cosmo-Client-Build") == "42")
    }

    @Test("sends no client headers when no identity is set")
    func prepareRoomWithoutClientIdentity() throws {
        let req = try RealtimeSession._makePrepareRoomRequest(options: options())
        #expect(req.value(forHTTPHeaderField: "X-Cosmo-Client") == nil)
        #expect(req.value(forHTTPHeaderField: "X-Cosmo-Client-Version") == nil)
        #expect(req.value(forHTTPHeaderField: "X-Cosmo-Client-Build") == nil)
    }
}
