import SwiftUI
import SwiftData

/// Apple Calendar import flow: request access, pick source calendars, import.
/// Used from both onboarding and Settings › Calendar; safe to re-run —
/// everything upserts by external identifier.
struct CalendarAppleImportSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case requestingAccess
        case pickingCalendars
        case importing
        case finished(AppleCalendarImporter.Summary)
        case failed(String)
    }

    @State private var importer = AppleCalendarImporter()
    @State private var phase: Phase = .requestingAccess
    @State private var sources: [(identifier: String, title: String, colorHex: String)] = []
    @State private var selectedIdentifiers: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Import from Apple Calendar") {
                dismiss()
            }

            Group {
                switch phase {
                case .requestingAccess:
                    ProgressView("Requesting calendar access…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .pickingCalendars:
                    calendarPicker
                case .importing:
                    ProgressView("Importing events…")
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

            if case .pickingCalendars = phase {
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

    private var calendarPicker: some View {
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
                Text("Choose calendars to import")
            } footer: {
                Text("Events from the past year through three years ahead are imported. Importing again later updates existing events instead of duplicating them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func finishedView(_ summary: AppleCalendarImporter.Summary) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text("Import complete")
                .font(.headline)
            Text("\(summary.eventCount) events across \(summary.calendarCount) calendars")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if summary.degradedSeriesCount > 0 {
                Text("\(summary.degradedSeriesCount) repeating series used rules SwiftClaw doesn't support and were imported as individual events.")
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
            sources = importer.availableCalendars()
            selectedIdentifiers = Set(sources.map(\.identifier))
            phase = .pickingCalendars
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func runImport() {
        phase = .importing
        let repository = CalendarRepository(modelContext: modelContext)
        do {
            let summary = try importer.importCalendars(identifiers: selectedIdentifiers, repository: repository)
            phase = .finished(summary)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
