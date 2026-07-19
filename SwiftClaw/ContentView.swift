import SwiftUI
import SwiftData
#if os(iOS)
import UIKit
#endif

enum NavigationItem: String, CaseIterable, Identifiable {
    case home = "Home"
    case chats = "Chats"
    case workspace = "Workspace"
    case deepResearch = "Deep Research"
    case settings = "Settings"

    var id: String { rawValue }

    var navigationLabel: String {
        switch self {
        case .deepResearch: "Research"
        default: rawValue
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .chats: "bubble.left.and.bubble.right"
        case .workspace: "square.grid.2x2"
        case .deepResearch: "doc.text.magnifyingglass"
        case .settings: "gear"
        }
    }

    @MainActor @ViewBuilder
    var destination: some View {
        switch self {
        case .home: HomeView()
        case .chats: ChatsView()
        case .workspace: WorkspaceView()
        case .deepResearch: DeepResearchView()
        case .settings: SettingsView()
        }
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var router = AppRouter.shared
    @State private var isNotificationBridgeStarted = false
    @State private var backStack: [NavigationItem] = []
    @State private var forwardStack: [NavigationItem] = []
    @State private var hasAppliedLaunchNavigation = false
    /// Set right before a programmatic assignment so the `onChange` observer
    /// knows not to treat that assignment as a new user navigation.
    @State private var isUpdatingSelectionWithoutRecording = false
    @AppStorage(SettingsKeys.deepResearchEnabled)
    private var isDeepResearchEnabled = SettingsStorage.defaultDeepResearchEnabled
    @AppStorage(SettingsKeys.emailEnabled) private var isEmailEnabled = SettingsStorage.defaultEmailEnabled
    @AppStorage(SettingsKeys.calendarEnabled) private var isCalendarEnabled = SettingsStorage.defaultCalendarEnabled
    @AppStorage(SettingsKeys.remindersEnabled) private var isRemindersEnabled = SettingsStorage.defaultRemindersEnabled
    @AppStorage(SettingsKeys.notesEnabled) private var isNotesEnabled = SettingsStorage.defaultNotesEnabled

    /// Unread mail drives the Workspace badge the way `router.unreadChatIDs`
    /// drives the Chats badge. Same partition as the workspace widget's
    /// "Unread" tile so the two counts always agree.
    @Query(filter: #Predicate<Email> { !$0.isRead && !$0.isArchived && !$0.isDeleted })
    private var unreadEmails: [Email]

    /// Unviewed research sessions badge the Research tab; an active run also
    /// badges it (via the observed monitor) so a backgrounded run stays
    /// discoverable.
    @Query(filter: #Predicate<ResearchSession> { $0.isUnviewed })
    private var unviewedResearchSessions: [ResearchSession]
    @State private var researchMonitor = ResearchProgressMonitor.shared

    /// Lazily-constructed email review dispatcher + its backing mail client.
    /// Built once on first use rather than per-render (the previous
    /// `destination(for: .chats)` allocated a fresh `SwiftMailClient` + dispatcher
    /// on every body evaluation).
    @State private var emailDispatcherState: EmailDispatcherCache? = EmailDispatcherCache()
    /// Lazily-constructed note-proposal dispatcher, cached the same way as
    /// `emailDispatcherState` — see `noteProposalDispatcher(for:)`.
    @State private var noteProposalDispatcherState: NoteProposalDispatcherCache? = NoteProposalDispatcherCache()
    /// Lazily-constructed memory dispatchers (write-chip undo + proposal
    /// approval), cached the same way — see `memoryDispatchers(for:)`.
    @State private var memoryDispatcherState: MemoryDispatcherCache? = MemoryDispatcherCache()

    private var visibleNavigationItems: [NavigationItem] {
        NavigationItem.allCases.filter { item in
            if item == .deepResearch {
                return isDeepResearchEnabled
            }

            if item == .settings {
                #if os(iOS)
                return true
                #else
                return false
                #endif
            }

            return true
        }
    }

    private var unreadEmailCount: Int {
        isEmailEnabled ? unreadEmails.count : 0
    }

    private var compactNavigationItems: [NavigationItem] {
        [
            .home,
            .chats,
            .workspace,
            .deepResearch,
            .settings,
        ].filter { visibleNavigationItems.contains($0) }
    }

    var body: some View {
        appShell
            .toolbar {
                #if os(macOS)
                ToolbarItemGroup(placement: .navigation) {
                    Button("Back", systemImage: "chevron.left", action: goBack)
                        .disabled(!canGoBack)
                        .keyboardShortcut("[", modifiers: .command)
                    Button("Forward", systemImage: "chevron.right", action: goForward)
                        .disabled(!canGoForward)
                        .keyboardShortcut("]", modifiers: .command)
                }
                #endif
            }
            .onChange(of: isDeepResearchEnabled) { _, _ in
                pruneHiddenNavigationHistory()
                ensureVisibleNavigationSelection()
            }
            .onChange(of: isEmailEnabled) { _, enabled in
                pruneHiddenNavigationHistory()
                ensureVisibleNavigationSelection()
                if enabled {
                    EmailWorkflowManager.shared.start(modelContainer: modelContext.container)
                } else {
                    EmailWorkflowManager.shared.stop()
                }
            }
            .onChange(of: isCalendarEnabled) { _, enabled in
                if enabled {
                    CalendarSyncCoordinator.shared.start(modelContainer: modelContext.container)
                    CalendarAlertScheduler.shared.start(modelContainer: modelContext.container)
                    CalendarWorkflowManager.shared.start(modelContainer: modelContext.container)
                } else {
                    CalendarSyncCoordinator.shared.stop()
                    CalendarAlertScheduler.shared.stop()
                    CalendarAlertScheduler.shared.clearAllPendingAlerts()
                    CalendarWorkflowManager.shared.stop()
                }
            }
            .onChange(of: isRemindersEnabled) { _, enabled in
                if enabled {
                    ReminderSyncCoordinator.shared.start(modelContainer: modelContext.container)
                    ReminderAlertScheduler.shared.start(modelContainer: modelContext.container)
                    ReminderWorkflowManager.shared.start(modelContainer: modelContext.container)
                } else {
                    ReminderSyncCoordinator.shared.stop()
                    ReminderAlertScheduler.shared.stop()
                    ReminderAlertScheduler.shared.clearAllPendingAlerts()
                    ReminderWorkflowManager.shared.stop()
                }
                // Either direction moves the calendar between its shared and
                // standalone alert budgets.
                CalendarAlertScheduler.shared.settingsDidChange()
            }
            .onChange(of: isNotesEnabled) { _, enabled in
                if enabled {
                    NotesWorkflowManager.shared.start(modelContainer: modelContext.container)
                } else {
                    NotesWorkflowManager.shared.stop()
                }
            }
            .onAppear {
                applyLaunchNavigationIfNeeded()
                startNotificationBridge()
            }
            .onDisappear {
                stopNotificationBridge()
            }
            .environment(router)
            .onChange(of: router.selectedNavigationItem) { oldValue, item in
                recordNavigation(from: oldValue)
                if item == .chats { router.clearUnreadChatIfOpened() }
            }
            .onChange(of: router.selectedChatID) { _, _ in
                router.clearUnreadChatIfOpened()
            }
    }

    @ViewBuilder
    private var appShell: some View {
        #if os(iOS)
        if horizontalSizeClass == .compact {
            compactAppShell
        } else {
            splitAppShell
        }
        #else
        splitAppShell
        #endif
    }

    private var splitAppShell: some View {
        NavigationSplitView {
            SidebarList(
                items: visibleNavigationItems,
                selection: Binding(
                    get: { router.selectedNavigationItem },
                    set: { router.selectedNavigationItem = $0 }
                ),
                title: { $0.navigationLabel },
                systemImage: { $0.systemImage },
                showsBadge: {
                    ($0 == .chats && router.hasUnreadChats)
                        || ($0 == .workspace && unreadEmailCount > 0)
                        || ($0 == .deepResearch
                            && (researchMonitor.isRunning || !unviewedResearchSessions.isEmpty))
                }
            )
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            if let item = router.selectedNavigationItem, visibleNavigationItems.contains(item) {
                destination(for: item)
                    .navigationTitle(item.rawValue)
            } else {
                Text("Select an item")
            }
        }
    }

    @MainActor @ViewBuilder
    private func destination(for item: NavigationItem) -> some View {
        switch item {
        case .home:
            HomeView { chatID in
                router.selectChat(chatID)
            }
        case .chats:
            ChatsView(
                selectedChatID: Binding(
                    get: { router.selectedChatID },
                    set: { router.selectedChatID = $0 }
                ),
                emailDispatcher: emailDispatcher(for: modelContext.container),
                noteProposalDispatcher: noteProposalDispatcher(for: modelContext.container),
                memoryWriteDispatcher: memoryDispatchers(for: modelContext.container).write,
                memoryProposalDispatcher: memoryDispatchers(for: modelContext.container).proposal
            )
        case .workspace:
            WorkspaceView(
                pendingEmailID: router.pendingEmailViewID,
                onEmailPresented: router.clearPendingEmailView,
                pendingCalendarFocus: router.pendingCalendarFocus,
                onCalendarPresented: router.clearPendingCalendarFocus,
                pendingReminderFocusID: router.pendingReminderFocusID,
                onReminderPresented: router.clearPendingReminderFocus
            )
        default:
            item.destination
        }
    }

    private var canGoBack: Bool {
        backStack.contains { visibleNavigationItems.contains($0) }
    }

    private var canGoForward: Bool {
        forwardStack.contains { visibleNavigationItems.contains($0) }
    }

    private func recordNavigation(from oldValue: NavigationItem?) {
        guard !isUpdatingSelectionWithoutRecording else {
            isUpdatingSelectionWithoutRecording = false
            return
        }
        if let oldValue, visibleNavigationItems.contains(oldValue) {
            backStack.append(oldValue)
            forwardStack.removeAll()
        }
    }

    private func goBack() {
        while let previous = backStack.popLast() {
            guard visibleNavigationItems.contains(previous) else { continue }
            if let current = router.selectedNavigationItem, visibleNavigationItems.contains(current) {
                forwardStack.append(current)
            }
            isUpdatingSelectionWithoutRecording = true
            router.selectedNavigationItem = previous
            return
        }
    }

    private func goForward() {
        while let next = forwardStack.popLast() {
            guard visibleNavigationItems.contains(next) else { continue }
            if let current = router.selectedNavigationItem, visibleNavigationItems.contains(current) {
                backStack.append(current)
            }
            isUpdatingSelectionWithoutRecording = true
            router.selectedNavigationItem = next
            return
        }
    }

    private func pruneHiddenNavigationHistory() {
        backStack.removeAll { !visibleNavigationItems.contains($0) }
        forwardStack.removeAll { !visibleNavigationItems.contains($0) }
    }

    private func ensureVisibleNavigationSelection() {
        guard !visibleNavigationItems.isEmpty else { return }
        if let item = router.selectedNavigationItem, visibleNavigationItems.contains(item) {
            return
        }
        isUpdatingSelectionWithoutRecording = true
        router.selectedNavigationItem = .home
    }

    private func applyLaunchNavigationIfNeeded() {
        #if DEBUG
        guard !hasAppliedLaunchNavigation else { return }
        hasAppliedLaunchNavigation = true

        guard let requestedItem = ProcessInfo.processInfo.argumentValue(after: "-SwiftClawInitialNavigationItem"),
              let item = NavigationItem(launchArgument: requestedItem),
              visibleNavigationItems.contains(item) else { return }

        isUpdatingSelectionWithoutRecording = true
        router.selectedNavigationItem = item
        #else
        hasAppliedLaunchNavigation = true
        #endif
    }

    /// Returns a cached `EmailReviewActionDispatcher`. Allocating on every
    /// render was wasteful; the dispatcher now resolves the per-email account
    /// lazily via `EmailAccountStore`, so it no longer holds a `MailClient`.
    @MainActor
    private func emailDispatcher(for container: ModelContainer) -> AnyHashableReviewActionDispatcher {
        if let existing = emailDispatcherState?.dispatcher {
            return existing
        }
        let dispatcher = AnyHashableReviewActionDispatcher(
            EmailReviewActionDispatcher(modelContainer: container)
        )
        emailDispatcherState?.dispatcher = dispatcher
        return dispatcher
    }

    /// Returns a cached `NoteProposalDispatcher` — same rationale as
    /// `emailDispatcher(for:)`, and deliberately a distinct instance so
    /// note-proposal actions never share a dispatcher with email review
    /// actions.
    @MainActor
    private func noteProposalDispatcher(for container: ModelContainer) -> AnyHashableReviewActionDispatcher {
        if let existing = noteProposalDispatcherState?.dispatcher {
            return existing
        }
        let dispatcher = AnyHashableReviewActionDispatcher(
            NoteProposalDispatcher(modelContainer: container)
        )
        noteProposalDispatcherState?.dispatcher = dispatcher
        return dispatcher
    }

    /// Returns the cached memory dispatchers — same rationale as
    /// `emailDispatcher(for:)`; two distinct instances because `.memoryWrite`
    /// (chip undo) and `.memoryProposal` (approval) are separate card types
    /// with separate action surfaces.
    @MainActor
    private func memoryDispatchers(
        for container: ModelContainer
    ) -> (write: AnyHashableReviewActionDispatcher, proposal: AnyHashableReviewActionDispatcher) {
        if let write = memoryDispatcherState?.writeDispatcher,
           let proposal = memoryDispatcherState?.proposalDispatcher {
            return (write, proposal)
        }
        let write = AnyHashableReviewActionDispatcher(MemoryWriteDispatcher())
        let proposal = AnyHashableReviewActionDispatcher(
            MemoryProposalDispatcher(modelContainer: container)
        )
        memoryDispatcherState?.writeDispatcher = write
        memoryDispatcherState?.proposalDispatcher = proposal
        return (write, proposal)
    }

    private func startNotificationBridge() {
        guard !isNotificationBridgeStarted else { return }
        isNotificationBridgeStarted = true
        router.startNotificationBridge()
    }

    private func stopNotificationBridge() {
        guard isNotificationBridgeStarted else { return }
        isNotificationBridgeStarted = false
        router.stopNotificationBridge()
    }
}

#if os(iOS)
// MARK: - Compact (iOS) shell
extension ContentView {
    private var compactAppShell: some View {
        TabView(
            selection: Binding(
                get: { router.selectedNavigationItem ?? .home },
                set: { router.selectedNavigationItem = $0 }
            )
        ) {
            ForEach(compactNavigationItems) { item in
                compactDestination(for: item)
                    .tabItem {
                        Label(item.navigationLabel, systemImage: item.systemImage)
                    }
                    .badge(tabBadgeCount(for: item))
                    .tag(item)
            }
        }
        .onAppear(perform: ensureVisibleNavigationSelection)
    }

    private func tabBadgeCount(for item: NavigationItem) -> Int {
        switch item {
        case .chats: router.unreadChatIDs.count
        case .workspace: unreadEmailCount
        // An active run keeps the tab badged even with nothing unviewed yet,
        // matching the sidebar dot.
        case .deepResearch: max(unviewedResearchSessions.count, researchMonitor.isRunning ? 1 : 0)
        default: 0
        }
    }

    /// Home fills the screen with its own chrome; Chats, Workspace, and
    /// Settings manage their own `NavigationStack` (they push
    /// programmatically). Every tab now manages its own `NavigationStack`
    /// (Research joined so notification taps can push programmatically) —
    /// nesting stacks breaks safe-area and transition behavior, so none is
    /// added here.
    @ViewBuilder
    private func compactDestination(for item: NavigationItem) -> some View {
        destination(for: item)
    }
}
#endif

/// Tiny mutable holder so a `@State`-backed view can cache the dispatcher
/// without rebuilding it on each render.
@MainActor
private final class EmailDispatcherCache {
    var dispatcher: AnyHashableReviewActionDispatcher?
}

/// Tiny mutable holder so a `@State`-backed view can cache the note-proposal
/// dispatcher without rebuilding it on each render — see `EmailDispatcherCache`.
@MainActor
private final class NoteProposalDispatcherCache {
    var dispatcher: AnyHashableReviewActionDispatcher?
}

/// Holder for both memory dispatchers — see `NoteProposalDispatcherCache`.
@MainActor
private final class MemoryDispatcherCache {
    var writeDispatcher: AnyHashableReviewActionDispatcher?
    var proposalDispatcher: AnyHashableReviewActionDispatcher?
}

#if DEBUG
private extension NavigationItem {
    init?(launchArgument: String) {
        switch launchArgument.lowercased().filter(\.isLetter) {
        case "home":
            self = .home
        case "chat", "chats":
            self = .chats
        case "workspace":
            self = .workspace
        case "deepresearch", "research":
            self = .deepResearch
        case "setting", "settings":
            self = .settings
        default:
            return nil
        }
    }
}

extension ProcessInfo {
    func argumentValue(after name: String) -> String? {
        guard let index = arguments.firstIndex(of: name) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard arguments.indices.contains(valueIndex) else { return nil }
        return arguments[valueIndex]
    }
}
#endif

#Preview {
    ContentView()
}
