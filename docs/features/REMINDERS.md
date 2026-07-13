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
- **Recurrence = roll-forward-on-completion**, in two modes: fixed-schedule
  (an RFC 5545 RRULE string reusing `RecurrenceRule`/`RecurrenceExpander`)
  and after-completion interval (calendar components `{count, unit}` JSON).
  One row per series; while the master is pending, `dueDate` is the next
  pending occurrence (an exhausted series keeps its final due date with
  `completedAt` set) — occurrences are never expanded or persisted. Completing inserts a detached
  completed log row (`parentReminderID`/`originalOccurrenceDate`) and
  advances the master: fixed-schedule from the *scheduled* date (so early
  completion works), after-completion from the completion date
  (`Services/Reminders/Recurrence/ReminderRecurrenceEngine.swift`). COUNT is
  decremented in the stored string on each advance. Undo deletes the log row
  and restores `dueDate`. No EXDATEs/overrides — editing a recurring
  reminder edits the series.
- Date-only vs timed: `hasDueTime: Bool`; date-only reminders store local
  start-of-day with a nil timezone (floating, like the calendar's `isAllDay`).
- Priority raw values sit on the RFC 5545 / EKReminder scale (0/1/5/9).
- Checklist items are a JSON blob on `checklistData` (the `alarmsData`
  pattern from `docs/conventions/MODELS.md`).
- `Services/Reminders/Repository/ReminderRepository.swift` is the single
  mutation boundary and identity authority: complete/uncomplete/skip
  transactions with log rows, upsert, dedupe, and it posts
  `.reminderStoreDidChange`. `Services/Reminders/ReminderSyncCoordinator.swift`
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

A `CalendarAlertScheduler` mirror: one alert per pending due-dated reminder,
reconciled over a rolling 7-day fire window on every store save
(`.reminderStoreDidChange`) and a 12 h tick, soonest-first under a
12-request budget (the calendar drops from 48 to 36 only while reminder
alerts can actually book, sharing the 64-request system cap). Timed
reminders fire at `dueDate`; date-only reminders fire at
`settings.reminders.allDayAlertMinutes` (default 9:00 AM; toggle + time
picker in Settings › Notifications), with fire dates built from calendar
components so DST can't shift them. Identifiers embed a content fingerprint
so edits rebook the request. Disabling the toggle or the feature clears
booked alerts. Taps route via `NotificationRoutingPayload.Kind.reminder` →
`AppRouter.showReminders(focusing:)` (a no-op while the feature is disabled —
a delivered banner can outlive the toggle), which threads a focus ID down
ContentView → WorkspaceView → RemindersView to select the reminder's list,
or its editor directly when that list is hidden.

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
since its `lastReviewedAt` stamp (set only after a successful pass); manual
runs bypass all suppression.

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
