import Foundation
import Testing
@testable import SwiftClaw

@Suite("Research configuration")
struct ResearchConfigurationTests {
    @Test func investigationPresetMatchesPlan() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        let configuration = ResearchConfiguration.investigation(userDefaults: fixture.defaults)

        #expect(configuration.maxThreads == 3)
        #expect(configuration.reflectionWaves == 0)
        #expect(configuration.searchCallBudget == 10)
        #expect(configuration.pageFetchBudget == 0)
        #expect(configuration.pagesPerThread == 0)
        #expect(configuration.sourceMode == .snippets)
        #expect(configuration.verification == .none)
        #expect(configuration.reportStyle == .conversational)
        #expect(configuration.reportLength == .concise)
        #expect(!configuration.clarify)
        #expect(!configuration.planPreview)
        #expect(configuration.totalBudget == .seconds(120))
        #expect(configuration.finalizationReserve == 0.2)
    }

    @Test func deepResearchPresetMatchesPlan() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        let configuration = ResearchConfiguration.deepResearch(userDefaults: fixture.defaults)

        #expect(configuration.maxThreads == 6)
        #expect(configuration.reflectionWaves == 2)
        #expect(configuration.searchCallBudget == 60)
        #expect(configuration.pageFetchBudget == 40)
        #expect(configuration.pagesPerThread == 3)
        #expect(configuration.sourceMode == .fetchPages(maxBytesPerPage: 1_500_000))
        #expect(configuration.verification == .claimCheck)
        #expect(configuration.reportStyle == .document(outlineFirst: true))
        #expect(configuration.reportLength == .concise)
        #expect(configuration.clarify)
        #expect(configuration.planPreview)
        #expect(configuration.totalBudget == .seconds(15 * 60))
        #expect(configuration.finalizationReserve == 0.2)
    }

    @Test func deepResearchPresetUsesStoredAndClampedRunSettings() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        fixture.defaults.set(20, forKey: SettingsKeys.deepResearchTimeBudgetMinutes)
        fixture.defaults.set(7, forKey: SettingsKeys.deepResearchMaxThreads)
        fixture.defaults.set(
            DeepResearchReportLength.standard.rawValue,
            forKey: SettingsKeys.deepResearchReportLength
        )

        var configuration = ResearchConfiguration.deepResearch(userDefaults: fixture.defaults)
        #expect(configuration.totalBudget == .seconds(20 * 60))
        #expect(configuration.maxThreads == 7)
        #expect(configuration.reportLength == .standard)

        fixture.defaults.set(1, forKey: SettingsKeys.deepResearchTimeBudgetMinutes)
        fixture.defaults.set(100, forKey: SettingsKeys.deepResearchMaxThreads)
        configuration = ResearchConfiguration.deepResearch(userDefaults: fixture.defaults)
        #expect(configuration.totalBudget == .seconds(5 * 60))
        #expect(configuration.maxThreads == 8)

        fixture.defaults.set(100, forKey: SettingsKeys.deepResearchTimeBudgetMinutes)
        fixture.defaults.set(1, forKey: SettingsKeys.deepResearchMaxThreads)
        configuration = ResearchConfiguration.deepResearch(userDefaults: fixture.defaults)
        #expect(configuration.totalBudget == .seconds(30 * 60))
        #expect(configuration.maxThreads == 2)
    }

    @Test func investigationPresetUsesStoredAndClampedMaxThreads() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        fixture.defaults.set(1, forKey: SettingsKeys.investigationMaxSubAgents)
        #expect(ResearchConfiguration.investigation(userDefaults: fixture.defaults).maxThreads == 1)

        fixture.defaults.set(4, forKey: SettingsKeys.investigationMaxSubAgents)
        #expect(ResearchConfiguration.investigation(userDefaults: fixture.defaults).maxThreads == 4)

        fixture.defaults.set(100, forKey: SettingsKeys.investigationMaxSubAgents)
        #expect(ResearchConfiguration.investigation(userDefaults: fixture.defaults).maxThreads == 5)
    }

    @Test func researchModelUsesDeepResearchModelWhenSet() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        fixture.defaults.set("Claw model", forKey: SettingsKeys.clawModel)
        fixture.defaults.set("Research model", forKey: SettingsKeys.deepResearchModel)

        #expect(ResearchModelResolver.resolvedModel(userDefaults: fixture.defaults) == "Research model")
    }

    @Test func researchModelFallsBackToClawModelWhenEmptyOrUnset() throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }

        fixture.defaults.set("Claw model", forKey: SettingsKeys.clawModel)
        #expect(ResearchModelResolver.resolvedModel(userDefaults: fixture.defaults) == "Claw model")

        fixture.defaults.set("", forKey: SettingsKeys.deepResearchModel)
        #expect(ResearchModelResolver.resolvedModel(userDefaults: fixture.defaults) == "Claw model")
    }
}
