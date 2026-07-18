import SwiftData
import SwiftUI

/// One navigable destination inside Memory. The macOS sidebar selects one;
/// iOS pushes one onto Workspace's ambient `NavigationStack`.
nonisolated enum MemorySection: Hashable {
    case all
    case recent
    case activity
    case tag(String)
    case collection(UUID)
}

/// Distinct route type for pushing an entry on iOS, so Memory's
/// `navigationDestination` registrations can't collide with other features'
/// `UUID`-typed destinations on the shared Workspace stack.
nonisolated struct MemoryEntryRoute: Hashable {
    let entryID: UUID
}

/// The Memory root: macOS three-column (sidebar › entry list › detail), iOS
/// stacked (landing › section list › entry detail) — pushed onto Workspace's
/// ambient `NavigationStack` like the other features, per the
/// `EmailView.compactThreadLayout` / `NotesView` precedent.
struct MemoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MemoryCollection.createdAt) private var collections: [MemoryCollection]
    @Query(sort: \MemoryEntry.updatedAt, order: .reverse) private var entries: [MemoryEntry]

    @State private var section: MemorySection? = .all
    @State private var selectedEntryID: UUID?
    @State private var isCreatingCollection = false

    /// The shared repository (so mutations bump the prompt builder's
    /// generation) with a local fallback for previews, where `AppBootstrap`
    /// never configured `MemoryFeatureModel.shared`.
    private var repository: MemoryRepository {
        MemoryFeatureModel.shared.repository ?? MemoryRepository(modelContext: modelContext)
    }

    private var pinnedCollections: [MemoryCollection] {
        collections.filter(\.isPinned)
    }

    private var unpinnedCollections: [MemoryCollection] {
        // Inbox surfaces first among the unpinned collections.
        collections.filter { !$0.isPinned }
            .sorted { ($0.isInbox ? 0 : 1, $0.createdAt) < ($1.isInbox ? 0 : 1, $1.createdAt) }
    }

    /// Every distinct tag across collections and entries, for the sidebar's
    /// tag shortcuts.
    private var allTags: [String] {
        var tags = Set<String>()
        for collection in collections { tags.formUnion(collection.tags) }
        for entry in entries { tags.formUnion(entry.tags) }
        return tags.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var body: some View {
        platformBody
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        isCreatingCollection = true
                    } label: {
                        Label("New Collection", systemImage: "folder.badge.plus")
                    }
                    .accessibilityLabel("New Collection")
                }
            }
            .sheet(isPresented: $isCreatingCollection) {
                MemoryCollectionEditorSheet(mode: .create, repository: repository)
            }
            .task {
                guard !ProcessInfo.processInfo.isRunningInPreview else { return }
                repository.ensureInbox()
            }
    }

    // MARK: - macOS three-column layout

    #if os(macOS)
    private var platformBody: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 210, idealWidth: 240, maxWidth: 300)
            middleColumn
                .frame(minWidth: 320, idealWidth: 400)
            detailColumn
                .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sidebar: some View {
        List(selection: $section) {
            Section {
                Label("All Memory", systemImage: "brain")
                    .tag(MemorySection.all)
                Label("Recent", systemImage: "clock")
                    .tag(MemorySection.recent)
                Label("Activity", systemImage: "clock.arrow.circlepath")
                    .tag(MemorySection.activity)
            }
            if !pinnedCollections.isEmpty {
                Section("Pinned") {
                    ForEach(pinnedCollections) { collection in
                        MemoryCollectionRow(collection: collection, compact: true)
                            .tag(MemorySection.collection(collection.id))
                    }
                }
            }
            Section("Collections") {
                ForEach(unpinnedCollections) { collection in
                    MemoryCollectionRow(collection: collection, compact: true)
                        .tag(MemorySection.collection(collection.id))
                }
            }
            if !allTags.isEmpty {
                Section("Tags") {
                    ForEach(allTags, id: \.self) { tag in
                        Label(tag, systemImage: "number")
                            .tag(MemorySection.tag(tag))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: section) { _, _ in
            selectedEntryID = nil
        }
    }

    @ViewBuilder
    private var middleColumn: some View {
        switch section {
        case .activity:
            MemoryActivityFeedView()
        case .none:
            emptyColumn("Select a collection")
        case .some(let section):
            // No `.id(section)` here: forcing a new identity per section
            // tears down and re-inserts the window toolbar in one update,
            // which NSToolbar rejects with an uncaught exception (crash on
            // every section change). The list resets its own search/filter
            // state in `.onChange(of: section)` instead.
            MemoryEntryListView(
                section: section,
                repository: repository,
                selectedEntryID: $selectedEntryID
            )
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if section == .activity {
            emptyColumn("Memory changes are listed in the feed")
        } else if let selectedEntryID,
                  let entry = entries.first(where: { $0.id == selectedEntryID }) {
            MemoryEntryDetailView(entry: entry, repository: repository)
        } else {
            emptyColumn("Select a memory")
        }
    }

    private func emptyColumn(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - iOS stacked layout

    #else
    private var platformBody: some View {
        landingList
            .navigationDestination(for: MemorySection.self) { section in
                if section == .activity {
                    MemoryActivityFeedView()
                } else {
                    MemoryEntryListView(section: section, repository: repository)
                }
            }
            .navigationDestination(for: MemoryEntryRoute.self) { route in
                if let entry = entries.first(where: { $0.id == route.entryID }) {
                    MemoryEntryDetailView(entry: entry, repository: repository)
                } else {
                    ContentUnavailableView(
                        "Memory Deleted",
                        systemImage: "brain",
                        description: Text("This entry no longer exists.")
                    )
                }
            }
    }

    private var landingList: some View {
        List {
            Section {
                NavigationLink(value: MemorySection.all) {
                    Label("All Memory", systemImage: "brain")
                }
                NavigationLink(value: MemorySection.recent) {
                    Label("Recent", systemImage: "clock")
                }
                NavigationLink(value: MemorySection.activity) {
                    Label("Activity", systemImage: "clock.arrow.circlepath")
                }
            }
            if !pinnedCollections.isEmpty {
                Section("Pinned") {
                    ForEach(pinnedCollections) { collection in
                        NavigationLink(value: MemorySection.collection(collection.id)) {
                            MemoryCollectionRow(collection: collection)
                        }
                    }
                }
            }
            Section("Collections") {
                ForEach(unpinnedCollections) { collection in
                    NavigationLink(value: MemorySection.collection(collection.id)) {
                        MemoryCollectionRow(collection: collection)
                    }
                }
            }
            if !allTags.isEmpty {
                Section("Tags") {
                    ForEach(allTags, id: \.self) { tag in
                        NavigationLink(value: MemorySection.tag(tag)) {
                            Label(tag, systemImage: "number")
                        }
                    }
                }
            }
        }
    }
    #endif
}
