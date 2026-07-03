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

    @AppStorage(SettingsKeys.emailEnabled) private var isEmailEnabled = SettingsStorage.defaultEmailEnabled

    @State private var navigationPath = NavigationPath()
    @State private var hasAppliedLaunchSelection = false

    private var visibleItems: [WorkspaceItem] {
        WorkspaceItem.allCases
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List(visibleItems) { item in
                NavigationLink(value: item) {
                    Label(item.rawValue, systemImage: item.systemImage)
                }
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
