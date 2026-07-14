import SwiftUI

struct NotesSettingsView: View {
    @AppStorage(SettingsKeys.notesEnabled) private var isNotesEnabled = SettingsStorage.defaultNotesEnabled
    @AppStorage(SettingsKeys.notesEmbeddingsEnabled) private var isEmbeddingsEnabled = SettingsStorage.defaultNotesEmbeddingsEnabled

    @State private var model = NotesFeatureModel.shared
    @State private var isShowingOnboarding = false
    @State private var isShowingResetConfirmation = false
    @State private var hasActivatedModel = false

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
            Button("Reveal in Finder") {
                model.revealVaultInFinder()
            }
            .disabled(model.configurationState != .configured)
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
}
