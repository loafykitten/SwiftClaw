#if DEBUG
import Foundation
import SwiftData

/// Launch-argument fixture for UI verification and automated testing:
/// `-research-fixture` seeds one session per interesting state (completed
/// report with citations/evidence/open questions, partial, running-plan
/// approval, failed) so screens can be inspected without live API keys or
/// driving the full flow. Mirrors `NoteProposalFixtureLaunch`'s launch-arg
/// idea; DEBUG-only.
enum ResearchSessionFixtureSeeder {
    static let launchArgument = "-research-fixture"

    @MainActor
    static func seedIfRequested(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        modelContainer: ModelContainer
    ) {
        guard arguments.contains(launchArgument) else { return }
        let context = modelContainer.mainContext
        var sessions = (try? context.fetch(FetchDescriptor<ResearchSession>())) ?? []

        if sessions.isEmpty {
            sessions = [completedSession(), partialSession(), planReadySession(), failedSession()]
            for session in sessions {
                context.insert(session)
            }
            try? context.save()
        }

        // `-research-fixture-open` drives the completed report through the
        // real notification deep-link path, so headless UI verification can
        // reach the report screen without tapping.
        if arguments.contains("\(launchArgument)-open"),
           let completed = sessions.first(where: { $0.status == .completed }) {
            AppRouter.shared.showResearchSession(completed.id)
        }
    }

    private static func completedSession() -> ResearchSession {
        let session = ResearchSession(
            topic: "History of the Antikythera mechanism",
            status: .completed,
            reportMarkdown: """
                ## Overview
                The Antikythera mechanism is an ancient Greek geared device \
                recovered from a shipwreck in 1901, generally interpreted as \
                an astronomical calculator [1]. Its construction is dated to \
                roughly the late second century BCE [2] ⚠.

                ## Discovery and recovery
                Sponge divers found the wreck off the island of Antikythera \
                and recovery work brought up the corroded fragments now held \
                in Athens [1]. Early researchers did not recognize the gearing \
                until decades later [3].

                ## What the gears computed
                X-ray tomography revealed epicyclic gearing that modeled the \
                Moon's variable speed, eclipse cycles, and the four-year \
                athletic games cycle [2] [3].

                ## Open questions
                - Who built the mechanism, and where was the workshop?
                """,
            unverifiedClaimCount: 1,
            isUnviewed: true
        )
        session.completedAt = .now
        session.sources = [
            ResearchSource(index: 1, title: "Antikythera mechanism — overview", url: "https://example.org/antikythera"),
            ResearchSource(index: 2, title: "Dating the mechanism", url: "https://example.org/dating"),
            ResearchSource(index: 3, title: "Tomography of the fragments", url: "https://example.org/tomography"),
        ]
        session.evidence = [
            EvidenceRecord(
                id: UUID(),
                sourceIndex: 1,
                url: "https://example.org/antikythera",
                title: "Antikythera mechanism — overview",
                quote: "The device was recovered in 1901 from a wreck off Antikythera and is widely described as an astronomical calculator.",
                claimSummary: "Recovered 1901; astronomical calculator interpretation.",
                retrievedAt: .now
            ),
            EvidenceRecord(
                id: UUID(),
                sourceIndex: 3,
                url: "https://example.org/tomography",
                title: "Tomography of the fragments",
                quote: "Computed tomography exposed gear trains modeling lunar anomaly and eclipse prediction.",
                claimSummary: "Tomography revealed the gearing's astronomical functions.",
                retrievedAt: .now
            ),
        ]
        session.openQuestions = ["Who built the mechanism, and where was the workshop?"]
        session.progress = ResearchSessionCheckpoint(
            completedStage: .writing,
            sourceCount: 3,
            activityFeed: ["Searching: antikythera mechanism discovery", "Read: Tomography of the fragments"],
            degradationNotes: [],
            canResume: false
        )
        return session
    }

    private static func partialSession() -> ResearchSession {
        let session = ResearchSession(
            topic: "State of solid-state battery manufacturing",
            status: .completedPartial,
            reportMarkdown: """
                ## Overview
                Solid-state battery lines remain pilot-scale; several \
                announced gigafactory timelines slipped to the late 2020s [1].

                ## Open questions
                - Which manufacturers have working pilot lines today?
                """,
            isUnviewed: true
        )
        session.completedAt = .now
        session.sources = [
            ResearchSource(index: 1, title: "Battery manufacturing report", url: "https://example.org/batteries"),
        ]
        session.openQuestions = ["Which manufacturers have working pilot lines today?"]
        session.progress = ResearchSessionCheckpoint(
            completedStage: .writing,
            sourceCount: 1,
            activityFeed: ["Searching: solid state battery gigafactory"],
            degradationNotes: [
                "Reflection: stopped before wave 2 because the search budget or work window was exhausted.",
                "Gather: 2 planned thread(s) produced no usable answer.",
            ],
            canResume: false
        )
        return session
    }

    private static func planReadySession() -> ResearchSession {
        let session = ResearchSession(
            topic: "Rust vs Swift for systems tooling",
            status: .awaitingPlanApproval
        )
        session.planPayload = ResearchSessionPlanPayload(
            plan: ResearchPlan(
                overview: "Compare Rust and Swift for cross-platform CLI and systems tooling in 2026.",
                threads: [
                    ResearchThreadPlan(
                        question: "How do compile times and binary sizes compare?",
                        query: "rust vs swift binary size compile time 2026"
                    ),
                    ResearchThreadPlan(
                        question: "What is the state of Swift on Linux and Windows?",
                        query: "swift linux windows support 2026"
                    ),
                ]
            ),
            context: ResearchPlanContext(
                topic: "Rust vs Swift for systems tooling",
                focus: nil,
                surfaceLines: ["[1] Example surface result"],
                sources: [ResearchSource(index: 1, title: "Example surface result", url: "https://example.org/surface")],
                searchCallsSpent: 1,
                degradationNotes: []
            )
        )
        session.progress = ResearchSessionCheckpoint(completedStage: .planning)
        return session
    }

    private static func failedSession() -> ResearchSession {
        ResearchSession(
            topic: "Local honey producers near Portland",
            status: .failed,
            errorMessage: "The search provider rejected the API key.",
            isUnviewed: true
        )
    }
}
#endif
