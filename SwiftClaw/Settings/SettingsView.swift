import SwiftUI

private enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance = "Appearance"
    case providers = "Providers"
    case behaviors = "Behaviors"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .appearance: "paintpalette"
        case .providers: "server.rack"
        case .behaviors: "slider.horizontal.3"
        }
    }
}

struct SettingsView: View {
    @State private var selectedSection: SettingsSection? = .appearance

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selectedSection) { section in
                Label(section.rawValue, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            Group {
                switch selectedSection {
                case .appearance:
                    AppearanceSettingsView()
                case .providers:
                    ProviderSettingsView()
                case .behaviors:
                    BehaviorSettingsView()
                case nil:
                    Text("Select a settings section")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(selectedSection?.rawValue ?? "Settings")
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}

private struct AppearanceSettingsView: View {
    @AppStorage(SettingsKeys.theme) private var theme = AppTheme.system.rawValue
    @AppStorage(SettingsKeys.accentHue) private var accentHue = AccentColor.defaultHue
    @AppStorage(SettingsKeys.accentBrightness) private var accentBrightness = AccentColor.defaultBrightness

    var body: some View {
        Form {
            Section("Theme") {
                ThemePicker(selection: $theme)
            }

            Section("Accent Color") {
                AccentColorEditor(hue: $accentHue, brightness: $accentBrightness)
            }
        }
        .formStyle(.grouped)
    }
}

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
    @Binding var brightness: Double

    private var isDefault: Bool {
        abs(hue - AccentColor.defaultHue) < 0.001
            && abs(brightness - AccentColor.defaultBrightness) < 0.001
    }

    private var hueGradient: Gradient {
        Gradient(colors: stride(from: 0.0, through: 1.0, by: 0.1).map {
            AccentColor.color(hue: $0, brightness: brightness)
        })
    }

    private var brightnessGradient: Gradient {
        Gradient(colors: [
            AccentColor.color(hue: hue, brightness: AccentColor.brightnessRange.lowerBound),
            AccentColor.color(hue: hue, brightness: AccentColor.brightnessRange.upperBound),
        ])
    }

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(AccentColor.color(hue: hue, brightness: brightness))
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
                    knobColor: AccentColor.color(hue: hue, brightness: brightness),
                    label: "Hue"
                )
                GradientSlider(
                    value: $brightness,
                    range: AccentColor.brightnessRange,
                    gradient: brightnessGradient,
                    knobColor: AccentColor.color(hue: hue, brightness: brightness),
                    label: "Brightness"
                )
            }

            Button("Reset") {
                hue = AccentColor.defaultHue
                brightness = AccentColor.defaultBrightness
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
        .accessibilityLabel("Accent color \(label.lowercased())")
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

    @State private var azureDeployments = SettingsStorage.loadDeployments()
    @State private var neuralwattModels = SettingsStorage.loadStringList(forKey: SettingsKeys.neuralwattModels)
    @State private var openRouterModels = SettingsStorage.loadStringList(forKey: SettingsKeys.openRouterModels)

    var body: some View {
        Form {
            Section("Azure") {
                TextField("Resource Name", text: $azureResourceName)
                    .autocorrectionDisabled()
                SecureField("API Key", text: $azureAPIKey)
                AzureDeploymentList(deployments: $azureDeployments)
            }

            Section("Neuralwatt") {
                SecureField("API Key", text: $neuralwattAPIKey)
                StringListEditor(
                    title: "Models",
                    placeholder: "Model name",
                    values: $neuralwattModels
                )
            }

            Section("OpenRouter") {
                SecureField("API Key", text: $openRouterAPIKey)
                StringListEditor(
                    title: "Models",
                    placeholder: "Model name",
                    values: $openRouterModels
                )
            }
        }
        .formStyle(.grouped)
        .onChange(of: azureDeployments) { _, newValue in
            SettingsStorage.saveDeployments(newValue)
        }
        .onChange(of: neuralwattModels) { _, newValue in
            SettingsStorage.saveStringList(newValue, forKey: SettingsKeys.neuralwattModels)
        }
        .onChange(of: openRouterModels) { _, newValue in
            SettingsStorage.saveStringList(newValue, forKey: SettingsKeys.openRouterModels)
        }
    }
}

private struct AzureDeploymentList: View {
    @Binding var deployments: [AzureDeployment]
    @State private var deploymentName = ""
    @State private var displayName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Deployments")
                .font(.headline)

            ForEach($deployments) { $deployment in
                HStack(spacing: 8) {
                    TextField("Deployment Name", text: $deployment.deploymentName)
                    TextField("Display Name", text: $deployment.displayName)
                    Button {
                        deployments.removeAll { $0.id == deployment.id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove deployment")
                }
            }

            HStack(spacing: 8) {
                TextField("Deployment Name", text: $deploymentName)
                TextField("Display Name", text: $displayName)
                Button {
                    addDeployment()
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.plain)
                .disabled(deploymentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Add deployment")
            }
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
                displayName: trimmedDisplay
            )
        )
        deploymentName = ""
        displayName = ""
    }
}

private struct StringListEditor: View {
    let title: String
    let placeholder: String
    @Binding var values: [String]
    @State private var newValue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)

            ForEach(values, id: \.self) { value in
                HStack {
                    Text(value)
                    Spacer()
                    Button {
                        values.removeAll { $0 == value }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove model")
                }
            }

            HStack {
                TextField(placeholder, text: $newValue)
                    .onSubmit(addValue)
                Button {
                    addValue()
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.plain)
                .disabled(newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Add model")
            }
        }
    }

    private func addValue() {
        let trimmedValue = newValue.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedValue.isEmpty, !values.contains(trimmedValue) else {
            return
        }

        values.append(trimmedValue)
        newValue = ""
    }
}

private struct BehaviorSettingsView: View {
    @AppStorage(SettingsKeys.swiftModel) private var swiftModel = ""
    @AppStorage(SettingsKeys.clawModel) private var clawModel = ""
    @AppStorage(SettingsKeys.deepResearchModel) private var deepResearchModel = ""

    @State private var azureDeployments = SettingsStorage.loadDeployments()
    @State private var neuralwattModels = SettingsStorage.loadStringList(forKey: SettingsKeys.neuralwattModels)
    @State private var openRouterModels = SettingsStorage.loadStringList(forKey: SettingsKeys.openRouterModels)

    private var availableModels: [String] {
        let azureModels = azureDeployments.map { deployment in
            "Azure: \(deployment.modelPickerTitle)"
        }
        let neuralwatt = neuralwattModels.map { "Neuralwatt: \($0)" }
        let openRouter = openRouterModels.map { "OpenRouter: \($0)" }

        return azureModels + neuralwatt + openRouter
    }

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
        azureDeployments = SettingsStorage.loadDeployments()
        neuralwattModels = SettingsStorage.loadStringList(forKey: SettingsKeys.neuralwattModels)
        openRouterModels = SettingsStorage.loadStringList(forKey: SettingsKeys.openRouterModels)
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
