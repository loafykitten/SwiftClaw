import SwiftUI
import SwiftData

/// Apple Reminders import flow: request access, pick source lists, import.
/// Used from both onboarding and Settings › Reminders; safe to re-run —
/// everything upserts by external identifier.
struct RemindersAppleImportSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case requestingAccess
        case pickingLists
        case importing
        case finished(AppleRemindersImporter.Summary)
        case failed(String)
    }

    @State private var importer = AppleRemindersImporter()
    @State private var phase: Phase = .requestingAccess
    @State private var sources: [(identifier: String, title: String, colorHex: String)] = []
    @State private var selectedIdentifiers: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Import from Apple Reminders") {
                dismiss()
            }

            Group {
                switch phase {
                case .requestingAccess:
                    ProgressView("Requesting reminders access…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .pickingLists:
                    listPicker
                case .importing:
                    ProgressView("Importing reminders…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .finished(let summary):
                    finishedView(summary)
                case .failed(let message):
                    ContentUnavailableView(
                        "Import Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if case .pickingLists = phase {
                SheetFooter(confirmTitle: "Import", isDisabled: selectedIdentifiers.isEmpty) {
                    runImport()
                }
            } else if case .finished = phase {
                SheetFooter(confirmTitle: "Done") {
                    dismiss()
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 380)
        #endif
        .task { await requestAccess() }
    }

    private var listPicker: some View {
        List {
            Section {
                ForEach(sources, id: \.identifier) { source in
                    Toggle(isOn: Binding(
                        get: { selectedIdentifiers.contains(source.identifier) },
                        set: { isOn in
                            if isOn {
                                selectedIdentifiers.insert(source.identifier)
                            } else {
                                selectedIdentifiers.remove(source.identifier)
                            }
                        }
                    )) {
                        Label {
                            Text(source.title)
                        } icon: {
                            Image(systemName: "circle.fill")
                                .foregroundStyle(Color(calendarHex: source.colorHex))
                        }
                    }
                }
            } header: {
                Text("Choose lists to import")
            } footer: {
                Text("Every to-do in the selected lists is imported, completed ones included. Importing again later updates existing to-dos instead of duplicating them. Subtasks inside Apple Reminders aren't readable by other apps and won't come across.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func finishedView(_ summary: AppleRemindersImporter.Summary) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text("Import complete")
                .font(.headline)
            Text("\(summary.reminderCount) reminders across \(summary.listCount) lists")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if summary.degradedRuleCount > 0 {
                Text("\(summary.degradedRuleCount) reminders used repeat rules SwiftClaw doesn't support and were imported without a repeat.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func requestAccess() async {
        do {
            try await importer.requestAccess()
            sources = importer.availableLists()
            selectedIdentifiers = Set(sources.map(\.identifier))
            phase = .pickingLists
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func runImport() {
        phase = .importing
        let repository = ReminderRepository(modelContext: modelContext)
        Task {
            let summary = await importer.importLists(identifiers: selectedIdentifiers, repository: repository)
            phase = .finished(summary)
        }
    }
}
