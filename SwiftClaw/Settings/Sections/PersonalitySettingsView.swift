import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#elseif os(iOS)
import PhotosUI
import UIKit
#endif

struct PersonalitySettingsView: View {
    @AppStorage(SettingsKeys.assistantDisplayName) private var assistantName = AssistantPersona.defaultDisplayName
    @AppStorage(SettingsKeys.assistantAvatarData) private var assistantAvatarData = Data()
    @AppStorage(SettingsKeys.assistantPersonalityPreset)
    private var personalityPresetID = AssistantPersonalityLibrary.defaultPresetID
    @AppStorage(SettingsKeys.assistantUsesCustomPersonality) private var usesCustomPersonality = false
    @AppStorage(SettingsKeys.assistantCustomPersonality) private var customPersonality = ""

    @State private var avatarError: String?
    #if os(iOS)
    @State private var selectedAssistantAvatarItem: PhotosPickerItem?
    #endif

    private var hasAvatarOverride: Bool {
        !assistantAvatarData.isEmpty
    }

    private var selectedPreset: AssistantPersonalityPreset {
        AssistantPersonalityLibrary.preset(for: personalityPresetID)
    }

    private var selectedPresetIndex: Int {
        AssistantPersonalityLibrary.presets.firstIndex { $0.id == selectedPreset.id } ?? 0
    }

    private var effectivePersonalityPrompt: String {
        AssistantPersonalityLibrary.prompt(
            presetID: personalityPresetID,
            usesCustomPersonality: usesCustomPersonality,
            customPersonality: customPersonality
        )
    }

    private var personalitySliderValue: Binding<Double> {
        Binding(
            get: { Double(selectedPresetIndex) },
            set: { newValue in
                let index = Int(newValue.rounded())
                guard AssistantPersonalityLibrary.presets.indices.contains(index) else {
                    return
                }

                personalityPresetID = AssistantPersonalityLibrary.presets[index].id
            }
        )
    }

    var body: some View {
        Form {
            Section("SwiftClaw's Persona") {
                LabeledContent("Name") {
                    HStack {
                        TextField("SwiftClaw", text: $assistantName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)

                        Button {
                            assistantName = AssistantPersona.defaultDisplayName
                        } label: {
                            Label("Reset", systemImage: "arrow.counterclockwise")
                        }
                        .disabled(AssistantPersona.sanitizedDisplayName(assistantName) == AssistantPersona.defaultDisplayName)
                    }
                }

                HStack(spacing: 14) {
                    AssistantAvatarPreview(avatarData: assistantAvatarData)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            #if os(macOS)
                            Button {
                                chooseAssistantAvatar()
                            } label: {
                                Label("Choose Image", systemImage: "photo")
                            }
                            #else
                            PhotosPicker(
                                selection: $selectedAssistantAvatarItem,
                                matching: .images,
                                photoLibrary: .shared()
                            ) {
                                Label("Choose Image", systemImage: "photo")
                            }
                            #endif

                            Button {
                                resetAssistantAvatar()
                            } label: {
                                Label("Use Default Avatar", systemImage: "arrow.counterclockwise")
                            }
                            .disabled(!hasAvatarOverride)
                        }

                        Text(hasAvatarOverride ? "Custom avatar selected." : "Using the default SwiftClaw avatar.")
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

            Section("SwiftClaw's Personality") {
                Toggle("Custom Personality", isOn: $usesCustomPersonality)

                if usesCustomPersonality {
                    TextEditor(text: $customPersonality)
                        .font(.body)
                        .frame(minHeight: 120)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Preset") {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(selectedPreset.displayName)
                                Text(selectedPreset.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        NativePersonalityPresetSlider(
                            value: personalitySliderValue,
                            range: 0...Double(max(AssistantPersonalityLibrary.presets.count - 1, 0)),
                            tickCount: AssistantPersonalityLibrary.presets.count
                        )
                        .frame(maxWidth: .infinity)

                        PersonalityPresetLabels(
                            selection: personalityPresetID,
                            presets: AssistantPersonalityLibrary.presets
                        )
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Prompt")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(effectivePersonalityPrompt)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 4)
            }
        }
        .formStyle(.grouped)
        #if os(iOS)
        .onChange(of: selectedAssistantAvatarItem) { _, item in
            loadAssistantAvatar(from: item)
        }
        #endif
    }

    #if os(macOS)
    private func chooseAssistantAvatar() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        guard let image = NSImage(contentsOf: url),
              let data = AssistantPersona.normalizedAvatarData(from: image) else {
            avatarError = "Couldn't read that image."
            return
        }

        assistantAvatarData = data
        avatarError = nil
    }
    #endif

    #if os(iOS)
    private func loadAssistantAvatar(from item: PhotosPickerItem?) {
        guard let item else {
            return
        }

        Task { @MainActor in
            defer {
                selectedAssistantAvatarItem = nil
            }

            do {
                guard let imageData = try await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: imageData),
                      let data = AssistantPersona.normalizedAvatarData(from: image) else {
                    avatarError = "Couldn't read that image."
                    return
                }

                assistantAvatarData = data
                avatarError = nil
            } catch {
                avatarError = "Couldn't read that image."
            }
        }
    }
    #endif

    private func resetAssistantAvatar() {
        assistantAvatarData = Data()
        avatarError = nil
    }
}

private struct PersonalityPresetLabels: View {
    let selection: String
    let presets: [AssistantPersonalityPreset]

    private let labelWidth: CGFloat = 88
    private let labelHeight: CGFloat = 16
    private let trackInset: CGFloat = 10

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let stepCount = max(presets.count - 1, 1)
            let trackWidth = max(width - trackInset * 2, 1)

            ZStack(alignment: .topLeading) {
                ForEach(Array(presets.enumerated()), id: \.element.id) { index, preset in
                    let tickX = trackInset + trackWidth * CGFloat(index) / CGFloat(stepCount)

                    Text(preset.displayName)
                        .font(.caption2)
                        .foregroundStyle(preset.id == selection ? .primary : .secondary)
                        .frame(width: labelWidth, alignment: .center)
                        .position(
                            x: min(max(tickX, labelWidth / 2), width - labelWidth / 2),
                            y: labelHeight / 2
                        )
                }
            }
        }
        .frame(height: labelHeight)
    }
}

private struct AssistantAvatarPreview: View {
    let avatarData: Data

    private let size: CGFloat = 72

    #if os(macOS) || os(iOS)
    private var image: PlatformImage? {
        AssistantPersona.avatarImage(
            overrideData: avatarData.isEmpty ? nil : avatarData
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
        .accessibilityLabel("SwiftClaw avatar preview")
    }

    private var placeholder: some View {
        Image(systemName: "sparkles")
            .resizable()
            .scaledToFit()
            .foregroundStyle(.secondary)
            .padding(16)
    }
}

#if os(macOS)
private struct NativePersonalityPresetSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let tickCount: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value)
    }

    func makeNSView(context: Context) -> NSSlider {
        let slider = FlexibleWidthNSSlider(
            value: value,
            minValue: range.lowerBound,
            maxValue: range.upperBound,
            target: context.coordinator,
            action: #selector(Coordinator.valueChanged(_:))
        )

        slider.isContinuous = true
        slider.numberOfTickMarks = tickCount
        slider.allowsTickMarkValuesOnly = true
        slider.tickMarkPosition = .below
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.value = $value
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.numberOfTickMarks = tickCount
        slider.doubleValue = value
    }
}

private final class FlexibleWidthNSSlider: NSSlider {
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width = NSView.noIntrinsicMetric
        return size
    }
}

private extension NativePersonalityPresetSlider {
    final class Coordinator: NSObject {
        var value: Binding<Double>

        init(value: Binding<Double>) {
            self.value = value
        }

        @MainActor @objc func valueChanged(_ sender: NSSlider) {
            value.wrappedValue = sender.doubleValue.rounded()
        }
    }
}
#else
private struct NativePersonalityPresetSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let tickCount: Int

    var body: some View {
        Slider(
            value: $value,
            in: range,
            step: 1
        )
    }
}
#endif
