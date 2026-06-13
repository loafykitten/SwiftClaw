import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

private enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance = "Appearance"
    case persona = "Persona"
    case personality = "Personality"
    case providers = "Providers"
    case behaviors = "Behaviors"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .appearance: "paintpalette"
        case .persona: "person.crop.circle"
        case .personality: "wand.and.sparkles"
        case .providers: "server.rack"
        case .behaviors: "slider.horizontal.3"
        }
    }
}

struct SettingsView: View {
    @State private var selectedSection: SettingsSection? = .appearance
    @AppStorage(SettingsKeys.accentHue) private var accentHue = AccentColor.defaultHue
    @AppStorage(SettingsKeys.accentLightness) private var accentLightness = AccentColor.defaultLightness

    private var accent: Color {
        AccentColor.color(hue: accentHue, lightness: accentLightness)
    }

    var body: some View {
        HStack(spacing: 0) {
            AccentSidebarList(
                items: SettingsSection.allCases,
                selection: $selectedSection,
                accent: accent,
                topContentInset: 11,
                title: { $0.rawValue },
                systemImage: { $0.systemImage }
            )
            .frame(width: 200)

            Divider()

            NavigationStack {
                detailContent
                    .navigationTitle(selectedSection?.rawValue ?? "Settings")
            }
        }
        .tint(accent)
        .frame(minWidth: 760, minHeight: 640)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedSection {
        case .appearance:
            AppearanceSettingsView()
        case .persona:
            PersonaSettingsView()
        case .personality:
            PersonalitySettingsView()
        case .providers:
            ProviderSettingsView()
        case .behaviors:
            BehaviorSettingsView()
        case nil:
            Text("Select a settings section")
                .foregroundStyle(.secondary)
        }
    }
}

private struct AppearanceSettingsView: View {
    @AppStorage(SettingsKeys.theme) private var theme = AppTheme.system.rawValue
    @AppStorage(SettingsKeys.accentHue) private var accentHue = AccentColor.defaultHue
    @AppStorage(SettingsKeys.accentLightness) private var accentLightness = AccentColor.defaultLightness
    @AppStorage(SettingsKeys.quoteAccentHue) private var quoteAccentHue = AccentColor.defaultQuoteHue
    @AppStorage(SettingsKeys.quoteAccentLightness) private var quoteAccentLightness = AccentColor.defaultQuoteLightness

    var body: some View {
        Form {
            Section("Theme") {
                ThemePicker(selection: $theme)
            }

            Section("Accent Color") {
                AccentColorEditor(hue: $accentHue, lightness: $accentLightness)
            }

            Section("Quote Accent") {
                AccentColorEditor(
                    hue: $quoteAccentHue,
                    lightness: $quoteAccentLightness,
                    defaultHue: AccentColor.defaultQuoteHue,
                    defaultLightness: AccentColor.defaultQuoteLightness,
                    accessibilityName: "Quote accent"
                )
            }
        }
        .formStyle(.grouped)
    }
}

private struct PersonaSettingsView: View {
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

private struct PersonalitySettingsView: View {
    @AppStorage(SettingsKeys.assistantDisplayName) private var assistantName = AssistantPersona.defaultDisplayName
    @AppStorage(SettingsKeys.assistantAvatarData) private var assistantAvatarData = Data()
    @AppStorage(SettingsKeys.assistantPersonalityPreset)
    private var personalityPresetID = AssistantPersonalityLibrary.defaultPresetID
    @AppStorage(SettingsKeys.assistantUsesCustomPersonality) private var usesCustomPersonality = false
    @AppStorage(SettingsKeys.assistantCustomPersonality) private var customPersonality = ""

    @State private var avatarError: String?

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
                            Button {
                                chooseAssistantAvatar()
                            } label: {
                                Label("Choose Image", systemImage: "photo")
                            }

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
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 120)
                        .padding(6)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
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
    }

    private func chooseAssistantAvatar() {
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
              let data = AssistantPersona.normalizedAvatarData(from: image) else {
            avatarError = "Couldn't read that image."
            return
        }

        assistantAvatarData = data
        avatarError = nil
        #endif
    }

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

    #if os(macOS)
    private var image: NSImage? {
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

// MARK: - Theme picker

private struct ThemePicker: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 20) {
            ForEach(AppTheme.allCases) { theme in
                ThemeOption(
                    theme: theme,
                    isSelected: selection == theme.rawValue
                ) {
                    selection = theme.rawValue
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 8)
    }
}

private struct ThemeOption: View {
    let theme: AppTheme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ThemeThumbnail(theme: theme)
                    .frame(width: 84, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(
                                isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary.opacity(0.25)),
                                lineWidth: isSelected ? 3 : 1
                            )
                    }

                Text(theme.rawValue)
                    .font(.caption)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(theme.rawValue) theme")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ThemeThumbnail: View {
    let theme: AppTheme

    var body: some View {
        switch theme {
        case .system:
            ZStack {
                MiniDesktop(scheme: .light)
                MiniDesktop(scheme: .dark)
                    .clipShape(DiagonalHalf())
            }
        case .light:
            MiniDesktop(scheme: .light)
        case .dark:
            MiniDesktop(scheme: .dark)
        }
    }
}

/// Clips to the bottom-right diagonal half, used for the System (auto) thumbnail.
private struct DiagonalHalf: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// A miniature desktop with a window, mimicking System Settings appearance tiles.
private struct MiniDesktop: View {
    let scheme: ColorScheme

    private var wallpaper: LinearGradient {
        switch scheme {
        case .dark:
            LinearGradient(
                colors: [Color(red: 0.18, green: 0.14, blue: 0.42), Color(red: 0.05, green: 0.07, blue: 0.18)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        default:
            LinearGradient(
                colors: [Color(red: 0.62, green: 0.78, blue: 0.96), Color(red: 0.34, green: 0.56, blue: 0.88)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var windowColor: Color {
        scheme == .dark ? Color(white: 0.16) : .white
    }

    private var barColor: Color {
        scheme == .dark ? Color(white: 0.24) : Color(white: 0.93)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            wallpaper

            VStack(spacing: 0) {
                HStack(spacing: 2.5) {
                    Circle().fill(.red).frame(width: 4, height: 4)
                    Circle().fill(.yellow).frame(width: 4, height: 4)
                    Circle().fill(.green).frame(width: 4, height: 4)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4)
                .frame(height: 10)
                .background(barColor)

                windowColor
            }
            .frame(width: 52, height: 34)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 5, topTrailingRadius: 5))
            .padding(.leading, 10)
        }
    }
}

// MARK: - Accent color

private struct AccentColorEditor: View {
    @Binding var hue: Double
    @Binding var lightness: Double

    var defaultHue = AccentColor.defaultHue
    var defaultLightness = AccentColor.defaultLightness
    var accessibilityName = "Accent color"

    private var isDefault: Bool {
        abs(hue - defaultHue) < 0.001
            && abs(lightness - defaultLightness) < 0.001
    }

    private var hueGradient: Gradient {
        Gradient(colors: stride(from: 0.0, through: 1.0, by: 0.1).map {
            AccentColor.color(hue: $0, lightness: lightness)
        })
    }

    private var lightnessGradient: Gradient {
        Gradient(colors: [
            AccentColor.color(hue: hue, lightness: AccentColor.lightnessRange.lowerBound),
            AccentColor.color(hue: hue, lightness: AccentColor.lightnessRange.upperBound),
        ])
    }

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(AccentColor.color(hue: hue, lightness: lightness))
                .frame(width: 36, height: 36)
                .overlay {
                    Circle()
                        .stroke(.secondary.opacity(0.25), lineWidth: 1)
                }

            VStack(spacing: 10) {
                GradientSlider(
                    value: $hue,
                    range: 0...1,
                    gradient: hueGradient,
                    knobColor: AccentColor.color(hue: hue, lightness: lightness),
                    label: "Hue",
                    accessibilityName: accessibilityName
                )
                GradientSlider(
                    value: $lightness,
                    range: AccentColor.lightnessRange,
                    gradient: lightnessGradient,
                    knobColor: AccentColor.color(hue: hue, lightness: lightness),
                    label: "Lightness",
                    accessibilityName: accessibilityName
                )
            }

            Button("Reset") {
                hue = defaultHue
                lightness = defaultLightness
            }
            .disabled(isDefault)
        }
        .padding(.vertical, 6)
    }
}

private struct GradientSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let gradient: Gradient
    let knobColor: Color
    let label: String
    let accessibilityName: String

    private let knobSize: CGFloat = 26
    private let trackHeight: CGFloat = 18

    private var fraction: Double {
        (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(gradient: gradient, startPoint: .leading, endPoint: .trailing))
                    .frame(height: trackHeight)

                Circle()
                    .fill(.white)
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: .black.opacity(0.24), radius: 2, y: 1)
                    .overlay {
                        Circle()
                            .stroke(knobColor, lineWidth: 3.5)
                    }
                    .offset(x: max(0, min(width - knobSize, width * fraction - knobSize / 2)))
            }
            .frame(height: knobSize)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard width > 0 else { return }
                        let fraction = min(max(drag.location.x / width, 0), 1)
                        value = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
                    }
            )
        }
        .frame(height: knobSize)
        .accessibilityElement()
        .accessibilityLabel("\(accessibilityName) \(label.lowercased())")
        .accessibilityValue("\(Int(fraction * 100)) percent")
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) * 0.05
            switch direction {
            case .increment: value = min(value + step, range.upperBound)
            case .decrement: value = max(value - step, range.lowerBound)
            @unknown default: break
            }
        }
    }
}

private struct ProviderSettingsView: View {
    @AppStorage(SettingsKeys.azureResourceName) private var azureResourceName = ""
    @KeychainStorage(SettingsKeys.azureAPIKey) private var azureAPIKey
    @KeychainStorage(SettingsKeys.neuralwattAPIKey) private var neuralwattAPIKey
    @KeychainStorage(SettingsKeys.openRouterAPIKey) private var openRouterAPIKey
    @KeychainStorage(SettingsKeys.braveSearchAPIKey) private var braveSearchAPIKey
    @AppStorage(SettingsKeys.braveSearchRequestsPerSecond)
    private var braveSearchRequestsPerSecond = SettingsStorage.defaultBraveSearchRequestsPerSecond

    @State private var azureDeployments = SettingsStorage.loadDeployments()
    @State private var neuralwattModels = SettingsStorage.loadProviderModels(forKey: SettingsKeys.neuralwattModels)
    @State private var openRouterModels = SettingsStorage.loadProviderModels(forKey: SettingsKeys.openRouterModels)

    @State private var azureExpanded = true
    @State private var neuralwattExpanded = true
    @State private var openRouterExpanded = true
    @State private var braveSearchExpanded = true

    private var azureResourceNameMissing: Bool {
        azureResourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!azureAPIKey.isEmpty || !azureDeployments.isEmpty)
    }

    var body: some View {
        Form {
            Section(isExpanded: $azureExpanded) {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Resource Name", text: $azureResourceName)
                        .autocorrectionDisabled()
                    if azureResourceNameMissing {
                        Text("Resource Name is required to use Azure.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                APIKeyField(title: "API Key", text: $azureAPIKey)
                AzureDeploymentList(deployments: $azureDeployments)
            } header: {
                Text("Azure")
            }

            Section(isExpanded: $neuralwattExpanded) {
                APIKeyField(title: "API Key", text: $neuralwattAPIKey)
                ProviderModelListEditor(
                    title: "Models",
                    placeholder: "Model name",
                    models: $neuralwattModels
                )
            } header: {
                Text("Neuralwatt")
            }

            Section(isExpanded: $openRouterExpanded) {
                APIKeyField(title: "API Key", text: $openRouterAPIKey)
                ProviderModelListEditor(
                    title: "Models",
                    placeholder: "Model name",
                    models: $openRouterModels
                )
            } header: {
                Text("OpenRouter")
            }

            Section(isExpanded: $braveSearchExpanded) {
                APIKeyField(title: "API Key", text: $braveSearchAPIKey)
                Text("Used by the Web Search and Investigation tools.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Request Limit")
                        Spacer()
                        Text("\(braveSearchRequestsPerSecond, specifier: "%.1f") req/s")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: $braveSearchRequestsPerSecond,
                        in: SettingsStorage.braveSearchRequestsPerSecondRange,
                        step: 0.5
                    )
                    Text("Match your Brave plan's rate limit. The free tier allows 1 request per second.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Brave Search")
            }
        }
        .formStyle(.grouped)
        .onChange(of: azureDeployments) { _, newValue in
            SettingsStorage.saveDeployments(newValue)
        }
        .onChange(of: neuralwattModels) { _, newValue in
            SettingsStorage.saveProviderModels(newValue, forKey: SettingsKeys.neuralwattModels)
        }
        .onChange(of: openRouterModels) { _, newValue in
            SettingsStorage.saveProviderModels(newValue, forKey: SettingsKeys.openRouterModels)
        }
    }
}

// MARK: - API key field with reveal toggle

private struct APIKeyField: View {
    let title: String
    @Binding var text: String
    @State private var isRevealed = false

    var body: some View {
        HStack(spacing: 8) {
            if isRevealed {
                TextField(title, text: $text)
                    .autocorrectionDisabled()
            } else {
                SecureField(title, text: $text)
            }
            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(isRevealed ? "Hide API key" : "Show API key")
            .accessibilityLabel(isRevealed ? "Hide API key" : "Show API key")
        }
    }
}

private struct AzureDeploymentList: View {
    @Binding var deployments: [AzureDeployment]
    @State private var deploymentName = ""
    @State private var displayName = ""
    @State private var capabilities = ModelCapability.defaultCapabilities

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Deployments")
                .font(.headline)

            ForEach($deployments) { $deployment in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .bottom, spacing: 10) {
                        SettingsTextField(
                            label: "Deployment Name",
                            text: $deployment.deploymentName
                        )
                        SettingsTextField(
                            label: "Display Name",
                            placeholder: "Optional",
                            text: $deployment.displayName
                        )
                        Button {
                            deployments.removeAll { $0.id == deployment.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Remove deployment")
                        .accessibilityLabel("Remove deployment \(deployment.deploymentName)")
                    }

                    ModelCapabilitySelector(capabilities: $deployment.capabilities)
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }

            Divider()
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .bottom, spacing: 10) {
                    SettingsTextField(
                        label: "Deployment Name",
                        text: $deploymentName
                    )
                    SettingsTextField(
                        label: "Display Name",
                        placeholder: "Optional",
                        text: $displayName
                    )
                    Button {
                        addDeployment()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .disabled(deploymentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Add deployment")
                    .accessibilityLabel("Add deployment")
                }

                ModelCapabilitySelector(capabilities: $capabilities)
            }
            .padding(10)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 1)
            )
        }
    }

    private func addDeployment() {
        let trimmedDeployment = deploymentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDisplay = displayName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedDeployment.isEmpty else {
            return
        }

        deployments.append(
            AzureDeployment(
                deploymentName: trimmedDeployment,
                displayName: trimmedDisplay,
                capabilities: capabilities
            )
        )
        deploymentName = ""
        displayName = ""
        capabilities = ModelCapability.defaultCapabilities
    }
}

private struct ProviderModelListEditor: View {
    let title: String
    let placeholder: String
    @Binding var models: [ProviderModel]
    @State private var newValue = ""
    @State private var capabilities = ModelCapability.defaultCapabilities

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            ForEach($models) { $model in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .bottom, spacing: 10) {
                        SettingsTextField(
                            label: "Model Name",
                            text: $model.name
                        )
                        Button {
                            models.removeAll { $0.id == model.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Remove model")
                        .accessibilityLabel("Remove model \(model.name)")
                    }

                    ModelCapabilitySelector(capabilities: $model.capabilities)
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }

            Divider()
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .bottom, spacing: 10) {
                    SettingsTextField(
                        label: "Model Name",
                        placeholder: placeholder,
                        text: $newValue,
                        onSubmit: addValue
                    )
                    Button {
                        addValue()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .disabled(!canAddValue)
                    .help("Add model")
                    .accessibilityLabel("Add model")
                }

                ModelCapabilitySelector(capabilities: $capabilities)
            }
            .padding(10)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 1)
            )
        }
    }

    private var canAddValue: Bool {
        let trimmedValue = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedValue.isEmpty && !models.contains { $0.name == trimmedValue }
    }

    private func addValue() {
        let trimmedValue = newValue.trimmingCharacters(in: .whitespacesAndNewlines)

        guard canAddValue else {
            return
        }

        models.append(ProviderModel(name: trimmedValue, capabilities: capabilities))
        newValue = ""
        capabilities = ModelCapability.defaultCapabilities
    }
}

private struct SettingsTextField: View {
    let label: String
    var placeholder: String = ""
    @Binding var text: String
    var onSubmit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("", text: $text, prompt: Text(placeholder))
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .onSubmit(onSubmit)
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ModelCapabilitySelector: View {
    @Binding var capabilities: Set<ModelCapability>

    var body: some View {
        HStack(spacing: 14) {
            ForEach(ModelCapability.allCases) { capability in
                Toggle(
                    capability.displayName,
                    isOn: Binding(
                        get: {
                            capabilities.contains(capability)
                        },
                        set: { isEnabled in
                            if isEnabled {
                                capabilities.insert(capability)
                            } else {
                                capabilities.remove(capability)
                            }
                        }
                    )
                )
                .toggleStyle(.checkbox)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct BehaviorSettingsView: View {
    @AppStorage(SettingsKeys.swiftModel) private var swiftModel = ""
    @AppStorage(SettingsKeys.clawModel) private var clawModel = ""
    @AppStorage(SettingsKeys.deepResearchModel) private var deepResearchModel = ""

    @State private var availableModels = SettingsStorage.loadAvailableModels()

    var body: some View {
        Form {
            Section {
                ModelPicker(
                    title: "Swift Model",
                    description: "Title gen, non-reasoning tasks",
                    selection: $swiftModel,
                    models: availableModels
                )
                ModelPicker(
                    title: "Claw Model",
                    description: "Companion model, reasoning tasks",
                    selection: $clawModel,
                    models: availableModels
                )
                ModelPicker(
                    title: "Deep Research Model",
                    description: "Long-running research tasks",
                    selection: $deepResearchModel,
                    models: availableModels
                )
            } header: {
                Text("Model Configuration")
            } footer: {
                if availableModels.isEmpty {
                    Text("No models available. Add deployments or models in the Providers section.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshModels)
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            refreshModels()
        }
    }

    private func refreshModels() {
        availableModels = SettingsStorage.loadAvailableModels()
    }
}

private struct ModelPicker: View {
    let title: String
    let description: String?
    @Binding var selection: String
    let models: [String]

    // Keep a stale selection visible instead of rendering a blank picker.
    private var isSelectionMissing: Bool {
        !selection.isEmpty && !models.contains(selection)
    }

    var body: some View {
        LabeledContent {
            Picker(title, selection: $selection) {
                Text("None").tag("")
                if isSelectionMissing {
                    Text("\(selection) (unavailable)").tag(selection)
                }
                ForEach(models, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 320)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

#Preview {
    SettingsView()
}
