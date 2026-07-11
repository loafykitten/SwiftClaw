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
        if let end = parsed.end.flatMap(Self.parseISODate), end > start {
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
    /// code fences and surrounding prose.
    nonisolated static func parseResponse(_ response: String) -> ParsedEvent? {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        // Try raw, then fenced, then first {...} span.
        let candidates: [String] = [
            trimmed,
            Self.fencedBody(of: trimmed) ?? "",
            Self.firstJSONObject(in: trimmed) ?? "",
        ]
        for candidate in candidates where !candidate.isEmpty {
            if let parsed = try? JSONDecoder().decode(ParsedEvent.self, from: Data(candidate.utf8)) {
                return parsed
            }
        }
        return nil
    }

    private nonisolated static func fencedBody(of text: String) -> String? {
        guard let fenceStart = text.range(of: "```") else { return nil }
        let afterFence = text[fenceStart.upperBound...].drop { $0 != "\n" }.dropFirst()
        guard let fenceEnd = afterFence.range(of: "```") else { return nil }
        return String(afterFence[..<fenceEnd.lowerBound])
    }

    private nonisolated static func firstJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            return nil
        }
        return String(text[start...end])
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
