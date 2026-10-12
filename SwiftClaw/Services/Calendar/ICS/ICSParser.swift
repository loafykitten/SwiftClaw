import Foundation

/// Tolerant RFC 5545 reader: unfolds lines, walks components, extracts the
/// VEVENT subset (`parse`) or VTODO subset (`parseTodos`) SwiftClaw supports,
/// and skips everything it doesn't recognize (VTIMEZONE, X- properties,
/// unknown params) rather than failing — real-world .ics from Google/Outlook
/// is full of extensions. The two walks are independent, so a mixed file
/// yields its events and its to-dos without either affecting the other.
nonisolated enum ICSParser {
    /// One NAME;PARAM=V;PARAM=V:value content line.
    struct ContentLine {
        let name: String
        let parameters: [String: String]
        let value: String
    }

    static func parse(_ text: String) -> [ICSEventRepresentation] {
        let lines = unfold(text)
        var events: [ICSEventRepresentation] = []

        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.name == "BEGIN" && line.value.uppercased() == "VEVENT" {
                let (event, nextIndex) = parseEvent(lines, from: index + 1)
                if let event {
                    events.append(event)
                }
                index = nextIndex
            } else {
                index += 1
            }
        }
        return events
    }

    static func parseTodos(_ text: String) -> [ICSTodoRepresentation] {
        let lines = unfold(text)
        var todos: [ICSTodoRepresentation] = []

        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.name == "BEGIN" && line.value.uppercased() == "VTODO" {
                let (todo, nextIndex) = parseTodo(lines, from: index + 1)
                if let todo {
                    todos.append(todo)
                }
                index = nextIndex
            } else {
                index += 1
            }
        }
        return todos
    }

    // MARK: - VEVENT

    private static func parseEvent(
        _ lines: [ContentLine],
        from startIndex: Int
    ) -> (ICSEventRepresentation?, Int) {
        var uid: String?
        var title = ""
        var start: Date?
        var end: Date?
        var isAllDay = false
        var timeZoneIdentifier: String?
        var startIsUTC = false
        var location: String?
        var notes: String?
        var urlString: String?
        var rruleString: String?
        var recurrenceID: Date?
        var exceptionDates: [Date] = []
        var alarmOffsets: [TimeInterval] = []
        var durationValue: TimeInterval?

        var index = startIndex
        while index < lines.count {
            let line = lines[index]
            switch line.name {
            case "END" where line.value.uppercased() == "VEVENT":
                index += 1
                guard let uid, let start else { return (nil, index) }
                let resolvedEnd = end
                    ?? durationValue.map { start.addingTimeInterval($0) }
                    ?? (isAllDay ? start.addingTimeInterval(24 * 3600) : start.addingTimeInterval(3600))
                var event = ICSEventRepresentation(uid: uid, start: start, end: resolvedEnd)
                event.title = title
                event.isAllDay = isAllDay
                event.timeZoneIdentifier = timeZoneIdentifier
                    ?? Self.recurrenceZone(isUTC: startIsUTC, recurs: rruleString != nil)
                event.location = location
                event.notes = notes
                event.urlString = urlString
                event.rruleString = rruleString
                event.recurrenceID = recurrenceID
                event.exceptionDates = exceptionDates
                event.alarmOffsets = alarmOffsets
                return (event, index)

            case "BEGIN" where line.value.uppercased() == "VALARM":
                let (offset, nextIndex) = parseAlarm(lines, from: index + 1)
                if let offset {
                    alarmOffsets.append(offset)
                }
                index = nextIndex
                continue

            case "BEGIN":
                // Unknown nested component — skip to its END.
                index = skipComponent(lines, from: index + 1, component: line.value.uppercased())
                continue

            case "UID":
                uid = line.value
            case "SUMMARY":
                title = unescapeText(line.value)
            case "LOCATION":
                location = unescapeText(line.value)
            case "DESCRIPTION":
                notes = unescapeText(line.value)
            case "URL":
                urlString = line.value
            case "RRULE":
                rruleString = line.value
            case "RECURRENCE-ID":
                recurrenceID = ICSDateFormat.parse(
                    line.value,
                    timeZoneIdentifier: line.parameters["TZID"],
                    isDateOnly: line.parameters["VALUE"]?.uppercased() == "DATE"
                )
            case "DTSTART":
                let dateOnly = line.parameters["VALUE"]?.uppercased() == "DATE"
                isAllDay = dateOnly
                timeZoneIdentifier = line.parameters["TZID"] ?? timeZoneIdentifier
                startIsUTC = Self.isUTCValue(line, isDateOnly: dateOnly)
                start = ICSDateFormat.parse(line.value, timeZoneIdentifier: line.parameters["TZID"], isDateOnly: dateOnly)
            case "DTEND":
                let dateOnly = line.parameters["VALUE"]?.uppercased() == "DATE"
                end = ICSDateFormat.parse(line.value, timeZoneIdentifier: line.parameters["TZID"], isDateOnly: dateOnly)
            case "DURATION":
                durationValue = parseDuration(line.value)
            case "EXDATE":
                // May carry several comma-separated values.
                for value in line.value.split(separator: ",") {
                    let dateOnly = line.parameters["VALUE"]?.uppercased() == "DATE"
                    if let date = ICSDateFormat.parse(
                        String(value),
                        timeZoneIdentifier: line.parameters["TZID"],
                        isDateOnly: dateOnly
                    ) {
                        exceptionDates.append(date)
                    }
                }
            default:
                break
            }
            index += 1
        }
        return (nil, index) // ran out of lines without END:VEVENT
    }

    // MARK: - VTODO

    private static func parseTodo(
        _ lines: [ContentLine],
        from startIndex: Int
    ) -> (ICSTodoRepresentation?, Int) {
        var uid: String?
        var title = ""
        var notes: String?
        var urlString: String?
        var due: Date?
        var isDateOnly = false
        var timeZoneIdentifier: String?
        var dueIsUTC = false
        var priority = 0
        var isFlagged = false
        var completedAt: Date?
        var statusCompleted = false
        var rruleString: String?
        var afterCompletionRepeat: ReminderAfterCompletionRepeat?
        var checklist: [ReminderChecklistItem] = []

        var index = startIndex
        while index < lines.count {
            let line = lines[index]
            switch line.name {
            case "END" where line.value.uppercased() == "VTODO":
                index += 1
                guard let uid else { return (nil, index) }
                var todo = ICSTodoRepresentation(uid: uid)
                todo.title = title
                todo.notes = notes
                todo.urlString = urlString
                todo.due = due
                todo.isDateOnly = due != nil && isDateOnly
                todo.timeZoneIdentifier = isDateOnly
                    ? nil
                    : timeZoneIdentifier ?? Self.recurrenceZone(
                        isUTC: dueIsUTC,
                        recurs: rruleString != nil || afterCompletionRepeat != nil
                    )
                todo.priority = priority
                todo.isFlagged = isFlagged
                todo.completedAt = completedAt
                todo.isCompleted = statusCompleted || completedAt != nil
                todo.rruleString = rruleString
                todo.afterCompletionRepeat = rruleString == nil ? afterCompletionRepeat : nil
                todo.checklist = checklist
                return (todo, index)

            case "BEGIN":
                // Nested components (VALARM and anything else) — skip whole.
                index = skipComponent(lines, from: index + 1, component: line.value.uppercased())
                continue

            case "UID":
                uid = line.value
            case "SUMMARY":
                title = unescapeText(line.value)
            case "DESCRIPTION":
                notes = unescapeText(line.value)
            case "URL":
                urlString = line.value
            case "RRULE":
                rruleString = line.value
            case "DUE":
                isDateOnly = line.parameters["VALUE"]?.uppercased() == "DATE"
                timeZoneIdentifier = line.parameters["TZID"] ?? timeZoneIdentifier
                dueIsUTC = Self.isUTCValue(line, isDateOnly: isDateOnly)
                due = ICSDateFormat.parse(line.value, timeZoneIdentifier: line.parameters["TZID"], isDateOnly: isDateOnly)
            case "PRIORITY":
                priority = min(max(Int(line.value) ?? 0, 0), 9)
            case "STATUS":
                statusCompleted = line.value.uppercased() == "COMPLETED"
            case "COMPLETED":
                completedAt = ICSDateFormat.parse(line.value, timeZoneIdentifier: line.parameters["TZID"], isDateOnly: false)
            case "X-SWIFTCLAW-FLAGGED":
                isFlagged = line.value.uppercased() == "TRUE"
            case "X-SWIFTCLAW-REPEAT-AFTER":
                afterCompletionRepeat = parseRepeatAfter(line.value)
            case "X-SWIFTCLAW-CHECKLIST":
                checklist.append(ReminderChecklistItem(
                    id: line.parameters["ID"].flatMap(UUID.init(uuidString:)) ?? UUID(),
                    text: unescapeText(line.value),
                    isDone: line.parameters["DONE"]?.uppercased() == "TRUE"
                ))
            default:
                break
            }
            index += 1
        }
        return (nil, index) // ran out of lines without END:VTODO
    }

    // MARK: - Time zones

    /// A DATE-TIME written in UTC form ("…T090000Z") with no TZID.
    private static func isUTCValue(_ line: ContentLine, isDateOnly: Bool) -> Bool {
        !isDateOnly && line.parameters["TZID"] == nil && line.value.uppercased().hasSuffix("Z")
    }

    /// The zone a repeating component without TZID recurs in. A UTC start
    /// recurs in UTC (a weekly 09:00Z meeting stays 09:00Z across the
    /// viewer's DST change); nil stays reserved for floating local times.
    /// One-offs keep nil either way: their instant is already exact, and a
    /// nil zone lets the editor adopt the local zone if the user later adds
    /// a repeat.
    private static func recurrenceZone(isUTC: Bool, recurs: Bool) -> String? {
        isUTC && recurs ? "UTC" : nil
    }

    /// "<count> <unit>" (e.g. "2 week") → after-completion repeat.
    private static func parseRepeatAfter(_ value: String) -> ReminderAfterCompletionRepeat? {
        let parts = value.split(separator: " ")
        guard parts.count == 2,
              let count = Int(parts[0]), count >= 1,
              let unit = ReminderAfterCompletionRepeat.Unit(rawValue: String(parts[1]).lowercased())
        else { return nil }
        return ReminderAfterCompletionRepeat(count: count, unit: unit)
    }

    private static func parseAlarm(
        _ lines: [ContentLine],
        from startIndex: Int
    ) -> (TimeInterval?, Int) {
        var offset: TimeInterval?
        var index = startIndex
        while index < lines.count {
            let line = lines[index]
            if line.name == "END" && line.value.uppercased() == "VALARM" {
                return (offset, index + 1)
            }
            // Only relative (duration) triggers map to our alarm model;
            // absolute date-time triggers are skipped.
            if line.name == "TRIGGER" && line.parameters["VALUE"]?.uppercased() != "DATE-TIME" {
                offset = parseDuration(line.value)
            }
            index += 1
        }
        return (offset, index)
    }

    private static func skipComponent(_ lines: [ContentLine], from startIndex: Int, component: String) -> Int {
        var index = startIndex
        var depth = 1
        while index < lines.count {
            let line = lines[index]
            if line.name == "BEGIN" && line.value.uppercased() == component {
                depth += 1
            } else if line.name == "END" && line.value.uppercased() == component {
                depth -= 1
                if depth == 0 { return index + 1 }
            }
            index += 1
        }
        return index
    }

    // MARK: - Primitives

    /// Unfolds continuation lines (leading space/tab) and splits each content
    /// line into name / parameters / value. Tolerates LF-only input.
    static func unfold(_ text: String) -> [ContentLine] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var physical: [String] = []
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = line.first, first == " " || first == "\t", !physical.isEmpty {
                physical[physical.count - 1] += String(line.dropFirst())
            } else if !line.isEmpty {
                physical.append(String(line))
            }
        }
        return physical.compactMap(parseContentLine)
    }

    private static func parseContentLine(_ line: String) -> ContentLine? {
        // Split at the first ":" that is not inside a quoted parameter value.
        var nameAndParams = ""
        var value = ""
        var inQuotes = false
        var foundColon = false
        for character in line {
            if foundColon {
                value.append(character)
            } else if character == "\"" {
                inQuotes.toggle()
                nameAndParams.append(character)
            } else if character == ":" && !inQuotes {
                foundColon = true
            } else {
                nameAndParams.append(character)
            }
        }
        guard foundColon else { return nil }

        var parts = nameAndParams.split(separator: ";").map(String.init)
        guard !parts.isEmpty else { return nil }
        let name = parts.removeFirst().uppercased()
        var parameters: [String: String] = [:]
        for part in parts {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            parameters[pair[0].uppercased()] = String(pair[1]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return ContentLine(name: name, parameters: parameters, value: value)
    }

    static func unescapeText(_ text: String) -> String {
        var result = ""
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else {
                result.append(character)
                continue
            }
            switch iterator.next() {
            case "n", "N": result.append("\n")
            case "\\": result.append("\\")
            case ";": result.append(";")
            case ",": result.append(",")
            case .some(let other): result.append(other)
            case nil: break
            }
        }
        return result
    }

    /// ISO 8601 duration ("-PT15M", "P1DT2H") → seconds.
    static func parseDuration(_ value: String) -> TimeInterval? {
        var rest = Substring(value)
        var sign: TimeInterval = 1
        if rest.hasPrefix("-") { sign = -1; rest = rest.dropFirst() }
        else if rest.hasPrefix("+") { rest = rest.dropFirst() }
        guard rest.hasPrefix("P") else { return nil }
        rest = rest.dropFirst()

        var total: TimeInterval = 0
        var inTime = false
        var number = ""
        for character in rest {
            if character == "T" {
                inTime = true
            } else if character.isNumber {
                number.append(character)
            } else {
                guard let quantity = TimeInterval(number) else { return nil }
                number = ""
                switch (character, inTime) {
                case ("W", false): total += quantity * 7 * 86400
                case ("D", false): total += quantity * 86400
                case ("H", true): total += quantity * 3600
                case ("M", true): total += quantity * 60
                case ("S", true): total += quantity
                default: return nil
                }
            }
        }
        guard number.isEmpty else { return nil }
        return sign * total
    }
}
