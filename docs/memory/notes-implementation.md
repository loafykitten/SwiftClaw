# Notes feature implementation

**Started:** 2026-07-13  **Status:** in progress

## Goal

Ship the Notes markdown-vault feature per `docs/NOTES_PLAN.md`: configurable
vault (app-managed or external Obsidian-compatible folder), styled-source
editor + reading mode, hybrid local FTS5+embedding search, always-allowed AI
read/search tools, AI edits gated behind proposal diff cards, plus wikilinks/
backlinks, quick capture + daily note, fuzzy switcher, Workspace tile, and a
scheduled review service.

## Current state

Plan approved and committed (`docs/NOTES_PLAN.md`). Branch: `feature/notes`
(cut from main after the Reminders fast-forward). Existing scaffold:
`NotesView`/`NotesSettingsView` placeholders, `settings.notes.enabled` key,
`WorkspaceSection.notes`.

Phase 1 shared file utilities are done and passing (`SwiftClaw/Services/Files/`:
`SecurityScopedBookmarkStore` — @MainActor, injectable `UserDefaults`, stale
re-save, `ScopedURL` balances start/stop-access on deinit;
`FSEventStreamMonitor` — `#if os(macOS)`, `@unchecked Sendable` +
`nonisolated` (module default actor isolation is MainActor, so this needed
explicit `nonisolated` on the class), wraps `FSEventStreamRef` →
`AsyncStream<Event>`, idempotent `stop()`; `AtomicFileWriter` — `nonisolated
enum`, temp-write + `replaceItemAt`/`moveItem`). Tests in
`SwiftClawTests/Files/` (`SecurityScopedBookmarkStoreTests`,
`AtomicFileWriterTests`, one real-FSEvents integration test in
`FSEventStreamMonitorTests` — races stream iteration against a 10s timeout,
matches on directory name rather than full path since FSEvents reports
symlink-resolved paths, e.g. `/private/var/...` vs the `/var/...` the temp
dir was created under). All three suites pass via `-only-testing:`; full
build succeeds. Note: the project's `SWIFT_DEFAULT_ACTOR_ISOLATION` is
`MainActor` — anything meant to run off the main actor needs an explicit
`nonisolated`.

Phase 1 vault layer is done and passing (`SwiftClaw/Services/Notes/Vault/`):
`VaultConfiguration.swift` — `VaultLocation { appManaged | external(bookmarkKey)
}` + `@MainActor VaultConfigurationStore` (injectable `UserDefaults`/
`FileManager`/entitlement check/ubiquity-container lookup); `vaultID` is a
persisted UUID string keying `revisionsDirectory()`/`indexDirectory()` under
`App Support/SwiftClaw/Notes/...` (same convention as
`EmailAttachmentStore.defaultRootDirectory`); `resolveAppManagedRoot()` picks
the ubiquity container only when *both* entitled and a container URL actually
resolves, else falls back to App Support — never blocks on iCloud.
`NotesVault.swift` — `actor`, sole file-touching type: `enumerate`/`read`/
`write(relativePath:content:expectedHash:)`/`rename`/`delete`, all wrapped in
a `withScope` bracket around an injectable `ScopeAccessor` (`nil` for
app-managed, resolves a `ScopedURL` for external vaults). Path safety: two
separate root-comparison strings are needed — `standardizedRootPath` (plain
`.standardizedFileURL`, no symlink resolution) for the traversal/absolute-
escape check against `resolveURL`'s candidate (which is built the same
unresolved way), and `resolvedRootPrefix` (`.resolvingSymlinksInPath()`) only
for the symlink-escape check against an *existing* file's resolved parent —
mixing the two breaks on `/var` → `/private/var`-style temp-dir symlinks
(same gotcha `FSEventStreamMonitorTests` already hit). `write`'s hash guard:
re-hashes the on-disk file immediately before writing (never trusts a
caller-cached hash); nil `expectedHash` means create-only (matches only if no
file exists yet); any mismatch — including the create-only collision case —
writes the *attempted* content to a `Name (conflict <timestamp>).md` sibling
and leaves the on-disk file untouched (never invents which side "wins").
`delete` uses `FileManager.trashItem`. `VaultIgnoreRules.swift` — dot-prefix
check covers dotfiles/dirs (`.obsidian`, `.git`) and non-`.md`/`.tmp` filter.
`NoteRevisionStore.swift` — `actor`, content-agnostic `[key: String →
[NoteRevision]]`; per-key subdirectory name is the SHA-256 hex of the key
(sidesteps sanitizing arbitrary keys like vault-relative paths into
filesystem-safe names); revision id is a zero-padded-millisecond UTC
timestamp + injectable random suffix (sortable, and the timestamp is
re-parsed from the id for prune decisions instead of relying on real file
mtimes, so pruning stays testable under an injected `clock`); prune enforces
50-per-key and 30-day caps independently in one pass. `VaultReconciler.swift`
— `actor`; `start(events: AsyncStream<Void>, onDelta:)` takes a
*payload-stripped* hint stream (the FSEvents→`Void` mapping is the caller's
job, keeping the reconciler decoupled from `FSEventStreamMonitor` specifics)
and debounces via a cancel-and-reschedule `Task` per hint; `rescanNow()` is
the full-scan fallback — always cancels any pending debounced rescan and
performs exactly one immediate scan via an injectable `StateProvider`
returning `[VaultEntry(relativePath, sha256)]`. Rename pairing only fires
when a removed path and an added path are each the *sole* candidate sharing
a content hash — ambiguous multi-candidate hash matches are left as separate
add/remove rather than guessed. No baseline-suppression: the very first
`rescanNow()`/event-triggered scan against an empty `knownState` reports the
whole existing vault as `added` (repository/bootstrap layer is expected to
either treat that as its initial catalog or call `rescanNow()` once before
wiring up UI-visible delta handling).

Tests in `SwiftClawTests/Notes/`: `NotesVaultTests` (byte-equal round trip,
conflict copy with original intact, create-collision non-clobber, rename +
no-clobber, ignore-rule enumeration, path-traversal rejection, delete),
`NoteRevisionStoreTests` (round trip, per-key isolation, newest-first order,
50-cap prune, 30-day prune — all via injected clock/id-suffix sequences, no
wall-clock dependency), `VaultReconcilerTests` (debounced single rescan,
burst coalescing, fallback catching a change the event stream never signaled,
unique-hash rename pairing, ambiguous-hash non-pairing, in-place modify).
Full suite + full build both green.

Phase 1 repository + settings package is done and passing
(`SwiftClaw/Services/Notes/Repository/`): `NotesRepository.swift` — `@MainActor`
sole mutation boundary (per `ReminderRepository`), dependency-injected with
`NotesVault`/`NoteRevisionStore` so tests use temp roots; in-memory
`[NoteSummary]` catalog kept sorted by `relativePath` (stable identity;
`title` is filename-derived display-only, never identity); `reload()` does a
full enumerate+read bootstrap and **never** posts `.notesStoreDidChange` —
that's initial hydration, and it's also the baseline a reconciler's first
empty-`knownState` full scan would otherwise re-report as "added" for every
file; `apply(delta:)` folds a `VaultReconciler.ReconcileDelta` in (renamed
pairs update identity in place without a re-read since the hash is already
known to match; added/modified are re-read from the vault, never trusted from
the delta's hash; removed paths drop their entry) and posts the notification
only when something actually mutated; `create(title:folder:)` sanitizes via
`NotesFilenameSanitizer` (strips `/\:` + control chars, trims leading dots so
a sanitized name can never land hidden per `VaultIgnoreRules`, "Untitled"
fallback, subfolder kept only when relative/traversal-free/non-dot-prefixed)
and tries " 2", " 3", … suffixes, pre-checking each candidate with the new
`NotesVault.exists(relativePath:)` (added to `NotesVault.swift` — the
"narrowly scoped existence API" the plan anticipated, keeping `NotesVault` the
sole file-touching type) so a foreseeable collision never burns `write`'s
conflict-copy fallback; a stray `.conflict` outcome from a create-only race
is discarded and the next suffix tried, never accepted as the created note.
`save`/`rename`/`delete` all snapshot pre-mutation content via
`NoteRevisionStore.snapshot(key: relativePath, ...)` before mutating (`save`
skips the snapshot only when nothing exists yet at that path);
`save`'s hash-mismatch path adds the conflict copy to the catalog (original
entry left untouched) and throws `NotesError.externalConflict(copyPath:)`.
`NotesError.swift` — `LocalizedError` enum, `.from(_:)` reuses an existing
`LocalizedError` message when wrapping a `NotesVault`/`NoteRevisionStore`
error rather than a generic fallback.

Settings (`SwiftClaw/Settings/AppSettings.swift`): the 8 plan keys added
under a new "Notes keys" section; `notesVaultLocationType`/
`notesVaultBookmarkKey` are two separate top-level keys (not one JSON blob)
so `SettingsStorage.saveNotesVaultLocation(.appManaged)` is a plain
write-type+clear-bookmark-key operation — `loadNotesVaultLocation` falls back
to `.appManaged` if `"external"` is set with no bookmark key saved (hand-edited
defaults edge case). `VaultConfigurationStore.vaultID` (in
`Services/Notes/Vault/VaultConfiguration.swift`) now reads/writes
`SettingsKeys.notesVaultID` instead of its old private hard-coded defaults
key — one source of truth, per this package's task. Defaults: daily-note
folder "Daily Notes", default-new-note folder `nil` (vault root), review
interval 24h (0 = manual), embeddings on by default.
`SettingsNotifications.notesReviewScheduleDidChange` added next to the
Calendar/Reminders equivalents; `Notification.Name.notesStoreDidChange` lives
with `NotesRepository.swift` itself (per `ReminderRepository`'s
`reminderStoreDidChange` convention — store-did-change lives with the
repository, review-schedule-did-change lives in `SettingsNotifications`).

Entitlement added: `com.apple.security.files.user-selected.read-write` in
`SwiftClaw.entitlements` (re-signs the debug build — voids the Accessibility
grant for computer-use verification only, per the plan's documented caveat;
unit tests/manual checks unaffected).

Tests: `SwiftClawTests/Notes/NotesRepositoryTests.swift` (reload/catalog
sort, partial-load-failure skip-and-surface, delta apply for
added/modified/removed/renamed incl. the empty-delta no-op/no-notify case,
filename sanitization + Untitled fallback + deterministic suffix collisions
+ safe/unsafe subfolder handling, revision-before-save/rename/delete,
external-conflict-throws-with-original-intact-and-copy-cataloged, save
updates the catalog summary) — the notification-assertion tests need
`@Suite(.serialized)` since `NotificationCenter.default` is a shared global
and Swift Testing runs a struct's `@Test`s in parallel by default, which was
cross-contaminating the "no notification posted" assertions with posts from
concurrently-running sibling tests in the same suite.
`SwiftClawTests/Notes/NotesSettingsStorageTests.swift` (defaults, vault
location round-trip + stale-bookmark-key cleanup + external-without-bookmark
fallback, folder helpers, review interval incl. 0-is-preserved, embeddings
toggle, `VaultConfigurationStore.vaultID` now reads through the shared
settings key). All Notes/Files suites + full build green.

Phase 1 UI package is done and passing
(`SwiftClaw/Features/Notes/NotesFeatureModel.swift`,
`NoteEditorModel.swift`, `NotesOnboardingSheet.swift`, rewritten
`NotesView.swift`, rewritten `Settings/Sections/NotesSettingsView.swift`):
`NotesFeatureModel` — `@MainActor @Observable` singleton
(`.shared`, per `MailSyncMonitor.shared`/`EmailManualSyncCoordinator.shared`
— both `NotesView` and `NotesSettingsView` consume the same instance so
there's exactly one vault watcher/reconciler per launch, not one per view);
owns `VaultConfigurationStore`/`SecurityScopedBookmarkStore` plus the
configured `NotesVault`/`NotesRepository`/`VaultReconciler`/
`FSEventStreamMonitor` for whichever `VaultLocation` is active. `activate()`/
`deactivate()` are reference-counted (`activeCount`) so either view's
`.task`/`.onDisappear` toggling the shared instance's "visible" state doesn't
stop the other's periodic rescan; `activate()` no-ops entirely under
`ProcessInfo.processInfo.isRunningInPreview` (construction alone never
touches disk/Keychain/bookmarks — all of that is deferred into `activate()`/
onboarding actions). Full rescan wiring: `configure(location:)` builds a
`VaultReconciler` whose `StateProvider` does `vault.enumerate()` +
`vault.read(relativePath:)` per path for hashes (no lighter-weight hash-only
vault API exists; acceptable at personal-vault scale, documented as a
low-confidence tradeoff, not optimized here) and starts it against an
FSEvents-hint `AsyncStream` (macOS only) plus an `NSApplication.
didBecomeActiveNotification` observer (app-activation rescan) and a 300s
periodic `Task` loop gated on `activeCount > 0` (visible-while-Notes-is-open
rescan). Reconcile handling explicitly does **not** touch the open editor's
`expectedHash` — it calls `editor.handleExternalChange()`, which is itself a
no-op while the editor is dirty (see `NoteEditorModel` below); a rename of
the selected note retargets `selectedPath`/`editor.selectedPath` without
discarding in-progress edits.

Vault-change safety: `chooseAppManagedVault()`/`chooseExternalVault(url:)`
both funnel through `applyNewVaultLocation`, which tears down the current
vault/watcher, calls the new `VaultConfigurationStore.regenerateVaultID()`
(added this package — old getter only generated-once-then-cached; changing
vaults now always mints a fresh ID so revisions/index never collide with a
previous vault), persists the new `VaultLocation` +
`notesHasCompletedOnboarding = true`, and removes the *previous* bookmark
only if it's not the one just adopted. `resetVaultConfiguration()`
disconnects (clears location/bookmark/onboarding-completed keys, removes the
bookmark) but never touches vault file contents — matches the plan's "Reset
means disconnect, not delete." External-vault `scopeAccessor`/FSEvents-watch
bookmark resolution is done via `[weak self]` + `MainActor`-isolated calls,
never by capturing `SecurityScopedBookmarkStore` itself in the `@Sendable`
`NotesVault.ScopeAccessor` closure — that class isn't `Sendable` and the
codebase's established weak-self exception (`EmailManualSyncCoordinator`)
is what makes the cross-actor hop compile under Swift 6 strict concurrency.

`NoteEditorModel` — `@MainActor @Observable`, one instance per configured
vault (owned by `NotesFeatureModel`), holds the interim `TextEditor`'s
loaded baseline (`loadedContent`/`expectedHash`), live `editedText`,
`isDirty`, and `conflictBanner`. The hash invariant the plan called out:
`expectedHash` is written *only* by `load` (on select, or a reconcile reload
of a clean note) and `save` (on success) — `handleExternalChange()` is a
no-op whenever `isDirty`, so a reconciled catalog hash can never silently
replace the hash the editor actually loaded while an edit is in flight.
Autosave is a cancel-and-reschedule `Task` at ~1.5s idle (`VaultReconciler`'s
debounce pattern); `flushPendingSave()` (unconditional, not debounced) is
called on selection change (`select(path:)` calls it before switching) and
on the editor view's `.onDisappear`. On `.externalConflict`, editor text and
`expectedHash` are deliberately left exactly as they were (nothing lost — the
attempted content already landed at the vault's conflict-copy path) and
further *idle-debounced* autosaves are frozen (`isAutosaveFrozen`) so the
same stale hash doesn't mint a fresh conflict copy every debounce cycle
while the banner sits unread; explicit flushes (selection change, disappear)
still fire regardless, so a last edit is never silently dropped. This
freeze-idle-but-not-explicit-flush behavior is a judgment call, not
plan-mandated — noted as the package's main low-confidence design decision.

`NotesOnboardingSheet` — two option cards (create app-managed vault / choose
existing folder, explicitly captioned "works with Obsidian vaults") +
`NSOpenPanel` + `SecurityScopedBookmarkStore.save(url:forKey:)` under a
`"notes.vault.bookmark.<uuid>"` generated key, plus a "Not Now" escape hatch
— matches `CalendarOnboardingSheet`'s card/interaction style and its
`@AppStorage(...HasCompletedOnboarding)` gating convention exactly (new key
`SettingsKeys.notesHasCompletedOnboarding`, `AppSettings.swift`).

`NotesView` — `NavigationSplitView`: list column has `.searchable` title
search (case-insensitive `localizedCaseInsensitiveContains` on `title`, not
`relativePath`) + a toolbar "New Note" button
(`NotesFeatureModel.createNote()`, which reads
`SettingsStorage.loadNotesDefaultNewNoteFolder()` and selects the created
note); selection `Binding` is `String?` path identity, matching
`NoteSummary.id`. Detail column is the interim `TextEditor` bound through
`NoteEditorModel.editedText`/`textDidChange(_:)` — an intentional Binding
loop, the plan's explicitly-allowed exception for *this* interim editor only
(Phase 2's NSTextView controller must not repeat this pattern). Conflict
banner is a dismissible, non-modal bar naming the copy path; empty/loading/
error states are separate `FeaturePlaceholderView`/`ProgressView` branches
with accessibility labels.

`NotesSettingsView` — Vault section (Location/Path `LabeledContent` +
Change…/Reveal in Finder/Reset… actions, Reset behind a `confirmationDialog`
warning that files aren't deleted) always shown when Notes is enabled, even
unconfigured (its footer explains how to get started); Stats/Defaults/AI
Review sections only render once `configurationState == .configured`.
"Change…" reopens `NotesOnboardingSheet`; "Reveal" uses
`NSWorkspace.shared.activateFileViewerSelecting`, bracketing external-vault
access in a `withExtendedLifetime` scope.

Repository addition: `NotesRepository.read(relativePath:) async throws ->
NoteFileSnapshot` (delegates to `NotesVault.read`, wraps errors via
`NotesError.from`) — the plan's "if the repository lacks a read method, add
one" instruction; `NoteEditorModel` goes through this, never touching
`NotesVault` directly.

Tests: `SwiftClawTests/Notes/NoteEditorModelTests.swift` (load/select
clears dirty, typing doesn't touch disk before autosave fires, idle autosave
writes after the debounce delay, selection change flushes a pending dirty
edit, flush is a no-op when clean, external change reloads when clean,
external change is a full no-op while dirty — text *and* hash untouched,
conflicted save keeps editor text + surfaces the copy path with both sides
of content verified on disk, dismissing the banner doesn't discard text,
clearing selection resets state) and
`SwiftClawTests/Notes/NotesFeatureModelTests.swift` (activate with no prior
onboarding never creates a repository, app-managed vault choice configures
an empty repo + persists onboarding, external vault choice saves a bookmark
+ configures — path assertion compares by last path component only, since a
resolved bookmark goes through `/private/var/...` while
`resolvingSymlinksInPath()` on the plain temp URL stops at `/var/...`, the
same symlink gotcha `FSEventStreamMonitorTests` already documented; changing
from app-managed to external regenerates `vaultID`; creating a note then
resetting disconnects configuration but leaves the `.md` file on disk;
selecting a note through the model drives the shared editor). Both new
suites are `@Suite(.serialized)` and marked with a comment explaining why:
they exercise real `NotesRepository` mutations that post the shared/unscoped
`.notesStoreDidChange` to `NotificationCenter.default`, which was racing
`NotesRepositoryTests`' pre-existing "no notification posted" assertions
once run concurrently in the same test process — serializing both new
suites (not `NotesRepositoryTests`, left untouched) resolved it; a full
unfiltered `xcodebuild test` run confirmed no flakiness across the whole
target, run twice.

A temp-directory `FileManager` subclass
(`TempApplicationSupportFileManager`, test-file-local) overrides
`.applicationSupportDirectory` so `VaultConfigurationStore`'s app-managed
vault/revisions paths in `NotesFeatureModelTests` never touch the real
`~/Library/Application Support` on the machine running tests.

All ten Notes/Files suites and a full unsigned build are green after the final
review fixes. An earlier full unfiltered `SwiftClawTests` run also passed.

## Review fixes (2026-07-13)

Addressed the Phase 1 implementation review without changing Phase 2+ scope:

- `NotesVault` now rejects symbolic-link files for read, write, and existence
  probes; enumeration skips every symbolic link, including Markdown links
  that point outside the vault. The existing directory-symlink escape and
  loop behavior remains covered.
- `NoteEditorModel` generations each selection so stale load successes and
  errors cannot replace a newer selection. A successful save that observes a
  later edit schedules another idle autosave after the in-flight coalesced
  save completes.
- Vault teardown now awaits reconciler stop and invalidates old reconciler
  callbacks with a configuration generation before a new repository can be
  configured. Reset is async so it follows the same teardown path.
- `NotesSettingsView` activates the shared feature model only while Notes is
  enabled and balances its reference on disable or disappearance.
- Added focused regression coverage to `NotesVaultTests`,
  `NoteEditorModelTests`, and `NotesFeatureModelTests`. The editor races use
  a test-only scoped-operation gate to force their ordering.
- Final independent review fixes keep dirty editor text visible after ordinary
  save failures or external deletion, block selection changes until a failed
  save succeeds, and publish repository catalog changes through observable
  `NotesFeatureModel.notes` state so both the list and Settings stats refresh.
- The authoritative ten-suite Notes/Files test run and unsigned macOS build
  pass. Computer Use reached the expected re-signing caveat and stopped with
  `Computer Use was not approved to use SwiftClaw`; no macOS permission was
  changed.

`git diff --check` and `swiftc -parse` pass for the touched production and
test sources. Per the task constraint, no `xcodebuild` command was run in
this sandbox; the root orchestrator should run the authoritative tests.

## Phase 1 visual editor follow-up (2026-07-13)

Moving New Note to an explicit `.primaryAction` toolbar item was disproved by
the supplied wide screenshot: the button moved to the trailing toolbar around
x=1065, but the note text stayed around x=549 while the inner list/detail
separator was around x=339. The resulting ~210 px gap matches the outer app
sidebar width, so it is not caused by the toolbar item or `TextEditor` margins.
The earlier safe-area attempt remains reverted, and the previously failed
`.ignoresSafeArea`, `.textEditorStyle(.plain)`, and `.contentMargins` workarounds
remain absent.

The cause is a nested navigation container: `NotesView` put its own
`NavigationSplitView` inside `ContentView`'s outer `NavigationSplitView`, so
the outer leading sidebar reservation was applied again to the Notes detail.
On macOS, `NotesView` now uses a native resizable `HSplitView` with a 220–360 px
list pane (280 px ideal) and a 400 px minimum detail pane. This preserves the
list selection, search, Notes title, detail editor, and trailing New Note
primary action without creating a second navigation container. The
`NavigationSplitView` remains as the planned non-macOS fallback.

`swiftc -parse SwiftClaw/Features/Notes/NotesView.swift`, `git diff --check`,
and the unsigned macOS build pass for this update. Computer Use and direct
screenshot inspection pass at both tested sizes: the 1021x450 capture has a
separator near x=560 and text near x=573; the 1007x768 capture has a separator
near x=432 and text near x=445. The resulting 13 px editor inset replaces the
former 210–215 px gap with normal padding, while the list, editor, New Note,
and Search notes controls remain visible without clipping or overlap. Evidence:
`/tmp/swiftclaw-hsplit-final-narrow.jpeg` and
`/tmp/swiftclaw-hsplit-final-wide.jpeg`.

## Next steps

Phases 1 and 2 are complete. Resume with Phase 3 (`## Phase 3 — Index &
search, backlinks, quick switcher, vault health`). Phases 4–7 remain after
Phase 3.

Phase 2 summary: `Package.swift` + the Xcode project's package references
(both `Package.resolved` lock files updated) now pull in
`apple/swift-markdown` (`branch: main`, matching the `OpenAI` dependency's
convention — swift-markdown has no semver tags, only dated snapshot tags).
`SwiftClaw/Services/Markdown/` (shared, no Notes types): `MarkdownDocument.swift`
parses only the *body* past any front matter (handing YAML-ish front-matter
lines to cmark itself risks misparses — a `key: value` line immediately
followed by the closing `---` reads as a Setext heading underline — so
front matter is sliced off before parsing and never handed to `Document
(parsing:)`), exposes `headings`/`excludedRanges` (front matter + fenced/
indented code blocks + inline code spans) via a `SourceLocation`→
`String.Index` `OffsetConverter` that accounts for the front-matter byte
offset; `FrontMatterBlock.swift` is a byte-preserving, line-based `---`
block parser (no YAML lib) — `settingValue(_:for:)` replaces/appends only
one key's line, `tags` reads both inline (bracketed/comma, quote-stripped)
and YAML dash-list forms; `MarkdownRenderedView.swift` +
`MarkdownInlineFlowView.swift` + `NoteAsyncImageView.swift` render reading
mode via `swift-markdown`'s tree (headings/paragraphs/emphasis/strong/
strikethrough/lists incl. checkboxes/tables/fenced+inline code/thematic
breaks/`> [!kind]` Obsidian callouts approximated by sniffing the quote's
first line) — since `swift-markdown`/SwiftUI both export `Text`/`Link`/
`Image`/`Table`, those cases are qualified `Markdown.X`; Obsidian wikilinks/
embeds aren't real CommonMark so a small regex scanner
(`WikilinkTextScanner`) finds `[[page|alias]]`/`![[embed]]` inside plain
`Text` runs, and per-substring tap targets work by building an
`AttributedString` with a same-app-only `swiftclaw-wikilink://` URL scheme
as the `.link` carrier (SwiftUI's `Text` makes `AttributedString` links
tappable natively — this avoids the "one `onTapGesture` per whole merged
Text" limitation). Images (including embeds) load only through a caller-
supplied `loadImage` closure, never `FileManager` directly — backed by a new
narrow `NotesVault.readData(relativePath:)` / `NotesRepository.readData
(relativePath:)` (raw `Data`, no UTF-8 decode, reusing the same
`resolveExistingURL` path-safety checks as `read`).

`SwiftClaw/Features/Notes/Editor/`: `NoteEditorController.swift` is the
Phase 2 replacement for `NoteEditorModel` (deleted, along with
`NoteEditorModelTests.swift` — replaced by `NoteEditorControllerTests.swift`,
`NoteEditorModel` is fully gone, no two competing editor owners). Same
hash/dirty/autosave invariants as Phase 1, plus: `currentText` is the
controller's own authoritative copy, updated one-way from the live editor's
`textDidChange(_:)` callback and pushed the other direction only through an
`applyText: ((String) -> Void)?` closure the view layer wires up in
`makeNSView` — SwiftUI itself never holds the document in `@State`/
`Binding`. Reconcile handling is upgraded: clean → reload (unchanged); dirty
→ `externalChangeChoice` (a non-modal bar), freezing autosave until resolved.
`keepMine()` saves the buffer anyway (expected to lose the hash race,
landing at a conflict copy while the external file stays untouched) and then
explicitly reloads the fresh external content so the editor ends up
coherent instead of sitting on a stale buffer that would mint another
conflict copy on the next autosave — this reuses the exact same
`ConflictBanner` UI as an ordinary autosave conflict. `takeTheirs()` discards
the buffer and reloads, never saving. `NoteEditorView.swift` is
`NSViewRepresentable` on macOS: `makeNSView` builds the `NSTextView`/
`NSScrollView`, attaches `MarkdownSourceHighlighter` as the text storage's
delegate *before* the first content assignment (so even the initial load is
styled through the same path as every later edit), and wires
`controller.applyText` to `textView.string = text`; `updateNSView` is
deliberately empty. The non-macOS fallback is a plain `TextEditor` +
`Binding` (an intentional, documented exception — no NSTextView-equivalent
exists there yet; real iOS work is future, out of this package's scope).
`MarkdownSourceHighlighter.swift` is an `NSTextStorageDelegate`
(`nonisolated` conformance + `MainActor.assumeIsolated`, since `NSTextStorage`
only calls this on the thread already driving the text view, and Swift 6
requires `nonisolated` on ObjC-protocol conformances regardless — same
pattern as `EmailQuickActionSwipe`'s gesture delegate): paragraph-scoped
restyling normally, widened to end-of-document when the edited paragraph is
a fence delimiter line (```` ``` ````/`~~~`), via a `FenceStateMachine` that
recomputes per-line fence state from scratch on every edit (cheap at
personal-note scale, always correct even when a fence toggled earlier in the
doc). Attributes-only — a `DEBUG` `assert` checks `textStorage.string` is
byte-identical before/after every restyle. `isStyling` guards against
re-entrant `didProcessEditing` calls from the attribute writes themselves.
`MarkdownEditorTheme.swift` holds colors/fonts; `.current` picks a fully
opaque high-contrast palette over the normally-translucent one whenever
`NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast` is on (user
instruction: UX/accessibility over strict HIG/Liquid Glass when they
conflict) — `nonisolated` throughout since the highlighter reads it from its
delegate callback.

`SwiftClaw/Features/Notes/Reading/NoteReadingView.swift`: renders
`editor.currentText` (not strictly "last saved" — the live buffer, so
switching to Read mode never requires saving first) via
`MarkdownRenderedView`; wikilink taps resolve against `model.notes` by exact
path or title match (approximate — Phase 3's link graph replaces this);
images try vault-root-relative then note-folder-relative paths through
`NotesRepository.readData`. `NotesView.swift` modified: Edit/Read toggle +
`Cmd-E` in the toolbar (shown only when a note is selected), detail column
routes through `NoteEditorController`/`NoteEditorView`/`NoteReadingView`
instead of the interim `TextEditor`, a new non-modal Keep Mine/Take Theirs
bar for `externalChangeChoice`, and the macOS `HSplitView` layout is
untouched. `NotesFeatureModel.swift` modified: `NoteEditorModel` →
`NoteEditorController` throughout (routing/reconcile-delta wiring
unchanged).

Tests: `SwiftClawTests/Markdown/` (new) — `FrontMatterBlockTests` (byte-for-
byte corpus: unknown keys/comments preserved, a body thematic break never
mistaken for the closing fence, single-key replace, missing-key append,
CRLF preserved end-to-end, inline bracketed/comma tags, dash-list tags);
`MarkdownDocumentTests` (heading outline + source ranges incl. Unicode
content before a heading, excluded ranges for fenced/indented/inline code,
front matter excluded without producing bogus headings, inline code nested
in a heading both outlined and excluded); `MarkdownLosslessnessTests`
(`@MainActor`, macOS-only — an Obsidian-style corpus with callouts,
`[[page|alias]]`, `![[embed]]`, nested tags, front matter, and fenced code
through a live `NSTextStorage` + the highlighter, asserting `.string` is
byte-identical after the initial styling pass and after simulated typing/
deletion/fence-toggle edits — the highlighter is kept alive across each
edit since `NSTextStorage.delegate` is `weak`).
`SwiftClawTests/Notes/NoteEditorControllerTests.swift` replaces
`NoteEditorModelTests.swift`: same Phase 1 coverage (load/selection,
autosave, blur-flush-on-selection-change, ordinary conflict, save-failure
non-loss) renamed to the controller, plus new coverage for the external-
change choice bar (dirty → choice presented, not a silent no-op; idle
autosave stays frozen while pending), `keepMine()` (conflict copy created,
original untouched, editor ends up on the fresh external content, no repeat
conflict copies), and `takeTheirs()` (buffer discarded, external content
reloaded, nothing ever saved). `NotesFeatureModelTests.swift` updated
(`editedText` → `currentText`) — its existing delta-handling tests don't
happen to cover a dirty note hitting `handleExternalChange()`, so no
behavior assertions needed changing there.

Verification: `-only-testing:SwiftClawTests/Notes` (as given in the task
prompt) matches zero tests — Notes tests are individual Swift Testing
structs under that folder, not a class/suite literally named `Notes`, and
`PBXFileSystemSynchronizedRootGroup` doesn't create a group-level test
target filter `xcodebuild` can match on. Ran every Notes+Markdown suite by
name instead (`NotesVaultTests`, `NoteRevisionStoreTests`,
`VaultReconcilerTests`, `NotesRepositoryTests`, `NotesSettingsStorageTests`,
`NotesFeatureModelTests`, `NoteEditorControllerTests`,
`FrontMatterBlockTests`, `MarkdownDocumentTests`,
`MarkdownLosslessnessTests`) — all pass. Full unfiltered `xcodebuild test`
(the whole app, every suite) also passes with no regressions, and a full
`xcodebuild build` succeeds. `git diff --check` is clean.

Low-confidence decisions worth a second look before Phase 3:
- `NoteReadingView` renders `editor.currentText` (the live, possibly-dirty
  buffer) rather than strictly the last-saved content — chosen so Read mode
  never forces a save first, matching Obsidian's live-preview feel, but it's
  a judgment call the plan didn't spell out.
- Obsidian `[!kind]` callout detection and wikilink/embed resolution in the
  renderer are both string-sniffing heuristics scoped to Phase 2's rendering
  needs, not the real parser Phase 3's `WikilinkScanner`/`NoteLinkGraph` will
  need (source-range-aware, excluded-range-aware). Don't assume this
  renderer-local logic is reusable there without revisiting it.
- `MarkdownSourceHighlighter`'s inline styling (bold/italic/code/links) is
  independent regex passes over each line with no mutual-exclusion
  awareness (e.g. a `**bold `code`**` span could double-style) — acceptable
  per the plan's explicit "approximate styling" allowance, but worth a
  second look if it looks visually off in manual testing.
- `keepMine()`'s "reload the fresh external content afterward" behavior is
  this package's interpretation of "transition to a coherent state without
  repeated conflict copies" — the plan didn't fully spell out whether Keep
  Mine should leave the local buffer in place (frozen, like an ordinary
  autosave conflict) instead of reloading. Worth confirming against the
  intended UX during manual testing.

Older low-confidence decisions from Phase 1, still open:
- Post-conflict autosave freezing (idle-debounce paused, explicit
  save-on-selection-change/disappear still fires) is not explicitly
  plan-mandated — an alternative would be to keep autosaving unconditionally
  and accept repeated conflict copies.
- `VaultReconciler`'s `StateProvider` here does a full `enumerate()` +
  per-path `read()` (whole-content read, discarding content, just for the
  hash) every rescan; fine at personal-vault scale but would want a
  hash-only vault API before Phase 3 indexing runs at higher note counts.
- `NotesFeatureModel.shared` is a hand-rolled singleton (no DI container in
  this codebase) — matches `MailSyncMonitor.shared`/
  `EmailManualSyncCoordinator.shared` precedent, but means tests must
  construct fresh instances via the internal (non-`shared`) initializer,
  which they do.

## Phase 2 external review fixes (2026-07-13)

Resolved all four findings from the external gpt-5.6-terra high review without
broadening into Phase 3:

- **P1 data-loss race on clean external reload** (`NoteEditorController`):
  `handleExternalChange()`'s clean-note branch called `load`, whose
  `repository.read` await could suspend while the buffer was still clean; a
  keystroke landing during that suspension was previously clobbered
  unconditionally by the returned external snapshot, since only
  `selectionGeneration` was checked, not any per-edit state. Added
  `editGeneration` (incremented in every `textDidChange(_:)`); `load` now
  takes an optional `requireEditGeneration`, captured by
  `handleExternalChange()` immediately before the `await`. On return, if
  `editGeneration` no longer matches, the snapshot is discarded and
  `externalChangeChoice` is surfaced instead (via new shared helper
  `presentExternalChangeChoiceIfNeeded()`) — same outcome as if the edit had
  arrived a moment earlier. Ordinary loads (selection, Keep Mine, Take
  Theirs) pass `nil` and are unaffected — those are user-initiated buffer
  replacements, not a race with the buffer.
- **P1 data-loss on Keep Mine non-conflict failure** (`keepMine()`): the
  `catch let error as NotesError` branch previously called `await load(...)`
  (discarding/reloading the buffer) for *any* `NotesError`, not just a
  confirmed `.externalConflict` — so a revoked security scope or disk I/O
  error during the attempted save would silently reload external content
  over the user's buffer even though nothing was actually written anywhere.
  Now only the `.externalConflict` case clears `externalChangeChoice` and
  reloads; every other `NotesError` and the generic `catch` leave
  `currentText`/`isDirty`/`externalChangeChoice` untouched and just set
  `saveError`, so the choice bar stays up and retryable (Keep Mine again, or
  Take Theirs).
- **P2 reading mode rendered front matter** (`MarkdownRenderedView`): `body`
  was calling `Document(parsing: source, options: [])` on the raw source,
  including any leading `---` front-matter block, so its keys/delimiters
  rendered as text/headings. Added `MarkdownRenderedView.body(of:)` (slices
  past `FrontMatterBlock.range.upperBound`, matching the pattern
  `MarkdownDocument` already used for parsing) and switched `body` to parse
  that instead of `source` directly.
- **P2 fixed-width fence tracking** (`FenceStateMachine`): `recompute`
  previously tracked only the fence *character*, matching any line with
  `hasPrefix(String(repeating: marker, count: 3))` — so a 4-backtick opener
  incorrectly closed on any 3-backtick line inside its own content.
  `fenceOpener(of:)` now returns `(marker, runLength)`; a closer must match
  the same marker and have a run length at least as long as the opener's.
  `isFenceDelimiter` (used for widening the highlighter's restyle range) is
  unchanged in spirit — still permissive about trailing content — since that
  call site only needs "is this a fence-toggle line", not exact closer
  validation.

New regression coverage: `NoteEditorControllerTests.externalReloadRaceKeepsTypedEditsAndPresentsAChoiceInsteadOfClobberingThem`
(uses the existing `ScopeGate` test double to suspend the reconcile reload's
read mid-flight, types during the suspension, then unblocks — fails under the
old code since the snapshot used to win unconditionally),
`.keepMineNonConflictSaveErrorKeepsTheBufferAndLeavesTheChoiceRetryable` (uses
the existing `FailOnceScope` double to fail Keep Mine's save with a
non-conflict I/O error; asserts buffer/dirty/choice survive, `saveError` is
set, and no conflict copy exists on disk); new
`SwiftClawTests/Markdown/MarkdownRenderedViewTests.swift` (front matter never
appears in `body(of:)`'s output or in the parsed block tree; a body thematic
break that never opened front matter is left untouched); new
`SwiftClawTests/Markdown/FenceStateMachineTests.swift` (4-backtick opener
stays open across an inner 3-backtick line and both backtick/tilde variants
only close on a same-marker run at least as long as the opener's — these
construct `FenceStateMachine` directly and fail under the old
character-only-match implementation).

Verification: the four requested suites
(`-only-testing:SwiftClawTests/NoteEditorControllerTests`,
`.../MarkdownLosslessnessTests`, `.../MarkdownDocumentTests`, plus the new
`.../MarkdownRenderedViewTests` and `.../FenceStateMachineTests`, since the
new regression coverage for findings 3 and 4 lives in those new suites) all
pass. A full unfiltered `xcodebuild test` (every suite in the app) passes
with no regressions. A full unsigned `xcodebuild build` succeeds. `git diff
--check` is clean.

Files touched by this fix pass:
`SwiftClaw/Features/Notes/Editor/NoteEditorController.swift`,
`SwiftClaw/Services/Markdown/MarkdownRenderedView.swift`,
`SwiftClaw/Features/Notes/Editor/MarkdownSourceHighlighter.swift`,
`SwiftClawTests/Notes/NoteEditorControllerTests.swift` (2 new tests),
`SwiftClawTests/Markdown/MarkdownRenderedViewTests.swift` (new),
`SwiftClawTests/Markdown/FenceStateMachineTests.swift` (new).

Phase 2 is still **not** marked complete in `docs/NOTES_PLAN.md` — pending
follow-up review and Computer Use testing by the orchestrator, per the
existing "Next steps" below.

## Phase 2 keepMine race follow-up fixes (2026-07-13)

Resolved the two `NoteEditorController.keepMine()` races from the final
gpt-5.6-terra high follow-up review (the fence-state fix from the prior pass
was confirmed clean by that review, no change needed there):

- **P1 post-conflict reload race**: in the `.externalConflict` branch, when no
  edit happened *during the save itself* (`editGeneration == editGenerationAtSave`),
  the old code cleared `externalChangeChoice`/`isAutosaveFrozen` *before*
  `await load(...)`'s `repository.read` — so typing during that suspended read
  had nothing left guarding it, and the unconditional-apply `load` call
  clobbered the newer buffer with the external snapshot. Fixed by keeping the
  choice/freeze active across the read: `load` now returns a `Bool` (applied
  or not, `@discardableResult` for the other call sites that don't need it),
  and the reload passes `requireEditGeneration: editGeneration` (captured
  immediately before the call, same pattern `handleExternalChange()` already
  used). The choice/freeze are only cleared when `load` reports `true`; if a
  race discarded the snapshot, `load`'s existing `presentExternalChangeChoiceIfNeeded()`
  call is a no-op (choice/freeze were already active) so the newest buffer
  stays dirty and actionable. The pre-existing "edit happened during the save
  itself" branch (`editGeneration != editGenerationAtSave`, which already
  skipped the reload and kept everything frozen) was untouched — it wasn't
  part of this bug.
- **P2 unexpected Keep Mine success with in-flight typing**: the success path
  correctly left `currentText` newer than `loadedContent` (so `isDirty` stays
  true) when the user typed during the save, but it never restarted autosave
  after clearing `isAutosaveFrozen` — the newer buffer would sit dirty
  forever with nothing scheduled to save it. Added a `scheduleAutosaveIfNeeded()`
  call right after unfreezing, matching `performSave`'s existing success path.

New regression coverage in `NoteEditorControllerTests.swift`:
`keepMinePostConflictReloadRaceKeepsTheNewestTypingAndLeavesTheChoiceActionable`
(uses `ScopeGate(blockedCall: 4)` — call 1 is the initial select; Keep Mine
uses call 2 to snapshot the revision and call 3 for its guarded write, both
allowed through to hit the conflict; call 4 is the post-conflict reload's
read, suspended while a newer buffer is typed; asserts
the newest buffer survives byte-identically, stays dirty, the choice/banner
remain active naming the created copy, the external file is untouched, and
the conflict copy holds only the earlier pre-reload buffer) and
`keepMineUnexpectedSuccessWithInFlightTypingRestartsAutosaveForTheNewerBuffer`
(manufactures a pending `externalChangeChoice` via `handleExternalChange()`'s
dirty branch — which presents the choice with no repository call at all — so
the on-disk hash is never actually changed and Keep Mine's suspended save
subsequently succeeds; types newer content while that save is in flight;
asserts the newer text stays dirty immediately after, the choice clears with
no conflict banner, and the restarted idle autosave later flushes the newer
text to disk with no conflict copy).

Verification: `-only-testing:SwiftClawTests/NoteEditorControllerTests` passes
(both new tests plus all pre-existing ones in that suite). A full unfiltered
`xcodebuild test` (every suite in the app) passes with no regressions. A full
unsigned `xcodebuild build` succeeds. `git diff --check` is clean.

Files touched by this fix pass:
`SwiftClaw/Features/Notes/Editor/NoteEditorController.swift` (`load` now
returns `Bool`; `keepMine()`'s conflict branch and success branch updated),
`SwiftClawTests/Notes/NoteEditorControllerTests.swift` (2 new tests).

Phase 2 is still **not** marked complete in `docs/NOTES_PLAN.md` — pending
follow-up review and Computer Use testing by the orchestrator.

## Phase 2 concurrency resolution follow-up (2026-07-13)

Sonnet 5 began resolving the validated controller-concurrency findings but
exhausted its session mid-pass. The Sonnet-to-Terra fallback was completed by
inspecting those uncommitted edits rather than restarting Phase 2 or widening
scope into Phase 3.

- `NoteEditorController` now has observable private-set
  `isResolvingExternalChange`, set for the full Keep Mine or Take Theirs
  operation and cleared by `defer`, including conflict, ordinary error, and
  stale-selection exits. Both choices refuse a second resolution while it is
  true. Every `load` owns a fresh UUID request token; only the request that
  still owns `activeLoadID` may clear `isLoading`, including stale path/
  selection and edit-generation branches.
- Keep Mine leaves a non-conflict save failure retryable: the current buffer,
  dirty state, and external-change choice stay intact, while `saveError`
  explains the failure. Take Theirs now keeps that choice visible and frozen
  until its replacement read applies; a failed or stale read therefore
  remains retryable instead of removing the choice and its busy indication.
- `NotesView` disables both choice buttons during resolution and visibly says
  “Resolving…” with an accessibility label. The UI remains present for both
  resolution paths while their work is in flight.
- `NoteEditorControllerTests` now deterministically cover: a blocked Keep
  Mine with duplicate Keep Mine and Take Theirs attempts (exactly one
  conflict copy and coherent final state); non-conflict Keep Mine failure
  followed by a successful retry; retargeting during a suspended guarded
  post-conflict read (spinner clears, dirty text and choice remain); two
  overlapping selections (the older completion cannot clear the newer
  spinner); and a blocked Take Theirs (choice stays visibly busy/retryable
  until the guarded read settles).

Verification performed in this environment:

- `swiftc -parse` over the changed controller, Notes view, and controller
  tests: passed.
- `git diff --check`: passed.
- The requested focused controller test, full test, and unsigned build were
  all launched in the foreground with `DEVELOPER_DIR` and
  `CODE_SIGNING_ALLOWED=NO`, but each exited 1 before workspace resolution,
  compilation, or test discovery. Xcode failed while initializing host
  simulator services: `CoreSimulatorService connection became invalid`,
  `simdiskimaged` could not start, and `Connection refused`. This is an
  environment block, not an in-scope Notes failure; rerun the same three
  commands once CoreSimulator is available.

Files touched by this follow-up:
`SwiftClaw/Features/Notes/Editor/NoteEditorController.swift`,
`SwiftClaw/Features/Notes/NotesView.swift`,
`SwiftClawTests/Notes/NoteEditorControllerTests.swift`, and this memory file.

Phase 2 remains **not** marked complete in `docs/NOTES_PLAN.md`.

## Phase 2 save/choice serialization follow-up (2026-07-13)

Resolved the validated Phase 2 save/choice serialization findings without
starting Phase 3 or changing `docs/NOTES_PLAN.md`:

- `NoteEditorController.select(path:)` now rejects immediately while Keep
  Mine or Take Theirs owns a resolution. It leaves `selectedPath` unchanged
  and performs no flush, so `NotesFeatureModel.select` also leaves its
  `selectedPath` unchanged; the list binding reads that model value and
  naturally reverts. `flushPendingSave()` rejects for the same period, which
  also protects the editor view's blur/`onDisappear` save path from starting
  another write.
- Normal saves now have one tracked internal `SaveOutcome` task
  (`succeeded`, `externalConflict(copyPath:)`, or `failed`) carrying the
  captured content. Keep Mine and Take Theirs first join any save that was
  already suspended when the external-change choice appeared. No choice path
  directly calls `repository.save` outside this serialization boundary.
  Take Theirs never adds a write after that join; it guarded-reloads the
  external version. Keep Mine treats a joined success or a conflict copy for
  its exact captured buffer as already satisfied (reusing the success/banner
  state), and only starts one later serialized attempt when the earlier save
  was failed or held an older buffer. Newer typing remains dirty/actionable
  rather than being reloaded over.
- `performSave` no longer unfreezes an active external-change choice merely
  because a previously started normal save succeeded. The resolution itself
  clears the choice/freeze and restarts autosave when appropriate.
- Added deterministic `NoteEditorControllerTests` for blocked Keep Mine plus
  rejected selection/flush (then normal selection after release), blocked
  normal-save + Take Theirs (one possible original conflict copy, no second
  save/copy, external text loaded), and blocked normal-save + Keep Mine
  (joins the copy and keeps newer typing actionable). The `ScopeGate` now
  exposes its call count; comments/assertions account for
  `NotesRepository.save`'s snapshot read followed by guarded write.

Verification in this Codex workspace:

- `swiftc -parse SwiftClaw/Features/Notes/Editor/NoteEditorController.swift SwiftClawTests/Notes/NoteEditorControllerTests.swift`: passed.
- `git diff --check`: passed.
- Attempted the focused `xcodebuild ... -only-testing:SwiftClawTests/NoteEditorControllerTests` command with `DEVELOPER_DIR`, an unsigned build, and `xcbeautify`. It stopped before workspace resolution, compilation, or test discovery because this sandbox cannot connect to CoreSimulator: `CoreSimulatorService connection became invalid`, `simdiskimaged` was unavailable, and the service returned `Connection refused`. That is an environment block, not a test failure; rerun the focused suite (then host-context full/build verification) outside this sandbox.

Phase 2 remains **not** marked complete in `docs/NOTES_PLAN.md`.

## Phase 2 explicit-flush current-buffer preservation fix (2026-07-13)

Resolved the validated selection/flush data-loss race without starting Phase 3
or changing `docs/NOTES_PLAN.md`:

- `NoteEditorController.flushPendingSave()` now captures the current text and
  expected hash before every serialized save/join. When a joined outcome was
  for an older buffer — including when a concurrent flush captures B and only
  joins an in-flight save of A — it verifies the outcome preserved the exact
  captured buffer before treating it as final. Otherwise it loops to save the
  newer dirty buffer using the controller's then-current expected hash. An
  ordinary failure remains final only when it is for that exact capture. The
  loop only retries after awaiting a save/join; it exits on a selection/path
  change, external removal, or active external-choice resolution.
- Conflict banners now retain their captured buffer privately and are cleared
  when that buffer is no longer current, so an older copy cannot authorize
  selection after a later ordinary save failure. `flush` returns success only
  for a write of the exact current buffer; it returns false with a conflict
  banner only when that exact buffer reached a conflict copy. `select(path:)`
  also rechecks removal/resolution state after its suspended flush before
  accepting the banner-based navigation path.
- Added deterministic controller tests for a blocked save of buffer A followed
  by buffer B and a selection change: one where A succeeds and one where an
  external edit makes A conflict. Both hold B's subsequent save at a second
  gate to prove selection stays on A until B is written or copied. The conflict
  case confirms the external original remains intact and a conflict copy
  contains B (two distinct conflict copies are expected for A and B). A
  companion regression verifies an ordinary B save failure after an A copy
  retains the A selection instead of navigating through the stale banner.

Verification in this Codex workspace:

- `swiftc -parse SwiftClaw/Features/Notes/Editor/NoteEditorController.swift SwiftClawTests/Notes/NoteEditorControllerTests.swift`: passed.
- `git diff --check`: passed.
- The focused `xcodebuild ... -only-testing:SwiftClawTests/NoteEditorControllerTests`
  attempt stopped before workspace resolution, compilation, or test discovery:
  this sandbox cannot connect to `CoreSimulatorService`, `simdiskimaged` is
  unavailable, and Xcode reports `Connection refused` (exit 143). This is the
  known sandbox CoreSimulator block, not a controller-test failure; rerun the
  focused suite from the host context.

Phase 2 remains **not** marked complete in `docs/NOTES_PLAN.md`.

## Phase 2 Keep Mine joined-save completion ordering fix (2026-07-13)

Resolved the remaining blocked-normal-save + Keep Mine controller race:

- **Cause:** the normal flush checked only the transient
  `isResolvingExternalChange` flag after its awaited save. When the blocked A
  save completed, both the normal flush and Keep Mine were eligible to resume.
  If Keep Mine ran first, it correctly consumed A's conflict outcome, observed
  newer B typing, and returned (clearing that flag). The older normal flush
  then resumed, saw B no longer matched its captured A buffer, and looped into
  a second stale-hash save of B. That overwrote the banner with B's copy and
  added the unexpected vault calls/copy.
- **Fix:** Keep Mine and Take Theirs now capture the exact in-flight save task
  before exposing their resolving state, so their join remains owned even if a
  waiter cleans up the shared slot. Each resolution also advances a private
  generation. `flushPendingSave()` captures that generation before it starts
  and validates it both before and after every awaited save. A flush that
  predates a resolver therefore stops instead of retrying a newer buffer after
  the resolver has returned. The existing blocked test remains genuinely
  overlapping: A is held at its repository snapshot read, Keep Mine joins it,
  B is typed while both wait, and only then is A released.

Verification: `swiftc -parse` over the controller and controller tests, plus
`git diff --check`, pass. The focused Xcode suite still cannot start in this
sandbox because CoreSimulator/simdiskimaged is unavailable before test
discovery; host rerun is required.

## Phase 2 final review-finding resolution (2026-07-13)

Resolved the final controller-test deadlock and rechecked all four Sonnet
review fixes without changing Phase 3 scope or `docs/NOTES_PLAN.md`:

- **In-flight local-save reconcile guard:** `handleExternalChange()` now
  treats a successfully completed save it was already waiting for as this
  app's own notification and returns without an external-change choice. This
  stays true if newer local typing keeps the buffer dirty: that typing is not
  evidence of an external edit. If the observed save instead found a real
  external conflict, its completed `SaveOutcome` is retained only until the
  user chooses an action. Keep Mine reuses that exact conflict copy when it
  preserved the current buffer, avoiding a duplicate stale-hash write; Take
  Theirs still only reloads the external file.
- **Deterministic controller tests:** the two existing blocked-normal-save
  tests were the hanging cases. Each called `await handleExternalChange()`
  while deliberately holding the normal save at `ScopeGate` call #2, but the
  new guard correctly waits for that save. They now start reconciliation in a
  task, assert that no false choice appears while blocked, release the save,
  then assert the true external-conflict choice and exercise Take Theirs or
  Keep Mine. The Keep Mine test proves it reloads from the already-created
  copy with exactly four vault operations and no duplicate copy.
- **Ambient inline fonts:** `MarkdownInlineFlowView` continues to give only
  inline code an explicit monospaced font. Plain text, emphasis, strong,
  strikethrough, Markdown links, and wikilinks all inherit their heading or
  table-header font; styles use `inlinePresentationIntent`. Added link and
  wikilink inheritance assertions alongside the existing plain/bold/italic
  and code checks.
- **Reading image paths:** `NoteReadingView` correctly tries a note-folder
  candidate before its normalized vault-root fallback, collapses safe `.` /
  `..` segments lexically, deduplicates candidates, and rejects traversal
  above the vault root. Its focused tests cover folder priority, normalization,
  safe parent traversal, absolute paths, and vault escapes.
- **Async image state:** `NoteAsyncImageView` resets both the loaded image and
  failure state before every `.task(id: relativePath)` load. The small
  `NoteAsyncImageLoadState` helper keeps that state transition testable
  without a view-inspection dependency; a new test covers clearing an old
  image and a prior failure before the next path loads.

Real verification in this workspace:

- Passed: `swiftc -parse` over the controller, controller tests, inline
  renderer, async image view, reading view, and their focused tests.
- Passed: `git diff --check` and `git diff --cached --check`.
- Blocked before test discovery: foreground `xcodebuild` with
  `set -o pipefail`, `DEVELOPER_DIR`, `CODE_SIGNING_ALLOWED=NO`, and unique
  `/tmp` derived-data paths exits 143 immediately after sandbox-restricted
  Xcode startup (`confstr`/FSEvents; the initial attempt also reported an
  unavailable CoreSimulator service). Moving HOME and compiler module caches
  into `/tmp` did not change that result. The SwiftPM fallback is also blocked
  while compiling the manifest (`sandbox-exec: sandbox_apply: Operation not
  permitted`). No Xcode test — including the full
  `NoteEditorControllerTests` suite or the Markdown/NoteReading focused suites
  — was claimed as run here.

Next host-context verification, using unique derived-data paths and
`set -o pipefail`: run the complete `NoteEditorControllerTests` suite, then
the Markdown suites (`MarkdownInlineFlowViewTests`, `NoteAsyncImageViewTests`,
`MarkdownDocumentTests`, `MarkdownLosslessnessTests`, `MarkdownRenderedViewTests`,
`FenceStateMachineTests`, `FrontMatterBlockTests`) and
`NoteReadingViewTests`. Keep Phase 2 unmarked in `docs/NOTES_PLAN.md` until
that verification and the planned UI review finish.

## Decisions & constraints

- All architecture/API decisions live in `docs/NOTES_PLAN.md` — don't
  re-litigate there-recorded picks (swift-markdown, FTS5+NLEmbedding hybrid,
  proposal cards over blocking approval, ubiquity-container dormant sync,
  source-agnostic `Services/Search/`).
- Safety invariants are non-negotiable: byte-preserving round-trip, hash
  guards + conflict copies (never silently overwrite external edits),
  revisions outside the vault, `.obsidian/`/dotfiles opaque, index =
  rebuildable cache.
- AI reads are always allowed; AI writes ONLY via `NoteEditProposal` +
  user-approved diff card, with hash re-validation at approve time.
- Each phase must be independently committable and `main`-mergeable behind
  `settings.notes.enabled`.
- Cross-feature seams (approval gate, search index, markdown engine,
  FuzzyMatcher, file utilities, revision store) are built generic, but the
  actual migrations of other features are follow-ups, NOT in this task's
  scope.
- Caveat: adding the entitlement re-signs the debug app, which voids its
  Accessibility grant — computer-use verification will need the grant
  re-added; unit tests and manual checks are unaffected.
- User instruction: prefer UX/accessibility over strict HIG/Liquid Glass
  when they conflict (e.g. honor increase-contrast over translucency).

## Files touched

- `docs/NOTES_PLAN.md` — the full implementation plan (new).
- `docs/memory/notes-implementation.md` — this file (new).
- `SwiftClaw/Services/Files/` — shared file utilities (new, prior package).
- `SwiftClaw/Services/Notes/Vault/` — `VaultConfiguration.swift`,
  `NotesVault.swift` (+ `exists(relativePath:)`), `VaultIgnoreRules.swift`,
  `NoteRevisionStore.swift`, `VaultReconciler.swift` (new, then modified for
  this package's `exists` addition + `vaultID` settings-key integration).
- `SwiftClaw/Services/Notes/Repository/` — `NotesRepository.swift`,
  `NotesError.swift` (new).
- `SwiftClaw/Settings/AppSettings.swift` — Notes settings keys +
  `SettingsStorage` helpers + `notesReviewScheduleDidChange` (modified).
- `SwiftClaw/SwiftClaw.entitlements` — `+files.user-selected.read-write`
  (modified).
- `SwiftClawTests/Notes/` — `NotesVaultTests.swift`,
  `NoteRevisionStoreTests.swift`, `VaultReconcilerTests.swift`,
  `NotesRepositoryTests.swift`, `NotesSettingsStorageTests.swift` (new).

### Phase 2

- `Package.swift` + `SwiftClaw.xcodeproj/project.pbxproj` — added
  `apple/swift-markdown` (branch `main`) as a package dependency/product on
  the `SwiftClaw` target; `Package.resolved` (root and
  `project.xcworkspace/xcshareddata/swiftpm/`) both updated via normal
  resolution (modified).
- `SwiftClaw/Services/Markdown/` — `MarkdownDocument.swift`,
  `FrontMatterBlock.swift`, `MarkdownRenderedView.swift`,
  `MarkdownInlineFlowView.swift`, `NoteAsyncImageView.swift` (new).
- `SwiftClaw/Services/Notes/Vault/NotesVault.swift` — added
  `readData(relativePath:)` (raw bytes, no UTF-8 decode) (modified).
- `SwiftClaw/Services/Notes/Repository/NotesRepository.swift` — added
  `readData(relativePath:)` delegating to the vault (modified).
- `SwiftClaw/Features/Notes/Editor/` — `NoteEditorController.swift`,
  `NoteEditorView.swift`, `MarkdownSourceHighlighter.swift`,
  `MarkdownEditorTheme.swift` (new).
- `SwiftClaw/Features/Notes/NoteEditorModel.swift` — deleted, replaced by
  `Editor/NoteEditorController.swift`.
- `SwiftClaw/Features/Notes/Reading/NoteReadingView.swift` (new).
- `SwiftClaw/Features/Notes/NotesView.swift` — Edit/Read toggle + Cmd-E,
  detail column routes through the new controller/editor/reading views, new
  Keep Mine/Take Theirs bar; `HSplitView` layout unchanged (modified).
- `SwiftClaw/Features/Notes/NotesFeatureModel.swift` — `NoteEditorModel` →
  `NoteEditorController` (modified).
- `SwiftClawTests/Markdown/` — `FrontMatterBlockTests.swift`,
  `MarkdownDocumentTests.swift`, `MarkdownLosslessnessTests.swift`,
  `MarkdownInlineFlowViewTests.swift`, `MarkdownRenderedViewTests.swift`,
  `FenceStateMachineTests.swift`, `NoteAsyncImageViewTests.swift` (new).
- `SwiftClawTests/Notes/NoteEditorModelTests.swift` — deleted, replaced by
  `NoteEditorControllerTests.swift` (new).
- `SwiftClawTests/Notes/NoteReadingViewTests.swift` — path-normalization and
  note-directory-first image-resolution regressions (new).
- `SwiftClawTests/Notes/NotesFeatureModelTests.swift` — `editedText` →
  `currentText` (modified).

## Phase 2 reading-mode image identity / ordered-list start / fence-deletion follow-up (2026-07-13)

Resolved three validated final review findings without starting Phase 3 or
changing `docs/NOTES_PLAN.md`:

- **Image task identity keyed only by `relativePath`** (`NoteAsyncImageView`):
  `.task(id: relativePath)` meant switching between two different notes that
  both reference an identically-named relative image (e.g. both use
  `image.png`) left SwiftUI's task identity unchanged across the note switch,
  so the second note's load never restarted and briefly (or indefinitely, if
  the first load already finished) showed the first note's already-loaded
  image. Added `imageLoadScope: String` threaded from `NoteReadingView`
  (`notePath`) through `MarkdownRenderedView` → `MarkdownBlockView` →
  `MarkdownListView`/`MarkdownQuoteView`/`MarkdownTableView`/
  `MarkdownInlineFlowView` → `NoteAsyncImageView`, which now keys its
  `.task(id:)` off a `Hashable` `ImageLoadTaskID(scope:relativePath:)` (made
  non-`private` so it's directly testable). The existing pre-`await`
  `loadState.reset()` is unchanged — it still runs whenever this new combined
  identity changes, so stale loaded/failure state still clears correctly.
- **Ordered lists always started at 1** (`MarkdownRenderedView`): the private
  `MarkdownListView.marker(for:index:)` numbered every ordered list from 1,
  ignoring `Markdown.OrderedList.startIndex` (CommonMark's `3. / 4. / 5.`
  syntax for a list that doesn't start at 1). `MarkdownListView` is now
  non-`private`, takes a `startIndex: UInt` (threaded from
  `MarkdownBlockView`'s `OrderedList` case; unordered lists pass a fixed `1`,
  unused), and its marker logic is a directly-testable `static func
  marker(checkbox:ordered:startIndex:index:)`.
- **Fence-delimiter deletion left stale styling** (`MarkdownSourceHighlighter`):
  `rangeToRestyle` widened the restyle range to end-of-document only when the
  *post-edit* edited line still read as a fence delimiter via
  `FenceStateMachine.isFenceDelimiter`. Deleting a marker character from an
  opening or closing fence (e.g. ` ``` ` → ` `` `) drops that line below the
  3-marker minimum, so it stops matching `isFenceDelimiter` even though the
  fence parity for every following line just changed — the narrow
  paragraph-only restyle then left later lines with stale monospaced/
  secondary (or stale ordinary) attributes. Fixed by also snapshotting
  `fenceState.insideFenceAtLineStart` *before* calling `recompute` each edit,
  then comparing it against the recomputed array from the edited line index
  onward (and unconditionally widening if the line count itself changed);
  any divergence conservatively widens to end-of-document. `restyle` and
  `rangeToRestyle` both gained the `editedLineIndex`/`previousFenceStates`
  plumbing to support this; the byte-for-byte `DEBUG` assert and
  `isStyling` re-entrancy guard are unchanged.

New regression coverage:
- `SwiftClawTests/Markdown/NoteAsyncImageViewTests.swift` — three new tests
  against `NoteAsyncImageView.ImageLoadTaskID` directly (different scope +
  same `relativePath` → different identity; same scope + same path → equal
  identity; same scope + different path → different identity). No view-tree
  introspection.
- `SwiftClawTests/Markdown/MarkdownRenderedViewTests.swift` — four new tests
  against `MarkdownListView.marker(...)` directly (ordinary 1-start
  numbering; a 3-start list's markers read `3./4./5.`; a parsed
  `"3. Third\n4. Fourth\n5. Fifth\n"` document's `OrderedList.startIndex ==
  3`, confirming swift-markdown surfaces it as expected; unordered-list
  markers ignore `startIndex` and stay bullet/checkbox).
- `SwiftClawTests/Markdown/MarkdownLosslessnessTests.swift` — three new tests
  using a new `probeTheme` (unmistakably distinct `textColor`/`secondaryColor`/
  fonts from ordinary usage) injected via `MarkdownSourceHighlighter`'s
  existing `themeProvider` init parameter: deleting one backtick from an
  opening fence line recomputes the previously-fenced content line back to
  ordinary-text color (not left stale as fenced); deleting one backtick from
  a closing fence line (so the fence never actually closes) recomputes every
  following line to fenced/secondary color (not left stale as ordinary); a
  tilde-fence counterpart of the opening-fence case. All three also assert
  the surrounding text stayed byte-for-byte identical apart from the single
  deleted character. The pre-existing
  `togglingAFenceDelimiterRestylesWithoutChangingCharacters` same-length-
  replace test already covered the insertion/toggle direction and needed no
  changes.

Verification:
- `swiftc -parse` implicitly covered by the full build below.
- `git diff --check`: clean.
- Focused suites via `-only-testing:`: `MarkdownRenderedViewTests`,
  `MarkdownInlineFlowViewTests`, `NoteAsyncImageViewTests`,
  `NoteReadingViewTests`, `FenceStateMachineTests`,
  `MarkdownLosslessnessTests`, `MarkdownDocumentTests`,
  `FrontMatterBlockTests`, `NoteEditorControllerTests` — all pass (unsigned
  macOS build/test, `CODE_SIGNING_ALLOWED=NO`, `set -o pipefail` +
  `xcbeautify --quiet`).
- Full unsigned macOS `xcodebuild build`: succeeds.
- Full unsigned iPhone 17 Simulator `xcodebuild build` (`platform=iOS
  Simulator,name=iPhone 17`, `CODE_SIGNING_ALLOWED=NO`): succeeds — checked
  because `MarkdownSourceHighlighter`/`MarkdownEditorTheme` are
  `#if os(macOS)`-only but `NoteAsyncImageView`/`MarkdownRenderedView`/
  `MarkdownInlineFlowView` are cross-platform (`PlatformImage`) and now carry
  the new `imageLoadScope`/`startIndex` parameters on both platforms.
- Two pre-existing, unrelated Swift 6 concurrency errors surfaced during the
  focused test run (`ReminderReviewServiceTests.swift`,
  `CalendarReviewServiceTests.swift` — `mutation of captured var ... in
  concurrently-executing code`); confirmed via `git status --porcelain` that
  neither file is touched by this change, so these are pre-existing and out
  of scope here, not a regression from this fix pass.

Files touched by this fix pass:
`SwiftClaw/Services/Markdown/NoteAsyncImageView.swift`,
`SwiftClaw/Services/Markdown/MarkdownInlineFlowView.swift`,
`SwiftClaw/Services/Markdown/MarkdownRenderedView.swift`,
`SwiftClaw/Features/Notes/Reading/NoteReadingView.swift`,
`SwiftClaw/Features/Notes/Editor/MarkdownSourceHighlighter.swift`,
`SwiftClawTests/Markdown/NoteAsyncImageViewTests.swift`,
`SwiftClawTests/Markdown/MarkdownRenderedViewTests.swift`,
`SwiftClawTests/Markdown/MarkdownLosslessnessTests.swift`.

At this checkpoint Phase 2 was still awaiting Computer Use/manual UI testing;
the later completion entry below supersedes that state.

## Phase 2 Computer Use blocker (2026-07-13)

Implementation review is clean (`gpt-5.6-terra` high: **No findings**), the
full macOS test suite passes, and unsigned macOS plus iPhone 17 Simulator
builds succeed. Computer Use was attempted three times through the required
`gpt-5.6-sol` low agent and once through the host Computer Use runtime.

Both runtimes can list `com.caffeineplz.SwiftClaw`, but capture fails with
`cgWindowNotFound`. Host inspection showed the desktop is at `loginwindow`
(locked/non-interactive session) and on-screen app windows expose no shareable
capture surface. The iOS 27 runtime is installed and a disposable iPhone 17
simulator successfully booted, installed, and launched SwiftClaw; a static
1206x2622 screenshot proved the app rendered its Home screen. This Xcode
installation has no interactive `Simulator.app`, so the Notes flows could not
be driven or visually verified on iOS either. The disposable simulator, test
process, and isolated HOME were removed afterward.

This blocker was later cleared for macOS; see the completion entry below. The
iOS host still lacks a Computer Use-accessible live simulator surface.

## Phase 2 complete (2026-07-13)

Phase 2 is marked complete in `docs/NOTES_PLAN.md`, and the phase-boundary
coverage in `docs/testing/USER_FACING_TESTS.md` is updated.

Final fixes driven by live macOS Computer Use:

- `NotesFeatureModel.createNote()` now exposes configured-vault creation
  failures through a dismissible list error instead of the onboarding-only
  configuration error channel.
- `NoteEditorController.keepMine()` reuses an already-completed autosave's
  conflict copy when it contains the same buffer, preventing a second
  identical copy.
- `NotesVault` builds mutation URLs from its already-standardized root path,
  fixing valid new-note creation when an external folder arrives as
  `/private/tmp/...` while Foundation standardizes the root to `/tmp/...`.

Regression coverage was added to `NotesFeatureModelTests`,
`NoteEditorControllerTests`, and `NotesVaultTests`. The focused suites and the
full macOS test suite pass. Unsigned macOS and iPhone 17 Simulator builds pass;
the ad hoc signed macOS artifact also builds and launches.

The final `gpt-5.6-terra` high review found two small follow-ups, both resolved:
`lastListError` is now cleared by the vault teardown/switch/reset lifecycle,
and the alternate-lexical-root regression coverage now exercises the conflict
copy path as well as new-file creation. Their focused suites, the full macOS
suite, and both platform builds pass after the fixes. Targeted Terra re-review:
**No findings.**

The final macOS Computer Use pass used a disposable external vault and passed:
New Note created and selected exactly one file, raw Markdown persisted, Read
and Edit switched in both directions with coherent rendering, and Keep Mine
created exactly one local-buffer conflict copy while the original retained the
external version. No actionable macOS UI findings remain.

The separate iOS pass booted a disposable iPhone 17 simulator, installed and
launched SwiftClaw, and captured a fresh 1206x2622 screenshot. Visual inspection
showed a coherent, legible phone layout with no obvious clipping or overlap.
Interactive iOS coverage remains host-blocked rather than failed: Xcode denied
Computer Use access, this Xcode installation has no standalone `Simulator.app`,
and Preview also denied Computer Use access. Navigation and Notes interaction
were therefore not claimed. The iOS simulator build and launch both succeeded.
