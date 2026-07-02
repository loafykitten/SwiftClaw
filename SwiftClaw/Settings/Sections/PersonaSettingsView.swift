import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

struct PersonaSettingsView: View {
    @AppStorage(SettingsKeys.personaDisplayName) private var displayNameOverride = ""
    @AppStorage(SettingsKeys.personaAvatarData) private var avatarData = Data()

    @State private var avatarError: String?

    private var hasNameOverrideValue: Bool {
        !displayNameOverride.isEmpty
    }

    private var hasAvatarOverride: Bool {
        !avatarData.isEmpty
    }

    var body: some View {
        Form {
            Section("Name") {
                LabeledContent("Detected Name") {
                    Text(PersonaProfile.detectedDisplayName)
                        .foregroundStyle(.secondary)
                }

                TextField("Name Override", text: $displayNameOverride)

                Button {
                    displayNameOverride = ""
                } label: {
                    Label("Use Detected Name", systemImage: "arrow.counterclockwise")
                }
                .disabled(!hasNameOverrideValue)
            }

            Section("Chat Avatar") {
                HStack(spacing: 14) {
                    PersonaAvatarPreview(avatarData: avatarData)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Button {
                                chooseAvatar()
                            } label: {
                                Label("Choose Image", systemImage: "photo")
                            }

                            Button {
                                resetAvatar()
                            } label: {
                                Label("Use Detected Avatar", systemImage: "arrow.counterclockwise")
                            }
                            .disabled(!hasAvatarOverride)
                        }

                        Text(hasAvatarOverride ? "Custom avatar selected." : "Using the detected macOS profile image.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let avatarError {
                            Text(avatarError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseAvatar() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        guard let image = NSImage(contentsOf: url),
              let data = PersonaProfile.normalizedAvatarData(from: image) else {
            avatarError = "Couldn't read that image."
            return
        }

        avatarData = data
        avatarError = nil
        #endif
    }

    private func resetAvatar() {
        avatarData = Data()
        avatarError = nil
    }
}

private struct PersonaAvatarPreview: View {
    let avatarData: Data

    private let size: CGFloat = 72

    #if os(macOS)
    private var image: NSImage? {
        PersonaProfile.avatarImage(
            overrideData: avatarData.isEmpty ? nil : avatarData,
            pointSize: size
        )
    }
    #endif

    var body: some View {
        ZStack {
            #if os(macOS)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
            #else
            placeholder
            #endif
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle()
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        }
        .accessibilityLabel("Chat avatar preview")
    }

    private var placeholder: some View {
        Image(systemName: "person.crop.circle.fill")
            .resizable()
            .scaledToFit()
            .foregroundStyle(.secondary)
            .padding(2)
    }
}
