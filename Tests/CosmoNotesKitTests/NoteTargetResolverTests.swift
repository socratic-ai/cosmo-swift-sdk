import Foundation
import Testing

@testable import CosmoNotesKit

@Suite struct NoteTargetResolverTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

    // 2026-07-21T12:00:00Z
    private let noon = Date(timeIntervalSince1970: 1_784_635_200)

    @Test func noTargetResolvesToTodayInTheGivenTimezone() {
        let resolution = NoteTargetResolver.resolveDaily(targets: [], now: noon, timeZone: utc)
        #expect(resolution == .resolved(.init(dateKey: "2026-07-21")))
        if case .resolved(let target) = resolution {
            #expect(target.id == "daily-2026-07-21")
        }
    }

    @Test func todayFollowsTheTimezoneNotTheInstant() {
        // 2026-07-21T03:00:00Z is still 2026-07-20 in Los Angeles (UTC-7).
        let earlyUTC = Date(timeIntervalSince1970: 1_784_602_800)
        let utcDay = NoteTargetResolver.resolveDaily(targets: [], now: earlyUTC, timeZone: utc)
        let laDay = NoteTargetResolver.resolveDaily(
            targets: [], now: earlyUTC, timeZone: losAngeles)
        #expect(utcDay == .resolved(.init(dateKey: "2026-07-21")))
        #expect(laDay == .resolved(.init(dateKey: "2026-07-20")))
    }

    @Test func midnightSplitsConsecutiveSavesAcrossDailyNotes() {
        // 23:59 and 00:01 UTC around the 2026-07-21 → 2026-07-22 boundary.
        let beforeMidnight = Date(timeIntervalSince1970: 1_784_678_340)
        let afterMidnight = Date(timeIntervalSince1970: 1_784_678_460)
        let before = NoteTargetResolver.resolveDaily(
            targets: [], now: beforeMidnight, timeZone: utc)
        let after = NoteTargetResolver.resolveDaily(
            targets: [], now: afterMidnight, timeZone: utc)
        #expect(before == .resolved(.init(dateKey: "2026-07-21")))
        #expect(after == .resolved(.init(dateKey: "2026-07-22")))
    }

    @Test func explicitDateResolvesToThatDayRegardlessOfNow() {
        let resolution = NoteTargetResolver.resolveDaily(
            targets: [.date("2026-02-03")], now: noon, timeZone: losAngeles)
        #expect(resolution == .resolved(.init(dateKey: "2026-02-03")))
        if case .resolved(let target) = resolution {
            #expect(target.id == "daily-2026-02-03")
        }
    }

    @Test func leapDayIsAValidDate() {
        let resolution = NoteTargetResolver.resolveDaily(
            targets: [.date("2028-02-29")], now: noon, timeZone: utc)
        #expect(resolution == .resolved(.init(dateKey: "2028-02-29")))
    }

    @Test(arguments: [
        "2026-02-30",  // not a real calendar day
        "2026-13-01",  // month out of range
        "26-07-21",  // wrong width
        "2026/07/21",  // wrong separator
        "July 4",  // not a stamp at all
        "",
    ])
    func invalidDateIsAnErrorNotAFallback(stamp: String) {
        let resolution = NoteTargetResolver.resolveDaily(
            targets: [.date(stamp)], now: noon, timeZone: utc)
        #expect(resolution == .invalidDate(stamp))
    }
}
