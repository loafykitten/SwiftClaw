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
    @State private var selectedNavigationItem: NavigationItem? = .home
    @State private var selectedChatID: UUID?
    @State private var pendingEmailViewID: UUID?
    @AppStorage(SettingsKeys.accentHue) private var accentHue = AccentColor.defaultHue
    @AppStorage(SettingsKeys.accentLightness) private var accentLightness = AccentColor.defaultLightness
    @AppStorage(SettingsKeys.emailEnabled) private var isEmailEnabled = SettingsStorage.defaultEmailEnabled

    /// Lazily-constructed email review dispatcher + its backing mail client.
    /// Built once on first use rather than per-render (the previous
    /// `destination(for: .chats)` allocated a fresh `SwiftMailClient` + dispatcher
    /// on every body evaluation).
    @State private var emailDispatcherState: EmailDispatcherCache? = EmailDispatcherCache()

    private var accent: Color {
        AccentColor.color(hue: accentHue, lightness: accentLightness)
    }

    private var visibleNavigationItems: [NavigationItem] {
        NavigationItem.allCases.filter { item in
            item != .email || isEmailEnabled
        }
    }

    var body: some View {
        NavigationSplitView {
            AccentSidebarList(
                items: visibleNavigationItems,
                selection: $selectedNavigationItem,
                accent: accent,
                title: { $0.rawValue },
                systemImage: { $0.systemImage }
            )
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            if let item = selectedNavigationItem, visibleNavigationItems.contains(item) {
                destination(for: item)
                    .navigationTitle(item.rawValue)
            } else {
                Text("Select an item")
            }
        }
        .tint(accent)
        .onChange(of: isEmailEnabled) { _, enabled in
            if !enabled, selectedNavigationItem == .email {
                selectedNavigationItem = .home
            }
            if enabled {
                EmailWorkflowManager.shared.start(modelContainer: modelContext.container)
            } else {
                EmailWorkflowManager.shared.stop()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .emailReviewChatCreated)) { note in
            if let chatID = note.userInfo?["chatID"] as? UUID {
                selectedChatID = chatID
                selectedNavigationItem = .chats
                // Auto-navigate is the badge-irrelevant path (no badge was
                // set when auto-navigate is on); `.emailReviewChatOpened`
                // below is posted by the `selectedNavigationItem` change.
            }
        }
        .onChange(of: selectedNavigationItem) { _, item in
            // The badge-clear fires whenever the user lands on Chats — covers
            // both the auto-navigate path above and the default config where
            // a badge was set but no auto-open happened (otherwise the badge
            // lingers until email is disabled / app quits).
            if item == .chats {
                NotificationCenter.default.post(name: .emailReviewChatOpened, object: nil)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .emailReviewViewEmail)) { note in
            if let emailID = note.userInfo?["emailID"] as? UUID {
                pendingEmailViewID = emailID
                selectedNavigationItem = .email
            }
        }
    }

    @MainActor @ViewBuilder
    private func destination(for item: NavigationItem) -> some View {
        switch item {
        case .home:
            HomeView { chatID in
                selectedChatID = chatID
                selectedNavigationItem = .chats
            }
        case .chats:
            ChatsView(
                selectedChatID: $selectedChatID,
                emailDispatcher: emailDispatcher(for: modelContext.container)
            )
        default:
            if item == .email {
                EmailView(pendingEmailID: pendingEmailViewID)
                    .onAppear { pendingEmailViewID = nil }
            } else {
                item.destination
            }
        }
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
