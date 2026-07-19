import Foundation
import SwiftData

nonisolated enum ResearchSessionStatus: String, Codable, Sendable {
    case pending
    case clarifying
    case planning
    case awaitingPlanApproval
    case running
    case completed
    case completedPartial
    case failed
    case cancelled
}

/// Stage-granular durable state. Only what streams during a run lives here —
/// results (report, sources, evidence, open questions) are first-class
/// session columns written once at completion. In-flight thread work is
/// intentionally not serialized; v1 resume starts a fresh run with the
/// approved plan.
nonisolated struct ResearchSessionCheckpoint: Codable, Sendable {
    var completedStage: ResearchStage?
    var sourceCount: Int
    var activityFeed: [String]
    var degradationNotes: [String]
    var canResume: Bool

    init(
        completedStage: ResearchStage? = nil,
        sourceCount: Int = 0,
        activityFeed: [String] = [],
        degradationNotes: [String] = [],
        canResume: Bool = false
    ) {
        self.completedStage = completedStage
        self.sourceCount = sourceCount
        self.activityFeed = activityFeed
        self.degradationNotes = degradationNotes
        self.canResume = canResume
    }
}

/// A durable deep-research run in the main local SwiftData store.
@Model
final class ResearchSession {
    @Attribute(.unique) var id: UUID
    var topic: String
    var title: String
    var createdAt: Date
    var completedAt: Date?
    var statusRaw: String
    var planData: Data?
    var clarificationsData: Data?
    var sourcesData: Data?
    var evidenceData: Data?
    var progressData: Data?
    var reportMarkdown: String?
    var openQuestionsData: Data?
    var unverifiedClaimCount: Int = 0
    var errorMessage: String?
    var isUnviewed: Bool = false

    init(
        id: UUID = UUID(),
        topic: String,
        title: String? = nil,
        createdAt: Date = .now,
        completedAt: Date? = nil,
        status: ResearchSessionStatus = .pending,
        reportMarkdown: String? = nil,
        unverifiedClaimCount: Int = 0,
        errorMessage: String? = nil,
        isUnviewed: Bool = false
    ) {
        self.id = id
        self.topic = topic
        self.title = title ?? topic
        self.createdAt = createdAt
        self.completedAt = completedAt
        statusRaw = status.rawValue
        self.reportMarkdown = reportMarkdown
        self.unverifiedClaimCount = unverifiedClaimCount
        self.errorMessage = errorMessage
        self.isUnviewed = isUnviewed
    }

    var status: ResearchSessionStatus {
        get { ResearchSessionStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    /// The editable plan and the surface-search state required to run it
    /// later — the engine's planning result, persisted as-is.
    var planPayload: ResearchPlanningResult? {
        get { Self.decode(ResearchPlanningResult.self, from: planData) }
        set { planData = Self.encode(newValue) }
    }

    var clarifications: [ResearchClarification] {
        get { Self.decode([ResearchClarification].self, from: clarificationsData) ?? [] }
        set { clarificationsData = newValue.isEmpty ? nil : Self.encode(newValue) }
    }

    var sources: [ResearchSource] {
        get { Self.decode([ResearchSource].self, from: sourcesData) ?? [] }
        set { sourcesData = newValue.isEmpty ? nil : Self.encode(newValue) }
    }

    var evidence: [EvidenceRecord] {
        get { Self.decode([EvidenceRecord].self, from: evidenceData) ?? [] }
        set { evidenceData = newValue.isEmpty ? nil : Self.encode(newValue) }
    }

    var progress: ResearchSessionCheckpoint? {
        get { Self.decode(ResearchSessionCheckpoint.self, from: progressData) }
        set { progressData = Self.encode(newValue) }
    }

    var openQuestions: [String] {
        get { Self.decode([String].self, from: openQuestionsData) ?? [] }
        set { openQuestionsData = newValue.isEmpty ? nil : Self.encode(newValue) }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func encode(_ value: (some Encodable)?) -> Data? {
        guard let value else { return nil }
        return try? JSONEncoder().encode(value)
    }

    /// Clears the unviewed badge; every terminal-state screen calls this from
    /// its `onAppear`.
    func markViewed(in context: ModelContext) {
        guard isUnviewed else { return }
        isUnviewed = false
        try? context.save()
    }
}
