import Foundation
@testable import SwiftClaw
import SwiftData
import Testing

@MainActor
@Suite("Research session coordinator", .serialized)
struct ResearchSessionCoordinatorTests {
    @Test func createPlanAndRunPersistsCompletedResult() async throws {
        let container = try Self.inMemoryContainer()
        var notifications = [(UUID, String, Bool)]()
        let coordinator = Self.coordinator(
            runHandler: { _, _, _, progress in
                progress(.stageChanged(.searching))
                progress(.activity("Found source"))
                progress(.sourceCount(1))
                progress(.stageChanged(.writing))
                return Self.completedResult()
            },
            notificationHandler: { notifications.append(($0, $1, $2)) }
        )
        coordinator.configure(modelContainer: container)

        let session = coordinator.createSession(topic: "Test topic")
        coordinator.submitClarifications(
            session: session,
            answers: [ResearchClarification(question: "Scope?", answer: "Focused")]
        )
        await coordinator.generatePlan(session: session)

        #expect(session.status == .awaitingPlanApproval)
        #expect(session.planPayload?.plan == Self.planningResult.plan)
        var approvedPlan = try #require(session.planPayload?.plan)
        approvedPlan.overview = "User-edited overview"
        coordinator.startRun(session: session, approvedPlan: approvedPlan)
        await coordinator.waitForIdleForTesting()

        let stored = try Self.fetch(session.id, in: container)
        #expect(stored.planPayload?.plan.overview == "User-edited overview")
        #expect(stored.status == .completed)
        #expect(stored.reportMarkdown == "# Report\n\nFinished.")
        #expect(stored.sources.count == 1)
        #expect(stored.evidence.count == 1)
        #expect(stored.isUnviewed)
        #expect(stored.completedAt != nil)
        #expect(stored.progress?.completedStage == .writing)
        #expect(notifications.count == 1)
        #expect(notifications.first?.0 == session.id)
        #expect(notifications.first?.2 == false)
    }

    @Test func cancellingKeepsTheEnginePartialResult() async throws {
        let container = try Self.inMemoryContainer()
        let coordinator = Self.coordinator(runHandler: { _, _, _, progress in
            progress(.stageChanged(.reading))
            while !Task.isCancelled {
                await Task.yield()
            }
            return Self.partialResult()
        })
        coordinator.configure(modelContainer: container)
        let session = coordinator.createSession(topic: "Cancelled topic")
        await coordinator.generatePlan(session: session)
        let plan = try #require(session.planPayload?.plan)

        coordinator.startRun(session: session, approvedPlan: plan)
        await Task.yield()
        coordinator.cancel(session: session)
        await coordinator.waitForIdleForTesting()

        let stored = try Self.fetch(session.id, in: container)
        #expect(stored.status == .cancelled)
        #expect(stored.reportMarkdown == "# Partial\n\nGathered findings.")
        #expect(stored.sources.count == 1)
        #expect(stored.progress?.canResume == true)
        #expect(coordinator.resumableSession()?.id == session.id)
    }

    @Test func partialCompletionPersistsPartialStatusAndNotifies() async throws {
        let container = try Self.inMemoryContainer()
        var notifications = [(UUID, String, Bool)]()
        let coordinator = Self.coordinator(
            runHandler: { _, _, _, _ in Self.partialResult() },
            notificationHandler: { notifications.append(($0, $1, $2)) }
        )
        coordinator.configure(modelContainer: container)
        let session = coordinator.createSession(topic: "Partial topic")
        await coordinator.generatePlan(session: session)
        let plan = try #require(session.planPayload?.plan)

        coordinator.startRun(session: session, approvedPlan: plan)
        await coordinator.waitForIdleForTesting()

        let stored = try Self.fetch(session.id, in: container)
        #expect(stored.status == .completedPartial)
        #expect(stored.reportMarkdown == "# Partial\n\nGathered findings.")
        #expect(stored.progress?.degradationNotes == ["Cancelled after gathering."])
        #expect(stored.isUnviewed)
        #expect(notifications.count == 1)
        #expect(notifications.first?.2 == true)
    }

    @Test func runFailurePersistsFailedStatusAndError() async throws {
        let container = try Self.inMemoryContainer()
        let coordinator = Self.coordinator(runHandler: { _, _, _, _ in
            throw CoordinatorTestError.runFailed
        })
        coordinator.configure(modelContainer: container)
        let session = coordinator.createSession(topic: "Failure topic")
        await coordinator.generatePlan(session: session)
        let plan = try #require(session.planPayload?.plan)

        coordinator.startRun(session: session, approvedPlan: plan)
        await coordinator.waitForIdleForTesting()

        let stored = try Self.fetch(session.id, in: container)
        #expect(stored.status == .failed)
        #expect(stored.errorMessage == "Stubbed run failure.")
        #expect(stored.completedAt != nil)
        #expect(stored.isUnviewed)
    }

    @Test func configureMapsInterruptedRunWithoutReportToCancelledAndResumable() throws {
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let session = ResearchSession(topic: "Interrupted", status: .running)
        session.planPayload = ResearchSessionPlanPayload(
            plan: Self.planningResult.plan,
            context: Self.planningResult.context
        )
        session.progress = ResearchSessionCheckpoint(completedStage: .reading)
        context.insert(session)
        try context.save()

        let coordinator = Self.coordinator()
        coordinator.configure(modelContainer: container)

        let stored = try Self.fetch(session.id, in: container)
        #expect(stored.status == .cancelled)
        #expect(stored.reportMarkdown == nil)
        #expect(stored.completedAt != nil)
        #expect(stored.errorMessage?.contains("interrupted") == true)
        #expect(stored.progress?.canResume == true)
        #expect(coordinator.resumableSession()?.id == session.id)
    }

    private static func coordinator(
        runHandler: @escaping ResearchSessionCoordinator.RunHandler = { _, _, _, _ in
            Self.completedResult()
        },
        notificationHandler: @escaping ResearchSessionCoordinator.NotificationHandler = { _, _, _ in }
    ) -> ResearchSessionCoordinator {
        ResearchSessionCoordinator(
            planHandler: { _, _, _ in Self.planningResult },
            runHandler: runHandler,
            notificationHandler: notificationHandler,
            runBudget: .seconds(1)
        )
    }

    private static var planningResult: ResearchPlanningResult {
        ResearchPlanningResult(
            plan: ResearchPlan(
                overview: "Planned overview",
                threads: [ResearchThreadPlan(question: "Question", query: "query")]
            ),
            context: ResearchPlanContext(
                topic: "Test topic",
                focus: nil,
                surfaceLines: ["[1] Source"],
                sources: [source],
                searchCallsSpent: 1,
                degradationNotes: []
            )
        )
    }

    private static var source: ResearchSource {
        ResearchSource(index: 1, title: "Source", url: "https://example.com")
    }

    private static var evidence: EvidenceRecord {
        EvidenceRecord(
            id: UUID(),
            sourceIndex: 1,
            url: source.url,
            title: source.title,
            quote: "Supporting quote.",
            claimSummary: "Supported claim.",
            retrievedAt: .now
        )
    }

    private static func completedResult() -> DeepResearchRunResult {
        DeepResearchRunResult(
            reportMarkdown: "# Report\n\nFinished.",
            openQuestions: [],
            sources: [source],
            evidence: [evidence],
            unverifiedClaimCount: 0,
            degradationNotes: [],
            isPartial: false
        )
    }

    private static func partialResult() -> DeepResearchRunResult {
        DeepResearchRunResult(
            reportMarkdown: "# Partial\n\nGathered findings.",
            openQuestions: ["What remains?"],
            sources: [source],
            evidence: [evidence],
            unverifiedClaimCount: 0,
            degradationNotes: ["Cancelled after gathering."],
            isPartial: true
        )
    }

    private static func inMemoryContainer() throws -> ModelContainer {
        try ModelContainer(
            for: ResearchSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private static func fetch(_ id: UUID, in container: ModelContainer) throws -> ResearchSession {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<ResearchSession>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try #require(context.fetch(descriptor).first)
    }
}

private nonisolated enum CoordinatorTestError: LocalizedError, Sendable {
    case runFailed

    var errorDescription: String? {
        "Stubbed run failure."
    }
}
