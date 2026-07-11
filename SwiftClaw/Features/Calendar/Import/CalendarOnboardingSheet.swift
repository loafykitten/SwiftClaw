import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// First-enable onboarding (per docs/plans/calendar.md): offer Apple Calendar
/// import, .ics import, or a fresh start. Every path is also reachable later
/// from Settings › Calendar, so dismissing is never a dead end.
struct CalendarOnboardingSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKeys.calendarHasCompletedOnboarding) private var hasCompletedOnboarding = false

    @State private var isShowingAppleImport = false
    @State private var isShowingICSImporter = false
    @State private var icsImportSummary: String?

    private var repository: CalendarRepository {
        CalendarRepository(modelContext: modelContext)
    }

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                Text("Set Up Your Calendar")
                    .font(.title2.weight(.semibold))
                Text("Bring in your existing events, or start with a clean slate. You can import anytime from Settings › Calendar.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 28)
            .padding(.horizontal, 32)

            VStack(spacing: 10) {
                optionButton(
                    title: "Import from Apple Calendar",
                    subtitle: "Copy events from the calendars on this Mac.",
                    systemImage: "arrow.down.circle"
                ) {
                    isShowingAppleImport = true
                }
                optionButton(
                    title: "Import a Calendar File",
                    subtitle: "Load events from an .ics file.",
                    systemImage: "doc.badge.arrow.up"
                ) {
                    isShowingICSImporter = true
                }
                optionButton(
                    title: "Start Fresh",
                    subtitle: "Begin with an empty Personal calendar.",
                    systemImage: "sparkles"
                ) {
                    _ = repository.defaultCalendar()
                    complete()
                }
            }
            .padding(.horizontal, 24)

            if let icsImportSummary {
                Text(icsImportSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button("Not Now") {
                complete()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.bottom, 20)
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 420)
        #endif
        .sheet(isPresented: $isShowingAppleImport, onDismiss: complete) {
            CalendarAppleImportSheet()
        }
        .fileImporter(
            isPresented: $isShowingICSImporter,
            allowedContentTypes: [.icsCalendar, .text]
        ) { result in
            handleICSImport(result)
        }
    }

    private func optionButton(
        title: String,
        subtitle: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.body.weight(.medium))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .glassEffect(in: .rect(cornerRadius: 12.0))
            .contentShape(.rect(cornerRadius: 12.0))
        }
        .buttonStyle(.plain)
    }

    private func handleICSImport(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            icsImportSummary = "Couldn't read that file."
            return
        }
        let target = repository.defaultCalendar(preferredID: SettingsStorage.loadCalendarDefaultCalendarID())
        let count = ICSImporter.importEvents(from: text, into: target, repository: repository)
        icsImportSummary = "Imported \(count) event\(count == 1 ? "" : "s")."
        complete()
    }

    private func complete() {
        hasCompletedOnboarding = true
        dismiss()
    }
}
