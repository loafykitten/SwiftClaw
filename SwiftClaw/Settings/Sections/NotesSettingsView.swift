import SwiftData
import SwiftUI

struct NotesSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage(SettingsKeys.notesEnabled) private var isNotesEnabled = SettingsStorage.defaultNotesEnabled
    @AppStorage(SettingsKeys.notesEmbeddingsEnabled) private var isEmbeddingsEnabled = SettingsStorage.defaultNotesEmbeddingsEnabled
    @AppStorage(SettingsKeys.notesReviewIntervalSeconds)
    private var reviewIntervalSeconds = SettingsStorage.defaultNotesReviewIntervalSeconds

    @State private var model = NotesFeatureModel.shared
    @State private var isShowingOnboarding = false
    @State private var isShowingResetConfirmation = false
    @State private var hasActivatedModel = false
    @State private var dailyNoteFolder = SettingsStorage.defaultNotesDailyNoteFolder
    @State private var dailyNoteFolderError: String?
    @State private var isReviewing = false
    @State private var reviewStatusMessage: String?

    var body: some View {
        Form {
            Section {
                Toggle("Enable Notes", isOn: $isNotesEnabled)
            } footer: {
                Text("Shows Notes in Workspace: a Markdown vault you can also open in Obsidian or any text editor.")
            }

            if isNotesEnabled {
                vaultSection

                if model.configurationState == .configured {
                    statsSection
                    quickCaptureSection
                    reviewSection
                    embeddingsSection
                    healthSection
                    if !model.brokenLinks.isEmpty || model.isLoadingBrokenLinks {
                        brokenLinksSection
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: isNotesEnabled) {
            guard isNotesEnabled else {
                deactivateModelIfNeeded()
                return
            }
            guard !hasActivatedModel else { return }
            hasActivatedModel = true
            await model.activate()
        }
        .task(id: model.configurationState) {
            guard model.configurationState == .configured else { return }
            await model.refreshHealth()
            await model.refreshBrokenLinks()
        }
        .onChange(of: isEmbeddingsEnabled) { _, newValue in
            Task { await model.updateEmbeddingsEnabled(newValue) }
        }
        .onAppear {
            dailyNoteFolder = SettingsStorage.loadNotesDailyNoteFolder()
            // Unlike `.task(id: model.configurationState)` above (which only
            // reruns on a state *transition*), this fires on every appearance
            // — including navigating back to this section without the vault
            // ever leaving `.configured` — so the vault-location label and
            // note count shown here don't lag behind changes that happened
            // while some other screen was on top.
            guard model.configurationState == .configured else { return }
            Task { await model.refreshCatalog() }
        }
        .onDisappear { deactivateModelIfNeeded() }
        .sheet(isPresented: $isShowingOnboarding) {
            NotesOnboardingSheet(model: model)
        }
        .confirmationDialog(
            "Disconnect this vault?",
            isPresented: $isShowingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                Task { await model.resetVaultConfiguration() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("SwiftClaw will forget this vault's location. Your note files are not deleted.")
        }
    }

    @ViewBuilder
    private var quickCaptureSection: some View {
        Section {
            TextField("Daily Note Folder", text: $dailyNoteFolder)
                .onSubmit(saveDailyNoteFolder)
                .accessibilityIdentifier("settings.notes.dailyNoteFolder")
            Button("Save Daily Note Folder", action: saveDailyNoteFolder)
            if let dailyNoteFolderError {
                Text(dailyNoteFolderError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Quick Capture")
        } footer: {
            Text("Daily captures append to YYYY-MM-DD.md in this vault-relative folder. Leave it blank to use the vault root.")
        }
    }

    @ViewBuilder
    private var reviewSection: some View {
        Section {
            Picker("Scheduled Review", selection: $reviewIntervalSeconds) {
                Text("Manually only").tag(0)
                Text("Every 6 hours").tag(6 * 3600)
                Text("Every 12 hours").tag(12 * 3600)
                Text("Daily").tag(24 * 3600)
            }
            .onChange(of: reviewIntervalSeconds) { _, _ in
                NotificationCenter.default.post(
                    name: SettingsNotifications.notesReviewScheduleDidChange,
                    object: nil
                )
            }

            Button {
                runReviewNow()
            } label: {
                if isReviewing {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Reviewing…")
                    }
                } else {
                    Text("Review Now")
                }
            }
            .disabled(isReviewing || model.configurationState != .configured)
            .accessibilityIdentifier("settings.notes.reviewNow")

            if let reviewStatusMessage {
                Text(reviewStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.notes.reviewStatus")
            }
        } header: {
            Text("AI Review")
        } footer: {
            Text("The assistant checks vault hygiene and triage: unchecked daily-note tasks, conflicts, broken links, recent notes, and index health. It never edits notes.")
        }
    }

    private func deactivateModelIfNeeded() {
        guard hasActivatedModel else { return }
        model.deactivate()
        hasActivatedModel = false
    }

    @ViewBuilder
    private var vaultSection: some View {
        Section {
            LabeledContent("Location", value: model.stats.locationDescription)
            if let path = model.stats.resolvedPath {
                LabeledContent("Path", value: path)
                    .textSelection(.enabled)
            }
            Button("Change…") {
                isShowingOnboarding = true
            }
            #if os(macOS)
            Button("Reveal in Finder") {
                model.revealVaultInFinder()
            }
            .disabled(model.configurationState != .configured)
            #endif
            Button("Reset…", role: .destructive) {
                isShowingResetConfirmation = true
            }
            .disabled(model.configurationState != .configured)
        } header: {
            Text("Vault")
        } footer: {
            if model.configurationState != .configured, let message = model.lastConfigurationError?.errorDescription {
                Text(message)
            } else if model.configurationState != .configured {
                Text("No vault configured yet. Choose or create one to start taking notes.")
            }
        }
    }

    @ViewBuilder
    private var statsSection: some View {
        Section("Stats") {
            LabeledContent("Notes", value: "\(model.stats.noteCount)")
        }
    }

    @ViewBuilder
    private var embeddingsSection: some View {
        Section {
            Toggle("Semantic Search (On-Device)", isOn: $isEmbeddingsEnabled)
        } footer: {
            Text("Improves search by understanding meaning, not just matching words. Runs fully on-device via Apple's NLEmbedding; no data leaves your Mac.")
        }
    }

    @ViewBuilder
    private var healthSection: some View {
        Section {
            if let summary = model.healthSummary {
                LabeledContent("Full-Text Search", value: summary.ftsAvailable ? "Available" : "Unavailable")
                LabeledContent("Semantic Search", value: isEmbeddingsEnabled ? (summary.embeddingAvailable ? "Available" : "Unavailable") : "Off")
                LabeledContent("Broken Links", value: "\(summary.brokenLinkCount)")
                LabeledContent("Conflict Copies", value: "\(summary.conflictCopyCount)")
                if let lastSuccess = summary.lastIndexSuccessAt {
                    LabeledContent("Last Indexed", value: lastSuccess.formatted(date: .abbreviated, time: .shortened))
                }
                if !summary.lastIndexFailedPaths.isEmpty {
                    LabeledContent("Failed to Index", value: "\(summary.lastIndexFailedPaths.count)")
                }
                if let indexError = summary.indexError {
                    Text(indexError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } else {
                ProgressView("Checking index health…")
            }

            Button("Rebuild Index") {
                Task { await model.rebuildIndex() }
            }
            .disabled(model.isRebuildingIndex)

            if model.isRebuildingIndex {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Rebuilding…")
                        .foregroundStyle(.secondary)
                }
            }
            if let error = model.rebuildIndexError {
                Text(error.errorDescription ?? "Couldn't rebuild the index.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Index Health")
        }
    }

    @ViewBuilder
    private var brokenLinksSection: some View {
        Section("Broken Links") {
            if model.isLoadingBrokenLinks, model.brokenLinks.isEmpty {
                ProgressView()
            } else {
                ForEach(Array(model.brokenLinks.enumerated()), id: \.offset) { _, link in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(NoteSummary.title(forRelativePath: link.sourcePath))
                            .font(.body)
                        Text("Links to unresolved \"\(link.pagePath)\"")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func saveDailyNoteFolder() {
        let trimmed = dailyNoteFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            SettingsStorage.saveNotesDailyNoteFolder("")
            dailyNoteFolder = ""
            dailyNoteFolderError = nil
            return
        }
        guard let safe = NotesFilenameSanitizer.sanitizeFolder(trimmed), safe == trimmed else {
            dailyNoteFolderError = "Use a vault-relative folder without dot folders, empty components, or .."
            return
        }
        SettingsStorage.saveNotesDailyNoteFolder(safe)
        dailyNoteFolder = safe
        dailyNoteFolderError = nil
    }

    private func runReviewNow() {
        guard !isReviewing else { return }
        isReviewing = true
        reviewStatusMessage = nil
        NotesWorkflowManager.shared.start(modelContainer: modelContext.container)
        Task {
            reviewStatusMessage = await NotesWorkflowManager.shared.reviewNow()
                ?? "Notes review isn't available yet."
            isReviewing = false
        }
    }
}
