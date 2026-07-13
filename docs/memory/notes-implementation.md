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

Plan approved and committed (`docs/NOTES_PLAN.md`). No feature code written
yet. Branch: `feature/notes` (cut from main after the Reminders
fast-forward). Existing scaffold: `NotesView`/`NotesSettingsView`
placeholders, `settings.notes.enabled` key, `WorkspaceSection.notes`.

## Next steps

1. Phase 1 — start with the shared file utilities
   (`SwiftClaw/Services/Files/`: `SecurityScopedBookmarkStore`,
   `FSEventStreamMonitor`, `AtomicFileWriter`) and their tests; they have no
   Notes dependencies.
2. Phase 1 — vault layer (`Services/Notes/Vault/`: `VaultConfiguration`,
   `NotesVault` actor with hash-guarded atomic writes + conflict copies,
   `VaultIgnoreRules`, `NoteRevisionStore`, `VaultReconciler`) + tests.
3. Phase 1 — `NotesRepository`, `NotesError`, entitlement addition
   (`com.apple.security.files.user-selected.read-write`), settings keys.
4. Phase 1 — UI: `NotesOnboardingSheet`, real `NotesView` (interim plain
   editor + conflict banner), `NotesSettingsView`. Run the Phase 1 manual
   script (external-edit conflict check) before committing the phase.
5. Phases 2–7 per `docs/NOTES_PLAN.md`.

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
