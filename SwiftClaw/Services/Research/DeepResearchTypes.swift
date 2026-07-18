import Foundation

nonisolated struct ResearchClarification: Codable, Sendable, Equatable {
    var question: String
    var answer: String
}

nonisolated struct ResearchThreadPlan: Codable, Sendable, Equatable {
    var question: String
    var query: String
}

nonisolated struct ResearchPlan: Codable, Sendable, Equatable {
    var overview: String
    var threads: [ResearchThreadPlan]
}

nonisolated struct ResearchSource: Codable, Sendable, Equatable {
    let index: Int
    let title: String
    let url: String
}

/// Surface-search state retained while the editable plan is reviewed.
nonisolated struct ResearchPlanContext: Codable, Sendable, Equatable {
    let topic: String
    let focus: String?
    let surfaceLines: [String]
    let sources: [ResearchSource]
    let searchCallsSpent: Int
    let degradationNotes: [String]
}

nonisolated struct ResearchPlanningResult: Codable, Sendable, Equatable {
    var plan: ResearchPlan
    let context: ResearchPlanContext
}

nonisolated struct DeepResearchRunResult: Codable, Sendable {
    let reportMarkdown: String
    let openQuestions: [String]
    let sources: [ResearchSource]
    let evidence: [EvidenceRecord]
    let unverifiedClaimCount: Int
    let degradationNotes: [String]
    let isPartial: Bool
}

nonisolated enum ResearchStage: Sendable, Equatable {
    case planning
    case searching
    case reading
    case crossChecking
    case writing
}

nonisolated enum ResearchProgressEvent: Sendable, Equatable {
    case stageChanged(ResearchStage)
    case activity(String)
    case sourceCount(Int)
}
