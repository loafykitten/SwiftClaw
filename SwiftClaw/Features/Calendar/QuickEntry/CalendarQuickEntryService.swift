import Foundation
import os

/// Natural-language event entry ("Lunch with Sam tomorrow 1pm") via the
/// app's inference stack: one `.standalone` completion with a strict
/// JSON-out contract, parsed into a `CalendarEventDraft` the user confirms in
/// the editor before anything is saved. On any failure the caller falls back
/// to a blank editor prefilled with the raw phrase as the title — quick entry
/// must never lose the user's typing.
@MainActor
final class CalendarQuickEntryService {
    private static let logger = AppLog.make("calendar.quickentry")

    /// Model output contract.
    nonisolated struct ParsedEvent: Codable, Sendable {
        var title: String
        /// ISO 8601 with offset, e.g. "2026-07-11T13:00:00-05:00".
        var start: String
        var end: String?
        var allDay: Bool?
        var location: String?
        /// RFC 5545 RRULE value when the phrase implies repetition.
        var rrule: String?

        enum CodingKeys: String, CodingKey {
            case title, start, end, location, rrule
            case allDay = "all_day"
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
    func draft(
        from phrase: String,
        referenceDate: Date = .now,
        calendarID: UUID?
    ) async throws -> CalendarEventDraft {
        let model = SettingsStorage.loadModelSelection(
            forKey: SettingsKeys.clawModel,
            userDefaults: userDefaults
        )
        guard !model.isEmpty else { throw QuickEntryError.modelNotConfigured }

        let response = try await completeProvider(
            [.system(Self.systemPrompt(referenceDate: referenceDate)), .user(phrase)],
            model,
            .standalone,
            []
        )
        guard let parsed = Self.parseResponse(response),
              let start = Self.parseISODate(parsed.start)
        else {
            Self.logger.warning("quick entry: unparseable model response")
            throw QuickEntryError.unparseableResponse
        }

        var draft = CalendarEventDraft(newAt: start, calendarID: calendarID)
        draft.title = parsed.title
        draft.isAllDay = parsed.allDay ?? false
        if draft.isAllDay, let days = Self.allDayRange(start: parsed.start, end: parsed.end) {
            // All-day dates are the model's civil dates as written; an
            // offset that differs from the device's must not shift the day.
            draft.start = days.first.startDate()
            draft.end = days.first.adding(days: days.count).startDate()
        } else if let end = parsed.end.flatMap(Self.parseISODate), end > start {
            draft.end = end
        } else if draft.isAllDay {
            draft.end = start.addingTimeInterval(24 * 3600)
        }
        draft.location = parsed.location ?? ""
        draft.rule = parsed.rrule.flatMap(RecurrenceRule.init(rruleString:))
        return draft
    }

    // MARK: - Parsing

    /// Extracts the JSON object from the model response, tolerating markdown
    /// code fences and surrounding prose (shared scanner).
    nonisolated static func parseResponse(_ response: String) -> ParsedEvent? {
        ModelResponseJSON.decode(ParsedEvent.self, from: response)
    }

    /// The civil days of an all-day phrase, read from the "yyyy-MM-dd" the
    /// model wrote. An end at midnight (or a bare date) is exclusive; an end
    /// with a clock time ("…T23:59:59") includes its day. At least one day.
    nonisolated static func allDayRange(start: String, end: String?) -> (first: CivilDay, count: Int)? {
        guard let first = CivilDay(isoDatePrefix: start) else { return nil }
        guard let end, let endDay = CivilDay(isoDatePrefix: end) else { return (first, 1) }
        let time = end.dropFirst(10)
        let isMidnight = time.isEmpty || time.hasPrefix("T00:00")
        let exclusiveEnd = isMidnight ? endDay : endDay.adding(days: 1)
        return (first, max(1, first.days(until: exclusiveEnd)))
    }

    nonisolated static func parseISODate(_ string: String) -> Date? {
        // ISO8601 with and without fractional seconds; both appear in the wild.
        var strategy = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
        if let date = try? strategy.parse(string) {
            return date
        }
        strategy = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        return try? strategy.parse(string)
    }

    private static func systemPrompt(referenceDate: Date) -> String {
        let zone = TimeZone.current
        return """
        You convert one natural-language phrase into one calendar event. \
        Reply with ONLY a JSON object — no prose, no markdown fences:
        {
          "title": "<event title, the phrase minus the date/time/location words>",
          "start": "<ISO 8601 date-time with offset>",
          "end": "<ISO 8601 date-time with offset; omit if unknown (a 1-hour default applies)>",
          "all_day": <true only for date-only events like birthdays or trips>,
          "location": "<place name if the phrase names one, else omit>",
          "rrule": "<RFC 5545 RRULE like FREQ=WEEKLY;BYDAY=MO if the phrase implies repetition, else omit>"
        }

        The current date-time is \(referenceDate.formatted(.iso8601)) in the user's time zone \
        \(zone.identifier). Resolve relative words ("tomorrow", "next tuesday", "tonight") \
        against that. Times without am/pm mean the next plausible occurrence (e.g. "at 7" \
        in the evening context). If the phrase names no date, assume the soonest upcoming slot today or tomorrow.
        """
    }
}
