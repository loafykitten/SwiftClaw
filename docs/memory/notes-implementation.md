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

Phase 1 is complete. Start `## Phase 2 — Markdown engine, styled-source editor,
reading mode` in `docs/NOTES_PLAN.md`: add the shared markdown engine and the
styled-source editor/reading-mode package. Phases 3–7 remain after that.

Low-confidence decisions worth a second look before Phase 2:
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
