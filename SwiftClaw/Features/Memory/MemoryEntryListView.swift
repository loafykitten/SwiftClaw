import SwiftData
import SwiftUI

/// The searchable entry list for one `MemorySection` — the middle column on
/// macOS, a pushed screen on iOS. Search goes through
/// `MemoryRepository.search` (the same seam the `search_memory` tool will
/// use) and is visibly labeled with what it covers ("Search All Memory" vs.
/// the collection name). Repository observation re-runs snapshot search when
/// a mutation lands through UI, chat tools, or a review service.
struct MemoryEntryListView: View {
    let section: MemorySection
    let repository: MemoryRepository
    /// macOS selection binding; nil on iOS, where rows push instead.
    var selectedEntryID: Binding<UUID?>?

    @Query(sort: \MemoryCollection.createdAt) private var collections: [MemoryCollection]

    @State private var searchText = ""
    @State private var aiCreatedOnly = false
    @State private var accessLevelFilter: MemoryCollection.AccessLevel?
    @State private var scopeFilter: MemoryRepository.ScopeFilter = .any
    @State private var entryPendingDeletion: MemoryEntry?
    @State private var isAddingEntry = false
    @State private var isEditingCollection = false
    @State private var isConfirmingCollectionDelete = false

    private static let recentLimit = 30

    private var currentCollection: MemoryCollection? {
        guard case .collection(let id) = section else { return nil }
        return collections.first { $0.id == id }
    }

    private var title: String {
        switch section {
        case .all: "All Memory"
        case .recent: "Recent"
        case .activity: "Activity"
        case .tag(let tag): "Tag: \(tag)"
        case .collection: currentCollection?.title ?? "Collection"
        }
    }

    private var isFiltering: Bool {
        aiCreatedOnly || accessLevelFilter != nil || scopeFilter != .any
    }

    private func visibleEntries(mutationGeneration: Int) -> [MemoryEntry] {
        // Reading the generation in `body` is the invalidation source; the
        // value itself is only a cache key for repository-backed snapshots.
        _ = mutationGeneration
        var filter = MemoryRepository.SearchFilter(
            accessLevel: accessLevelFilter,
            scope: scopeFilter,
            aiCreatedOnly: aiCreatedOnly
        )
        if case .tag(let tag) = section {
            filter.tags = [tag]
        }
        let limit: Int? = if case .recent = section { Self.recentLimit } else { nil }
        var results = repository.search(searchText, filter: filter, limit: limit)
        switch section {
        case .collection(let id):
            results = results.filter { $0.collection?.id == id }
        case .recent:
            break
        case .all, .tag, .activity:
            break
        }
        return results
    }

    var body: some View {
        let mutationGeneration = repository.mutationGeneration
        let visibleEntries = visibleEntries(mutationGeneration: mutationGeneration)
        // Deliberately staged with intermediate `let`s — one flat modifier
        // chain here exceeded the type checker's budget.
        let base = listContent(visibleEntries: visibleEntries)
            .searchable(text: $searchText, prompt: searchPrompt)
            .navigationTitle(title)
            .toolbar { toolbarContent }
        let withSheets = base
            .sheet(isPresented: $isAddingEntry) {
                MemoryEntryEditorSheet(
                    mode: .create(defaultCollection: currentCollection),
                    repository: repository,
                    collections: collections
                )
            }
            .sheet(isPresented: $isEditingCollection) {
                if let collection = currentCollection {
                    MemoryCollectionEditorSheet(mode: .edit(collection), repository: repository)
                }
            }
        return withSheets
            .confirmationDialog(
                "Delete this memory?",
                isPresented: isConfirmingEntryDelete,
                titleVisibility: .visible
            ) {
                Button("Delete Memory", role: .destructive) {
                    if let entry = entryPendingDeletion {
                        repository.deleteEntry(entry, actor: .user)
                    }
                    entryPendingDeletion = nil
                }
            } message: {
                Text("The entry is removed from memory. The activity feed keeps a record of what it said.")
            }
            .confirmationDialog(
                "Delete this collection?",
                isPresented: $isConfirmingCollectionDelete,
                titleVisibility: .visible
            ) {
                Button("Delete Collection", role: .destructive) {
                    if let collection = currentCollection {
                        try? repository.deleteCollection(collection, actor: .user)
                    }
                }
            } message: {
                collectionDeleteMessage
            }
            .onChange(of: section) { _, _ in
                // The macOS middle column keeps one identity across section
                // changes (see `MemoryView.middleColumn`), so clear the
                // search/filter state by hand — a query typed in one
                // collection must not silently constrain the next.
                searchText = ""
                aiCreatedOnly = false
                accessLevelFilter = nil
                scopeFilter = .any
            }
    }

    private func listContent(visibleEntries: [MemoryEntry]) -> some View {
        List(selection: selectionBinding) {
            if let collection = currentCollection {
                collectionHeader(collection)
            }
            if visibleEntries.isEmpty {
                emptyState
            }
            ForEach(visibleEntries) { entry in
                row(for: entry)
                    .tag(entry.id)
            }
        }
    }

    private var selectionBinding: Binding<UUID?> {
        selectedEntryID ?? .constant(nil)
    }

    private var isConfirmingEntryDelete: Binding<Bool> {
        Binding(
            get: { entryPendingDeletion != nil },
            set: { if !$0 { entryPendingDeletion = nil } }
        )
    }

    private var searchPrompt: Text {
        switch section {
        case .collection:
            Text("Search \(currentCollection?.title ?? "Collection")")
        default:
            Text("Search All Memory")
        }
    }

    private var collectionDeleteMessage: Text {
        switch currentCollection?.entries.count ?? 0 {
        case 0: Text("It has no entries. This can't be undone.")
        case 1: Text("Its 1 entry is deleted with it. This can't be undone.")
        case let count: Text("Its \(count) entries are deleted with it. This can't be undone.")
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for entry: MemoryEntry) -> some View {
        let showsCollection = currentCollection == nil
        Group {
            #if os(macOS)
            MemoryEntryRow(entry: entry, showsCollection: showsCollection)
            #else
            NavigationLink(value: MemoryEntryRoute(entryID: entry.id)) {
                MemoryEntryRow(entry: entry, showsCollection: showsCollection)
            }
            #endif
        }
        .contextMenu {
            Button(role: .destructive) {
                entryPendingDeletion = entry
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if SearchQuery.isActive(searchText) || isFiltering {
            ContentUnavailableView.search
        } else {
            ContentUnavailableView(
                "No Memories Yet",
                systemImage: "brain",
                description: Text("Facts you or the assistant save appear here.")
            )
        }
    }

    // MARK: - Collection header

    private func collectionHeader(_ collection: MemoryCollection) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    MemoryAccessBadge(accessLevel: collection.accessLevel)
                    if let scope = collection.scope {
                        MemoryChip(text: scope.displayName, systemImage: scope.systemImage)
                    }
                    if collection.isPinned {
                        MemoryChip(text: "Pinned", systemImage: "pin.fill")
                    }
                }
                if let details = collection.details, !details.isEmpty {
                    Text(details)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if !collection.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(collection.tags, id: \.self) { tag in
                            MemoryChip(text: tag)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            filterMenu
        }
        if let collection = currentCollection {
            ToolbarItem(placement: .automatic) {
                collectionMenu(collection)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                isAddingEntry = true
            } label: {
                Label("New Memory", systemImage: "plus")
            }
            .disabled(collections.isEmpty && currentCollection == nil)
            .accessibilityLabel("New Memory")
        }
    }

    private var filterMenu: some View {
        Menu {
            Toggle("Added by AI", isOn: $aiCreatedOnly)
            Picker("AI access", selection: $accessLevelFilter) {
                Text("Any Access").tag(MemoryCollection.AccessLevel?.none)
                ForEach(MemoryCollection.AccessLevel.allCases, id: \.self) { level in
                    Text(MemoryAccessPresentation.label(for: level)).tag(Optional(level))
                }
            }
            Picker("Scope", selection: $scopeFilter) {
                Text("Any Scope").tag(MemoryRepository.ScopeFilter.any)
                Text("Global").tag(MemoryRepository.ScopeFilter.global)
                ForEach(MemoryCollectionEditorSheet.scopeOptions) { feature in
                    Text(feature.displayName).tag(MemoryRepository.ScopeFilter.feature(feature))
                }
            }
        } label: {
            Label(
                "Filter",
                systemImage: isFiltering
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle"
            )
        }
        .accessibilityLabel(isFiltering ? "Filter memories, filters active" : "Filter memories")
    }

    private func collectionMenu(_ collection: MemoryCollection) -> some View {
        Menu {
            if !collection.isInbox {
                Button {
                    isEditingCollection = true
                } label: {
                    Label("Edit Collection", systemImage: "pencil")
                }
            }
            Button {
                repository.updateCollection(collection, isPinned: !collection.isPinned, actor: .user)
            } label: {
                Label(
                    collection.isPinned ? "Unpin" : "Pin",
                    systemImage: collection.isPinned ? "pin.slash" : "pin"
                )
            }
            if !collection.isInbox {
                Divider()
                Button(role: .destructive) {
                    isConfirmingCollectionDelete = true
                } label: {
                    Label("Delete Collection", systemImage: "trash")
                }
            }
        } label: {
            Label("Collection Actions", systemImage: "ellipsis.circle")
        }
        .accessibilityLabel("Collection actions")
    }
}
