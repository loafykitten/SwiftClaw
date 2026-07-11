import Foundation

/// Pure occurrence expansion for `RecurrenceRule`. All date math goes through
/// a Gregorian `Calendar` in the event's own time zone so wall-clock times
/// survive DST transitions (a 9:00 weekly standup stays at 9:00 local across
/// the change), and week/month boundaries respect the rule's WKST.
///
/// The event's start is always the first occurrence, whether or not it matches
/// the rule's BY-parts — mirroring EventKit and every mainstream client.
/// COUNT is accounted against generated instances *before* EXDATE removal
/// (the common interpretation), so deleting one occurrence doesn't grow the
/// series' tail.
nonisolated enum RecurrenceExpander {
    /// Most occurrences a single expansion returns; guards runaway rules.
    static let occurrenceCap = 1000
    /// Hard guard on period iteration (a daily rule spans ~110 years).
    private static let periodIterationCap = 40_000

    /// Occurrence starts whose interval `[start, start + duration)` intersects
    /// `window`, sorted ascending. `cap` bounds the result count; UI callers
    /// keep the default, while import reconciliation (which must enumerate a
    /// multi-year window exhaustively to recover deletions) passes a higher
    /// one — `periodIterationCap` still guards runaway rules.
    static func occurrenceStarts(
        rule: RecurrenceRule,
        eventStart: Date,
        duration: TimeInterval,
        window: DateInterval,
        exceptionDates: [Date] = [],
        timeZone: TimeZone? = nil,
        cap: Int = occurrenceCap
    ) -> [Date] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone ?? .current
        calendar.firstWeekday = rule.weekStart.foundationWeekday

        let context = ExpansionContext(
            rule: rule,
            calendar: calendar,
            eventStart: eventStart,
            duration: max(0, duration),
            window: window,
            exceptionKeys: Set(exceptionDates.map(Self.exceptionKey)),
            countLimit: {
                if case .occurrenceCount(let count) = rule.end { count } else { nil }
            }(),
            untilDate: {
                if case .untilDate(let until) = rule.end { until } else { nil }
            }(),
            cap: max(1, cap)
        )
        return expand(context)
    }

    /// Whether the occurrence starting at `date` was removed via EXDATE.
    /// Comparison is second-granular to absorb sub-second drift from
    /// serialization round-trips.
    static func isException(_ date: Date, exceptionDates: [Date]) -> Bool {
        exceptionDates.map(exceptionKey).contains(exceptionKey(date))
    }

    private static func exceptionKey(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSinceReferenceDate.rounded())
    }

    // MARK: - Core loop

    private struct ExpansionContext {
        let rule: RecurrenceRule
        let calendar: Calendar
        let eventStart: Date
        let duration: TimeInterval
        let window: DateInterval
        let exceptionKeys: Set<Int64>
        let countLimit: Int?
        let untilDate: Date?
        let cap: Int

        /// The latest instant any period can start and still matter.
        var horizon: Date {
            if let untilDate { min(untilDate, window.end) } else { window.end }
        }
    }

    private static func expand(_ context: ExpansionContext) -> [Date] {
        var results: [Date] = []
        // Instances generated so far (before EXDATE removal), for COUNT.
        var generatedCount = 0

        func emit(_ occurrence: Date) -> Bool {
            // Returns false when expansion must stop.
            if let until = context.untilDate, occurrence > until { return false }
            generatedCount += 1
            if !context.exceptionKeys.contains(exceptionKey(occurrence)) {
                let end = occurrence.addingTimeInterval(context.duration)
                if occurrence < context.window.end && end > context.window.start {
                    results.append(occurrence)
                    if results.count >= context.cap { return false }
                }
            }
            if let countLimit = context.countLimit, generatedCount >= countLimit { return false }
            return true
        }

        // The event start is always the first occurrence.
        guard emit(context.eventStart) else { return results }

        var periodIndex = firstRelevantPeriodIndex(context)
        var iterations = 0
        while iterations < periodIterationCap {
            iterations += 1
            guard let period = periodInterval(context, periodIndex: periodIndex) else { break }
            if period.start > context.horizon { break }

            var candidates = candidateStarts(context, in: period)
            if !context.rule.setPositions.isEmpty {
                candidates = applySetPositions(context.rule.setPositions, to: candidates)
            }
            for occurrence in candidates {
                // Skip anything at/before the event start: the start was
                // emitted up front, and BY-parts can generate earlier days
                // within the first period.
                guard occurrence > context.eventStart else { continue }
                guard emit(occurrence) else { return results.sorted() }
            }
            periodIndex += 1
        }
        return results.sorted()
    }

    // MARK: - Periods

    /// The `periodIndex`-th recurrence period (day/week/month/year advanced by
    /// `interval` each step) counted from the period containing the event
    /// start. Returns nil if calendar math fails (never in practice).
    private static func periodInterval(_ context: ExpansionContext, periodIndex: Int) -> DateInterval? {
        let calendar = context.calendar
        let step = context.rule.interval * periodIndex

        switch context.rule.frequency {
        case .daily:
            guard let day = calendar.date(byAdding: .day, value: step, to: context.eventStart),
                  let dayStart = calendar.dateInterval(of: .day, for: day)
            else { return nil }
            return dayStart
        case .weekly:
            guard let anchorWeek = calendar.dateInterval(of: .weekOfYear, for: context.eventStart),
                  let weekStart = calendar.date(byAdding: .day, value: 7 * step, to: anchorWeek.start),
                  let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)
            else { return nil }
            return DateInterval(start: weekStart, end: weekEnd)
        case .monthly:
            guard let anchorMonth = calendar.dateInterval(of: .month, for: context.eventStart),
                  let monthStart = calendar.date(byAdding: .month, value: step, to: anchorMonth.start),
                  let month = calendar.dateInterval(of: .month, for: monthStart)
            else { return nil }
            return month
        case .yearly:
            guard let anchorYear = calendar.dateInterval(of: .year, for: context.eventStart),
                  let yearStart = calendar.date(byAdding: .year, value: step, to: anchorYear.start),
                  let year = calendar.dateInterval(of: .year, for: yearStart)
            else { return nil }
            return year
        }
    }

    /// Skips periods that end before the window (adjusted for event duration)
    /// so expanding a years-old rule for this week's view doesn't walk every
    /// intervening period. COUNT rules can't skip — every generated instance
    /// must be accounted.
    private static func firstRelevantPeriodIndex(_ context: ExpansionContext) -> Int {
        guard context.countLimit == nil else { return 0 }
        let target = context.window.start.addingTimeInterval(-context.duration)
        guard target > context.eventStart else { return 0 }

        let calendar = context.calendar
        let interval = context.rule.interval
        let elapsed: Int?
        switch context.rule.frequency {
        case .daily:
            elapsed = calendar.dateComponents([.day], from: context.eventStart, to: target).day
        case .weekly:
            elapsed = calendar.dateComponents([.weekOfYear], from: context.eventStart, to: target).weekOfYear
        case .monthly:
            elapsed = calendar.dateComponents([.month], from: context.eventStart, to: target).month
        case .yearly:
            elapsed = calendar.dateComponents([.year], from: context.eventStart, to: target).year
        }
        guard let elapsed, elapsed > 0 else { return 0 }
        // Land two periods early: boundary effects (week grouping, negative
        // month days) are cheaper to re-scan than to reason away.
        return max(0, elapsed / interval - 2)
    }

    // MARK: - Candidates within a period

    private static func candidateStarts(_ context: ExpansionContext, in period: DateInterval) -> [Date] {
        let rule = context.rule
        let calendar = context.calendar

        var candidates: [Date]
        switch rule.frequency {
        case .daily:
            // The period is the day itself; the candidate keeps the event's
            // wall-clock time. BYDAY/BYMONTH act as filters.
            guard let start = applyTime(context, toDayContaining: period.start) else { return [] }
            candidates = [start]
            if !rule.daysOfWeek.isEmpty {
                let allowed = Set(rule.daysOfWeek.map(\.weekday))
                candidates = candidates.filter { allowed.contains(weekday(of: $0, calendar: calendar)) }
            }
        case .weekly:
            let targets = rule.daysOfWeek.isEmpty
                ? [weekday(of: context.eventStart, calendar: calendar)]
                : rule.daysOfWeek.map(\.weekday)
            let allowed = Set(targets)
            candidates = daysWithin(period, calendar: calendar)
                .filter { allowed.contains(weekday(of: $0, calendar: calendar)) }
                .compactMap { applyTime(context, toDayContaining: $0) }
        case .monthly:
            candidates = monthCandidates(context, month: period)
        case .yearly:
            let months = rule.monthsOfYear.isEmpty
                ? [calendar.component(.month, from: context.eventStart)]
                : rule.monthsOfYear
            candidates = []
            for monthNumber in months.sorted() {
                var components = calendar.dateComponents([.year], from: period.start)
                components.month = monthNumber
                components.day = 1
                guard let start = calendar.date(from: components),
                      let month = calendar.dateInterval(of: .month, for: start)
                else { continue }
                candidates.append(contentsOf: monthCandidates(context, month: month))
            }
        }

        if !rule.monthsOfYear.isEmpty && rule.frequency != .yearly {
            let allowed = Set(rule.monthsOfYear)
            candidates = candidates.filter { allowed.contains(calendar.component(.month, from: $0)) }
        }
        return candidates.sorted()
    }

    /// Expands one month's candidates: BYMONTHDAY days, BYDAY weekday matches
    /// (with per-entry ordinals), or the event start's day-of-month as the
    /// default. Months lacking the requested day (Feb 30th, a 5th Friday)
    /// contribute nothing.
    private static func monthCandidates(_ context: ExpansionContext, month: DateInterval) -> [Date] {
        let rule = context.rule
        let calendar = context.calendar
        guard let dayRange = calendar.range(of: .day, in: .month, for: month.start) else { return [] }
        let dayCount = dayRange.count

        func date(forDay day: Int) -> Date? {
            var components = calendar.dateComponents([.year, .month], from: month.start)
            components.day = day
            guard let midnight = calendar.date(from: components) else { return nil }
            return applyTime(context, toDayContaining: midnight)
        }

        if !rule.daysOfMonth.isEmpty {
            var days = rule.daysOfMonth.compactMap { requested -> Date? in
                let day = requested > 0 ? requested : dayCount + requested + 1
                guard (1...dayCount).contains(day) else { return nil }
                return date(forDay: day)
            }
            // RFC 5545: with BYMONTHDAY present, BYDAY *limits* the expanded
            // set ("FREQ=MONTHLY;BYMONTHDAY=1,2,3,4,5,6,7;BYDAY=MO" = first
            // Monday). Numeric BYDAY ordinals are invalid alongside
            // BYMONTHDAY, so only the weekday matters here.
            if !rule.daysOfWeek.isEmpty {
                let allowed = Set(rule.daysOfWeek.map(\.weekday))
                days = days.filter { allowed.contains(weekday(of: $0, calendar: calendar)) }
            }
            return days
        }

        if !rule.daysOfWeek.isEmpty {
            let allDays = (1...dayCount).compactMap(date(forDay:))
            var selected: [Date] = []
            for entry in rule.daysOfWeek {
                let matches = allDays.filter { weekday(of: $0, calendar: calendar) == entry.weekday }
                if let ordinal = entry.ordinal {
                    let index = ordinal > 0 ? ordinal - 1 : matches.count + ordinal
                    if matches.indices.contains(index) {
                        selected.append(matches[index])
                    }
                } else {
                    selected.append(contentsOf: matches)
                }
            }
            return selected
        }

        let defaultDay = calendar.component(.day, from: context.eventStart)
        guard defaultDay <= dayCount else { return [] }
        return [date(forDay: defaultDay)].compactMap(\.self)
    }

    // MARK: - Helpers

    /// BYSETPOS selects 1-based positions (negative = from the end) from the
    /// period's sorted candidate set.
    private static func applySetPositions(_ positions: [Int], to candidates: [Date]) -> [Date] {
        let sorted = candidates.sorted()
        var selected: [Date] = []
        for position in positions {
            let index = position > 0 ? position - 1 : sorted.count + position
            if sorted.indices.contains(index) {
                selected.append(sorted[index])
            }
        }
        return selected.sorted()
    }

    /// The event's wall-clock time applied to the day containing `day`.
    /// `Calendar` resolves DST gaps (a 02:30 start on spring-forward day maps
    /// to the next valid instant).
    private static func applyTime(_ context: ExpansionContext, toDayContaining day: Date) -> Date? {
        let calendar = context.calendar
        let time = calendar.dateComponents([.hour, .minute, .second], from: context.eventStart)
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = time.hour
        components.minute = time.minute
        components.second = time.second
        return calendar.date(from: components)
    }

    private static func weekday(of date: Date, calendar: Calendar) -> RecurrenceRule.Weekday {
        RecurrenceRule.Weekday(foundationWeekday: calendar.component(.weekday, from: date)) ?? .monday
    }

    private static func daysWithin(_ interval: DateInterval, calendar: Calendar) -> [Date] {
        var days: [Date] = []
        var cursor = interval.start
        while cursor < interval.end {
            days.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return days
    }
}
