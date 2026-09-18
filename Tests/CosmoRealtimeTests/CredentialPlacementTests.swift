import Foundation
import Testing

@testable import CosmoRealtime

/// The predicate behind the construction trap: a workspace API key is
/// refused in the token slot, acts-as-user tokens and minted JWTs are not.
/// The trap itself is a `fatalError` and cannot run in-process; the
/// predicate carries the decision, so it is what gets pinned.
@Suite("Credential placement")
struct CredentialPlacementTests {

    @Test func aWorkspaceKeyIsAPIKeyShaped() {
        #expect(CredentialPlacement.isAPIKeyShaped("cosmo_" + String(repeating: "a", count: 64)))
    }

    @Test func actsAsUserTokensAreNot() {
        #expect(!CredentialPlacement.isAPIKeyShaped("cosmo_pat_" + String(repeating: "b", count: 32)))
    }

    @Test func mintedJWTsAreNot() {
        #expect(!CredentialPlacement.isAPIKeyShaped("eyJhbGciOiJIUzI1NiJ9.payload.sig"))
    }

    @Test func legitimateTokensStillConstruct() {
        _ = RealtimeClient(token: "eyJhbGciOiJIUzI1NiJ9.payload.sig")
        _ = RealtimeClient(token: "cosmo_pat_" + String(repeating: "b", count: 32))
    }

    @Test func theMessageNamesTheRemedyAndTheDocs() {
        #expect(CredentialPlacement.apiKeyInTokenSlotMessage.contains("apiKey:"))
        #expect(CredentialPlacement.apiKeyInTokenSlotMessage.contains("mintToken"))
        #expect(CredentialPlacement.apiKeyInTokenSlotMessage.contains("end-user-credentials"))
    }

    @Test func anAPIKeyStillConstructsAClientAnywhere() {
        _ = RealtimeClient(apiKey: "cosmo_" + String(repeating: "a", count: 64))
    }
}
