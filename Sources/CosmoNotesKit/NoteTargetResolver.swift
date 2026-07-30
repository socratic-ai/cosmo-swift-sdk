import Foundation

/// Deterministic mapping from a note tool call's target parameters to exactly
/// one note. Daily rules: no target means today and a `date` means that day's
/// daily note — an invalid date is an error, never a fallback.
public enum NoteTargetResolver {
    /// One target parameter as supplied by a tool call.
    public enum Target: Equatable, Sendable {
        /// A `YYYY-MM-DD` calendar day.
        case date(String)
    }

    /// A resolved daily note.
    public struct DailyTarget: Equatable, Sendable {
        /// The deterministic store id, `daily-YYYY-MM-DD`.
        public let id: String
        /// The `YYYY-MM-DD` day key, which is also the note's title.
        public let dateKey: String

        public init(dateKey: String) {
            self.id = Note.dailyID(dateKey: dateKey)
            self.dateKey = dateKey
        }
    }

    /// The outcome of resolving one call's targets.
    public enum DailyResolution: Equatable, Sendable {
        case resolved(DailyTarget)
        /// The supplied date is not a real `YYYY-MM-DD` calendar date.
        case invalidDate(String)
    }

    /// The single place "today" is computed: with no target, the daily note
    /// for the calendar day containing `now` in `timeZone`. Production
    /// callers pass `Date()` and `TimeZone.current` at the moment of the
    /// tool call, so the day boundary follows the device's current local
    /// timezone at that instant.
    public static func resolveDaily(
        targets: [Target], now: Date, timeZone: TimeZone
    ) -> DailyResolution {
        guard let target = targets.first else {
            return .resolved(
                DailyTarget(dateKey: MarkdownSections.dateStamp(now, timeZone: timeZone)))
        }
        switch target {
        case .date(let stamp):
            guard MarkdownSections.isValidStamp(stamp) else { return .invalidDate(stamp) }
            return .resolved(DailyTarget(dateKey: stamp))
        }
    }
}
