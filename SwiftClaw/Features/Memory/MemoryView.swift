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

/// Tag JSON is decoded once per repository mutation generation. All Memory
/// writes share that signal, including writes originating outside this view.
@MainActor
private final class MemoryTagIndexCache {
    private var generation = -1
    private var cachedTags: [String] = []

    func tags(
        for generation: Int,
        collections: [MemoryCollection],
        repository: MemoryRepository
    ) -> [String] {
        guard generation != self.generation else { return cachedTags }
        var tags = Set<String>()
        for collection in collections { tags.formUnion(collection.tags) }
        for entry in repository.allEntries() { tags.formUnion(entry.tags) }
        cachedTags = tags.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        self.generation = generation
        return cachedTags
    }
}

/// The Memory root: macOS three-column (sidebar › entry list › detail), iOS
/// stacked (landing › section list › entry detail) — pushed onto Workspace's
/// ambient `NavigationStack` like the other features, per the
/// `EmailView.compactThreadLayout` / `NotesView` precedent.
struct MemoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MemoryCollection.createdAt) private var collections: [MemoryCollection]

    @State private var section: MemorySection? = .all
    @State private var selectedEntryID: UUID?
    @State private var isCreatingCollection = false
    @State private var tagIndexCache = MemoryTagIndexCache()

    /// The shared repository (so mutations bump the prompt builder's
    /// generation) with a local fallback for previews, where `AppBootstrap`
    /// never configured `MemoryFeatureModel.shared`.
    private var repository: MemoryRepository {
        MemoryFeatureModel.shared.repository ?? MemoryRepository(modelContext: modelContext)
    }

    var body: some View {
        let repository = repository
        let mutationGeneration = repository.mutationGeneration
        let pinnedCollections = collections.filter(\.isPinned)
        // Inbox surfaces first among the unpinned collections.
        let unpinnedCollections = collections.filter { !$0.isPinned }
            .sorted { ($0.isInbox ? 0 : 1, $0.createdAt) < ($1.isInbox ? 0 : 1, $1.createdAt) }
        let allTags = tagIndexCache.tags(
            for: mutationGeneration,
            collections: collections,
            repository: repository
        )
        return platformBody(
            repository: repository,
            pinnedCollections: pinnedCollections,
            unpinnedCollections: unpinnedCollections,
            allTags: allTags
        )
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
    private func platformBody(
        repository: MemoryRepository,
        pinnedCollections: [MemoryCollection],
        unpinnedCollections: [MemoryCollection],
        allTags: [String]
    ) -> some View {
        HSplitView {
            sidebar(
                pinnedCollections: pinnedCollections,
                unpinnedCollections: unpinnedCollections,
                allTags: allTags
            )
                .frame(minWidth: 210, idealWidth: 240, maxWidth: 300)
            middleColumn(repository: repository)
                .frame(minWidth: 320, idealWidth: 400)
            detailColumn(repository: repository)
                .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func sidebar(
        pinnedCollections: [MemoryCollection],
        unpinnedCollections: [MemoryCollection],
        allTags: [String]
    ) -> some View {
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
    private func middleColumn(repository: MemoryRepository) -> some View {
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
    private func detailColumn(repository: MemoryRepository) -> some View {
        if section == .activity {
            emptyColumn("Memory changes are listed in the feed")
        } else if let selectedEntryID,
                  let entry = repository.entry(id: selectedEntryID) {
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
    private func platformBody(
        repository: MemoryRepository,
        pinnedCollections: [MemoryCollection],
        unpinnedCollections: [MemoryCollection],
        allTags: [String]
    ) -> some View {
        landingList(
            pinnedCollections: pinnedCollections,
            unpinnedCollections: unpinnedCollections,
            allTags: allTags
        )
            .navigationDestination(for: MemorySection.self) { section in
                if section == .activity {
                    MemoryActivityFeedView()
                } else {
                    MemoryEntryListView(section: section, repository: repository)
                }
            }
            .navigationDestination(for: MemoryEntryRoute.self) { route in
                if let entry = repository.entry(id: route.entryID) {
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

    private func landingList(
        pinnedCollections: [MemoryCollection],
        unpinnedCollections: [MemoryCollection],
        allTags: [String]
    ) -> some View {
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
