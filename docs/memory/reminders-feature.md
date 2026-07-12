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

**Phase 4 (due-date notifications) implemented and reviewed** —
`ReminderAlertScheduler` mirrors `CalendarAlertScheduler` (`.reminderStoreDidChange`
+ 12h tick, 7-day fire horizon, budget 12; calendar lowered 48→36). One alert
per pending due-dated reminder: timed fires at `dueDate`, date-only at
`settings.reminders.allDayAlertMinutes` (default 9:00 AM; toggle + time picker
in Notification Settings, key `settings.notifications.reminderAlerts.enabled`).
Routing: `Kind.reminder` → `AppRouter.showReminders(focusing:)` →
`pendingReminderFocusID` threads ContentView → WorkspaceView → RemindersView,
which selects the reminder's list (Today fallback) and clears the focus.
Lifecycle in ContentView/AppBootstrap; disable clears booked alerts. Codex
review (gpt-5.6-sol) found three valid issues, all fixed with regression
tests: date-only fire dates are now built from calendar components (DST-safe),
identifiers embed a stable SHA256 content fingerprint so title edits rebook
the request, and reconcile awaits an in-flight `clearAllPendingAlerts` so a
quick disable→enable can't strand alerts. 19 scheduler tests; full suite green.
NOTE: the stale-content and clear-race fixes were NOT back-ported to
`CalendarAlertScheduler` (same latent issues there, pre-existing, out of
scope) — tracked as its own task in `calendar-alert-scheduler-backports.md`
so the note survives this file's deletion at Phase 8.

**Phase 5 (Apple Reminders + VTODO import/export + onboarding) implemented and reviewed** —
the first-open Reminders sheet now offers Apple Reminders import, `.ics`
import, or a fresh start, with both import paths and per-list export also
available later in Settings. Apple import requests full EventKit access,
copies selected lists and reminders into the SwiftClaw store, maps dates,
completion, priority, and supported fixed recurrence, and safely re-runs by
stable EventKit identity. VTODO import/export shares the Calendar ICS reader
and writer, keeps standard fields plus SwiftClaw flags, checklists, and
after-completion repeats, and accepts mixed VEVENT/VTODO files without the
component types interfering.

The requested sub-agent review and fix-verification pass found six edge-case
bugs, all fixed with regression tests: Apple re-import clears the local-only
after-completion repeat only when the source carries a fixed rule, status-only
completed imports keep their original fallback timestamp, reminders without a
cross-device EventKit identifier use the stable local identifier and migrate
the same row if an external identity appears later, and impossible ICS dates
are rejected instead of Calendar-normalized into another day. The new focused
suites, existing Calendar ICS suite, and full macOS suite pass.

## Next steps

1. Phase 6: AI review loop (`ReviewType.reminders` already exists; replace
   placeholder branch at `ReviewCardRendererRegistry` line ~42).
2. Phase 7: calendar chips (parallel `ReminderCalendarItem` type, NOT
   `EventOccurrence`) + `WorkspaceRemindersSummary` tile.
3. Phase 8: `docs/features/REMINDERS.md`, doc updates, delete this file in the
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
- `SwiftClaw/Services/Reminders/ReminderAlertScheduler.swift` — due-date alert reconciliation; `AppNotificationService`/`NotificationRoutingPayload` grew the reminder posting path, `Kind.reminder`, and fingerprinted identifiers; `AppRouter`/`WorkspaceView`/`RemindersView` thread `pendingReminderFocusID`; `NotificationSettingsView` has the toggle + all-day time picker; calendar budget now 36.
- `SwiftClaw/Services/Reminders/Import/`, `Features/Reminders/Import/` — EventKit mapping/import, list picker, and first-open onboarding; Reminders Settings now exposes repeatable Apple/ICS import and per-list export; permission strings and the Reminders entitlement are wired for both build configurations.
- `SwiftClaw/Services/Reminders/ICS/`, `Services/Calendar/ICS/` — neutral VTODO representation, store transfer, and shared parser/serializer support for standard to-do fields plus SwiftClaw round-trip extensions.
- `SwiftClawTests/Reminders/` — foundation, UI/service phases, alert scheduling, EventKit import mapping/application, and VTODO round trips; all ten suites green.
