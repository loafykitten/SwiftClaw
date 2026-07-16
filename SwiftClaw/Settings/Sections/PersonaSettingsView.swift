import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#elseif os(iOS)
import PhotosUI
import UIKit
#endif

struct PersonaSettingsView: View {
    @AppStorage(SettingsKeys.personaDisplayName) private var displayNameOverride = ""
    @AppStorage(SettingsKeys.personaAvatarData) private var avatarData = Data()

    @State private var avatarError: String?
    #if os(iOS)
    @State private var selectedAvatarItem: PhotosPickerItem?
    #endif

    private var hasNameOverrideValue: Bool {
        !displayNameOverride.isEmpty
    }

    private var hasAvatarOverride: Bool {
        !avatarData.isEmpty
    }

    var body: some View {
        Form {
            Section("Name") {
                #if os(macOS)
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
                #else
                LabeledContent("Preferred Name") {
                    TextField("friend", text: $displayNameOverride, prompt: Text("friend"))
                        .multilineTextAlignment(.trailing)
                }
                #endif
            }

            Section("Chat Avatar") {
                #if os(iOS)
                let pickerAvatarData = avatarData
                let pickerHasAvatarOverride = hasAvatarOverride
                let pickerAvatarStatusText = avatarStatusText
                PhotosPicker(
                    selection: $selectedAvatarItem,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    HStack(spacing: 12) {
                        PersonaAvatarPreview(avatarData: pickerAvatarData, size: 56)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(pickerHasAvatarOverride ? "Change Image" : "Choose Image")
                                .foregroundStyle(.primary)

                            Text(pickerAvatarStatusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 8)

                        Image(systemName: "photo")
                            .foregroundStyle(.tint)
                            .imageScale(.medium)
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)

                if hasAvatarOverride {
                    Button(role: .destructive) {
                        resetAvatar()
                    } label: {
                        Label("Remove Image", systemImage: "trash")
                    }
                }

                if let avatarError {
                    Text(avatarError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                #else
                HStack(spacing: 14) {
                    PersonaAvatarPreview(avatarData: avatarData)

                    VStack(alignment: .leading, spacing: 8) {
                        avatarControls

                        Text(avatarStatusText)
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
                #endif
            }
        }
        .formStyle(.grouped)
        #if os(iOS)
        .onChange(of: selectedAvatarItem) { _, item in
            loadAvatar(from: item)
        }
        #endif
    }

    #if os(macOS)
    @ViewBuilder
    private var avatarControls: some View {
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
    }
    #endif

    private var avatarStatusText: String {
        if hasAvatarOverride {
            return "Custom avatar selected."
        }

        #if os(macOS)
        return "Using the detected macOS profile image."
        #else
        return "Using the default avatar."
        #endif
    }

    #if os(macOS)
    private func chooseAvatar() {
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
    }
    #endif

    #if os(iOS)
    private func loadAvatar(from item: PhotosPickerItem?) {
        guard let item else {
            return
        }

        Task { @MainActor in
            defer {
                selectedAvatarItem = nil
            }

            do {
                guard let imageData = try await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: imageData),
                      let data = PersonaProfile.normalizedAvatarData(from: image) else {
                    avatarError = "Couldn't read that image."
                    return
                }

                avatarData = data
                avatarError = nil
            } catch {
                avatarError = "Couldn't read that image."
            }
        }
    }
    #endif

    private func resetAvatar() {
        avatarData = Data()
        avatarError = nil
    }
}

private struct PersonaAvatarPreview: View {
    let avatarData: Data
    let size: CGFloat

    nonisolated init(avatarData: Data, size: CGFloat = 72) {
        self.avatarData = avatarData
        self.size = size
    }

    #if os(macOS) || os(iOS)
    private var image: PlatformImage? {
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
            #elseif os(iOS)
            if let image {
                Image(uiImage: image)
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
