import Foundation
@testable import SwiftClaw
import Testing

struct ReminderKitMappingTests {
    // MARK: - Due dates

    @Test func timedDueResolvesInComponentsZone() throws {
        var components = DateComponents(year: 2026, month: 7, day: 15, hour: 9, minute: 30)
        components.timeZone = TimeZone(identifier: "America/Los_Angeles")

        let resolved = ReminderKitMapping.resolvedDueDate(from: components)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        // 09:30 PDT (UTC-7 in July) == 16:30 UTC.
        let expected = utc.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 16, minute: 30))!
        #expect(resolved.date == expected)
        #expect(resolved.hasDueTime)
        #expect(resolved.timeZoneIdentifier == "America/Los_Angeles")
    }

    @Test func timedDueWithoutZoneResolvesAsLocalFloatingTime() throws {
        let components = DateComponents(year: 2026, month: 7, day: 15, hour: 9)

        let resolved = ReminderKitMapping.resolvedDueDate(from: components)
        let expected = Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 9))!
        #expect(resolved.date == expected)
        #expect(resolved.hasDueTime)
        #expect(resolved.timeZoneIdentifier == nil)
    }

    /// Date-only dues are floating local days: whatever zone the components
    /// carry, the reminder lands on that calendar day's local midnight with
    /// no stored zone (the all-day event convention).
    @Test func dateOnlyDueIsLocalStartOfDayIgnoringComponentZone() throws {
        var components = DateComponents(year: 2026, month: 7, day: 15)
        components.timeZone = TimeZone(identifier: "Asia/Tokyo")

        let resolved = ReminderKitMapping.resolvedDueDate(from: components)
        let expected = Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 15))!
        #expect(resolved.date == expected)
        #expect(!resolved.hasDueTime)
        #expect(resolved.timeZoneIdentifier == nil)
    }

    @Test func missingComponentsMeanNoDueDate() {
        #expect(ReminderKitMapping.resolvedDueDate(from: nil).date == nil)
        // A partial date (no day) can't resolve to a due date either.
        let partial = DateComponents(year: 2026, month: 7)
        let resolved = ReminderKitMapping.resolvedDueDate(from: partial)
        #expect(resolved.date == nil)
        #expect(!resolved.hasDueTime)
    }

    // MARK: - Priority

    @Test func priorityClampsToRFCScale() {
        #expect(ReminderKitMapping.clampedPriority(-3) == 0)
        #expect(ReminderKitMapping.clampedPriority(0) == 0)
        #expect(ReminderKitMapping.clampedPriority(5) == 5)
        #expect(ReminderKitMapping.clampedPriority(12) == 9)
    }
}
