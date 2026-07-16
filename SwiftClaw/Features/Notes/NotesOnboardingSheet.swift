import SwiftUI
#if os(macOS)
import AppKit
#else
import UniformTypeIdentifiers
#endif

/// First-configure onboarding: create an app-managed vault, or point at an
/// existing folder — including a live Obsidian vault, since notes are always
/// plain `.md` files. Follows `CalendarOnboardingSheet`'s interaction style
/// (two option cards + a non-trapping "Not Now"); every path is also
/// reachable later from Settings › Notes via "Change…".
struct NotesOnboardingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var model: NotesFeatureModel

    @State private var isWorking = false
    @State private var errorMessage: String?
    #if os(iOS)
    @State private var isShowingFolderImporter = false
    #endif

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Image(systemName: "note.text")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                Text("Set Up Your Notes")
                    .font(.title2.weight(.semibold))
                Text("Notes are plain Markdown files you fully own. Create a vault SwiftClaw manages, or point it at an existing folder — including a live Obsidian vault. You can change this anytime from Settings › Notes.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 28)
            .padding(.horizontal, 32)

            VStack(spacing: 10) {
                optionButton(
                    title: "Create App Vault",
                    subtitle: "SwiftClaw manages a fresh folder for your notes.",
                    systemImage: "sparkles"
                ) {
                    Task { await createAppManagedVault() }
                }
                optionButton(
                    title: "Choose an Existing Folder",
                    subtitle: "Point at a folder on disk — works with Obsidian vaults.",
                    systemImage: "folder"
                ) {
                    chooseExistingFolder()
                }
            }
            .padding(.horizontal, 24)
            .disabled(isWorking)

            if isWorking {
                ProgressView()
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Spacer(minLength: 0)

            Button("Not Now") {
                dismiss()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.bottom, 20)
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 440)
        #else
        .fileImporter(
            isPresented: $isShowingFolderImporter,
            allowedContentTypes: [.folder]
        ) { result in
            handleFolderImport(result)
        }
        #endif
    }

    private func optionButton(
        title: String,
        subtitle: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.body.weight(.medium))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background {
                optionCardBackground
            }
            .contentShape(.rect(cornerRadius: 12.0))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var optionCardBackground: some View {
        if colorSchemeContrast == .increased {
            #if os(macOS)
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.primary.opacity(0.7), lineWidth: 1.5)
                }
            #else
            RoundedRectangle(cornerRadius: 12)
                .fill(.background)
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.primary.opacity(0.7), lineWidth: 1.5)
                }
            #endif
        } else {
            Color.clear
                .glassEffect(in: .rect(cornerRadius: 12.0))
        }
    }

    private func createAppManagedVault() async {
        isWorking = true
        errorMessage = nil
        await model.chooseAppManagedVault()
        isWorking = false
        if model.configurationState == .configured {
            complete()
        } else {
            errorMessage = model.lastConfigurationError?.errorDescription ?? "Couldn't set up a vault."
        }
    }

    private func chooseExistingFolder() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose a folder for your Notes vault. This can be an empty folder or an existing Obsidian vault."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            await configureExternalVault(url: url)
        }
        #else
        isShowingFolderImporter = true
        #endif
    }

    #if os(iOS)
    private func handleFolderImport(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        Task {
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            await configureExternalVault(url: url)
        }
    }
    #endif

    private func configureExternalVault(url: URL) async {
        isWorking = true
        errorMessage = nil
        await model.chooseExternalVault(url: url)
        isWorking = false
        if model.configurationState == .configured {
            complete()
        } else {
            errorMessage = model.lastConfigurationError?.errorDescription ?? "Couldn't open that folder."
        }
    }

    private func complete() {
        dismiss()
    }
}
