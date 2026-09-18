import Foundation
import Testing
@testable import CosmoRealtime

@Suite("RealtimeClient credential surface")
struct SessionOptionsTests {

    private static let baseURL = URL(string: "https://platform.askcosmo.ai")!

    @Test("init(apiKey:) yields an apiKey credential")
    func apiKeyCredential() {
        let client = RealtimeClient(apiKey: "k")
        #expect(client.credential == .apiKey("k"))
    }

    @Test("init(token:) yields a token credential")
    func tokenCredential() {
        let client = RealtimeClient(token: "jwt")
        #expect(client.credential == .token("jwt"))
    }

    @Test("designated init(credential:) preserves an apiKey credential")
    func designatedInitApiKey() {
        let client = RealtimeClient(credential: .apiKey("k"))
        #expect(client.credential == .apiKey("k"))
    }

    @Test("designated init(credential:) preserves a token credential")
    func designatedInitToken() {
        let client = RealtimeClient(credential: .token("jwt"))
        #expect(client.credential == .token("jwt"))
    }

    @Test("a client takes its backend from the resolver, not the caller")
    func baseURLComesFromResolver() {
        #expect(RealtimeClient(apiKey: "k").baseURL == RealtimeBaseURL.resolve())
    }

    @Test("init(tokenSource:) yields a tokenSource credential")
    func tokenSourceCredential() {
        let source = TokenSource.custom {
            MintedToken(jwt: "jwt", expiresAt: Date().addingTimeInterval(3600))
        }
        let client = RealtimeClient(tokenSource: source)
        #expect(client.credential == .tokenSource(source))
    }

    @Test("bearerToken returns the underlying secret for each case")
    func bearerTokenUnwraps() async throws {
        #expect(try await RealtimeClient.Credential.apiKey("k").bearerToken() == "k")
        #expect(try await RealtimeClient.Credential.token("jwt").bearerToken() == "jwt")
        let source = TokenSource.custom {
            MintedToken(jwt: "fetched-jwt", expiresAt: Date().addingTimeInterval(3600))
        }
        #expect(
            try await RealtimeClient.Credential.tokenSource(source).bearerToken()
                == "fetched-jwt"
        )
    }

    @Test("tokenSource credentials are equal by source identity, not configuration")
    func tokenSourceEquality() {
        let fetch: @Sendable () async throws -> MintedToken = {
            MintedToken(jwt: "jwt", expiresAt: Date().addingTimeInterval(3600))
        }
        let source = TokenSource.custom(fetch)
        let other = TokenSource.custom(fetch)
        #expect(
            RealtimeClient.Credential.tokenSource(source) == .tokenSource(source)
        )
        #expect(
            RealtimeClient.Credential.tokenSource(source) != .tokenSource(other)
        )
        #expect(RealtimeClient.Credential.tokenSource(source) != .token("jwt"))
    }

    @Test("description and debugDescription mask the secret")
    func credentialMasksSecret() {
        let key = RealtimeClient.Credential.apiKey("super-secret-key")
        let token = RealtimeClient.Credential.token("super-secret-jwt")
        let source = RealtimeClient.Credential.tokenSource(
            .custom { MintedToken(jwt: "jwt", expiresAt: Date()) }
        )

        for rendered in [key.description, key.debugDescription] {
            #expect(!rendered.contains("super-secret-key"))
            #expect(rendered == "Credential.apiKey(•••)")
        }
        for rendered in [token.description, token.debugDescription] {
            #expect(!rendered.contains("super-secret-jwt"))
            #expect(rendered == "Credential.token(•••)")
        }
        for rendered in [source.description, source.debugDescription] {
            #expect(rendered == "Credential.tokenSource(•••)")
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
        let client = RealtimeClient(
            apiKey: "k", baseURL: URL(string: "http://example.com")!
        )
        await #expect(throws: CredentialsError(code: .insecureBaseURL, message: "Realtime base URL must use https (http allowed only for localhost): http://example.com")) {
            _ = try await RealtimeSession.start(client)
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
