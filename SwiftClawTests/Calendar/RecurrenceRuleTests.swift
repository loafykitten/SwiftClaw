import Foundation
import Testing
@testable import SwiftClaw

struct RecurrenceRuleTests {
    @Test func serializesCanonicalPartOrder() {
        let rule = RecurrenceRule(
            frequency: .weekly,
            interval: 2,
            daysOfWeek: [.init(.monday), .init(.wednesday)],
            end: .occurrenceCount(10)
        )
        #expect(rule.rruleString == "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE;COUNT=10")
    }

    @Test func omitsDefaultInterval() {
        #expect(RecurrenceRule.daily.rruleString == "FREQ=DAILY")
        #expect(RecurrenceRule.biweekly.rruleString == "FREQ=WEEKLY;INTERVAL=2")
    }

    @Test(arguments: [
        "FREQ=DAILY",
        "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE;COUNT=10",
        "FREQ=MONTHLY;BYDAY=3TU",
        "FREQ=MONTHLY;BYDAY=-1FR",
        "FREQ=MONTHLY;BYMONTHDAY=1,15,-1",
        "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1",
        "FREQ=YEARLY;BYMONTH=3,9",
        "FREQ=WEEKLY;BYDAY=SA,SU;WKST=SU",
        "FREQ=DAILY;UNTIL=20261231T235959Z",
    ])
    func roundTripsSupportedRules(_ rrule: String) throws {
        let rule = try #require(RecurrenceRule(rruleString: rrule))
        #expect(rule.rruleString == rrule)
    }

    @Test func parsesDateOnlyUntilAsEndOfUTCDay() throws {
        let rule = try #require(RecurrenceRule(rruleString: "FREQ=DAILY;UNTIL=20260630"))
        guard case .untilDate(let until) = rule.end else {
            Issue.record("expected an UNTIL end")
            return
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: until)
        #expect(parts.year == 2026)
        #expect(parts.month == 6)
        #expect(parts.day == 30)
        #expect(parts.hour == 23)
        #expect(parts.minute == 59)
        #expect(parts.second == 59)
    }

    @Test func parsingIsCaseInsensitiveForKeysAndTokens() throws {
        let rule = try #require(RecurrenceRule(rruleString: "freq=weekly;byday=mo,fr"))
        #expect(rule.frequency == .weekly)
        #expect(rule.daysOfWeek.map(\.weekday) == [.monday, .friday])
    }

    @Test(arguments: [
        "",                        // no FREQ
        "FREQ=HOURLY",             // unsupported frequency
        "FREQ=DAILY;BYHOUR=9",     // unsupported part — must not silently drop
        "FREQ=DAILY;BYWEEKNO=20",  // unsupported part
        "FREQ=WEEKLY;BYDAY=XX",    // malformed day token
        "FREQ=MONTHLY;BYMONTHDAY=0",
        "FREQ=DAILY;INTERVAL=0",
        "FREQ=DAILY;UNTIL=tomorrow",
        "FREQ=DAILY;COUNT=0",
        "garbage",
    ])
    func rejectsMalformedOrUnsupportedRules(_ rrule: String) {
        #expect(RecurrenceRule(rruleString: rrule) == nil)
    }

    @Test func mapsWeekdayNumberingBothWays() {
        for weekday in RecurrenceRule.Weekday.allCases {
            #expect(RecurrenceRule.Weekday(foundationWeekday: weekday.foundationWeekday) == weekday)
            #expect(RecurrenceRule.Weekday(rfcToken: weekday.rfcToken) == weekday)
        }
        #expect(RecurrenceRule.Weekday.sunday.foundationWeekday == 1)
        #expect(RecurrenceRule.Weekday.monday.foundationWeekday == 2)
        #expect(RecurrenceRule.Weekday.saturday.foundationWeekday == 7)
    }

    // MARK: - Hostile input

    /// Imported values reach the parser unfiltered. `abs(Int.min)` traps, so
    /// every bound must be a range check, and none of these may crash.
    @Test(arguments: [
        "FREQ=MONTHLY;BYMONTHDAY=-9223372036854775808",
        "FREQ=MONTHLY;BYDAY=-9223372036854775808MO",
        "FREQ=MONTHLY;BYDAY=MO;BYSETPOS=-9223372036854775808",
        "FREQ=DAILY;INTERVAL=9223372036854775807",
        "FREQ=DAILY;INTERVAL=10001",
        "FREQ=MONTHLY;BYMONTHDAY=32",
        "FREQ=YEARLY;BYDAY=54MO",
        "FREQ=MONTHLY;BYDAY=MO;BYSETPOS=367",
        "FREQ=DAILY;COUNT=-9223372036854775808",
    ])
    func rejectsOutOfRangeValues(rrule: String) {
        #expect(RecurrenceRule(rruleString: rrule) == nil)
    }

    @Test func acceptsBoundaryValues() {
        #expect(RecurrenceRule(rruleString: "FREQ=MONTHLY;BYMONTHDAY=-31,31") != nil)
        #expect(RecurrenceRule(rruleString: "FREQ=YEARLY;BYDAY=-53MO,53FR") != nil)
        #expect(RecurrenceRule(rruleString: "FREQ=YEARLY;BYDAY=MO;BYSETPOS=-366,366") != nil)
        #expect(RecurrenceRule(rruleString: "FREQ=DAILY;INTERVAL=\(RecurrenceRule.maximumInterval)") != nil)
    }

    /// RFC 5545 forbids these; accepting them would expand them silently
    /// wrong (ordinals ignored, BYMONTHDAY dropped).
    @Test(arguments: [
        "FREQ=DAILY;BYDAY=1MO",
        "FREQ=WEEKLY;BYDAY=2TU",
        "FREQ=WEEKLY;BYMONTHDAY=1",
    ])
    func rejectsForbiddenCombinations(rrule: String) {
        #expect(RecurrenceRule(rruleString: rrule) == nil)
    }
}
