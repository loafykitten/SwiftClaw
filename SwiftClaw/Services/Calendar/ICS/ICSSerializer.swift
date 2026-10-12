import Foundation

/// Minimal RFC 5545 writer for the VEVENT subset SwiftClaw exports:
/// UID/DTSTAMP/DTSTART/DTEND/SUMMARY/LOCATION/DESCRIPTION/URL/RRULE/EXDATE/
/// VALARM, with text escaping and 75-octet line folding. Also writes the
/// VTODO subset (`serialize(todos:)`): DUE/STATUS/COMPLETED/PRIORITY/RRULE
/// plus SwiftClaw's X- properties for flags, checklists, and
/// after-completion repeats.
///
/// Date policy: all-day events (and date-only to-dos) use VALUE=DATE written
/// from their canonical civil dates (exclusive DTEND per spec, DATE UNTIL);
/// non-recurring timed events serialize as UTC instants ("...Z" — universally
/// portable); recurring timed events keep their zone via TZID so wall-clock
/// semantics survive DST. No VTIMEZONE component is emitted — every major
/// client resolves Olson TZIDs without one, and generating VTIMEZONE rules is
/// where hand-rolled serializers go to die.
nonisolated enum ICSSerializer {
    static func serialize(_ events: [ICSEventRepresentation], calendarName: String? = nil) -> String {
        var lines: [String] = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//SwiftClaw//Calendar//EN",
            "CALSCALE:GREGORIAN",
        ]
        if let calendarName, !calendarName.isEmpty {
            lines.append("X-WR-CALNAME:\(escapeText(calendarName))")
        }
        for event in events {
            lines.append(contentsOf: serializeEvent(event))
        }
        lines.append("END:VCALENDAR")
        return lines.map(fold).joined(separator: "\r\n") + "\r\n"
    }

    static func serialize(todos: [ICSTodoRepresentation], listName: String? = nil) -> String {
        var lines: [String] = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//SwiftClaw//Reminders//EN",
            "CALSCALE:GREGORIAN",
        ]
        if let listName, !listName.isEmpty {
            lines.append("X-WR-CALNAME:\(escapeText(listName))")
        }
        for todo in todos {
            lines.append(contentsOf: serializeTodo(todo))
        }
        lines.append("END:VCALENDAR")
        return lines.map(fold).joined(separator: "\r\n") + "\r\n"
    }

    private static func serializeEvent(_ event: ICSEventRepresentation) -> [String] {
        var lines = ["BEGIN:VEVENT"]
        lines.append("UID:\(event.uid)")
        lines.append("DTSTAMP:\(ICSDateFormat.utcString(from: .now))")

        if event.isAllDay {
            // All-day values are canonical civil dates (`CivilDay`, midnight
            // UTC), so they format in the canonical calendar and write the
            // same dates whatever zone the exporting device is in.
            let calendar = CivilDay.canonicalCalendar
            lines.append("DTSTART;VALUE=DATE:\(ICSDateFormat.dateOnlyString(from: event.start, calendar: calendar))")
            // DTEND for VALUE=DATE is exclusive: the day after the last day.
            let firstDay = CivilDay(canonical: event.start)
            let exclusiveEnd = max(CivilDay(canonical: event.end), firstDay.adding(days: 1))
            lines.append("DTEND;VALUE=DATE:\(ICSDateFormat.dateOnlyString(from: exclusiveEnd.canonicalDate, calendar: calendar))")
        } else if event.rruleString != nil, let zone = event.timeZoneIdentifier, !ICSDateFormat.isUTC(zone) {
            let calendar = ICSDateFormat.calendar(for: zone)
            lines.append("DTSTART;TZID=\(zone):\(ICSDateFormat.localString(from: event.start, calendar: calendar))")
            lines.append("DTEND;TZID=\(zone):\(ICSDateFormat.localString(from: event.end, calendar: calendar))")
        } else {
            lines.append("DTSTART:\(ICSDateFormat.utcString(from: event.start))")
            lines.append("DTEND:\(ICSDateFormat.utcString(from: event.end))")
        }

        lines.append("SUMMARY:\(escapeText(event.title))")
        if let location = event.location, !location.isEmpty {
            lines.append("LOCATION:\(escapeText(location))")
        }
        if let notes = event.notes, !notes.isEmpty {
            lines.append("DESCRIPTION:\(escapeText(notes))")
        }
        if let urlString = event.urlString, !urlString.isEmpty {
            lines.append("URL:\(urlString)")
        }
        if let rrule = event.rruleString {
            lines.append("RRULE:\(event.isAllDay ? Self.dateOnlyRRule(rrule) : rrule)")
        }
        for exception in event.exceptionDates {
            if event.isAllDay {
                // RFC 5545 requires EXDATE to match DTSTART's value type, so
                // an all-day series excludes whole dates (canonical calendar,
                // as DTSTART above).
                let calendar = CivilDay.canonicalCalendar
                lines.append("EXDATE;VALUE=DATE:\(ICSDateFormat.dateOnlyString(from: exception, calendar: calendar))")
            } else if let zone = event.timeZoneIdentifier, event.rruleString != nil, !ICSDateFormat.isUTC(zone) {
                let calendar = ICSDateFormat.calendar(for: zone)
                lines.append("EXDATE;TZID=\(zone):\(ICSDateFormat.localString(from: exception, calendar: calendar))")
            } else {
                lines.append("EXDATE:\(ICSDateFormat.utcString(from: exception))")
            }
        }
        for offset in event.alarmOffsets {
            lines.append("BEGIN:VALARM")
            lines.append("ACTION:DISPLAY")
            lines.append("DESCRIPTION:Reminder")
            lines.append("TRIGGER:\(durationString(from: offset))")
            lines.append("END:VALARM")
        }
        lines.append("END:VEVENT")
        return lines
    }

    // MARK: - VTODO

    private static func serializeTodo(_ todo: ICSTodoRepresentation) -> [String] {
        var lines = ["BEGIN:VTODO"]
        lines.append("UID:\(todo.uid)")
        lines.append("DTSTAMP:\(ICSDateFormat.utcString(from: .now))")

        if let due = todo.due {
            if todo.isDateOnly {
                // Date-only dues are canonical civil dates, same as all-day
                // DTSTART.
                let calendar = CivilDay.canonicalCalendar
                lines.append("DUE;VALUE=DATE:\(ICSDateFormat.dateOnlyString(from: due, calendar: calendar))")
            } else if todo.rruleString != nil || todo.afterCompletionRepeat != nil,
                      let zone = todo.timeZoneIdentifier, !ICSDateFormat.isUTC(zone) {
                // Repeating timed to-dos keep their zone so wall-clock
                // semantics survive DST, matching the VEVENT policy —
                // after-completion repeats do zone-sensitive month/DST math
                // too, so they need the TZID as much as RRULEs do.
                let calendar = ICSDateFormat.calendar(for: zone)
                lines.append("DUE;TZID=\(zone):\(ICSDateFormat.localString(from: due, calendar: calendar))")
            } else {
                lines.append("DUE:\(ICSDateFormat.utcString(from: due))")
            }
        }

        lines.append("SUMMARY:\(escapeText(todo.title))")
        if let notes = todo.notes, !notes.isEmpty {
            lines.append("DESCRIPTION:\(escapeText(notes))")
        }
        if let urlString = todo.urlString, !urlString.isEmpty {
            lines.append("URL:\(urlString)")
        }
        if todo.priority != 0 {
            lines.append("PRIORITY:\(todo.priority)")
        }
        if todo.isCompleted || todo.completedAt != nil {
            lines.append("STATUS:COMPLETED")
            lines.append("COMPLETED:\(ICSDateFormat.utcString(from: todo.completedAt ?? .now))")
        } else {
            lines.append("STATUS:NEEDS-ACTION")
        }
        if let rrule = todo.rruleString {
            lines.append("RRULE:\(todo.isDateOnly ? Self.dateOnlyRRule(rrule) : rrule)")
        } else if let repeatAfter = todo.afterCompletionRepeat {
            lines.append("X-SWIFTCLAW-REPEAT-AFTER:\(repeatAfter.count) \(repeatAfter.unit.rawValue)")
        }
        if todo.isFlagged {
            lines.append("X-SWIFTCLAW-FLAGGED:TRUE")
        }
        for item in todo.checklist {
            lines.append("X-SWIFTCLAW-CHECKLIST;ID=\(item.id.uuidString);DONE=\(item.isDone ? "TRUE" : "FALSE"):\(escapeText(item.text))")
        }
        lines.append("END:VTODO")
        return lines
    }

    // MARK: - Primitives

    /// An all-day / date-only RRULE with UNTIL as a DATE, matching the
    /// VALUE=DATE start (RFC 5545 §3.3.10). Rules outside our subset pass
    /// through verbatim.
    static func dateOnlyRRule(_ rrule: String) -> String {
        guard let rule = RecurrenceRule(rruleString: rrule), case .untilDate = rule.end else { return rrule }
        return rule.dateOnlyRRuleString
    }

    /// RFC 5545 §3.3.11 TEXT escaping.
    static func escapeText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// ISO 8601 duration for a trigger offset ("-PT15M", "PT0S").
    static func durationString(from offset: TimeInterval) -> String {
        let sign = offset < 0 ? "-" : ""
        var seconds = Int(abs(offset).rounded())
        let days = seconds / 86400
        seconds %= 86400
        let hours = seconds / 3600
        seconds %= 3600
        let minutes = seconds / 60
        seconds %= 60

        var body = "P"
        if days > 0 { body += "\(days)D" }
        var time = ""
        if hours > 0 { time += "\(hours)H" }
        if minutes > 0 { time += "\(minutes)M" }
        if seconds > 0 { time += "\(seconds)S" }
        if time.isEmpty && days == 0 { time = "0S" }
        if !time.isEmpty { body += "T\(time)" }
        return sign + body
    }

    /// Folds a content line at 75 octets (UTF-8), continuing with CRLF+space.
    static func fold(_ line: String) -> String {
        let limit = 75
        guard line.utf8.count > limit else { return line }
        var segments: [String] = []
        var current = ""
        var currentOctets = 0
        // First segment gets the full 75; continuations lose one octet to the
        // leading space.
        var segmentLimit = limit
        for character in line {
            let octets = String(character).utf8.count
            if currentOctets + octets > segmentLimit {
                segments.append(current)
                current = ""
                currentOctets = 0
                segmentLimit = limit - 1
            }
            current.append(character)
            currentOctets += octets
        }
        if !current.isEmpty { segments.append(current) }
        return segments.joined(separator: "\r\n ")
    }
}

/// Fixed-format .ics date parsing/formatting (no `DateFormatter` — not
/// Sendable and overkill for fixed-width numerics).
nonisolated enum ICSDateFormat {
    static func calendar(for timeZoneIdentifier: String?) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZoneIdentifier.flatMap(TimeZone.init(identifier:))
            ?? TimeZone(identifier: "UTC")
            ?? .gmt
        return calendar
    }

    /// UTC zones serialize in the portable "…Z" form rather than as a TZID
    /// (the parser maps a repeating "…Z" start back to UTC).
    static func isUTC(_ timeZoneIdentifier: String) -> Bool {
        ["UTC", "GMT", "Etc/UTC", "Etc/GMT"].contains(timeZoneIdentifier)
    }

    static func utcString(from date: Date) -> String {
        let parts = calendar(for: nil).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d%02d%02dT%02d%02d%02dZ",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
    }

    static func localString(from date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d%02d%02dT%02d%02d%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
    }

    static func dateOnlyString(from date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Parses "yyyyMMdd" (DATE), "yyyyMMdd'T'HHmmss" (local in `zone`), or
    /// "yyyyMMdd'T'HHmmssZ" (UTC). Returns nil on malformed input.
    ///
    /// `isDateOnly` values (VALUE=DATE) are civil dates and come back as
    /// canonical `CivilDay` instants (midnight UTC), the store's all-day /
    /// date-only encoding; any TZID is ignored, as RFC 5545 DATE has none.
    static func parse(_ value: String, timeZoneIdentifier: String?, isDateOnly: Bool) -> Date? {
        let characters = Array(value)
        func digits(_ range: Range<Int>) -> Int? {
            guard range.upperBound <= characters.count else { return nil }
            return Int(String(characters[range.lowerBound..<range.upperBound]))
        }
        guard let year = digits(0..<4), let month = digits(4..<6), let day = digits(6..<8),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }

        var components = DateComponents(year: year, month: month, day: day)
        var zoneIdentifier = timeZoneIdentifier

        if isDateOnly || characters.count == 8 {
            components.hour = 0
            components.minute = 0
            components.second = 0
            if isDateOnly {
                zoneIdentifier = "UTC"
            }
            // A bare 8-digit value without VALUE=DATE resolves in the
            // caller's zone choice, as before.
        } else {
            guard characters.count >= 15, characters[8] == "T",
                  let hour = digits(9..<11), let minute = digits(11..<13), let second = digits(13..<15)
            else { return nil }
            components.hour = hour
            components.minute = minute
            components.second = second
            if characters.count == 16 && characters[15] == "Z" {
                zoneIdentifier = "UTC"
            } else if characters.count != 15 {
                return nil
            }
        }
        let calendar = calendar(for: zoneIdentifier ?? TimeZone.current.identifier)
        guard let date = calendar.date(from: components) else { return nil }

        // Reject impossible calendar dates (20260431 would silently roll to
        // May 1) but validate only the DATE fields: a wall-clock time inside a
        // DST spring-forward gap is legitimate in real-world files and must
        // keep normalizing to the shifted instant, not drop the component.
        // Hour overflow still fails here because it rolls the day.
        let fields: Set<Calendar.Component> = [.year, .month, .day]
        let resolved = calendar.dateComponents(fields, from: date)
        for field in fields where resolved.value(for: field) != components.value(for: field) {
            return nil
        }
        return date
    }
}
