import Foundation

/// Persisted last-used LiveKit URL, the prewarm target for
/// ``RealtimeSession/prewarmConnection(origin:)``.
///
/// The URL is per-environment stable (the project's LiveKit Cloud URL),
/// so the most recent one is a valid pre-warm target until the env
/// changes — and a stale URL just wastes a harmless TLS warm-up that the
/// next connect's authoritative URL ignores.
///
/// The key string is stable across sessions, so any session start warms the
/// next connect against the last session's LiveKit URL.
enum PrewarmCache {
    static let lastLiveKitURLDefaultsKey = "ai.socratic.cosmo-realtime.lastLiveKitURL"

    /// Read the cached LiveKit URL, treating an empty string as absent.
    static func lastLiveKitURL(_ defaults: UserDefaults = .standard) -> String? {
        guard
            let url = defaults.string(forKey: lastLiveKitURLDefaultsKey),
            !url.isEmpty
        else { return nil }
        return url
    }

    /// Record the LiveKit URL a successful join used, for the next prewarm.
    static func storeLastLiveKitURL(_ url: String, _ defaults: UserDefaults = .standard) {
        defaults.set(url, forKey: lastLiveKitURLDefaultsKey)
    }
}
