import Foundation
import Testing
@testable import CosmoRealtime

@Suite("client identity wire contract")
struct ClientIdentityTests {

    private let identity = ClientIdentity(
        client: "cosmo-mac",
        marketingVersion: "1.0.0",
        build: "42"
    )

    @Test("header fields carry client, version and build under the agreed names")
    func headerFields() {
        let fields = Dictionary(
            uniqueKeysWithValues: identity.headerFields.map { ($0.name, $0.value) }
        )
        #expect(fields["X-Cosmo-Client"] == "cosmo-mac")
        #expect(fields["X-Cosmo-Client-Version"] == "1.0.0")
        #expect(fields["X-Cosmo-Client-Build"] == "42")
        #expect(fields.count == 3)
    }

    @Test("apply stamps all three headers onto a URLRequest")
    func applyToRequest() {
        var request = URLRequest(url: URL(string: "https://api.example.com/x")!)
        identity.apply(to: &request)
        #expect(request.value(forHTTPHeaderField: "X-Cosmo-Client") == "cosmo-mac")
        #expect(request.value(forHTTPHeaderField: "X-Cosmo-Client-Version") == "1.0.0")
        #expect(request.value(forHTTPHeaderField: "X-Cosmo-Client-Build") == "42")
    }

    @Test("apply leaves unrelated headers untouched")
    func applyPreservesOtherHeaders() {
        var request = URLRequest(url: URL(string: "https://api.example.com/x")!)
        request.setValue("Bearer k", forHTTPHeaderField: "Authorization")
        identity.apply(to: &request)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer k")
    }
}
