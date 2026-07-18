# Deep Research feature + Investigation repositioning

**Started:** 2026-07-18  **Status:** ready for review (planning phase)

## Goal

Ship Deep Research in the Research tab (durable, cited, verified report
sessions) and reposition Investigation as its casual in-chat tier, both on a
shared parameterized `ResearchEngine`. Full plan: `docs/DEEP_RESEARCH_PLAN.md`.

## Current state

Planning complete on `feature/deep-research` (worktree
`.claude/worktrees/deep-research`). No code changes yet. Evidence reports
(gpt-5.6-sol research, citations spot-verified 14/14) committed under
`docs/research/deep-research/`.

## Next steps

1. Get Ember's review of `docs/DEEP_RESEARCH_PLAN.md` (open questions at the
   bottom need answers — especially SwiftSoup vs. hand-rolled extractor).
2. Phase 1: extract `Services/Research/ResearchEngine.swift` +
   `ResearchConfiguration` from `InvestigationEngine` with no behavior change;
   wire the dormant `SettingsKeys.deepResearchModel` fallback chain.
3. Phases 2–6 per the plan doc.

## Decisions & constraints

- One shared engine, two presets — not two pipelines (user's request,
  validated by architecture research).
- Deep Research is user-initiated from the Research tab; never registered on
  `ToolRegistry.shared`. Investigation stays the only chat research tool.
- Trust UX is the differentiator: evidence ledger with stored excerpts,
  claim-level citation popovers, verification pass, "Open questions" section.
- No quotas; show cost/scope hints instead (BYO keys).
- iOS: foreground-only runs in v1, with stage checkpoints + resume.
- `deepResearchModel` ("Research Model" in Behaviors) exists but is unused
  today — the engine must start honoring it (fallback: Claw Model).

## Files touched

- `docs/DEEP_RESEARCH_PLAN.md` — the plan (new)
- `docs/research/deep-research/{competitive-teardown,user-sentiment,architecture-patterns}.md` — verified evidence base (new)
- `docs/memory/deep-research.md` — this file
