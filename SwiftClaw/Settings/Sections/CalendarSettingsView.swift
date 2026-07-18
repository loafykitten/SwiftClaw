import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct CalendarSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage(SettingsKeys.calendarEnabled) private var isCalendarEnabled = SettingsStorage.defaultCalendarEnabled
    @AppStorage(SettingsKeys.calendarDefaultCalendarID) private var defaultCalendarIDString = ""
    @AppStorage(SettingsKeys.calendarReviewIntervalSeconds)
    private var reviewIntervalSeconds = SettingsStorage.defaultCalendarReviewIntervalSeconds
    @AppStorage(SettingsKeys.calendarOverlayEnabled)
    private var isOverlayEnabled = SettingsStorage.defaultCalendarOverlayEnabled
    @Query(sort: \UserCalendar.sortOrder) private var calendars: [UserCalendar]

    @State private var isShowingAppleImport = false
    @State private var isShowingICSImporter = false
    @State private var icsStatusMessage: String?
    @State private var exportDocument: ICSFileDocument?
    @State private var exportCalendarID: UUID?
    @State private var isShowingExporter = false

    private var repository: CalendarRepository {
        CalendarRepository(modelContext: modelContext)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enable Calendar", isOn: $isCalendarEnabled)
            } footer: {
                Text("Shows the Calendar in Workspace, with month, week, day, and agenda views.")
            }

            if isCalendarEnabled {
                Section("Defaults") {
                    Picker("Default Calendar", selection: $defaultCalendarIDString) {
                        Text("First calendar").tag("")
                        ForEach(calendars) { calendar in
                            Label {
                                Text(calendar.name)
                            } icon: {
                                Image(systemName: "circle.fill")
                                    .foregroundStyle(Color(calendarHex: calendar.colorHex))
                            }
                            .tag(calendar.id.uuidString)
                        }
                    }
                }

                Section {
                    Picker("Scheduled Review", selection: $reviewIntervalSeconds) {
                        Text("Manually only").tag(0)
                        Text("Every 6 hours").tag(6 * 3600)
                        Text("Every 12 hours").tag(12 * 3600)
                        Text("Daily").tag(24 * 3600)
                    }
                    .onChange(of: reviewIntervalSeconds) { _, _ in
                        NotificationCenter.default.post(
                            name: SettingsNotifications.calendarReviewScheduleDidChange,
                            object: nil
                        )
                    }
                } header: {
                    Text("AI Review")
                } footer: {
                    Text("The assistant periodically looks over your upcoming schedule for conflicts, prep work, and standouts, and posts a review chat when something needs you.")
                }

                Section {
                    Toggle("Show Apple Calendar events", isOn: $isOverlayEnabled)
                } header: {
                    Text("Overlay")
                } footer: {
                    Text("Displays this Mac's Apple Calendar events read-only alongside your SwiftClaw events. Nothing is imported or modified.")
                }

                Section {
                    Button("Import from Apple Calendar…") {
                        isShowingAppleImport = true
                    }
                    Button("Import Calendar File (.ics)…") {
                        isShowingICSImporter = true
                    }
                    if let icsStatusMessage {
                        Text(icsStatusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Import")
                } footer: {
                    Text("Importing again later is safe — existing events are updated, not duplicated.")
                }

                Section {
                    if calendars.isEmpty {
                        Text("No calendars to export yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(calendars) { calendar in
                            Button("Export “\(calendar.name)”…") {
                                exportCalendar(calendar)
                            }
                        }
                    }
                } header: {
                    Text("Export")
                } footer: {
                    Text("Exports a standard .ics file readable by Apple Calendar, Google Calendar, and everything else.")
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isShowingAppleImport) {
            CalendarAppleImportSheet()
        }
        .fileImporter(
            isPresented: $isShowingICSImporter,
            allowedContentTypes: [.icsCalendar, .text]
        ) { result in
            handleICSImport(result)
        }
        .fileExporter(
            isPresented: $isShowingExporter,
            document: exportDocument,
            contentType: .icsCalendar,
            defaultFilename: exportFilename
        ) { _ in
            exportDocument = nil
            exportCalendarID = nil
        }
    }

    private var exportFilename: String {
        guard let exportCalendarID,
              let calendar = calendars.first(where: { $0.id == exportCalendarID })
        else { return "Calendar" }
        return calendar.name.isEmpty ? "Calendar" : calendar.name
    }

    private func exportCalendar(_ calendar: UserCalendar) {
        let events = (calendar.events ?? []).filter { !$0.isOverride }
        let overrides = (calendar.events ?? []).filter(\.isOverride)
        // Overrides export as standalone events; their EXDATE already lives
        // on the master, so nothing double-renders on re-import.
        let text = ICSImporter.exportText(for: events + overrides, calendarName: calendar.name)
        exportDocument = ICSFileDocument(text: text)
        exportCalendarID = calendar.id
        isShowingExporter = true
    }

    private func handleICSImport(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        Task {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let parsed = try await Task.detached(priority: .userInitiated) {
                    let text = try String(contentsOf: url, encoding: .utf8)
                    return ICSParser.parse(text)
                }.value
                let target = repository.defaultCalendar(
                    preferredID: SettingsStorage.loadCalendarDefaultCalendarID()
                )
                let count = ICSImporter.importEvents(parsed, into: target, repository: repository)
                icsStatusMessage = "Imported \(count) event\(count == 1 ? "" : "s") into “\(target.name)”."
            } catch {
                icsStatusMessage = "Couldn't read that file."
            }
        }
    }
}
