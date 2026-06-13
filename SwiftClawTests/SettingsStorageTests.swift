import Foundation
import Testing
@testable import SwiftClaw

struct SettingsStorageTests {
    @Test func migratesOldStringListsToProviderModels() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        fixture.defaults.set(["model-a", "model-b"], forKey: SettingsKeys.neuralwattModels)

        let models = SettingsStorage.loadProviderModels(
            forKey: SettingsKeys.neuralwattModels,
            userDefaults: fixture.defaults
        )

        #expect(models.map(\.name) == ["model-a", "model-b"])
        #expect(models.allSatisfy { $0.capabilities == ModelCapability.defaultCapabilities })
    }

    @Test func azureDeploymentsDecodeMissingCapabilitiesAsDefault() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        let data = try #require("""
            [
                {
                    "id": "11111111-1111-1111-1111-111111111111",
                    "deploymentName": "gpt-4o",
                    "displayName": "GPT 4o"
                }
            ]
            """.data(using: .utf8))
        fixture.defaults.set(data, forKey: SettingsKeys.azureDeployments)

        let deployments = SettingsStorage.loadDeployments(userDefaults: fixture.defaults)

        #expect(deployments.count == 1)
        #expect(deployments[0].deploymentName == "gpt-4o")
        #expect(deployments[0].capabilities == ModelCapability.defaultCapabilities)
    }

    @Test func capabilityLookupUsesNamespacedModelSelection() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        SettingsStorage.saveDeployments(
            [
                AzureDeployment(
                    deploymentName: "azure-deployment",
                    displayName: "Azure Display",
                    capabilities: [.tools, .vision]
                ),
            ],
            userDefaults: fixture.defaults
        )
        SettingsStorage.saveProviderModels(
            [
                ProviderModel(
                    name: "neural-model",
                    capabilities: [.reasoning, .json]
                ),
            ],
            forKey: SettingsKeys.neuralwattModels,
            userDefaults: fixture.defaults
        )
        SettingsStorage.saveProviderModels(
            [
                ProviderModel(
                    name: "router/model",
                    capabilities: [.tools, .reasoning, .vision, .json]
                ),
            ],
            forKey: SettingsKeys.openRouterModels,
            userDefaults: fixture.defaults
        )

        #expect(
            SettingsStorage.capabilities(
                for: "Azure: Azure Display",
                userDefaults: fixture.defaults
            ) == [.tools, .vision]
        )
        #expect(
            SettingsStorage.capabilities(
                for: "Neuralwatt: neural-model",
                userDefaults: fixture.defaults
            ) == [.reasoning, .json]
        )
        #expect(
            SettingsStorage.capabilities(
                for: "OpenRouter: router/model",
                userDefaults: fixture.defaults
            ) == [.tools, .reasoning, .vision, .json]
        )
        #expect(
            SettingsStorage.capabilities(
                for: "OpenRouter: missing",
                userDefaults: fixture.defaults
            ) == ModelCapability.defaultCapabilities
        )
    }
}

private struct UserDefaultsFixture {
    let suiteName: String
    let defaults: UserDefaults

    init() throws {
        suiteName = "SwiftClawTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
