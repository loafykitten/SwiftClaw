import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct RemindersSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage(SettingsKeys.remindersEnabled) private var isRemindersEnabled = SettingsStorage.defaultRemindersEnabled
    @AppStorage(SettingsKeys.remindersDefaultListID) private var defaultListIDString = ""
    @Query(sort: \ReminderList.sortOrder) private var lists: [ReminderList]

    @State private var isShowingAppleImport = false
    @State private var isShowingICSImporter = false
    @State private var icsStatusMessage: String?
    @State private var exportDocument: ICSFileDocument?
    @State private var exportListID: UUID?
    @State private var isShowingExporter = false

    private var repository: ReminderRepository {
        ReminderRepository(modelContext: modelContext)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enable Reminders", isOn: $isRemindersEnabled)
            } footer: {
                Text("Shows Reminders in Workspace: lists, due dates, repeats, and checklists.")
            }

            if isRemindersEnabled {
                Section("Defaults") {
                    Picker("Default List", selection: $defaultListIDString) {
                        Text("First list").tag("")
                        ForEach(lists) { list in
                            Label {
                                Text(list.name)
                            } icon: {
                                Image(systemName: "circle.fill")
                                    .foregroundStyle(Color(calendarHex: list.colorHex))
                            }
                            .tag(list.id.uuidString)
                        }
                    }
                }

                Section {
                    Button("Import from Apple Reminders…") {
                        isShowingAppleImport = true
                    }
                    Button("Import a Reminders File (.ics)…") {
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
                    Text("Importing again later is safe — existing reminders are updated, not duplicated.")
                }

                Section {
                    if lists.isEmpty {
                        Text("No lists to export yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(lists) { list in
                            Button("Export “\(list.name)”…") {
                                exportList(list)
                            }
                        }
                    }
                } header: {
                    Text("Export")
                } footer: {
                    Text("Exports a standard .ics to-do file. Checklists and flags round-trip between SwiftClaws; other apps read the rest.")
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isShowingAppleImport) {
            RemindersAppleImportSheet()
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
            exportListID = nil
        }
    }

    private var exportFilename: String {
        guard let exportListID,
              let list = lists.first(where: { $0.id == exportListID })
        else { return "Reminders" }
        return list.name.isEmpty ? "Reminders" : list.name
    }

    private func exportList(_ list: ReminderList) {
        // Completion logs stay home: they're history rows for a master that
        // exports with its own completion state.
        let reminders = (list.reminders ?? []).filter { !$0.isCompletionLog }
        let text = ICSTodoImporter.exportText(for: reminders, listName: list.name)
        exportDocument = ICSFileDocument(text: text)
        exportListID = list.id
        isShowingExporter = true
    }

    private func handleICSImport(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            icsStatusMessage = "Couldn't read that file."
            return
        }
        let target = repository.defaultList(preferredID: SettingsStorage.loadRemindersDefaultListID())
        let count = ICSTodoImporter.importTodos(from: text, into: target, repository: repository)
        icsStatusMessage = "Imported \(count) reminder\(count == 1 ? "" : "s") into “\(target.name)”."
    }
}
