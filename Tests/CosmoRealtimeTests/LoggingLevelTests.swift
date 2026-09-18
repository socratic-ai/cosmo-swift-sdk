import Foundation
import Testing
@testable import CosmoRealtime

/// `COSMO_LOG_LEVEL` is read once at launch, so these drive the parse
/// directly rather than mutating the process environment.
@Suite("COSMO_LOG_LEVEL")
struct LoggingLevelTests {
    @Test("every documented value maps to its level", arguments: [
        ("silent", CosmoRealtimeLog.Level.silent),
        ("error", .error),
        ("warn", .warning),
        ("warning", .warning),
        ("info", .info),
        ("debug", .debug),
    ])
    func documentedValues(value: String, expected: CosmoRealtimeLog.Level) {
        #expect(CosmoRealtimeLog.parseLevel(value) == expected)
    }

    @Test("case and surrounding whitespace do not matter")
    func lenientParsing() {
        #expect(CosmoRealtimeLog.parseLevel("  DEBUG\n") == .debug)
    }

    @Test("unset and unrecognized both read as silent")
    func quietByDefault() {
        #expect(CosmoRealtimeLog.parseLevel(nil) == .silent)
        #expect(CosmoRealtimeLog.parseLevel("") == .silent)
        #expect(CosmoRealtimeLog.parseLevel("verbose") == .silent)
    }
}
