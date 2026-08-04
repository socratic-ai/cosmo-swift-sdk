import Foundation
import Testing
@testable import CosmoRealtime

@Suite("RealtimeSession.Options credential surface")
struct SessionOptionsTests {

    private static let baseURL = URL(string: "https://platform.askcosmo.ai")!

    @Test("init(apiKey:) yields an apiKey credential that can mint")
    func apiKeyCredential() {
        let options = RealtimeSession.Options(apiKey: "k")
        #expect(options.credential == .apiKey("k"))
        #expect(options.canMint == true)
    }

    @Test("init(token:) yields a token credential that cannot mint")
    func tokenCredential() {
        let options = RealtimeSession.Options(token: "jwt")
        #expect(options.credential == .token("jwt"))
        #expect(options.canMint == false)
    }

    @Test("designated init(credential:) preserves an apiKey credential that can mint")
    func designatedInitApiKey() {
        let options = RealtimeSession.Options(credential: .apiKey("k"))
        #expect(options.credential == .apiKey("k"))
        #expect(options.canMint == true)
    }

    @Test("designated init(credential:) preserves a token credential that cannot mint")
    func designatedInitToken() {
        let options = RealtimeSession.Options(credential: .token("jwt"))
        #expect(options.credential == .token("jwt"))
        #expect(options.canMint == false)
    }

    @Test("options take their backend from the resolver, not the caller")
    func baseURLComesFromResolver() {
        #expect(RealtimeSession.Options(apiKey: "k").baseURL == RealtimeBaseURL.resolve())
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
            ("https://platform.askcosmo.ai", true),
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
            (VerifyTLS.auto, "platform.askcosmo.ai", true),
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
            (VerifyTLS.disabled, "platform.askcosmo.ai", false),
        ]
    )
    func verifyTLSResolution(mode: VerifyTLS, host: String, expectVerify: Bool) {
        #expect(mode.resolve(forHost: host) == expectVerify)
    }

    @Test("start rejects a cleartext remote base URL before any network call")
    func startThrowsOnInsecureBaseURL() async {
        var options = RealtimeSession.Options(apiKey: "k")
        options.baseURL = URL(string: "http://example.com")!
        await #expect(throws: RealtimeSessionError.insecureBaseURL("http://example.com")) {
            _ = try await RealtimeSession.start(options)
        }
    }
}

@Suite("COSMO_BASE_URL resolution")
struct BaseURLResolutionTests {

    private func resolve(_ value: String?) -> URL {
        RealtimeBaseURL.resolve(environment: value.map { ["COSMO_BASE_URL": $0] } ?? [:])
    }

    @Test("an unset, empty, or whitespace-only value falls back to production")
    func fallsBackToProduction() {
        for value in [nil, "", "   "] {
            #expect(resolve(value) == RealtimeBaseURL.productionBaseURL)
        }
    }

    @Test("a configured backend is used verbatim, trimmed")
    func usesConfiguredBackend() {
        #expect(resolve("  https://staging.example.com  ")
            == URL(string: "https://staging.example.com")!)
    }

    @Test("trailing slashes are dropped so one backend has one spelling")
    func dropsTrailingSlashes() {
        #expect(resolve("https://staging.example.com///")
            == URL(string: "https://staging.example.com")!)
    }

    @Test("a cleartext remote backend resolves to something start will reject")
    func cleartextRemoteIsRejectable() {
        #expect(RealtimeSession.isSecureBaseURL(resolve("http://evil.example.com")) == false)
        #expect(RealtimeSession.isSecureBaseURL(resolve("http://localhost:8000")) == true)
    }

    @Test("an unparseable value never silently resolves to production")
    func unparseableIsNotProduction() {
        let resolved = resolve("not a url")
        #expect(resolved != RealtimeBaseURL.productionBaseURL)
        #expect(RealtimeSession.isSecureBaseURL(resolved) == false)
    }
}
