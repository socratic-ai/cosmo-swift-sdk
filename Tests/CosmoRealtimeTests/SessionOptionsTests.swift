import Foundation
import Testing
@testable import CosmoRealtime

@Suite("RealtimeSession.Options credential surface")
struct SessionOptionsTests {

    private static let baseURL = URL(string: "https://app.askcosmo.ai")!

    @Test("init(apiKey:) yields an apiKey credential that can mint")
    func apiKeyCredential() {
        let options = RealtimeSession.Options(apiKey: "k", baseURL: Self.baseURL)
        #expect(options.credential == .apiKey("k"))
        #expect(options.canMint == true)
    }

    @Test("init(token:) yields a token credential that cannot mint")
    func tokenCredential() {
        let options = RealtimeSession.Options(token: "jwt", baseURL: Self.baseURL)
        #expect(options.credential == .token("jwt"))
        #expect(options.canMint == false)
    }

    @Test("designated init(credential:) preserves an apiKey credential that can mint")
    func designatedInitApiKey() {
        let options = RealtimeSession.Options(credential: .apiKey("k"), baseURL: Self.baseURL)
        #expect(options.credential == .apiKey("k"))
        #expect(options.canMint == true)
    }

    @Test("designated init(credential:) preserves a token credential that cannot mint")
    func designatedInitToken() {
        let options = RealtimeSession.Options(credential: .token("jwt"), baseURL: Self.baseURL)
        #expect(options.credential == .token("jwt"))
        #expect(options.canMint == false)
    }

    @Test("bearerValue returns the underlying secret for each case")
    func bearerValueUnwraps() {
        #expect(RealtimeSession.Options.Credential.apiKey("k").bearerValue == "k")
        #expect(RealtimeSession.Options.Credential.token("jwt").bearerValue == "jwt")
    }

    @Test("description and debugDescription mask the secret")
    func credentialMasksSecret() {
        let key = RealtimeSession.Options.Credential.apiKey("super-secret-key")
        let token = RealtimeSession.Options.Credential.token("super-secret-jwt")

        for rendered in [key.description, key.debugDescription] {
            #expect(!rendered.contains("super-secret-key"))
            #expect(rendered == "Credential.apiKey(•••)")
        }
        for rendered in [token.description, token.debugDescription] {
            #expect(!rendered.contains("super-secret-jwt"))
            #expect(rendered == "Credential.token(•••)")
        }
    }

    @Test(
        "isSecureBaseURL allows https and loopback http, rejects cleartext to a remote host",
        arguments: [
            ("https://app.askcosmo.ai", true),
            ("https://EXAMPLE.com", true),
            ("http://localhost:8000", true),
            ("http://LOCALHOST", true),
            ("http://LocalHost:8000", true),
            ("http://127.0.0.1", true),
            ("http://[::1]:8000", true),
            ("http://example.com", false),
            // Host-less URL: `.host` is nil, so it fails closed as insecure.
            ("http:///path", false),
        ]
    )
    func secureBaseURLClassification(urlString: String, expected: Bool) {
        let url = URL(string: urlString)!
        #expect(RealtimeSession.isSecureBaseURL(url) == expected)
    }

    @Test(
        "VerifyTLS.resolve: .auto verifies remote hosts and skips loopback only; .enabled/.disabled are unconditional",
        arguments: [
            (VerifyTLS.auto, "app.askcosmo.ai", true),
            (VerifyTLS.auto, "localhost", false),
            (VerifyTLS.auto, "LOCALHOST", false),
            (VerifyTLS.auto, "127.0.0.1", false),
            (VerifyTLS.auto, "::1", false),
            // Look-alikes are not loopback — must still verify.
            (VerifyTLS.auto, "localhost.evil.com", true),
            (VerifyTLS.auto, "127.0.0.1.evil.com", true),
            // Empty host (URL.host nil → "") fails closed: verify.
            (VerifyTLS.auto, "", true),
            // .enabled always verifies; .disabled is a global escape hatch that
            // weakens trust even for a remote host.
            (VerifyTLS.enabled, "localhost", true),
            (VerifyTLS.disabled, "app.askcosmo.ai", false),
        ]
    )
    func verifyTLSResolution(mode: VerifyTLS, host: String, expectVerify: Bool) {
        #expect(mode.resolve(forHost: host) == expectVerify)
    }

    @Test("start rejects a cleartext remote base URL before any network call")
    func startThrowsOnInsecureBaseURL() async {
        let options = RealtimeSession.Options(
            apiKey: "k",
            baseURL: URL(string: "http://example.com")!
        )
        await #expect(throws: RealtimeSessionError.insecureBaseURL("http://example.com")) {
            _ = try await RealtimeSession.start(options)
        }
    }
}
