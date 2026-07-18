# Deep Research & Investigation — Plan

**Status:** ready for review · **Branch:** `feature/deep-research` · **Date:** 2026-07-18

SwiftClaw gains a real **Deep Research** feature (the currently-placeholder
Research tab), and **Investigation** is repositioned as its lighter, in-chat
sibling. Both run on one shared, parameterized `ResearchEngine`; they differ
only in configuration and presentation.

## Evidence base

Three verified research reports live in `docs/research/deep-research/`:

- `competitive-teardown.md` — how ChatGPT, Gemini, Perplexity, Claude, Grok,
  Copilot Researcher, Kagi, and You.com ARI ship this feature (primary-source
  cited; unverifiable details explicitly marked).
- `user-sentiment.md` — what users love/hate, mined from Reddit, HN, app-store
  reviews, and expert critiques.
- `architecture-patterns.md` — lab architectures (Anthropic/OpenAI/Google) and
  six OSS deep-research implementations, dissected at the source level.

Research was performed by gpt-5.6-sol shells; 14/14 sampled citations were
independently re-fetched and confirmed (including every load-bearing claim
referenced below). Claims below are traceable through those reports.

## What the evidence says

**Table stakes** (every serious product has these): a deliberate mode switch
separate from normal chat; autonomous multi-step search + synthesis; visible
source grounding; a stated slower-but-deeper time contract; usage controls.

**Differentiators worth copying:** editable pre-run plan with explicit start
(ChatGPT, Gemini — the single most-praised control); background continuation
with completion notifications (Gemini's is best documented); live
activity/thinking feed; a depth ladder (Search → Research → Labs at
Perplexity; Quick → Research at Kagi — exactly our Investigation → Deep
Research shape); citations that link claims to sources (Anthropic runs a
dedicated CitationAgent).

**Top user complaints, ranked:** (1) confident hallucinations and broken
citations — the dominant complaint for every product; (2) SEO-spam/low-quality
sources and paywall blindness; (3) padded "consultant slop" (Gemini) or
shallowness (Perplexity/Grok); (4) instructions ignored / questions silently
dropped ("misinformation by omission"); (5) verification cost eating the time
savings; (6) no mid-run steering; (7) stuck/failed runs losing everything;
(8) quota anxiety.

**Architecture consensus:** every serious implementation reads full pages
(snippets only discover sources — they can't support claims); "depth" is a
budget profile (search calls, page fetches, reflection waves, verification
coverage), not a recursion count; graceful degradation reserves 15–25% of
budget for finalization; citation quality climbs a ladder from "URL list" to
"claim-to-source verification". Ranked quality-per-complexity upgrades over
our current Investigation: (1) page fetching, (2) evidence ledger + citation
verification, (3) one bounded reflection wave, (4) outline-first section
writing, (5) source-aware critique, and only last (6) recursive multi-agent
orchestration (~15× chat token cost per Anthropic).

## Product decisions for SwiftClaw

**Lean into** (feasible and differentiating for a BYO-keys native app):

- **Trust as the headline.** Evidence ledger with stored supporting excerpts;
  claim-level citation popovers (tap [n] → title, domain, date, and the actual
  quote); a verification pass that flags unsupported claims visibly; an honest
  **"Open questions"** section listing what the run could not establish. This
  attacks complaints 1, 4, and 5, which no mainstream product solves well.
- **No quotas — cost transparency instead.** Users bring their own Brave and
  model keys, so we show an upfront estimate (time, search calls, rough token
  scale) rather than rationing runs. Kills complaint 8 structurally.
- **Editable plan gate.** Clarifying questions (skippable) → editable
  sub-question list → explicit "Start Research". Table stakes for the deep
  tier; Investigation skips it entirely.
- **Durable sessions + notifications.** Runs persist in SwiftData, survive
  navigation, badge the Research tab, and fire a local notification on
  completion. Partial results are always kept (complaint 7).
- **Report → workspace flow.** Export to the Notes vault, share as markdown,
  and "Ask a follow-up" spawning a chat seeded with the report — SwiftClaw
  already has the plumbing others lack.
- **Concise by default.** Target reports measured in screens, not pages, with
  a length/detail control in settings (complaint 3).

**Lean away from:**

- Recursive multi-agent orchestration, mid-run steering, and Labs-style
  artifact generation — high complexity, later-phase at best.
- Padding, fake comprehensiveness, decorative citations.
- iOS background completion promises we can't keep (see Constraints).

## Architecture: one engine, two presets

The user's instinct is right and matches both the current code shape and the
field's convergence: **one parameterized engine**, two configurations.

### `ResearchConfiguration`

`InvestigationEngine` already has the right skeleton (surface search → planned
threads → parallel workers → synthesis with a `SourceCatalog`). It generalizes
into `Services/Research/ResearchEngine.swift` driven by:

```swift
struct ResearchConfiguration: Sendable {
    var maxThreads: Int              // Investigation 3 (existing setting) · Deep 6
    var reflectionWaves: Int         // 0 · 2
    var searchCallBudget: Int        // 10 · 60
    var pageFetchBudget: Int         // 0 (snippets, as today) · 40
    var pagesPerThread: Int          // 0 · 3
    var sourceMode: SourceMode       // .snippets · .fetchPages(maxBytesPerPage:)
    var verification: Verification   // .none · .claimCheck
    var reportStyle: ReportStyle     // .conversational · .document(outlineFirst: true)
    var clarify: Bool                // false · true (UI-level gate)
    var planPreview: Bool            // false · true (UI-level gate)
    var totalBudget: Duration        // 120 s · 15 min (finalization reserve ~20%)
    var finalizationReserve: Double  // 0.2 — stop launching work at 80% elapsed
}
```

A single `ResearchBudget` actor leases search calls, page fetches, and time so
parallel workers can't overspend (pattern from the architecture report). All
Brave traffic keeps flowing through `BraveRateGate`.

### Pipeline (shared; deep-only stages marked ◆)

1. **Clarify ◆** (UI, not engine): Research Model asks ≤3 questions; skippable.
2. **Plan**: surface search → thread plan. ◆ Deep shows it as an editable list
   behind "Start Research".
3. **Gather**: parallel threads; each searches, ◆ fetches + extracts top pages
   (`PageFetcher` + `ContentExtractor`), and a Swift-Model pass produces
   **evidence records** — `(url, title, quote, claimSummary, retrievedAt)` —
   into an `EvidenceStore` actor (generalizing `SourceCatalog`).
4. **Reflect ◆**: one Research-Model gap analysis ("what's still unanswered or
   contradictory?"); launch follow-up threads only if budget allows; repeat up
   to `reflectionWaves`.
5. **Write**: Investigation = single conversational synthesis (as today, but
   lighter format). ◆ Deep = outline first, sections drafted against their
   assigned evidence, intro/conclusion last.
6. **Verify ◆**: Swift Model checks each cited claim against its stored
   excerpt; unsupported claims get repaired or flagged `⚠`; unanswered plan
   questions land in "Open questions".
7. **Deliver**: Investigation returns a string into chat, as today. Deep
   persists a `ResearchSession` report + sources + evidence, fires the
   notification.

Failure at any stage degrades to the previous stage's output — the mechanical
fallback pattern `InvestigationEngine` already implements, extended per stage.

### New components

| Component | Kind | Notes |
|---|---|---|
| `ResearchEngine`, `ResearchConfiguration`, `ResearchBudget`, `EvidenceStore` | `Services/Research/` | Engine extracted from `InvestigationEngine`; presets `.investigation` / `.deepResearch` |
| `PageFetcher` | struct | URLSession, ~1.5 MB & 15 s caps, HTML/PDF-text only, honest failure (skip + note) |
| `ContentExtractor` | struct | HTML → main-content plain text/markdown. Open question: hand-rolled heuristics vs. adding SwiftSoup (repo currently has zero deps — prefer hand-rolled first pass) |
| `ResearchSession` | `@Model` | Per MODELS.md: unique UUID id, `statusRaw`+computed enum, JSON blobs (`planData`, `sourcesData`, `evidenceData`), `reportMarkdown`, timestamps, `errorMessage` |
| `ResearchSessionCoordinator` | `@MainActor` singleton | `ChatTaskCoordinator` pattern: owns the run `Task`, one active session at a time, cancel keeps partials, checkpoint after each stage for resume-on-relaunch |
| `ResearchProgressMonitor` | `@MainActor @Observable` | `MailSyncMonitor` pattern: stage, activity feed lines, source counter, elapsed/budget |
| `AppNotificationService.notifyResearchComplete(sessionID:title:)` | addition | Routes into the session via `NotificationRoutingPayload` |

**Model tiers:** the existing-but-unused `SettingsKeys.deepResearchModel`
("Research Model") finally gets wired: planning, reflection, writing, and
verification for both tiers (falling back to Claw Model when unset — resolves
today's inconsistency where the setting exists but `InvestigationEngine` uses
Claw); extraction stays on Swift Model.

**Not a chat tool:** Deep Research is user-initiated from the Research tab and
never registered on `ToolRegistry.shared` (per TOOLS.md capability-based
registry rule). `InvestigateTool` remains the only research-shaped chat tool,
now calling `ResearchEngine` with the `.investigation` preset.

## UX design

### Research tab (macOS split view; iOS stack)

- **Sidebar/list**: sessions newest-first (`SidebarList` styling), each row
  showing title, date, and status (spinner=running, ✓, ⚠ partial, ✕ failed).
  "New Research" button at top. Tab badge while a run is active or unviewed.
- **New session**: multiline topic field with a one-line scope hint under it —
  "Deep Research takes ~10–20 min and makes ~40–60 searches with your keys" —
  and a Start button. No depth slider in v1; Investigation *is* the shallow
  option.
- **Clarify** (skippable): the assistant's ≤3 questions rendered as a short
  form with one text field each; "Skip — research as asked" is always visible.
- **Plan review**: editable checklist of sub-questions (inline edit, delete,
  add), the overview sentence, and **Start Research**. This screen is the
  quota-free "cost preview" moment.
- **Running**: stage timeline (Planning → Searching → Reading →
  Cross-checking → Writing) with the live feed beneath (recent queries, pages
  read, evidence count), sources counter, elapsed vs. budget. **Cancel** stops
  after the current stage and writes a partial report. Navigating away is
  fine; completion fires a local notification (macOS + iOS) that deep-links to
  the session.
- **Report**: rendered with `MarkdownRenderedView`. Tappable `[n]` citations
  open a popover: source title, domain, date, and the stored supporting
  excerpt — plus `⚠ not verified against source` when the check failed.
  Sections: report body → **Open questions** → **Sources** (numbered, with
  domains). macOS gets a TOC inspector. Toolbar actions: Copy, Share/export
  markdown, **Save to Notes**, **Ask a follow-up** (creates a chat whose first
  system-side context is the report + sources).

### Investigation (the casual tier)

- Stays exactly where it is: composer toggle, opt-in per message, result in
  the chat stream.
- Report format lightens: short overview, key findings with inline `[n]`
  cites, sources — drops the rigid three-section structure; tone directive in
  the synthesis prompt becomes conversational.
- Tool description updated to position it against Deep Research; composer help
  text likewise ("Quick multi-search investigation — for a full cited report,
  use Research").
- Optional cross-link (phase 4): a small "Research this deeper" chip on
  investigation results that pre-fills a Deep Research session.

## Constraints

- **iOS backgrounding:** v1 deep runs require the app foregrounded (same as
  chat generation today). Stage checkpoints mean a suspended run offers
  "Resume research?" on return instead of losing work. macOS runs freely.
  `BGProcessingTask` is explicitly out of scope for v1.
- **Brave rate limits:** deep tier paces through `BraveRateGate` with its
  budget; degraded search ⇒ partial report, never a hard failure.
- **Paywalls/403s:** fetch failures fall back to that source's snippet and the
  report marks snippet-only evidence (sentiment report shows users accept
  honest gaps, not silent ones).
- **Token cost:** a deep run will plausibly use 10–30× an Investigation run
  (field data: Gemini estimates ~250k input tokens/run; Anthropic ~15× chats).
  The scope hint on the new-session screen is the mitigation.

## Implementation phases

Each phase builds and passes tests independently; plan-review after each.

1. **Engine extraction (no behavior change).** Create `Services/Research/`;
   move `InvestigationEngine` internals into `ResearchEngine` +
   `ResearchConfiguration`; `InvestigateTool` uses the `.investigation`
   preset; wire `deepResearchModel` fallback chain. Existing investigation
   tests keep passing; add config/budget unit tests.
2. **Evidence + fetching.** `PageFetcher`, `ContentExtractor`,
   `EvidenceStore`, `ResearchBudget`; snippets→pages behind
   `sourceMode`; extraction produces evidence records. Unit tests with HTML
   fixtures.
3. **Deep pipeline.** Reflection wave, outline-first writing, claim
   verification, per-stage degradation. Engine-level integration test behind a
   mocked search/fetch layer.
4. **Persistence + coordinator.** `ResearchSession` model (main store),
   `ResearchSessionCoordinator` with checkpoints/resume,
   `ResearchProgressMonitor`, completion notification + routing.
5. **Research tab UI.** Session list, new/clarify/plan/running/report views,
   citation popovers, exports, follow-up-chat bridge. Replace
   `DeepResearchView` placeholder.
6. **Investigation refit + settings + polish.** Casual report format, tool
   description/help text, `SettingsSection.deepResearch` (enable toggle, time
   budget, thread cap, report length), USER_FACING_TESTS entries, simulator
   UI verification pass.

## Open questions

1. `ContentExtractor`: hand-rolled readability heuristics vs. adding
   SwiftSoup as the repo's first dependency. (Plan assumes hand-rolled.)
2. Should Deep Research later expose a second "Extended" effort level (Gemini
   Max / Grok DeeperSearch pattern), or is Investigation → Deep Research
   ladder enough? (Assumed: enough for v1.)
3. Follow-up chat seeding: full report in context vs. summary + on-demand
   fetch tool. (Assumed: summary + sources list; report is markdown the model
   can request via an appended request-bound tool.)
4. Do investigation runs also get evidence-backed citation popovers in chat
   (nice, but requires persisting evidence for chat messages)? (Assumed: v1
   no — chat report keeps plain `[n]` + source URLs.)
