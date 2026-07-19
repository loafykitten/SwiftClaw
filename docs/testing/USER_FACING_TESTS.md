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

Each entry below leads with **Do** (what you actually do) and **Why** (why a
person has to do it), followed by the technical detail for reference.

### App Shell and Cross-Feature Flows

- **H-SHELL-001 — First-run notification offer.**
  **Do:** Reset notification permissions, launch the app fresh, and walk through
  the notification offer — try both Allow and Not Now, then relaunch.
  **Why:** Only a person can judge whether the timing and wording feel right,
  and the real macOS permission prompt can't be automated.
  *Detail:* The OS prompt must appear only after you consent in-app, and
  Settings must remain a recovery path if you said Not Now.
- **H-SHELL-002 — Real notification delivery and routing.**
  **Do:** Turn on one notification source at a time (mail, review results,
  background chat reply, Calendar alert, Reminder alert), trigger each one, and
  tap the notification.
  **Why:** Real notification delivery needs OS permission and live data —
  automation can't receive them.
  *Detail:* Each notification must be useful and its tap must open the exact
  destination. No notification should appear while that destination is already
  on screen.
- **H-SHELL-003 — Notification denial recovery.**
  **Do:** Deny notification permission in macOS, read the in-app warning, use
  its Open System Settings button, grant permission there, and come back.
  **Why:** This crosses into System Settings, which only a person can drive,
  and the warning text needs a human readability check.
  *Detail:* The in-app status must refresh without relaunching the app.
- **H-SHELL-004 — Accessibility pass.**
  **Do:** Put the mouse away — use keyboard-only navigation and VoiceOver
  through the main window, Settings, composer, delete dialogs, review cards,
  and feature editors.
  **Why:** Whether focus order and spoken labels actually make sense is a
  judgment call.
  *Detail:* Focus order, names, values, and the reasons controls are disabled
  must all be clear.
- **H-SHELL-005 — Startup failure presentation.**
  **Do:** Nothing yet — this one is on hold.
  **Why:** It needs a safe debug switch to fake a database failure, which
  doesn't exist yet; forcing a real failure would risk real data.
  *Detail:* Once fault injection exists: force model-container creation to
  fail and check that the recovery screen explains the problem and options.

### Home

- **H-HOME-001 — Personalized greeting quality.**
  **Do:** Open the app at different times of day (and different weather) and
  read the greeting on Home.
  **Why:** "Does this greeting sound natural and not weird?" is AI-quality
  judgment only a person can make.
  *Detail:* It should be brief, varied, use time/daylight/weather only when
  relevant, and end with your preferred persona name. Requires Swift Model,
  location, and network.
- **H-HOME-002 — Greeting fallback quality.**
  **Do:** Repeat the greeting check with location denied, then with the network
  off, then with no Swift Model configured.
  **Why:** The fallback should feel normal, not broken — that's a feel check.
  *Detail:* The fallback must appear quickly and must not mention missing
  context or show an error.
- **H-HOME-003 — Home blurb quality.**
  **Do:** Read the small secondary line under the greeting a few times.
  **Why:** Tone (cozy/witty, not robotic) is subjective.
  *Detail:* It should be short and free of quotes, emoji, or explanations. If
  generation fails, the layout must stay stable with no error noise. Requires
  Swift Model.
- **H-HOME-004 — First-message result.**
  **Do:** Send a message from the Home screen (try one with an image attached)
  and read the reply in the new chat.
  **Why:** Judging answer quality, persona, and image understanding needs a
  human eye.
  *Detail:* The new conversation should preserve your original prompt and
  attachments. Requires configured models; use a vision model for the image
  case.

### Chats and Composer

- **H-CHAT-001 — Multi-turn continuity and persona.**
  **Do:** Have a several-message back-and-forth conversation.
  **Why:** Whether the assistant "remembers" the conversation and stays in
  character is a quality judgment.
  *Detail:* It must use prior context, the selected model, and current
  Persona/Personality settings without ever exposing system instructions.
- **H-CHAT-002 — Reasoning behavior.**
  **Do:** Ask the same question twice — once with reasoning Off, once with a
  reasoning effort turned up — and compare.
  **Why:** "Did more effort visibly help?" is a judgment call.
  *Detail:* Both must complete, and raw private reasoning must never be shown.
- **H-CHAT-003 — Investigation quality.**
  **Do:** Turn on Investigation and ask a current-events research question.
  **Why:** Checking that citations actually support the claims means reading
  the sources yourself.
  *Detail:* Progress text should make sense, citation links must work, and the
  Sources section should be complete. Requires Brave Search and a
  reasoning/tool-capable model.
- **H-CHAT-004 — Vision conversation.**
  **Do:** Send one image, then several images, ask follow-up questions about
  them, and relaunch the app.
  **Why:** Whether it understood the right image correctly is human judgment.
  *Detail:* It must use the correct images, keep context across turns, and
  still render them after relaunch. Requires a vision model.
- **H-CHAT-005 — Generated titles.**
  **Do:** Start chats and look at the auto-generated titles; also try
  Regenerate Title.
  **Why:** "Is this a good title?" is subjective.
  *Detail:* Titles must be concise, representative, single-line, and unquoted.
  Regeneration should reflect both the opening and recent messages.
- **H-CHAT-006 — Background reply notification.**
  **Do:** Send a message that will take a while, navigate away before it
  finishes, and tap the notification when it arrives.
  **Why:** Real notification delivery needs OS permission and live timing.
  *Detail:* The preview must be safe and useful, the tap must open the exact
  chat, and no notification should fire while you're already viewing that chat.
- **H-CHAT-007 — Appearance judgment.**
  **Do:** Look over chats in both Light and Dark themes, including at the
  smallest window size.
  **Why:** Visual polish (density, readability, balance) is a taste check.
  *Detail:* Judge bubble balance, avatars, markdown hierarchy, quote accent
  readability, and hover states.

### Workspace

- **H-WORK-001 — Dashboard usefulness.**
  **Do:** With realistic mail, events, and reminders loaded, glance at the
  Workspace widgets and resize the window.
  **Why:** "Does this show me the right stuff at a glance?" is a usefulness
  judgment.
  *Detail:* Summaries should surface the right information and stay readable
  at common window sizes.
- **H-WORK-002 — Cross-feature routing.**
  **Do:** Open review cards and real notifications for email, Calendar, and
  Reminders, and check where each one lands you.
  **Why:** Whether the destination is what a person would *expect* is a
  judgment call, and real notifications can't be automated.
  *Detail:* Include mail older than the initially loaded message window.

### Email

- **H-MAIL-001 — Account lifecycle.**
  **Do:** Add a throwaway email account, save it, relaunch, edit its settings,
  retest the connection, then delete the account.
  **Why:** Real account credentials, Keychain, and a live server are involved —
  none of that belongs in automation.
  *Detail:* Secrets must live in the Keychain while configured and be removed
  on deletion; already-synced local mail should remain.
- **H-MAIL-002 — Live first and incremental sync.**
  **Do:** Run the first sync, send yourself new mail, and sync again.
  **Why:** Needs a real mail server delivering real messages.
  *Detail:* Status and last-sync text must be honest, the first-sync cap must
  not block later mail, and re-syncing must not create duplicates.
- **H-MAIL-003 — IMAP reconciliation.**
  **Do:** In a *different* mail app, mark things read/flagged, delete, archive,
  and move messages — then check SwiftClaw catches up.
  **Why:** Needs a second real mail client acting on the same live account.
  *Detail:* SwiftClaw must settle to the server's state without losing your
  notes or breaking thread grouping.
- **H-MAIL-004 — Connection reuse.**
  **Do:** Flag a message while a long sync is running; later, leave the app
  idle long enough for the connection to time out, then sync again.
  **Why:** Live-connection timing behavior can only be seen against a real
  server. *(Known gap — not yet verified live.)*
  *Detail:* Interactive actions must stay responsive and reconnect cleanly.
- **H-MAIL-005 — Folder discovery.**
  **Do:** With an account that has standard, custom, and nested folders, browse
  the folder list — including a Gmail account and a second account.
  **Why:** Real providers (especially Gmail) do quirky folder things fixtures
  can't reproduce. *(Known gap — not yet verified live.)*
  *Detail:* Gmail All Mail must not be misclassified, Review Folders must list
  real choices, and the multi-account unified view hides interleaved custom
  folders.
- **H-MAIL-006 — Message rendering.**
  **Do:** Open a variety of real mail: plain text, non-English text, very long
  mail, ugly newsletter HTML, remote images, links, attachments.
  **Why:** "Does this look readable and safe?" is an eyeball check across
  messy real-world mail.
  *Detail:* Content must remain readable and usable without broken layout.
- **H-MAIL-007 — Server-side actions.**
  **Do:** Mark read, flag, archive, delete to Trash, permanently delete, and
  add a local note — then verify in another mail client too.
  **Why:** Confirming the *server* really changed requires a second client;
  permanent deletion is destructive.
  *Detail:* Include recovering a message from Trash before permanent deletion.
- **H-MAIL-008 — Reply end to end.**
  **Do:** Reply back and forth between two throwaway mailboxes.
  **Why:** Real delivery, threading, and the Sent folder only prove out
  against live servers. *(Known gap — not yet verified live.)*
  *Detail:* Recipient threading and headers must be correct, the Sent copy
  must upload, and the local sent row must reconcile without a duplicate.
- **H-MAIL-009 — Review judgment.**
  **Do:** Run Review Now on an inbox you control and read what the AI picked
  and said.
  **Why:** Whether the AI chose sensibly and stayed restrained is judgment.
  *Detail:* A large unread backlog must not blow up the prompt.
- **H-MAIL-010 — Review scope.**
  **Do:** Change the review scope settings (read/unread/flagged/notated, age,
  max count, Archive/Trash, custom folders) and rerun reviews.
  **Why:** Checking the AI actually respected each scope means reading the
  results.
  *Detail:* Inbox must always stay included, and results must match the
  chosen scope.
- **H-MAIL-011 — Review actions.**
  **Do:** From a review card, use Review, Flag, Archive, and Delete.
  **Why:** Server-side effects need live verification.
  *Detail:* Local and server state must agree. The suggested Reply action
  currently marks read and flags rather than opening a composer — that's
  expected.
- **H-MAIL-012 — Conversational review follow-up.**
  **Do:** In an Inbox Review chat, ask about the mail it showed, then about
  older mail, then about a specific folder/status.
  **Why:** Spotting hallucinated mail content requires knowing what's really
  in the mailbox.
  *Detail:* It must fetch the relevant messages and be honest about
  uncertainty.
- **H-MAIL-013 — Scheduled review behavior.**
  **Do:** Try manual-only, interval, and daily review schedules, with
  auto-navigation both on and off, over real elapsed time.
  **Why:** Schedules and background notifications play out in real time.
  *Detail:* A prior unread review should suppress duplicates, and
  notifications/badges should match the setting.

### Calendar

- **H-CAL-001 — Natural-language quick entry.**
  **Do:** Type event phrases in plain English — timed, all-day, with duration,
  a calendar name, recurrence, an alert, and something ambiguous.
  **Why:** Judging how well the AI understood your phrasing is a human call.
  *Detail:* The editor should be sensibly prefilled, keep your phrase if
  parsing fails, and never save before you confirm. Requires a model.
- **H-CAL-002 — Apple Calendar import.**
  **Do:** Import from Apple Calendar: try denying then allowing permission,
  picking calendars, and re-importing.
  **Why:** Real OS permission prompts and your real Apple Calendar data are
  involved.
  *Detail:* All-day events, recurrence, and detached/deleted occurrences must
  map accurately; re-imports must update rather than duplicate.
- **H-CAL-003 — ICS interoperability.**
  **Do:** Import calendar (.ics) files from Apple/Google, then export from
  SwiftClaw and open the file in another calendar app.
  **Why:** The round-trip through other real apps is the whole point.
  *Detail:* All-day dates, time zones, recurrence, EXDATE, detached instances,
  Unicode, and folded lines must all survive.
- **H-CAL-004 — Apple Calendar overlay.**
  **Do:** Compare the overlay side by side with Apple Calendar, change an
  event in Apple Calendar, and watch SwiftClaw refresh.
  **Why:** Needs the real Apple Calendar app changing real data.
  *Detail:* Overlay events must stay read-only and never become stored
  SwiftClaw events.
- **H-CAL-005 — Event alerts.**
  **Do:** Create events a few minutes out with alerts, wait for them, tap
  them, then edit/delete events and toggle sources and the feature.
  **Why:** Real alert delivery happens on the OS's clock, not automation's.
  *Detail:* Delivery text/time and tap routing must be correct; edits,
  deletes, and toggles must rebook or clear alerts. A retitled event's alert
  shows the new title; disable-then-quickly-re-enable must still rebook.
- **H-CAL-007 — AI review quality.**
  **Do:** Set up a calendar with conflicts, changed events, and things worth
  preparing for, then read the AI's review.
  **Why:** Whether the analysis is useful and restrained is judgment.
  *Detail:* Manual refresh must bypass scheduled suppression.
- **H-CAL-008 — Scheduled AI loop.**
  **Do:** Try manual-only, 6-hour, 12-hour, and daily review settings over
  real time.
  **Why:** Scheduling plays out over hours/days.
  *Detail:* Unchanged events and unread prior results should suppress
  duplicate reviews; useful results should route and notify correctly.
- **H-CAL-009 — CloudKit sync.**
  **Do:** Nothing yet — blocked until paid-team entitlements are restored.
  **Why:** Two-device iCloud sync can't run without those entitlements. This
  is a known blocker, not a release failure.
  *Detail:* When unblocked: verify two-device sync, post-merge dedupe, and
  remote alert reconciliation.

### Reminders

- **H-REM-001 — Natural-language quick entry.**
  **Do:** Type reminder phrases in plain English — no date, date-only, timed,
  with a list, priority, flag, notes, and both repeat styles.
  **Why:** Judging how well the AI parsed your phrasing is a human call.
  *Detail:* Unmatched lists and repeat-without-a-due-date must degrade safely,
  and nothing saves before you confirm.
- **H-REM-002 — Apple Reminders import.**
  **Do:** Import from Apple Reminders: try permission states, pick lists, and
  re-import.
  **Why:** Real OS permission and your real Reminders data are involved.
  *Detail:* Completed/date/time/priority/fixed recurrence must map correctly,
  re-import must not duplicate, and the known "Apple subtasks not imported"
  omission must be communicated.
- **H-REM-003 — VTODO interoperability.**
  **Do:** Export/import reminder (.ics VTODO) files with another task app, and
  with a second SwiftClaw profile for SwiftClaw-specific extras.
  **Why:** Round-tripping through other real apps is the point.
  *Detail:* Flags, checklists, and after-completion repeats must survive the
  SwiftClaw-to-SwiftClaw trip; mixed event/task files must not cross-import.
- **H-REM-004 — Reminder alerts.**
  **Do:** Set timed and date-only reminders (including across a DST-change
  date), wait for the alerts, tap them, and try edits, completion, deletion,
  and toggles.
  **Why:** Real alert delivery happens on the OS's clock.
  *Detail:* Delivery time and tap routing must be exact. A hidden-list
  reminder's tap opens its editor directly; tapping a delivered banner after
  the feature is disabled must do nothing (no stuck navigation).
- **H-REM-005 — AI review quality.**
  **Do:** Seed undated, overdue, and this-week reminders, run a review, and
  read it.
  **Why:** Prioritization quality and restraint are judgment.
  *Detail:* The no-result case must be handled, failures must retry, and
  manual runs must bypass suppression.
- **H-REM-006 — Scheduled AI loop.**
  **Do:** Try manual-only, 6-hour, 12-hour, and daily review settings over
  real time.
  **Why:** Scheduling plays out over hours/days.
  *Detail:* An unread prior review, no pending work, or unchanged work should
  suppress a scheduled pass; meaningful changes should produce one.
- **H-REM-007 — Recurrence semantics.**
  **Do:** Live with real repeating tasks for a bit: complete early, complete
  late, skip, undo, and let a limited-count series run out.
  **Why:** Whether the behavior matches what the wording *promised* is a
  human judgment over real usage.
  *Detail:* History should match the language shown in the UI.

### Notes

- **H-NOTE-001 — External vault interoperability.**
  **Do:** Connect a throwaway folder of Markdown notes (with Obsidian
  metadata), then add/edit/rename/remove notes from another editor.
  **Why:** Real interop with another app (Obsidian) needs that app.
  *Detail:* SwiftClaw must reconcile the visible note list while leaving
  dotfiles, `.obsidian/`, non-Markdown files, and symlinks untouched.
- **H-NOTE-002 — Concurrent-edit safety.**
  **Do:** Edit the same note in SwiftClaw and another editor at once; try Keep
  Mine, Take Theirs, and deleting the file externally while SwiftClaw has
  unsaved text.
  **Why:** This is data-safety judgment with a real second editor — the one
  place you can lose writing.
  *Detail:* Keep Mine preserves the external version and creates exactly one
  clearly surfaced conflict copy of your SwiftClaw edits; Take Theirs discards
  the local buffer with no copy. Externally deleted + unsaved text: the text
  stays visible and the path isn't silently recreated.
- **H-NOTE-003 — External-vault permission recovery.**
  **Do:** Revoke or disconnect vault access while a note has unsaved edits,
  then restore access and retry the save.
  **Why:** OS file-permission revocation is a real-system action.
  *Detail:* The editor must keep your text readable and selected, explain the
  save failure, and save on retry without a relaunch.
- **H-NOTE-004 — Hybrid search quality.**
  **Do:** Search a realistic vault with exact terms, punctuation-heavy text,
  headings, and reworded paraphrases.
  **Why:** "Did it find the right note?" is relevance judgment.
  *Detail:* Results must open the right note with useful heading/snippet
  context, and stay useful with embeddings disabled or unavailable.
- **H-NOTE-005 — Link graph and backlinks.**
  **Do:** Create direct, aliased, heading, unresolved, and inside-code-fence
  wikilinks, then check backlinks and broken-link reports.
  **Why:** Whether resolution matches Obsidian's behavior is a comparison a
  person makes.
  *Detail:* Fenced code examples must not be treated as links.
- **H-NOTE-006 — Quick switcher ranking.**
  **Do:** Use Command-O with exact, prefix, scattered-letters, path, and
  no-match queries.
  **Why:** Whether ranking "feels predictable" is subjective.
  *Detail:* Highlighted matches should make sense and choosing a result must
  select that note.
- **H-NOTE-007 — Vault health and rebuild.**
  **Do:** Create broken links and conflict copies, toggle embeddings, and
  rebuild the index; read the banner and Settings details.
  **Why:** Whether the degraded-search explanation is *clear* is a
  readability judgment.
  *Detail:* Banner and Settings must agree and recover after a rebuild.
- **H-NOTE-008 — AI read tools end to end.**
  **Do:** With a throwaway vault connected, ask a chat what your notes say
  about a distinctive topic. Then disable Notes and ask again.
  **Why:** Judging answer accuracy against what the notes really say is
  human work.
  *Detail:* The answer must use Search Notes / Read Note, cite the correct
  note and heading, preserve verbatim content when asked, and disclose
  truncation. After disabling Notes, neither tool may remain available.
- **H-NOTE-009 — AI note proposal quality and safety.**
  **Do:** Ask the AI to edit a note and to create one. Approve one proposal,
  reject the other, and change one target file externally before approving.
  **Why:** AI writing to your files is the highest-stakes flow — approval
  safety needs a human.
  *Detail:* The AI should propose, not write immediately. Only an approved,
  unchanged target may be written; a stale proposal must say it wasn't
  applied.
- **H-NOTE-010 — Notes review judgment.**
  **Do:** Run manual and scheduled Notes reviews on a realistic throwaway
  vault and read the results.
  **Why:** Usefulness and restraint are judgment.
  *Detail:* Reviews stay read-only and should surface unchecked daily-note
  tasks, conflict copies, broken links, notes needing follow-up, and degraded
  index health.
- **H-NOTE-011 — Scale and large-note usability.**
  **Do:** Generate 5,000 varied notes in a temporary vault, time the initial
  indexing, run searches, then open and edit a 1 MiB note.
  **Why:** "Does it *feel* responsive?" under load is experienced, not
  asserted.
  *Detail:* Indexing should finish within 30 seconds on the supported test
  Mac. Typing, selection, autosave, and VoiceOver must stay usable in the
  big note (styling may be capped), with no source changes beyond what you
  typed.
- **H-NOTE-012 — Revision recovery safety.**
  **Do:** Save a note several times, open Revisions, make sense of the
  timestamps/previews, and restore an old version.
  **Why:** Restore must never destroy current work — a data-safety check.
  *Detail:* The current note stays byte-for-byte unchanged; the old content
  appears as one clearly named sibling conflict copy you can merge by hand.

### Memory

- **H-MEM-001 — Autonomous capture judgment.**
  **Do:** Chat normally and mention lasting preferences; watch what the
  assistant decides to save to Memory.
  **Why:** Whether it saved the *right* things (and skipped trivia) is
  judgment.
  *Detail:* Saved facts should be short and single-purpose, filed into
  sensible collections (Inbox when unsure, never a wrong home), each save
  disclosed with a chip. One-off statements should not be saved.
- **H-MEM-002 — Asks-first flow quality.**
  **Do:** With an "AI asks first" collection, ask the assistant to remember
  something that belongs there, and try the proposal card and Edit sheet.
  **Why:** Clarity of the proposal wording is a readability judgment.
  *Detail:* The card must show entry text, target, and reason; dismissed
  proposals must not come back in later conversations.
- **H-MEM-003 — Review-run proposal restraint.**
  **Do:** Over several days of normal email/calendar/reminders/notes reviews,
  watch how often memory suggestions appear and decline some.
  **Why:** Restraint over days of real data can only be observed by living
  with it.
  *Detail:* Suggestions should be rare (max two per run), genuinely durable
  patterns, land in the run's review chat or a Memory suggestions chat, and
  declined ones stop reappearing.
- **H-MEM-004 — Recall usefulness.**
  **Do:** With facts already stored, chat normally and see whether the
  assistant uses them without being reminded.
  **Why:** "Did it apply my facts naturally?" is judgment.
  *Detail:* Includes scoped collections during feature discussions; it must
  never recite internal entry handles at you.
- **H-MEM-005 — Accessibility pass.**
  **Do:** VoiceOver through Memory: collection rows, entry rows, chip and
  proposal cards, editor sheets, and confirmation dialogs.
  **Why:** Whether spoken output makes sense is a human check.
  *Detail:* The access-level description must be spoken, and badge meaning
  must never rely on color alone.

### Deep Research

- **H-DR-001 — Full deep-research run quality.**
  **Do:** With real Brave and model keys, run Deep Research on a topic you
  know well: answer or skip the clarifying questions, edit the plan (rewrite
  one question, delete one, add one), start the run, and read the finished
  report end to end.
  **Why:** Report quality, citation accuracy, and whether the ⚠ flags and
  Open questions feel honest are judgment calls only a person can make.
  *Detail:* The report should be concise (screens, not pages), every [n]
  citation popover must show a believable excerpt from that source, and the
  run should finish inside the promised time scale.
- **H-DR-002 — Mid-run behavior on a real run.**
  **Do:** Start a run, watch the stage timeline and activity feed, navigate
  away and back, then stop a later run mid-flight.
  **Why:** Whether progress feels alive and cancel feels safe is subjective;
  real runs pace differently than fixtures.
  *Detail:* Stopping must produce a partial report with a visible
  stopped-early banner and run notes, never a lost session.
- **H-DR-003 — Completion notification.**
  **Do:** Start a run, switch to another tab (macOS: another app), wait for
  the completion notification, and tap it.
  **Why:** Real notification delivery and foreground suppression need a live
  run and OS permission.
  *Detail:* The notification must not appear if the Research tab is
  frontmost; tapping must land on the finished session's report.
- **H-DR-004 — Follow-up chat grounding.**
  **Do:** From a finished report, use Ask a follow-up; ask about a detail
  from a middle section of the report.
  **Why:** Whether the model actually uses the research_report tool and
  answers from the report (with [n] citations) is an AI-quality check.
  *Detail:* The chat's first answer should draw on report content without
  you pasting anything.
- **H-DR-005 — Investigation vs Deep Research positioning.**
  **Do:** Run the composer's Investigation toggle on a question, then run
  Deep Research on the same topic; compare tone and depth.
  **Why:** The casual-vs-deep contrast (conversational bullets vs cited
  document) is a subjective read.
  *Detail:* Investigation stays in-chat, short and conversational with [n]
  cites; Deep Research produces the structured, verified report.

### Settings

- **H-SET-001 — Theme quality and propagation.**
  **Do:** Try System/Light/Dark in both windows, flip macOS appearance while
  on System, and hit Reset.
  **Why:** Contrast and readability are eyeball checks; the live macOS
  appearance flip is a real-OS action.
  *Detail:* Check quote-accent contrast; Reset must restore a readable
  default.
- **H-SET-002 — Persona end to end.**
  **Do:** Check your detected name/avatar on Home and in chats, then override
  them, reset, and try an invalid image.
  **Why:** "Does it look right?" and error-message clarity are judgment.
  *Detail:* Replacement, reset, and the invalid-image error must all be
  understandable.
- **H-SET-003 — Assistant personality end to end.**
  **Do:** Ask the same real question under Focused, Clear, Deep, Playful,
  Warm, and a custom prompt.
  **Why:** Whether the tone actually matches the setting is judgment.
  *Detail:* Preview and response should match the choice; a whitespace-only
  custom prompt must be safe.
- **H-SET-004 — Provider integrations.**
  **Do:** For each AI provider, add a real key, confirm models appear, run a
  real completion (and reasoning), rotate the key, and remove it.
  **Why:** Real API keys and live provider calls can't go in automation.
  *Detail:* Credentials must persist and rotate correctly. Use disposable
  keys where possible.
- **H-SET-005 — Brave Search configuration.**
  **Do:** Configure a Brave key, run a real cited search, and check the
  Ready/Needs Setup state and Investigation dependency.
  **Why:** Needs a live key and live search traffic.
  *Detail:* Behavior at the configured request rate should match
  expectations.
- **H-SET-006 — Settings layout quality.**
  **Do:** Resize Settings down to minimum and through common sizes and look
  everything over.
  **Why:** Clipping and cramped layout are eyeball checks.
  *Detail:* Check the sidebar, forms, provider disclosures, long personality
  prompts, and Back/Forward controls.

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
  Reminders, Notes, and Memory. Workspace widgets and feature-backed Settings
  sections must update immediately, and hidden destinations must be pruned from
  selection and navigation history.
- **CU-SHELL-005 — Research tab badge.** Seed unviewed research sessions
  (`-research-fixture`). The Research sidebar dot / tab badge count must match
  the unviewed sessions, stay present while a run is active, and clear after
  the report (or failed state) is viewed.
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
  Reminders, Notes, and Memory tiles appear in an adaptive readable grid.
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
- **CU-WORK-008 — Memory tile.** With Memory enabled, the tile must show live
  entry and collection counts, and a pending-proposals line only when
  proposals await review; counts must refresh on reappearance after
  adding/removing entries.

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
  Not Now, and completion persistence. On iOS, Choose an Existing Folder must
  present the system folder picker and cancel cleanly. No vault work should run
  before Notes is enabled and configured.
- **CU-NOTE-002 — Create, edit, autosave, and search.** Create several notes,
  type distinctive content, wait for idle autosave, switch selections, relaunch,
  and confirm content persists. New filenames must be safe and unique; the list
  must sort in Finder-like natural order (case-insensitive, numeric-aware);
  title search and empty states must track the visible list. Creation through equivalent
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
  clipping or overlap. At wide window sizes the macOS editor caps its text
  measure near 72 characters and centers it rather than growing unreadably wide.
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
  embeddings disabled. Snippets must be single-line context around the match
  (not the chunk's opening heading), and semantic results must exclude notes
  unrelated to the query (similarity floor) instead of listing most of the
  vault. Inspect screenshots and accessibility state together.
- **CU-NOTE-009 — Quick switcher and backlinks.** Exercise Command-O ranking,
  keyboard dismissal and selection, then open the backlinks inspector for linked,
  unlinked, and multiply-linked notes. Resizing must not clip either surface.
  Switcher and list rows show a path caption only when it adds information
  beyond the title. On iOS the backlinks sheet must offer a Done button (plus
  drag-to-dismiss) and dismiss back to the editor.
- **CU-NOTE-010 — Wikilink completion and health.** Type `[[` and narrow, accept,
  and dismiss suggestions. On macOS the popup must appear adjacent to the caret
  (flipping above when there is no room below) and support full keyboard use:
  Up/Down move the highlighted row, Return/Tab accept it, Escape dismisses
  without inserting. Then create a broken link and conflict copy, inspect the
  health banner and Settings details (broken-link rows show a navigation
  chevron), rebuild, and verify the visible state recovers without disturbing
  the current edit. *(Caution: synthetic AX-injected input cannot drive the
  keyboard path — see `docs/testing/SIMULATOR_UI_VERIFICATION.md` caveats;
  use real key events or the hosted integration tests.)*
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
  cannot write into the new or unavailable vault. Diff line text must render in
  primary label color (only markers and backgrounds tinted), and with Increase
  Contrast enabled the added/removed backgrounds become opaque.
- **CU-NOTE-013 — Quick capture and daily notes.** From the Notes toolbar and
  Workspace action on macOS and iOS, append several captures to today's
  `YYYY-MM-DD.md` and create colliding standalone titles. The destination menu
  must show a checkmark on the current choice, and the iOS sheet must be
  top-aligned with a labeled Save button. Existing Markdown must be preserved
  byte-for-byte outside the appended separator/bullet, filenames must uniquify
  safely, Captured Today must roll over by local day, and a hash conflict must
  preserve the external edit.
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
  `+`/`-` punctuation. In reading mode, headings must expose their level as
  accessibility headings and task checkboxes must read as Completed/Incomplete
  task rather than raw glyphs. Vault banners (conflict, save error, health)
  must expose each action — Keep Mine, Take Theirs, Dismiss, Choose a Vault —
  as an individually focusable control with a self-explanatory label.
- **CU-NOTE-016 — Revisions sheet and restore copy.** In the hardened temporary
  fixture on macOS and iOS, open Revisions for a note with history and for one
  without it. Verify newest-first dates, short previews, empty/loading/error
  states, accessible Restore/Close controls, and disabled duplicate activation
  while restoring. Previews must show note content, skipping front matter, so
  cards are distinguishable. Restore a revision and confirm the success path names one
  new conflict copy containing the historical content while the live note stays
  unchanged. Close the sheet and confirm the copy is visible and searchable.

### Memory

- **CU-MEM-001 — Landing, Inbox, and badges.** With Memory freshly enabled,
  the landing (iOS) / sidebar (macOS) must show All Memory, Recent, Activity,
  and a Collections group containing an auto-created Inbox. Every collection
  row must carry an explicit labeled access badge ("AI asks first" /
  "AI writes freely" with distinct symbols), tag chips, entry count, and
  last-changed date.
- **CU-MEM-002 — Collection lifecycle and confirmations.** Create a collection
  with details, tags, access level, scope, and pinned; edit it; verify the
  asksFirst → writesFreely switch requires a confirmation dialog while the
  reverse does not; delete it via its confirmation naming the entry count.
  The Inbox must refuse delete/scope affordances.
- **CU-MEM-003 — Entry lifecycle and activity feed.** Add, edit, move, and
  delete entries; verify superseded entries render with their marker and stay
  out of a collection's active count. Every mutation must appear in Activity
  with the right verb, actor, snapshot text, and collection-level events
  phrased as "Created/Edited/Deleted collection".
- **CU-MEM-004 — Search and filters.** The search field must be labeled for
  its scope ("Search All Memory" vs. the collection name); queries must match
  entry bodies, tags, and collection titles; the filter menu (Added by AI,
  access level, scope) must combine with search; no-result and empty states
  must be distinct.
- **CU-MEM-005 — Write chip cards.** Launch with `-SwiftClawSeedMemoryCards`.
  The seeded chat's "Memory updated" chip must show the entry, its
  collection, and View + Undo. View opens a read-only peek sheet with the
  access badge. Undo flips the row to "No longer in memory" and removes the
  entry from Memory; an edited-since entry must show Undo disabled with an
  explanation instead.
- **CU-MEM-006 — Proposal cards.** With the same fixture, Accept must flip a
  card to "Saved to memory" and create the entry in its target; Edit must
  open prefilled, and Save & Accept must apply the modified wording;
  Dismiss must flip to "Dismissed" and write nothing. New-collection
  proposals must create the collection with its seed entries on accept.
  States must survive relaunch.
- **CU-MEM-007 — Tool listing and gating.** With Memory enabled, Search
  Memory and Open Memory Collection must show Ready in Settings › Tools
  without per-tool switches; disabling Memory must immediately flip them to
  Needs setup and remove all memory tools from chat.

### Deep Research

- **CU-DR-001 — Session list states.** Launch with `-research-fixture`. The
  list must show completed (green check), partial (orange triangle), failed
  (red x), and plan-ready (dashed circle) rows with relative dates and
  unviewed dots; the tab badge must match the unviewed count.
- **CU-DR-002 — Report rendering and citations.** Open the completed fixture
  session (`-research-fixture-open` deep-links it). The report must render
  headings, tappable [n] citation links, the inline ⚠ marker, an unverified-
  claims banner, Open questions, and the numbered Sources list. Tapping a
  citation or source row must open the source sheet with excerpts or the
  honest snippet-only note; sheet's link opens the source URL externally.
- **CU-DR-003 — Partial report honesty.** Open the partial fixture session.
  The stopped-early/fell-back banner must show with expandable run notes
  listing the degradations.
- **CU-DR-004 — Plan review editing.** Open the plan-ready fixture session.
  Questions and queries must be editable inline; deleting all threads must
  disable Start Research; adding a question row must re-enable it once
  filled. The footer must state the time/search scale.
- **CU-DR-005 — New session flow gating.** Create a session with a topic; the
  Continue button must be disabled for whitespace-only topics. The clarify
  step must always show a Skip button, even while questions load.
- **CU-DR-006 — Failed session recovery.** Open the failed fixture session.
  It must show the error message and a retry action (planning retry when no
  plan was saved); viewing it must clear its unviewed dot and badge count.
- **CU-DR-007 — Delete confirmation.** Deleting a session from the list must
  ask for confirmation and mention run cancellation when the session is
  running; confirming must remove the row and any open detail for it.
- **CU-DR-008 — Notification deep link routing.** With the app running and a
  seeded session, `AppRouter.showResearchSession` (fixture `-open` arg) must
  select the Research tab and present that session on both macOS and iOS
  compact.
- **CU-DR-009 — Report exports.** Copy Report must put the full markdown
  (title, body, sources) on the pasteboard; Save to Notes must appear only
  with a configured vault and create a note titled after the session.
- **CU-DR-010 — macOS outline inspector.** On a completed report, the
  Outline toolbar button must toggle an inspector listing the report's
  sections; selecting one must scroll the report to that heading.
- **CU-DR-011 — Settings section.** Research settings must persist across
  relaunch (time budget, thread cap, report length) and hiding the Research
  tab must remove it from navigation, pruning history, until re-enabled.

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
  Change and Reset (Reveal in Finder is macOS-only and must not appear on iOS).
  Notes and Settings must agree on the active vault; Reset must disconnect
  without deleting files, and disabling Notes must stop vault activity.
- **CU-SET-021 — Notes capture and review settings.** Daily Note Folder must
  accept only safe vault-relative folders (blank means root), Scheduled Review
  must persist manual/6-hour/12-hour/daily choices, and Review Now must show an
  honest progress/result state while using the configured disposable vault.
