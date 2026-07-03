import SwiftData
import SwiftUI

private enum WorkspaceItem: String, CaseIterable, Hashable, Identifiable {
    case email = "Email"
    case calendar = "Calendar"
    case reminders = "Reminders"
    case notes = "Notes"
    case memory = "Memory"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .email: "envelope"
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .notes: "note.text"
        case .memory: "brain"
        }
    }
}

/// A hub listing the workspace features; selecting one pushes it. A single
/// stack (rather than a nested split view) keeps the chrome sane on every
/// platform — the app-level sidebar or tab bar is the only outer navigation.
struct WorkspaceView: View {
    var pendingEmailID: UUID?
    var onEmailPresented: () -> Void = {}

    @Query(sort: \Email.date, order: .reverse)
    private var emails: [Email]
    @AppStorage(SettingsKeys.emailEnabled) private var isEmailEnabled = SettingsStorage.defaultEmailEnabled

    @State private var navigationPath = NavigationPath()
    @State private var hasAppliedLaunchSelection = false

    private var visibleItems: [WorkspaceItem] {
        WorkspaceItem.allCases
    }

    private var widgetColumns: [GridItem] {
        #if os(iOS)
        [GridItem(.adaptive(minimum: 220), spacing: 16)]
        #else
        [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 16)]
        #endif
    }

    var body: some View {
        let emailSummary = WorkspaceEmailSummary(emails: emails)

        NavigationStack(path: $navigationPath) {
            ScrollView {
                LazyVGrid(
                    columns: widgetColumns,
                    alignment: .leading,
                    spacing: 16
                ) {
                    ForEach(visibleItems) { item in
                        NavigationLink(value: item) {
                            WorkspaceWidgetPanel(item: item, emailSummary: emailSummary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Workspace")
            .navigationDestination(for: WorkspaceItem.self) { item in
                destination(for: item)
                    .navigationTitle(item.rawValue)
            }
        }
        .onAppear(perform: prepareSelection)
        .onChange(of: pendingEmailID) { _, _ in
            prepareSelection()
        }
    }

    @ViewBuilder
    private func destination(for item: WorkspaceItem) -> some View {
        switch item {
        case .email:
            EmailView(
                pendingEmailID: pendingEmailID,
                openCompactThread: openEmailThread,
                onPendingEmailHandled: onEmailPresented
            )
        case .calendar:
            CalendarView()
        case .reminders:
            RemindersView()
        case .notes:
            NotesView()
        case .memory:
            MemoryView()
        }
    }

    private func prepareSelection() {
        #if DEBUG
        if !hasAppliedLaunchSelection,
           let requestedItem = ProcessInfo.processInfo.argumentValue(after: "-SwiftClawInitialWorkspaceItem"),
           let item = WorkspaceItem(launchArgument: requestedItem),
           visibleItems.contains(item) {
            hasAppliedLaunchSelection = true
            navigate(to: item)
            return
        }
        hasAppliedLaunchSelection = true
        #endif

        if pendingEmailID != nil, isEmailEnabled {
            navigate(to: .email)
        }
    }

    private func navigate(to item: WorkspaceItem) {
        var path = NavigationPath()
        path.append(item)
        navigationPath = path
    }

    private func openEmailThread(mailbox: EmailMailbox, threadID: UUID) {
        var path = NavigationPath()
        path.append(WorkspaceItem.email)
        path.append(mailbox)
        path.append(threadID)
        navigationPath = path
    }
}

#if DEBUG
private extension WorkspaceItem {
    init?(launchArgument: String) {
        switch launchArgument.lowercased().filter(\.isLetter) {
        case "email", "mail":
            self = .email
        case "calendar":
            self = .calendar
        case "reminder", "reminders":
            self = .reminders
        case "note", "notes":
            self = .notes
        case "memory":
            self = .memory
        default:
            return nil
        }
    }
}
#endif

#Preview {
    WorkspaceView()
}

private struct WorkspaceWidgetPanel: View {
    let item: WorkspaceItem
    let emailSummary: WorkspaceEmailSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: item.systemImage)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 28, height: 28)

                Text(item.rawValue)
                    .font(.headline)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }

            if item == .email {
                WorkspaceEmailStatsView(summary: emailSummary)
            } else {
                Text("Coming soon")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .padding(18)
        .glassEffect(in: .rect(cornerRadius: 16.0))
        .contentShape(.rect(cornerRadius: 16.0))
        .accessibilityElement(children: .combine)
    }
}

private struct WorkspaceEmailStatsView: View {
    let summary: WorkspaceEmailSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow(alignment: .firstTextBaseline) {
                    WorkspaceEmailStatTile(count: summary.unreadCount, label: "Unread")
                    WorkspaceEmailStatTile(count: summary.inboxThreadCount, label: "Inbox")
                }
                GridRow(alignment: .firstTextBaseline) {
                    WorkspaceEmailStatTile(count: summary.flaggedThreadCount, label: "Flagged")
                    WorkspaceEmailStatTile(count: summary.notatedThreadCount, label: "Notated")
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                if let reviewedAt = SettingsStorage.loadEmailLastReviewCompletedAt() {
                    Text("Reviewed \(Text(reviewedAt, style: .relative)) ago")
                }
                let nextReview = SettingsStorage.nextEmailReviewDate()
                if nextReview > .now {
                    Text("Next review in \(Text(nextReview, style: .relative))")
                } else {
                    Text("Review due")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct WorkspaceEmailStatTile: View {
    let count: Int
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(count, format: .number)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(count == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .gridColumnAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) \(label)")
    }
}
