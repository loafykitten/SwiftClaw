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

    init(configuration: ResearchConfiguration, pageFetcher: PageFetcher = PageFetcher()) {
        self.configuration = configuration
        self.pageFetcher = pageFetcher
    }

    private struct DeadlineExceededError: LocalizedError, Sendable {
        var errorDescription: String? {
            "The investigation time budget ran out."
        }
    }

    func investigate(topic: String, focus: String?) async throws -> String {
        let researchModel = ResearchModelResolver.resolvedModel()
        let swiftModel = UserDefaults.standard.string(forKey: SettingsKeys.swiftModel) ?? ""

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
        let plan = await analysisPlan(
            subject: subject,
            surfaceLines: surfaceLines,
            maxThreads: configuration.maxThreads,
            researchModel: researchModel,
            deadline: deadline
        )

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

    // MARK: - Analysis (Research Model)

    private struct AnalysisPlan: Decodable {
        var overview: String
        var threads: [ThreadPlan]
    }

    private struct ThreadPlan: Decodable, Sendable {
        var question: String
        var query: String
    }

    private func analysisPlan(
        subject: String,
        surfaceLines: [String],
        maxThreads: Int,
        researchModel: String,
        deadline: ContinuousClock.Instant
    ) async -> AnalysisPlan {
        let prompt = """
            You are the lead investigator planning a deep web investigation. \
            Today's date is \(Date.now.formatted(date: .long, time: .omitted)).

            # Purpose
            Plan the most useful follow-up research threads from the surface \
            search results.

            Topic under investigation: \(subject)

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

            if let plan = Self.decodeJSON(AnalysisPlan.self, from: response) {
                return AnalysisPlan(
                    overview: plan.overview,
                    threads: Array(plan.threads.prefix(maxThreads))
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
        return AnalysisPlan(
            overview: "",
            threads: [ThreadPlan(
                question: "What additional detail and context exists on \(subject)?",
                query: "\(subject) details explained"
            )]
        )
    }

    // MARK: - Sub-agents (Swift Model)

    private struct ThreadOutcome: Sendable {
        let question: String
        let finding: String
        let note: String?
    }

    private func runThreads(
        _ threads: [ThreadPlan],
        evidenceStore: EvidenceStore,
        budget: ResearchBudget,
        swiftModel: String,
        deadline: ContinuousClock.Instant
    ) async -> [ThreadOutcome] {
        await withTaskGroup(of: (Int, ThreadOutcome).self) { group in
            for (index, thread) in threads.enumerated() {
                group.addTask {
                    (index, await investigateThread(
                        thread,
                        evidenceStore: evidenceStore,
                        budget: budget,
                        swiftModel: swiftModel,
                        deadline: deadline
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
        _ thread: ThreadPlan,
        evidenceStore: EvidenceStore,
        budget: ResearchBudget,
        swiftModel: String,
        deadline: ContinuousClock.Instant
    ) async -> ThreadOutcome {
        guard ContinuousClock.now + .seconds(5) < deadline else {
            return ThreadOutcome(
                question: thread.question,
                finding: "This thread was not investigated.",
                note: "Skipped — the investigation time budget ran out"
            )
        }

        let results: [BraveSearchClient.Result]
        do {
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
                note: Self.failureNote(for: error)
            )
        }

        guard !results.isEmpty else {
            return ThreadOutcome(
                question: thread.question,
                finding: "No web results were found for the follow-up query \"\(thread.query)\".",
                note: nil
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
                deadline: deadline
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
                note: Self.failureNote(for: error)
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
        _ thread: ThreadPlan,
        results: [BraveSearchClient.Result],
        evidenceStore: EvidenceStore,
        budget: ResearchBudget,
        swiftModel: String,
        maxBytesPerPage: Int,
        deadline: ContinuousClock.Instant
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
                note: Self.failureNote(for: error)
            )
        }
    }

    private enum EvidenceResponseError: LocalizedError, Sendable {
        case invalidJSON

        var errorDescription: String? {
            "The evidence response was not valid JSON."
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

        let prompt = """
            You are the lead investigator writing the final report of a deep web \
            investigation. Today's date is \(Date.now.formatted(date: .long, time: .omitted)).

            # Purpose
            Turn the surface results and follow-up findings into a concise, \
            sourced investigation report.

            Topic: \(subject)

            Initial overview from the surface pass: \(overview.isEmpty ? "(none)" : overview)

            Surface search results (each begins with its source number in brackets):
            \(surfaceLines.joined(separator: "\n"))

            Follow-up thread findings:
            \(threadSection)

            Cross-reference everything above and write the report body in markdown \
            with exactly these sections:
            ## Overview — 2-3 sentences giving the broad picture.
            ## Key Findings — the most important facts as concise bullets.
            ## Deeper Findings — one "### <thread question>" subsection per \
            follow-up thread, analyzing its outcome in context of the other \
            threads; point out where sources agree, contradict, or leave gaps.

            Rules: cite source numbers like [3] after claims; only cite numbers \
            that appear above; if a thread has a Status note, state plainly that \
            its results are partial or missing and why. Do not add a title, a \
            Sources section, or any sections beyond the three listed. Reply with \
            the markdown only.
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
            try await BraveSearchClient.fromSettings().search(query: query, count: count)
        }
    }

    private func completeWithDeadline(
        messages: [InferenceMessage],
        model: String,
        deadline: ContinuousClock.Instant
    ) async throws -> String {
        try await withDeadline(deadline) {
            try await InferenceService.shared.complete(
                messages: messages,
                model: model,
                systemPromptMode: .standalone
            )
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
