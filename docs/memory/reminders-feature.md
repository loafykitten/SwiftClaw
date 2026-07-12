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

**Phase 1 (foundation) committed as `e8a4d62`** — models, container
registration, recurrence engine, repository, sync coordinator, and three test
suites. Built by a gpt-5.5 codex run, then reviewed by Claude, which found and
fixed two bugs:

1. Engine COUNT off-by-one: codex expanded with the already-decremented rule,
   but `RecurrenceExpander`'s COUNT budget includes the anchor occurrence, so
   a COUNT=2 series ended one occurrence early. Fix: expand with the ORIGINAL
   rule, return the decremented string. Regression test
   `countTwoYieldsExactlyOneFinalOccurrence` added.
2. `dedupeLists` keyed by `externalIdentifier ?? name` — would merge distinct
   same-name lists (data loss). Fixed to `?? id.uuidString` matching
   `CalendarRepository.dedupeCalendars`; dedupe test updated + a
   never-merge-by-name guard test added.

**Phase 2 (core UI, settings, lifecycle) implemented and validated** —
the placeholder UI is now a sidebar of smart views and user lists, reminder
detail rows with reversible completion/history, list management, and one
draft-backed editor for due dates, both repeat modes, priority, flags,
checklists, URLs, and notes. `CalendarRecurrencePicker` was reusable unchanged.
Settings now expose enable/default-list controls, and the sync coordinator
starts and stops with the feature toggle.

Phase 2 review fixed two completion gaps: opening/cancelling the editor no
longer creates a default list (fallback creation happens only on Save), and
hiding/deleting the selected list returns the UI to Today. Sidebar selection,
toolbar actions, and completion controls received an accessibility pass.

All five Reminders suites pass, including new default-list and stale-selection
coverage. The full macOS suite passes (56 suites, 449 tests). Live smoke testing
verified launch, feature enablement, Settings, Workspace navigation,
accessibility labels, the empty state, and cancel-without-write. The UI
automation connection dropped during deeper editor interaction while the app
remained running with no crash in its logs.

**Phase 3 (NL quick entry) implemented and reviewed** —
`ReminderQuickEntryService` mirrors `CalendarQuickEntryService` (injectable
`completeProvider`, `.standalone`, strict JSON: title/due/has_time/list/
priority/rrule/repeat_after) but degrades instead of throwing where reminders
allow it: no due date is valid, a repeat without a due date is dropped so the
draft stays saveable, and an unmatched/omitted list stays nil (editor applies
the default; quick entry inherits the open user list). Quick entry bar sits
above the panes in `RemindersView`; any failure falls back to the manual
editor with the phrase as the title. Codex review (gpt-5.6-sol, after
`brew upgrade codex` → 0.144.1 — the gpt-5.5 workaround is obsolete) found
three valid P2s, all fixed with regression tests: blank parsed title now
throws (preserves the typed phrase), `has_time: true` with an offset-less
timestamp parses as local time (never downgrades to date-only; unreadable →
dateless), and impossible dates like 2026-02-30 are rejected by round-trip
validation instead of Calendar-normalized. 15 suite tests; full macOS suite
green.

## Next steps

1. Phase 4: `ReminderAlertScheduler` + `Kind.reminder` routing
   (**lower calendar budget 48→36, reminders 12**).
2. Phase 5: Apple Reminders EventKit import + VTODO ICS + onboarding hook/sheet
   + entitlement/INFOPLIST key.
3. Phase 6: AI review loop (`ReviewType.reminders` already exists; replace
   placeholder branch at `ReviewCardRendererRegistry` line ~42).
4. Phase 7: calendar chips (parallel `ReminderCalendarItem` type, NOT
   `EventOccurrence`) + `WorkspaceRemindersSummary` tile.
5. Phase 8: `docs/features/REMINDERS.md`, doc updates, delete this file in the
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
- `SwiftClaw/Features/Reminders/` — smart/user-list sidebar, list detail and rows, list management, and draft-backed editor/checklist/repeat controls.
- `SwiftClaw/Settings/Sections/RemindersSettingsView.swift`, `SwiftClaw/Settings/AppSettings.swift` — feature toggle, default-list preference, and future onboarding key.
- `SwiftClaw/ContentView.swift`, `SwiftClaw/Shared/AppBootstrap.swift` — sync coordinator lifecycle wiring.
- `SwiftClaw/Features/Reminders/QuickEntry/ReminderQuickEntryService.swift` — NL quick entry parsing into a `ReminderDraft`; `RemindersView` grew the entry bar + fallback.
- `SwiftClawTests/Reminders/` — foundation plus `ReminderDraftTests`, `ReminderSmartListTests`, and `ReminderQuickEntryServiceTests`; all six suites green.
