import Foundation
import Testing
@testable import SwiftClaw

@Suite("Deep research pipeline", .serialized)
struct DeepResearchPipelineTests {
    @Test func happyPathReflectsWritesVerifiesAndReportsOpenQuestions() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set("Test Research Model", forKey: SettingsKeys.deepResearchModel)
        fixture.defaults.set("Test Swift Model", forKey: SettingsKeys.swiftModel)
        let promptLog = LockedValue<[String]>([])
        let searchLog = LockedValue<[String]>([])
        let progressLog = LockedValue<[ResearchProgressEvent]>([])
        let fetcher = makeFetcher(routes: standardPages)
        var configuration = testConfiguration()
        configuration.reflectionWaves = 1

        let engine = ResearchEngine(
            configuration: configuration,
            pageFetcher: fetcher,
            userDefaults: fixture.defaults,
            searchProvider: { query, _ in
                searchLog.update { $0.append(query) }
                switch query {
                case "test topic": return Self.surfaceResults
                case "launch query": return [Self.surfaceResults[0]]
                case "missing query": throw BraveSearchClient.ClientError.missingAPIKey
                case "follow-up query": return [Self.surfaceResults[2]]
                default: return []
                }
            },
            completionProvider: scriptedCompletion(promptLog: promptLog) { prompt in
                if prompt.contains("Ask only the questions needed") {
                    return #"{"questions":["Which time period matters?"]}"#
                }
                if prompt.contains("Plan the most useful follow-up research threads") {
                    return #"{"overview":"A focused overview.","threads":[{"question":"When did it launch?","query":"launch query"},{"question":"What remains missing?","query":"missing query"}]}"#
                }
                if prompt.contains("Question to answer: When did it launch?") {
                    return #"{"finding":"Records date the launch to 2019 [1].","evidence":[{"sourceIndex":1,"quote":"The launch happened in 2019.","claimSummary":"The launch year was 2019."}]}"#
                }
                if prompt.contains("Identify specific questions that remain unanswered") {
                    return #"{"threads":[{"question":"Was the follow-up confirmed?","query":"follow-up query"}]}"#
                }
                if prompt.contains("Question to answer: Was the follow-up confirmed?") {
                    return #"{"finding":"The follow-up was confirmed [3].","evidence":[{"sourceIndex":3,"quote":"The follow-up was confirmed.","claimSummary":"The follow-up was confirmed."}]}"#
                }
                if prompt.contains("Design an evidence-backed report outline") {
                    return #"{"sections":[{"heading":"Launch evidence","sourceIndices":[1]},{"heading":"Follow-up evidence","sourceIndices":[3]},{"heading":"Combined view","sourceIndices":[1,3]}]}"#
                }
                if prompt.contains("Section heading: Launch evidence") {
                    return "The launch happened in 2020 [1]."
                }
                if prompt.contains("Section heading: Follow-up evidence") {
                    return "The follow-up was confirmed [3]."
                }
                if prompt.contains("Section heading: Combined view") {
                    return "The evidence spans both periods [1] [3]."
                }
                if prompt.contains("Write the introduction and conclusion") {
                    return #"{"introduction":"This report reviews the available record.","conclusion":"The evidence answers most, but not all, planned questions."}"#
                }
                if prompt.contains("Judge whether each claim is supported") {
                    return #"{"verdicts":[{"id":1,"verdict":"unsupported"},{"id":2,"verdict":"supported"},{"id":3,"verdict":"supported"}]}"#
                }
                throw PipelineStubError.unhandledPrompt
            }
        )

        let questions = await engine.clarifyingQuestions(topic: "test topic")
        #expect(questions == ["Which time period matters?"])
        let planning = try await engine.plan(
            topic: "test topic",
            focus: nil,
            clarifications: [ResearchClarification(
                question: questions[0],
                answer: "2018 through 2021"
            )]
        )
        let result = await engine.run(plan: planning.plan, context: planning.context) { event in
            progressLog.update { $0.append(event) }
        }

        #expect(result.reportMarkdown.contains("The launch happened in 2020 [1] ⚠."))
        #expect(result.reportMarkdown.contains("## Open questions"))
        #expect(result.openQuestions == ["What remains missing?"])
        #expect(result.sources.map(\.index) == [1, 2, 3])
        #expect(result.evidence.count == 2)
        #expect(Set(result.evidence.map(\.sourceIndex)) == [1, 3])
        #expect(result.unverifiedClaimCount == 1)
        #expect(result.isPartial)
        #expect(searchLog.value.contains("follow-up query"))
        #expect(promptLog.value.contains { $0.contains("Answer: 2018 through 2021") })
        #expect(progressLog.value.compactMap { event -> ResearchStage? in
            guard case .stageChanged(let stage) = event else { return nil }
            return stage
        } == [.planning, .searching, .reading, .crossChecking, .writing])
        #expect(progressLog.value.contains(.sourceCount(3)))
    }

    @Test func outlineAndVerificationFailuresDegradeWithoutBlockingReport() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set("Test Research Model", forKey: SettingsKeys.deepResearchModel)
        fixture.defaults.set("Test Swift Model", forKey: SettingsKeys.swiftModel)
        let promptLog = LockedValue<[String]>([])
        var configuration = testConfiguration()
        configuration.reflectionWaves = 0
        let engine = ResearchEngine(
            configuration: configuration,
            pageFetcher: makeFetcher(routes: standardPages),
            userDefaults: fixture.defaults,
            searchProvider: { query, _ in
                query == "test topic" ? Self.surfaceResults : [Self.surfaceResults[0]]
            },
            completionProvider: scriptedCompletion(promptLog: promptLog) { prompt in
                if prompt.contains("Plan the most useful follow-up research threads") {
                    return #"{"overview":"Overview.","threads":[{"question":"When did it launch?","query":"launch query"}]}"#
                }
                if prompt.contains("Question to answer: When did it launch?") {
                    return #"{"finding":"The launch happened in 2019 [1].","evidence":[{"sourceIndex":1,"quote":"The launch happened in 2019.","claimSummary":"The launch year was 2019."}]}"#
                }
                if prompt.contains("Design an evidence-backed report outline") {
                    throw InferenceError.emptyResponse
                }
                if prompt.contains("Turn the surface results and follow-up findings") {
                    return "## Overview\nFallback synthesis retained the launch in 2019 [1]."
                }
                if prompt.contains("Judge whether each claim is supported") {
                    return "not json"
                }
                throw PipelineStubError.unhandledPrompt
            }
        )

        let planning = try await engine.plan(topic: "test topic", focus: nil)
        let result = await engine.run(plan: planning.plan, context: planning.context)

        #expect(result.reportMarkdown.contains("Fallback synthesis"))
        #expect(result.unverifiedClaimCount == 0)
        #expect(result.degradationNotes.contains { $0.contains("outline generation failed") })
        #expect(result.degradationNotes.contains { $0.contains("shipped unverified") })
        #expect(result.isPartial)
    }

    @Test func exhaustedSearchBudgetSkipsSecondReflectionAndStillWrites() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set("Test Research Model", forKey: SettingsKeys.deepResearchModel)
        fixture.defaults.set("Test Swift Model", forKey: SettingsKeys.swiftModel)
        let promptLog = LockedValue<[String]>([])
        var configuration = testConfiguration()
        configuration.reflectionWaves = 2
        configuration.searchCallBudget = 3
        let engine = ResearchEngine(
            configuration: configuration,
            pageFetcher: makeFetcher(routes: standardPages),
            userDefaults: fixture.defaults,
            searchProvider: { query, _ in
                switch query {
                case "test topic": Self.surfaceResults
                case "launch query": [Self.surfaceResults[0]]
                case "follow-up query": [Self.surfaceResults[2]]
                default: []
                }
            },
            completionProvider: scriptedCompletion(promptLog: promptLog) { prompt in
                if prompt.contains("Plan the most useful follow-up research threads") {
                    return #"{"overview":"Overview.","threads":[{"question":"When did it launch?","query":"launch query"}]}"#
                }
                if prompt.contains("Question to answer: When did it launch?") {
                    return #"{"finding":"The launch happened in 2019 [1].","evidence":[{"sourceIndex":1,"quote":"The launch happened in 2019.","claimSummary":"The launch year was 2019."}]}"#
                }
                if prompt.contains("Identify specific questions that remain unanswered") {
                    return #"{"threads":[{"question":"Was the follow-up confirmed?","query":"follow-up query"}]}"#
                }
                if prompt.contains("Question to answer: Was the follow-up confirmed?") {
                    return #"{"finding":"The follow-up was confirmed [3].","evidence":[{"sourceIndex":3,"quote":"The follow-up was confirmed.","claimSummary":"The follow-up was confirmed."}]}"#
                }
                if prompt.contains("Design an evidence-backed report outline") {
                    return #"{"sections":[{"heading":"Launch","sourceIndices":[1]},{"heading":"Follow-up","sourceIndices":[3]},{"heading":"Summary","sourceIndices":[1,3]}]}"#
                }
                if prompt.contains("Draft the requested section") {
                    return "The gathered evidence supports this section [1]."
                }
                if prompt.contains("Write the introduction and conclusion") {
                    return #"{"introduction":"Introduction.","conclusion":"Conclusion."}"#
                }
                if prompt.contains("Judge whether each claim is supported") {
                    return #"{"verdicts":[{"id":1,"verdict":"supported"},{"id":2,"verdict":"supported"},{"id":3,"verdict":"supported"}]}"#
                }
                throw PipelineStubError.unhandledPrompt
            }
        )

        let planning = try await engine.plan(topic: "test topic", focus: nil)
        let result = await engine.run(plan: planning.plan, context: planning.context)

        #expect(promptLog.value.filter {
            $0.contains("Identify specific questions that remain unanswered")
        }.count == 1)
        #expect(result.reportMarkdown.contains("## Conclusion"))
        #expect(result.degradationNotes.contains { $0.contains("stopped before wave 2") })
    }

    /// Before searches ran under `withDeadline`, a slow successful search
    /// could outlive the whole research budget.
    @Test func slowSearchIsBoundedByTheRunDeadline() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set("Test Research Model", forKey: SettingsKeys.deepResearchModel)
        var configuration = testConfiguration()
        configuration.totalBudget = .milliseconds(500)
        let engine = ResearchEngine(
            configuration: configuration,
            pageFetcher: makeFetcher(routes: standardPages),
            userDefaults: fixture.defaults,
            searchProvider: { _, _ in
                try await Task.sleep(for: .seconds(30))
                return Self.surfaceResults
            },
            completionProvider: { _, _ in throw PipelineStubError.unhandledPrompt }
        )

        let start = ContinuousClock.now
        await #expect(throws: (any Error).self) {
            try await engine.plan(topic: "test topic", focus: nil)
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    /// A page that sends headers and then trickles nothing used to hold the
    /// run until the per-request timeout, eating the writing reserve.
    @Test func stalledPageFetchIsBoundedByTheRunDeadline() async throws {
        let fixture = try UserDefaultsFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set("Test Research Model", forKey: SettingsKeys.deepResearchModel)
        fixture.defaults.set("Test Swift Model", forKey: SettingsKeys.swiftModel)
        var configuration = testConfiguration()
        configuration.reflectionWaves = 0
        // Threads only start with more than 5 seconds left.
        configuration.totalBudget = .seconds(6)
        let engine = ResearchEngine(
            configuration: configuration,
            pageFetcher: makeFetcher(routes: [
                "https://example.com/launch": .init(body: "", hangs: true),
            ]),
            userDefaults: fixture.defaults,
            searchProvider: { _, _ in [Self.surfaceResults[0]] },
            completionProvider: scriptedCompletion(promptLog: LockedValue([])) { _ in
                throw PipelineStubError.unhandledPrompt
            }
        )
        let plan = ResearchPlan(
            overview: "Overview.",
            threads: [ResearchThreadPlan(question: "When did it launch?", query: "launch query")]
        )
        let context = ResearchPlanContext(
            topic: "test topic",
            focus: nil,
            surfaceLines: [],
            sources: [],
            searchCallsSpent: 0,
            degradationNotes: []
        )

        let start = ContinuousClock.now
        _ = await engine.run(plan: plan, context: context)
        // Without the deadline the fetch waits out PageFetcher's 15s timeout.
        #expect(ContinuousClock.now - start < .seconds(12))
    }

    nonisolated private static let surfaceResults = [
        BraveSearchClient.Result(
            title: "Launch source",
            url: "https://example.com/launch",
            description: "Launch history.",
            age: nil
        ),
        BraveSearchClient.Result(
            title: "Missing source",
            url: "https://example.com/missing",
            description: "Incomplete context.",
            age: nil
        ),
        BraveSearchClient.Result(
            title: "Follow-up source",
            url: "https://example.com/follow-up",
            description: "Follow-up history.",
            age: nil
        ),
    ]

    private var standardPages: [String: StubDeepResearchURLProtocol.StubResponse] {
        [
            "https://example.com/launch": .init(body: "<main><p>The launch happened in 2019.</p></main>"),
            "https://example.com/follow-up": .init(body: "<main><p>The follow-up was confirmed.</p></main>"),
        ]
    }

    nonisolated private func testConfiguration() -> ResearchConfiguration {
        var configuration = ResearchConfiguration.deepResearch()
        configuration.maxThreads = 3
        configuration.searchCallBudget = 10
        configuration.pageFetchBudget = 10
        configuration.pagesPerThread = 1
        configuration.reportLength = .concise
        configuration.totalBudget = .seconds(30)
        configuration.finalizationReserve = 0
        return configuration
    }

    nonisolated private func makeFetcher(
        routes: [String: StubDeepResearchURLProtocol.StubResponse]
    ) -> PageFetcher {
        StubDeepResearchURLProtocol.routes.update { $0 = routes }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubDeepResearchURLProtocol.self]
        return PageFetcher(
            session: URLSession(configuration: configuration),
            resolveHost: { _ in [[93, 184, 216, 34]] },
            readConnection: { _ in FetchDestinationPolicy.Connection(remoteAddress: "93.184.216.34") }
        )
    }

    nonisolated private func scriptedCompletion(
        promptLog: LockedValue<[String]>,
        response: @escaping @Sendable (String) throws -> String
    ) -> ResearchEngine.CompletionProvider {
        { messages, _ in
            let prompt = messages.compactMap { message -> String? in
                guard case .user(let content, _) = message else { return nil }
                return content
            }.last ?? ""
            promptLog.update { $0.append(prompt) }
            return try response(prompt)
        }
    }
}

nonisolated private enum PipelineStubError: LocalizedError, Sendable {
    case unhandledPrompt

    var errorDescription: String? { "The scripted completion did not recognize the prompt." }
}


nonisolated private final class StubDeepResearchURLProtocol: URLProtocol, @unchecked Sendable {
    struct StubResponse: Sendable {
        let body: String
        /// Sends headers, then never delivers the body or finishes.
        var hangs = false
    }

    static let routes = LockedValue<[String: StubResponse]>([:])

    override class func canInit(with _: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let stub = Self.routes.value[url.absoluteString],
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: nil,
                  headerFields: ["Content-Type": "text/html"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        guard !stub.hangs else { return }
        client?.urlProtocol(self, didLoad: Data(stub.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
