import Foundation

/// Typed representation of the RFC 5545 RRULE subset SwiftClaw supports:
/// FREQ, INTERVAL, BYDAY (with ordinals), BYMONTHDAY, BYMONTH, BYSETPOS,
/// UNTIL, COUNT, WKST. This covers everything Apple Calendar's UI can create
/// (`EKRecurrenceRule` maps 1:1 onto it) plus the common .ics cases; parsing
/// rejects rules that use parts outside the subset so the importer can degrade
/// them explicitly instead of expanding them wrong.
nonisolated struct RecurrenceRule: Codable, Sendable, Hashable {
    enum Frequency: String, Codable, Sendable, CaseIterable {
        case daily = "DAILY"
        case weekly = "WEEKLY"
        case monthly = "MONTHLY"
        case yearly = "YEARLY"
    }

    /// ISO weekday (1 = Monday … 7 = Sunday), matching RFC 5545 day tokens.
    enum Weekday: Int, Codable, Sendable, CaseIterable, Comparable {
        case monday = 1, tuesday, wednesday, thursday, friday, saturday, sunday

        var rfcToken: String {
            switch self {
            case .monday: "MO"
            case .tuesday: "TU"
            case .wednesday: "WE"
            case .thursday: "TH"
            case .friday: "FR"
            case .saturday: "SA"
            case .sunday: "SU"
            }
        }

        init?(rfcToken: String) {
            switch rfcToken {
            case "MO": self = .monday
            case "TU": self = .tuesday
            case "WE": self = .wednesday
            case "TH": self = .thursday
            case "FR": self = .friday
            case "SA": self = .saturday
            case "SU": self = .sunday
            default: return nil
            }
        }

        /// Foundation `DateComponents.weekday` numbering (1 = Sunday … 7 = Saturday).
        var foundationWeekday: Int {
            self == .sunday ? 1 : rawValue + 1
        }

        init?(foundationWeekday: Int) {
            switch foundationWeekday {
            case 1: self = .sunday
            case 2...7: self.init(rawValue: foundationWeekday - 1)
            default: return nil
            }
        }

        static func < (lhs: Weekday, rhs: Weekday) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// A BYDAY entry: a weekday with an optional ordinal within the period
    /// ("3TU" = third Tuesday, "-1FR" = last Friday). Ordinals only apply to
    /// monthly/yearly frequencies.
    struct DayOfWeek: Codable, Sendable, Hashable {
        var weekday: Weekday
        var ordinal: Int?

        init(_ weekday: Weekday, ordinal: Int? = nil) {
            self.weekday = weekday
            self.ordinal = ordinal
        }

        var rfcToken: String {
            if let ordinal { "\(ordinal)\(weekday.rfcToken)" }
            else { weekday.rfcToken }
        }

        init?(rfcToken: String) {
            let dayPart = String(rfcToken.suffix(2))
            guard let weekday = Weekday(rfcToken: dayPart) else { return nil }
            let ordinalPart = rfcToken.dropLast(2)
            if ordinalPart.isEmpty {
                self.init(weekday)
            } else if let ordinal = Int(ordinalPart), ordinal != 0, (-53...53).contains(ordinal) {
                // Range check, never `abs`: `abs(Int.min)` traps.
                self.init(weekday, ordinal: ordinal)
            } else {
                return nil
            }
        }
    }

    enum End: Codable, Sendable, Hashable {
        /// Inclusive last possible occurrence instant (RRULE UNTIL, always UTC).
        case untilDate(Date)
        /// Total number of occurrences counted from the event start (RRULE COUNT).
        case occurrenceCount(Int)
    }

    /// Largest INTERVAL the parser accepts. RFC 5545 sets no bound, but
    /// nothing real needs more, and the cap keeps period arithmetic far from
    /// overflow (the expander also multiplies with overflow checks).
    static let maximumInterval = 10_000

    var frequency: Frequency
    var interval: Int
    var daysOfWeek: [DayOfWeek]
    var daysOfMonth: [Int]
    var monthsOfYear: [Int]
    var setPositions: [Int]
    var end: End?
    var weekStart: Weekday

    init(
        frequency: Frequency,
        interval: Int = 1,
        daysOfWeek: [DayOfWeek] = [],
        daysOfMonth: [Int] = [],
        monthsOfYear: [Int] = [],
        setPositions: [Int] = [],
        end: End? = nil,
        weekStart: Weekday = .monday
    ) {
        self.frequency = frequency
        self.interval = max(1, interval)
        self.daysOfWeek = daysOfWeek
        self.daysOfMonth = daysOfMonth
        self.monthsOfYear = monthsOfYear
        self.setPositions = setPositions
        self.end = end
        self.weekStart = weekStart
    }

    // MARK: - Presets

    static let daily = RecurrenceRule(frequency: .daily)
    static let weekdays = RecurrenceRule(
        frequency: .weekly,
        daysOfWeek: [.init(.monday), .init(.tuesday), .init(.wednesday), .init(.thursday), .init(.friday)]
    )
    static let weekly = RecurrenceRule(frequency: .weekly)
    static let biweekly = RecurrenceRule(frequency: .weekly, interval: 2)
    static let monthly = RecurrenceRule(frequency: .monthly)
    static let yearly = RecurrenceRule(frequency: .yearly)

    // MARK: - RRULE serialization

    /// The RFC 5545 RRULE value (without the "RRULE:" property name), parts in
    /// canonical order so equal rules serialize identically.
    var rruleString: String {
        var parts = ["FREQ=\(frequency.rawValue)"]
        if interval != 1 {
            parts.append("INTERVAL=\(interval)")
        }
        if !daysOfWeek.isEmpty {
            parts.append("BYDAY=\(daysOfWeek.map(\.rfcToken).joined(separator: ","))")
        }
        if !daysOfMonth.isEmpty {
            parts.append("BYMONTHDAY=\(daysOfMonth.map(String.init).joined(separator: ","))")
        }
        if !monthsOfYear.isEmpty {
            parts.append("BYMONTH=\(monthsOfYear.map(String.init).joined(separator: ","))")
        }
        if !setPositions.isEmpty {
            parts.append("BYSETPOS=\(setPositions.map(String.init).joined(separator: ","))")
        }
        switch end {
        case .untilDate(let date):
            parts.append("UNTIL=\(Self.untilString(from: date))")
        case .occurrenceCount(let count):
            parts.append("COUNT=\(count)")
        case nil:
            break
        }
        if weekStart != .monday {
            parts.append("WKST=\(weekStart.rfcToken)")
        }
        return parts.joined(separator: ";")
    }

    /// Parses an RRULE value. Returns nil for malformed input or for rules
    /// using parts outside the supported subset (BYHOUR, BYWEEKNO, …) — the
    /// caller decides whether to degrade or reject, but never silently
    /// misexpands.
    init?(rruleString: String) {
        var frequency: Frequency?
        var interval = 1
        var daysOfWeek: [DayOfWeek] = []
        var daysOfMonth: [Int] = []
        var monthsOfYear: [Int] = []
        var setPositions: [Int] = []
        var end: End?
        var weekStart = Weekday.monday

        for part in rruleString.split(separator: ";") {
            let keyValue = part.split(separator: "=", maxSplits: 1)
            guard keyValue.count == 2 else { return nil }
            let key = keyValue[0].uppercased()
            let value = String(keyValue[1])

            switch key {
            case "FREQ":
                guard let parsed = Frequency(rawValue: value.uppercased()) else { return nil }
                frequency = parsed
            case "INTERVAL":
                guard let parsed = Int(value), (1...Self.maximumInterval).contains(parsed) else { return nil }
                interval = parsed
            case "BYDAY":
                for token in value.split(separator: ",") {
                    guard let day = DayOfWeek(rfcToken: String(token).uppercased()) else { return nil }
                    daysOfWeek.append(day)
                }
            case "BYMONTHDAY":
                for token in value.split(separator: ",") {
                    // Range checks, never `abs`: `abs(Int.min)` traps.
                    guard let day = Int(token), day != 0, (-31...31).contains(day) else { return nil }
                    daysOfMonth.append(day)
                }
            case "BYMONTH":
                for token in value.split(separator: ",") {
                    guard let month = Int(token), (1...12).contains(month) else { return nil }
                    monthsOfYear.append(month)
                }
            case "BYSETPOS":
                for token in value.split(separator: ",") {
                    guard let position = Int(token), position != 0, (-366...366).contains(position) else {
                        return nil
                    }
                    setPositions.append(position)
                }
            case "UNTIL":
                guard let date = Self.parseUntil(value) else { return nil }
                end = .untilDate(date)
            case "COUNT":
                guard let count = Int(value), count >= 1 else { return nil }
                end = .occurrenceCount(count)
            case "WKST":
                guard let day = Weekday(rfcToken: value.uppercased()) else { return nil }
                weekStart = day
            default:
                // Unsupported part (BYHOUR, BYYEARDAY, BYWEEKNO, RSCALE, …).
                return nil
            }
        }

        guard let frequency else { return nil }
        // Combinations RFC 5545 forbids, which the expander would otherwise
        // silently misexpand: BYDAY ordinals outside MONTHLY/YEARLY, and
        // BYMONTHDAY with WEEKLY.
        if frequency == .daily || frequency == .weekly,
           daysOfWeek.contains(where: { $0.ordinal != nil }) {
            return nil
        }
        if frequency == .weekly, !daysOfMonth.isEmpty {
            return nil
        }
        self.init(
            frequency: frequency,
            interval: interval,
            daysOfWeek: daysOfWeek,
            daysOfMonth: daysOfMonth,
            monthsOfYear: monthsOfYear,
            setPositions: setPositions,
            end: end,
            weekStart: weekStart
        )
    }

    // MARK: - UNTIL parsing/formatting

    /// Fixed UTC Gregorian calendar. `Calendar` is a Sendable value type, so
    /// this is safe as a static under strict concurrency (`DateFormatter`
    /// would not be).
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    /// RFC 5545 UNTIL is either a UTC DATE-TIME ("20261231T235959Z") or, for
    /// all-day recurrences, a DATE ("20261231", treated as end of that UTC day
    /// so the last day is included).
    private static func parseUntil(_ value: String) -> Date? {
        var components = DateComponents()
        func digits(_ range: Range<Int>) -> Int? {
            let characters = Array(value)
            guard range.upperBound <= characters.count else { return nil }
            return Int(String(characters[range.lowerBound..<range.upperBound]))
        }
        guard let year = digits(0..<4), let month = digits(4..<6), let day = digits(6..<8) else {
            return nil
        }
        components.year = year
        components.month = month
        components.day = day

        switch value.count {
        case 8:
            components.hour = 23
            components.minute = 59
            components.second = 59
        case 16 where Array(value)[8] == "T" && value.hasSuffix("Z"):
            guard let hour = digits(9..<11), let minute = digits(11..<13), let second = digits(13..<15) else {
                return nil
            }
            components.hour = hour
            components.minute = minute
            components.second = second
        default:
            return nil
        }

        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        return utcCalendar.date(from: components)
    }

    private static func untilString(from date: Date) -> String {
        let parts = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d%02d%02dT%02d%02d%02dZ",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
    }
}
