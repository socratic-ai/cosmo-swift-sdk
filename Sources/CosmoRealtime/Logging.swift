import Foundation

/// Shared os_log subsystem for the CosmoRealtime SDK.
///
/// Intentionally the SAME string as the first-party app's
/// `RealtimeLog.subsystem` (`socratic.cosmo-realtime`) so a single
/// `log stream` / `log show` predicate captures app + SDK together
/// during a session. The two live in separate Swift packages and can't
/// share a constant, so the value is duplicated here on purpose —
/// keep them in sync. `category` distinguishes the source (SDK uses
/// `client` / `dispatch` / `sends` / `screenshare` / `session-ws`;
/// the app uses `session-model` / `voice-session` / `audio` / …).
///
/// See this package's internal contributor notes ("Querying logs") for
/// the canonical query and the connect-latency phase breakdown.
public enum CosmoRealtimeLog {
    public static let subsystem = "socratic.cosmo-realtime"
}
