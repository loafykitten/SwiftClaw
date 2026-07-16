# Notes UI/UX/a11y review fixes

**Started:** 2026-07-16  **Status:** COMPLETE — all findings implemented and verified; all 8 formerly-blocked confirmations resolved (7 visually passed, A1 proven via hosted integration tests after codex's AX-injected input turned out to be the failure, not the app)

## Goal
Resolve the 19 findings from the 2026-07-16 Notes UI/UX/accessibility review (screenshots + report in /tmp/codex-computer-use.6WAmGU). Implementation delegated to codex (gpt-5.6-sol, medium); Claude verifies each batch, then runs a final visual verification and code review.

## Current state
All 19 findings implemented (five codex batches, gpt-5.6-sol medium) and diff-reviewed by Claude. Claude fixed six codex/regression issues directly: (1) `Text` ambiguous with Markdown.Text → SwiftUI.Text; (2) invalid #if/#else postfix-chain in NotesQuickCaptureControl → extracted saveButton property; (3) NotesFeatureModelTests raw .sorted() expectations → localizedStandardCompare; (4) CRASH on Return/Escape in wikilink popup (stale-index ForEach) → identity on relativePath; (5) FTS snippet cut off by lineLimit → collapsedToSingleLine; (6) potential layout spin in CenteredMeasureScrollView → equality guard on textContainerInset. Full macOS test suite GREEN, iOS build GREEN, scoped suites green after every later fix. Final holistic code review of the entire diff: done.

## Next steps (blocks to resolve)
1. ALL RESOLVED 2026-07-16 afternoon — provider recovered; verify-final run + follow-ups: macOS revisions preview PASS (w03), flattened snippet PASS (w04, 1 result, single line, contains "invariant"), menu checkmark PASS (w01, beside "Today's Daily Note"); iOS via idb coordinate taps (Device Hub AX was a dead end): backlinks Done PASS incl. dismissal (vi01), quick-capture layout PASS (vi02, codex), settings without Reveal in Finder PASS (vi03), onboarding folder picker presents system picker + cancels cleanly PASS (vi04). A1 (wikilink Down/Return) closed via SwiftClawTests/Notes/NoteEditorViewKeyboardTests.swift (5 hosted-NSTextView tests, GREEN — see F7 row) after two codex GUI attempts failed for tool reasons, plus v04's earlier live caret-anchored screenshot. Screenshots in /tmp/codex-computer-use.6WAmGU.
2. Codex's stale "Problem Report for SwiftClaw" crash-reporter dialogs may be on screen — they are from the (since-fixed) NSWindow over-release in the FIRST version of the new test file crashing the test host, not from the app. Close them by hand.
2. If the ~75%-CPU hang reappears (seen once, before the textContainerInset guard): profile the editor layout path first.
3. F20 (double back-chevron in macOS title bar) remains deferred — app-shell navigation, not Notes.
4. Test-vault fixtures live in the app-managed vault (~/Library/Application Support/SwiftClaw/Notes/Vault) and defaults point there (`settings.notes.vaultLocationType = appManaged`); the iOS sim app has the same fixtures in its container. Clean up or repoint when the user resumes manual use.

## Findings status

| # | Finding | Status |
|---|---------|--------|
| F1 | iOS onboarding folder picker dead button | implemented (batch 1); iOS build green; live-visual blocked (provider outage) |
| F2 | iOS backlinks sheet undismissable | implemented (batch 1); iOS build green; live-visual blocked (provider outage) |
| F3 | .combine hides banner buttons from VoiceOver | implemented (batch 2), diff-reviewed |
| F4 | Vector search needs similarity floor | implemented (batch 3, 0.50 floor + tests), diff-reviewed |
| F5 | Snippets not match-contextual | implemented (batch 3) + Claude single-line collapse; unit-tested; live-verify blocked |
| F6 | Quick-capture destination state invisible (macOS menu) | implemented (batch 4, Picker in Menu), diff-reviewed |
| F7 | Wikilink popup: no keyboard nav, anchored away from caret | implemented (batch 4) + Claude crash fix; anchoring/highlight visually confirmed (v04); keyboard path proven by NoteEditorViewKeyboardTests (5 tests: anchor set, anchor tracks caret deep in document with on-screen window, Down moves selection, Return inserts, Escape dismisses, popup never steals first responder). Two codex GUI runs showed Down/Return inert + popup at top-left fallback — diagnosed as codex AX-injected input: AX insertion edits text without making the view first responder, so key events had nowhere to land, firstRect had no input context (nil anchor → fallback), and textDidEndEditing never fired (popup stayed open). Not an app bug. |
| F8 | Revision previews all show identical front matter | implemented (batch 4, FrontMatterBlock skip), diff-reviewed |
| F9 | Reading mode: no heading traits; checkbox glyphs unlabeled | implemented (batch 2), diff-reviewed |
| F10 | Diff green/red text contrast | implemented (batch 2), diff-reviewed |
| F11 | "Reveal in Finder" shown on iOS | implemented (batch 1); iOS build green; live-visual blocked (provider outage) |
| F12 | iOS Quick Capture sheet layout | implemented (batch 1); iOS build green; live-visual blocked (provider outage) |
| F13 | Quick-switcher icon is a paste glyph | implemented (batch 5), diff-reviewed |
| F14 | Health banner a11y label says "Tap" | implemented (batch 2), diff-reviewed |
| F15 | Catalog sort case-sensitive raw path | implemented (batch 5, localizedStandardCompare), diff-reviewed |
| F16 | Editor unbounded line length | implemented (batch 5, 72ch centered measure), diff-reviewed |
| F17 | Redundant caption on root notes | implemented (batch 5), diff-reviewed |
| F18 | Broken Links rows lack click affordance | implemented (batch 5, chevron), diff-reviewed |
| F19 | iOS editor unstyled — document as known gap | implemented (batch 5, NOTES.md), diff-reviewed |
| F20 | Double back-chevron in macOS title bar | deferred — app-shell navigation, not Notes; revisit separately |

## Regressions found in visual verification (fixed by Claude)
- **Crash on Return/Escape in wikilink popup** (batch 4 regression): `ForEach(indices, id: \.self)` + stale index subscript in `WikilinkCompletionOverlay` trapped when accept/dismiss emptied the array mid-update. Fixed: identity on `note.relativePath` via enumerated pairs. Crash log evidence: SwiftClaw-2026-07-16-022207.ips (Array._checkSubscript in completionList line 289).
- **Snippet display** (F5 follow-up): FTS5 window included the match but line-limited rows cut it off → `HybridSearcher.collapsedToSingleLine` flattens snippets; unit-tested.
- **Potential layout spin** (batch 5 risk): `CenteredMeasureScrollView.layout()` unconditionally set `textContainerInset`, which invalidates layout → possible full-CPU loop (a verify run saw the app unresponsive at ~75% CPU). Fixed with an equality guard. Root cause of the observed hang not 100% attributed — watch for recurrence.

## Verification status
- Full macOS test suite: GREEN end-to-end on the final tree (including the new NoteEditorViewKeyboardTests). iOS build: GREEN.
- Visually confirmed on macOS: switcher icon (v01), caret-anchored popup with highlighted first row incl. flip-above (v04), broken-links chevron (v08), search threshold=1 result (v07), redundant captions hidden + margins correct-at-narrow (v03), revisions content preview (w03), flattened single-line snippet with threshold (w04), quick-capture menu checkmark (w01).
- Visually confirmed on iOS (idb taps + simctl screenshots): backlinks Done + dismissal (vi01), quick-capture top-aligned layout with labeled Save (vi02), settings without Reveal in Finder (vi03), onboarding folder picker presents + cancels (vi04); notes list also shows switcher icon, hidden redundant captions, localizedStandardCompare ordering.
- Wikilink keyboard path (F7): hosted integration tests, not GUI — see F7 row for the codex-input diagnosis.

## Decisions & constraints
- Implementation via `codex exec -m gpt-5.6-sol -c model_reasoning_effort=medium -s workspace-write`, sequential batches (shared files, no worktrees needed).
- Codex must not commit/push; verification per batch = focused Notes test suites + build.
- UX/a11y wins over strict HIG when they conflict (user directive from the review request).
- F20 deferred: the extra back chevron comes from Workspace's NavigationStack + the app's custom history controls in ContentView, outside Notes scope.

## Files touched
- SwiftClaw/Features/Notes/NotesOnboardingSheet.swift — iOS .fileImporter folder picker + shared configureExternalVault (F1)
- SwiftClaw/Features/Notes/BacklinksPanel.swift — optional Done button in header (F2)
- SwiftClaw/Features/Notes/NotesView.swift — inspector sites pass onDismiss + presentationDragIndicator (F2)
- SwiftClaw/Features/Notes/QuickCapture/NotesQuickCaptureControl.swift — labeled iOS save button; sheet top-aligned (F12)
- SwiftClaw/Settings/Sections/NotesSettingsView.swift — Reveal in Finder behind #if os(macOS) (F11)
- SwiftClawTests/Notes/NoteEditorViewKeyboardTests.swift — NEW: hosted-NSTextView integration tests for the wikilink popup keyboard path (F7 verification)
