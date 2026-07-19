# Deep Research feature + Investigation repositioning

**Started:** 2026-07-18  **Status:** all 6 phases implemented; final review + verification pass in progress

## Goal

Ship Deep Research in the Research tab (durable, cited, verified report
sessions) and reposition Investigation as its casual in-chat tier, both on a
shared parameterized `ResearchEngine`. Full plan: `docs/DEEP_RESEARCH_PLAN.md`.

## Current state

Phases 1-5 committed on `feature/deep-research` (e3ce9f4, f04e9db, b6b7095,
edfcf9e, 6c8dd8c); Phase 6 (investigation refit + settings + docs) is in the
working tree awaiting its final review before commit. Every phase passed:
codex (gpt-5.6-sol) implementation -> Claude diff review + build/tests ->
Opus review -> fixes -> commit. UI (phase 5) was Claude-built with an
adversarial gpt-5.6-sol review (19 findings, all triaged and ~17 fixed).
iOS visual verification done via the DEBUG fixture args (see below) because
simulator HID input died mid-session.

## Next steps

1. Land Phase 6 after the Opus review verdict.
2. Manual user testing per docs/testing/USER_FACING_TESTS.md H-DR-001..005
   (real keys needed: full run quality, notifications, follow-up grounding).
3. Delete this file when the feature ships to main.

## Decisions & constraints

- One shared engine, two presets; Deep Research never registers on
  `ToolRegistry.shared` (InvestigateTool stays the only chat research tool;
  the request-bound `research_report` tool rides on `Chat.researchSessionID`).
- Trust UX: evidence ledger + citation sheets + claim ⚠ flags + Open
  questions; `isPartial` means cancelled/degraded, NOT open questions.
- iOS foreground-only runs in v1; interrupted runs map to honest
  cancelled/partial states at launch; resume = fresh run with saved plan.
- Deep settings: Settings > Deep Research (tab toggle, 5-30 min budget,
  2-8 threads, concise/standard/thorough length); Research Model stays in
  Behaviors with Claw fallback.
- DEBUG verification: `-research-fixture` seeds 4 sessions;
  `-research-fixture-open` deep-links the completed report;
  `-SwiftClawInitialNavigationItem research` lands on the tab.

## Known deferred items

- PageFetcher reads AsyncBytes byte-by-byte (fine vs network; chunk later).
- Citation sheet flags ⚠ sources at line granularity (claim-level verdict
  persistence would need engine changes).
- BGProcessingTask / iOS background completion out of scope for v1.
- `createSession` swallows save errors (logs only) — rare, revisit if seen.
