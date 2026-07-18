# Deep Research feature + Investigation repositioning

**Started:** 2026-07-18  **Status:** Phase 2 ready for Claude review

## Goal

Ship Deep Research in the Research tab (durable, cited, verified report
sessions) and reposition Investigation as its casual in-chat tier, both on a
shared parameterized `ResearchEngine`. Full plan: `docs/DEEP_RESEARCH_PLAN.md`.

## Current state

Planning is complete on `feature/deep-research` (worktree
`.claude/worktrees/deep-research`). Phase 1 extracted the existing Investigation
pipeline into `ResearchEngine` + `ResearchConfiguration` and wired the optional
Research Model fallback. Phase 2 adds the shared budget, bounded HTML/PDF page
fetching, dependency-free main-content extraction, and evidence ledger behind
`.fetchPages`; the `.investigation()` snippet prompt and report path remain
unchanged. New focused test sources cover each component. Build and full test
verification are delegated to Claude per the phase task.

## Next steps

1. Claude: review the Phase 2 diff and run macOS/iOS build plus focused tests.
2. Address any compiler/test findings from the real project build.
3. Phases 3–6 per the plan doc.

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
- `SwiftClaw/Services/Research/ResearchConfiguration.swift` — shared presets and Research Model resolution
- `SwiftClaw/Services/Research/ResearchEngine.swift` — extracted Investigation pipeline
- `SwiftClaw/Services/Tools/Investigation/InvestigateTool.swift` — uses the Investigation preset
- `SwiftClaw/Services/Tools/Investigation/InvestigationEngine.swift` — deleted after extraction
- `SwiftClawTests/Research/ResearchConfigurationTests.swift` — preset, setting, and model-resolution coverage
- `SwiftClaw/Services/Research/{ResearchBudget,EvidenceStore,PageFetcher,ContentExtractor}.swift` — Phase 2 evidence and fetching primitives
- `SwiftClaw/Services/Research/ResearchEngine.swift` — budget routing and `.fetchPages` gather branch
- `SwiftClawTests/Research/{ResearchBudget,EvidenceStore,PageFetcher,ContentExtractor}Tests.swift` — Phase 2 focused coverage
