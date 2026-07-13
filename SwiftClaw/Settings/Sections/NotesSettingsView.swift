import SwiftUI

struct NotesSettingsView: View {
    @AppStorage(SettingsKeys.notesEnabled) private var isNotesEnabled = SettingsStorage.defaultNotesEnabled

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
}
