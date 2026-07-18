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

    private let configuration: ResearchConfiguration

    init(configuration: ResearchConfiguration) {
        self.configuration = configuration
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

        let deadline = ContinuousClock.now + configuration.totalBudget
        let subject = focus.map { "\(topic) — focus: \($0)" } ?? topic

        // 1. Surface search.
        let surfaceResults = try await searchWithRetries(
            query: topic,
            count: Self.surfaceResultCount,
            deadline: deadline
        )

        guard !surfaceResults.isEmpty else {
            return "The investigation found no web results for \"\(topic)\"."
        }

        let catalog = SourceCatalog()
        let surfaceLines = await numberedLines(for: surfaceResults, in: catalog)

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
            catalog: catalog,
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

        let sources = await catalog.numberedList()
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
        catalog: SourceCatalog,
        swiftModel: String,
        deadline: ContinuousClock.Instant
    ) async -> [ThreadOutcome] {
        await withTaskGroup(of: (Int, ThreadOutcome).self) { group in
            for (index, thread) in threads.enumerated() {
                group.addTask {
                    (index, await investigateThread(
                        thread,
                        catalog: catalog,
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
        catalog: SourceCatalog,
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
                deadline: deadline
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

        let resultLines = await numberedLines(for: results, in: catalog)
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
            let mentions = await catalog.indices(forURLs: results.map(\.url))
                .map { "[\($0)]" }
                .joined(separator: ", ")

            return ThreadOutcome(
                question: thread.question,
                finding: "Sources \(mentions) were found but could not be analyzed.",
                note: Self.failureNote(for: error)
            )
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
        deadline: ContinuousClock.Instant
    ) async throws -> [BraveSearchClient.Result] {
        try await withRetries(deadline: deadline, label: "search") {
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
        in catalog: SourceCatalog
    ) async -> [String] {
        var lines = [String]()

        for result in results {
            let index = await catalog.register(title: result.title, url: result.url)
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

/// Assigns stable citation numbers to source URLs across the surface pass and
/// all concurrently running sub-agents, de-duplicating by URL.
private actor SourceCatalog {
    private var sources = [(title: String, url: String)]()
    private var indexByURL = [String: Int]()

    /// Registers a source and returns its 1-based citation number.
    func register(title: String, url: String) -> Int {
        if let existing = indexByURL[url] {
            return existing
        }

        sources.append((title: title, url: url))
        let index = sources.count
        indexByURL[url] = index
        return index
    }

    func indices(forURLs urls: [String]) -> [Int] {
        urls.compactMap { indexByURL[$0] }.sorted()
    }

    func numberedList() -> [(index: Int, title: String, url: String)] {
        sources.enumerated().map { offset, source in
            (index: offset + 1, title: source.title, url: source.url)
        }
    }
}
