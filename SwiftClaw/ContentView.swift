import SwiftUI
import SwiftData

enum NavigationItem: String, CaseIterable, Identifiable {
    case home = "Home"
    case chats = "Chats"
    case deepResearch = "Deep Research"
    case email = "Email"
    case calendar = "Calendar"
    case reminders = "Reminders"
    case notes = "Notes"
    case memory = "Memory"
    case tools = "Tools"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .chats: "bubble.left.and.bubble.right"
        case .deepResearch: "magnifyingglass"
        case .email: "envelope"
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .notes: "note.text"
        case .memory: "brain"
        case .tools: "wrench.and.screwdriver"
        }
    }

    @MainActor @ViewBuilder
    var destination: some View {
        switch self {
        case .home: HomeView()
        case .chats: ChatsView()
        case .deepResearch: DeepResearchView()
        case .email: EmailView()
        case .calendar: CalendarView()
        case .reminders: RemindersView()
        case .notes: NotesView()
        case .memory: MemoryView()
        case .tools: ToolsView()
        }
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var router = AppRouter.shared
    @State private var isNotificationBridgeStarted = false
    @State private var backStack: [NavigationItem] = []
    @State private var forwardStack: [NavigationItem] = []
    /// Set right before a programmatic assignment so the `onChange` observer
    /// knows not to treat that assignment as a new user navigation.
    @State private var isUpdatingSelectionWithoutRecording = false
    @AppStorage(SettingsKeys.emailEnabled) private var isEmailEnabled = SettingsStorage.defaultEmailEnabled

    /// Lazily-constructed email review dispatcher + its backing mail client.
    /// Built once on first use rather than per-render (the previous
    /// `destination(for: .chats)` allocated a fresh `SwiftMailClient` + dispatcher
    /// on every body evaluation).
    @State private var emailDispatcherState: EmailDispatcherCache? = EmailDispatcherCache()

    private var visibleNavigationItems: [NavigationItem] {
        NavigationItem.allCases.filter { item in
            item != .email || isEmailEnabled
        }
    }

    var body: some View {
        NavigationSplitView {
            SidebarList(
                items: visibleNavigationItems,
                selection: Binding(
                    get: { router.selectedNavigationItem },
                    set: { router.selectedNavigationItem = $0 }
                ),
                title: { $0.rawValue },
                systemImage: { $0.systemImage },
                showsBadge: { $0 == .chats && router.hasUnreadChats }
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
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button("Back", systemImage: "chevron.left", action: goBack)
                    .disabled(!canGoBack)
                    .keyboardShortcut("[", modifiers: .command)
                Button("Forward", systemImage: "chevron.right", action: goForward)
                    .disabled(!canGoForward)
                    .keyboardShortcut("]", modifiers: .command)
            }
        }
        .onChange(of: isEmailEnabled) { _, enabled in
            pruneHiddenNavigationHistory()
            if !enabled, router.selectedNavigationItem == .email {
                isUpdatingSelectionWithoutRecording = true
                router.selectedNavigationItem = .home
            }
            if enabled {
                EmailWorkflowManager.shared.start(modelContainer: modelContext.container)
            } else {
                EmailWorkflowManager.shared.stop()
            }
        }
        .onAppear(perform: startNotificationBridge)
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
                emailDispatcher: emailDispatcher(for: modelContext.container)
            )
        default:
            if item == .email {
                EmailView(pendingEmailID: router.pendingEmailViewID)
                    .onAppear { router.clearPendingEmailView() }
            } else {
                item.destination
            }
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

/// Tiny mutable holder so a `@State`-backed view can cache the dispatcher
/// without rebuilding it on each render.
@MainActor
private final class EmailDispatcherCache {
    var dispatcher: AnyHashableReviewActionDispatcher?
}

#Preview {
    ContentView()
}
