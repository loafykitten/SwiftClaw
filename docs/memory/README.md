# Working-task memory

This directory holds in-flight task state so work survives an agent switch,
a cleared session, or a context-window summary. It is scratch state, not
documentation — durable knowledge belongs in `docs/architecture`,
`docs/conventions`, or `docs/features`.

## Convention

- One file per active task: `<task-slug>.md` (e.g. `calendar-cloudkit-sync.md`).
- Create the file when starting a task that won't finish in one sitting, or
  when asked to hand off. Update it as the task progresses — a stale memory
  file is worse than none.
- Delete the file when the task ships (include the deletion in the final
  commit). Anything worth keeping longer than the task should be promoted
  into the real docs first.

## File format

```markdown
# <Task title>

**Started:** <date>  **Status:** in progress | blocked | ready for review

## Goal
What "done" looks like, in a sentence or two.

## Current state
What has been built/changed so far, and whether it builds & passes tests.

## Next steps
Ordered, concrete. The first item should be actionable with no other context.

## Decisions & constraints
Choices already made (and why) so they aren't re-litigated. User instructions
that aren't obvious from the diff.

## Files touched
Paths, with a word on what changed in each.
```

Sections may be omitted when empty, but **Goal** and **Next steps** are the
minimum for a useful handoff.
