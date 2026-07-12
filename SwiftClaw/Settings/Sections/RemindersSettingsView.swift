import SwiftUI
import SwiftData

struct RemindersSettingsView: View {
    @AppStorage(SettingsKeys.remindersEnabled) private var isRemindersEnabled = SettingsStorage.defaultRemindersEnabled
    @AppStorage(SettingsKeys.remindersDefaultListID) private var defaultListIDString = ""
    @Query(sort: \ReminderList.sortOrder) private var lists: [ReminderList]

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
            }
        }
        .formStyle(.grouped)
    }
}
