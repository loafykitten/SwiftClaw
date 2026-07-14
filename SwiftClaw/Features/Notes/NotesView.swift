import SwiftUI

struct NotesView: View {
    @State private var model = NotesFeatureModel.shared
    @AppStorage(SettingsKeys.notesHasCompletedOnboarding) private var hasCompletedOnboarding = false
    @State private var isShowingOnboarding = false
    @State private var searchText = ""
    @State private var isReadingMode = false

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
        VStack(spacing: 0) {
            if let error = model.lastListError {
                listErrorBanner(error)
            }
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
        }
        .searchable(text: $searchText, prompt: "Search notes")
        .navigationTitle("Notes")
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
