import Foundation
import Testing
@testable import SwiftClaw

struct SettingsStorageTests {
    @Test func migratesOldStringListsToVisionCapableProviderModels() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        fixture.defaults.set(["model-a", "model-b"], forKey: SettingsKeys.neuralwattModels)

        let models = SettingsStorage.loadProviderModels(
            forKey: SettingsKeys.neuralwattModels,
            userDefaults: fixture.defaults
        )

        #expect(models.map(\.name) == ["model-a", "model-b"])
        #expect(models.allSatisfy { $0.capabilities == ModelCapability.defaultCapabilities })
        #expect(models.allSatisfy { $0.capabilities.contains(.vision) })
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

    @Test func toolEnableSettingsDefaultToOn() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        #expect(SettingsStorage.isWebSearchEnabled(userDefaults: fixture.defaults))
        #expect(SettingsStorage.isInvestigationEnabled(userDefaults: fixture.defaults))
    }

    @Test func workspaceFeaturesDefaultToDisabledAndReadStoredFlags() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        for feature in WorkspaceFeature.allCases {
            #expect(!SettingsStorage.isWorkspaceFeatureEnabled(feature, userDefaults: fixture.defaults))
            fixture.defaults.set(true, forKey: feature.settingsKey)
            #expect(SettingsStorage.isWorkspaceFeatureEnabled(feature, userDefaults: fixture.defaults))
        }
    }

    @Test func disabledWebSearchDisablesInvestigationEffectively() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        fixture.defaults.set(false, forKey: SettingsKeys.webSearchEnabled)
        fixture.defaults.set(true, forKey: SettingsKeys.investigationEnabled)

        #expect(!SettingsStorage.isWebSearchEnabled(userDefaults: fixture.defaults))
        #expect(!SettingsStorage.isInvestigationEnabled(userDefaults: fixture.defaults))
    }

    @Test func emailReviewMaxThreadsUsesTheDefaultAndStoredValue() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        #expect(SettingsStorage.loadEmailReviewMaxThreads(userDefaults: fixture.defaults) == 10)
        fixture.defaults.set(15, forKey: SettingsKeys.emailReviewMaxThreads)
        #expect(SettingsStorage.loadEmailReviewMaxThreads(userDefaults: fixture.defaults) == 15)
    }

    @Test func clawReasoningEffortUsesDefaultStoredAndFallbackValues() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        #expect(SettingsStorage.defaultClawReasoningEffort == .medium)
        #expect(SettingsStorage.loadClawReasoningEffort(userDefaults: fixture.defaults) == .medium)

        fixture.defaults.set(ModelReasoningEffort.high.rawValue, forKey: SettingsKeys.clawReasoningEffort)
        #expect(SettingsStorage.loadClawReasoningEffort(userDefaults: fixture.defaults) == .high)

        fixture.defaults.set("bogus", forKey: SettingsKeys.clawReasoningEffort)
        #expect(SettingsStorage.loadClawReasoningEffort(userDefaults: fixture.defaults) == .medium)
    }

    @Test func availableModelsPartitionsByReasoningCapability() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        SettingsStorage.saveDeployments(
            [
                AzureDeployment(
                    deploymentName: "reasoning-deploy",
                    displayName: "Reasoning",
                    capabilities: [.reasoning, .tools]
                ),
                AzureDeployment(
                    deploymentName: "plain-deploy",
                    displayName: "Plain",
                    capabilities: [.json, .vision]
                ),
            ],
            userDefaults: fixture.defaults
        )
        SettingsStorage.saveProviderModels(
            [
                ProviderModel(name: "reasoning-model", capabilities: [.reasoning]),
                ProviderModel(name: "plain-model"),
            ],
            forKey: SettingsKeys.neuralwattModels,
            userDefaults: fixture.defaults
        )

        let all = SettingsStorage.loadAvailableModels(userDefaults: fixture.defaults)
        #expect(all.count == 4)

        let reasoning = SettingsStorage.loadAvailableModels(
            requiresReasoning: true,
            userDefaults: fixture.defaults
        )
        #expect(reasoning == ["Azure: Reasoning", "Neuralwatt: reasoning-model"])

        let nonReasoning = SettingsStorage.loadAvailableModels(
            requiresReasoning: false,
            userDefaults: fixture.defaults
        )
        #expect(nonReasoning == ["Azure: Plain", "Neuralwatt: plain-model"])
    }

    @Test func composerReasoningDefaultFollowsTheSelectedModelsCapabilities() {
        #expect(
            SettingsStorage.composerDefaultReasoningEffort(
                isClawModel: false,
                supportsReasoning: false,
                clawReasoningEffort: .medium
            ) == nil
        )
        #expect(
            SettingsStorage.composerDefaultReasoningEffort(
                isClawModel: true,
                supportsReasoning: false,
                clawReasoningEffort: .high
            ) == nil
        )
        #expect(
            SettingsStorage.composerDefaultReasoningEffort(
                isClawModel: true,
                supportsReasoning: true,
                clawReasoningEffort: .medium
            ) == .medium
        )
        #expect(
            SettingsStorage.composerDefaultReasoningEffort(
                isClawModel: true,
                supportsReasoning: true,
                clawReasoningEffort: .high
            ) == .high
        )
        #expect(
            SettingsStorage.composerDefaultReasoningEffort(
                isClawModel: false,
                supportsReasoning: true,
                clawReasoningEffort: .high
            ) == .low
        )
    }
}
