import SwiftUI

struct MemorySettingsView: View {
    @AppStorage(SettingsKeys.memoryEnabled)
    private var isMemoryEnabled = SettingsStorage.defaultMemoryEnabled

    var body: some View {
        Form {
            Section {
                Toggle("Enable Memory", isOn: $isMemoryEnabled)
            } footer: {
                Text("Shows Memory in Workspace, where you can manage small facts the assistant can recall for you.")
            }
        }
        .formStyle(.grouped)
    }
}
