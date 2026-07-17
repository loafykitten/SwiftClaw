# Memory feature implementation

**Started:** 2026-07-16  **Status:** in progress (planned, no code yet)

## Goal

Implement the Memory feature per `docs/features/MEMORY.md` (settled design)
and `docs/MEMORY_PLAN.md` (phases, key decisions). Done = all three phases
landed with tests, the plan doc retired into the feature doc, and this file
deleted.

## Current state

Planning complete; no implementation code exists. `docs/MEMORY_PLAN.md`
holds the verified research findings, the resolutions of the feature doc's
four open questions, the data model, and the phase breakdown. A placeholder
`WorkspaceItem.memory` + coming-soon `MemoryView` already exist and must be
converted, not duplicated.

## Next steps

1. Phase 1, step 1: add the four `@Model` classes (`MemoryCollection`,
   `MemoryEntry`, `MemoryProposal`, `MemoryActivityEvent`) in `Models/`,
   register them in **both** `mainSchema` and `fullSchema` in
   `Shared/SwiftClawModelContainerFactory.swift`, and build
   `MemoryRepository` + `MemoryFeatureModel` with `SwiftClawTests/Memory/`
   suites. Field lists are in the plan's "Data model" section.
2. Phase 1, step 2: feature wiring (WorkspaceFeature case, settings,
   ToolsView, SettingsSection + MemorySettingsView, WorkspaceView tile
   conversion).
3. Phase 1, step 3: Memory UI (three-column macOS / stacked iOS, access
   badges, confirmations, search, activity feed).
4. Then Phase 2 (LLM exposure) and Phase 3 (review integration) per the plan.

## Decisions & constraints

All key decisions are recorded in `docs/MEMORY_PLAN.md` — do not re-litigate
there-resolved questions (serialization format, lexical-not-SearchIndex
search, own `MemoryProposal` model, hard-delete undo). User instruction:
plan and docs first, implementation only after explicit go-ahead; work lives
on the `feature/memory` branch.

## Files touched

- `docs/MEMORY_PLAN.md` — new implementation plan.
- `docs/features/MEMORY.md` — status note + open questions replaced with
  planning resolutions.
- `AGENTS.md` — doc index entry for the plan.
