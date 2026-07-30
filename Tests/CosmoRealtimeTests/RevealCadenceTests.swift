import Foundation
import Testing
@testable import CosmoRealtime

@Suite struct RevealCadenceTests {
    @Test func tunedVoicesGetTheirOwnCadence() {
        #expect(RevealCadence.perWord(for: .charon) == .milliseconds(280))
        #expect(RevealCadence.perWord(for: .puck) == .milliseconds(220))
    }

    @Test func untunedVoicesFallBackToDefault() {
        for voice in [GeminiVoice.aoede, .fenrir, .kore, .leda, .orus, .zephyr] {
            #expect(RevealCadence.perWord(for: voice) == RevealCadence.defaultPerWord)
        }
    }

    @Test func everyVoiceResolvesToAPositiveInterval() {
        // No voice may map to a zero/negative cadence (would busy-spin the reveal).
        for voice in GeminiVoice.allCases {
            #expect(RevealCadence.perWord(for: voice) > .zero)
        }
    }
}
