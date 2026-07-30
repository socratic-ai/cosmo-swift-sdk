import Foundation
import Testing

@testable import CosmoRealtime

/// Pins the LiveKit-URL cache that ``RealtimeSession/prewarmConnection`` reads
/// and ``LiveKitSessionTransport`` writes after a join. Covers the pure
/// read/write/empty-string logic offline. The live TLS warm itself
/// (``Room.prepareConnection``) needs the network and is not yet covered by
/// any test.
@Suite("Prewarm URL cache")
struct PrewarmCacheTests {

    private func freshDefaults() -> UserDefaults {
        let suite = "PrewarmCacheTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func absentWhenNeverStored() {
        #expect(PrewarmCache.lastLiveKitURL(freshDefaults()) == nil)
    }

    @Test func storeThenReadRoundtrips() {
        let defaults = freshDefaults()
        PrewarmCache.storeLastLiveKitURL("wss://edge.example", defaults)
        #expect(PrewarmCache.lastLiveKitURL(defaults) == "wss://edge.example")
    }

    @Test func emptyStringReadsAsAbsent() {
        let defaults = freshDefaults()
        PrewarmCache.storeLastLiveKitURL("", defaults)
        #expect(PrewarmCache.lastLiveKitURL(defaults) == nil)
    }

    @Test func laterStoreOverwrites() {
        let defaults = freshDefaults()
        PrewarmCache.storeLastLiveKitURL("wss://a.example", defaults)
        PrewarmCache.storeLastLiveKitURL("wss://b.example", defaults)
        #expect(PrewarmCache.lastLiveKitURL(defaults) == "wss://b.example")
    }
}
