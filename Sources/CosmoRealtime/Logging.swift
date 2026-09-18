import Foundation

/// Shared os_log subsystem for the CosmoRealtime SDK.
///
/// One subsystem (`socratic.cosmo-realtime`) covers everything the SDK
/// logs, so a single `log stream` / `log show` predicate captures a
/// whole session. `category` distinguishes the source (`session`,
/// `session-transport`, `session-screenshare`, `client-tools`, …).
///
/// ``trace(_:_:_:)`` is the second, opt-in sink, and it carries only what
/// a command-line run cannot otherwise see: `os_log` levels are configured
/// outside the process and `.debug` records are not persisted, so no
/// environment variable can turn them on. Setting `COSMO_LOG_LEVEL` to
/// `silent`, `error`, `warn`, `info`, or `debug` gates the traced lines,
/// which today means the connect-latency breakdown at `debug`.
///
/// This is narrower than the same variable in Python and TypeScript, where
/// it makes the whole SDK verbose. Everything the SDK logs still goes to
/// `os_log` under the subsystem above, and that stays the way to read a
/// session in full. Widening the stderr sink means routing the `Logger`
/// call sites through it, which would cost them their `privacy:`
/// annotations.
public enum CosmoRealtimeLog {
    /// The `os_log` subsystem every SDK log record is filed under — pass it
    /// to Console.app or `log stream` to read a session.
    public static let subsystem = "socratic.cosmo-realtime"

    /// How much the SDK writes to standard error.
    enum Level: Int, Sendable {
        case silent = 0
        case error = 1
        case warning = 2
        case info = 3
        case debug = 4
    }

    static let levelEnvironmentVariable = "COSMO_LOG_LEVEL"

    /// The verbosity `COSMO_LOG_LEVEL` asked for; ``Level/silent`` when it
    /// asked for nothing. An unrecognized value reads as silent rather than
    /// trapping: a typo in a debugging variable must not stop a launch.
    static let level: Level = parseLevel(
        ProcessInfo.processInfo.environment[levelEnvironmentVariable]
    )

    static func parseLevel(_ raw: String?) -> Level {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "error": return .error
        case "warn", "warning": return .warning
        case "info": return .info
        case "debug": return .debug
        default: return .silent
        }
    }

    /// Write one line to standard error when the environment asked for this
    /// level or louder. The message is autoclosed, so a caller pays only for
    /// the interpolation it actually emits.
    static func trace(
        _ level: Level,
        _ category: String,
        _ message: @autoclosure () -> String
    ) {
        guard level.rawValue <= Self.level.rawValue, level != .silent else { return }
        let line = "cosmo-realtime \(category) \(message())\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
