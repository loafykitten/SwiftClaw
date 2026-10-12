# Reminders

SwiftClaw's own to-do list: SwiftData-backed reminders with smart views and
user lists, natural-language quick entry, Apple Reminders + VTODO .ics
import, .ics export, due-date alerts, an AI Reminders Review, opt-in chips in
the Calendar views, and a Workspace tile. Mirrors the Calendar subsystem's
architecture throughout — when in doubt, the Calendar counterpart is the
template (`docs/features/CALENDAR.md`).

## Data model (`Models/Reminder.swift`, `Models/ReminderList.swift`)

- Lives in the same **CloudKit-shaped "SwiftClawCalendar" configuration** as
  the calendar models (built in `Shared/SwiftClawModelContainerFactory.swift`;
  the documented exception in `docs/conventions/MODELS.md`), so flipping on
  sync needs no migration.
- **Recurrence rolls forward on completion** in two modes: fixed schedule (an
  RFC 5545 RRULE using `RecurrenceRule`/`RecurrenceExpander`) and an
  after-completion interval (`{count, unit}` JSON). One row represents the
  series; occurrences are never expanded or persisted.
- While a recurring master is pending, `dueDate` is its next occurrence.
  Completion inserts a detached log row
  (`parentReminderID`/`originalOccurrenceDate`) and advances the master from
  the scheduled date for fixed recurrence or the completion date for
  after-completion recurrence
  (`Services/Reminders/Recurrence/ReminderRecurrenceEngine.swift`). COUNT is
  decremented on each advance; an exhausted series keeps its final due date
  with `completedAt` set.
- Each completion records on its log row (`completionSnapshotData`, a
  `ReminderCompletionSnapshot`) the master's due date, completion stamp,
  rule, and after-completion repeat before and after it advanced. Undo
  removes the log row and restores the before-state exactly. Only the latest
  log can be undone, and only while the master still matches the recorded
  after-state: a later skip, reschedule, or rule edit (COUNT included) makes
  `uncomplete` throw `UndoCompletionError`, which the row shows in its alert.
  Logs written before snapshots existed are refused too. There are no EXDATEs
  or per-occurrence overrides; editing a recurring reminder edits the series.
- Date-only vs timed: `hasDueTime: Bool`; date-only reminders store local
  start-of-day with a nil timezone (floating, like the calendar's `isAllDay`).
- Priority raw values sit on the RFC 5545 / EKReminder scale (0/1/5/9).
- Checklist items are a JSON blob on `checklistData` (the `alarmsData`
  pattern from `docs/conventions/MODELS.md`).
- `Services/Reminders/Repository/ReminderRepository.swift` is the single
  mutation boundary and identity authority: complete/uncomplete/skip
  transactions with log rows, upsert, dedupe, and it posts
  `.reminderStoreDidChange`. Complete, uncomplete, skip, and delete each run
  as their own `performTransaction` and throw `SaveError` when the save
  fails; the rollback covers only that change (changes already pending on the
  shared context are saved first). `ReminderListDetailView` and the calendar's
  reminder chips surface failures in one `actionFailureAlert` per screen. `Services/Reminders/ReminderSyncCoordinator.swift`
  is the `CalendarSyncCoordinator` clone for the (currently dormant) CloudKit
  path — see CALENDAR.md's "CloudKit sync (dormant)" for why.

## Import / export (`Services/Reminders/Import`, `Services/Reminders/ICS`)

- `AppleRemindersImporter` + `ReminderKitMapping`: re-runnable EventKit
  import — copies selected lists and reminders; maps dates, completion,
  priority, and supported fixed recurrence; upserts by stable EventKit
  identity, falling back to the local identifier when no cross-device
  external identifier exists (and migrating the same row if one appears
  later). Checklists are dropped on Apple import (no EK API). Needs the
  reminders entitlement + `NSRemindersFullAccessUsageDescription` (an
  `INFOPLIST_KEY_*` build setting in both configurations; Info.plist is
  generated).
- VTODO import/export shares the Calendar ICS reader/writer
  (`Services/Calendar/ICS/`), funneled through `ICSTodoTransfer.swift`.
  Standard fields round-trip, plus SwiftClaw extras via `X-SWIFTCLAW-*`
  properties (flags, checklists, after-completion repeats). Mixed
  VEVENT/VTODO files parse without the component types interfering;
  impossible dates are rejected rather than Calendar-normalized.
- First-open onboarding (`Features/Reminders/Import/RemindersOnboardingSheet`)
  offers Apple import / .ics import / start fresh; Apple import, .ics import,
  and per-list .ics export are all re-runnable from Settings › Reminders.

## UI (`Features/Reminders/`)

`RemindersView` hosts a sidebar of smart views (`ReminderSmartList`) and user
lists, reminder detail rows with reversible completion and history, list
management, and the quick entry bar. One draft-backed editor sheet
(`Editor/ReminderEditorSheet` over a `ReminderDraft` value; Save is the only
write — cancelling never creates the fallback default list) covers due
dates, both repeat modes, priority, flags, checklists, URLs, and notes;
`CalendarRecurrencePicker` is reused unchanged for fixed schedules.

Quick entry (`QuickEntry/ReminderQuickEntryService`) mirrors
`CalendarQuickEntryService` (injectable `completeProvider`, `.standalone`
prompt, strict JSON) but degrades instead of throwing where reminders allow
it: no due date is valid, a repeat without a due date is dropped so the
draft stays saveable, and an unmatched list stays nil (the editor applies
the default; quick entry inherits the open user list). Any failure falls
back to the manual editor with the typed phrase as the title.

## Alerts (`Services/Reminders/ReminderAlertScheduler.swift`)

- One alert is booked per pending due-dated reminder. The scheduler reconciles
  a rolling 7-day fire window after store saves
  (`.reminderStoreDidChange`) and every 12 hours, keeping the soonest 12
  requests. Calendar uses 36 of the 64 system slots while Reminder alerts are
  active and 48 otherwise.
- Timed reminders fire at `dueDate`. Date-only reminders use
  `settings.reminders.allDayAlertMinutes` (default 9:00 AM; configured in
  Settings › Notifications), with calendar components preventing DST shifts.
- Content fingerprints make edits replace stale requests. Disabling the alert
  source or feature clears booked alerts, after waiting for in-flight posts
  so an add already past its gate is removed instead of surviving; a pass
  overtaken by a newer one stops before touching requests.
- Taps route through `NotificationRoutingPayload.Kind.reminder` to
  `AppRouter.showReminders(focusing:)`. Routing is a no-op while the feature is
  disabled. Otherwise it selects the reminder's list, or opens the editor when
  that list is hidden.

## Reminders Review (`Services/Reminders/Review/`, `ReminderWorkflowManager`)

The Calendar Review pattern 1:1: `ReminderWorkflowManager` owns the loop
(interval from Settings › Reminders; 0 = manual only),
`ReminderReviewService.runOnce()` builds a `.standalone` prompt with a scoped
`ToolRegistry` of `fetch_reminders` + `notify_user_about_reminders` (never on
`ToolRegistry.shared`), and the model decides whether to create a
"Reminders review —" chat with a review card
(`Features/Chats/ReviewCards/RemindersReviewCardRenderer`). Scope is pending
masters that are undated, overdue, or due within 7 days. Scheduled passes
skip when a review is still unread, nothing is pending, or nothing changed
since its `lastReviewedAt` stamp (set only after a successful pass, and only
on rows unchanged since the fetch); manual runs bypass all suppression. The
"changed?" check spans the whole scope, and when the fetch is limited it
admits new or changed reminders first.

## Calendar chips + Workspace tile

Opt-in (default-off `settings.reminders.showInCalendar` toggle in Settings ›
Reminders, AND-ed with the feature toggle): `ReminderCalendarItem` /
`ReminderCalendarItemBuilder` produce one item per pending master — no
expansion; overdue rolls forward to render on today, Today-smart-list style;
hidden lists are respected. `ReminderCalendarChipView` renders in the month
grid (inside the shared per-cell chip budget + overflow popover), the
timeline all-day strip, and agenda sections (agenda rows get a
complete-in-place button that goes through `ReminderRepository.complete` so
recurrence rolls forward). The Workspace tile is the pure
`WorkspaceRemindersSummary` (Today incl. overdue / Overdue / This Week /
Flagged + next timed deadline) rendered by `WorkspaceRemindersStatsView`.
Both the chips and the tile re-evaluate `now` via
`TimelineView(.everyMinute)` so overdue state moves while a window sits open.

## Testing

`SwiftClawTests/Reminders/` — recurrence-engine roll-forward goldens,
repository CRUD + dedupe, smart-list filtering, draft/editor rules,
quick-entry parsing, alert-scheduler reconciliation against the notification
spy, EventKit mapping + importer application, VTODO round-trips, review
service/tool seams, payload coding, calendar-item builder, and the Workspace
summary. Run with `-only-testing:SwiftClawTests/<Suite>`.
