# Notes

SwiftClaw's local-first Markdown vault. Plain `.md` files are always the
source of truth, so a vault can also be opened in Obsidian, a text editor, or
any other file-based tool. Notes adds styled-source editing and reading mode,
hybrid search, backlinks, quick capture, read-only AI recall, approval-gated
AI edits, revision copies, scheduled review, and a Workspace tile.

## Ownership and lifecycle

`NotesFeatureModel.shared` is the UI-facing coordinator. It resolves the active
vault, owns one repository/editor/reconciler/indexer set, and exposes stable
observable state to Notes, Settings, Workspace, Tools, and chat. Construction
does no file, Keychain, network, or SwiftData work; `activate()` performs setup
and is preview-safe.

`NotesRepository` is the `@MainActor` mutation boundary and owns the in-memory
`[NoteSummary]` catalog. Views and tools do not touch vault files directly.
`NotesVault`, `NoteRevisionStore`, `VaultReconciler`, `NotesIndexer`,
`SearchIndex`, and `NoteLinkGraph` are actors for their background or mutable
resources. A `VaultOperationLeaseCoordinator` keeps vault reset/switch from
interleaving with proposal approval or revision restore. Reset/switch also
first saves the open editor's buffer and is refused (vault unchanged) when that
buffer can't be saved and isn't already in a conflict copy.

## Vaults and file safety (`Services/Notes/Vault/`)

The location is either app-managed (`App Support/SwiftClaw/Notes/Vault`) or an
external security-scoped folder. `VaultConfigurationStore` persists that choice
and a vault ID; the ID namespaces the private index and revision directories.

`NotesVault` is the only type that reads or changes vault files. Every path is
relative, traversal-checked, and checked against symlink escape. Enumeration
includes visible `.md` files only; dotfiles, `.obsidian/`, `.git/`, symlinks,
non-Markdown files, and SwiftClaw temp artifacts stay opaque.

Safety rules:

- Reads return raw content plus SHA-256 and modification time.
- Saves compare the caller's expected hash inside one coordinated replacement.
  A mismatch never overwrites: the attempted content becomes a sibling
  `Name (conflict <timestamp>).md` copy, itself published create-only so a
  sibling that appears meanwhile is never replaced.
- Creates and renames are create-only/no-clobber operations; a proposal rename
  is also hash-checked inside its coordinated move. Deletes move files to Trash.
- `AtomicFileWriter` publishes complete content atomically; a reader never sees
  a partially written file.
- FSEvents are hints. `VaultReconciler` debounces them and also full-scans on
  app activation and every five minutes while Notes is active.

An app-managed vault contains only user-owned Markdown and assets. Search
databases, revisions, SwiftData proposal records, and app settings never enter
the vault.

## Editing and reading (`Features/Notes/`)

On macOS, `NoteEditorView` wraps `NSTextView`; its text storage is the on-screen
source of truth, avoiding a SwiftUI binding feedback loop. `NoteEditorController`
loads selections, autosaves after 1.5 seconds or blur, and handles external
changes. A clean buffer reloads. A dirty buffer offers Keep Mine (write exactly
one conflict copy) or Take Theirs (discard and reload). Save failures keep the
editable text visible.

`MarkdownSourceHighlighter` changes attributes only and asserts in DEBUG that
characters are unchanged. It styles paragraphs incrementally, widening after a
fence-state change. Syntax styling is capped above 1 MiB of UTF-8 content so a
large note remains responsive and editable; normal base text styling remains.
The styled-source editor is macOS-only and uses `NSTextView` with an
`NSTextStorageDelegate`. By design in v1, iOS uses a plain-text SwiftUI
`TextEditor` fallback without source styling or syntax highlighting.

Reading mode uses the shared `Services/Markdown` parser/renderer for headings,
lists, tables, code, callouts, wikilinks, and relative images. Front matter is
hidden when reading but preserved exactly in source. The lightweight front
matter helper edits only an explicitly requested key line; it is not a YAML
normalizer.

## Index, search, links, and health

`Services/Search` is source-agnostic. `SearchIndex` uses SQLite with:

- `documents(source_type, source_id, title, uri, content_hash, updated_at)`;
- `chunks(document_id, ordinal, heading_path, byte_start, byte_end, content)`;
- external-content FTS5 `chunks_fts` using `unicode61`;
- `embeddings(chunk_id, model_id, dim, vector)`.

`NotesIndexer` parses and chunks changed notes, skips unchanged hashes, and can
rebuild the cache from the catalog. The startup catalog sync also drops cached
notes the catalog lacks (deletions/renames made while the app was closed).
That cleanup runs exclusively of reconcile deltas and rechecks the live
catalog, so a note indexed meanwhile is never dropped. Multi-statement writes run as one `SQLiteDatabase.transaction` call, never as
separately awaited `BEGIN`/`COMMIT`s. Search combines FTS and optional on-device
`NLEmbedding` cosine results with reciprocal-rank fusion. Missing embeddings or
FTS5 degrade visibly instead of crashing. The generated 5,000-note performance
gate runs without embeddings and requires a rebuild under 30 seconds.

`NoteLinkGraph` stores outgoing wikilinks and tags separately. Scanners ignore
front matter/code ranges where appropriate, resolve Obsidian-style paths, and
power backlinks and broken-link health. `NotesHealthSummary` also reports
conflict copies, index freshness, and FTS/embedding availability. The index and
link graph are rebuildable caches, never a second source of truth.

The list supports title search and hybrid content results. Command-O opens the
fuzzy quick switcher; keyboard focus, Up/Down selection, Return, and Escape are
all supported. The backlinks inspector and wikilink completion remain
Notes-scoped in v1 (see the cross-feature follow-ups below).

## AI tools and proposal approval

`search_notes` and `read_note` are registered on `ToolRegistry.shared`. They are
always allowed when Notes is enabled/configured and disappear when it is not.
Search returns cited snippets; read returns verbatim content with a truncation
notice when capped, and only for visible Markdown note paths (never dotfiles,
`.git/`, or non-Markdown files).

`propose_note_edit` and `propose_note_create` are request-bound chat tools. They
insert a `NoteEditProposal` into the main local SwiftData store and queue a diff
card; they never write the vault. Approve binds to the originating vault, holds
a vault-operation lease, re-reads the target, re-checks its base hash, snapshots
the current version, then uses the repository's coordinated mutation path. A
stale target becomes `conflicted` and remains untouched. Reject changes only the
proposal state. Proposal records and full proposed content are device-local.

Notes Review is separate system work. `NotesReviewService` creates a scoped
registry containing only its fetch/notify tools and runs with `.standalone`;
those tools are never available to normal chats. It reports restrained vault
hygiene and triage, never unprompted edits.

## Capture, daily notes, and Workspace

`NotesQuickCaptureService` serializes capture for the active vault. Daily-note
capture appends a timestamped bullet to `settings.notes.dailyNoteFolder` using
the normal hash guard; standalone capture creates a safely uniquified note.
Capture is available in Notes and the Workspace tile. The tile shows note count,
captured-today count, and health. `NotesWorkflowManager` schedules manual/daily
review and suppresses redundant scheduled work.

## Revisions

`NoteRevisionStore` keeps pre-mutation UTF-8 snapshots outside the vault under
`App Support/.../Revisions/<vaultID>`, keyed by relative path. It retains at
most 50 revisions per key and 30 days. Save, rename, and delete snapshot before
mutation.

The per-note Revisions sheet lists newest-first timestamps and short previews.
Restore is intentionally non-destructive: historical content is atomically
published as a uniquely named sibling conflict copy, added to the visible
catalog/index, and the current note is never changed. Revisions are path-keyed;
history captured before a rename remains under the old path.

## Dormant sync

The app-managed seam targets an iCloud Drive ubiquity container, not CloudKit
records, because files remain authoritative. Entitlement detection and the
location seam ship disabled; v1 uses local App Support unless the entitlement is
enabled deliberately. External vault sync belongs to that folder's provider and
arrives through the same reconcile/hash-conflict path as any other editor.

## Testing

`SwiftClawTests/Notes/`, `SwiftClawTests/Markdown/`, and
`SwiftClawTests/Search/` cover vault path safety, conflicts, revisions,
reconciliation, editor races/losslessness, parsing/rendering, indexing/search,
links, tools/proposals, quick capture, review, and Workspace summaries. The
stable human and Computer Use flows live in
`docs/testing/USER_FACING_TESTS.md`; all UI passes use the hardened temporary
fixture identity and never a real vault.

## Remaining work and deferred items

Deferred from v1: wikilink rename back-propagation (corruption risk; health
surfaces broken links instead), a graph view, a CJK trigram FTS table,
NLContextualEmbedding, tag-editing UI, a rich revision-history browser, the
app-global switcher, and editor attachment embedding.

Watch items:

- The macOS title bar shows a double back-chevron while Notes is open. This is
  app-shell navigation (Workspace's NavigationStack plus the custom history
  controls in `ContentView`), not Notes — fix it there.
- `CenteredMeasureScrollView.layout()` guards `textContainerInset` against
  redundant sets because an unconditional set invalidates layout and can spin.
  One ~75%-CPU editor hang was observed before the guard and never fully
  attributed; if it recurs, profile the editor layout path first.

Cross-feature follow-ups — the seams are designed in, migrations are separate
work:

1. **Approval gate** — the generic approve/reject tokens, shared `DiffEngine`
   plus diff subview, and the coordinator-queue pattern can back email-draft
   and calendar-edit proposals.
2. **Hybrid index** — `Services/Search` takes no Notes types; email and
   chat-history adapters would enable an app-wide semantic recall tool.
3. **Markdown engine** — swap the Chats transcript renderer onto the shared
   `Services/Markdown` stack to gain lists, tables, and code blocks.
4. **FuzzyMatcher** (`Shared/`) — an app-global Cmd-K switcher can reuse it
   unchanged.
5. **File utilities** (`Services/Files/`) — import/export and watched folders.
6. **Revision store** — content-agnostic; can hold email-draft history.
