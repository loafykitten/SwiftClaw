# Calendar

SwiftClaw's own calendar: SwiftData-backed events with month/week/day/agenda
views, Apple Calendar + .ics import, .ics export, scheduled event alerts, an
AI Calendar Review mirroring the Inbox Review, and an optional read-only
Apple Calendar overlay. Mirrors the Email subsystem's architecture throughout
— when in doubt, the Email counterpart is the template.

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
- `Services/Calendar/Repository/CalendarRepository.swift` is the single
  mutation boundary and the identity authority (deterministic lookups,
  `dedupeAfterRemoteMerge()` for CloudKit-merge duplicates).

## CloudKit sync (dormant)

`SwiftClawModelContainerFactory` prefers a CloudKit-backed calendar
configuration but only when the process is actually signed with
`com.apple.developer.icloud-services` (checked via `SecTask` — CloudKit
*traps* rather than throws without it). Personal development teams cannot
carry iCloud entitlements, so sync is currently dormant; the re-enable recipe
lives in a comment in `SwiftClaw/SwiftClaw.entitlements`. The local fallback
opens the same store, so nothing is lost either way.
`Services/Calendar/CalendarSyncCoordinator.swift` runs a debounced dedupe
pass on remote-change notifications once sync is live.

## Import / export (`Services/Calendar/Import`, `Services/Calendar/ICS`)

- `AppleCalendarImporter` + `EventKitMapping`: re-runnable EventKit import —
  upserts by `calendarItemExternalIdentifier`, reconstructs recurring masters,
  maps detached occurrences to overrides, recovers deleted occurrences as
  EXDATEs by diffing expansion against what EventKit returned, and degrades
  unmappable recurrences to windowed one-offs. Needs the calendars entitlement
  + `NSCalendarsFullAccessUsageDescription` (an `INFOPLIST_KEY_*` build
  setting; Info.plist is generated).
- `ICSSerializer` / `ICSParser`: in-house minimal RFC 5545 (VEVENT subset,
  folding/escaping, tolerant parse). All usage funnels through
  `ICSTransfer.swift` so the backend is swappable. All-day values serialize as
  floating local dates (`VALUE=DATE`, including EXDATEs — never UTC, which
  would shift the date in non-UTC zones); `RECURRENCE-ID` VEVENTs import as
  detached override rows keyed `uid@detached@<original-start>`, masters first
  regardless of file order.
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
`CalendarEventDraft` value; Save is the only write.

## Alerts (`Services/Calendar/CalendarAlertScheduler.swift`)

Event alarms become `UNCalendarNotificationTrigger` requests through
`AppNotificationService` (the service's only scheduled posting path).
The scheduler reconciles a rolling 7-day window **by fire date** (occurrences
are expanded a further 28 days out so long-lead alarms still book;
deterministic identifiers, soonest-first under a 48-request budget) on every
store save (`.calendarStoreDidChange`), remote change, and a 12 h tick.
Disabling the notification toggle empties the desired set, so the next
reconcile *clears* already-booked requests (`settingsDidChange()` triggers one
promptly); disabling the Calendar feature calls `clearAllPendingAlerts()`.
Taps route via `NotificationRoutingPayload.Kind.calendarEvent` →
`AppRouter.showCalendar()`.

## Calendar Review (`Services/Calendar/Review/`, `CalendarWorkflowManager`)

The Inbox Review pattern: `CalendarWorkflowManager` owns the loop (interval
from Settings; 0 = manual only), `CalendarReviewService.runOnce()` builds a
`.standalone` prompt with a scoped `ToolRegistry` of `fetch_calendar_events`
+ `notify_user_about_events` (never on `ToolRegistry.shared`), and the model
decides whether to create a "Calendar review —" chat with a `.calendar`
review card (`Features/Chats/ReviewCards/CalendarReviewCardRenderer`).
Fetched events are stamped `lastReviewedAt` only after a successful pass.
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
COUNT/UNTIL, EXDATE), repository CRUD + dedup, layout-engine packing, month
math, ICS round-trips (incl. Google-flavored fixtures), EventKit mapping,
alert-scheduler reconciliation against the notification spy, review
service/tool seams, and quick-entry parsing. Run with
`-only-testing:SwiftClawTests/<Suite>`.
