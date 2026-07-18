import Foundation

/// Controls how the shared research pipeline gathers and presents findings.
nonisolated struct ResearchConfiguration: Sendable {
    var maxThreads: Int
    var reflectionWaves: Int
    var searchCallBudget: Int
    var pageFetchBudget: Int
    var pagesPerThread: Int
    var sourceMode: SourceMode
    var verification: Verification
    var reportStyle: ReportStyle
    var clarify: Bool
    var planPreview: Bool
    var totalBudget: Duration
    var finalizationReserve: Double

    static func investigation(userDefaults: UserDefaults = .standard) -> Self {
        Self(
            maxThreads: SettingsStorage.loadInvestigationMaxSubAgents(userDefaults: userDefaults),
            reflectionWaves: 0,
            searchCallBudget: 10,
            pageFetchBudget: 0,
            pagesPerThread: 0,
            sourceMode: .snippets,
            verification: .none,
            reportStyle: .conversational,
            clarify: false,
            planPreview: false,
            totalBudget: .seconds(120),
            finalizationReserve: 0.2
        )
    }

    static func deepResearch(userDefaults _: UserDefaults = .standard) -> Self {
        Self(
            maxThreads: 6,
            reflectionWaves: 2,
            searchCallBudget: 60,
            pageFetchBudget: 40,
            pagesPerThread: 3,
            sourceMode: .fetchPages(maxBytesPerPage: 1_500_000),
            verification: .claimCheck,
            reportStyle: .document(outlineFirst: true),
            clarify: true,
            planPreview: true,
            totalBudget: .seconds(15 * 60),
            finalizationReserve: 0.2
        )
    }
}

nonisolated enum SourceMode: Sendable, Equatable {
    case snippets
    case fetchPages(maxBytesPerPage: Int)
}

nonisolated enum Verification: Sendable, Equatable {
    case none
    case claimCheck
}

nonisolated enum ReportStyle: Sendable, Equatable {
    case conversational
    case document(outlineFirst: Bool)
}

/// Resolves the optional Research Model, falling back to the Claw Model.
nonisolated enum ResearchModelResolver {
    static func resolvedModel(userDefaults: UserDefaults = .standard) -> String {
        let researchModel = userDefaults.string(forKey: SettingsKeys.deepResearchModel) ?? ""

        if !researchModel.isEmpty {
            return researchModel
        }

        return userDefaults.string(forKey: SettingsKeys.clawModel) ?? ""
    }
}
