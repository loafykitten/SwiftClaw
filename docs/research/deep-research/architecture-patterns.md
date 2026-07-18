# Architecture patterns for agentic deep-research pipelines

Research date: 2026-07-18

## Executive conclusion

Serious deep-research systems are not merely “search more, then use a bigger synthesis prompt.” They converge on five capabilities:

1. Iterative control: search, inspect evidence, identify gaps, then search again.
2. Full-page reading: snippets discover sources; fetched page content supplies evidence.
3. Source-tagged compression: workers return compact findings without losing URLs or quotes.
4. Bounded parallelism: independent questions run concurrently, but dependent research proceeds in waves.
5. Citation verification: claims are mapped back to retained source passages, ideally in a separate pass.

Anthropic explicitly uses a lead researcher, parallel subagents, persistent memory, repeated delegation waves, and a separate CitationAgent. OpenAI describes an o3-based browsing policy trained through reinforcement learning rather than a hand-scripted research graph; the ChatGPT product wraps it with clarification and prompt rewriting. Google exposes an autonomous iterative agent through a long-running asynchronous job API, while leaving its internal worker topology undisclosed. (https://www.anthropic.com/engineering/multi-agent-research-system, https://cdn.openai.com/deep-research-system-card.pdf, https://developers.openai.com/api/docs/guides/deep-research.md, https://ai.google.dev/gemini-api/docs/deep-research)

For the existing Investigation pipeline, the highest-value next upgrade is full-page fetching with source-tagged evidence. Citation verification is second; one bounded reflection wave is third. Recursive multi-agent orchestration should come later because it adds substantial cost, state-management work, and failure modes. (https://github.com/langchain-ai/open_deep_research/blob/main/src/open_deep_research/utils.py, https://github.com/Ayanami0730/deep_research_bench/blob/main/README.md, https://www.anthropic.com/engineering/multi-agent-research-system)

---

## 1. Published architectures from the big labs

### Anthropic Research

Anthropic’s system is an explicit orchestrator–worker architecture. A `LeadResearcher` analyzes the question, saves its plan to external memory, launches specialized subagents in parallel, synthesizes their findings, and decides whether to launch another wave. Each worker independently performs iterative searches and uses reasoning between tool calls to assess source quality and refine the next query. (https://www.anthropic.com/engineering/multi-agent-research-system)

The plan is persisted because Anthropic says the lead context may exceed 200,000 tokens and be truncated. The broader context strategy is distributed compression: every worker gets a clean context, explores one branch, and returns only high-value findings; completed phases can also be summarized into external memory. Anthropic additionally recommends storing large worker artifacts outside the coordinator and passing references instead of repeatedly copying them through the lead agent. (https://www.anthropic.com/engineering/multi-agent-research-system)

Parallelism exists at two levels: the lead commonly launches 3–5 subagents simultaneously, and workers issue three or more tool calls in parallel. Anthropic reports that this reduced latency by as much as 90% on complex queries. Current worker waves are nevertheless synchronous from the lead’s perspective: it waits for the wave to finish before deciding what to do next. Anthropic says fully asynchronous steering could improve utilization but would add state-consistency, coordination, and error-propagation problems. (https://www.anthropic.com/engineering/multi-agent-research-system)

Anthropic uses explicit effort heuristics:

- Simple fact: one agent, roughly 3–10 tool calls.
- Comparison: 2–4 subagents, roughly 10–15 calls each.
- Complex research: potentially more than ten specialized subagents.

These are prompt-level resource rules because early versions sometimes spawned 50 workers for simple tasks or searched indefinitely for nonexistent information. (https://www.anthropic.com/engineering/multi-agent-research-system)

The performance comes with a large budget increase. Anthropic reports ordinary agents consuming about four times the tokens of a chat interaction and multi-agent research consuming about fifteen times as many. In its BrowseComp analysis, token use alone explained 80% of performance variance; token use, tool calls, and model choice together explained 95%. Its Opus 4 lead plus Sonnet 4 workers outperformed single-agent Opus 4 by 90.2% on an internal breadth-oriented research evaluation. (https://www.anthropic.com/engineering/multi-agent-research-system)

Citation grounding is a separate terminal stage. After research and report synthesis, a `CitationAgent` examines the documents and report, identifies the precise source locations supporting claims, and inserts citations. This is materially safer than asking the writer to remember URLs from a large context. (https://www.anthropic.com/engineering/multi-agent-research-system)

### OpenAI Deep Research

OpenAI describes the core as an early o3 model optimized for browsing. It was trained through reinforcement learning on research-specific browsing tasks to search, click, scroll, interpret web pages and files, use Python, pivot based on discoveries, and synthesize information across many websites. This is an agent policy learned end-to-end across browsing tasks, not a published fixed graph such as `plan → N searches → extraction → synthesis`. (https://cdn.openai.com/deep-research-system-card.pdf)

The public material does not disclose an Anthropic-style worker hierarchy or prove that every internal component is a single process. The supportable distinction is narrower: OpenAI presents the core as one agentic research model with learned tool use, while product scaffolding performs limited preprocessing around it. (https://cdn.openai.com/deep-research-system-card.pdf, https://developers.openai.com/api/docs/guides/deep-research.md)

ChatGPT’s product flow has three stages:

1. An intermediate model asks clarifying questions.
2. An intermediate model rewrites the request into a detailed research prompt.
3. The deep-research model performs the research.

The Responses API exposes the third stage directly and expects a sufficiently complete prompt; clarification and rewriting are the application’s responsibility. (https://developers.openai.com/api/docs/guides/deep-research.md)

The research model can issue `search`, `open_page`, and `find_in_page` actions, as well as file-search, MCP, and code-interpreter calls. This means its evidence loop includes navigating and reading pages rather than using search snippets alone. Requests may take tens of minutes and are intended to run in background mode. (https://developers.openai.com/api/docs/guides/deep-research.md)

OpenAI exposes `max_tool_calls` as the main cost and latency control. The API returns the complete tool-action trace plus a final message whose inline citations are structured URL annotations. OpenAI requires applications to render those citations visibly and clickably. (https://developers.openai.com/api/docs/guides/deep-research.md)

OpenAI does not publish its internal context-compression algorithm, planning depth, parallel search width, or a separate citation-verifier architecture in the checked sources. Those details should be treated as undisclosed, not inferred from product behavior. (https://cdn.openai.com/deep-research-system-card.pdf, https://developers.openai.com/api/docs/guides/deep-research.md)

### Google Gemini Deep Research

Gemini’s original product flow begins with a multi-step research plan that the user can revise or approve. After approval, Gemini repeatedly searches, reads interesting information, starts new searches based on what it learned, and eventually produces an organized report linked to original sources. The launch description also cited Gemini’s one-million-token context window as an enabling component. (https://blog.google/products-and-platforms/products/gemini/google-gemini-deep-research/)

The current Gemini API describes Deep Research as an autonomous `planning → searching → reading → writing` loop. Collaborative planning can pause execution, return a proposed plan, and allow the client to revise it through another interaction. (https://ai.google.dev/gemini-api/docs/deep-research)

Long-running research must use background execution. The API immediately returns an interaction ID, moves the task through `in_progress`, `completed`, or `failed`, and supports polling or streaming progress and thought summaries. Clients are expected to reconnect if a long-lived stream drops. This is the published asynchronous task-manager boundary; it does not reveal whether the internal researcher uses parallel subagents. (https://ai.google.dev/gemini-api/docs/deep-research)

Google exposes two effort classes rather than a numeric depth control. Its preview estimates say ordinary Deep Research may use roughly 80 searches, 250,000 input tokens, and 60,000 output tokens, while Deep Research Max may reach roughly 160 searches, 900,000 input tokens, and 80,000 output tokens. Google says the agent autonomously determines how much reading and searching is needed. (https://ai.google.dev/gemini-api/docs/deep-research)

Google returns citations and recommends that clients review them, but the checked material does not describe a separate citation model, source-passage alignment algorithm, or internal parallelism strategy. (https://ai.google.dev/gemini-api/docs/deep-research)

### Lab-level comparison

| System | Planning and iteration | Parallelism | Context management | Citation grounding |
|---|---|---|---|---|
| Anthropic | Lead plans, launches workers, reviews findings, and may launch more waves. (https://www.anthropic.com/engineering/multi-agent-research-system) | Explicit parallel subagents and parallel worker tool calls. (https://www.anthropic.com/engineering/multi-agent-research-system) | External plan memory, worker-local contexts, phase summaries, persistent artifacts. (https://www.anthropic.com/engineering/multi-agent-research-system) | Separate CitationAgent aligns report claims to document locations. (https://www.anthropic.com/engineering/multi-agent-research-system) |
| OpenAI | RL-trained browsing model searches and pivots autonomously; product adds clarification and prompt rewriting. (https://cdn.openai.com/deep-research-system-card.pdf, https://developers.openai.com/api/docs/guides/deep-research.md) | Internal topology undisclosed. (https://developers.openai.com/api/docs/guides/deep-research.md) | Internal compression strategy undisclosed; background execution and tool-call cap are exposed. (https://developers.openai.com/api/docs/guides/deep-research.md) | Structured URL annotations in the final message; internal verification mechanism undisclosed. (https://developers.openai.com/api/docs/guides/deep-research.md) |
| Google | User-reviewable plan followed by iterative search/read/search cycles. (https://blog.google/products-and-platforms/products/gemini/google-gemini-deep-research/, https://ai.google.dev/gemini-api/docs/deep-research) | Internal topology undisclosed. (https://ai.google.dev/gemini-api/docs/deep-research) | Long-running background interaction with polling, streaming, and large token use. (https://ai.google.dev/gemini-api/docs/deep-research) | Citations returned, but alignment mechanics undisclosed. (https://ai.google.dev/gemini-api/docs/deep-research) |

---

## 2. Open-source implementations

### GPT Researcher

The ordinary architecture is planner, execution agents, and publisher: generate research questions, gather material for each question, summarize and source-track resources, then aggregate the results. (https://github.com/assafelovic/gpt-researcher/blob/main/README.md)

Its deep mode is a recursive breadth/depth tree:

```text
generate breadth queries
    └─ concurrently run a normal researcher per query
         ├─ search and fetch sources
         ├─ extract learnings and learning→URL mappings
         └─ propose follow-up questions
              └─ recurse with depth-1 and reduced breadth
```

At each recursion level, branches run behind an async semaphore. When descending, breadth becomes `max(2, breadth / 2)` and depth decrements. Defaults are breadth 3, depth 2, and concurrency 4. (https://github.com/assafelovic/gpt-researcher/blob/main/gpt_researcher/skills/deep_research.py, https://github.com/assafelovic/gpt-researcher/blob/main/gpt_researcher/config/variables/default.py)

Stopping is primarily structural: depth exhausted, no generated queries, or all branches failed. This is less adaptive than a learned “enough evidence” decision because a successful branch descends whenever depth remains. (https://github.com/assafelovic/gpt-researcher/blob/main/gpt_researcher/skills/deep_research.py)

Fetched documents can be split into roughly 1,000-character chunks with 100-character overlap and filtered by embedding similarity. Deep mode additionally trims the accumulated context to the most recent 25,000 words. (https://github.com/assafelovic/gpt-researcher/blob/main/gpt_researcher/context/compression.py, https://github.com/assafelovic/gpt-researcher/blob/main/gpt_researcher/skills/deep_research.py)

Citations are carried as a mapping from extracted learning text to URL and then included in the writer’s context. This is better than retaining only an unstructured URL list, but there is no deterministic post-draft check that each cited page entails the final claim. (https://github.com/assafelovic/gpt-researcher/blob/main/gpt_researcher/skills/deep_research.py)

Its “detailed report” mode demonstrates outline-first writing: initial research generates subtopics, each subtopic receives additional research and draft section titles, sections are written separately, and introduction, table of contents, conclusion, and references are assembled afterward. The current implementation processes those subtopic reports sequentially. (https://github.com/assafelovic/gpt-researcher/blob/main/backend/report_type/detailed_report/detailed_report.py)

### LangChain/LangGraph Open Deep Research

The current graph is:

```text
clarify user
→ write research brief
→ supervisor loop
    → parallel ConductResearch workers
        → worker ReAct search/reflect loop
        → compress worker findings
    → supervisor reviews compressed findings
    → repeat or ResearchComplete
→ single final-report generation
```

The supervisor can issue several `ConductResearch` tool calls together; those worker graphs are executed concurrently. Workers independently call search, MCP, and reflection tools until they stop or hit their tool-call limit. (https://github.com/langchain-ai/open_deep_research/blob/main/src/open_deep_research/deep_researcher.py)

Defaults allow five concurrent research units, six supervisor iterations, and ten ReAct tool-call iterations per worker. Separate models and token caps can be configured for page summarization, research, worker compression, and final writing. (https://github.com/langchain-ai/open_deep_research/blob/main/src/open_deep_research/configuration.py)

The prompt requires workers to reflect after every search: identify what was found, what remains missing, whether the evidence is sufficient, and whether to continue. Prompted stop conditions include having a comprehensive answer, having three or more relevant sources, or seeing similar information in the last two searches. Hard limits cap simple work at 2–3 searches and complex work at five searches per worker. (https://github.com/langchain-ai/open_deep_research/blob/main/src/open_deep_research/prompts.py)

Tavily searches request raw page content, deduplicate by URL, truncate each page to a configurable default of 50,000 characters, and summarize pages concurrently into structured summaries plus key excerpts. The resulting evidence blocks preserve title and URL. (https://github.com/langchain-ai/open_deep_research/blob/main/src/open_deep_research/utils.py, https://github.com/langchain-ai/open_deep_research/blob/main/src/open_deep_research/configuration.py)

Worker compression is explicitly source-preserving, but citation correctness is prompt-enforced rather than verified by a graph node. The final report is generated in one call over all compressed notes. (https://github.com/langchain-ai/open_deep_research/blob/main/src/open_deep_research/prompts.py, https://github.com/langchain-ai/open_deep_research/blob/main/src/open_deep_research/deep_researcher.py)

On context overflow, worker compression removes older messages and retries; final writing progressively truncates findings. This provides mechanical completion, although simple prefix truncation may discard later branches disproportionately. (https://github.com/langchain-ai/open_deep_research/blob/main/src/open_deep_research/deep_researcher.py)

### Hugging Face Open Deep Research with smolagents

The Hugging Face example is closer to a general deep-search agent than a long-form report pipeline. A manager `CodeAgent` receives up to 12 steps and delegates browsing to a managed `ToolCallingAgent` with up to 20 steps; both create a new plan every four steps. (https://github.com/huggingface/smolagents/blob/main/examples/open_deep_research/run.py)

The web agent has search, visit, page-up/down, find, archive, and file-inspection tools. It performs sequential adaptive browsing rather than supervisor-controlled parallel worker fan-out. (https://github.com/huggingface/smolagents/blob/main/examples/open_deep_research/run.py)

Its text browser fetches pages, converts them to Markdown, maintains browser history, and exposes content through roughly 5 KiB viewports. The conversion layer removes scripts and styles, markdownifies HTML, and supports PDFs, Office documents, audio, and YouTube transcripts. (https://github.com/huggingface/smolagents/blob/main/examples/open_deep_research/scripts/text_web_browser.py, https://github.com/huggingface/smolagents/blob/main/examples/open_deep_research/scripts/mdconvert.py)

Stopping is controlled by the agent’s judgment and maximum-step limits. Citation auditing and long-form section writing are not first-class stages in this example. (https://github.com/huggingface/smolagents/blob/main/examples/open_deep_research/run.py)

### Firecrawl deep research service

Firecrawl’s production service runs a bounded iterative loop. Each depth level generates up to three search queries, runs them in parallel, uses `searchAndScrapeSearchResult` to obtain main-content Markdown, deduplicates URLs, adds the new pages as findings, and asks an LLM what was learned, which gaps remain, and whether to continue. (https://github.com/firecrawl/firecrawl/blob/main/apps/api/src/lib/deep-research/deep-research-service.ts)

It stops on any of: `maxDepth`, `maxUrls`, wall-clock deadline, no remaining gaps, or three failed analysis attempts. It then synthesizes whatever evidence was collected. (https://github.com/firecrawl/firecrawl/blob/main/apps/api/src/lib/deep-research/deep-research-service.ts)

The public controls are unusually operational: depth 1–12 with default 7, URLs 1–1,000 with default 20, and time 30–600 seconds with default 300. Runs are queued background jobs with persisted progress. (https://github.com/firecrawl/firecrawl/blob/main/apps/api/src/controllers/v1/deep-research.ts)

The reflection prompt receives time remaining and is told to stop with less than one minute left. The state retains only the most recent 50 findings, and the final prompt requests citations, but there is no claim-to-passage verifier. (https://github.com/firecrawl/firecrawl/blob/main/apps/api/src/lib/deep-research/research-manager.ts)

### Firesearch example

Firesearch decomposes a request into factual subquestions, fetches Markdown content through Firecrawl, checks which subquestions are answered, and retries unanswered ones using alternative searches. Default knobs include 12 maximum queries, four sources per search, three fallback scrapes, two search attempts, and a 0.7 answer-confidence threshold. (https://github.com/firecrawl/firesearch/blob/main/README.md)

Its graph performs source summarization in parallel, scrapes results missing sufficient content, and asks an evaluator to map each subquestion to an answer, confidence score, and source URLs. Research returns to the planning node while important subquestions remain unanswered and retry capacity remains. (https://github.com/firecrawl/firesearch/blob/main/lib/langgraph-search-engine.ts)

This is useful pre-synthesis verification: it tests coverage before writing. It does not subsequently test whether every sentence in the generated report is entailed by its displayed citation. (https://github.com/firecrawl/firesearch/blob/main/lib/langgraph-search-engine.ts)

### dzhng/deep-research

This is the clearest minimal reference implementation. It generates `breadth` search queries, runs them concurrently, asks Firecrawl for up to five Markdown pages per query, trims each page, extracts compact learnings and follow-up questions, and recursively continues with `depth - 1` and `ceil(breadth / 2)`. (https://github.com/dzhng/deep-research/blob/main/src/deep-research.ts)

The only successful-run stop condition is depth exhaustion; there is no adaptive sufficiency decision. The final writer receives the deduplicated learnings and appends all visited URLs under “Sources,” but claims are not mapped to particular URLs. (https://github.com/dzhng/deep-research/blob/main/src/deep-research.ts)

### Jina node-DeepResearch

Jina implements a dynamic `search | visit | reflect | answer | code` action loop. The loop continues until an answer passes evaluation or a shared token budget is exhausted; the default budget is one million tokens. It reserves the final 15% of the budget for forced-answer “beast mode” if no candidate has passed. (https://github.com/jina-ai/node-DeepResearch/blob/main/src/agent.ts)

Search results populate a ranked URL frontier, but the agent is prevented from immediately answering from snippets. A later `visit` action reads full pages and adds their content to the knowledge store. (https://github.com/jina-ai/node-DeepResearch/blob/main/src/agent.ts, https://github.com/jina-ai/node-DeepResearch/blob/main/src/tools/read.ts)

Reflection creates explicit gap questions. Candidate answers can be evaluated for properties such as freshness and completeness; failed answers produce an error analysis and improvement instructions, after which the agent continues researching. Optional `teamSize` decomposition runs subproblems concurrently and aggregates their answers. (https://github.com/jina-ai/node-DeepResearch/blob/main/src/agent.ts)

Citation generation is post-hoc. The system chunks both the final answer and retained web pages, embeds both sets, matches answer chunks to source chunks above a relevance threshold, limits one match per answer/source chunk, and falls back to Jaccard similarity if embeddings fail. This is stronger than allowing the writer to invent URLs, but similarity alone is not proof that a passage entails a claim. (https://github.com/jina-ai/node-DeepResearch/blob/main/src/tools/build-ref.ts)

---

## 3. Key design questions

### Iterative reflection versus one-shot fan-out

One-shot planning plus parallel fan-out is fast, easy to budget, and well suited to questions whose dimensions are known up front. Its weakness is path dependence: the initial planner cannot ask about entities, contradictions, or missing dimensions that only become visible after reading sources. Anthropic explicitly argues that open-ended research cannot be reliably hardcoded as a linear one-shot path. (https://www.anthropic.com/engineering/multi-agent-research-system)

Fully iterative agents adapt better but can repeat searches, chase weak leads, and exhaust budgets. LangChain therefore combines model reflection with hard search limits, while Firecrawl combines an LLM `shouldContinue` decision with depth, URL, failure, and time caps. (https://github.com/langchain-ai/open_deep_research/blob/main/src/open_deep_research/prompts.py, https://github.com/firecrawl/firecrawl/blob/main/apps/api/src/lib/deep-research/deep-research-service.ts)

The practical answer is a hybrid: begin with a broad parallel wave, merge its evidence, run one global gap analysis, then launch only the missing follow-ups. Additional waves should require a high-value unresolved gap and remaining budget. This preserves most of the latency benefit while allowing research to react to evidence. (https://www.anthropic.com/engineering/multi-agent-research-system, https://github.com/firecrawl/firesearch/blob/main/lib/langgraph-search-engine.ts)

### Full pages versus snippets

Every serious OSS implementation checked here eventually reads actual page content: LangChain requests raw content and summarizes it, Firecrawl returns or scrapes Markdown, GPT Researcher scrapes and chunks pages, Hugging Face exposes a text browser, dzhng feeds Firecrawl Markdown into its extractor, and Jina has an explicit read action. (https://github.com/langchain-ai/open_deep_research/blob/main/src/open_deep_research/utils.py, https://github.com/firecrawl/firecrawl/blob/main/apps/api/src/lib/deep-research/deep-research-service.ts, https://github.com/assafelovic/gpt-researcher/blob/main/gpt_researcher/context/compression.py, https://github.com/huggingface/smolagents/blob/main/examples/open_deep_research/scripts/text_web_browser.py, https://github.com/dzhng/deep-research/blob/main/src/deep-research.ts, https://github.com/jina-ai/node-DeepResearch/blob/main/src/tools/read.ts)

Snippets remain valuable for ranking and frontier discovery, but they are too short and decontextualized to support detailed claims, limitations, comparisons, or quotes safely. No clean public snippet-only versus full-page ablation was found in the checked sources, so this is an architectural convergence rather than a quantified causal result.

A robust extraction path is:

```text
HTML/PDF
→ main-content extraction
→ normalized Markdown
→ source-stable chunks
→ relevance filtering
→ structured summary + key excerpts
→ evidence records
```

LangChain’s structured summary plus key excerpts and GPT Researcher’s chunk-and-embedding compression are concrete implementations of this pattern. (https://github.com/langchain-ai/open_deep_research/blob/main/src/open_deep_research/utils.py, https://github.com/assafelovic/gpt-researcher/blob/main/gpt_researcher/context/compression.py)

Fetched pages also introduce prompt-injection risk. OpenAI explicitly trains and adds system safeguards for hostile web content, while Google warns that public pages and uploaded files may contain malicious instructions. Page content should therefore be treated as untrusted data, never as control text. (https://cdn.openai.com/deep-research-system-card.pdf, https://ai.google.dev/gemini-api/docs/deep-research)

### Citation grounding

Citation quality forms a useful ladder:

1. Append all visited URLs: easy, but no claim mapping. dzhng uses this approach. (https://github.com/dzhng/deep-research/blob/main/src/deep-research.ts)
2. Prompt the writer to preserve citations: common in GPT Researcher, LangChain, and Firecrawl, but still vulnerable to dropped or misplaced citations. (https://github.com/assafelovic/gpt-researcher/blob/main/gpt_researcher/skills/deep_research.py, https://github.com/langchain-ai/open_deep_research/blob/main/src/open_deep_research/prompts.py, https://github.com/firecrawl/firecrawl/blob/main/apps/api/src/lib/deep-research/research-manager.ts)
3. Post-hoc relevance alignment: Jina matches answer chunks to page chunks, preventing arbitrary URL invention but not proving entailment. (https://github.com/jina-ai/node-DeepResearch/blob/main/src/tools/build-ref.ts)
4. Claim-to-source verification: extract atomic claim–URL pairs, fetch the cited passage, and judge whether it supports the claim. DeepResearchBench’s FACT evaluator uses this structure. (https://github.com/Ayanami0730/deep_research_bench/blob/main/README.md)
5. Dedicated citation agent over retained documents: Anthropic uses this production architecture. (https://www.anthropic.com/engineering/multi-agent-research-system)

A production evidence record should contain at least:

```swift
struct Evidence {
    let sourceID: UUID
    let url: URL
    let title: String
    let retrievedAt: Date
    let queryID: UUID
    let chunkID: String
    let quote: String
    let normalizedText: String
    let contentDigest: String
}

struct Claim {
    let claimID: UUID
    var text: String
    var evidenceIDs: [UUID]
    var verification: VerificationStatus
}
```

The writer should cite `sourceID` or `evidenceID`, never emit raw URLs from memory. A resolver can then produce numbered citations deterministically.

### Verification and critique passes

Anthropic performs citation alignment after report generation. Firesearch verifies whether its evidence answers planned subquestions before report generation. Jina evaluates candidate answers, feeds failure reasons back into the research loop, and retries. (https://www.anthropic.com/engineering/multi-agent-research-system, https://github.com/firecrawl/firesearch/blob/main/lib/langgraph-search-engine.ts, https://github.com/jina-ai/node-DeepResearch/blob/main/src/agent.ts)

DeepResearchBench operationalizes citation verification by extracting claim–URL pairs, scraping the pages, and judging support. It measures citation accuracy and the number of verifiably supported citations. (https://github.com/Ayanami0730/deep_research_bench/blob/main/README.md)

The checked sources do not provide a clean ablation proving that a generic second-model prose review improves report quality. The strongest documented case is narrower: source-aware verification catches unsupported, stale, or incomplete answers before acceptance. Therefore, critique prompts should receive the claims and source passages, not merely the draft.

### Report generation

A single final synthesis is simplest and works when compressed evidence fits comfortably in context. Current LangChain Open Deep Research uses that design. (https://github.com/langchain-ai/open_deep_research/blob/main/src/open_deep_research/deep_researcher.py)

Outline-first, section-by-section writing provides better context isolation, lets each section see only its relevant evidence, and permits per-section verification. GPT Researcher’s detailed-report implementation generates subtopics and draft section titles, researches each subtopic, writes separate reports, and assembles them with an introduction and conclusion. (https://github.com/assafelovic/gpt-researcher/blob/main/backend/report_type/detailed_report/detailed_report.py)

For deep-tier reports, the preferred flow is:

```text
evidence ledger
→ outline with section evidence assignments
→ section drafts in parallel
→ local citation audit
→ cross-section deduplication and contradiction check
→ introduction and conclusion last
→ final global citation audit
```

Introduction and conclusion should be written last because they depend on the actual findings rather than the initial plan.

### Budget models and graceful degradation

Useful budgets are independent:

- Wall clock: stop starting new work before the deadline.
- Search calls: bounds provider cost and frontier explosion.
- Page fetches: bounds network and parsing work.
- Input/output tokens: bounds model cost and context growth.
- Iterations or waves: bounds control-loop depth.
- Concurrent workers: bounds rate pressure and memory.
- Sources per question: bounds evidence breadth.

Firecrawl enforces wall-clock, depth, and URL budgets; OpenAI exposes `max_tool_calls`; Jina uses a shared token budget; LangChain caps supervisor iterations, worker calls, and concurrency; Anthropic teaches the coordinator effort ranges. (https://github.com/firecrawl/firecrawl/blob/main/apps/api/src/controllers/v1/deep-research.ts, https://developers.openai.com/api/docs/guides/deep-research.md, https://github.com/jina-ai/node-DeepResearch/blob/main/src/agent.ts, https://github.com/langchain-ai/open_deep_research/blob/main/src/open_deep_research/configuration.py, https://www.anthropic.com/engineering/multi-agent-research-system)

Graceful degradation should reserve a finalization budget. Jina reserves 15% for a forced answer; Firecrawl stops research when time expires and synthesizes collected findings; LangChain truncates findings when the final model exceeds context. (https://github.com/jina-ai/node-DeepResearch/blob/main/src/agent.ts, https://github.com/firecrawl/firecrawl/blob/main/apps/api/src/lib/deep-research/deep-research-service.ts, https://github.com/langchain-ai/open_deep_research/blob/main/src/open_deep_research/deep_researcher.py)

A safer policy is to stop launching work with 15–25% of wall time remaining, cancel low-priority frontier tasks, finish in-flight fetches, mark unresolved sections explicitly, synthesize from verified evidence, and scale the citation audit to the remaining time.

### What “depth” means in practice

“Depth” is not standardized:

| Implementation | Meaning |
|---|---|
| GPT Researcher | Recursive levels; each level turns follow-up questions into new branches and reduces breadth. (https://github.com/assafelovic/gpt-researcher/blob/main/gpt_researcher/skills/deep_research.py) |
| dzhng | Recursive levels; each branch receives `depth - 1` and `ceil(breadth / 2)`. (https://github.com/dzhng/deep-research/blob/main/src/deep-research.ts) |
| Firecrawl | Sequential search–analyze iterations, each generating up to three parallel queries. (https://github.com/firecrawl/firecrawl/blob/main/apps/api/src/lib/deep-research/deep-research-service.ts) |
| LangChain | No single depth value; supervisor reflection iterations and per-worker ReAct calls are separate knobs. (https://github.com/langchain-ai/open_deep_research/blob/main/src/open_deep_research/configuration.py) |
| Hugging Face | Manager and browser maximum steps, with periodic replanning. (https://github.com/huggingface/smolagents/blob/main/examples/open_deep_research/run.py) |
| Jina | Dynamic steps until evaluation success or token exhaustion. (https://github.com/jina-ai/node-DeepResearch/blob/main/src/agent.ts) |
| Google | Effort is autonomously chosen; the API exposes ordinary and Max agents rather than numeric depth. (https://ai.google.dev/gemini-api/docs/deep-research) |
| OpenAI | Effort is agent-controlled, with `max_tool_calls` available as a hard ceiling. (https://developers.openai.com/api/docs/guides/deep-research.md) |

A product-facing `depth` setting should therefore expand into a complete budget profile rather than map only to recursion count.

---

## 4. Recommended shared engine

### Shared state machine

```text
Clarify / normalize request
        ↓
Create plan and initial frontier
        ↓
Search discovery ─────────────┐
        ↓                     │
Rank and fetch pages          │
        ↓                     │
Extract source-tagged evidence│
        ↓                     │
Coverage and gap reflection ──┘ if valuable gaps remain
        ↓
Outline and assign evidence
        ↓
Draft report
        ↓
Claim-to-source verification and repair
        ↓
Final report
```

A central `ResearchBudget` actor should lease search calls, fetches, tokens, worker slots, and time. Workers should not independently decide that budget remains; otherwise concurrent branches can all spend the same remaining allowance.

A durable `ResearchRun` should store the plan, frontier, visited URLs, evidence records, claims, budget counters, and stage. The casual tier can remain in-memory, while the deep tier should checkpoint between waves so it can survive app suspension, transient provider errors, or reconnects. This follows the background-job patterns exposed by Google and Firecrawl. (https://ai.google.dev/gemini-api/docs/deep-research, https://github.com/firecrawl/firecrawl/blob/main/apps/api/src/controllers/v1/deep-research.ts)

### Proposed tier profiles

These are starting values for evaluation, not published benchmark optima.

| Control | Investigation, ~2 minutes | Deep Research, ~10–20 minutes |
|---|---:|---:|
| Planning | Existing initial plan | Detailed plan, optionally user-reviewable |
| Worker slots | 3–5 | 4–8 |
| Reflection waves | 0–1 | 2–4 |
| Search calls | 6–12 | 40–100 |
| Page fetches | 4–10 | 30–80 |
| Pages per subquestion | 1–2 | 3–6 |
| Evidence excerpts per page | 2–5 | 5–15 |
| Report strategy | One synthesis over evidence packets | Outline, section drafts, merge |
| Verification | Check top claims and all displayed citations | Verify every substantive claim |
| Deadline reserve | 20–30 seconds | 2–3 minutes |
| Failure behavior | Answer with explicit gaps | Partial report with per-section coverage state |

The deep-tier magnitudes are intentionally below Google’s preview estimates and Anthropic’s largest complex-query guidance until cost and quality measurements justify expansion. (https://ai.google.dev/gemini-api/docs/deep-research, https://www.anthropic.com/engineering/multi-agent-research-system)

### Ranked upgrades by quality per complexity

1. **Fetch and normalize real pages.** Keep Brave snippets for discovery, but fetch the best one or two pages per investigation thread and extract main-content Markdown. This gives the existing pipeline actual evidence without changing its high-level shape. (https://github.com/langchain-ai/open_deep_research/blob/main/src/open_deep_research/utils.py, https://github.com/firecrawl/firesearch/blob/main/README.md)

2. **Introduce an evidence ledger and citation verifier.** Preserve URL, title, passage, digest, and retrieval time at extraction. After drafting, split the report into claims and verify each citation against its retained passages; unsupported claims should be repaired, qualified, or removed. (https://www.anthropic.com/engineering/multi-agent-research-system, https://github.com/Ayanami0730/deep_research_bench/blob/main/README.md)

3. **Add one bounded reflection wave.** After initial threads finish, ask one model to list only material unanswered questions or contradictions. Launch follow-ups only when they fit the remaining budget. (https://github.com/firecrawl/firesearch/blob/main/lib/langgraph-search-engine.ts, https://github.com/langchain-ai/open_deep_research/blob/main/src/open_deep_research/prompts.py)

4. **Use outline-first, section-scoped writing for the deep tier.** Assign evidence to sections before drafting, write sections concurrently, then merge and audit. Keep the casual tier’s single synthesis. (https://github.com/assafelovic/gpt-researcher/blob/main/backend/report_type/detailed_report/detailed_report.py)

5. **Add a source-aware critique pass.** Review completeness, contradictions, stale evidence, and unsupported claims using the draft plus evidence excerpts. A generic model reviewing prose without sources is much less useful. (https://github.com/jina-ai/node-DeepResearch/blob/main/src/agent.ts, https://github.com/Ayanami0730/deep_research_bench/blob/main/README.md)

6. **Only then add recursive multi-agent orchestration.** It is valuable for broad questions and contexts larger than one model can manage, but Anthropic’s reported token multiplier and coordination problems make it the highest-complexity upgrade. (https://www.anthropic.com/engineering/multi-agent-research-system)

The best near-term design is therefore not a separate Deep Research codebase. It is one parameterized engine whose policies control page fetching, worker width, reflection waves, source count, report strategy, verification coverage, and budget ceilings.

---

## All URLs

- https://www.anthropic.com/engineering/multi-agent-research-system
- https://cdn.openai.com/deep-research-system-card.pdf
- https://developers.openai.com/api/docs/guides/deep-research.md
- https://blog.google/products-and-platforms/products/gemini/google-gemini-deep-research/
- https://ai.google.dev/gemini-api/docs/deep-research
- https://github.com/assafelovic/gpt-researcher/blob/main/README.md
- https://github.com/assafelovic/gpt-researcher/blob/main/gpt_researcher/skills/deep_research.py
- https://github.com/assafelovic/gpt-researcher/blob/main/gpt_researcher/config/variables/default.py
- https://github.com/assafelovic/gpt-researcher/blob/main/gpt_researcher/context/compression.py
- https://github.com/assafelovic/gpt-researcher/blob/main/backend/report_type/detailed_report/detailed_report.py
- https://github.com/langchain-ai/open_deep_research/blob/main/README.md
- https://github.com/langchain-ai/open_deep_research/blob/main/src/open_deep_research/configuration.py
- https://github.com/langchain-ai/open_deep_research/blob/main/src/open_deep_research/deep_researcher.py
- https://github.com/langchain-ai/open_deep_research/blob/main/src/open_deep_research/prompts.py
- https://github.com/langchain-ai/open_deep_research/blob/main/src/open_deep_research/utils.py
- https://github.com/huggingface/smolagents/blob/main/examples/open_deep_research/run.py
- https://github.com/huggingface/smolagents/blob/main/examples/open_deep_research/scripts/text_web_browser.py
- https://github.com/huggingface/smolagents/blob/main/examples/open_deep_research/scripts/mdconvert.py
- https://github.com/firecrawl/firecrawl/blob/main/apps/api/src/lib/deep-research/deep-research-service.ts
- https://github.com/firecrawl/firecrawl/blob/main/apps/api/src/lib/deep-research/research-manager.ts
- https://github.com/firecrawl/firecrawl/blob/main/apps/api/src/controllers/v1/deep-research.ts
- https://github.com/firecrawl/firesearch/blob/main/README.md
- https://github.com/firecrawl/firesearch/blob/main/lib/langgraph-search-engine.ts
- https://github.com/dzhng/deep-research/blob/main/src/deep-research.ts
- https://github.com/jina-ai/node-DeepResearch/blob/main/README.md
- https://github.com/jina-ai/node-DeepResearch/blob/main/src/agent.ts
- https://github.com/jina-ai/node-DeepResearch/blob/main/src/tools/read.ts
- https://github.com/jina-ai/node-DeepResearch/blob/main/src/tools/build-ref.ts
- https://github.com/Ayanami0730/deep_research_bench/blob/main/README.md