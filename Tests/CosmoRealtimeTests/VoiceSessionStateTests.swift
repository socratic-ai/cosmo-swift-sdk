import Testing
@testable import CosmoRealtime

/// ``VoiceSessionState/isCallActive`` answers "does a cloud session hold the
/// input device?" — it gates local note capture and the launcher's start
/// affordances. The exhaustive switch makes a *new* case a compile error, but
/// not a mis-classified existing one, so pin the classification itself.
@Suite struct VoiceSessionStateTests {

    private let live = VoiceSessionState.live(sessionId: "s1")

    @Test func connectingAndEndingHoldTheMicJustAsLiveDoes() {
        // The bug this pins: guarding on `isLive` alone let local capture start
        // mid-connect, landing a second consumer on the single input device the
        // moment the room joined.
        #expect(VoiceSessionState.connecting.isCallActive)
        #expect(VoiceSessionState.ending.isCallActive)
        #expect(live.isCallActive)
    }

    @Test func restingStatesDoNotHoldTheMic() {
        #expect(!VoiceSessionState.idle.isCallActive)
        #expect(!VoiceSessionState.error(.init(
            headline: "h",
            message: "m",
            heardTranscript: nil,
            actions: []
        )).isCallActive)
    }

    @Test func isLiveStaysNarrowerThanIsCallActive() {
        // The two are not interchangeable: `isLive` means "conversing",
        // `isCallActive` means "the mic is committed".
        #expect(!VoiceSessionState.connecting.isLive)
        #expect(!VoiceSessionState.ending.isLive)
        #expect(live.isLive)
    }
}
