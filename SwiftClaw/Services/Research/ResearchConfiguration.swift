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
    var reportLength: DeepResearchReportLength
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
            reportLength: .concise,
            clarify: false,
            planPreview: false,
            totalBudget: .seconds(120),
            finalizationReserve: 0.2
        )
    }

    static func deepResearch(userDefaults: UserDefaults = .standard) -> Self {
        let timeBudgetMinutes = SettingsStorage.loadDeepResearchTimeBudgetMinutes(
            userDefaults: userDefaults
        )
        return Self(
            maxThreads: SettingsStorage.loadDeepResearchMaxThreads(userDefaults: userDefaults),
            reflectionWaves: 2,
            searchCallBudget: 60,
            pageFetchBudget: 40,
            pagesPerThread: 3,
            sourceMode: .fetchPages(maxBytesPerPage: 1_500_000),
            verification: .claimCheck,
            reportStyle: .document(outlineFirst: true),
            reportLength: SettingsStorage.loadDeepResearchReportLength(userDefaults: userDefaults),
            clarify: true,
            planPreview: true,
            totalBudget: .seconds(timeBudgetMinutes * 60),
            finalizationReserve: 0.2
        )
    }

    var reportLengthDirective: String {
        switch reportLength {
        case .concise:
            "1-2 short paragraphs per section, screens not pages"
        case .standard:
            "2-3 paragraphs per section"
        case .thorough:
            "as much detail as the evidence supports, still no padding"
        }
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
