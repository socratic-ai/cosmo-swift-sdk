import Foundation
import Testing

@testable import CosmoRealtime

/// ``VoiceSettingsStore/noiseCancellationPreference`` is the session-start
/// read: ``nil`` when the user never chose (so the field stays off the wire and
/// the server's per-surface default applies), the explicit value otherwise.
@Suite("VoiceSettings noise-cancellation preference")
struct VoiceSettingsPreferenceTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "socratic.cosmo-realtime.sdk.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test("unset preference is nil so the app leaves the field off the wire")
    func unsetPreferenceIsNil() {
        let store = VoiceSettingsStore(defaults: freshDefaults())
        #expect(store.noiseCancellationPreference == nil)
        // The always-a-Bool toggle accessor still reads its default-off.
        #expect(store.noiseCancellationEnabled == false)
    }

    @Test("an explicit choice is reported so it is sent on the wire and wins")
    func explicitChoiceIsReported() {
        let defaults = freshDefaults()
        let store = VoiceSettingsStore(defaults: defaults)

        store.noiseCancellationEnabled = false
        #expect(store.noiseCancellationPreference == false)

        store.noiseCancellationEnabled = true
        #expect(store.noiseCancellationPreference == true)
    }
}
