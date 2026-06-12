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
    @AppStorage(SettingsKeys.accentHue) private var accentHue = AccentColor.defaultHue
    @AppStorage(SettingsKeys.accentBrightness) private var accentBrightness = AccentColor.defaultBrightness

    var body: some View {
        NavigationSplitView {
            List(NavigationItem.allCases, selection: $selectedNavigationItem) { item in
                Label(item.rawValue, systemImage: item.systemImage)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .listStyle(.sidebar)
            .listItemTint(AccentColor.color(hue: accentHue, brightness: accentBrightness))
        } detail: {
            if let item = selectedNavigationItem {
                item.destination
                    .navigationTitle(item.rawValue)
            } else {
                Text("Select an item")
            }
        }
    }
}

#Preview {
    ContentView()
}
