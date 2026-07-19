import Foundation
@testable import SwiftClaw
import SwiftData
import Testing

@MainActor
struct ResearchSessionTests {
    @Test func statusAndJSONBlobsRoundTripThroughSwiftData() throws {
        let container = try Self.inMemoryContainer()
        let context = ModelContext(container)
        let session = ResearchSession(topic: "Durable research")
        let plan = ResearchPlan(
            overview: "Overview",
            threads: [ResearchThreadPlan(question: "Why?", query: "why query")]
        )
        let source = ResearchSource(index: 1, title: "Source", url: "https://example.com")
        let evidence = EvidenceRecord(
            id: UUID(),
            sourceIndex: 1,
            url: source.url,
            title: source.title,
            quote: "A supporting quote.",
            claimSummary: "The claim is supported.",
            retrievedAt: .now
        )

        session.status = .awaitingPlanApproval
        session.planPayload = ResearchSessionPlanPayload(
            plan: plan,
            context: ResearchPlanContext(
                topic: session.topic,
                focus: "A focus",
                surfaceLines: ["[1] Source"],
                sources: [source],
                searchCallsSpent: 1,
                degradationNotes: []
            )
        )
        session.clarifications = [ResearchClarification(question: "Scope?", answer: "Narrow")]
        session.sources = [source]
        session.evidence = [evidence]
        session.progress = ResearchSessionCheckpoint(
            completedStage: .reading,
            sourceCount: 1,
            activityFeed: ["Read Source"],
            canResume: true
        )
        session.openQuestions = ["What remains unknown?"]
        context.insert(session)
        try context.save()

        let fetched = try #require(
            ModelContext(container).fetch(FetchDescriptor<ResearchSession>()).first
        )
        #expect(fetched.status == .awaitingPlanApproval)
        #expect(fetched.planPayload?.plan == plan)
        #expect(fetched.clarifications == session.clarifications)
        #expect(fetched.sources == [source])
        #expect(fetched.evidence == [evidence])
        #expect(fetched.progress?.completedStage == .reading)
        #expect(fetched.openQuestions == ["What remains unknown?"])

        fetched.statusRaw = "future-status"
        #expect(fetched.status == .pending)
    }

    private static func inMemoryContainer() throws -> ModelContainer {
        try ModelContainer(
            for: ResearchSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }
}
