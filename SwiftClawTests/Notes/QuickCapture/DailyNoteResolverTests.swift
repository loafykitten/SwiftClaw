import Foundation
@testable import SwiftClaw
import Testing

struct DailyNoteResolverTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }

    @Test func resolvesLocalDatePathHeadingAndTime() {
        let now = Date(timeIntervalSince1970: 1_768_442_381) // 2026-01-15 01:59 UTC / Jan 14 local
        let result = DailyNoteResolver(calendar: Self.calendar).resolve(now: now, folder: "Daily Notes")

        #expect(result.localDate == "2026-01-14")
        #expect(result.time == "19:59")
        #expect(result.relativePath == "Daily Notes/2026-01-14.md")
        #expect(result.heading == "# 2026-01-14")
        #expect(result.newNoteContent(text: "hello") == "# 2026-01-14\n\n- 19:59 hello")
    }

    @Test func appendPreservesExistingContentAndAddsOnlyRequiredSeparator() throws {
        let resolution = try DailyNoteResolver(calendar: Self.calendar).resolve(
            now: #require(Self.calendar.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 9, minute: 7))),
            folder: nil
        )

        #expect(resolution.appending(text: "next", to: "bytes") == "bytes\n- 09:07 next")
        #expect(resolution.appending(text: "next", to: "bytes\n") == "bytes\n- 09:07 next")
        #expect(resolution.appending(text: "next", to: "bytes\n\n") == "bytes\n\n- 09:07 next")
        #expect(resolution.appending(text: "next", to: "") == "\n- 09:07 next")
    }

    @Test func unsafeFolderFallsBackToVaultRoot() {
        let result = DailyNoteResolver(calendar: Self.calendar).resolve(now: .distantPast, folder: "../escape")
        #expect(!result.relativePath.contains(".."))
        #expect(!result.relativePath.contains("/"))
    }
}
