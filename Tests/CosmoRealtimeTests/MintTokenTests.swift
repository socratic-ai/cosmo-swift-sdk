import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
import os.lock
@testable import CosmoRealtime

@Suite("Mint token")
struct MintTokenTests {


    @Test("a 200 maps to a MintedToken with the parsed jwt and expiry")
    func okMapsToMintedToken() async throws {
        let body = #"{"jwt":"end-user-jwt","expires_at":"2026-06-24T10:00:00Z","token_id":"tok-1"}"#
        let transport = StubTransport {
            (HTTPResponse(status: .ok), HTTPBody(body))
        }
        let token = try await makeStubClient(transport).mintToken("user-42")
        #expect(token.jwt == "end-user-jwt")
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = 24
        components.hour = 10
        components.timeZone = TimeZone(identifier: "UTC")
        let expected = Calendar(identifier: .gregorian).date(from: components)
        #expect(token.expiresAt == expected)
        #expect(token.tokenId == "tok-1")
    }

    @Test("an auth-layer 401 is request_rejected; its body carries no slug, so http_401")
    func unauthorizedMapsToRejected() async {
        let body = #"{"detail":"Invalid API key"}"#
        let transport = StubTransport { jsonResponse(.unauthorized, body) }
        await #expect {
            _ = try await makeStubClient(transport).mintToken("user-42")
        } throws: { error in
            guard let error = error as? MintTokenError else { return false }
            return error.code == .requestRejected
                && error.serverCode == "http_401"
                && error.message == "Invalid API key"
        }
    }

    @Test("an undocumented 4xx lifts the body's slug onto serverCode")
    func undocumentedRejectionMapsToRejected() async {
        let body = #"{"detail":{"code":"forbidden","message":"missing scope"}}"#
        let transport = StubTransport { jsonResponse(.forbidden, body) }
        await #expect {
            _ = try await makeStubClient(transport).mintToken("user-42")
        } throws: { error in
            guard let error = error as? MintTokenError else { return false }
            return error.code == .requestRejected
                && error.serverCode == "forbidden"
                && error.message.contains("missing scope")
        }
    }

    @Test("an undocumented rejection carrying no slug falls back to the http_<status> synthetic")
    func undocumentedRejectionWithoutCodeMapsToSynthetic() async {
        let body = #"{"detail":"service unavailable"}"#
        let transport = StubTransport { jsonResponse(.serviceUnavailable, body) }
        await #expect {
            _ = try await makeStubClient(transport).mintToken("user-42")
        } throws: { error in
            guard let error = error as? MintTokenError else { return false }
            // No object-shaped detail.code, so nothing to lift; the message
            // still carries the status and raw body.
            return error.code == .requestRejected
                && error.serverCode == "http_503"
                && error.message.contains("service unavailable")
        }
    }

    @Test("an undocumented rejection carrying only a type surfaces that type as the slug")
    func undocumentedRejectionWithTypeOnlySurfacesType() async {
        // An api key without the mint scope earns an ordinary 403 whose
        // envelope has a type and no code. The reference SDKs report
        // `api_error` for it, so a caller branching on the server slug must
        // not see `http_403` here instead.
        let body = #"{"error":{"type":"api_error","message":"Missing scope: user_tokens:mint"}}"#
        let transport = StubTransport { jsonResponse(.forbidden, body) }
        await #expect {
            _ = try await makeStubClient(transport).mintToken("user-42")
        } throws: { error in
            guard let error = error as? MintTokenError else { return false }
            return error.code == .requestRejected
                && error.serverCode == "api_error"
                && error.message == "Missing scope: user_tokens:mint"
        }
    }

    @Test("a validation 422 carries no code, so the envelope's type becomes the slug")
    func unprocessableContentMapsToRejected() async {
        let body = #"{"error":{"type":"validation_error","message":"Invalid request parameters \u2014 body.external_user_id: Field required","errors":[{"loc":["body","external_user_id"],"type":"missing","msg":"Field required"}]}}"#
        let transport = StubTransport { jsonResponse(.unprocessableContent, body) }
        await #expect {
            _ = try await makeStubClient(transport).mintToken("")
        } throws: { error in
            guard let error = error as? MintTokenError else { return false }
            return error.code == .requestRejected
                && error.serverCode == "validation_error"
                && error.message.contains("Field required")
        }
    }

    @Test("a typed 422 rejection surfaces the envelope's error code")
    func typedRejectionSurfacesCode() async {
        let body = #"{"error":{"type":"api_error","code":"inline_tools_not_allowed","message":"Inline server-tool definitions require API-key authentication."}}"#
        let transport = StubTransport { jsonResponse(.unprocessableContent, body) }
        await #expect {
            _ = try await makeStubClient(transport).mintToken("")
        } throws: { error in
            guard let error = error as? MintTokenError else { return false }
            return error.code == .requestRejected
                && error.serverCode == "inline_tools_not_allowed"
                && error.message.contains("API-key")
        }
    }

    @Test("a 200 with an undecodable body maps to invalid_response")
    func undecodableSuccessBodyMapsToInvalidResponse() async {
        let transport = StubTransport { jsonResponse(.ok, "not json at all") }
        await #expect {
            _ = try await makeStubClient(transport).mintToken("user-42")
        } throws: { error in
            guard let error = error as? MintTokenError else { return false }
            return error.code == .invalidResponse
                && error.serverCode == nil
                && !error.message.isEmpty
        }
    }

    @Test("a transport throw maps to request_failed")
    func transportThrowMapsToRequestFailed() async {
        let transport = StubTransport { throw StubError() }
        await #expect {
            _ = try await makeStubClient(transport).mintToken("user-42")
        } throws: { error in
            guard let error = error as? MintTokenError else { return false }
            return error.code == .requestFailed
                && error.serverCode == nil
                && !error.message.isEmpty
        }
    }

    @Test("a token-credentialed client is refused without reaching the network")
    func tokenCredentialRefusedBeforeNetwork() async {
        let transport = StubTransport {
            Issue.record("a token-only client must not reach the network")
            return jsonResponse(.ok, "{}")
        }
        await #expect {
            _ = try await makeStubClient(transport, credential: .token("end-user-jwt"))
                .mintToken("user-42")
        } throws: { error in
            (error as? MintTokenError)?.code == .missingApiKey
        }
    }

    @Test("a token-source client cannot mint either")
    func tokenSourceCredentialRefused() async {
        let transport = StubTransport {
            Issue.record("a token-source client must not reach the network")
            return jsonResponse(.ok, "{}")
        }
        let source = TokenSource.custom {
            MintedToken(jwt: "jwt", expiresAt: Date().addingTimeInterval(3600))
        }
        await #expect {
            _ = try await makeStubClient(transport, credential: .tokenSource(source))
                .mintToken("user-42")
        } throws: { error in
            (error as? MintTokenError)?.code == .missingApiKey
        }
    }
}
