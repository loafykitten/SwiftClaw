import Foundation
import SwiftData

/// System-only tool the calendar-review pass uses to pull the schedule it
/// should look at. NOT registered on `ToolRegistry.shared` — constructed per
/// pass by `CalendarReviewService` in a scoped registry. Returns expanded
/// occurrences (not master rows) so the model reasons about the actual
/// timeline, with each occurrence carrying its master event's GUID for
/// `notify_user_about_events`.
final class CalendarReviewFetchTool: Tool {
    let name = "fetch_calendar_events"
    let displayName = "Fetch Calendar Events"
    let description = """
    Fetches the user's upcoming calendar occurrences. All filters are optional: \
    from_days (default 0 = today) and to_days (default 7) bound the window in days \
    relative to now; include_all_day (default true); limit (default 50, max 200).
    """
    let systemImage = "calendar.badge.clock"
    let parameters: [ToolParameter] = [
        ToolParameter(name: "from_days", type: .integer, description: "Window start, days from now (0 = now)."),
        ToolParameter(name: "to_days", type: .integer, description: "Window end, days from now."),
        ToolParameter(name: "include_all_day", type: .boolean, description: "Include all-day events (default true)."),
        ToolParameter(name: "limit", type: .integer, description: "Maximum occurrences returned (default 50)."),
    ]

    var isConfigured: Bool { true }
    var isEnabled: Bool { true }

    private let modelContainer: ModelContainer
    /// Reports the event rows actually handed to the model, keyed by ID
    /// with the `modifiedAt` the model saw, so the service stamps
    /// `lastReviewedAt` after a successful pass only on rows that haven't
    /// changed since.
    private let onEventsFetched: @MainActor ([UUID: Date]) -> Void

    init(
        modelContainer: ModelContainer,
        onEventsFetched: @escaping @MainActor ([UUID: Date]) -> Void = { _ in }
    ) {
        self.modelContainer = modelContainer
        self.onEventsFetched = onEventsFetched
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        let fromDays = arguments["from_days"]?.intValue ?? 0
        let toDays = arguments["to_days"]?.intValue ?? 7
        let includeAllDay = arguments["include_all_day"]?.boolValue ?? true
        let limit = min(200, max(1, arguments["limit"]?.intValue ?? 50))
        guard toDays > fromDays else {
            throw ToolError.invalidArguments("to_days must be greater than from_days")
        }

        return await MainActor.run {
            let now = Date.now
            let window = DateInterval(
                start: now.addingTimeInterval(TimeInterval(fromDays) * 24 * 3600),
                end: now.addingTimeInterval(TimeInterval(toDays) * 24 * 3600)
            )
            let repository = CalendarRepository(modelContext: ModelContext(modelContainer))
            var occurrences = repository.occurrences(in: window)
            if !includeAllDay {
                occurrences.removeAll(where: \.isAllDay)
            }
            occurrences = Array(occurrences.prefix(limit))

            let masterIDs = Array(Set(occurrences.map(\.eventID)))
            var eventsByID: [UUID: CalendarEvent] = [:]
            for event in repository.events(withIDs: masterIDs) {
                if eventsByID[event.id] == nil {
                    eventsByID[event.id] = event
                }
            }
            onEventsFetched(eventsByID.mapValues(\.modifiedAt))

            guard !occurrences.isEmpty else {
                return "No events in this window."
            }

            let calendarNames: [UUID: String] = Dictionary(
                uniqueKeysWithValues: repository.calendars().map { ($0.id, $0.name) }
            )
            let lines = occurrences.map { occurrence -> String in
                let event = eventsByID[occurrence.eventID]
                var parts = [
                    "eventGUID: \(occurrence.eventID.uuidString)",
                    "title: \(occurrence.title)",
                    occurrence.isAllDay
                        ? "date: \(occurrence.start.formatted(.dateTime.year().month().day())) (all-day)"
                        : "start: \(occurrence.start.formatted(date: .abbreviated, time: .shortened)), end: \(occurrence.end.formatted(date: .omitted, time: .shortened))",
                ]
                if let calendarID = occurrence.calendarID, let name = calendarNames[calendarID] {
                    parts.append("calendar: \(name)")
                }
                if let location = event?.locationText, !location.isEmpty {
                    parts.append("location: \(location)")
                }
                if let notes = event?.notes, !notes.isEmpty {
                    parts.append("notes: \(notes.prefix(120))")
                }
                if event?.isRecurring == true {
                    parts.append("recurring: yes")
                }
                // Flag events an earlier pass already surfaced (and that
                // haven't changed since) so the model doesn't repeat itself.
                if let event, let reviewedAt = event.lastReviewedAt, event.modifiedAt <= reviewedAt {
                    parts.append("previously reviewed: yes")
                }
                return "- " + parts.joined(separator: " | ")
            }
            return "\(occurrences.count) occurrences:\n" + lines.joined(separator: "\n")
        }
    }
}
