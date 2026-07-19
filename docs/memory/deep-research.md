# Deep Research feature + Investigation repositioning

**Started:** 2026-07-18  **Status:** all 6 phases committed; plan-review done (2026-07-19), awaiting manual real-keys pass

## Goal

Ship Deep Research in the Research tab (durable, cited, verified report
sessions) and reposition Investigation as its casual in-chat tier, both on a
shared parameterized `ResearchEngine`. Full plan: `docs/DEEP_RESEARCH_PLAN.md`.

## Current state

All 6 phases committed on `feature/deep-research` (e3ce9f4 through b56b3ef;
phase 6 landed in d17cb97/1d03cf7). Every phase passed:
codex (gpt-5.6-sol) implementation -> Claude diff review + build/tests ->
Opus review -> fixes -> commit. UI (phase 5) was Claude-built with an
adversarial gpt-5.6-sol review (19 findings, all triaged and ~17 fixed).
iOS visual verification done via the DEBUG fixture args (see below) because
simulator HID input died mid-session.

The 2026-07-19 plan-review (`docs/DEEP_RESEARCH_REVIEW.md`) found no bugs;
its punch list is applied: verification moved to the Research Model (plan doc
updated to match), notification taps re-enable a disabled Research tab,
`ThreadOutcome` failures are structural (`failed` flag) instead of
string-sniffed, and the duplicated plan-payload type + view helpers were
collapsed.

## Next steps

1. Manual user testing per docs/testing/USER_FACING_TESTS.md H-DR-001..005
   (real keys needed: full run quality, notifications, follow-up grounding).
2. Delete this file (and docs/DEEP_RESEARCH_REVIEW.md) when the feature
   ships to main.

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
