# Reminders feature (full build)

**Started:** 2026-07-11  **Status:** in progress

## Goal

Ship the Reminders feature end to end on `feature/reminders`, mirroring the
Calendar subsystem 1:1 (CloudKit-shaped SwiftData models in the
"SwiftClawCalendar" store, repository mutation boundary, EventKit import,
VTODO .ics import/export, due-date alerts, AI review loop, opt-in calendar
chips, Workspace tile). Full plan (research, scope decisions, 8 phases):
`~/.claude/plans/in-a-new-branch-hashed-llama.md` — key content mirrored here.

## Current state

**Phase 1 (foundation) implemented** — models, container registration,
recurrence engine, repository, sync coordinator, three test suites. Built by a
gpt-5.5 codex run, then reviewed by Claude, which found and fixed two bugs:

1. Engine COUNT off-by-one: codex expanded with the already-decremented rule,
   but `RecurrenceExpander`'s COUNT budget includes the anchor occurrence, so
   a COUNT=2 series ended one occurrence early. Fix: expand with the ORIGINAL
   rule, return the decremented string. Regression test
   `countTwoYieldsExactlyOneFinalOccurrence` added.
2. `dedupeLists` keyed by `externalIdentifier ?? name` — would merge distinct
   same-name lists (data loss). Fixed to `?? id.uuidString` matching
   `CalendarRepository.dedupeCalendars`; dedupe test updated + a
   never-merge-by-name guard test added.

All three Reminders suites pass. Full-suite regression run in progress; Phase 1
commit pending its result.

## Next steps

1. Confirm full test suite green, then commit Phase 1.
2. Phase 2: core UI (replace `RemindersView`/`RemindersSettingsView`
   placeholders), draft/editor, smart lists, ContentView lifecycle hook.
   Taste-sensitive — Claude implements directly, no codex. Check first whether
   `CalendarRecurrencePicker` is reusable for the repeat picker's
   fixed-schedule mode.
3. Phase 3: NL quick entry (`ReminderQuickEntryService`).
4. Phase 4: `ReminderAlertScheduler` + `Kind.reminder` routing
   (**lower calendar budget 48→36, reminders 12**).
5. Phase 5: Apple Reminders EventKit import + VTODO ICS + onboarding +
   entitlement/INFOPLIST key.
6. Phase 6: AI review loop (`ReviewType.reminders` already exists; replace
   placeholder branch at `ReviewCardRendererRegistry` line ~42).
7. Phase 7: calendar chips (parallel `ReminderCalendarItem` type, NOT
   `EventOccurrence`) + `WorkspaceRemindersSummary` tile.
8. Phase 8: `docs/features/REMINDERS.md`, doc updates, delete this file in the
   final commit.

## Decisions & constraints

- **Recurrence = roll-forward-on-completion**, both modes (RRULE fixed-schedule
  reusing `RecurrenceRule`/`RecurrenceExpander`, and after-completion interval
  as calendar components `{count, unit}` JSON). One row per series; `dueDate`
  always the next pending occurrence. Completing inserts a detached completed
  log row (`parentReminderID`/`originalOccurrenceDate`) and advances the master
  anchored at the *scheduled* date (early completion works). Undo = delete log
  row + restore `dueDate`. COUNT is decremented in the stored string on each
  advance. No EXDATEs/overrides; editing a recurring reminder edits the series.
- Date-only vs timed: `hasDueTime: Bool`; date-only = local start-of-day, nil
  timezone (floating, like `isAllDay`).
- Priority raw values on RFC 5545/EKReminder scale (0/1/5/9).
- Checklist = JSON blob `checklistData` (`alarmsData` pattern); dropped on
  Apple import (no EK API), round-trips VTODO via `X-SWIFTCLAW-CHECKLIST`.
- Research guardrails: NO gamification/kanban/tags/team features; AI only
  suggests (never mutates); completion always reversible; calm UI (sidebar +
  detail + one editor sheet); accessibility wins over HIG when they conflict.
- Subagents: user wants **gpt-5.5, not gpt-5.6-sol** — codex config defaults to
  5.6-sol, so pass `-m gpt-5.5` explicitly. Review every codex diff. UI phases
  (2, 7) are taste-sensitive: do directly or review extra hard.
- New files are auto-picked-up (`PBXFileSystemSynchronizedRootGroup`); only
  Phase 5's INFOPLIST key touches the pbxproj (both Debug + Release blocks).
- Build/test: `xcodebuild -scheme SwiftClaw -destination 'platform=macOS'
  build|test -derivedDataPath /tmp/DerivedData | xcbeautify --quiet`,
  `-only-testing:SwiftClawTests/<Suite>` to scope.

## Files touched

- `SwiftClaw/Models/Reminder.swift`, `SwiftClaw/Models/ReminderList.swift` — new CloudKit-shaped models + value types (`ReminderSource`, `ReminderPriority` on the 0/1/5/9 scale, `ReminderChecklistItem`, `ReminderAfterCompletionRepeat`).
- `SwiftClaw/Shared/SwiftClawModelContainerFactory.swift` — both models added to `calendarSchema` + `fullSchema`.
- `SwiftClaw/Services/Reminders/Recurrence/ReminderRecurrenceEngine.swift` — pure roll-forward math (fixed-schedule from scheduled date, after-completion from completion date, COUNT decrement).
- `SwiftClaw/Services/Reminders/Repository/ReminderRepository.swift` — mutation boundary; posts `.reminderStoreDidChange`; complete/uncomplete/skip transactions with log rows; upsert; dedupe.
- `SwiftClaw/Services/Reminders/ReminderSyncCoordinator.swift` — CalendarSyncCoordinator clone.
- `SwiftClawTests/Reminders/` — `ReminderRepositoryTests`, `ReminderRecurrenceEngineTests`, `ReminderPayloadCodingTests` (all green).
