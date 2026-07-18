# Competitive teardown: “Deep Research” features

**Research date:** 2026-07-18  
**Scope:** Shipping end-user products, with primary sources preferred. Product behavior and quotas change quickly; dated launch figures are labeled as such. Anything I could not verify from a loaded page is marked **unverified**.

**Fetch note:** OpenAI, Perplexity, and xAI returned Cloudflare 403 pages to direct headless `curl`; I loaded readable snapshots of those canonical pages through `r.jina.ai` and cite the original canonical URLs. All other cited pages returned HTTP 200 directly.

## Executive summary

The category has converged on a deliberate mode switch, an autonomous multi-search run, visible source grounding, and a longer structured answer that remains in chat. The major split is whether the product treats research as a **report workflow** (ChatGPT, Gemini, Claude, Microsoft), a **fast answer workflow** (Perplexity Research, Kagi Research), or a **deliverable-building workflow** (Perplexity Labs, Gemini Canvas, You.com ARI). (https://help.openai.com/en/articles/10500283-deep-research-faq) (https://gemini.google/overview/deep-research/) (https://www.anthropic.com/news/integrations) (https://www.perplexity.ai/hub/blog/introducing-perplexity-labs) (https://blog.kagi.com/kagi-assistants) (https://you.com/resources/introducing-ari-the-first-professional-grade-research-agent-for-business)

Editable preflight plans are not universal: ChatGPT and Gemini expose them, while Claude plans internally and the loaded Perplexity, Grok, Microsoft, Kagi, and ARI product pages do not document a user-editable approval step. (https://help.openai.com/en/articles/10500283-deep-research-faq) (https://gemini.google/overview/deep-research/) (https://www.anthropic.com/engineering/multi-agent-research-system)

The strongest long-run UX combines an editable plan, a live activity/source trace, background continuation, a completion notification, and a durable report view; Gemini documents all but mid-run interruption, while ChatGPT documents all of them including interruption and source changes during the run. (https://support.google.com/gemini/answer/15719111?hl=en) (https://gemini.google/overview/deep-research/) (https://help.openai.com/en/articles/10500283-deep-research-faq)

## 1. OpenAI ChatGPT Deep Research

### Positioning and entry point

OpenAI distinguishes Search as a quick recent-information lookup that returns a short linked summary, while Deep Research spends longer reading and analyzing many sources and returns a detailed documented report. (https://help.openai.com/en/articles/10500283-deep-research-faq)

The current product can be invoked with `/Deepresearch`, from **Deep research** in the composer’s `+` tools menu, or from the sidebar. (https://help.openai.com/en/articles/10500283-deep-research-faq)

Before submission, the user can choose the public web, uploaded files, connected apps, and specific sites; site controls support either strict domain restriction or “prioritize these sites, but allow full-web search.” (https://help.openai.com/en/articles/10500283-deep-research-faq)

### Clarification and plan

ChatGPT creates a proposed research plan that the user can review and modify before research begins, and it may ask clarifying questions alongside that plan. (https://help.openai.com/en/articles/10500283-deep-research-faq)

This is a true preflight checkpoint rather than a hidden model plan: the help page explicitly says the user can edit the plan before kickoff. (https://help.openai.com/en/articles/10500283-deep-research-faq)

### Progress during the run

The original product flow opened a sidebar summarizing steps taken and sources used, and let the user step away while the task ran. (https://openai.com/index/introducing-deep-research/)

The current flow adds real-time progress plus mid-run interruption: the user can refine the focus and change which sources the task may access without starting over. (https://help.openai.com/en/articles/10500283-deep-research-faq)

OpenAI says the user receives a completion notification, although its loaded pages do not spell out the current per-platform notification presentation. (https://openai.com/index/introducing-deep-research/)

### Duration and depth

OpenAI’s launch guidance says a run may take 5–30 minutes and may find, analyze, and synthesize hundreds of online sources. (https://openai.com/index/introducing-deep-research/)

The system can work across text, images, PDFs, uploaded files, and connected sources, and it can react to what it finds by changing direction. (https://openai.com/index/introducing-deep-research/) (https://help.openai.com/en/articles/10500283-deep-research-faq)

### Report and citations

Completed work opens in a full-screen report view with a table of contents, a “sources used” section, and an activity history. (https://help.openai.com/en/articles/10500283-deep-research-faq)

Reports contain citations or source links for verification and can be downloaded as Markdown, Word, or PDF. (https://help.openai.com/en/articles/10500283-deep-research-faq)

Reports remain attached to conversation history unless the chat is deleted; research-specific follow-up Q&A behavior and the exact numbered/hover citation treatment are not separately documented in the loaded help page, so those details are **unverified**. (https://help.openai.com/en/articles/10500283-deep-research-faq)

### Limits and gating

Current exact allowances vary by plan; ChatGPT shows a remaining-task counter, and fixed monthly allowances reset 30 days after first use. (https://help.openai.com/en/articles/10500283-deep-research-faq)

The last exact public quota snapshot on the launch page, dated April 24, 2025, was 5 monthly queries for Free, 25 for Plus/Team/Enterprise/Edu, and 250 for Pro, with automatic fallback to a lightweight model after the full-version limit; this may be stale relative to the current in-product counter. (https://openai.com/index/introducing-deep-research/)

### Distinctive bets

ChatGPT has the broadest explicit control loop in the loaded documentation: source scoping before the run, editable plan approval, live progress, interruption, focus changes, and source changes during execution. (https://help.openai.com/en/articles/10500283-deep-research-faq)

It also treats research output as a reusable document rather than only a chat response, with full-screen navigation and three download formats. (https://help.openai.com/en/articles/10500283-deep-research-faq)

## 2. Google Gemini Deep Research

### Positioning and entry point

On the web, the user opens **Add Files → Deep Research** in the prompt box; Google’s product page also describes this as selecting Deep Research in the prompt bar. (https://support.google.com/gemini/answer/15719111?hl=en) (https://gemini.google/overview/deep-research/)

Google Search is selected by default, while the user can add or substitute Gmail, Drive, uploaded files, and NotebookLM notebooks as sources. (https://support.google.com/gemini/answer/15719111?hl=en)

### Clarification and plan

After prompt submission, Gemini generates a multi-point research plan; the user can select **Edit plan** and must then press **Start research**, making approval explicit. (https://support.google.com/gemini/answer/15719111?hl=en)

The product page says the plan is personalized and user-refinable, but the loaded official pages do not document an automatic clarifying-question step before the plan, so that behavior is **unverified**. (https://gemini.google/overview/deep-research/)

### Progress during the run

Gemini has a thinking panel that shows what the system has learned and what it intends to do next while it iteratively gathers information. (https://gemini.google/overview/deep-research/)

The job runs asynchronously: the user can leave the chat, switch apps, or turn off the computer, and Gemini will continue from shared task state rather than requiring the foreground session to remain open. (https://support.google.com/gemini/answer/15719111?hl=en) (https://gemini.google/overview/deep-research/)

Completion appears next to the web chat thread and as a device notification in the mobile app, subject to device notification settings. (https://support.google.com/gemini/answer/15719111?hl=en)

Google does not document mid-run user interruption or steering in the loaded pages, so that capability is **unverified**. (https://support.google.com/gemini/answer/15719111?hl=en)

### Duration and depth

Google says a report usually takes 5–10 minutes, with complex reports taking longer. (https://support.google.com/gemini/answer/15719111?hl=en)

Gemini can browse up to hundreds of websites and process hundreds of pages during a session. (https://gemini.google/overview/deep-research/)

### Report and citations

The output is a comprehensive multi-page report with links to original sources, and the same chat retains enough gathered context for follow-up questions. (https://blog.google/products/gemini/google-gemini-deep-research/) (https://gemini.google/overview/deep-research/)

Google does not define the exact numbered/hover citation-card treatment in the loaded text, so that visual detail is **unverified**. (https://support.google.com/gemini/answer/15719111?hl=en)

In Canvas, the report can be shared, exported to Google Docs, or copied as text. (https://support.google.com/gemini/answer/15719111?hl=en)

Gemini can turn a report into an Audio Overview, quiz, or interactive Canvas content; Google AI Ultra reports may directly include charts, diagrams, schematics, animations, and interactive simulators, although those Ultra visuals are currently unavailable when Workspace services such as Gmail or Drive are included as sources. (https://gemini.google/overview/deep-research/) (https://support.google.com/gemini/answer/15719111?hl=en)

### Limits and gating

Deep Research is available without a Google AI plan and on AI Plus, Pro, and Ultra, but request limits are compute-based and dynamic rather than published as stable exact counts. (https://support.google.com/gemini/answer/16275805?hl=en)

There are daily-request and concurrent-run limits; Gemini warns when the daily limit is close, and Pro/Ultra users receive higher limits. (https://support.google.com/gemini/answer/15719111?hl=en)

The current general limit page describes AI Plus as 2× standard limits, AI Pro as 4× standard, and AI Ultra as either 5× or 20× AI Pro depending on subscription, while warning that compute-heavy features such as Deep Research consume more usage and limits may change without notice. (https://support.google.com/gemini/answer/16275805?hl=en)

### Distinctive bets

Gemini’s strongest product bet is “research as transformable media”: one research corpus can become a report, audio, quiz, visualization, interactive simulator, or other Canvas object. (https://gemini.google/overview/deep-research/) (https://support.google.com/gemini/answer/15719111?hl=en)

Its asynchronous task manager and explicit desktop/mobile completion notifications are unusually well documented. (https://gemini.google/overview/deep-research/) (https://support.google.com/gemini/answer/15719111?hl=en)

## 3. Perplexity Research / Deep Research and Labs

### Three product levels

Perplexity described its base Search product as the mode for answers, Deep Research as the mode for deeper and richer analysis, and Labs as the mode for producing broader project deliverables. (https://www.perplexity.ai/hub/blog/introducing-perplexity-labs)

At the Labs launch, Perplexity said it was shortening the name “Deep Research” to “Research,” positioning it between Search and Labs; the current naming and continued availability of the Labs label in July 2026 are **unverified** from the loaded official pages. (https://www.perplexity.ai/hub/blog/introducing-perplexity-labs)

### Research: entry, plan, and progress

The launch flow used **Deep Research** in the search-box mode selector before query submission. (https://www.perplexity.ai/hub/blog/introducing-perplexity-deep-research)

Perplexity says the agent iteratively searches, reads, reasons, and refines its own research plan as it learns, but the loaded page does not document user-visible clarification questions or an editable/approvable preflight plan. (https://www.perplexity.ai/hub/blog/introducing-perplexity-deep-research)

The loaded official page does not specify a live activity feed, progress bar, background notification, or leave-and-return behavior for Research, so those details are **unverified**. (https://www.perplexity.ai/hub/blog/introducing-perplexity-deep-research)

### Research: duration, depth, report, and limits

Perplexity says Research performs dozens of searches, reads hundreds of sources, and generally spends 2–4 minutes; its launch tests completed most tasks in under three minutes. (https://www.perplexity.ai/hub/blog/introducing-perplexity-deep-research)

After evaluating sources, it writes a clear comprehensive report that can be exported as PDF or a document, or converted into a shareable Perplexity Page. (https://www.perplexity.ai/hub/blog/introducing-perplexity-deep-research)

The loaded launch page does not document the exact inline citation UI, a consolidated source-list view, or research-report follow-up Q&A, so those details are **unverified**. (https://www.perplexity.ai/hub/blog/introducing-perplexity-deep-research)

The launch policy made Research free for everyone, with a limited number of daily answers for non-subscribers and high-volume access for Pro; the loaded page gives no stable numeric cap, so current exact quotas are **unverified**. (https://www.perplexity.ai/hub/blog/introducing-perplexity-deep-research)

### Labs: invocation and output model

Labs launched from the input-bar mode selector on web, iOS, and Android, with Mac and Windows announced as later targets. (https://www.perplexity.ai/hub/blog/introducing-perplexity-labs)

Labs typically performs ten minutes or more of self-supervised work and combines deep web browsing with code execution, chart creation, and image creation. (https://www.perplexity.ai/hub/blog/introducing-perplexity-labs)

Its outputs can include reports, spreadsheets, dashboards, and simple deployed web apps rather than only prose answers. (https://www.perplexity.ai/hub/blog/introducing-perplexity-labs)

Generated charts, images, CSVs, and code files appear in an **Assets** area below the query for viewing and download, while mini apps render directly below the query. (https://www.perplexity.ai/hub/blog/introducing-perplexity-labs)

Labs was Pro-only at launch, while Research was the faster broadly accessible mode; current Labs gating is **unverified**. (https://www.perplexity.ai/hub/blog/introducing-perplexity-labs)

### Distinctive bets

Perplexity optimizes Research for speed—hundreds of sources in roughly 2–4 minutes—rather than the 5–45 minute envelope documented by several rivals. (https://www.perplexity.ai/hub/blog/introducing-perplexity-deep-research) (https://www.anthropic.com/news/integrations) (https://openai.com/index/introducing-deep-research/)

Labs makes a clean conceptual jump from “answer my question” to “produce the working files and interactive tool,” which is closer to a project agent than a report generator. (https://www.perplexity.ai/hub/blog/introducing-perplexity-labs)

## 4. Anthropic Claude Research

### Positioning and entry point

Claude separates web search for straightforward questions needing one or two tool calls from Research for comprehensive information gathering that typically needs five or more tool calls and synthesis across the web and integrations. (https://support.claude.com/en/articles/11095361-when-should-i-use-web-search-extended-thinking-and-research)

The user enables Research from the `+` button at the lower-left of chat; a blue indicator appears at the bottom of the chat window and can be clicked again to disable it. (https://support.claude.com/en/articles/11088861-use-research-on-claude)

### Clarification and plan

Anthropic’s architecture uses a lead agent that analyzes the request, develops a strategy, and delegates parallel subtasks to research subagents. (https://www.anthropic.com/engineering/multi-agent-research-system)

That plan is internal and dynamic; the loaded end-user docs do not describe a user-visible clarification step or editable plan approval, so both are **unverified**. (https://support.claude.com/en/articles/11088861-use-research-on-claude) (https://www.anthropic.com/engineering/multi-agent-research-system)

### Progress during the run

Anthropic documents that extended thinking can be combined with Research and that the lead agent uses thinking to plan, but the loaded end-user pages do not document a dedicated Research progress feed, source counter, progress bar, completion notification, background continuation, or mid-run steering. (https://support.claude.com/en/articles/11095361-when-should-i-use-web-search-extended-thinking-and-research) (https://www.anthropic.com/engineering/multi-agent-research-system)

### Duration and depth

Anthropic’s general mode guide describes ordinary Research tasks as five or more tool calls over roughly 1–3 minutes. (https://support.claude.com/en/articles/11095361-when-should-i-use-web-search-extended-thinking-and-research)

Advanced Research can investigate hundreds of internal and external sources in 5–45 minutes, with most reports finishing in 5–15 minutes. (https://www.anthropic.com/news/integrations)

The production system uses a lead agent with parallel subagents and a final citation agent; Anthropic says parallelization cut complex-task research time by as much as 90%. (https://www.anthropic.com/engineering/multi-agent-research-system)

### Report and citations

Claude returns a comprehensive report with clear citations that link directly to the original material, including information drawn from the web, Google Workspace, or connected integrations. (https://www.anthropic.com/news/integrations)

The loaded official pages do not document a research-specific table of contents, source-list view, exact inline citation-card treatment, follow-up Q&A, or PDF/Word/Docs export, so those presentation details are **unverified**. (https://support.claude.com/en/articles/11088861-use-research-on-claude) (https://www.anthropic.com/news/integrations)

### Limits and gating

Research is available on Pro, Max, Team, and Enterprise plans. (https://www.anthropic.com/news/integrations)

Research counts against the same usage limits as normal Claude conversations but can consume those limits faster because it retrieves multiple sources and generates a comprehensive response. (https://support.claude.com/en/articles/11088861-use-research-on-claude)

Anthropic does not publish a separate stable per-month Research task count on the loaded pages. (https://support.claude.com/en/articles/11088861-use-research-on-claude)

### Distinctive bets

Claude’s differentiator is its explicitly documented multi-agent implementation: parallel research workers compress different parts of the source space, a lead agent decides whether more work is needed, and a separate citation agent maps claims back to exact source locations. (https://www.anthropic.com/engineering/multi-agent-research-system)

It also treats connected work systems as first-class research territory through Google Workspace and remote MCP integrations, rather than treating the public web as the only corpus. (https://www.anthropic.com/news/integrations)

## 5. xAI Grok DeepSearch / DeeperSearch

### Positioning and entry point

xAI introduced DeepSearch with Grok 3 as an agent for synthesizing information, reasoning across conflicting facts and opinions, and returning a concise comprehensive report that goes beyond a browser search. (https://x.ai/news/grok-3)

The loaded xAI announcement explicitly documents a **Think** button but does not describe the exact current DeepSearch composer control, so the current invocation UX is **unverified**. (https://x.ai/news/grok-3)

An independent March 2025 report observed a **DeeperSearch** option beside **DeepSearch**, rolled out without an xAI explanation of its intended use. (https://the-decoder.com/grok-3-adds-deeper-search-and-ai-image-editing-capabilities/)

### Clarification, plan, and progress

The loaded xAI pages do not document clarifying questions, a user-visible or editable plan, a progress bar, a background completion notification, or mid-run steering, so those behaviors are **unverified**. (https://x.ai/news/grok-3)

xAI calls the output a “final summary trace,” but does not state on the loaded page whether intermediate searches are exposed live during execution. (https://x.ai/news/grok-3)

### Duration and depth

xAI does not publish a typical DeepSearch duration or source count on the loaded official pages. (https://x.ai/news/grok-3)

In one non-representative independent test, DeepSearch took about one minute and consulted 40 sources, while DeeperSearch took about 6.5 minutes and consulted 19 sources; that test also found the slower result more detailed but less comprehensive for that particular news query. (https://the-decoder.com/grok-3-adds-deeper-search-and-ai-image-editing-capabilities/)

### Report, citations, and limits

DeepSearch’s official output description is a concise comprehensive report, while exact citation-card behavior, source-list presentation, follow-up affordances, and export formats are **unverified** from the loaded xAI pages. (https://x.ai/news/grok-3)

At Grok 3 launch, DeepSearch and Think were immediately available to X Premium+ users; Grok 3 capabilities were also rolling out to all Grok users with usage limits, with higher limits and advanced capabilities for Premium+. (https://x.ai/news/grok-3)

Current numeric DeepSearch and DeeperSearch quotas are **unverified**. (https://x.ai/news/grok-3)

### Distinctive bets

Grok’s clearest unique asset is native access to X: Grok 4 can use advanced keyword search, semantic search, and media viewing on X in addition to web browsing. (https://x.ai/news/grok-4)

DeeperSearch is also an unusual “more effort” tier nested inside the research feature, although xAI had not publicly defined its target use in the loaded sources. (https://the-decoder.com/grok-3-adds-deeper-search-and-ai-image-editing-capabilities/)

## 6. Other notable products

### Microsoft 365 Copilot Researcher

Researcher appears under **Agents** in Microsoft 365 Copilot Chat and is deliberately positioned against standard Copilot: standard chat is for fast summaries and replies, while Researcher takes longer to reason across work and web sources and returns a shareable report. (https://learn.microsoft.com/en-us/copilot/microsoft-365/researcher-agent)

It may ask clarifying questions and lets the user define whether the scope is work content, the web, or both, but Microsoft’s loaded page does not document an editable preflight plan. (https://learn.microsoft.com/en-us/copilot/microsoft-365/researcher-agent)

The final response includes organized sections, cited sources, visuals, charts, and graphs. (https://learn.microsoft.com/en-us/copilot/microsoft-365/researcher-agent)

Simple responses are typically under five minutes and highly complex ones take 10–45 minutes; the FAQ states a maximum of 25 queries per user per month. (https://learn.microsoft.com/en-us/microsoft-365/copilot/faq-researcher)

Researcher is part of the default experience for licensed Microsoft 365 Copilot users and can ground on Microsoft Graph, emails, meetings, files, chats, the Bing index, and configured third-party connectors. (https://learn.microsoft.com/en-us/microsoft-365/copilot/faq-researcher) (https://www.microsoft.com/en-us/microsoft-365/blog/2025/03/25/introducing-researcher-and-analyst-in-microsoft-365-copilot/)

Its distinctive bet is enterprise context and governance: it combines OpenAI’s deep research model with Microsoft 365 orchestration and the permissions/compliance boundary already attached to work data. (https://www.microsoft.com/en-us/microsoft-365/blog/2025/03/25/introducing-researcher-and-analyst-in-microsoft-365-copilot/) (https://learn.microsoft.com/en-us/copilot/microsoft-365/researcher-agent)

### Kagi Research, formerly Ki

Kagi renamed the beta **Ki** into two assistants: **Quick** for speed and **Research** for depth and diversity. (https://blog.kagi.com/kagi-assistants)

Users choose Kagi Research in Assistant’s model-selector **Assistants** tab or invoke it from Kagi Search with the `!research` bang. (https://help.kagi.com/kagi/ai/kagi-research.html)

Research performs response planning and research planning, averages 30 seconds or more, and can execute up to five steps with roughly 15 tool calls; the loaded docs do not describe a user-editable plan. (https://help.kagi.com/kagi/ai/kagi-research.html)

Kagi Research is Ultimate-only, while Quick is on all plans; Assistant fair use is tied to the plan’s dollar-value token allowance and warns in-app near the limit. (https://help.kagi.com/kagi/ai/kagi-research.html) (https://help.kagi.com/kagi/ai/assistant.html)

Kagi deliberately calls its product “Deep Search,” not “Deep Research,” because it prefers concise answers over long report-shaped output; visible purple tool dropdowns let users inspect searches, and Kagi adds a citation-relevance attribution to the final answer. (https://blog.kagi.com/kagi-assistants)

### You.com ARI

ARI is an enterprise-oriented research agent that analyzes up to 400 public and private sources and produces a professional report in under five minutes. (https://you.com/resources/introducing-ari-the-first-professional-grade-research-agent-for-business)

You.com reports an average response time of about three minutes, live progress tracking, and direct citation links for claims, charts, and numbers. (https://you.com/resources/ari-vs--chatgpt-deep-research-vs--google-deep-research-why-businesses-are-choosing-ari) (https://you.com/resources/introducing-ari-the-first-professional-grade-research-agent-for-business)

The output is a polished PDF with visual tables, annotated comparisons, and interactive data visualizations; slide-deck output was announced as forthcoming. (https://you.com/resources/ari-vs--chatgpt-deep-research-vs--google-deep-research-why-businesses-are-choosing-ari) (https://you.com/resources/introducing-ari-the-first-professional-grade-research-agent-for-business)

The loaded pages do not provide consumer-style composer UX, clarification/plan behavior, or stable public quotas, so those details are **unverified**. (https://you.com/resources/introducing-ari-the-first-professional-grade-research-agent-for-business)

ARI’s unique bet is “client-ready consulting artifact”: source scale, branded PDF presentation, business visuals, and mixed private/public data are the product rather than optional export polish. (https://you.com/resources/introducing-ari-the-first-professional-grade-research-agent-for-business)

## Comparison table

| Product | Entry point | Clarification / plan | Run UX | Typical duration / depth | Final output | Access / limits |
|---|---|---|---|---|---|---|
| ChatGPT Deep Research | Composer `+`, `/Deepresearch`, or sidebar; source/site scoping (https://help.openai.com/en/articles/10500283-deep-research-faq) | May clarify; editable plan before start (https://help.openai.com/en/articles/10500283-deep-research-faq) | Live progress, step/source history, interrupt and steer; completion notice (https://help.openai.com/en/articles/10500283-deep-research-faq) (https://openai.com/index/introducing-deep-research/) | 5–30 min; hundreds of sources (https://openai.com/index/introducing-deep-research/) | Full-screen cited report, TOC, sources, activity; Markdown/Word/PDF (https://help.openai.com/en/articles/10500283-deep-research-faq) | Plan-dependent counter; dated 2025 snapshot 5/25/250 monthly by tier (https://help.openai.com/en/articles/10500283-deep-research-faq) (https://openai.com/index/introducing-deep-research/) |
| Gemini Deep Research | Add Files / prompt-bar mode; selectable Search, Workspace, uploads, NotebookLM (https://support.google.com/gemini/answer/15719111?hl=en) | Editable multi-point plan plus explicit Start research (https://support.google.com/gemini/answer/15719111?hl=en) | Thinking panel; background continuation; web/mobile completion notification (https://gemini.google/overview/deep-research/) (https://support.google.com/gemini/answer/15719111?hl=en) | Usually 5–10 min; hundreds of sites/pages (https://support.google.com/gemini/answer/15719111?hl=en) (https://gemini.google/overview/deep-research/) | Linked multi-page report; Docs export, copy/share, Canvas, Audio Overview; Ultra visuals (https://support.google.com/gemini/answer/15719111?hl=en) (https://gemini.google/overview/deep-research/) | Free through Ultra; dynamic daily/concurrent compute limits, higher paid limits (https://support.google.com/gemini/answer/16275805?hl=en) (https://support.google.com/gemini/answer/15719111?hl=en) |
| Perplexity Research | Search-box mode selector (https://www.perplexity.ai/hub/blog/introducing-perplexity-deep-research) | Agent refines an internal plan; user-editable plan unverified (https://www.perplexity.ai/hub/blog/introducing-perplexity-deep-research) | Detailed current progress/notification UX unverified (https://www.perplexity.ai/hub/blog/introducing-perplexity-deep-research) | 2–4 min; dozens of searches and hundreds of sources (https://www.perplexity.ai/hub/blog/introducing-perplexity-deep-research) | Comprehensive report; PDF/document export or Perplexity Page (https://www.perplexity.ai/hub/blog/introducing-perplexity-deep-research) | Free limited daily use and higher-volume Pro at launch; exact current cap unverified (https://www.perplexity.ai/hub/blog/introducing-perplexity-deep-research) |
| Perplexity Labs | Input-bar mode selector (https://www.perplexity.ai/hub/blog/introducing-perplexity-labs) | User-editable plan unverified (https://www.perplexity.ai/hub/blog/introducing-perplexity-labs) | Self-supervised project run; downloadable Assets and inline mini apps (https://www.perplexity.ai/hub/blog/introducing-perplexity-labs) | 10+ min (https://www.perplexity.ai/hub/blog/introducing-perplexity-labs) | Reports, spreadsheets, dashboards, charts/images, code, deployed mini apps (https://www.perplexity.ai/hub/blog/introducing-perplexity-labs) | Pro-only at launch; current label/gating unverified (https://www.perplexity.ai/hub/blog/introducing-perplexity-labs) |
| Claude Research | Chat `+` → Research; blue active indicator (https://support.claude.com/en/articles/11088861-use-research-on-claude) | Internal lead-agent plan; user clarification/approval unverified (https://www.anthropic.com/engineering/multi-agent-research-system) | Research-specific progress/notification controls unverified (https://support.claude.com/en/articles/11088861-use-research-on-claude) | Ordinary 1–3 min; Advanced 5–45 min, most 5–15, hundreds of sources (https://support.claude.com/en/articles/11095361-when-should-i-use-web-search-extended-thinking-and-research) (https://www.anthropic.com/news/integrations) | Comprehensive report with direct original-source citations (https://www.anthropic.com/news/integrations) | Pro/Max/Team/Enterprise; normal conversation limit, consumed faster (https://www.anthropic.com/news/integrations) (https://support.claude.com/en/articles/11088861-use-research-on-claude) |
| Grok DeepSearch / DeeperSearch | Current control unverified; DeeperSearch observed beside DeepSearch (https://the-decoder.com/grok-3-adds-deeper-search-and-ai-image-editing-capabilities/) | Clarification/editable plan unverified (https://x.ai/news/grok-3) | “Final summary trace”; live run UX unverified (https://x.ai/news/grok-3) | No official typical figure; one test ~1 min/40 sources vs ~6.5 min/19 (https://the-decoder.com/grok-3-adds-deeper-search-and-ai-image-editing-capabilities/) | Concise comprehensive report; citation/export details unverified (https://x.ai/news/grok-3) | Premium+ advanced launch access, limited wider rollout; current exact quotas unverified (https://x.ai/news/grok-3) |
| Microsoft Researcher | Agent under M365 Copilot Chat (https://learn.microsoft.com/en-us/copilot/microsoft-365/researcher-agent) | May clarify; editable plan unverified (https://learn.microsoft.com/en-us/copilot/microsoft-365/researcher-agent) | Detailed current progress UX unverified (https://learn.microsoft.com/en-us/copilot/microsoft-365/researcher-agent) | Under 5 min simple; 10–45 min complex (https://learn.microsoft.com/en-us/microsoft-365/copilot/faq-researcher) | Cited, structured, shareable report with charts/visuals (https://learn.microsoft.com/en-us/copilot/microsoft-365/researcher-agent) | M365 Copilot license; 25 queries/user/month (https://learn.microsoft.com/en-us/microsoft-365/copilot/faq-researcher) |
| Kagi Research | Assistant model selector or `!research` bang (https://help.kagi.com/kagi/ai/kagi-research.html) | Internal response/research planning; editable plan unverified (https://help.kagi.com/kagi/ai/kagi-research.html) | Inspectable tool-call dropdowns (https://blog.kagi.com/kagi-assistants) | 30 sec+; up to 5 steps/~15 calls (https://help.kagi.com/kagi/ai/kagi-research.html) | Concise sourced answer with citation-relevance attribution, intentionally not a long report (https://blog.kagi.com/kagi-assistants) | Ultimate only; plan-value fair use (https://help.kagi.com/kagi/ai/kagi-research.html) (https://help.kagi.com/kagi/ai/assistant.html) |
| You.com ARI | Enterprise research product; exact consumer composer UX unverified (https://you.com/resources/introducing-ari-the-first-professional-grade-research-agent-for-business) | Clarification/editable plan unverified (https://you.com/resources/introducing-ari-the-first-professional-grade-research-agent-for-business) | Live progress tracking (https://you.com/resources/ari-vs--chatgpt-deep-research-vs--google-deep-research-why-businesses-are-choosing-ari) | ~3 min average, under 5; up to 400 sources (https://you.com/resources/introducing-ari-the-first-professional-grade-research-agent-for-business) (https://you.com/resources/ari-vs--chatgpt-deep-research-vs--google-deep-research-why-businesses-are-choosing-ari) | Polished PDF, citations, tables, comparisons, interactive visuals (https://you.com/resources/ari-vs--chatgpt-deep-research-vs--google-deep-research-why-businesses-are-choosing-ari) | Enterprise-oriented; public stable quota unverified (https://you.com/resources/introducing-ari-the-first-professional-grade-research-agent-for-business) |

## Table stakes vs. differentiators

### Table stakes

1. **A deliberate research invocation.** Every headliner separates the expensive research path from ordinary fast chat/search through a tool, toggle, mode, or advanced capability rather than silently applying it to every prompt. (https://help.openai.com/en/articles/10500283-deep-research-faq) (https://support.google.com/gemini/answer/15719111?hl=en) (https://www.perplexity.ai/hub/blog/introducing-perplexity-deep-research) (https://support.claude.com/en/articles/11088861-use-research-on-claude) (https://x.ai/news/grok-3)

2. **Autonomous multi-step retrieval and synthesis.** Each product searches repeatedly, reasons over what it found, and produces a synthesized answer or report rather than exposing a conventional result list. (https://openai.com/index/introducing-deep-research/) (https://gemini.google/overview/deep-research/) (https://www.perplexity.ai/hub/blog/introducing-perplexity-deep-research) (https://www.anthropic.com/engineering/multi-agent-research-system) (https://x.ai/news/grok-3)

3. **Visible grounding.** The category norm is a cited or source-backed final output; even where xAI’s official copy is vague, independent testing exposes consulted-source counts. (https://help.openai.com/en/articles/10500283-deep-research-faq) (https://blog.google/products/gemini/google-gemini-deep-research/) (https://www.perplexity.ai/hub/blog/introducing-perplexity-deep-research) (https://www.anthropic.com/news/integrations) (https://the-decoder.com/grok-3-adds-deeper-search-and-ai-image-editing-capabilities/)

4. **A latency/quality contract.** Research is clearly slower and deeper than normal answer mode, with the products setting expectations from roughly 30 seconds to 45 minutes depending on product and task. (https://help.kagi.com/kagi/ai/kagi-research.html) (https://www.anthropic.com/news/integrations)

5. **Usage controls.** All major products gate the expensive path through quotas, plan tiers, dynamic compute limits, or fair-use consumption. (https://help.openai.com/en/articles/10500283-deep-research-faq) (https://support.google.com/gemini/answer/16275805?hl=en) (https://www.perplexity.ai/hub/blog/introducing-perplexity-deep-research) (https://support.claude.com/en/articles/11088861-use-research-on-claude) (https://x.ai/news/grok-3)

### Differentiators and open product bets

- **Editable plan and explicit approval:** strongest in ChatGPT and Gemini; this is not yet universal table stakes. (https://help.openai.com/en/articles/10500283-deep-research-faq) (https://support.google.com/gemini/answer/15719111?hl=en)
- **Mid-run steering:** ChatGPT explicitly supports interruption, focus changes, and source changes while research is running. (https://help.openai.com/en/articles/10500283-deep-research-faq)
- **Background trust and return UX:** Gemini most clearly documents asynchronous recovery, leaving the app, thread badges, and mobile notifications; ChatGPT also documents step-away completion notification. (https://gemini.google/overview/deep-research/) (https://support.google.com/gemini/answer/15719111?hl=en) (https://openai.com/index/introducing-deep-research/)
- **Source control:** ChatGPT offers strict or prioritized domains plus connected apps, while Gemini exposes a source picker spanning Search, Workspace, uploads, and NotebookLM. (https://help.openai.com/en/articles/10500283-deep-research-faq) (https://support.google.com/gemini/answer/15719111?hl=en)
- **Private-work corpus:** Claude, Microsoft Researcher, Gemini, ChatGPT, and ARI all treat connected private data as part of research, but Microsoft differentiates through Graph permissions and enterprise compliance. (https://www.anthropic.com/news/integrations) (https://learn.microsoft.com/en-us/copilot/microsoft-365/researcher-agent) (https://support.google.com/gemini/answer/15719111?hl=en) (https://help.openai.com/en/articles/10500283-deep-research-faq) (https://you.com/resources/introducing-ari-the-first-professional-grade-research-agent-for-business)
- **Artifacts, not only reports:** Perplexity Labs builds files and mini apps; Gemini turns reports into media and interactive Canvas content; ARI produces polished client-ready PDFs. (https://www.perplexity.ai/hub/blog/introducing-perplexity-labs) (https://gemini.google/overview/deep-research/) (https://you.com/resources/introducing-ari-the-first-professional-grade-research-agent-for-business)
- **Inspectable execution:** ChatGPT exposes activity history, Gemini exposes a thinking panel, and Kagi exposes tool dropdowns plus citation-relevance metadata. (https://help.openai.com/en/articles/10500283-deep-research-faq) (https://gemini.google/overview/deep-research/) (https://blog.kagi.com/kagi-assistants)
- **Corpus advantage:** Grok’s native X semantic/keyword/media search is unique among the reviewed products. (https://x.ai/news/grok-4)
- **Depth ladder:** Perplexity separates Search → Research → Labs, Grok exposes DeepSearch → DeeperSearch, and Kagi separates Quick → Research. (https://www.perplexity.ai/hub/blog/introducing-perplexity-labs) (https://the-decoder.com/grok-3-adds-deeper-search-and-ai-image-editing-capabilities/) (https://help.kagi.com/kagi/ai/kagi-research.html)

## All URLs used

- https://help.openai.com/en/articles/10500283-deep-research-faq
- https://openai.com/index/introducing-deep-research/
- https://support.google.com/gemini/answer/15719111?hl=en
- https://support.google.com/gemini/answer/16275805?hl=en
- https://gemini.google/overview/deep-research/
- https://blog.google/products/gemini/google-gemini-deep-research/
- https://www.perplexity.ai/hub/blog/introducing-perplexity-deep-research
- https://www.perplexity.ai/hub/blog/introducing-perplexity-labs
- https://support.claude.com/en/articles/11088861-use-research-on-claude
- https://support.claude.com/en/articles/11095361-when-should-i-use-web-search-extended-thinking-and-research
- https://www.anthropic.com/news/integrations
- https://www.anthropic.com/engineering/multi-agent-research-system
- https://x.ai/news/grok-3
- https://x.ai/news/grok-4
- https://the-decoder.com/grok-3-adds-deeper-search-and-ai-image-editing-capabilities/
- https://learn.microsoft.com/en-us/copilot/microsoft-365/researcher-agent
- https://learn.microsoft.com/en-us/microsoft-365/copilot/faq-researcher
- https://www.microsoft.com/en-us/microsoft-365/blog/2025/03/25/introducing-researcher-and-analyst-in-microsoft-365-copilot/
- https://blog.kagi.com/kagi-assistants
- https://help.kagi.com/kagi/ai/kagi-research.html
- https://help.kagi.com/kagi/ai/assistant.html
- https://you.com/resources/introducing-ari-the-first-professional-grade-research-agent-for-business
- https://you.com/resources/ari-vs--chatgpt-deep-research-vs--google-deep-research-why-businesses-are-choosing-ari
