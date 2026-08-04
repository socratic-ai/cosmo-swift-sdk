import Foundation
import Testing
@testable import CosmoRealtime

/// ``VoiceSession/makeOptions(credentials:clientOptions:)`` is the only
/// ``RealtimeSession/Options`` builder on the live voice path — the session
/// start, the prepare-room call and the dial all inherit it, so an identity
/// dropped here is an unheadered voice path.
@Suite("voice-path session options")
struct VoiceSessionOptionsTests {

    private let credentials = Credentials(
        apiKey: "cosmo_secret",
        apiURL: URL(string: "https://platform.askcosmo.ai")!
    )

    private let identity = ClientIdentity(
        client: "cosmo-mac",
        marketingVersion: "1.0.0",
        build: "42"
    )

    @Test("the caller's client identity reaches the session options")
    func forwardsClientIdentity() {
        let options = VoiceSession.makeOptions(
            credentials: credentials,
            clientOptions: ClientOptions(clientIdentity: identity)
        )
        #expect(options.clientIdentity == identity)
        #expect(options._apiMiddlewares(prepared: nil).contains { $0 is ClientIdentityMiddleware })
    }

    @Test("no identity means no client headers")
    func withoutClientIdentity() {
        let options = VoiceSession.makeOptions(
            credentials: credentials,
            clientOptions: ClientOptions()
        )
        #expect(options.clientIdentity == nil)
        #expect(!options._apiMiddlewares(prepared: nil).contains { $0 is ClientIdentityMiddleware })
    }
}
