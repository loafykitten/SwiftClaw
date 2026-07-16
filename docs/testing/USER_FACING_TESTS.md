# User-Facing Test Catalog

This is the living catalog of user-facing behavior worth testing by hand. It is
organized first by who should run a check, then by feature.

- **Human testing** is for AI quality, subjective presentation, real accounts,
  OS permission and notification behavior, external-app interoperability, and
  destructive server-side effects.
- **Computer Use testing** is for deterministic UI, navigation, CRUD, local
  persistence, rendering, and routing. A prepared fixture profile may be used.
- This is an inventory, not a test-run report. Do not record pass/fail state here.
- Only read or update this file at the end of a feature or phase. Add a new stable
  ID for new behavior, update affected entries when behavior changes, and remove
  an entry only when the behavior is intentionally removed.
- Keep secrets, personal mail, and production calendars out of automation
  fixtures. Human tests that use external systems should use disposable data.

SwiftClaw supports macOS and iOS. A step that names a platform applies only to
that platform; otherwise cover both where the behavior exists on both.

## Human Testing

### App Shell and Cross-Feature Flows

- **H-SHELL-001 — First-run notification offer.** With notification state reset,
  launch the app and judge the splash timing, delayed offer, Allow/Not Now flow,
  and relaunch behavior. The OS prompt must appear only after consent, and
  Settings must remain a recovery path.
- **H-SHELL-002 — Real notification delivery and routing.** With each source
  enabled in turn, generate new mail, review results, a background chat reply, a
  Calendar alert, and a Reminder alert. Each notification must be useful and its
  tap must open the exact destination. No notification should appear while that
  destination is already visible. *(Requires OS permission and live/seeded data.)*
- **H-SHELL-003 — Notification denial recovery.** Deny permission in macOS,
  confirm the in-app warning is understandable, use Open System Settings, grant
  permission, and return. The status must refresh without relaunching.
- **H-SHELL-004 — Accessibility pass.** Use keyboard-only navigation and
  VoiceOver across the main window, Settings, composer, destructive dialogs,
  review cards, and feature editors. Focus order, names, values, and disabled
  reasons must be clear.
- **H-SHELL-005 — Startup failure presentation.** Using a safe debug fault
  injection, force model-container creation to fail. The recovery screen must
  explain the problem and recovery options without risking real data. *(Defer
  until a safe fault-injection mode exists.)*

### Home

- **H-HOME-001 — Personalized greeting quality.** At different times and weather
  conditions, confirm the generated greeting is brief, natural, varied, and uses
  time/daylight/weather only when relevant. It should end with the preferred
  persona name. *(Requires Swift Model, location, and network.)*
- **H-HOME-002 — Greeting fallback quality.** Repeat with location denied,
  network offline, and no Swift Model. The fallback must appear quickly and must
  not mention missing context or expose an error.
- **H-HOME-003 — Home blurb quality.** Confirm the generated secondary line is
  short, cozy or witty, and free of quotes, emoji, or explanations. Failure must
  leave a stable layout without error noise. *(Requires Swift Model.)*
- **H-HOME-004 — First-message result.** Submit from Home and judge the answer,
  selected model, persona, and image understanding. The new conversation should
  preserve the original prompt and attachments. *(Requires configured models;
  use a vision model for the image case.)*

### Chats and Composer

- **H-CHAT-001 — Multi-turn continuity and persona.** Hold a repeatable multi-turn
  conversation. The assistant must use prior context, the selected model, and
  current Persona/Personality settings without exposing system instructions.
- **H-CHAT-002 — Reasoning behavior.** Compare Off and supported reasoning
  efforts on the same prompt. Both must complete, effort should visibly improve
  the appropriate task, and raw private reasoning must never be shown.
- **H-CHAT-003 — Investigation quality.** Ask a current research question with
  Investigation enabled. Progress text should make sense, claims should be
  supported by working citation links, and the Sources section should be
  complete. *(Requires Brave Search and a reasoning/tool-capable model.)*
- **H-CHAT-004 — Vision conversation.** Send one and several images, then ask a
  follow-up. The assistant must use the correct images, preserve context across
  turns, and render them after relaunch. *(Requires a vision model.)*
- **H-CHAT-005 — Generated titles.** Initial and regenerated titles must be
  concise, representative, single-line, and unquoted. Regeneration should use
  both the opening and recent messages.
- **H-CHAT-006 — Background reply notification.** Leave a slow chat before it
  finishes. Confirm the notification preview is safe and useful and opens the
  exact chat. No notification should be posted while viewing that chat.
- **H-CHAT-007 — Appearance judgment.** Across Light and Dark themes, judge chat
  density, bubble balance, avatars, markdown hierarchy, quote accent readability,
  hover states, and minimum-window layout.

### Workspace

- **H-WORK-001 — Dashboard usefulness.** With realistic mail, events, and
  reminders, judge whether the widget summaries surface the right information
  at a glance and remain readable at common window sizes.
- **H-WORK-002 — Cross-feature routing.** Open review cards and real
  notifications for old email, Calendar, and Reminders. Confirm the resulting
  Workspace destination is the item a person would expect, including mail older
  than the initial message window.

### Email

- **H-MAIL-001 — Account lifecycle.** Add a disposable IMAP/SMTP account, test
  unsaved credentials, save, relaunch, edit connection details, retest, and
  delete. Secrets must persist in Keychain while configured and be removed on
  account deletion; already-synced local mail should remain.
- **H-MAIL-002 — Live first and incremental sync.** Run first sync, receive new
  mail, and sync again. Status and last-sync text must be honest, the first-sync
  cap must not block later mail, and incremental sync must avoid duplicates.
- **H-MAIL-003 — IMAP reconciliation.** In another client, change read/flag
  state, delete, archive, and move messages. SwiftClaw must settle to the server
  state without losing notes or thread identity.
- **H-MAIL-004 — Connection reuse.** Toggle a flag while a long sync is running,
  leave the app idle past the session timeout, then sync again. Interactive
  actions must remain responsive and reconnect cleanly. *(Explicit live gap.)*
- **H-MAIL-005 — Folder discovery.** With populated standard, custom, and nested
  folders, confirm single-account contents are plausible, Gmail All Mail is not
  misclassified, Review Folders lists real choices, and multi-account unified
  scope hides interleaved custom folders. *(Explicit live gap.)*
- **H-MAIL-006 — Message rendering.** Inspect plain text, Unicode, long mail,
  malformed and newsletter HTML, remote images, links, and attachments. Content
  must remain readable, safe, and usable without broken layout.
- **H-MAIL-007 — Server-side actions.** Mark read, flag, archive, delete to Trash,
  permanently delete from Trash, and add a local note. Verify both SwiftClaw and
  another mail client, including recovery before permanent deletion.
- **H-MAIL-008 — Reply end to end.** Reply between two disposable mailboxes.
  Recipient threading and headers must be correct, Sent APPEND must succeed, and
  the immediate local sent row must reconcile to the server UID without a
  duplicate. *(Explicit live gap.)*
- **H-MAIL-009 — Review judgment.** Run Review Now on a controlled inbox and
  judge selection, summaries, suggested actions, persona, and restraint. A large
  unread backlog must not create an unusable prompt.
- **H-MAIL-010 — Review scope.** Vary read/unread/flagged/notated, age, maximum
  count, Archive/Trash, and custom-folder settings. Inbox must remain included
  and the result must match the chosen scope.
- **H-MAIL-011 — Review actions.** From a review card, Review, Flag, Archive, and
  Delete. Local and server state must agree. The current suggested Reply action
  is expected to mark read and flag rather than open a composer.
- **H-MAIL-012 — Conversational review follow-up.** Ask an Inbox Review chat
  about shown mail, older mail, and an explicit folder/status. It must fetch the
  relevant messages, distinguish uncertainty, and avoid hallucinating content.
- **H-MAIL-013 — Scheduled review behavior.** Exercise manual-only, interval,
  and daily schedules with auto-navigation both on and off. Prior unread review
  results should suppress duplicates, and background notifications/badges should
  match the setting.

### Calendar

- **H-CAL-001 — Natural-language quick entry.** Try timed, all-day, duration,
  calendar, recurrence, alert, and ambiguous phrases. The editor should be
  sensibly prefilled, preserve the phrase on failure, and never save before
  confirmation. *(Requires a model.)*
- **H-CAL-002 — Apple Calendar import.** Test denied and allowed permission,
  selected calendars, all-day events, recurrence, detached/deleted occurrences,
  and re-import. Mapping must be accurate and reruns must update rather than
  duplicate.
- **H-CAL-003 — ICS interoperability.** Import Apple/Google fixtures with
  all-day dates, time zones, recurrence, EXDATE, detached instances, Unicode,
  and folded lines. Export and open externally; dates and series must survive.
- **H-CAL-004 — Apple Calendar overlay.** Compare the read-only overlay with
  Apple Calendar, change an event externally, and confirm it refreshes. Overlay
  events must never become editable or stored SwiftClaw events.
- **H-CAL-005 — Event alerts.** Schedule near-future timed/all-day and lead-time
  alerts. Delivery text/time and tap routing must be correct; edits, deletes,
  source toggles, and feature disable must rebook or clear them. A retitled
  event's alert must show the new title, and disabling the feature then quickly
  re-enabling it must still rebook.
- **H-CAL-007 — AI review quality.** With conflicts, changed events, and prep
  opportunities, judge manual/scheduled analysis, restraint, summaries, and
  suppression. Manual refresh must bypass scheduled suppression.
- **H-CAL-008 — Scheduled AI loop.** Exercise manual-only, 6-hour, 12-hour, and
  daily settings. Unchanged events and unread prior results should suppress
  duplicates; useful results should route and notify correctly.
- **H-CAL-009 — CloudKit sync.** Verify two-device sync, post-merge dedupe, and
  remote alert reconciliation only after paid-team entitlements are restored.
  This test is currently blocked, not a release failure.

### Reminders

- **H-REM-001 — Natural-language quick entry.** Try undated, date-only, timed,
  list, priority, flag, notes, and both repeat styles. Unmatched lists and invalid
  repeat-without-due input must degrade safely, with confirmation before save.
- **H-REM-002 — Apple Reminders import.** Test permission states, list selection,
  completed/date/time/priority/fixed recurrence mapping, and re-import without
  duplicates. Confirm the known omission of Apple subtasks is communicated.
- **H-REM-003 — VTODO interoperability.** Round-trip standard fields with another
  task app and SwiftClaw-specific flags, checklists, and after-completion repeats
  with a second SwiftClaw profile. Mixed VEVENT/VTODO files must not cross-import.
- **H-REM-004 — Reminder alerts.** Verify timed and date-only delivery, selected
  wall-clock time across a DST-adjacent date, edit rebooking, completion/delete
  clearing, feature/source toggles, and tap routing to the exact reminder. A
  hidden-list reminder's tap opens its editor directly; tapping a delivered
  banner after the feature is disabled must do nothing (no stuck navigation).
- **H-REM-005 — AI review quality.** With undated, overdue, and next-seven-day
  work, judge prioritization, restraint, summaries, and the no-result case.
  Failures must retry; manual runs must bypass suppression.
- **H-REM-006 — Scheduled AI loop.** Exercise manual-only, 6-hour, 12-hour, and
  daily settings. Prior unread review, no pending work, and unchanged work should
  suppress a scheduled pass; meaningful changes should produce a result.
- **H-REM-007 — Recurrence semantics.** Use real-world fixed-schedule and
  after-completion tasks. Early completion, late completion, skip, undo, COUNT
  exhaustion, and history should match the language shown to the user.

### Notes

- **H-NOTE-001 — External vault interoperability.** Connect a disposable folder
  containing Markdown notes and Obsidian metadata. Add, edit, rename, and remove
  notes from another editor. SwiftClaw must reconcile the visible catalog while
  leaving dotfiles, `.obsidian/`, non-Markdown files, and symlinks untouched.
- **H-NOTE-002 — Concurrent-edit safety.** Edit the same note in SwiftClaw and an
  external editor. The non-modal choice must explain Keep Mine and Take Theirs.
  Keep Mine must preserve the external version and create exactly one clearly
  surfaced conflict copy containing the SwiftClaw edits; Take Theirs must discard
  the local buffer without creating a copy. If the file is deleted externally
  while SwiftClaw has unsaved text, that text must remain visible and the deleted
  path must not be silently recreated.
- **H-NOTE-003 — External-vault permission recovery.** Disconnect or revoke access
  while a note has unsaved edits, then restore access. The editor must keep the
  text readable and selected, explain the save failure, and save successfully on
  retry without requiring a relaunch.
- **H-NOTE-004 — Hybrid search quality.** Search exact terms, punctuation-heavy
  text, headings, and paraphrases across a representative vault. Results must
  open the right note, show useful heading/snippet context, and remain useful
  with embeddings disabled or unavailable.
- **H-NOTE-005 — Link graph and backlinks.** Exercise direct, aliased, heading,
  unresolved, and code-fenced wikilinks. Backlinks and broken-link reporting must
  follow Obsidian-style resolution without treating fenced examples as links.
- **H-NOTE-006 — Quick switcher ranking.** Use Command-O with exact, prefix,
  subsequence, path, and no-match queries. Ranking and highlighted matches should
  feel predictable, and choosing a result must select that note.
- **H-NOTE-007 — Vault health and rebuild.** Create broken links and conflict
  copies, toggle embeddings, and rebuild the index. Banner and Settings details
  must agree, explain degraded search clearly, and recover after a rebuild.
- **H-NOTE-008 — AI read tools end to end.** With a disposable configured vault,
  ask a real chat what the notes say about a distinctive topic. The answer must
  use Search Notes and Read Note as needed, cite the correct relative note and
  heading, preserve verbatim content when requested, and clearly disclose any
  truncation. Disable Notes and confirm neither tool remains available to chat.
- **H-NOTE-009 — AI note proposal quality and safety.** With a disposable vault
  and configured model, ask for a note edit and a new note. The assistant should
  summarize the intended change clearly and produce a focused proposal instead
  of changing files immediately. Approve one proposal, reject another, and alter
  a target externally before approval; only the approved unchanged target may be
  written, while the stale proposal must explain that it was not applied.
- **H-NOTE-010 — Notes review judgment.** With a representative disposable
  vault, run manual and scheduled Notes reviews through a configured model.
  Selection and summaries must stay restrained and read-only while usefully
  surfacing unchecked daily-note work, conflict copies, broken links, recent
  notes that need follow-up, and degraded index health.
- **H-NOTE-011 — Scale and large-note usability.** Generate 5,000 varied notes
  in an owned temporary vault and confirm initial indexing finishes within 30
  seconds on the supported test Mac. Exact, middle/late-corpus, and no-result
  searches should remain responsive. Open and edit a 1 MiB Markdown note;
  typing, selection, autosave, and VoiceOver must remain usable even when syntax
  styling is capped, with no source changes beyond what was typed.
- **H-NOTE-012 — Revision recovery safety.** Edit a note through several saved
  versions, understand the timestamps/previews in Revisions, and restore an old
  version. The current note must remain byte-for-byte unchanged; the old content
  must appear in one clearly named sibling conflict copy that can be compared
  and merged manually.

### Settings

- **H-SET-001 — Theme quality and propagation.** Judge System/Light/Dark and
  quote-accent contrast in both windows. System must follow a live macOS
  appearance change, and Reset must restore a readable default.
- **H-SET-002 — Persona end to end.** Confirm detected and overridden name/avatar
  look right on Home and in chats. A valid replacement, reset, and invalid image
  error must all be understandable.
- **H-SET-003 — Assistant personality end to end.** Compare Focused, Clear, Deep,
  Playful, Warm, and a custom prompt using the same real request. Preview and
  response should match the choice; whitespace-only custom input must be safe.
- **H-SET-004 — Provider integrations.** For each provider Ember uses, verify
  credential persistence/rotation, model discovery, a real completion, reasoning
  behavior, and removal. Use disposable keys where possible.
- **H-SET-005 — Brave Search configuration.** Confirm Ready/Needs Setup state,
  a real cited search, Investigation dependency, and expected behavior at the
  configured request rate. *(Requires a Brave key.)*
- **H-SET-006 — Settings layout quality.** At minimum and common window sizes,
  judge sidebar, forms, provider disclosures, long personality prompts, and
  Back/Forward controls for clipping and usability.

## Computer Use Testing

### App Shell and Cross-Feature Flows

- **CU-SHELL-001 — Launch shell.** Launch and relaunch. The splash should appear
  and fade cleanly into a usable Home screen without a flash of broken content.
- **CU-SHELL-002 — Main navigation history.** Visit Home, Chats, Workspace, and
  Deep Research. Toolbar Back/Forward and Command-[ / Command-] must follow
  history; a new branch clears Forward.
- **CU-SHELL-003 — Sidebar badges.** Seed unread chat replies and unread active
  email. Chats and Workspace badges and the Dock count must agree with visible
  state and update after viewing, archive, or delete.
- **CU-SHELL-004 — Feature gating.** Disable and re-enable Email, Calendar,
  Reminders, and Notes. Workspace widgets and feature-backed Settings sections
  must update immediately, and hidden destinations must be pruned from selection
  and navigation history.
- **CU-SHELL-005 — Placeholder features.** Deep Research and Memory must
  show intentional Coming Soon states with correct titles rather than blank or
  interactive-looking unfinished UI.
- **CU-SHELL-006 — Theme persistence.** Change theme/accent, open both windows,
  relaunch, and confirm appearance remains consistent.

### Home

- **CU-HOME-001 — Layout and resizing.** Verify mascot, title, greeting, blurb,
  and bottom composer at normal/minimum widths while generated text loads. There
  must be no clipping, overlap, or layout jump.
- **CU-HOME-002 — Persona deep link.** Click the highlighted persona name in the
  greeting. Settings must open directly to Persona; changing the name must update
  the highlight/greeting.
- **CU-HOME-003 — Home-to-chat transition.** Send once. Exactly one persisted
  chat must be created and selected, the user message/attachments must appear,
  generation must start, and the draft must clear only after persistence succeeds.
- **CU-HOME-004 — Immediate title.** Before title generation finishes, use the
  first input line, trimmed to 60 characters with an ellipsis. The generated
  update must not switch or lose the open chat.
- **CU-HOME-005 — Creation failure.** With safe fault injection, fail attachment
  finalization or save. Show a useful alert, keep the draft, stop busy state, and
  leave no orphan chat/image.

### Chats List

- **CU-CHAT-001 — History rows and order.** Seed mixed dates, pins, models,
  unread, and generating state. Rows must show the right metadata; pinned chats
  sort above unpinned and each group sorts newest visible message first.
- **CU-CHAT-002 — Stable selection.** Filtering, insertion, sync, or deletion
  must not jump away from a still-valid selection. Archiving the current chat
  should intentionally return to list-only rather than auto-select another.
- **CU-CHAT-003 — New chat.** Create a blank New Chat using the Swift Model,
  persist it immediately, and send its first message. A forced save failure must
  show an alert without a phantom row.
- **CU-CHAT-004 — Search.** Match title, model, and visible message body with
  case/diacritic-insensitive, whitespace-token AND behavior. Clear restores the
  list; no match shows the search empty state.
- **CU-CHAT-005 — Active/Archived filter.** Switching filters must clear search,
  reset stale selection/path, and show the correct distinct empty state.
- **CU-CHAT-006 — Pin and unpin.** Row actions must be discoverable. Pin moves an
  active chat into the pinned group; unpin restores date order; archived chats
  cannot remain pinned.
- **CU-CHAT-007 — Archive and unarchive.** Archive removes pin/unread and the
  composer, and places the chat in Archived. Unarchive selects it in Active and
  leaves it unpinned.
- **CU-CHAT-008 — Delete confirmation.** First delete action must ask for
  confirmation. Cancel preserves; Delete removes chat, stored images, unread
  state, and generation, then chooses a sensible fallback. Cover Active and
  Archived.
- **CU-CHAT-009 — Unread lifecycle.** Finish a reply while elsewhere, relaunch,
  and verify row/sidebar/Dock unread state persists. Opening that exact chat,
  archiving, or deleting must clear it and its delivered notification.
- **CU-CHAT-010 — Empty states and toolbar.** No Chats Yet, No Archived Chats,
  No Chat Selected, search-empty, New Chat, and Active/Archived controls must
  appear in the correct pane with useful labels/help.

### Individual Chat

- **CU-CHAT-011 — Transcript layout.** Verify alignment, avatars, accent, local
  timestamps, selectable content, and user-avatar deep link. Messages must remain
  chronological, including equal timestamps.
- **CU-CHAT-012 — Date separators.** Seed a multi-day transcript. Separators must
  occur only at day boundaries and expose an accessible full date.
- **CU-CHAT-013 — Markdown.** Cover H1–H3, paragraphs, bold, italic, inline code,
  block quotes, markdown/bare links, citation links, long wrapping, text
  selection, and click/cursor behavior in Light and Dark themes.
- **CU-CHAT-014 — Generation lifecycle.** Send once and verify one user message,
  disabled duplicate controls, header/list spinner, autoscroll, progress/tool
  status, and replacement by one assistant response.
- **CU-CHAT-015 — Error recovery.** Force a provider failure. End the spinner,
  show a clear error bubble, preserve history/draft rules, and allow another send
  that clears the stale error.
- **CU-CHAT-016 — Per-chat reasoning.** Set different efforts in two chats,
  switch between them, and relaunch. Each chat must retain its own setting.
- **CU-CHAT-017 — Model capability transitions.** Switch model between turns.
  Header/row must update and reasoning, attachment, and Investigation controls
  must immediately reflect the new capabilities.
- **CU-CHAT-018 — Rename.** Save/Return commits a trimmed nonblank title;
  Escape/Cancel restores it. Conflicting menu actions must be disabled while
  editing or generating.
- **CU-CHAT-019 — Regenerate title.** Show progress and block duplicate starts.
  Disable during generation and omit for Inbox Review chats, whose title prefix
  controls review tools.
- **CU-CHAT-020 — Detail archive actions.** Archive must close active detail and
  remove composer. Archived detail must offer Unarchive without compose or title
  regeneration.
- **CU-CHAT-021 — Sent-image viewer.** Verify fanned stack/count, chosen image,
  Left/Right wraparound, arrows, Escape/X/backdrop close, and Image unavailable
  fallback.
- **CU-CHAT-022 — Task cancellation.** Navigate away or delete while generation
  or title work runs. Late completion must not update a disappeared or different
  chat.

### Shared Chat Composer

- **CU-COMP-001 — No-model state.** With no available models, show `(N/A)` and
  disable input, model, reasoning, attachments, Investigation, and Send without
  creating an empty chat.
- **CU-COMP-002 — Model menu and fallback.** Show Swift/Claw shortcuts only when
  valid, list raw models, mark selection, and fall back to Swift then first
  available when the selected model disappears.
- **CU-COMP-003 — Capability controls.** Reasoning appears only for supported
  models; attachments require vision; Investigation requires enabled/configured
  Web Search, Investigation, Tools, reasoning capability, and effort above Off.
  Disabled help must say why.
- **CU-COMP-004 — Reasoning defaults.** Model changes apply configured defaults;
  unsupported models hide effort. Home uses the global default while existing
  chats keep their own value.
- **CU-COMP-005 — Investigation one-shot.** A successful send consumes and clears
  the toggle. Incompatible model/effort/settings changes must clear it immediately.
- **CU-COMP-006 — Keyboard input.** Field grows from one to three lines, Return
  sends, Shift-Return inserts a newline, whitespace cannot send, and busy state
  blocks duplicates.
- **CU-COMP-007 — Draft retention.** Failed submission keeps text and attachments
  and rolls back finalized files. Only successful submission clears them.
- **CU-COMP-008 — Image picker.** Import multiple supported images, preview and
  remove independently, and show useful errors at 10 images, 10 MB per image,
  100 MB total, invalid input, and normalization above 4096 px.
- **CU-COMP-009 — Image paste.** Command-V with an image adds an attachment;
  normal copied text still pastes as text with no junk payload.
- **CU-COMP-010 — Image drag/drop.** Eligible drag shows the dashed overlay and
  imports. Unsupported drops preserve the draft. The overlay must never block
  ordinary click, drag, or text selection.
- **CU-COMP-011 — Capability cleanup.** Attach images under a vision model, then
  switch to non-vision or disable the capability. Thumbnails and temporary draft
  files must clear and cannot be sent accidentally.
- **CU-COMP-012 — Preview and disposal.** Preview navigation/close must not alter
  the draft. Closing/navigating away must discard temporary images; reopening is clean.
- **CU-COMP-013 — Focus, hover, and accessibility.** Background/scroll dismissal,
  composer sizing, tooltips, accessible names/values, selection traits, hover,
  disabled state, and pointing-hand cursors must behave without getting stuck.

### Workspace and Widgets

- **CU-WORK-001 — Grid and feature navigation.** Enabled Email, Calendar,
  Reminders, and Notes tiles appear with Memory in an adaptive readable grid.
  Each tile opens its feature.
- **CU-WORK-002 — Disabled feature affordance.** Disabled features move to More
  Features. Selecting one opens Settings > Tools with the correct row centered
  and highlighted; re-enabling restores the tile.
- **CU-WORK-003 — Email tile.** Account count and Unread message, Inbox thread,
  Flagged thread, and Notated thread counts must be distinct and update after
  read/flag/note/archive/delete. Review footer must update without new mail.
- **CU-WORK-004 — Calendar tile.** Verify Today, Tomorrow, This Week, next timed
  event, happening-now, and Nothing scheduled this week around day/week boundaries.
- **CU-WORK-005 — Reminders tile.** Verify Today including overdue, Overdue,
  This Week, Flagged, next timed deadline, fallback text, mutation updates, and
  minute-boundary refresh.
- **CU-WORK-006 — Deep links.** Route prepared email/review/calendar/reminder IDs
  into the correct feature and item, including old mail beyond the first window
  and reminder list selection (a hidden-list reminder opens its editor directly).
- **CU-WORK-007 — Notes tile and capture.** The Notes tile must show live note
  count, Captured Today, and health without clipping on macOS or compact iOS.
  Its Quick Capture action must append through the configured vault and update
  both counts immediately without navigating first.

### Email

- **CU-MAIL-001 — Empty and setup states.** With no account, direct the user to
  Email Settings. With an empty configured account or empty Flagged mailbox,
  preserve navigation and show useful content-level empty states.
- **CU-MAIL-002 — Layout navigation.** At regular width, show mailbox/thread/detail
  panes with correct selection. Resize through supported macOS widths and verify
  titles, back behavior, and no stranded detail.
- **CU-MAIL-003 — Account scope.** With two fixture accounts, show All Accounts,
  filter every mailbox, display account badges only when useful, fall back after
  account removal, and switch account when targeting its custom folder.
- **CU-MAIL-004 — Mailbox partitioning.** Inbox, Flagged, Sent, Drafts, Junk,
  Archive, Trash, and custom folders must show the right threads. Empty secondary
  boxes hide as designed; archive/delete updates immediately.
- **CU-MAIL-005 — Thread rows.** Verify stripped sender names, subject, snippet,
  date, unread count, account badge, and stable selected thread after sync/rethread.
- **CU-MAIL-006 — Search and windowing.** Search sender/subject/body within current
  mailbox/account. Older mail must remain absent until Show Older Messages grows
  the 1000-row window; thread detail still shows all messages.
- **CU-MAIL-007 — Swipe action.** Exercise Review, Flag, Archive, and Delete
  configuration. Horizontal drag must not break vertical scroll/taps, and each
  action/confirmation must update the list correctly.
- **CU-MAIL-008 — Thread detail.** Render headers, participants, ordered messages,
  plain/HTML bodies, dates, note marker, attachment metadata, unavailable state,
  and local read transition.
- **CU-MAIL-009 — Local thread actions.** Add/edit note, flag, archive, delete,
  and permanently delete from Trash. UI, mailboxes, widget counts, and selection
  must update; server truth remains a Human test.
- **CU-MAIL-010 — Reply composer UI.** Reply must prefill recipient/subject,
  validate required content, cancel cleanly, block duplicate send, and show a
  useful send failure. Delivery remains a Human test.
- **CU-MAIL-011 — Pending old-email selection.** Route to an email older than the
  current window. The window must expand automatically and open the target.

### Email AI Review

- **CU-MAILAI-001 — Review card rendering.** Verify title, items, summary, sender,
  date, account badge, recommended-action badge, three-row clamp/scroll, and
  persisted all-clear state.
- **CU-MAILAI-002 — Review card routing.** Row/body/View must open the correct
  email and remove the acted item persistently.
- **CU-MAILAI-003 — Review card actions.** Context and configured swipe actions
  must offer the expected choices, confirm destructive work, disable duplicates,
  and remove completed rows. Server state remains a Human check.
- **CU-MAILAI-004 — Refresh.** Sparkle refresh must disable/spin during work and
  replace or clear analysis without creating duplicate cards.

### Calendar

- **CU-CAL-001 — Onboarding.** Reset first-open state and cover Apple import,
  ICS import, Start Fresh, Not Now, cancellation, and completion persistence.
- **CU-CAL-002 — View modes and navigation.** Exercise Month/Week/Day/Agenda,
  Today, previous/next, period titles, Command-1–4, Command-T, Command-Shift-arrow,
  and Command-N across month/year and DST boundaries.
- **CU-CAL-003 — Month grid.** Verify colors, titles, times, adjacent-month days,
  day creation, per-cell chip budget, and +N overflow with crowded mixed content.
- **CU-CAL-004 — Week/day timeline.** Verify overlap packing, all-day strip,
  scroll, drag-create, move, and resize. Recurring and overlay events must not be
  draggable, and vertical scrolling must not trigger edits.
- **CU-CAL-005 — Agenda.** Verify chronological 30-day grouping, all-day/timed
  labels, empty state, and Edit/Delete context actions.
- **CU-CAL-006 — Event editor.** Cover required title, default calendar, all-day
  and timed dates, duration preservation, end validation, location, URL, notes,
  alerts, Save-only writes, Cancel, and sensible creation defaults.
- **CU-CAL-007 — Recurrence scopes.** Cover daily/weekly/monthly/yearly/custom,
  interval/weekdays/end conditions, DST/leap dates, Edit This vs All, and Delete
  This/This and Future/All with clear prompts.
- **CU-CAL-008 — Calendar management.** Add, inline rename, recolor, hide/show,
  set default, and delete with warning. Chips and creation defaults must update.
- **CU-CAL-009 — Import/export UI.** File pickers and sheets must cancel cleanly,
  malformed ICS must show a useful error, valid fixture counts must be correct,
  and export naming must use the calendar name. Semantic compatibility is Human.
- **CU-CAL-010 — Read-only overlay UI.** With fixture/live overlay data, native
  events display alongside local events and expose no edit/delete/drag path.

### Calendar AI Review

- **CU-CALAI-001 — Review card.** Verify event subject, summary, date, calendar
  metadata, persisted removal after View, all-clear state, and refresh spinner.
- **CU-CALAI-002 — Routing.** View/body must open Calendar focused on the expected
  event or occurrence without leaving a stale review item.

### Reminders

- **CU-REM-001 — Onboarding.** Reset first-open state and cover Apple import, ICS
  import, Start Fresh, Not Now, cancellation, and completion persistence.
- **CU-REM-002 — Smart views and counts.** Today includes overdue; Scheduled is
  due-dated; Inbox is undated; Flagged and Completed are accurate. User-list
  counts, hidden/deleted fallback, and empty states must agree. A hidden list's
  reminders are excluded from every smart view, sidebar badge, and the Workspace
  tile (matching calendar chips); they reappear when the list is shown again.
- **CU-REM-003 — Creation defaults.** New from Today inherits today, from a user
  list inherits that list, and elsewhere uses the default list. Command-N and +
  must agree.
- **CU-REM-004 — Editor fields.** Cover title gating, list, no due/date-only/timed,
  priority, flag, URL, notes, checklists, Save-only writes, Cancel, and no surprise
  creation of a fallback list.
- **CU-REM-005 — Checklist.** Add/remove/check/uncheck items, drop empty steps on
  Save, show completed count, and persist edits.
- **CU-REM-006 — Rows and ordering.** Verify due/overdue styling, repeat,
  priority, flag, checklist, notes indicators, smart-list ordering, and persisted
  manual order in user lists.
- **CU-REM-007 — Completion and undo.** One-off completion moves to history and
  can uncomplete. Recurring completion logs history and advances the master; undo
  restores the prior due date and removes the log. Only the newest history row
  per series offers undo (older rows' circles are disabled with an explanatory
  tooltip), and a rapid double-click completes one occurrence, not two.
- **CU-REM-008 — Repeat modes.** Cover fixed schedule and after-completion units,
  end constraints, invalid repeat without due, early completion basis, Skip This
  Occurrence, COUNT exhaustion (skipping the final occurrence retires the series
  rather than leaving it pending), and completed-log read-only behavior.
- **CU-REM-009 — Delete semantics.** Pending delete confirms, recurring warning
  mentions history, completed cleanup behaves as designed, and list delete warns
  before removing its reminders.
- **CU-REM-010 — List management.** Add, rename, recolor, reorder where supported,
  hide/show, set default, and delete. Sidebar, chips, and creation defaults update.
- **CU-REM-011 — Import/export UI.** Sheets/file pickers cancel cleanly, malformed
  VTODO shows a useful error, fixture counts/names are correct, and export uses the
  list name. Semantic compatibility is Human.
- **CU-REM-012 — Show in Calendar.** Default off and feature-gated; when enabled,
  pending masters appear in Month, all-day strip, and Agenda. Hidden lists stay
  hidden, overdue rolls to today, and overflow is shared with events.
- **CU-REM-013 — Calendar actions.** Open in Reminders routes to the correct list;
  Mark Completed and Agenda completion remove or roll forward the item through
  the repository.

### Reminders AI Review

- **CU-REMAI-001 — Review card.** Verify subject, summary, due date, list metadata,
  persistent removal after View, all-clear state, and refresh spin/disable.
- **CU-REMAI-002 — Routing.** View/body must open the exact reminder and select
  its visible list, or open the reminder's editor directly when its list is
  hidden.

### Notes

- **CU-NOTE-001 — Onboarding and vault choice.** Reset first-open state and cover
  app-managed vault creation, choosing a prepared external folder, cancellation,
  Not Now, and completion persistence. No vault work should run before Notes is
  enabled and configured.
- **CU-NOTE-002 — Create, edit, autosave, and search.** Create several notes,
  type distinctive content, wait for idle autosave, switch selections, relaunch,
  and confirm content persists. New filenames must be safe and unique; title
  search and empty states must track the visible list. Creation through equivalent
  `/tmp` and `/private/tmp` external-vault paths must work; a real creation failure
  must show a dismissible error instead of silently doing nothing.
- **CU-NOTE-003 — External catalog refresh.** With a prepared disposable vault,
  add, rename, modify, and remove selected and non-selected Markdown files outside
  SwiftClaw. The list and Settings note count must refresh; clean selected files
  may close, while dirty deleted files retain their editor buffer and warning.
- **CU-NOTE-004 — Conflict and failed-save presentation.** Trigger a hash conflict
  and a recoverable write failure with safe fixtures. Conflict-copy and save-error
  banners must be readable and accessible, failed selection changes must keep the
  original dirty note open, and editable text must never be replaced by an error
  placeholder. Exercise both Keep Mine and Take Theirs; Keep Mine must create
  exactly one copy of the current local buffer even when autosave completes before
  reconciliation notices the external change.
- **CU-NOTE-005 — Editor layout and resizing.** At minimum and common window
  sizes, resize the Notes list/detail split and inspect screenshots as well as
  accessibility state. The selected note text must keep normal leading padding;
  the list, editor, New Note, and Search notes must remain visible without
  clipping or overlap.
- **CU-NOTE-006 — Styled-source losslessness.** Type and edit headings, emphasis,
  lists with a non-1 start, links, wikilinks, fenced code, callouts, tables, front
  matter, and image syntax. Source styling must never alter characters; switching
  notes, relaunching, and returning from Read must preserve the exact Markdown.
  Removing an opening or closing fence marker must immediately clear stale code
  styling from every affected line.
- **CU-NOTE-007 — Reading mode.** Use Edit/Read and Command-E. Reading mode must
  hide front matter and coherently render headings, emphasis, lists, tables,
  fenced code, callouts, wikilinks, and relative images. Two notes that reference
  different same-named images must not reuse stale image content, and returning
  to Edit must restore the complete source.
- **CU-NOTE-008 — Indexed search.** In a disposable vault, verify initial and
  incremental indexing, exact and punctuation-heavy queries, heading/snippet
  presentation, result navigation, no-result state, and FTS-only behavior with
  embeddings disabled. Inspect screenshots and accessibility state together.
- **CU-NOTE-009 — Quick switcher and backlinks.** Exercise Command-O ranking,
  keyboard dismissal and selection, then open the backlinks inspector for linked,
  unlinked, and multiply-linked notes. Resizing must not clip either surface.
- **CU-NOTE-010 — Wikilink completion and health.** Type `[[` and narrow, accept,
  and dismiss suggestions; then create a broken link and conflict copy, inspect
  the health banner and Settings details, rebuild, and verify the visible state
  recovers without disturbing the current edit.
- **CU-NOTE-011 — AI read-tool listing and gating.** With Notes enabled and a
  disposable indexed vault, Search Notes and Read Note must show Ready in Tools
  without per-tool switches. While remaining on Tools, disable Notes and confirm
  both badges immediately become Needs setup; re-enable Notes and confirm both
  immediately return to Ready. Inspect screenshots and accessibility state on
  both macOS and iOS for all three states.
- **CU-NOTE-012 — Note proposal diff cards.** In a disposable vault and chat,
  create edit and create proposals without changing either target first. Each
  card must show its kind, path, summary, accessible added/removed lines, and a
  working Show/Hide changes control without clipping. Reject one and approve the
  other; terminal status must replace the action buttons, rejection must leave
  files untouched, and approval must apply exactly once. Change an edit target
  before approval and confirm the card becomes conflicted without overwriting it.
  Repeat after switching or disconnecting the vault and confirm the old proposal
  cannot write into the new or unavailable vault.
- **CU-NOTE-013 — Quick capture and daily notes.** From the Notes toolbar and
  Workspace action on macOS and iOS, append several captures to today's
  `YYYY-MM-DD.md` and create colliding standalone titles. Existing Markdown must
  be preserved byte-for-byte outside the appended separator/bullet, filenames
  must uniquify safely, Captured Today must roll over by local day, and a hash
  conflict must preserve the external edit.
- **CU-NOTE-014 — Notes review card.** In an isolated vault containing an
  unchecked daily task, conflict copy, broken link, and recent note, Review Now
  must create a readable `.notes` card with index health and no edit actions.
  Sparkle refresh must replace the prior card, disable while running, and remain
  credential-free under the DEBUG fixture on both macOS and iOS.
- **CU-NOTE-015 — Editor and quick-switcher accessibility.** On macOS, inspect
  the native editor through the accessibility tree and VoiceOver: it must remain
  an editable text control with a useful label/value and normal text navigation.
  Open Command-O without the mouse; type a query, move with Up/Down, open with
  Return, and dismiss with Escape. On iOS, verify the TextEditor fallback keeps
  the same readable label and lossless content behavior. Proposal diffs must
  speak added, removed, unchanged, and blank lines without relying on color or
  `+`/`-` punctuation.
- **CU-NOTE-016 — Revisions sheet and restore copy.** In the hardened temporary
  fixture on macOS and iOS, open Revisions for a note with history and for one
  without it. Verify newest-first dates, short previews, empty/loading/error
  states, accessible Restore/Close controls, and disabled duplicate activation
  while restoring. Restore a revision and confirm the success path names one
  new conflict copy containing the historical content while the live note stays
  unchanged. Close the sheet and confirm the copy is visible and searchable.

### Settings

- **CU-SET-001 — Open and reuse.** Command-, and the app menu must open the native
  Settings window at Appearance without spawning duplicate windows unexpectedly.
- **CU-SET-002 — Section navigation.** Visit several sections; toolbar Back/Forward
  and Command-[ / Command-] must traverse history, and a new selection clears
  Forward.
- **CU-SET-003 — Direct links.** Email gear opens Email, chat user avatar opens
  Persona, and a disabled Workspace feature opens Tools at the highlighted row.
- **CU-SET-004 — Relaunch persistence.** Theme, persona, personality, provider
  metadata, model behaviors, notification/source choices, feature toggles, and
  schedules must persist. Secret fields remain masked.
- **CU-SET-005 — Appearance controls.** System/Light/Dark selection, hue/lightness
  preview, live quote update, and Reset enabled state must behave correctly.
- **CU-SET-006 — Persona controls.** Override/reset name; choose/cancel/remove a
  valid avatar; verify preview, status, accessibility, and persistence.
- **CU-SET-007 — Personality controls.** Assistant name/avatar reset, all five
  preset labels, prompt preview, Custom Personality toggle/editor, and persistence
  must be coherent.
- **CU-SET-008 — Provider editors.** Expand/collapse providers, mask/reveal keys,
  add/edit/collapse/remove deployments/models, update summaries/capabilities, and
  show Azure's missing resource-name warning. Use dummy metadata only.
- **CU-SET-009 — Model behavior filtering.** Non-reasoning models appear under
  Swift, reasoning models under Claw, and all under Research. Reasoning Effort is
  disabled with no Claw model; stale selections show unavailable rather than blank.
- **CU-SET-010 — Tools dependencies.** Investigation depends on Web Search;
  disabling Web Search disables Investigation. Max Subagents is available only
  when effective and shows an integer. Feature rows expose setup state and help.
- **CU-SET-011 — Notifications controls.** Master off disables sources; master on
  enables them. Reminder Alerts reveals the wall-clock picker, which persists
  after leaving/reopening.
- **CU-SET-012 — Email feature gating.** Email off disables account, schedule,
  scope, filters, and review controls; on restores them.
- **CU-SET-013 — Email schedule controls.** Interval/Daily switches editors;
  daily times add, sort, deduplicate, and retain at least one. Slower sync than
  review shows the stale-mail warning.
- **CU-SET-014 — Email scope controls.** Verify 5–100 review count boundaries,
  age toggle/slider, status filters, Slide Action, auto-navigation, and persistence.
- **CU-SET-015 — Email account validation.** Avoid initial error noise; cover bad
  host, spaces, port bounds, From address, disabled Test/Add, failed test, success
  invalidation after edits, and Cancel-without-save.
- **CU-SET-016 — Email account row.** Row opens Edit; custom swipe reveals Delete
  without breaking taps/scroll. Cancel preserves; confirmation removes.
- **CU-SET-017 — Review Folders settings.** Inbox stays enabled and locked,
  custom folders sort alphabetically, choices persist, and Refresh shows progress
  and a useful result.
- **CU-SET-018 — Calendar settings.** Enable reveals default calendar, review
  cadence, Apple overlay, imports, and per-calendar export; values persist and
  disable hides the feature-backed section safely.
- **CU-SET-019 — Reminders settings.** Enable reveals default list, Show in
  Calendar, review cadence, imports, and per-list export; values persist and
  disable hides the feature-backed section safely.
- **CU-SET-020 — Notes settings.** Enabling Notes reveals vault location,
  resolved path, note count, semantic-search and index-health controls, plus
  Change, Reveal, and Reset. Notes and Settings must agree on the active vault;
  Reset must disconnect without deleting files, and disabling Notes must stop
  vault activity.
- **CU-SET-021 — Notes capture and review settings.** Daily Note Folder must
  accept only safe vault-relative folders (blank means root), Scheduled Review
  must persist manual/6-hour/12-hour/daily choices, and Review Now must show an
  honest progress/result state while using the configured disposable vault.
