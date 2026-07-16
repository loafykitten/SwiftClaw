import SwiftUI

private struct NoteRevisionsTarget: Identifiable {
    let path: String
    var id: String { path }
}

struct NotesView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var model = NotesFeatureModel.shared
    @AppStorage(SettingsKeys.notesHasCompletedOnboarding) private var hasCompletedOnboarding = false
    @State private var isShowingOnboarding = false
    @State private var searchText = ""
    @State private var isReadingMode = false
    @State private var isShowingQuickSwitcher = false
    @State private var isShowingQuickCapture = false
    @State private var isShowingInspector = false
    @State private var isShowingHealthDetail = false
    @State private var revisionsTarget: NoteRevisionsTarget?
    @State private var compactActionDestination: CompactActionDestination?
    /// The detail currently visible in compact navigation. This is deliberately
    /// lifecycle-owned rather than derived from `model.selectedPath`: a model
    /// selection can be in flight, rejected while a save is pending, or still
    /// loading when the navigation stack has already presented a destination.
    @State private var compactDetailPath: String?
    /// Unlike `compactDetailPath`, this records only the latest selection
    /// attempt made by a presented compact detail. It deliberately does not
    /// drive navigation: `selectedPath` remains model-owned, so a rejected
    /// save/selection cannot create a destination loop.
    @State private var compactDetailSelectionAttempt: CompactDetailSelectionAttempt?

    var body: some View {
        notesContent
    }

    private var notesContent: some View {
        Group {
            switch model.configurationState {
            case .unknown:
                ProgressView("Loading Notes…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .needsOnboarding:
                needsOnboardingView
            case .configured:
                configuredSplitView
            }
        }
        .task { await model.activate() }
        .onDisappear {
            model.deactivate()
        }
        .onAppear {
            if !hasCompletedOnboarding {
                isShowingOnboarding = true
            }
        }
        .sheet(isPresented: $isShowingOnboarding) {
            onboardingSheet
        }
        .sheet(isPresented: $isShowingQuickSwitcher) {
            quickSwitcherSheet
        }
        .sheet(isPresented: $isShowingQuickCapture) {
            NotesQuickCaptureSheet(model: model, onCaptured: handleQuickCapture)
        }
        .sheet(isPresented: $isShowingHealthDetail) {
            healthDetailSheet
        }
        .sheet(item: $revisionsTarget) { target in
            NoteRevisionsSheet(relativePath: target.path, model: model) {
                revisionsTarget = nil
            }
        }
    }

    private var onboardingSheet: some View {
        NotesOnboardingSheet(model: model)
    }

    private var quickSwitcherSheet: some View {
        NotesQuickSwitcher(
            model: model,
            onSelectPath: compactSelectionHandler
        ) {
            isShowingQuickSwitcher = false
        }
    }

    private var healthDetailSheet: some View {
        NotesHealthDetailSheet(
            model: model,
            onSelectPath: compactSelectionHandler
        ) {
            isShowingHealthDetail = false
        }
    }

    private var needsOnboardingView: some View {
        VStack(spacing: 12) {
            Image(systemName: "note.text")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Set Up Notes")
                .font(.headline)
            if let message = model.lastConfigurationError?.errorDescription {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Button("Choose a Vault…") {
                isShowingOnboarding = true
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var configuredSplitView: some View {
        #if os(macOS)
        // A third `HSplitView` pane, not `.inspector(isPresented:)`: that
        // modifier is designed to pair with `NavigationSplitView` and
        // computes its trailing-panel geometry against that container's own
        // layout math. Paired with this custom `HSplitView` instead, it was
        // rendering the panel outside the window's actual bounds (unusable/
        // offscreen at normal and larger window sizes) rather than
        // participating in the same resizable split the list/detail panes
        // already use.
        HSplitView {
            listColumn
                .frame(minWidth: 220, idealWidth: 280, maxWidth: 360)

            detailColumn
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)

            if isShowingInspector {
                BacklinksPanel(model: model)
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            }
        }
        .toolbar { splitToolbar }
        #else
        if horizontalSizeClass == .compact {
            // `NotesView` is itself pushed onto Workspace's own
            // `NavigationStack` (see `WorkspaceView`). Nesting a two-column
            // `NavigationSplitView` inside that ambient stack left the whole
            // screen blank on a compact iPhone — its list/detail column
            // never settled on a visible column — the same class of bug the
            // macOS split previously hit nesting inside `ContentView`'s
            // outer `NavigationSplitView`. `EmailView.compactThreadLayout`
            // already established the fix for this app: on compact, push
            // plain `List`s onto the ambient stack via
            // `.navigationDestination(for:)` instead of embedding another
            // split/stack container.
            compactListColumn
        } else {
            NavigationSplitView {
                listColumn
            } detail: {
                detailColumn
            }
            .inspector(isPresented: $isShowingInspector) {
                BacklinksPanel(model: model)
            }
            .toolbar { splitToolbar }
        }
        #endif
    }

    @ToolbarContentBuilder
    private var splitToolbar: some ToolbarContent {
        #if os(macOS)
        ToolbarItem(placement: .automatic) {
            NotesQuickCaptureControl(model: model, onCaptured: handleQuickCapture)
                .frame(width: 290)
        }
        #else
        ToolbarItem(placement: .automatic) {
            Button {
                isShowingQuickCapture = true
            } label: {
                Label("Quick Capture", systemImage: "bolt.fill")
            }
            .accessibilityIdentifier("notes.quickCapture.open")
        }
        #endif
        if model.selectedPath != nil {
            ToolbarItem(placement: .automatic) {
                Button {
                    isReadingMode.toggle()
                } label: {
                    Label(isReadingMode ? "Edit" : "Read", systemImage: isReadingMode ? "pencil" : "book")
                }
                .keyboardShortcut("e", modifiers: .command)
                .accessibilityLabel(isReadingMode ? "Switch to Edit mode" : "Switch to Reading mode")
            }
        }
        if let selectedPath = model.selectedPath {
            ToolbarItem(placement: .automatic) {
                Button {
                    revisionsTarget = NoteRevisionsTarget(path: selectedPath)
                } label: {
                    Label("Revisions", systemImage: "clock.arrow.circlepath")
                }
                .accessibilityLabel("Show revisions for \(NoteSummary.title(forRelativePath: selectedPath))")
            }
        }
        ToolbarItem(placement: .automatic) {
            Button {
                isShowingQuickSwitcher = true
            } label: {
                Label("Quick Switcher", systemImage: "arrow.right.doc.on.clipboard")
            }
            .keyboardShortcut("o", modifiers: .command)
            .accessibilityLabel("Open quick switcher")
        }
        ToolbarItem(placement: .automatic) {
            Button {
                isShowingInspector.toggle()
            } label: {
                Label("Backlinks", systemImage: "sidebar.trailing")
            }
            .accessibilityLabel(isShowingInspector ? "Hide backlinks inspector" : "Show backlinks inspector")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await model.createNote() }
            } label: {
                Label("New Note", systemImage: "square.and.pencil")
            }
            .accessibilityLabel("New Note")
        }
    }

    #if !os(macOS)
    /// Compact-width iPhone layout: a flat list pushed onto Workspace's
    /// ambient `NavigationStack`, mirroring `EmailView.compactThreadLayout`.
    /// Shares the same loading/error/empty/health-banner states as
    /// `listColumn` — only the row navigation idiom differs (`NavigationLink`
    /// push vs. `List(selection:)`).
    @ViewBuilder
    private var compactListColumn: some View {
        VStack(spacing: 0) {
            if let banner = model.healthSummary.flatMap(NotesHealthPresentation.banner) {
                healthBanner(banner)
            }
            if let error = model.lastListError {
                listErrorBanner(error)
            }
            Group {
                if !searchText.isEmpty {
                    compactSearchResultsList
                } else if let repository = model.repository, repository.isLoading, repository.notes.isEmpty {
                    ProgressView("Loading notes…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let repository = model.repository,
                           model.notes.isEmpty,
                          let error = repository.lastError {
                    errorListState(error)
                } else if model.notes.isEmpty {
                    emptyListState
                } else {
                    List(model.notes) { note in
                        NavigationLink(value: note.relativePath) {
                            noteRow(note)
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search notes")
        .onChange(of: searchText) { _, newValue in
            model.setSearchQuery(newValue)
        }
        .navigationTitle("Notes")
        .navigationDestination(for: String.self) { path in
            compactDetail(path: path)
        }
        .navigationDestination(item: $compactActionDestination) { destination in
            compactDetail(path: destination.path)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    isShowingQuickCapture = true
                } label: {
                    Label("Quick Capture", systemImage: "bolt.fill")
                }
                .accessibilityIdentifier("notes.quickCapture.open")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    isShowingQuickSwitcher = true
                } label: {
                    Label("Quick Switcher", systemImage: "arrow.right.doc.on.clipboard")
                }
                .keyboardShortcut("o", modifiers: .command)
                .accessibilityLabel("Open quick switcher")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    createNoteFromCurrentLayout()
                } label: {
                    Label("New Note", systemImage: "square.and.pencil")
                }
                .accessibilityLabel("New Note")
            }
        }
    }

    @ViewBuilder
    private var compactSearchResultsList: some View {
        if model.isSearching, model.searchResults.isEmpty {
            ProgressView("Searching…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.searchError {
            FeaturePlaceholderView(
                systemImage: "exclamationmark.triangle",
                title: "Search Failed",
                message: error.errorDescription ?? "An unknown error occurred."
            )
            .accessibilityLabel("Search failed: \(error.errorDescription ?? "An unknown error occurred.")")
        } else if model.searchResults.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("No matches")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(model.searchResults, id: \.chunk.id) { hit in
                NavigationLink(value: hit.document.sourceID) {
                    searchHitRow(hit)
                }
            }
        }
    }

    @ViewBuilder
    private func compactDetail(path: String) -> some View {
        Group {
            // A navigation push can appear before `select(path:)` has saved
            // the prior note and loaded this one. Do not give the shared
            // editor a new label until both layers agree on its path; doing
            // so could otherwise show note A's buffer as note B.
            if model.selectedPath == path,
               let editor = model.editor,
               editor.selectedPath == path {
                NoteEditorDetailView(editor: editor, notePath: path, model: model, isReadingMode: isReadingMode)
            } else if compactDetailSelectionAttempt?.path != path
                        || compactDetailSelectionAttempt?.state == .pending {
                ProgressView("Loading note…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                compactDetailSelectionFailure(path: path)
            }
        }
        .onAppear {
            compactDetailPath = path
            beginCompactDetailSelection(path: path)
        }
        .onDisappear {
            if compactDetailPath == path {
                compactDetailPath = nil
            }
        }
        .inspector(isPresented: $isShowingInspector) {
            BacklinksPanel(model: model, onSelectPath: selectAndNavigateCompact)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    isReadingMode.toggle()
                } label: {
                    Label(isReadingMode ? "Edit" : "Read", systemImage: isReadingMode ? "pencil" : "book")
                }
                .accessibilityLabel(isReadingMode ? "Switch to Edit mode" : "Switch to Reading mode")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    isShowingQuickSwitcher = true
                } label: {
                    Label("Quick Switcher", systemImage: "arrow.right.doc.on.clipboard")
                }
                .keyboardShortcut("o", modifiers: .command)
                .accessibilityLabel("Open quick switcher")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    isShowingInspector.toggle()
                } label: {
                    Label("Backlinks", systemImage: "sidebar.trailing")
                }
                .accessibilityLabel(isShowingInspector ? "Hide backlinks inspector" : "Show backlinks inspector")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    revisionsTarget = NoteRevisionsTarget(path: path)
                } label: {
                    Label("Revisions", systemImage: "clock.arrow.circlepath")
                }
                .accessibilityLabel("Show revisions for \(NoteSummary.title(forRelativePath: path))")
            }
        }
    }

    private func compactDetailSelectionFailure(path: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Couldn't Open Note")
                .font(.title2)
                .fontWeight(.semibold)
            Text("SwiftClaw couldn't switch to this note. Any unsaved changes are still available.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again") {
                beginCompactDetailSelection(path: path)
            }
            .accessibilityLabel("Try opening note again")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func beginCompactDetailSelection(path: String) {
        let attemptID = UUID()
        compactDetailSelectionAttempt = CompactDetailSelectionAttempt(path: path, id: attemptID, state: .pending)

        Task { await finishCompactDetailSelection(path: path, attemptID: attemptID) }
    }

    private func finishCompactDetailSelection(path: String, attemptID: UUID) async {
        await model.select(path: path)

        guard compactDetailSelectionAttempt?.id == attemptID else { return }
        compactDetailSelectionAttempt = CompactDetailSelectionAttempt(
            path: path,
            id: attemptID,
            state: NotesCompactDetailSelectionState.afterSelection(
                requestedPath: path,
                selectedPath: model.selectedPath,
                editorSelectedPath: model.editor?.selectedPath
            )
        )
    }
    #endif

    @ViewBuilder
    private var listColumn: some View {
        VStack(spacing: 0) {
            if let banner = model.healthSummary.flatMap(NotesHealthPresentation.banner) {
                healthBanner(banner)
            }
            if let error = model.lastListError {
                listErrorBanner(error)
            }
            Group {
                if !searchText.isEmpty {
                    searchResultsList
                } else if let repository = model.repository, repository.isLoading, repository.notes.isEmpty {
                    ProgressView("Loading notes…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let repository = model.repository,
                           model.notes.isEmpty,
                          let error = repository.lastError {
                    errorListState(error)
                } else if model.notes.isEmpty {
                    emptyListState
                } else {
                    List(
                        model.notes,
                        selection: Binding(
                            get: { model.selectedPath },
                            set: { newValue in Task { await model.select(path: newValue) } }
                        )
                    ) { note in
                        noteRow(note)
                            .tag(note.relativePath)
                    }
                    .listStyle(.sidebar)
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search notes")
        .onChange(of: searchText) { _, newValue in
            model.setSearchQuery(newValue)
        }
        .navigationTitle("Notes")
    }

    @ViewBuilder
    private var searchResultsList: some View {
        if model.isSearching, model.searchResults.isEmpty {
            ProgressView("Searching…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.searchError {
            FeaturePlaceholderView(
                systemImage: "exclamationmark.triangle",
                title: "Search Failed",
                message: error.errorDescription ?? "An unknown error occurred."
            )
            .accessibilityLabel("Search failed: \(error.errorDescription ?? "An unknown error occurred.")")
        } else if model.searchResults.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("No matches")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(
                model.searchResults, id: \.chunk.id,
                selection: Binding(
                    get: { model.selectedPath },
                    set: { newValue in Task { await model.select(path: newValue) } }
                )
            ) { hit in
                searchHitRow(hit)
                    .tag(hit.document.sourceID)
            }
            .listStyle(.sidebar)
        }
    }

    private func noteRow(_ note: NoteSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(note.title)
                .font(.body)
            Text(note.relativePath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func searchHitRow(_ hit: SearchHit) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(hit.document.title.isEmpty ? hit.document.sourceID : hit.document.title)
                .font(.body)
            if !hit.headingPath.isEmpty {
                Text(hit.headingPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(hit.snippet)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }

    private func healthBanner(_ banner: NotesHealthPresentation.Banner) -> some View {
        Button {
            Task { await model.refreshBrokenLinks() }
            isShowingHealthDetail = true
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(banner.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .padding(10)
        .background(Color.orange.opacity(0.18), in: .rect(cornerRadius: 8))
        .padding(8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Vault health issues: \(banner.message). Tap for details.")
    }

    private func listErrorBanner(_ error: NotesError) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(error.errorDescription ?? "Couldn't create the note.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Dismiss") {
                model.dismissListError()
            }
            .buttonStyle(.plain)
            .font(.caption)
        }
        .padding(10)
        .background(Color.orange.opacity(0.18), in: .rect(cornerRadius: 8))
        .padding(8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Couldn't create the note: \(error.errorDescription ?? "An unknown error occurred.")")
    }

    private var emptyListState: some View {
        VStack(spacing: 8) {
            Image(systemName: searchText.isEmpty ? "note.text" : "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(searchText.isEmpty ? "No notes yet" : "No matches")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if searchText.isEmpty {
                Button("New Note") {
                    createNoteFromCurrentLayout()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorListState(_ error: NotesError) -> some View {
        FeaturePlaceholderView(
            systemImage: "exclamationmark.triangle",
            title: "Couldn't Load Notes",
            message: error.errorDescription ?? "An unknown error occurred."
        )
        .accessibilityLabel("Couldn't load notes: \(error.errorDescription ?? "An unknown error occurred.")")
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let editor = model.editor, let selectedPath = model.selectedPath {
            NoteEditorDetailView(editor: editor, notePath: selectedPath, model: model, isReadingMode: isReadingMode)
        } else {
            FeaturePlaceholderView(
                systemImage: "note.text",
                title: "No Note Selected",
                message: "Select a note from the list, or create a new one."
            )
        }
    }

    private var usesCompactNavigation: Bool {
        #if os(macOS)
        false
        #else
        horizontalSizeClass == .compact
        #endif
    }

    private var compactSelectionHandler: ((String) -> Void)? {
        guard usesCompactNavigation else { return nil }
        return { path in
            selectAndNavigateCompact(to: path)
        }
    }

    /// Action-driven selections do not originate from a compact list row, so
    /// they need their own navigation binding. This stays separate from
    /// `model.selectedPath`; `compactDetailPath` is updated only from the
    /// destination view's lifecycle, preventing a model-selection feedback
    /// loop while still avoiding a second push for the visible note.
    private func selectAndNavigateCompact(to path: String) {
        // On compact layouts the inspector is a sheet. Close it as routing
        // starts so a chosen backlink is immediately visible underneath.
        isShowingInspector = false
        Task {
            await model.select(path: path)
            guard let destination = NotesCompactNavigation.destination(
                for: path,
                selectedPath: model.selectedPath,
                currentDetailPath: compactDetailPath
            ) else { return }
            compactActionDestination = CompactActionDestination(path: destination)
        }
    }

    private func createNoteFromCurrentLayout() {
        Task {
            let createdPath = await model.createNote()
            guard usesCompactNavigation, let createdPath else { return }
            compactActionDestination = CompactActionDestination(path: createdPath)
        }
    }

    private func handleQuickCapture(path: String) {
        guard usesCompactNavigation else { return }
        guard let destination = NotesCompactNavigation.destination(
            for: path,
            selectedPath: model.selectedPath,
            currentDetailPath: compactDetailPath
        ) else { return }
        compactActionDestination = CompactActionDestination(path: destination)
    }
}

/// A compact action may navigate only after the model confirms it selected the
/// requested note. Keeping this decision pure makes failed or stale selections
/// harmless and lets the view avoid observing `selectedPath` for navigation.
enum NotesCompactNavigation {
    static func destination(
        for requestedPath: String,
        selectedPath: String?,
        currentDetailPath: String?
    ) -> String? {
        selectedPath == requestedPath && currentDetailPath != requestedPath ? requestedPath : nil
    }
}

/// The compact detail remains visibly pending only while its selection task is
/// running. Once that task returns, both the model and editor must agree on
/// the requested note before the destination may render its editor.
enum NotesCompactDetailSelectionState: Equatable {
    case pending
    case selected
    case failed

    static func afterSelection(
        requestedPath: String,
        selectedPath: String?,
        editorSelectedPath: String?
    ) -> Self {
        selectedPath == requestedPath && editorSelectedPath == requestedPath ? .selected : .failed
    }
}

private struct CompactDetailSelectionAttempt: Equatable {
    let path: String
    let id: UUID
    let state: NotesCompactDetailSelectionState
}

/// Keeps action-driven compact navigation distinct from row links, which use a
/// raw `String` path. That prevents the two `navigationDestination` overloads
/// from competing during SwiftUI view-builder type checking.
private struct CompactActionDestination: Hashable {
    let path: String
}

/// Vault-health detail sheet, opened from the health banner. Focuses on
/// broken links (source + unresolved target) since that's the actionable
/// detail the banner can't fit inline; other health facts (conflict copies,
/// FTS/embedding availability, index errors) live in `NotesSettingsView`'s
/// fuller health section.
private struct NotesHealthDetailSheet: View {
    let model: NotesFeatureModel
    let onSelectPath: ((String) -> Void)?
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoadingBrokenLinks, model.brokenLinks.isEmpty {
                    ProgressView("Checking links…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = model.brokenLinksError {
                    FeaturePlaceholderView(
                        systemImage: "exclamationmark.triangle",
                        title: "Couldn't Check Links",
                        message: error.errorDescription ?? "An unknown error occurred."
                    )
                } else if model.brokenLinks.isEmpty {
                    FeaturePlaceholderView(
                        systemImage: "checkmark.circle",
                        title: "No Broken Links",
                        message: "Every wikilink in this vault currently resolves."
                    )
                } else {
                    List(Array(model.brokenLinks.enumerated()), id: \.offset) { _, link in
                        Button {
                            if let onSelectPath {
                                onSelectPath(link.sourcePath)
                                onDismiss()
                            } else {
                                Task {
                                    await model.select(path: link.sourcePath)
                                    onDismiss()
                                }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(NoteSummary.title(forRelativePath: link.sourcePath))
                                    .font(.body)
                                Text("Links to unresolved \"\(link.pagePath)\"")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(NoteSummary.title(forRelativePath: link.sourcePath)) links to unresolved \(link.pagePath)")
                    }
                }
            }
            .navigationTitle("Broken Links")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onDismiss)
                }
            }
        }
        .frame(minWidth: 360, minHeight: 320)
        .task { await model.refreshBrokenLinks() }
    }
}

/// Detail column: the Phase 2 styled-source `NoteEditorView` (an
/// `NSTextView`-backed editor that owns its own text storage) or, when
/// `isReadingMode` is on, `NoteReadingView`'s rendered markdown. Selection
/// switching flushes any pending edit through `NoteEditorController`
/// regardless of which mode is showing, since the toggle is purely a view-
/// level concern layered on top of the same controller.
private struct NoteEditorDetailView: View {
    let editor: NoteEditorController
    let notePath: String
    let model: NotesFeatureModel
    let isReadingMode: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let choice = editor.externalChangeChoice {
                externalChangeChoiceBar(choice)
            }

            if let banner = editor.conflictBanner {
                conflictBanner(banner)
            }

            if let banner = editor.externalRemovalBanner {
                externalRemovalBanner(banner)
            }

            if let saveError = editor.saveError {
                saveErrorBanner(saveError)
            }

            if editor.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError = editor.loadError {
                FeaturePlaceholderView(
                    systemImage: "exclamationmark.triangle",
                    title: "Couldn't Load Note",
                    message: loadError.errorDescription ?? "An unknown error occurred."
                )
            } else if isReadingMode {
                NoteReadingView(content: editor.currentText, notePath: notePath, model: model)
            } else {
                NoteEditorView(controller: editor)
                    .accessibilityLabel("Note content, edit mode")
                    .overlay(alignment: .topLeading) {
                        WikilinkCompletionOverlay(controller: editor)
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The detail editor is the single view-level save point. The model
        // also coalesces flushes, since lifecycle callbacks can overlap.
        .onDisappear { Task { await editor.flushPendingSave() } }
    }

    private func externalChangeChoiceBar(_ choice: NoteEditorController.ExternalChangeChoice) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("This note changed outside SwiftClaw")
                    .font(.subheadline.weight(.semibold))
                Text("You have unsaved edits here. Keep yours (saved as a separate copy) or take the version on disk.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if editor.isResolvingExternalChange {
                ProgressView("Resolving…")
                    .controlSize(.small)
                    .font(.caption)
                    .accessibilityLabel("Resolving external change")
            }
            Button("Keep Mine") {
                Task { await editor.keepMine() }
            }
            .buttonStyle(.bordered)
            .font(.caption)
            .disabled(editor.isResolvingExternalChange)
            Button("Take Theirs") {
                Task { await editor.takeTheirs() }
            }
            .buttonStyle(.bordered)
            .font(.caption)
            .disabled(editor.isResolvingExternalChange)
        }
        .padding(10)
        .background(Color.orange.opacity(0.18), in: .rect(cornerRadius: 8))
        .padding(8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("This note changed outside SwiftClaw. Choose Keep Mine to save your edits as a separate copy, or Take Theirs to discard them and reload the version on disk.\(editor.isResolvingExternalChange ? " Resolving." : "")")
    }

    private func conflictBanner(_ banner: NoteEditorController.ConflictBanner) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("This note changed outside SwiftClaw")
                    .font(.subheadline.weight(.semibold))
                Text("Your edits were saved separately as \"\(banner.copyPath)\". Review and merge manually.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Dismiss") {
                editor.dismissConflictBanner()
            }
            .buttonStyle(.plain)
            .font(.caption)
        }
        .padding(10)
        .background(Color.orange.opacity(0.18), in: .rect(cornerRadius: 8))
        .padding(8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Conflict: this note changed outside SwiftClaw. Your edits were saved separately as \(banner.copyPath).")
    }

    private func externalRemovalBanner(_ banner: NoteEditorController.ExternalRemovalBanner) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "trash")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("This note was deleted outside SwiftClaw")
                    .font(.subheadline.weight(.semibold))
                Text("Your unsaved edits are still here. Copy them or select another note; SwiftClaw will not recreate \"\(banner.formerPath)\" automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.orange.opacity(0.18), in: .rect(cornerRadius: 8))
        .padding(8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("This note was deleted outside SwiftClaw. Your unsaved edits are still available and will not recreate \(banner.formerPath) automatically.")
    }

    private func saveErrorBanner(_ error: NotesError) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(error.errorDescription ?? "Couldn't save this note. Your edits are still in the editor.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.orange.opacity(0.18), in: .rect(cornerRadius: 8))
        .padding(8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Couldn't save note: \(error.errorDescription ?? "Your edits are still in the editor.")")
    }
}
