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
                    TextField("", text: $azureResourceName, prompt: Text("Resource name"))
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
                ProviderModelListEditor(models: $neuralwattModels)
            } header: {
                Text("Neuralwatt")
            }

            Section(isExpanded: $openRouterExpanded) {
                SecretKeyRow(title: "API Key", text: $openRouterAPIKey)
                ProviderModelListEditor(models: $openRouterModels)
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

    var body: some View {
        ProviderListEditor(
            title: "Deployments",
            emptyMessage: "No Azure deployments configured.",
            addButtonTitle: "Add Deployment",
            items: $deployments,
            makeItem: { AzureDeployment(deploymentName: "", displayName: "") }
        ) { $deployment, isExpanded, remove in
            AzureDeploymentEditor(deployment: $deployment, isExpanded: isExpanded, remove: remove)
        }
    }
}

private struct AzureDeploymentEditor: View {
    @Binding var deployment: AzureDeployment
    @Binding var isExpanded: Bool
    let remove: () -> Void

    private var title: String {
        let trimmedTitle = deployment.modelPickerTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? "New Deployment" : trimmedTitle
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            LabeledContent("Deployment Name") {
                TextField("", text: $deployment.deploymentName, prompt: Text("Deployment name"))
                    .autocorrectionDisabled()
                    .frame(maxWidth: 360)
            }
            LabeledContent("Display Name") {
                TextField("", text: $deployment.displayName, prompt: Text("Optional"))
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
            .accessibilityLabel("Remove deployment \(title)")
        } label: {
            ProviderItemLabel(title: title, capabilities: deployment.capabilities)
        }
    }
}

private struct ProviderModelListEditor: View {
    @Binding var models: [ProviderModel]

    var body: some View {
        ProviderListEditor(
            title: "Models",
            emptyMessage: "No models configured.",
            addButtonTitle: "Add Model",
            items: $models,
            makeItem: { ProviderModel(name: "") }
        ) { $model, isExpanded, remove in
            ProviderModelEditor(model: $model, isExpanded: isExpanded, remove: remove)
        }
    }
}

private struct ProviderModelEditor: View {
    @Binding var model: ProviderModel
    @Binding var isExpanded: Bool
    let remove: () -> Void

    private var title: String {
        let trimmedName = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? "New Model" : trimmedName
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            LabeledContent("Name") {
                TextField("", text: $model.name, prompt: Text("Model name"))
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
            .accessibilityLabel("Remove model \(title)")
        } label: {
            ProviderItemLabel(title: title, capabilities: model.capabilities)
        }
    }
}
