import Foundation
import os

/// Natural-language reminder entry ("Email Priya tomorrow 9am") via the
/// app's inference stack: one `.standalone` completion with a strict
/// JSON-out contract, parsed into a `ReminderDraft` the user confirms in
/// the editor before anything is saved. On any failure the caller falls back
/// to a blank editor prefilled with the raw phrase as the title — quick entry
/// must never lose the user's typing.
@MainActor
final class ReminderQuickEntryService {
    private static let logger = AppLog.make("reminders.quickentry")

    /// Model output contract.
    nonisolated struct ParsedReminder: Codable, Sendable {
        var title: String
        /// "YYYY-MM-DD" for date-only, or ISO 8601 with offset when timed.
        var due: String?
        var hasTime: Bool?
        /// One of the user's list names, matched case-insensitively.
        var list: String?
        /// "high" / "medium" / "low".
        var priority: String?
        /// RFC 5545 RRULE value for fixed-schedule repetition.
        var rrule: String?
        /// Interval repetition relative to completion.
        var repeatAfter: RepeatAfter?

        struct RepeatAfter: Codable, Sendable {
            var count: Int
            /// "day" / "week" / "month" / "year".
            var unit: String
        }

        enum CodingKeys: String, CodingKey {
            case title, due, list, priority, rrule
            case hasTime = "has_time"
            case repeatAfter = "repeat_after"
        }
    }

    /// Testable inference seam (the review-service pattern).
    var completeProvider: @Sendable ([InferenceMessage], String, InferenceSystemPromptMode, [any Tool]) async throws -> String = { messages, model, mode, tools in
        try await InferenceService.shared.complete(
            messages: messages,
            model: model,
            systemPromptMode: mode,
            tools: tools
        )
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    enum QuickEntryError: LocalizedError {
        case modelNotConfigured
        case unparseableResponse

        var errorDescription: String? {
            switch self {
            case .modelNotConfigured: "Quick entry needs a model in Settings."
            case .unparseableResponse: "Couldn't understand that phrase."
            }
        }
    }

    /// Parses `phrase` into a draft anchored to `referenceDate` (now).
    /// `lists` are the user's visible lists for name matching; an unmatched or
    /// omitted list leaves `listID` nil so the editor applies the default.
    func draft(
        from phrase: String,
        referenceDate: Date = .now,
        lists: [(id: UUID, name: String)]
    ) async throws -> ReminderDraft {
        let model = SettingsStorage.loadModelSelection(
            forKey: SettingsKeys.clawModel,
            userDefaults: userDefaults
        )
        guard !model.isEmpty else { throw QuickEntryError.modelNotConfigured }

        let response = try await completeProvider(
            [.system(Self.systemPrompt(referenceDate: referenceDate, listNames: lists.map(\.name))), .user(phrase)],
            model,
            .standalone,
            []
        )
        // A blank title counts as unparseable: succeeding here would clear the
        // entry field and open an unsaveable editor, losing the typed phrase.
        guard let parsed = Self.parseResponse(response),
              !parsed.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            Self.logger.warning("quick entry: unparseable model response")
            throw QuickEntryError.unparseableResponse
        }
        return Self.makeDraft(from: parsed, lists: lists)
    }

    /// Builds the draft from a parsed response. A missing or unparseable due
    /// date degrades to a dateless reminder (unlike events, reminders don't
    /// need one); a repeat without a due date is dropped so the draft stays
    /// saveable.
    nonisolated static func makeDraft(
        from parsed: ParsedReminder,
        lists: [(id: UUID, name: String)]
    ) -> ReminderDraft {
        let matchedListID = parsed.list.flatMap { name in
            lists.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id
        }
        var draft = ReminderDraft(newAt: nil, listID: matchedListID)
        draft.title = parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)

        if let due = parsed.due {
            if parsed.hasTime == true {
                // Never downgrade a claimed time to date-only — a due value we
                // can't read as an instant degrades to dateless instead of
                // silently shifting semantics.
                if let instant = CalendarQuickEntryService.parseISODate(due) ?? Self.parseLocalDateTime(due) {
                    draft.dueDate = instant
                    draft.dueDateMode = .dateTime
                }
            } else if let day = Self.parseISODateOnly(due) {
                draft.dueDate = day
                draft.dueDateMode = .date
            }
        }

        if draft.hasDueDate {
            if let rule = parsed.rrule.flatMap(RecurrenceRule.init(rruleString:)) {
                draft.repeatMode = .schedule
                draft.rule = rule
            } else if let after = parsed.repeatAfter,
                      let unit = ReminderAfterCompletionRepeat.Unit(rawValue: after.unit),
                      after.count >= 1 {
                draft.repeatMode = .afterCompletion
                draft.afterCompletionRepeat = ReminderAfterCompletionRepeat(count: after.count, unit: unit)
            }
        }

        draft.priority = switch parsed.priority?.lowercased() {
        case "high": .high
        case "medium": .medium
        case "low": .low
        default: .none
        }
        return draft
    }

    // MARK: - Parsing

    /// Extracts the JSON object from the model response, tolerating markdown
    /// code fences and surrounding prose (shared scanner).
    nonisolated static func parseResponse(_ response: String) -> ParsedReminder? {
        ModelResponseJSON.decode(ParsedReminder.self, from: response)
    }

    /// "YYYY-MM-DD" (or a longer string starting with it) → local midnight,
    /// matching the floating date-only convention.
    nonisolated static func parseISODateOnly(_ string: String) -> Date? {
        let parts = string.prefix(10).split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              let date = Calendar.current.date(from: DateComponents(year: year, month: month, day: day))
        else { return nil }
        // Calendar normalizes impossible components ("2026-02-30" → Mar 2)
        // instead of failing; round-trip to reject them.
        let check = Calendar.current.dateComponents([.year, .month, .day], from: date)
        guard check.year == year, check.month == month, check.day == day else { return nil }
        return date
    }

    /// Offset-less "YYYY-MM-DDTHH:MM:SS", a common model slip, read as the
    /// user's local time.
    nonisolated static func parseLocalDateTime(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: string)
    }

    private static func systemPrompt(referenceDate: Date, listNames: [String]) -> String {
        let zone = TimeZone.current
        let lists = listNames.isEmpty
            ? "The user has no lists yet."
            : "The user's lists: \(listNames.joined(separator: ", "))."
        return """
        You convert one natural-language phrase into one reminder (a to-do, not a \
        calendar event). Reply with ONLY a JSON object — no prose, no markdown fences:
        {
          "title": "<the to-do, the phrase minus the date/time/list/priority words>",
          "due": "<when it's due: 'YYYY-MM-DD' if no clock time is named, or ISO 8601 date-time with offset if one is; omit when the phrase implies no date>",
          "has_time": <true only when the phrase names a clock time>,
          "list": "<one of the user's list names when the phrase clearly names one, else omit>",
          "priority": "<'high', 'medium', or 'low' when the phrase implies urgency ('urgent', 'ASAP', 'sometime'), else omit>",
          "rrule": "<RFC 5545 RRULE like FREQ=WEEKLY;BYDAY=MO when it repeats on a fixed schedule, else omit>",
          "repeat_after": <{"count": 2, "unit": "week"} when it repeats relative to finishing ("every 2 weeks after I water the plants"); unit is "day", "week", "month", or "year"; else omit>
        }

        The current date-time is \(referenceDate.formatted(.iso8601)) in the user's time zone \
        \(zone.identifier). Resolve relative words ("tomorrow", "next tuesday", "tonight") \
        against that. Most reminders are date-only — only set a time the phrase actually names. \
        A repeat needs a due date: if the phrase implies repetition without a start, use the \
        soonest plausible day. \(lists)
        """
    }
}
