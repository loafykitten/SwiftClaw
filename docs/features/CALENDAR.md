# Calendar

SwiftClaw's own calendar: SwiftData-backed events with month/week/day/agenda
views, Apple Calendar + .ics import, .ics export, scheduled event alerts, an
AI Calendar Review mirroring the Inbox Review, and an optional read-only
Apple Calendar overlay.

## Data model (`Models/CalendarEvent.swift`, `Models/UserCalendar.swift`)

- Own canonical store, **separate "SwiftClawCalendar" configuration** built in
  `Shared/SwiftClawModelContainerFactory.swift`. The models are CloudKit-shaped
  (no `@Attribute(.unique)`, everything defaulted/optional — the documented
  exception in `docs/conventions/MODELS.md`) so flipping on sync needs no
  migration.
- Recurring events store one master row + an RFC 5545 RRULE string
  (`Services/Calendar/Recurrence/RecurrenceRule.swift`). Occurrences are
  **never persisted** — `RecurrenceExpander` materializes them per visible
  window; `CalendarOccurrenceBuilder` turns rows into the `EventOccurrence`
  values every view consumes.
- "Edit this event only" = EXDATE on the master + a detached override row
  (`parentEventID` / `originalOccurrenceDate`), the same shape EventKit uses.
- **All-day events are civil dates, never instants.** `startDate`/`endDate`
  of an all-day row hold canonical `CivilDay` dates (midnight UTC of each
  day, `Models/CivilDay.swift`) with an exclusive end day, so July 10 stays
  July 10, one day long, in any zone the device moves to. The master's
  EXDATEs, its overrides' `originalOccurrenceDate`, and its RRULE UNTIL (end
  of the civil day) use the same encoding, and all-day series expand in
  canonical (GMT) space, so they step by whole days, months, and years.
  Conversion to the current zone happens only at the boundaries:
  `CalendarOccurrenceBuilder` (which tests each occurrence's real local
  interval, so a 23-hour day can't drop out of a late window), the editor
  draft, alert fire dates (wall-clock offsets on the civil day), `.ics`
  `VALUE=DATE`, EventKit import/overlay, and quick entry.
  `EventOccurrence.start` is local; repository occurrence APIs take
  `occurrenceKey` (the stored encoding). Store window predicates widen by a
  day (`CalendarEvent.storeFetchWindow`). Timed events keep absolute
  instants. Legacy rows (`dateEncodingVersion == nil`, local-midnight
  instants) convert once at launch
  (`CalendarRepository.migrateAllDayDatesToCivilEncodingIfNeeded`, from
  `AppBootstrap`), reading each instant in the zone current at migration
  time; the per-row marker keeps it idempotent.
- `Services/Calendar/Repository/CalendarRepository.swift` is the single
  mutation boundary and the identity authority (deterministic lookups,
  `dedupeAfterRemoteMerge()` for CloudKit-merge duplicates). User-facing
  writes (editor Save, deletes, drag-reschedule, imports) run through
  `performTransaction`, which throws `SaveError` on a failed save after
  rolling back only its own writes: changes already pending on the shared
  context are saved before it starts. Tests inject save failures through the
  repository's `persist` seam.

## CloudKit sync (dormant)

`SwiftClawModelContainerFactory` uses a CloudKit-backed calendar configuration
only when the process has `com.apple.developer.icloud-services` (checked via
`SecTask` because CloudKit traps rather than throws without it). Builds without
the entitlement use the same local store. The re-enable recipe lives in
`SwiftClaw/SwiftClaw.entitlements`.

`Services/Calendar/CalendarSyncCoordinator.swift` runs a debounced dedupe
pass on remote-change notifications once sync is live.

## Import / export (`Services/Calendar/Import`, `Services/Calendar/ICS`)

- `AppleCalendarImporter` + `EventKitMapping`: re-runnable EventKit import —
  upserts by `calendarItemExternalIdentifier`, reconstructs recurring masters,
  maps detached occurrences to overrides, recovers deleted occurrences as
  EXDATEs by diffing expansion against what EventKit returned, and degrades
  unmappable recurrences to windowed one-offs. Only the fetched window is
  reconciled: EXDATEs and overrides outside it survive a re-import, and a
  series that became a one-off drops its rule, EXDATEs, and overrides
  (`CalendarRepository.clearRecurrence`). Needs the calendars entitlement
  + `NSCalendarsFullAccessUsageDescription` (an `INFOPLIST_KEY_*` build
  setting; Info.plist is generated).
- `ICSSerializer` / `ICSParser`: in-house minimal RFC 5545 (VEVENT + VTODO
  subsets — VTODO serves the Reminders subsystem — folding/escaping,
  tolerant parse; mixed-component files work). All VEVENT usage funnels
  through `ICSTransfer.swift` (VTODO through the Reminders subsystem's
  `ICSTodoTransfer.swift`) so the backend is swappable. All-day values
  serialize as `VALUE=DATE` civil dates (DTSTART/DTEND, EXDATE, and UNTIL as
  a DATE), and parse straight back to canonical `CivilDay` dates, so neither
  direction depends on the device's zone. Stray DATE-TIME EXDATEs or
  RECURRENCE-IDs on an all-day event map to the day they fall on in their
  own zone. `RECURRENCE-ID` VEVENTs
  import as detached override rows keyed `uid@detached@<original-start>`,
  masters first regardless of file order. Re-importing a master drops
  imported overrides the file no longer carries (unless it still EXDATEs
  them). Native rows export as `swiftclaw-<id>` and import back onto
  themselves (keeping their calendar), so re-importing your own export
  never duplicates. A repeating `…Z` start without TZID recurs in UTC.
- Imports run as one transaction (`performImport`): a failed save throws and
  the UI reports it instead of a count.
- First-enable onboarding (`Features/Calendar/Import/CalendarOnboardingSheet`)
  offers Apple import / .ics import / start fresh; everything re-runnable from
  Settings › Calendar.

## UI (`Features/Calendar/`)

`CalendarView` hosts the mode switcher (⌘1–4), navigation (⌘T today, ⌘⇧←/→),
natural-language quick entry (toolbar field → `CalendarQuickEntryService` →
prefilled editor), the calendars popover, and the onboarding hook. Month grid
(`Grid/CalendarMonthGridView`) shows real event titles with a "+N more"
popover; week/day (`Grid/CalendarTimelineView`) render frames precomputed by
the pure `CalendarTimelineLayoutEngine` and support drag-create/move/resize
(recurring masters and overlay events excluded — edits go through the
editor's explicit scope prompts). The editor sheet works off a
`CalendarEventDraft` value; Save is the only write, one
`performTransaction` — on a failed save it rolls back and the sheet stays
open with the draft. Deletes (context menus, the delete-scope prompt) and
drag-move/resize are throwing repository transactions too; `CalendarView`
reports a failure in one `actionFailureAlert` (`Shared/ActionFailureAlert.swift`)
and the rolled-back event snaps back. The timeline maps frames and gestures through
wall-clock time, so DST days line up with the 24 hour labels. When the opt-in
`settings.reminders.showInCalendar` toggle is on, due-dated reminders render
as chips in the month grid, all-day strip, and agenda — see
`docs/features/REMINDERS.md`.

## Alerts (`Services/Calendar/CalendarAlertScheduler.swift`)

- Event alarms become `UNCalendarNotificationTrigger` requests through
  `AppNotificationService`, the only scheduled posting path. All-day alarm
  offsets are wall-clock times on the civil day in the current zone ("-15 h"
  = 9:00 the day before), so they hold across DST and follow the device.
- The scheduler reconciles a rolling 7-day window by fire date. It expands
  occurrences 28 days further so long-lead alarms still book, then keeps the
  soonest requests.
- Request IDs include the event, fire date, and a content fingerprint, so title
  and all-day edits replace stale notifications.
- Calendar uses a 36-request budget while Reminder alerts are active and 48
  otherwise. This shares the 64-request system cap without reserving unused
  Reminder slots.
- Reconciliation runs after store saves (`.calendarStoreDidChange`), remote
  changes, settings changes, and every 12 hours. Disabling alerts clears booked
  requests; that reconcile pass, like `clearAllPendingAlerts()` (called when
  Calendar itself is disabled), first waits for in-flight posts, so an add
  still suspended in the notification center lands and is then removed. A
  pass that a newer one overtook while it was suspended stops before
  touching requests, so a quick off-then-on can't clear the re-enabled alerts.
  Scheduled posts re-check the feature toggle after their authorization
  lookup, so a disable mid-post books nothing.
- Taps route through `NotificationRoutingPayload.Kind.calendarEvent` to
  `AppRouter.showCalendar()`.

## Calendar Review (`Services/Calendar/Review/`, `CalendarWorkflowManager`)

The Inbox Review pattern: `CalendarWorkflowManager` owns the loop (interval
from Settings; 0 = manual only), `CalendarReviewService.runOnce()` builds a
`.standalone` prompt with a scoped `ToolRegistry` of `fetch_calendar_events`
+ `notify_user_about_events` (never on `ToolRegistry.shared`), and the model
decides whether to create a "Calendar review —" chat with a `.calendar`
review card (`Features/Chats/ReviewCards/CalendarReviewCardRenderer`).
Fetched events are stamped `lastReviewedAt` only after a successful pass,
and only if unchanged since the model fetched them.
Scheduled passes skip when nothing upcoming is new or modified since its
stamp; when a pass does run, unchanged reviewed events are marked
"previously reviewed" in the fetch payload so the model doesn't repeat
itself. Manual runs bypass all suppression.

## Overlay (`Services/Calendar/Overlay/CalendarOverlayProvider.swift`)

Settings-toggled, display-only `EventOccurrence`s read live from EventKit
(`source: .appleOverlay`), merged into the visible window. Nothing is stored;
overlay events can't be edited, deleted, or dragged.

## Remaining work

- **Live CloudKit sync pass** (blocked on a paid developer account): restore
  the entitlements per the recipe in `SwiftClaw/SwiftClaw.entitlements`,
  provision the container in CloudKit Console, then verify two-device event
  sync end to end — including that `CalendarSyncCoordinator`'s post-merge
  dedupe collapses the duplicate rows a first sync can create, and that
  `CalendarAlertScheduler` reconciles alerts on remote-change notifications.
  Everything is code-complete but has only ever run against the local
  fallback store.

## Testing

`SwiftClawTests/Calendar/` — recurrence goldens (DST, leap day, BYSETPOS,
COUNT/UNTIL, EXDATE), civil-date zone changes and migration
(`CivilDateTests`, shared with Reminders), repository CRUD + dedup, layout-engine packing, month
math, ICS round-trips (incl. Google-flavored fixtures), EventKit mapping,
alert-scheduler reconciliation against the notification spy, review
service/tool seams, and quick-entry parsing. Run with
`-only-testing:SwiftClawTests/<Suite>`.
