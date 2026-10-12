import Foundation

/// A calendar date with no time of day and no zone ("July 10"): the days of
/// an all-day event and the due day of a date-only reminder.
///
/// **Storage rule.** Persisted `Date` fields hold a civil day as its
/// *canonical instant*: midnight UTC of that day in the Gregorian calendar
/// (`canonicalDate`). The instant is an encoding, not a moment. Convert it at
/// the boundary (display, occurrence expansion, alert fire dates,
/// import/export, editors, review payloads) with `startDate(in:)` and
/// `init(containing:in:)`, so the day reads as the same date in every zone.
/// A local-midnight instant would instead slide to the previous or next day
/// once the device changes zone.
///
/// GMT has no DST, so canonical day arithmetic is exact: a day is always
/// 86,400 s, and recurrence expansion in `canonicalTimeZone` steps by whole
/// civil days, months, and years.
nonisolated struct CivilDay: Hashable, Comparable, Sendable, Codable {
    var year: Int
    var month: Int
    var day: Int

    /// Stamped into `dateEncodingVersion` on calendar and reminder rows whose
    /// all-day / date-only values use the canonical encoding. Nil marks a
    /// legacy row that still stores local-midnight instants; the startup
    /// migration converts those once.
    static let encodingVersion = 1

    /// Gregorian in GMT: the calendar canonical instants are read and built in.
    static let canonicalCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    static var canonicalTimeZone: TimeZone {
        canonicalCalendar.timeZone
    }

    /// The most a day's canonical instant can sit from that day's local
    /// midnight in any zone (UTC−12…UTC+14), rounded up to a whole day. Store
    /// predicates over columns that mix timed instants and civil days widen
    /// their bounds by this, then filter exactly on the converted values.
    static let storagePadding: TimeInterval = 24 * 3600

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The day `date` falls on in `calendar`'s zone. Only the zone is taken
    /// from `calendar`: civil days are always Gregorian, even when the user's
    /// calendar is Buddhist, Japanese, or Hebrew.
    init(containing date: Date, in calendar: Calendar = .current) {
        let parts = Self.gregorian(in: calendar).dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    /// A Gregorian calendar in `calendar`'s zone.
    static func gregorian(in calendar: Calendar) -> Calendar {
        guard calendar.identifier != .gregorian else { return calendar }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return gregorian
    }

    /// Decodes a stored canonical instant.
    init(canonical date: Date) {
        self.init(containing: date, in: Self.canonicalCalendar)
    }

    /// Parses the leading "yyyy-MM-dd" of an ISO 8601 string, rejecting
    /// impossible dates (Calendar would roll "2026-02-30" into March).
    init?(isoDatePrefix string: String) {
        let parts = string.prefix(10).split(separator: "-")
        guard parts.count == 3, parts[0].count == 4,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        let candidate = CivilDay(year: year, month: month, day: day)
        guard CivilDay(canonical: candidate.canonicalDate) == candidate else { return nil }
        self = candidate
    }

    /// Midnight UTC of this day: the stored encoding.
    var canonicalDate: Date {
        Self.canonicalCalendar.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
    }

    /// The last second of this day in canonical space: the inclusive UNTIL
    /// of an all-day or date-only series ending on this day.
    var canonicalEndOfDay: Date {
        adding(days: 1).canonicalDate.addingTimeInterval(-1)
    }

    /// The first instant of this day in `calendar`'s zone. That is local
    /// midnight, or the first valid moment where a DST jump skips midnight.
    func startDate(in calendar: Calendar = .current) -> Date {
        // Resolve noon (never inside a DST gap), then take its start of day.
        let calendar = Self.gregorian(in: calendar)
        let noon = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
        return noon.map(calendar.startOfDay(for:)) ?? canonicalDate
    }

    func adding(days: Int) -> CivilDay {
        CivilDay(canonical: canonicalDate.addingTimeInterval(TimeInterval(days) * 86400))
    }

    /// Calendar-component arithmetic (months clamp to month end, the way
    /// `Calendar` does) in canonical space, so DST never applies.
    func adding(_ component: Calendar.Component, value: Int) -> CivilDay {
        Self.canonicalCalendar.date(byAdding: component, value: value, to: canonicalDate)
            .map(CivilDay.init(canonical:)) ?? self
    }

    /// Whole days from this day to `other` (negative when `other` is earlier).
    func days(until other: CivilDay) -> Int {
        Int((other.canonicalDate.timeIntervalSince(canonicalDate) / 86400).rounded())
    }

    /// The wall-clock moment `offsetSeconds` from this day's start in
    /// `calendar`, split into whole days plus a time of day. "15 hours before"
    /// (the day before at 9:00) stays 9:00 local even across a DST change,
    /// and follows the device into a new zone.
    func wallClockDate(offsetSeconds: TimeInterval, in calendar: Calendar = .current) -> Date {
        // An absurd imported trigger (beyond ~a century, or non-finite) can't
        // be split into whole days safely; elapsed seconds put it far out of
        // any scheduling window instead of trapping.
        guard offsetSeconds.isFinite else { return .distantFuture }
        guard abs(offsetSeconds) < 100 * 366 * 86400 else {
            return startDate(in: calendar).addingTimeInterval(offsetSeconds)
        }
        let calendar = Self.gregorian(in: calendar)
        let dayOffset = Int((offsetSeconds / 86400).rounded(.down))
        let secondsIntoDay = Int((offsetSeconds - TimeInterval(dayOffset) * 86400).rounded())
        let target = adding(days: dayOffset)
        let components = DateComponents(
            year: target.year,
            month: target.month,
            day: target.day,
            hour: secondsIntoDay / 3600,
            minute: secondsIntoDay % 3600 / 60,
            second: secondsIntoDay % 60
        )
        return calendar.date(from: components)
            ?? target.startDate(in: calendar).addingTimeInterval(TimeInterval(secondsIntoDay))
    }

    /// "yyyy-MM-dd", the zone-free form review payloads hand the model.
    var isoString: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func < (lhs: CivilDay, rhs: CivilDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    // MARK: - Boundary conversions

    /// Local start, in `calendar`, of the day a stored canonical instant encodes.
    static func localStart(ofCanonical canonical: Date, in calendar: Calendar = .current) -> Date {
        CivilDay(canonical: canonical).startDate(in: calendar)
    }

    /// Canonical encoding of the day `date` falls on in `calendar`.
    static func canonicalDate(forLocal date: Date, in calendar: Calendar = .current) -> Date {
        CivilDay(containing: date, in: calendar).canonicalDate
    }

    /// The canonical window covering exactly the civil days that overlap
    /// `window` in `calendar`'s zone (an end at local midnight excludes the
    /// day it opens). All-day recurrence expands against this; callers that
    /// need the exact local overlap test each occurrence afterwards.
    static func canonicalWindow(covering window: DateInterval, in calendar: Calendar = .current) -> DateInterval {
        let first = CivilDay(containing: window.start, in: calendar)
        let last = CivilDay(containing: window.end, in: calendar)
        let endsAtMidnight = window.end == last.startDate(in: calendar) && window.end > window.start
        let exclusiveEnd = endsAtMidnight ? last : last.adding(days: 1)
        return DateInterval(start: first.canonicalDate, end: max(first.canonicalDate, exclusiveEnd.canonicalDate))
    }
}

// MARK: - Civil UNTIL

extension RecurrenceRule {
    /// For an all-day or date-only series: UNTIL moved to the end of the
    /// civil day it falls on in `calendar` (the editor's or importer's
    /// zone), expressed in canonical space.
    nonisolated func civilizingUntil(readingIn calendar: Calendar = .current) -> RecurrenceRule {
        guard case .untilDate(let until) = end else { return self }
        var rule = self
        rule.end = .untilDate(CivilDay(containing: until, in: calendar).canonicalEndOfDay)
        return rule
    }

    /// The reverse, for editors working in local time: a canonical UNTIL
    /// becomes the end of the same civil day in `calendar`.
    nonisolated func localizingCivilUntil(to calendar: Calendar = .current) -> RecurrenceRule {
        guard case .untilDate(let until) = end else { return self }
        var rule = self
        let day = CivilDay(canonical: until)
        rule.end = .untilDate(day.adding(days: 1).startDate(in: calendar).addingTimeInterval(-1))
        return rule
    }

    /// RRULE text for an all-day series in `.ics` export: RFC 5545 requires
    /// UNTIL to share DTSTART's VALUE=DATE type.
    nonisolated var dateOnlyRRuleString: String {
        guard case .untilDate(let until) = end else { return rruleString }
        let day = CivilDay(canonical: until)
        let dateUntil = String(format: "UNTIL=%04d%02d%02d", day.year, day.month, day.day)
        return rruleString
            .split(separator: ";")
            .map { $0.hasPrefix("UNTIL=") ? dateUntil : String($0) }
            .joined(separator: ";")
    }

    /// Canonical rule text for an imported or legacy all-day / date-only
    /// series. A DATE UNTIL ("20261231") already parses to the canonical end
    /// of that day and stays verbatim. A DATE-TIME UNTIL (non-conformant for
    /// a DATE start, but common) is read as a civil day: in UTC when it sits
    /// exactly on a UTC day boundary ("…T000000Z", "…T235959Z", which reads
    /// the same in every zone), otherwise as a local instant in `calendar`.
    /// Unparseable rules pass through unchanged.
    nonisolated static func civilRuleString(fromImported ruleString: String, readingIn calendar: Calendar = .current) -> String {
        guard let rule = RecurrenceRule(rruleString: ruleString), case .untilDate = rule.end else {
            return ruleString
        }
        let untilValue = ruleString
            .split(separator: ";")
            .first { $0.uppercased().hasPrefix("UNTIL=") }
            .map { String($0.dropFirst("UNTIL=".count)).uppercased() }
        if untilValue?.count == 8 {
            return ruleString
        }
        let isUTCDayBoundary = untilValue.map { $0.hasSuffix("T000000Z") || $0.hasSuffix("T235959Z") } ?? false
        return rule.civilizingUntil(readingIn: isUTCDayBoundary ? CivilDay.canonicalCalendar : calendar).rruleString
    }
}
