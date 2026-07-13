import SwiftUI

struct NotesView: View {
    @State private var model = NotesFeatureModel.shared
    @AppStorage(SettingsKeys.notesHasCompletedOnboarding) private var hasCompletedOnboarding = false
    @State private var isShowingOnboarding = false
    @State private var searchText = ""

    private var filteredNotes: [NoteSummary] {
        guard !searchText.isEmpty else { return model.notes }
        return model.notes.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
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
            NotesOnboardingSheet(model: model)
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

    private var configuredSplitView: some View {
        Group {
            #if os(macOS)
            HSplitView {
                listColumn
                    .frame(minWidth: 220, idealWidth: 280, maxWidth: 360)

                detailColumn
                    .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            }
            #else
            NavigationSplitView {
                listColumn
            } detail: {
                detailColumn
            }
            #endif
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.createNote() }
                } label: {
                    Label("New Note", systemImage: "square.and.pencil")
                }
                .accessibilityLabel("New Note")
            }
        }
    }

    @ViewBuilder
    private var listColumn: some View {
        Group {
            if let repository = model.repository, repository.isLoading, repository.notes.isEmpty {
                ProgressView("Loading notes…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let repository = model.repository,
                       model.notes.isEmpty,
                      let error = repository.lastError {
                errorListState(error)
            } else if filteredNotes.isEmpty {
                emptyListState
            } else {
                List(
                    filteredNotes,
                    selection: Binding(
                        get: { model.selectedPath },
                        set: { newValue in Task { await model.select(path: newValue) } }
                    )
                ) { note in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.title)
                            .font(.body)
                        Text(note.relativePath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .tag(note.relativePath)
                }
                .listStyle(.sidebar)
            }
        }
        .searchable(text: $searchText, prompt: "Search notes")
        .navigationTitle("Notes")
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
                    Task { await model.createNote() }
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
        if let editor = model.editor, model.selectedPath != nil {
            NoteEditorDetailView(editor: editor)
        } else {
            FeaturePlaceholderView(
                systemImage: "note.text",
                title: "No Note Selected",
                message: "Select a note from the list, or create a new one."
            )
        }
    }
}

/// Interim plain-text detail editor for Phase 1 — a `TextEditor` bound
/// straight to `NoteEditorModel`'s text. Phase 2 replaces this with an
/// NSTextView-backed styled-source editor that owns its own text storage
/// instead of round-tripping through a SwiftUI `Binding`.
private struct NoteEditorDetailView: View {
    let editor: NoteEditorModel

    var body: some View {
        VStack(spacing: 0) {
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
            } else {
                TextEditor(text: Binding(
                    get: { editor.editedText },
                    set: { editor.textDidChange($0) }
                ))
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .accessibilityLabel("Note content")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The detail editor is the single view-level save point. The model
        // also coalesces flushes, since lifecycle callbacks can overlap.
        .onDisappear { Task { await editor.flushPendingSave() } }
    }

    private func conflictBanner(_ banner: NoteEditorModel.ConflictBanner) -> some View {
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

    private func externalRemovalBanner(_ banner: NoteEditorModel.ExternalRemovalBanner) -> some View {
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
