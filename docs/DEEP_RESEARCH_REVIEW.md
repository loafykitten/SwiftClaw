# Deep Research — Implementation Review

**Reviewed:** 2026-07-19 · **Against:** `DEEP_RESEARCH_PLAN.md` (all 6 phases) ·
**Branch:** `feature/deep-research` · 4 parallel review workers + full test run

**Verdict: the plan is implemented.** All six phases are present and faithful
to the spec; the full macOS test suite passes (`Test Succeeded`, including all
nine new Research suites). No correctness bugs were found. What remains is a
short punch list (below) and the one genuine pre-merge gate: the **manual
real-keys pass `H-DR-001..005`** in `docs/testing/USER_FACING_TESTS.md`, which
cannot be automated (full-run report quality, notification delivery, follow-up
grounding).

## Action items (ranked)

**Status 2026-07-19 (later the same day): all five items below are resolved.**
Ember decided #1 the other way — verification now runs on the **Research
Model** (reasoning helps claim-vs-evidence entailment, and the plan's
Model-tiers paragraph already promised it); the plan's pipeline step 6 was
updated to match. #2 `showResearchSession` re-enables a disabled Research tab
(with a routing test). #3 `ThreadOutcome` carries a structural `failed` flag;
hedge-sniffing remains only for model-written "isn't established" prose.
#4 `ResearchSessionPlanPayload` collapsed into `ResearchPlanningResult`
(same JSON shape), `isAnotherRunActive` moved onto the coordinator,
`markViewed(in:)` onto `ResearchSession`. #5 memory file refreshed.
Remaining gate: the manual `H-DR-001..005` pass.

### 1. Decide the verification model tier — the plan contradicts itself

`ResearchEngine.swift:405-412` / `verify(...)` (~`:1297`) run claim
verification on the **Swift Model**. The plan says both things: pipeline step 6
("Swift Model checks each cited claim", plan line ~139) and the Model-tiers
paragraph ("planning, reflection, writing, and verification" on the Research
Model, ~line 160). Everything else routes exactly as promised.

**Recommendation:** keep Swift Model — verification is a mechanical
"does this stored excerpt support this claim" check, and cheap matters at
~40 claims/run — and fix the Model-tiers paragraph in the plan to match.
No code change.

### 2. Notification tap dead-ends if the Research tab is disabled mid-run

`AppRouter.showResearchSession` (`AppRouter.swift:108-111`) selects
`.deepResearch`, but `ContentView.ensureVisibleNavigationSelection`
(`ContentView.swift:319-326`) bounces a non-visible selection back to `.home`,
and the disable toggle removes the tab from `visibleNavigationItems`
(`ContentView.swift:88-92`). If the user disables Deep Research while a run is
in flight, the completion notification tap silently does nothing and
`pendingResearchSessionID` is never consumed.

**Fix (one-liner):** have `showResearchSession` re-enable
`deepResearchEnabled` (or exempt `.deepResearch` from the bounce while
`pendingResearchSessionID` is set).

### 3. `ThreadOutcome.isAnswered` is string-coupled to failure copy

`ResearchEngine.swift:595-608` decides answered/unanswered by
substring-matching the literal failure phrases produced at `:653`, `:674`,
`:682`, `:741`, `:933` ("could not be analyzed", "no web results were found",
…). Editing any failure message silently breaks Open-questions detection and
the gather-degradation note.

**Fix:** carry a structured `isAnswered`/`failed` flag on the outcome instead
of re-deriving it from prose (or at minimum a comment at both sites tying them
together).

### 4. Condense duplicated helpers

- `isAnotherRunActive` copy-pasted ×3 (`ResearchSessionFlowView.swift:261,
  452, 502`) — move to `ResearchSessionCoordinator.isAnotherRunActive(than:)`.
- `markViewed` ×3 (`ResearchSessionFlowView.swift:488, 547`,
  `ResearchReportView.swift:381`) — one shared helper/modifier.
- `ResearchSessionPlanPayload` (`ResearchSession.swift:17-20`) and
  `ResearchPlanningResult` (`DeepResearchTypes.swift:34-37`) are structurally
  identical, hand-copied in `generatePlan` (coordinator:180) — collapse to one
  type, or add a comment stating the persistence-vs-engine layering intent.

### 5. Refresh `docs/memory/deep-research.md`

Its "Current state" still says phase 6 is uncommitted/awaiting review; phase 6
landed in `d17cb97`/`1d03cf7`/`b56b3ef`. Update next steps to: (1) manual
`H-DR-001..005` pass, (2) delete the file in the merge-to-main commit.

## Noted — no action required for v1

- Page fetch is the one pipeline call not wrapped in `withDeadline`
  (`ResearchEngine.swift:805`); bounded only by the 15 s inactivity timeout +
  1.5 MB cap. A slow-drip server can outlive the run deadline. Rare; revisit
  if it ever shows up.
- `PageFetcher.swift:96-101` accumulates `AsyncBytes` one byte at a time —
  already recorded as deferred-by-design in the memory file.
- `ResearchRunningView` reads `ResearchProgressMonitor.shared` without
  matching `session.id` — safe under the one-run-at-a-time invariant the
  coordinator enforces.
- "Open questions" renders via the report markdown's own `##` heading rather
  than a dedicated styled section like Sources; `session.openQuestions` is
  only used for follow-up seeding. Cosmetic deviation from the plan's section
  list.
- Interrupted-at-planning sessions surface as terminal `.cancelled` rows
  (not resumable — no plan payload exists yet). Honest, just slightly odd UX.
- Foreground banner suppression is tab-coarse (`AppNotificationService.swift:541`),
  deliberately mirroring the mail precedent.
- Test-coverage soft spots, none warranting new tests now: no behavioral test
  of the `.investigation` preset end-to-end, PageFetcher timeout/redirect
  untested, coordinator resume asserted via flags but never driven.

## Plan promises verified met (per slice)

- **Engine (phases 1–3):** presets match the config table; `ResearchBudget`
  actor leasing with the 80% finalization window and planning-spend replay;
  PageFetcher caps + typed honest failures + snippet fallback with marked
  reason; evidence records with verbatim-quote guard; bounded reflection
  waves; outline-first writing with per-stage degradation; per-sentence ⚠
  verification with descending-offset insertion; Open questions dedup; Brave
  via `BraveRateGate`; Deep Research off `ToolRegistry.shared`;
  `ResearchReportTool` request-bound per resolved question 3; no
  `InvestigationEngine`/`SourceCatalog` leftovers.
- **Persistence (phase 4):** `ResearchSession` per MODELS.md, main local
  store (correctly not the CloudKit schema); coordinator owns the run task,
  one active session, cancel keeps partials, checkpoint per stage,
  resume-on-relaunch with no auto-restart and deletion-safe writes; monitor
  per the MailSyncMonitor pattern; deterministic notification identifiers with
  routing payload, per-feature + global gating, delivered-notification cleanup.
- **UI + refit (phases 5–6):** full session list / new / clarify / plan-review
  / running / report flow per the UX spec, citation popovers with ⚠ marker,
  macOS split view + TOC inspector vs iOS stack, badges, exports,
  Save to Notes, follow-up chat seeding; fixture seeder double-locked behind
  `#if DEBUG` + launch args; Investigation conversational refit + updated
  copy; all three Research settings actually wired into
  `ResearchConfiguration.deepResearch()`.
- **Tests/docs:** every phase's promised tests exist and are
  behavior-oriented; `USER_FACING_TESTS.md` H-DR/CU-DR entries match the
  implemented UX; the phase-6 simulator UI verification pass was performed
  (2026-07-19, launch-arg/fixture path).
