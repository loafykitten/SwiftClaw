import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension ICSEventRepresentation {
    /// Export mapping. The UID prefers the event's original external
    /// identity so an export→import round trip (or a re-import into another
    /// SwiftClaw) dedups instead of duplicating.
    @MainActor
    init(event: CalendarEvent) {
        self.init(
            uid: event.externalIdentifier ?? "swiftclaw-\(event.id.uuidString)",
            start: event.startDate,
            end: event.endDate
        )
        title = event.title
        isAllDay = event.isAllDay
        timeZoneIdentifier = event.timeZoneIdentifier
        location = event.locationText
        notes = event.notes
        urlString = event.urlString
        rruleString = event.recurrenceRuleString
        exceptionDates = event.exceptionDates
        alarmOffsets = event.alarms.map(\.offsetSeconds)
    }
}

/// Applies parsed .ics events to the store. Import is idempotent: rows are
/// upserted by UID (`externalIdentifier`), so re-importing the same file
/// updates rather than duplicates.
@MainActor
enum ICSImporter {
    @discardableResult
    static func importEvents(
        from text: String,
        into calendar: UserCalendar,
        repository: CalendarRepository
    ) -> Int {
        importEvents(ICSParser.parse(text), into: calendar, repository: repository)
    }

    @discardableResult
    static func importEvents(
        _ parsed: [ICSEventRepresentation],
        into calendar: UserCalendar,
        repository: CalendarRepository
    ) -> Int {
        repository.performImport {
            apply(parsed, into: calendar, repository: repository)
        }
        return parsed.count
    }

    private static func apply(
        _ parsed: [ICSEventRepresentation],
        into calendar: UserCalendar,
        repository: CalendarRepository
    ) {
        // Masters before overrides: a RECURRENCE-ID VEVENT shares its
        // master's UID, and the override needs the master row to link to
        // regardless of file order.
        let masters = parsed.filter { $0.recurrenceID == nil }
        let overrides = parsed.filter { $0.recurrenceID != nil }

        for representation in masters {
            repository.upsertImportedEvent(externalIdentifier: representation.uid) { event in
                apply(representation, to: event, calendar: calendar)
                event.recurrenceRuleString = representation.rruleString
                event.exceptionDates = representation.exceptionDates
            }
        }
        for representation in overrides {
            guard let originalStart = representation.recurrenceID else { continue }
            // Occurrence-scoped identity (the Apple importer's shape) so the
            // override never collides with its master's UID-keyed row.
            let overrideID = "\(representation.uid)@detached@\(originalStart.timeIntervalSinceReferenceDate)"
            let master = repository.event(withExternalIdentifier: representation.uid)
            repository.upsertImportedEvent(externalIdentifier: overrideID) { event in
                apply(representation, to: event, calendar: calendar)
                event.parentEventID = master?.id
                event.originalOccurrenceDate = originalStart
            }
            // Mask the replaced occurrence on the master (many producers
            // don't also emit an EXDATE for overridden instances).
            if let master, !RecurrenceExpander.isException(originalStart, exceptionDates: master.exceptionDates) {
                master.exceptionDates.append(originalStart)
                repository.saveChanges()
            }
        }
    }

    private static func apply(
        _ representation: ICSEventRepresentation,
        to event: CalendarEvent,
        calendar: UserCalendar
    ) {
        event.title = representation.title
        event.startDate = representation.start
        event.endDate = representation.end
        event.isAllDay = representation.isAllDay
        event.timeZoneIdentifier = representation.timeZoneIdentifier
        event.locationText = representation.location
        event.notes = representation.notes
        event.urlString = representation.urlString
        event.alarms = representation.alarmOffsets.map(CalendarAlarmPayload.init(offsetSeconds:))
        event.source = .icsImport
        event.calendar = calendar
    }

    @MainActor
    static func exportText(for events: [CalendarEvent], calendarName: String?) -> String {
        ICSSerializer.serialize(events.map(ICSEventRepresentation.init(event:)), calendarName: calendarName)
    }
}

/// `fileExporter` document wrapping serialized .ics text.
nonisolated struct ICSFileDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.icsCalendar]
    static let writableContentTypes: [UTType] = [.icsCalendar]

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

extension UTType {
    /// The system "text/calendar" type ("public.ics" is not a thing; the
    /// canonical identifier is com.apple.ical.ics).
    nonisolated static var icsCalendar: UTType {
        UTType(filenameExtension: "ics", conformingTo: .text) ?? .text
    }
}
