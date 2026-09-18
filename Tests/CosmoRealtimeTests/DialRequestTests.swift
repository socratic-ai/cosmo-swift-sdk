import Foundation
import Testing
@testable import CosmoRealtime

/// Wire serialization of the hand-rolled outbound-dial REST call
/// (``RealtimeSession/_makeDialRequest``). The dial endpoint has no generated
/// client, so these pin the endpoint path, bearer auth, and the snake_case
/// request body — ``caller_number`` present only when a caller-ID is passed —
/// so a future backend rename can't drift silently.
@Suite("dial request serialization")
struct DialRequestTests {

    private func options(
        key: String = "cosmo_secret",
        base: String = "https://api.example.com"
    ) -> RealtimeClient {
        RealtimeClient(apiKey: key, baseURL: URL(string: base)!)
    }

    @Test("POSTs to the session dial path with bearer auth + JSON content-type")
    func requestShape() async throws {
        let req = try await RealtimeSession._makeDialRequest(
            client: options(),
            sessionId: "sess-1",
            phoneNumber: "+14155550199",
            callerNumber: nil
        )
        #expect(req.httpMethod == "POST")
        #expect(req.url?.absoluteString == "https://api.example.com/api/v1/external/realtime/session/sess-1/dial")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer cosmo_secret")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test("body carries only phone_number when no caller-ID is passed")
    func bodyWithoutCaller() async throws {
        let req = try await RealtimeSession._makeDialRequest(
            client: options(),
            sessionId: "sess-1",
            phoneNumber: "+14155550199",
            callerNumber: nil
        )
        let json = try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]
        #expect(json?["phone_number"] as? String == "+14155550199")
        #expect(json?["caller_number"] == nil)
    }

    @Test("body carries caller_number when a caller-ID is passed")
    func bodyWithCaller() async throws {
        let req = try await RealtimeSession._makeDialRequest(
            client: options(),
            sessionId: "sess-1",
            phoneNumber: "+14155550199",
            callerNumber: "+12139458610"
        )
        let json = try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]
        #expect(json?["phone_number"] as? String == "+14155550199")
        #expect(json?["caller_number"] as? String == "+12139458610")
    }

    @Test("response decodes the snake_case dial_id into DialResult")
    func responseDecode() throws {
        let wire = #"{"dial_id":"550e8400-e29b-41d4-a716-446655440000"}"#
        let result = try JSONDecoder().decode(DialResult.self, from: Data(wire.utf8))
        #expect(result.dialId == UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000"))
    }

    @Test("a dial_id that is not a UUID fails the decode")
    func responseDecodeRejectsNonUuid() {
        let wire = #"{"dial_id":"not-a-uuid"}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(DialResult.self, from: Data(wire.utf8))
        }
    }

    @Test("rejects a malformed number before any request")
    func rejectsMalformed() throws {
        // Refused before any request, so it is a dial the SDK would not send
        // rather than a session-start failure.
        #expect(throws: DialError.self) {
            try validateE164("not-a-number", field: "phone_number")
        }
        // A well-formed E.164 passes.
        try validateE164("+14155550199", field: "phone_number")
    }

    @Test("a rejection surfaces the server's prose, not the raw body")
    func rejectionSurfacesProse() {
        // The wire shape a business rejection actually sends. Handing the whole
        // body to `message` put this JSON in front of a caller.
        let body = #"{"detail":{"code":"minute_limit_exceeded","message":"You have used all of your minutes."}}"#
        let rejection = parseErrorDetail(status: 403, data: Data(body.utf8))

        #expect(rejection.message == "You have used all of your minutes.")
        #expect(rejection.code == "minute_limit_exceeded")

        let error = DialError(
            code: .requestRejected, message: rejection.message, serverCode: rejection.code)
        #expect(error.code == .requestRejected)
        #expect(error.serverCode == "minute_limit_exceeded")
        #expect(!error.message.contains("{"))
    }
}
