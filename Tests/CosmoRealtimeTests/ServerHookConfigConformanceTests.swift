import Foundation
import Testing
@testable import CosmoRealtime

/// Executes the shared server-hook config vectors
/// (``sdks/cosmo-realtime/contract/server-hook-config-vectors.json``): every
/// canonical wire config round-trips through the ``SilenceTimeout`` wire type
/// unchanged. The Python suite consumes the same file — mirrors its
/// decode → dump → re-decode → equality semantics.
@Suite struct ServerHookConfigConformanceTests {

    @Test func silenceTimeoutRoundTripsSharedVectors() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // CosmoRealtimeTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // swift/
            .deletingLastPathComponent()  // cosmo-realtime/
            .appendingPathComponent("contract/server-hook-config-vectors.json", isDirectory: false)
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let vectors = root?["vectors"] as? [[String: Any]] ?? []
        #expect(!vectors.isEmpty)
        for vector in vectors {
            let name = vector["name"] as? String ?? "?"
            let wireData = try JSONSerialization.data(withJSONObject: vector["wire"] as Any)
            let decoded = try JSONDecoder().decode(SilenceTimeout.self, from: wireData)
            let reencoded = try JSONEncoder().encode(decoded)
            let redecoded = try JSONDecoder().decode(SilenceTimeout.self, from: reencoded)
            #expect(redecoded == decoded, "vector \(name) did not round-trip")
        }
    }
}
