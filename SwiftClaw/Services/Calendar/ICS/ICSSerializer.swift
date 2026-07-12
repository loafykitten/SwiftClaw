import Foundation

/// Minimal RFC 5545 writer for the VEVENT subset SwiftClaw exports:
/// UID/DTSTAMP/DTSTART/DTEND/SUMMARY/LOCATION/DESCRIPTION/URL/RRULE/EXDATE/
/// VALARM, with text escaping and 75-octet line folding. Also writes the
/// VTODO subset (`serialize(todos:)`): DUE/STATUS/COMPLETED/PRIORITY/RRULE
/// plus SwiftClaw's X- properties for flags, checklists, and
/// after-completion repeats.
///
/// Date policy: all-day events use VALUE=DATE (exclusive DTEND per spec);
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
            // All-day starts are floating local dates (stored as local
            // midnight instants). Format them in the local calendar — a UTC
            // read would shift the date in positive-offset zones (Tokyo's
            // July 10 midnight is July 9 UTC).
            let calendar = ICSDateFormat.calendar(for: TimeZone.current.identifier)
            lines.append("DTSTART;VALUE=DATE:\(ICSDateFormat.dateOnlyString(from: event.start, calendar: calendar))")
            // DTEND for VALUE=DATE is exclusive: the morning after the last day.
            let exclusiveEnd = max(
                event.end,
                calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: event.start)) ?? event.end
            )
            lines.append("DTEND;VALUE=DATE:\(ICSDateFormat.dateOnlyString(from: exclusiveEnd, calendar: calendar))")
        } else if event.rruleString != nil, let zone = event.timeZoneIdentifier {
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
            lines.append("RRULE:\(rrule)")
        }
        for exception in event.exceptionDates {
            if event.isAllDay {
                // RFC 5545 requires EXDATE to match DTSTART's value type, so
                // an all-day series excludes whole dates (same local calendar
                // as DTSTART above).
                let calendar = ICSDateFormat.calendar(for: TimeZone.current.identifier)
                lines.append("EXDATE;VALUE=DATE:\(ICSDateFormat.dateOnlyString(from: exception, calendar: calendar))")
            } else if let zone = event.timeZoneIdentifier, event.rruleString != nil {
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
                // Date-only dues are floating local days (stored as local
                // midnight instants) — format them in the local calendar,
                // same as all-day DTSTART.
                let calendar = ICSDateFormat.calendar(for: TimeZone.current.identifier)
                lines.append("DUE;VALUE=DATE:\(ICSDateFormat.dateOnlyString(from: due, calendar: calendar))")
            } else if todo.rruleString != nil, let zone = todo.timeZoneIdentifier {
                // Repeating timed to-dos keep their zone so wall-clock
                // semantics survive DST, matching the VEVENT policy.
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
            lines.append("RRULE:\(rrule)")
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
            // DATE values are floating; resolve in the caller's zone choice.
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

        let fields: Set<Calendar.Component> = isDateOnly || characters.count == 8
            ? [.year, .month, .day]
            : [.year, .month, .day, .hour, .minute, .second]
        let resolved = calendar.dateComponents(fields, from: date)
        for field in fields where resolved.value(for: field) != components.value(for: field) {
            return nil
        }
        return date
    }
}
