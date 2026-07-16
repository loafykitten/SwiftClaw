import Foundation
@testable import SwiftClaw
import Testing

struct NotesCaptureStatsStoreTests {
    @Test func incrementsAndRollsOverByLocalCalendarDay() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Chicago"))
        let store = NotesCaptureStatsStore(userDefaults: fixture.defaults, calendar: calendar)
        let late = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 23, minute: 59)))
        let next = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 16, hour: 0, minute: 1)))

        #expect(store.capturedCount(on: late) == 0)
        #expect(store.recordSuccessfulCapture(on: late) == 1)
        #expect(store.recordSuccessfulCapture(on: late) == 2)
        #expect(store.capturedCount(on: late) == 2)
        #expect(store.capturedCount(on: next) == 0)
        #expect(store.recordSuccessfulCapture(on: next) == 1)
        #expect(store.capturedCount(on: next) == 1)
        #expect(store.capturedCount(on: late) == 0)
    }
}
