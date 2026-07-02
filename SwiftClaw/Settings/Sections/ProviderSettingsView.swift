import SwiftUI

struct ProviderSettingsView: View {
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
                LabeledContent("Resource Name") {
                    TextField("Resource Name", text: $azureResourceName)
                        .autocorrectionDisabled()
                        .frame(maxWidth: 360)
                }
                if azureResourceNameMissing {
                    Text("Resource Name is required to use Azure.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                SecretKeyRow(title: "API Key", text: $azureAPIKey)
                AzureDeploymentListEditor(deployments: $azureDeployments)
            } header: {
                Text("Azure")
            }

            Section(isExpanded: $neuralwattExpanded) {
                SecretKeyRow(title: "API Key", text: $neuralwattAPIKey)
                ProviderModelListEditor(
                    title: "Models",
                    placeholder: "Model name",
                    models: $neuralwattModels
                )
            } header: {
                Text("Neuralwatt")
            }

            Section(isExpanded: $openRouterExpanded) {
                SecretKeyRow(title: "API Key", text: $openRouterAPIKey)
                ProviderModelListEditor(
                    title: "Models",
                    placeholder: "Model name",
                    models: $openRouterModels
                )
            } header: {
                Text("OpenRouter")
            }

            Section(isExpanded: $braveSearchExpanded) {
                SecretKeyRow(
                    title: "API Key",
                    text: $braveSearchAPIKey,
                    helpText: "Used by the Web Search and Investigation tools."
                )

                LabeledContent("Request Limit") {
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

private struct AzureDeploymentListEditor: View {
    @Binding var deployments: [AzureDeployment]

    @State private var deploymentName = ""
    @State private var displayName = ""
    @State private var capabilities = ModelCapability.defaultCapabilities

    private var canAddDeployment: Bool {
        !deploymentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ProviderListEditor(
            title: "Deployments",
            emptyMessage: "No Azure deployments configured.",
            addButtonTitle: "Add Deployment",
            items: $deployments,
            canAdd: canAddDeployment,
            addAction: addDeployment
        ) { $deployment, remove in
            LabeledContent("Deployment Name") {
                TextField("Deployment Name", text: $deployment.deploymentName)
                    .autocorrectionDisabled()
                    .frame(maxWidth: 360)
            }
            LabeledContent("Display Name") {
                TextField("Optional", text: $deployment.displayName)
                    .autocorrectionDisabled()
                    .frame(maxWidth: 360)
            }
            LabeledContent("Capabilities") {
                ModelCapabilitySelector(capabilities: $deployment.capabilities)
            }
            Button(role: .destructive, action: remove) {
                Label("Remove Deployment", systemImage: "minus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove deployment \(deployment.deploymentName)")
        } addContent: { add in
            LabeledContent("Deployment Name") {
                TextField("Deployment Name", text: $deploymentName)
                    .autocorrectionDisabled()
                    .onSubmit(add)
                    .frame(maxWidth: 360)
            }
            LabeledContent("Display Name") {
                TextField("Optional", text: $displayName)
                    .autocorrectionDisabled()
                    .onSubmit(add)
                    .frame(maxWidth: 360)
            }
            LabeledContent("Capabilities") {
                ModelCapabilitySelector(capabilities: $capabilities)
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

    private var canAddValue: Bool {
        let trimmedValue = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedValue.isEmpty && !models.contains { $0.name == trimmedValue }
    }

    var body: some View {
        ProviderListEditor(
            title: title,
            emptyMessage: "No models configured.",
            addButtonTitle: "Add Model",
            items: $models,
            canAdd: canAddValue,
            addAction: addValue
        ) { $model, remove in
            LabeledContent("Model Name") {
                TextField("Model Name", text: $model.name)
                    .autocorrectionDisabled()
                    .frame(maxWidth: 360)
            }
            LabeledContent("Capabilities") {
                ModelCapabilitySelector(capabilities: $model.capabilities)
            }
            Button(role: .destructive, action: remove) {
                Label("Remove Model", systemImage: "minus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove model \(model.name)")
        } addContent: { add in
            LabeledContent("Model Name") {
                TextField(placeholder, text: $newValue)
                    .autocorrectionDisabled()
                    .onSubmit(add)
                    .frame(maxWidth: 360)
            }
            LabeledContent("Capabilities") {
                ModelCapabilitySelector(capabilities: $capabilities)
            }
        }
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
