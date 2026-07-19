import Foundation
import os

/// Orchestrates a multi-pass web investigation:
///
/// 1. **Surface search** — one broad Brave search for the topic.
/// 2. **Analysis** — the Research Model reviews surface results and plans
///    follow-up lines of inquiry.
/// 3. **Sub-agents** — each line of inquiry runs in parallel: its own Brave
///    search plus a Swift Model extraction of what was found.
/// 4. **Synthesis** — the Research Model cross-references the surface data and
///    every thread's findings into the final report body.
///
/// All Brave calls flow through ``BraveRateGate``; rate-limited or transient
/// failures retry with backoff until the overall time budget runs out, and
/// threads that can't finish surface as partial results instead of failing
/// the whole investigation.
nonisolated struct ResearchEngine: Sendable {
    typealias SearchProvider = @Sendable (String, Int) async throws -> [BraveSearchClient.Result]
    typealias CompletionProvider = @Sendable ([InferenceMessage], String) async throws -> String
    typealias ProgressHandler = @Sendable (ResearchProgressEvent) -> Void

    private static let logger = AppLog.make("ResearchEngine")

    private static let maxAttempts = 3
    private static let surfaceResultCount = 8
    private static let threadResultCount = 4
    /// Keeps each fetched source small enough for the Swift Model prompt while
    /// preserving several paragraphs of useful context.
    private static let pageTextCharacterLimit = 6_000

    private let configuration: ResearchConfiguration
    private let pageFetcher: PageFetcher
    private let contentExtractor = ContentExtractor()
    private let searchProvider: SearchProvider
    private let completionProvider: CompletionProvider
    /// Resolved once at init — an engine instance is per-run, and resolving
    /// here keeps `UserDefaults` (non-Sendable) out of the stored state so
    /// tests can inject isolated defaults.
    private let researchModel: String
    private let swiftModel: String

    init(
        configuration: ResearchConfiguration,
        pageFetcher: PageFetcher = PageFetcher(),
        userDefaults: UserDefaults = .standard,
        searchProvider: @escaping SearchProvider = { query, count in
            try await BraveSearchClient.fromSettings().search(query: query, count: count)
        },
        completionProvider: @escaping CompletionProvider = { messages, model in
            try await InferenceService.shared.complete(
                messages: messages,
                model: model,
                systemPromptMode: .standalone
            )
        }
    ) {
        self.configuration = configuration
        self.pageFetcher = pageFetcher
        self.searchProvider = searchProvider
        self.completionProvider = completionProvider
        researchModel = ResearchModelResolver.resolvedModel(userDefaults: userDefaults)
        swiftModel = userDefaults.string(forKey: SettingsKeys.swiftModel) ?? ""
    }

    private struct DeadlineExceededError: LocalizedError, Sendable {
        var errorDescription: String? {
            "The research time budget ran out."
        }
    }

    func investigate(topic: String, focus: String?) async throws -> String {
        let researchModel = self.researchModel
        let swiftModel = self.swiftModel

        guard !researchModel.isEmpty, !swiftModel.isEmpty else {
            throw ToolError.notConfigured(
                toolName: "Investigation",
                reason: "Set the Claw Model and Swift Model in Settings → Behaviors."
            )
        }

        let startInstant = ContinuousClock.now
        let deadline = startInstant + configuration.totalBudget
        let budget = ResearchBudget(configuration: configuration, startInstant: startInstant)
        let subject = focus.map { "\(topic) — focus: \($0)" } ?? topic

        // 1. Surface search.
        let surfaceResults = try await searchWithRetries(
            query: topic,
            count: Self.surfaceResultCount,
            deadline: deadline,
            budget: budget
        )

        guard !surfaceResults.isEmpty else {
            return "The investigation found no web results for \"\(topic)\"."
        }

        let evidenceStore = EvidenceStore()
        let surfaceLines = await numberedLines(for: surfaceResults, in: evidenceStore)

        // 2. Research Model plans the follow-up threads.
        let planResult = await analysisPlan(
            subject: subject,
            surfaceLines: surfaceLines,
            maxThreads: configuration.maxThreads,
            researchModel: researchModel,
            deadline: deadline
        )
        let plan = planResult.plan

        Self.logger.info("""
            Investigation planned \(plan.threads.count, privacy: .public) threads \
            for topic (\(topic.count, privacy: .public) characters)
            """)

        // 3. Sub-agents investigate each thread in parallel.
        let outcomes = await runThreads(
            plan.threads,
            evidenceStore: evidenceStore,
            budget: budget,
            swiftModel: swiftModel,
            deadline: deadline
        )

        // 4. Research Model synthesizes the report body.
        let body = await synthesizedBody(
            subject: subject,
            overview: plan.overview,
            surfaceLines: surfaceLines,
            outcomes: outcomes,
            researchModel: researchModel,
            deadline: deadline
        ) ?? mechanicalBody(overview: plan.overview, surfaceLines: surfaceLines, outcomes: outcomes)

        let sources = await evidenceStore.numberedList()
            .map { "\($0.index). \($0.title) — \($0.url)" }
            .joined(separator: "\n")

        return """
            # Investigation: \(topic)

            \(body)

            ## Sources
            \(sources)
            """
    }

    // MARK: - Deep research entry points

    func clarifyingQuestions(topic: String) async -> [String] {
        let researchModel = self.researchModel
        guard !researchModel.isEmpty else {
            return []
        }

        let prompt = """
            You are planning a deep web research project. Today's date is \
            \(Date.now.formatted(date: .long, time: .omitted)).

            # Purpose
            Ask only the questions needed to clarify the requested research.

            Topic: \(topic)

            Respond ONLY with JSON in exactly this shape, with no markdown fences \
            or commentary:
            {"questions": ["short clarifying question"]}

            Return at most 3 short questions. Return an empty array when the topic \
            is already specific enough.
            """
        let deadline = ContinuousClock.now + configuration.totalBudget

        do {
            let response = try await withRetries(deadline: deadline, label: "clarification") {
                try await completeWithDeadline(
                    messages: [.user(prompt)],
                    model: researchModel,
                    deadline: deadline
                )
            }
            guard let decoded = Self.decodeJSON(ClarifyingQuestionsResponse.self, from: response) else {
                return []
            }

            let questions = decoded.questions
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.count <= 200 }
            guard !questions.isEmpty || decoded.questions.isEmpty else {
                return []
            }
            return Array(questions.prefix(3))
        } catch {
            Self.logger.info("Clarification skipped: \(String(describing: error))")
            return []
        }
    }

    func plan(
        topic: String,
        focus: String?,
        clarifications: [ResearchClarification] = []
    ) async throws -> ResearchPlanningResult {
        let researchModel = self.researchModel
        guard !researchModel.isEmpty else {
            throw ToolError.notConfigured(
                toolName: "Deep Research",
                reason: "Set the Claw Model in Settings → Behaviors."
            )
        }

        let startInstant = ContinuousClock.now
        let deadline = startInstant + configuration.totalBudget
        let budget = ResearchBudget(configuration: configuration, startInstant: startInstant)
        let surfaceResults = try await searchWithRetries(
            query: topic,
            count: Self.surfaceResultCount,
            deadline: deadline,
            budget: budget
        )
        let evidenceStore = EvidenceStore()
        let surfaceLines = await numberedLines(for: surfaceResults, in: evidenceStore)
        let subject = focus.map { "\(topic) — focus: \($0)" } ?? topic
        let planResult = await analysisPlan(
            subject: subject,
            surfaceLines: surfaceLines,
            maxThreads: configuration.maxThreads,
            researchModel: researchModel,
            deadline: deadline,
            clarifications: clarifications
        )
        let sources = await evidenceStore.numberedList().map {
            ResearchSource(index: $0.index, title: $0.title, url: $0.url)
        }

        return ResearchPlanningResult(
            plan: planResult.plan,
            context: ResearchPlanContext(
                topic: topic,
                focus: focus,
                surfaceLines: surfaceLines,
                sources: sources,
                searchCallsSpent: await budget.searchCallsSpent,
                degradationNotes: planResult.degradationNote.map { [$0] } ?? []
            )
        )
    }

    func run(
        plan: ResearchPlan,
        context: ResearchPlanContext,
        progress: ProgressHandler? = nil
    ) async -> DeepResearchRunResult {
        let startInstant = ContinuousClock.now
        let deadline = startInstant + configuration.totalBudget
        let budget = ResearchBudget(configuration: configuration, startInstant: startInstant)
        for _ in 0..<context.searchCallsSpent {
            _ = await budget.leaseSearchCall()
        }

        let evidenceStore = EvidenceStore()
        for source in context.sources.sorted(by: { $0.index < $1.index }) {
            _ = await evidenceStore.register(title: source.title, url: source.url)
        }

        let researchModel = self.researchModel
        let swiftModel = self.swiftModel
        let subject = context.focus.map { "\(context.topic) — focus: \($0)" } ?? context.topic
        var degradationNotes = context.degradationNotes
        var outcomes = [ThreadOutcome]()

        progress?(.stageChanged(.planning))
        progress?(.sourceCount(context.sources.count))
        progress?(.stageChanged(.searching))
        progress?(.stageChanged(.reading))
        outcomes = await runThreads(
            plan.threads,
            evidenceStore: evidenceStore,
            budget: budget,
            swiftModel: swiftModel,
            deadline: deadline,
            progress: progress
        )
        progress?(.sourceCount((await evidenceStore.numberedList()).count))

        let failedGatherCount = outcomes.filter { !$0.isAnswered }.count
        if failedGatherCount > 0 {
            degradationNotes.append(
                "Gather: \(failedGatherCount) planned thread(s) produced no usable answer."
            )
        }

        if Task.isCancelled {
            degradationNotes.append("Cancelled after gathering; the raw findings were preserved.")
            return await partialResult(
                plan: plan,
                context: context,
                outcomes: outcomes,
                evidenceStore: evidenceStore,
                degradationNotes: degradationNotes
            )
        }

        progress?(.stageChanged(.crossChecking))
        for wave in 0..<configuration.reflectionWaves {
            let inFinalizationWindow = await budget.isInFinalizationWindow(now: .now)
            let searchCallsRemaining = await budget.searchCallsRemaining
            guard !inFinalizationWindow, searchCallsRemaining > 0 else {
                degradationNotes.append(
                    "Reflection: stopped before wave \(wave + 1) because the search budget or work window was exhausted."
                )
                break
            }

            do {
                let evidence = await evidenceStore.allEvidence()
                let followUps = try await reflectionThreads(
                    plan: plan,
                    outcomes: outcomes,
                    evidence: evidence,
                    researchModel: researchModel,
                    deadline: deadline
                )
                guard !followUps.isEmpty else {
                    break
                }

                if Task.isCancelled {
                    degradationNotes.append("Cancelled after reflection; the gathered findings were preserved.")
                    return await partialResult(
                        plan: plan,
                        context: context,
                        outcomes: outcomes,
                        evidenceStore: evidenceStore,
                        degradationNotes: degradationNotes
                    )
                }

                progress?(.activity("Reflection wave \(wave + 1): \(followUps.count) follow-up thread(s)"))
                let followUpOutcomes = await runThreads(
                    followUps,
                    evidenceStore: evidenceStore,
                    budget: budget,
                    swiftModel: swiftModel,
                    deadline: deadline,
                    progress: progress
                )
                outcomes.append(contentsOf: followUpOutcomes)
                let failedFollowUpCount = followUpOutcomes.filter { !$0.isAnswered }.count
                if failedFollowUpCount > 0 {
                    degradationNotes.append(
                        "Reflection: wave \(wave + 1) left \(failedFollowUpCount) follow-up thread(s) unanswered."
                    )
                }
                progress?(.sourceCount((await evidenceStore.numberedList()).count))
            } catch {
                degradationNotes.append(
                    "Reflection: wave \(wave + 1) was skipped because \(error.localizedDescription)"
                )
                break
            }

            if Task.isCancelled {
                degradationNotes.append("Cancelled after reflection gathering; the raw findings were preserved.")
                return await partialResult(
                    plan: plan,
                    context: context,
                    outcomes: outcomes,
                    evidenceStore: evidenceStore,
                    degradationNotes: degradationNotes
                )
            }
        }

        progress?(.stageChanged(.writing))
        let writeResult = await writtenBody(
            subject: subject,
            plan: plan,
            surfaceLines: context.surfaceLines,
            outcomes: outcomes,
            evidence: await evidenceStore.allEvidence(),
            researchModel: researchModel,
            deadline: deadline
        )
        degradationNotes.append(contentsOf: writeResult.degradationNotes)

        if Task.isCancelled {
            degradationNotes.append("Cancelled after writing; claim verification was skipped.")
            return await completedResult(
                reportMarkdown: writeResult.body,
                unverifiedClaimCount: 0,
                plan: plan,
                outcomes: outcomes,
                evidenceStore: evidenceStore,
                degradationNotes: degradationNotes,
                forcePartial: true
            )
        }

        var reportMarkdown = writeResult.body
        var unverifiedClaimCount = 0
        if configuration.verification == .claimCheck {
            do {
                let verification = try await verify(
                    reportMarkdown: reportMarkdown,
                    evidence: await evidenceStore.allEvidence(),
                    researchModel: researchModel,
                    deadline: deadline
                )
                reportMarkdown = verification.reportMarkdown
                unverifiedClaimCount = verification.unverifiedClaimCount
            } catch {
                degradationNotes.append(
                    "Verification: the report shipped unverified because \(error.localizedDescription)"
                )
            }
        }

        return await completedResult(
            reportMarkdown: reportMarkdown,
            unverifiedClaimCount: unverifiedClaimCount,
            plan: plan,
            outcomes: outcomes,
            evidenceStore: evidenceStore,
            degradationNotes: degradationNotes,
            forcePartial: Task.isCancelled
        )
    }

    private struct ClarifyingQuestionsResponse: Decodable {
        let questions: [String]
    }

    private func partialResult(
        plan: ResearchPlan,
        context: ResearchPlanContext,
        outcomes: [ThreadOutcome],
        evidenceStore: EvidenceStore,
        degradationNotes: [String]
    ) async -> DeepResearchRunResult {
        await completedResult(
            reportMarkdown: mechanicalBody(
                overview: plan.overview,
                surfaceLines: context.surfaceLines,
                outcomes: outcomes
            ),
            unverifiedClaimCount: 0,
            plan: plan,
            outcomes: outcomes,
            evidenceStore: evidenceStore,
            degradationNotes: degradationNotes,
            forcePartial: true
        )
    }

    private func completedResult(
        reportMarkdown: String,
        unverifiedClaimCount: Int,
        plan: ResearchPlan,
        outcomes: [ThreadOutcome],
        evidenceStore: EvidenceStore,
        degradationNotes: [String],
        forcePartial: Bool
    ) async -> DeepResearchRunResult {
        var seenOpenQuestions = Set<String>()
        let openQuestions = plan.threads.compactMap { thread -> String? in
            guard let outcome = outcomes.first(where: { $0.question == thread.question }),
                  outcome.isAnswered else {
                return seenOpenQuestions.insert(thread.question).inserted ? thread.question : nil
            }
            return nil
        }
        let sources = await evidenceStore.numberedList().map {
            ResearchSource(index: $0.index, title: $0.title, url: $0.url)
        }
        let evidence = await evidenceStore.allEvidence()
        let body: String
        if openQuestions.isEmpty || reportMarkdown.contains("## Open questions") {
            body = reportMarkdown
        } else {
            body = reportMarkdown + "\n\n## Open questions\n" + openQuestions
                .map { "- \($0)" }
                .joined(separator: "\n")
        }

        return DeepResearchRunResult(
            reportMarkdown: body,
            openQuestions: openQuestions,
            sources: sources,
            evidence: evidence,
            unverifiedClaimCount: unverifiedClaimCount,
            degradationNotes: degradationNotes,
            // Open questions and ⚠-flagged claims are honesty features of a
            // healthy run, not degradation — they carry their own signals.
            isPartial: forcePartial || !degradationNotes.isEmpty
        )
    }

    // MARK: - Analysis (Research Model)

    private struct PlanGenerationResult: Sendable {
        let plan: ResearchPlan
        let degradationNote: String?
    }

    private func analysisPlan(
        subject: String,
        surfaceLines: [String],
        maxThreads: Int,
        researchModel: String,
        deadline: ContinuousClock.Instant,
        clarifications: [ResearchClarification] = []
    ) async -> PlanGenerationResult {
        let clarificationSection = clarifications.isEmpty ? "" : """


            Clarifications from the user:
            \(clarifications.map { "Question: \($0.question)\nAnswer: \($0.answer)" }.joined(separator: "\n"))
            """
        let prompt = """
            You are the lead investigator planning a deep web investigation. \
            Today's date is \(Date.now.formatted(date: .long, time: .omitted)).

            # Purpose
            Plan the most useful follow-up research threads from the surface \
            search results.

            Topic under investigation: \(subject)\(clarificationSection)

            Surface search results:
            \(surfaceLines.joined(separator: "\n"))

            Based on the key facts, entities, and open questions in these results, \
            decide the most valuable follow-up lines of inquiry. Respond ONLY with \
            JSON in exactly this shape, no markdown fences or commentary:
            {"overview": "2-3 sentence broad picture of the topic from the surface results", \
            "threads": [{"question": "what this thread should determine", \
            "query": "the web search query to run"}]}

            Plan at most \(maxThreads) threads. Prefer fewer, sharper threads over \
            redundant ones. Each query must be a specific, standalone web search.
            """

        do {
            let response = try await withRetries(deadline: deadline, label: "analysis") {
                try await completeWithDeadline(
                    messages: [.user(prompt)],
                    model: researchModel,
                    deadline: deadline
                )
            }

            if let plan = Self.decodeJSON(ResearchPlan.self, from: response) {
                return PlanGenerationResult(
                    plan: ResearchPlan(
                        overview: plan.overview,
                        threads: Array(plan.threads.prefix(maxThreads))
                    ),
                    degradationNote: nil
                )
            }

            Self.logger.error("Analysis response was not valid plan JSON; using fallback thread")
        } catch {
            Self.logger.error("""
                Analysis failed: \(String(describing: error), privacy: .public); \
                using fallback thread
                """)
        }

        // Fallback: a single straightforward follow-up so the investigation
        // still goes one level deeper than the surface pass.
        return PlanGenerationResult(
            plan: ResearchPlan(
                overview: "",
                threads: [ResearchThreadPlan(
                    question: "What additional detail and context exists on \(subject)?",
                    query: "\(subject) details explained"
                )]
            ),
            degradationNote: "Planning: the model plan was unavailable, so a single general thread was used."
        )
    }

    // MARK: - Sub-agents (Swift Model)

    private struct ThreadOutcome: Sendable {
        let question: String
        let finding: String
        let note: String?
        /// True when the engine wrote the finding itself as a failure
        /// placeholder (skipped, search failed, no results, analysis failed)
        /// rather than receiving it from the model.
        var failed = false

        var isAnswered: Bool {
            guard !failed else { return false }
            // The extraction prompts ask the model to "say what is and isn't
            // established" when evidence falls short; treat those hedges as
            // unanswered so the thread lands in Open questions.
            let normalized = finding.lowercased()
            let hedges = [
                "isn't established",
                "is not established",
                "remains unanswered",
            ]
            return !finding.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !hedges.contains(where: normalized.contains)
        }
    }

    private func runThreads(
        _ threads: [ResearchThreadPlan],
        evidenceStore: EvidenceStore,
        budget: ResearchBudget,
        swiftModel: String,
        deadline: ContinuousClock.Instant,
        progress: ProgressHandler? = nil
    ) async -> [ThreadOutcome] {
        await withTaskGroup(of: (Int, ThreadOutcome).self) { group in
            for (index, thread) in threads.enumerated() {
                group.addTask {
                    (index, await investigateThread(
                        thread,
                        evidenceStore: evidenceStore,
                        budget: budget,
                        swiftModel: swiftModel,
                        deadline: deadline,
                        progress: progress
                    ))
                }
            }

            var outcomes = [ThreadOutcome?](repeating: nil, count: threads.count)
            for await (index, outcome) in group {
                outcomes[index] = outcome
            }

            return outcomes.compactMap(\.self)
        }
    }

    private func investigateThread(
        _ thread: ResearchThreadPlan,
        evidenceStore: EvidenceStore,
        budget: ResearchBudget,
        swiftModel: String,
        deadline: ContinuousClock.Instant,
        progress: ProgressHandler? = nil
    ) async -> ThreadOutcome {
        guard ContinuousClock.now + .seconds(5) < deadline else {
            return ThreadOutcome(
                question: thread.question,
                finding: "This thread was not investigated.",
                note: "Skipped — the investigation time budget ran out",
                failed: true
            )
        }

        let results: [BraveSearchClient.Result]
        do {
            progress?(.activity("Searching: \(thread.query)"))
            results = try await searchWithRetries(
                query: thread.query,
                count: Self.threadResultCount,
                deadline: deadline,
                budget: budget
            )
            Self.logger.info("""
                Sub-agent thread searched the web and found \
                \(results.count, privacy: .public) results
                """)
        } catch {
            return ThreadOutcome(
                question: thread.question,
                finding: "The follow-up search could not be completed.",
                note: Self.failureNote(for: error),
                failed: true
            )
        }

        guard !results.isEmpty else {
            return ThreadOutcome(
                question: thread.question,
                finding: "No web results were found for the follow-up query \"\(thread.query)\".",
                note: nil,
                failed: true
            )
        }

        if case .fetchPages(let maxBytesPerPage) = configuration.sourceMode {
            return await investigateFetchedThread(
                thread,
                results: results,
                evidenceStore: evidenceStore,
                budget: budget,
                swiftModel: swiftModel,
                maxBytesPerPage: maxBytesPerPage,
                deadline: deadline,
                progress: progress
            )
        }

        let resultLines = await numberedLines(for: results, in: evidenceStore)
        let prompt = """
            You are a research sub-agent. Today's date is \
            \(Date.now.formatted(date: .long, time: .omitted)).

            # Purpose
            Answer one focused research question using only the provided search \
            results.

            Question to answer: \(thread.question)

            Search results (each begins with its source number in brackets):
            \(resultLines.joined(separator: "\n"))

            Write 2-4 sentences answering the question using only these results, \
            citing source numbers like [3] after each claim. If the results don't \
            fully answer the question, say what is and isn't established. Reply \
            with the sentences only.
            """

        do {
            let finding = try await withRetries(deadline: deadline, label: "extraction") {
                try await completeWithDeadline(
                    messages: [.user(prompt)],
                    model: swiftModel,
                    deadline: deadline
                )
            }

            return ThreadOutcome(
                question: thread.question,
                finding: finding.trimmingCharacters(in: .whitespacesAndNewlines),
                note: nil
            )
        } catch {
            let mentions = await evidenceStore.indices(forURLs: results.map(\.url))
                .map { "[\($0)]" }
                .joined(separator: ", ")

            return ThreadOutcome(
                question: thread.question,
                finding: "Sources \(mentions) were found but could not be analyzed.",
                note: Self.failureNote(for: error),
                failed: true
            )
        }
    }

    private struct FetchedThreadMaterial: Sendable {
        let sourceIndex: Int
        let url: String
        let title: String
        let text: String
        let retrievedAt: Date
        let isSnippetFallback: Bool
        let fallbackReason: String?
    }

    private struct ThreadEvidenceResponse: Decodable, Sendable {
        let finding: String
        let evidence: [ProposedEvidence]
    }

    private struct ProposedEvidence: Decodable, Sendable {
        let sourceIndex: Int
        let quote: String
        let claimSummary: String
    }

    private func investigateFetchedThread(
        _ thread: ResearchThreadPlan,
        results: [BraveSearchClient.Result],
        evidenceStore: EvidenceStore,
        budget: ResearchBudget,
        swiftModel: String,
        maxBytesPerPage: Int,
        deadline: ContinuousClock.Instant,
        progress: ProgressHandler? = nil
    ) async -> ThreadOutcome {
        var materials = [FetchedThreadMaterial]()

        for result in results.prefix(configuration.pagesPerThread) {
            let sourceIndex = await evidenceStore.register(title: result.title, url: result.url)
            let fallback: (String) -> FetchedThreadMaterial = { reason in
                FetchedThreadMaterial(
                    sourceIndex: sourceIndex,
                    url: result.url,
                    title: result.title,
                    text: WebSearchFormatter.snippet(from: result.description, maxLength: 220),
                    retrievedAt: .now,
                    isSnippetFallback: true,
                    fallbackReason: reason
                )
            }

            guard let url = URL(string: result.url) else {
                materials.append(fallback("the result URL was invalid"))
                continue
            }

            guard await budget.leasePageFetch() else {
                materials.append(fallback("the page-fetch budget or work window was exhausted"))
                continue
            }

            do {
                let page = try await pageFetcher.fetch(url: url, maxBytes: maxBytesPerPage)
                let isHTML = page.mimeType == "text/html"
                    || page.mimeType == "application/xhtml+xml"
                let extractedText = isHTML
                    ? contentExtractor.extractMainText(fromHTML: page.bodyText)
                    : page.bodyText.trimmingCharacters(in: .whitespacesAndNewlines)

                guard !extractedText.isEmpty else {
                    materials.append(fallback("the page contained no readable text"))
                    continue
                }

                let extractedTitle = isHTML
                    ? contentExtractor.extractTitle(fromHTML: page.bodyText)
                    : nil
                materials.append(FetchedThreadMaterial(
                    sourceIndex: sourceIndex,
                    url: page.finalURL.absoluteString,
                    title: extractedTitle ?? result.title,
                    text: String(extractedText.prefix(Self.pageTextCharacterLimit)),
                    retrievedAt: .now,
                    isSnippetFallback: false,
                    fallbackReason: nil
                ))
                progress?(.activity("Read: \(extractedTitle ?? result.title)"))
            } catch {
                Self.logger.info("Page fetch failed: \(String(describing: error))")
                materials.append(fallback(error.localizedDescription))
            }
        }

        let sourceMaterial = materials.map { material in
            if material.isSnippetFallback {
                return """
                    [\(material.sourceIndex)] \(material.title)
                    Snippet fallback (\(material.fallbackReason ?? "page unavailable")): \(material.text)
                    """
            }

            return """
                [\(material.sourceIndex)] \(material.title)
                Page text:
                \(material.text)
                """
        }
        .joined(separator: "\n\n")

        let prompt = """
            You are a research sub-agent. Today's date is \
            \(Date.now.formatted(date: .long, time: .omitted)).

            # Purpose
            Answer one focused research question using only the provided page \
            text and clearly marked snippet fallbacks.

            Question to answer: \(thread.question)

            Source material (each begins with its source number in brackets):
            \(sourceMaterial)

            Respond ONLY with JSON in exactly this shape, with no markdown fences \
            or commentary:
            {"finding": "2-4 sentences with source citations like [3]", \
            "evidence": [{"sourceIndex": 3, "quote": "verbatim sentence(s) from that source", \
            "claimSummary": "what the quote supports"}]}

            Use only the supplied material. Cite a source number after each claim. \
            Every evidence quote must be copied verbatim from that source's Page \
            text. Do not create evidence records from Snippet fallback material. \
            If the material does not fully answer the question, say what is and \
            is not established in finding.
            """

        do {
            let response = try await withRetries(deadline: deadline, label: "extraction") {
                try await completeWithDeadline(
                    messages: [.user(prompt)],
                    model: swiftModel,
                    deadline: deadline
                )
            }

            guard let decoded = Self.decodeJSON(ThreadEvidenceResponse.self, from: response) else {
                throw EvidenceResponseError.invalidJSON
            }

            let fetchedByIndex = materials
                .filter { !$0.isSnippetFallback }
                .reduce(into: [Int: FetchedThreadMaterial]()) { result, material in
                    result[material.sourceIndex] = material
                }
            for evidence in decoded.evidence {
                guard let material = fetchedByIndex[evidence.sourceIndex],
                      !evidence.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !evidence.claimSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      material.text.contains(evidence.quote) else {
                    continue
                }

                await evidenceStore.addEvidence(
                    sourceIndex: evidence.sourceIndex,
                    url: material.url,
                    title: material.title,
                    quote: evidence.quote,
                    claimSummary: evidence.claimSummary,
                    retrievedAt: material.retrievedAt
                )
            }

            let evidenceCount = (await evidenceStore.allEvidence()).count
            progress?(.activity("Evidence: \(evidenceCount) record(s)"))

            let fallbackCount = materials.filter(\.isSnippetFallback).count
            let note = fallbackCount == 0
                ? nil
                : "Partial — \(fallbackCount) page fetch(es) failed; search snippets were used instead"
            return ThreadOutcome(
                question: thread.question,
                finding: decoded.finding.trimmingCharacters(in: .whitespacesAndNewlines),
                note: note
            )
        } catch {
            let mentions = await evidenceStore.indices(forURLs: results.map(\.url))
                .map { "[\($0)]" }
                .joined(separator: ", ")

            return ThreadOutcome(
                question: thread.question,
                finding: "Sources \(mentions) were found but could not be analyzed.",
                note: Self.failureNote(for: error),
                failed: true
            )
        }
    }

    private enum EvidenceResponseError: LocalizedError, Sendable {
        case invalidJSON

        var errorDescription: String? {
            "The evidence response was not valid JSON."
        }
    }

    // MARK: - Reflection (Research Model)

    private struct ReflectionResponse: Decodable, Sendable {
        let threads: [ResearchThreadPlan]
    }

    private func reflectionThreads(
        plan: ResearchPlan,
        outcomes: [ThreadOutcome],
        evidence: [EvidenceRecord],
        researchModel: String,
        deadline: ContinuousClock.Instant
    ) async throws -> [ResearchThreadPlan] {
        guard !researchModel.isEmpty else {
            throw DeepPipelineError.modelNotConfigured
        }

        let prompt = """
            You are reviewing an active deep web research project. Today's date is \
            \(Date.now.formatted(date: .long, time: .omitted)).

            # Purpose
            Identify specific questions that remain unanswered or contradictory.

            Research plan:
            \(planText(plan))

            Thread findings:
            \(outcomesText(outcomes))

            Evidence summaries:
            \(evidenceText(evidence))

            Respond ONLY with JSON in exactly this shape, with no markdown fences \
            or commentary:
            {"threads": [{"question": "specific unresolved question", \
            "query": "standalone web search query"}]}

            Return at most \(configuration.maxThreads) follow-up threads. Return an \
            empty array when the evidence is sufficient. Do not repeat completed threads.
            """
        let response = try await withRetries(deadline: deadline, label: "reflection") {
            try await completeWithDeadline(
                messages: [.user(prompt)],
                model: researchModel,
                deadline: deadline
            )
        }
        guard let decoded = Self.decodeJSON(ReflectionResponse.self, from: response) else {
            throw DeepPipelineError.invalidReflection
        }

        return Array(decoded.threads
            .filter {
                !$0.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !$0.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .prefix(configuration.maxThreads))
    }

    // MARK: - Outline-first writing (Research Model)

    private struct OutlineResponse: Decodable, Sendable {
        let sections: [OutlineSection]
    }

    private struct OutlineSection: Decodable, Sendable {
        let heading: String
        let sourceIndices: [Int]
    }

    private struct IntroductionConclusionResponse: Decodable, Sendable {
        let introduction: String
        let conclusion: String
    }

    private struct WriteResult: Sendable {
        let body: String
        let degradationNotes: [String]
    }

    private func writtenBody(
        subject: String,
        plan: ResearchPlan,
        surfaceLines: [String],
        outcomes: [ThreadOutcome],
        evidence: [EvidenceRecord],
        researchModel: String,
        deadline: ContinuousClock.Instant
    ) async -> WriteResult {
        guard case .document(let outlineFirst) = configuration.reportStyle, outlineFirst else {
            let body = await synthesizedBody(
                subject: subject,
                overview: plan.overview,
                surfaceLines: surfaceLines,
                outcomes: outcomes,
                researchModel: researchModel,
                deadline: deadline
            )
            return WriteResult(
                body: body ?? mechanicalBody(
                    overview: plan.overview,
                    surfaceLines: surfaceLines,
                    outcomes: outcomes
                ),
                degradationNotes: body == nil
                    ? ["Writing: synthesis failed, so the raw findings were used."]
                    : []
            )
        }

        do {
            guard !researchModel.isEmpty else {
                throw DeepPipelineError.modelNotConfigured
            }
            let outlinePrompt = """
                You are outlining a deep research report. Today's date is \
                \(Date.now.formatted(date: .long, time: .omitted)).

                # Purpose
                Design an evidence-backed report outline before drafting prose.

                Topic: \(subject)

                Research plan:
                \(planText(plan))

                Thread findings:
                \(outcomesText(outcomes))

                Evidence summaries:
                \(evidenceText(evidence))

                Respond ONLY with JSON in exactly this shape, with no markdown fences \
                or commentary:
                {"sections": [{"heading": "specific section heading", \
                "sourceIndices": [1, 3]}]}

                Return 3-6 sections. Assign only source indices shown above. Length \
                target: \(configuration.reportLengthDirective). Do not include \
                introduction, conclusion, Open questions, or Sources sections.
                """
            let response = try await withRetries(deadline: deadline, label: "outline") {
                try await completeWithDeadline(
                    messages: [.user(outlinePrompt)],
                    model: researchModel,
                    deadline: deadline
                )
            }
            guard let outline = Self.decodeJSON(OutlineResponse.self, from: response),
                  (3...6).contains(outline.sections.count),
                  outline.sections.allSatisfy({
                      !$0.heading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  }) else {
                throw DeepPipelineError.invalidOutline
            }

            var notes = [String]()
            var draftedSections = [String]()
            for section in outline.sections {
                let assignedOutcomes = outcomes.filter {
                    !Set(Self.citationIndices(in: $0.finding))
                        .isDisjoint(with: Set(section.sourceIndices))
                }
                let assignedEvidence = evidence.filter {
                    section.sourceIndices.contains($0.sourceIndex)
                }

                if Task.isCancelled {
                    draftedSections.append(mechanicalSection(
                        heading: section.heading,
                        outcomes: assignedOutcomes
                    ))
                    notes.append(
                        "Writing: section “\(section.heading)” used raw findings after cancellation."
                    )
                    continue
                }

                let sectionPrompt = """
                    You are drafting one section of a deep research report. \
                    Today's date is \(Date.now.formatted(date: .long, time: .omitted)).

                    # Purpose
                    Draft the requested section using only its assigned findings and evidence.

                    Topic: \(subject)
                    Section heading: \(section.heading)

                    Assigned thread findings:
                    \(outcomesText(assignedOutcomes))

                    Assigned evidence:
                    \(evidenceText(assignedEvidence))

                    Length target: \(configuration.reportLengthDirective). Use paragraphs \
                    or a focused bullet list when it presents the evidence more clearly. \
                    Cite source numbers like [3] after claims. State gaps or contradictions \
                    plainly. Reply with the section body only, without a heading or commentary.
                    """

                do {
                    let draft = try await withRetries(deadline: deadline, label: "section writing") {
                        try await completeWithDeadline(
                            messages: [.user(sectionPrompt)],
                            model: researchModel,
                            deadline: deadline
                        )
                    }
                    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        throw DeepPipelineError.emptySection
                    }
                    draftedSections.append("## \(section.heading)\n\(trimmed)")
                } catch {
                    draftedSections.append(mechanicalSection(
                        heading: section.heading,
                        outcomes: assignedOutcomes
                    ))
                    notes.append(
                        "Writing: section “\(section.heading)” used raw findings because \(error.localizedDescription)"
                    )
                }
            }

            let sectionsText = draftedSections.joined(separator: "\n\n")
            guard !Task.isCancelled else {
                return WriteResult(body: sectionsText, degradationNotes: notes)
            }

            let bookendsPrompt = """
                You are finishing a deep research report. Today's date is \
                \(Date.now.formatted(date: .long, time: .omitted)).

                # Purpose
                Write the introduction and conclusion after reading the drafted sections.

                Topic: \(subject)
                Plan overview: \(plan.overview.isEmpty ? "(none)" : plan.overview)

                Drafted sections:
                \(sectionsText)

                Respond ONLY with JSON in exactly this shape, with no markdown fences \
                or commentary:
                {"introduction": "1-2 concise paragraphs", \
                "conclusion": "1 concise paragraph"}

                Preserve the sections' source citations in any factual claims. Do not \
                add headings, a title, an Open questions section, or a Sources section.
                """
            do {
                let response = try await withRetries(deadline: deadline, label: "report bookends") {
                    try await completeWithDeadline(
                        messages: [.user(bookendsPrompt)],
                        model: researchModel,
                        deadline: deadline
                    )
                }
                guard let bookends = Self.decodeJSON(
                    IntroductionConclusionResponse.self,
                    from: response
                ), !bookends.introduction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    !bookends.conclusion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw DeepPipelineError.invalidBookends
                }
                return WriteResult(
                    body: """
                        ## Overview
                        \(bookends.introduction.trimmingCharacters(in: .whitespacesAndNewlines))

                        \(sectionsText)

                        ## Conclusion
                        \(bookends.conclusion.trimmingCharacters(in: .whitespacesAndNewlines))
                        """,
                    degradationNotes: notes
                )
            } catch {
                notes.append(
                    "Writing: introduction and conclusion were omitted because \(error.localizedDescription)"
                )
                return WriteResult(body: sectionsText, degradationNotes: notes)
            }
        } catch {
            var notes = [
                "Writing: outline generation failed, so single-pass synthesis was used (\(error.localizedDescription))"
            ]
            let body = await synthesizedBody(
                subject: subject,
                overview: plan.overview,
                surfaceLines: surfaceLines,
                outcomes: outcomes,
                researchModel: researchModel,
                deadline: deadline
            )
            if let body {
                return WriteResult(body: body, degradationNotes: notes)
            }

            notes.append("Writing: single-pass synthesis also failed, so the raw findings were used.")
            return WriteResult(
                body: mechanicalBody(
                    overview: plan.overview,
                    surfaceLines: surfaceLines,
                    outcomes: outcomes
                ),
                degradationNotes: notes
            )
        }
    }

    private func mechanicalSection(heading: String, outcomes: [ThreadOutcome]) -> String {
        let body = outcomes.isEmpty
            ? "No gathered finding was assigned to this section."
            : outcomes.map { outcome in
                var text = outcome.finding
                if let note = outcome.note {
                    text += "\n\n*\(note).*"
                }
                return text
            }
            .joined(separator: "\n\n")
        return "## \(heading)\n\(body)"
    }

    // MARK: - Claim verification (Swift Model)

    private struct CitedClaim: Sendable {
        let id: Int
        let text: String
        let sourceIndices: [Int]
        let markerOffset: Int
        let isSubstantive: Bool
    }

    private struct VerificationResponse: Decodable, Sendable {
        let verdicts: [ClaimVerdict]
    }

    private struct ClaimVerdict: Decodable, Sendable {
        let id: Int
        let verdict: String
    }

    private struct VerificationResult: Sendable {
        let reportMarkdown: String
        let unverifiedClaimCount: Int
    }

    private func verify(
        reportMarkdown: String,
        evidence: [EvidenceRecord],
        researchModel: String,
        deadline: ContinuousClock.Instant
    ) async throws -> VerificationResult {
        let claims = Self.citedClaims(in: reportMarkdown)
        guard !claims.isEmpty else {
            return VerificationResult(reportMarkdown: reportMarkdown, unverifiedClaimCount: 0)
        }
        guard !researchModel.isEmpty else {
            throw DeepPipelineError.modelNotConfigured
        }

        let claimMaterial = claims.map { claim in
            let records = evidence.filter { claim.sourceIndices.contains($0.sourceIndex) }
            let quotes = records.isEmpty
                ? "(no fetched evidence records for the cited sources)"
                : records.map {
                    "[\($0.sourceIndex)] Claim summary: \($0.claimSummary)\nQuote: \($0.quote)"
                }
                .joined(separator: "\n")
            return """
                Claim \(claim.id): \(claim.text)
                Cited sources: \(claim.sourceIndices.map(String.init).joined(separator: ", "))
                Evidence:
                \(quotes)
                """
        }
        .joined(separator: "\n\n")
        let prompt = """
            You are checking cited claims in a research report. Today's date is \
            \(Date.now.formatted(date: .long, time: .omitted)).

            # Purpose
            Judge whether each claim is supported by the fetched evidence for its citations.

            Claims and evidence:
            \(claimMaterial)

            Respond ONLY with JSON in exactly this shape, with no markdown fences \
            or commentary:
            {"verdicts": [{"id": 1, "verdict": "supported"}]}

            Return one verdict per claim. Verdict must be supported, unsupported, or \
            no-evidence. Use no-evidence when the cited sources have no fetched quotes. \
            Do not infer support from the claim or source title alone.
            """
        let response = try await withRetries(deadline: deadline, label: "claim verification") {
            try await completeWithDeadline(
                messages: [.user(prompt)],
                model: researchModel,
                deadline: deadline
            )
        }
        guard let decoded = Self.decodeJSON(VerificationResponse.self, from: response) else {
            throw DeepPipelineError.invalidVerification
        }
        var verdictByID = [Int: String]()
        for verdict in decoded.verdicts {
            guard verdictByID[verdict.id] == nil else {
                throw DeepPipelineError.invalidVerification
            }
            verdictByID[verdict.id] = verdict.verdict.lowercased()
        }
        guard claims.allSatisfy({ verdictByID[$0.id] != nil }),
              verdictByID.values.allSatisfy({
                  ["supported", "unsupported", "no-evidence"].contains($0)
              }) else {
            throw DeepPipelineError.invalidVerification
        }

        let evidenceIndices = Set(evidence.map(\.sourceIndex))
        let markerOffsets = claims.compactMap { claim -> Int? in
            switch verdictByID[claim.id] {
            case "unsupported":
                return claim.markerOffset
            case "no-evidence"
                where claim.isSubstantive
                    && Set(claim.sourceIndices).isDisjoint(with: evidenceIndices):
                return claim.markerOffset
            default:
                return nil
            }
        }
        let mutable = NSMutableString(string: reportMarkdown)
        for offset in Set(markerOffsets).sorted(by: >) {
            mutable.insert(" ⚠", at: offset)
        }
        return VerificationResult(
            reportMarkdown: mutable as String,
            unverifiedClaimCount: Set(markerOffsets).count
        )
    }

    private static func citedClaims(in report: String) -> [CitedClaim] {
        let text = report as NSString
        let citationPattern = try! NSRegularExpression(pattern: #"\[(\d+)\]"#)
        var claims = [CitedClaim]()
        var lineLocation = 0

        while lineLocation < text.length {
            let lineRange = text.lineRange(for: NSRange(location: lineLocation, length: 0))
            let lineEnd = min(NSMaxRange(lineRange), text.length)
            let contentRange = NSRange(location: lineRange.location, length: lineEnd - lineRange.location)
            let line = text.substring(with: contentRange) as NSString
            var sentenceStart = 0

            while sentenceStart < line.length {
                var sentenceEnd = line.length
                if sentenceStart < line.length {
                    for index in sentenceStart..<line.length {
                        let character = line.character(at: index)
                        guard character == 46 || character == 33 || character == 63 else {
                            continue
                        }
                        let next = index + 1
                        if next == line.length
                            || Self.isWhitespaceUTF16(line.character(at: next)) {
                            sentenceEnd = next
                            break
                        }
                    }
                }

                let sentenceRange = NSRange(
                    location: sentenceStart,
                    length: max(0, sentenceEnd - sentenceStart)
                )
                let citations = citationPattern.matches(
                    in: line as String,
                    range: sentenceRange
                )
                if let lastCitation = citations.last {
                    let sourceIndices = citations.compactMap { match -> Int? in
                        guard match.numberOfRanges > 1 else { return nil }
                        return Int(line.substring(with: match.range(at: 1)))
                    }
                    let rawClaim = line.substring(with: sentenceRange)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let plainClaim = rawClaim.replacingOccurrences(
                        of: #"^#{1,6}\s+|^[-*]\s+"#,
                        with: "",
                        options: .regularExpression
                    )
                    let wordCount = plainClaim.split(whereSeparator: { $0.isWhitespace }).count
                    claims.append(CitedClaim(
                        id: claims.count + 1,
                        text: plainClaim,
                        sourceIndices: Array(Set(sourceIndices)).sorted(),
                        markerOffset: lineRange.location + NSMaxRange(lastCitation.range),
                        isSubstantive: wordCount >= 5
                    ))
                }

                sentenceStart = sentenceEnd
                while sentenceStart < line.length,
                      Self.isWhitespaceUTF16(line.character(at: sentenceStart)) {
                    sentenceStart += 1
                }
            }

            lineLocation = lineEnd
        }
        return claims
    }

    /// Whitespace test on a raw UTF-16 code unit. Surrogate halves (emoji and
    /// other astral characters) are not valid scalars and are never whitespace;
    /// a force-unwrapped `UnicodeScalar` here would crash on them.
    private static func isWhitespaceUTF16(_ codeUnit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(codeUnit) else {
            return false
        }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func citationIndices(in text: String) -> [Int] {
        let expression = try! NSRegularExpression(pattern: #"\[(\d+)\]"#)
        let string = text as NSString
        return expression.matches(
            in: text,
            range: NSRange(location: 0, length: string.length)
        ).compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            return Int(string.substring(with: match.range(at: 1)))
        }
    }

    private func planText(_ plan: ResearchPlan) -> String {
        let threads = plan.threads.enumerated().map { index, thread in
            "\(index + 1). \(thread.question) — query: \(thread.query)"
        }
        .joined(separator: "\n")
        return "Overview: \(plan.overview.isEmpty ? "(none)" : plan.overview)\n\(threads)"
    }

    private func outcomesText(_ outcomes: [ThreadOutcome]) -> String {
        guard !outcomes.isEmpty else { return "(none)" }
        return outcomes.map { outcome in
            var text = "Question: \(outcome.question)\nFinding: \(outcome.finding)"
            if let note = outcome.note {
                text += "\nStatus: \(note)"
            }
            return text
        }
        .joined(separator: "\n\n")
    }

    private func evidenceText(_ evidence: [EvidenceRecord]) -> String {
        guard !evidence.isEmpty else { return "(no fetched evidence records)" }
        return evidence.map {
            "[\($0.sourceIndex)] \($0.title)\nClaim: \($0.claimSummary)\nQuote: \($0.quote)"
        }
        .joined(separator: "\n\n")
    }

    private enum DeepPipelineError: LocalizedError, Sendable {
        case modelNotConfigured
        case invalidReflection
        case invalidOutline
        case emptySection
        case invalidBookends
        case invalidVerification

        var errorDescription: String? {
            switch self {
            case .modelNotConfigured:
                "the required model is not configured."
            case .invalidReflection:
                "the reflection response was not valid JSON."
            case .invalidOutline:
                "the outline response was not valid 3-6 section JSON."
            case .emptySection:
                "the drafted section was empty."
            case .invalidBookends:
                "the introduction and conclusion response was not valid JSON."
            case .invalidVerification:
                "the claim-verification response was not valid JSON."
            }
        }
    }

    // MARK: - Synthesis (Research Model)

    private func synthesizedBody(
        subject: String,
        overview: String,
        surfaceLines: [String],
        outcomes: [ThreadOutcome],
        researchModel: String,
        deadline: ContinuousClock.Instant
    ) async -> String? {
        let threadSection = outcomes.map { outcome in
            var lines = ["Question: \(outcome.question)", "Finding: \(outcome.finding)"]
            if let note = outcome.note {
                lines.append("Status: \(note)")
            }
            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n")

        let presentationDirective: String
        switch configuration.reportStyle {
        case .conversational:
            presentationDirective = """
                Write a short overview paragraph, then add "## Key findings" with the \
                most useful facts as concise bullets. Keep it conversational and under \
                ~400 words; do not use a rigid section template. Do not add a title or a \
                Sources section.
                """
        case .document:
            presentationDirective = """
                Write a document-style report with a short overview, descriptive findings \
                sections that connect the evidence across threads, and a conclusion. Use \
                clear markdown headings. Length target: \(configuration.reportLengthDirective). \
                Do not add a title, an Open questions section, or a Sources section.
                """
        }

        let prompt = """
            You are the lead investigator writing the final report of a multi-search web \
            investigation. Today's date is \(Date.now.formatted(date: .long, time: .omitted)).

            # Purpose
            Turn the surface results and follow-up findings into a sourced research report.

            Topic: \(subject)

            Initial overview from the surface pass: \(overview.isEmpty ? "(none)" : overview)

            Surface search results (each begins with its source number in brackets):
            \(surfaceLines.joined(separator: "\n"))

            Follow-up thread findings:
            \(threadSection)

            Cross-reference everything above and write the report body in markdown. \
            \(presentationDirective)

            Rules: cite source numbers like [3] inline after claims; only cite numbers \
            that appear above; if a thread has a Status note, state plainly that its \
            results are partial or missing and why. Reply with the markdown only.
            """

        do {
            let body = try await withRetries(deadline: deadline, label: "synthesis") {
                try await completeWithDeadline(
                    messages: [.user(prompt)],
                    model: researchModel,
                    deadline: deadline
                )
            }

            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            Self.logger.error("""
                Synthesis failed: \(String(describing: error), privacy: .public); \
                falling back to mechanical report
                """)
            return nil
        }
    }

    /// Assembles the report body without a model when synthesis fails, so the
    /// user still gets the gathered findings.
    private func mechanicalBody(
        overview: String,
        surfaceLines: [String],
        outcomes: [ThreadOutcome]
    ) -> String {
        var sections = [String]()

        if !overview.isEmpty {
            sections.append("## Overview\n\(overview)")
        }

        sections.append("## Key Findings\n" + surfaceLines.joined(separator: "\n"))

        if !outcomes.isEmpty {
            let threads = outcomes.map { outcome in
                var text = "### \(outcome.question)\n\(outcome.finding)"
                if let note = outcome.note {
                    text += "\n\n*\(note).*"
                }
                return text
            }
            .joined(separator: "\n\n")

            sections.append("## Deeper Findings\n\(threads)")
        }

        sections.append("*Note: automated synthesis was unavailable; this report lists the raw findings.*")

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Search + retry plumbing

    private func searchWithRetries(
        query: String,
        count: Int,
        deadline: ContinuousClock.Instant,
        budget: ResearchBudget
    ) async throws -> [BraveSearchClient.Result] {
        guard await budget.leaseSearchCall() else {
            throw DeadlineExceededError()
        }

        return try await withRetries(deadline: deadline, label: "search") {
            try await searchProvider(query, count)
        }
    }

    private func completeWithDeadline(
        messages: [InferenceMessage],
        model: String,
        deadline: ContinuousClock.Instant
    ) async throws -> String {
        try await withDeadline(deadline) {
            try await completionProvider(messages, model)
        }
    }

    private func withDeadline<T: Sendable>(
        _ deadline: ContinuousClock.Instant,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let now = ContinuousClock.now

        guard now < deadline else {
            throw DeadlineExceededError()
        }

        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(for: now.duration(to: deadline))
                throw DeadlineExceededError()
            }

            defer {
                group.cancelAll()
            }

            guard let result = try await group.next() else {
                throw DeadlineExceededError()
            }

            return result
        }
    }

    /// Runs an operation with up to ``maxAttempts`` tries, backing off
    /// exponentially (honoring Retry-After) while the deadline allows.
    private func withRetries<T: Sendable>(
        deadline: ContinuousClock.Instant,
        label: String,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        var attempt = 1

        while true {
            do {
                return try await operation()
            } catch {
                let delay = Self.retryDelay(for: error, attempt: attempt)

                guard attempt < Self.maxAttempts,
                      Self.isRetryable(error),
                      ContinuousClock.now + delay < deadline else {
                    throw error
                }

                Self.logger.info("""
                    Retrying \(label, privacy: .public) (attempt \
                    \(attempt + 1, privacy: .public)) after error: \
                    \(String(describing: error), privacy: .public)
                    """)

                try? await Task.sleep(for: delay)
                attempt += 1
            }
        }
    }

    private static func isRetryable(_ error: any Error) -> Bool {
        if error is CancellationError {
            return false
        }

        if error is DeadlineExceededError {
            return false
        }

        if let clientError = error as? BraveSearchClient.ClientError {
            return clientError.isRetryable
        }

        // Configuration problems won't fix themselves mid-run.
        if error is InferenceError || error is ToolError {
            return false
        }

        // Anything else (network hiccups, provider 429/5xx) is worth retrying.
        return true
    }

    private static func retryDelay(for error: any Error, attempt: Int) -> Duration {
        if let suggested = (error as? BraveSearchClient.ClientError)?.suggestedRetryDelay {
            return .seconds(suggested)
        }

        let backoff = pow(2, Double(attempt - 1))
        return .seconds(backoff + Double.random(in: 0...0.5))
    }

    // MARK: - Sources and formatting

    private func numberedLines(
        for results: [BraveSearchClient.Result],
        in evidenceStore: EvidenceStore
    ) async -> [String] {
        var lines = [String]()

        for result in results {
            let index = await evidenceStore.register(title: result.title, url: result.url)
            var line = "[\(index)] \(result.title)"

            if let age = result.age, !age.isEmpty {
                line += " (\(age))"
            }

            let snippet = WebSearchFormatter.snippet(from: result.description, maxLength: 220)
            if !snippet.isEmpty {
                line += " — \(snippet)"
            }

            lines.append(line)
        }

        return lines
    }

    private static func failureNote(for error: any Error) -> String {
        if error is DeadlineExceededError {
            return "Partial — the investigation time budget ran out"
        }

        if let clientError = error as? BraveSearchClient.ClientError,
           case .badResponse(let statusCode, _, _) = clientError,
           statusCode == 429 {
            return "Partial — rate limited by the search API"
        }

        return "Partial — \(error.localizedDescription)"
    }

    /// Decodes model-produced JSON, tolerating markdown fences and prose
    /// around the object.
    private static func decodeJSON<T: Decodable>(_ type: T.Type, from response: String) -> T? {
        guard let start = response.firstIndex(of: "{"),
              let end = response.lastIndex(of: "}") else {
            return nil
        }

        let json = String(response[start...end])
        return try? JSONDecoder().decode(type, from: Data(json.utf8))
    }
}
