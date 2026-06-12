import SwiftUI

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
    @State private var selectedNavigationItem: NavigationItem? = .home
    @State private var selectedChatID: UUID?
    @AppStorage(SettingsKeys.accentHue) private var accentHue = AccentColor.defaultHue
    @AppStorage(SettingsKeys.accentLightness) private var accentLightness = AccentColor.defaultLightness

    private var accent: Color {
        AccentColor.color(hue: accentHue, lightness: accentLightness)
    }

    var body: some View {
        NavigationSplitView {
            AccentSidebarList(
                items: NavigationItem.allCases,
                selection: $selectedNavigationItem,
                accent: accent,
                title: { $0.rawValue },
                systemImage: { $0.systemImage }
            )
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            if let item = selectedNavigationItem {
                destination(for: item)
                    .navigationTitle(item.rawValue)
            } else {
                Text("Select an item")
            }
        }
        .tint(accent)
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
            ChatsView(selectedChatID: $selectedChatID)
        default:
            item.destination
        }
    }
}

#Preview {
    ContentView()
}
