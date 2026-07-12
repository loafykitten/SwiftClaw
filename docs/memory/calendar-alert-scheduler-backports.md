# CalendarAlertScheduler: back-port the phase-4 reminder-scheduler fixes

**Started:** 2026-07-11  **Status:** not started (queued behind the Reminders feature)

## Goal

Port two fixes from `ReminderAlertScheduler` (commit `18a1e77`) back to
`CalendarAlertScheduler`, which has the same latent bugs. Found during the
Reminders phase-4 codex review (gpt-5.6-sol); deliberately not fixed then to
keep the phase scoped.

## The bugs

1. **Stale content on edit.** Alert identifiers encode only
   `(eventID, fireDate)` and `reconcile()` diffs identifiers alone, so
   retitling an event never replaces an already-booked notification — the
   banner fires with the old title. Reminder fix: fold a stable SHA256
   content fingerprint into the identifier
   (`NotificationIdentifier.reminderAlert(reminderID:fireDate:contentFingerprint:)`
   + `ReminderAlertScheduler.contentFingerprint(title:hasDueTime:)`). Must be
   stable across launches — `String.hashValue` is process-seeded and would
   rebook everything on relaunch. Regression test:
   `editingTheTitleRebooksTheAlertWithFreshContent`.
2. **Disable→enable clear race.** `clearAllPendingAlerts()` is fire-and-forget
   (`CalendarAlertScheduler.swift` ~line 102): it reads booked identifiers and
   removes them in a detached Task. Toggling the Calendar feature off then
   quickly on lets the next `reconcile()` read the still-booked identifiers,
   skip rebooking them, and then the straggling clear deletes them — alerts
   stay unbooked until the next store change or 12h tick. Reminder fix: store
   the clear as `pendingClear` and `await` it at the top of `reconcile()`.
   Regression test: `reconcileAfterClearAllRebooksPromptly`.

## Next steps

1. Mirror both fixes in `SwiftClaw/Services/Calendar/CalendarAlertScheduler.swift`
   (fingerprint over title + isAllDay; alarm offsets are already in the fire
   date). Extend `NotificationIdentifier.calendarAlert(eventID:fireDate:)`
   with a `contentFingerprint` parameter to match the reminder shape.
2. Add the two regression tests to `CalendarAlertSchedulerTests`, adapted from
   `ReminderAlertSchedulerTests`.
3. Delete this file in that commit.

## Decisions & constraints

- Keep the two schedulers structural clones — that symmetry is why the review
  findings mapped 1:1; don't let them drift further.
- Low urgency: both bugs are narrow (stale banner text; a timing window on a
  rare toggle sequence). Fine to land after the Reminders feature ships.
