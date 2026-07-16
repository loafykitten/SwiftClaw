# SwiftClaw — App Architecture

SwiftUI + SwiftData app (`@main SwiftClawApp`). The schemas and store
configurations live in `Shared/SwiftClawModelContainerFactory.swift` — a main
store plus the CloudKit-shaped calendar configuration, which also holds the
reminders models (see `docs/features/CALENDAR.md` and
`docs/features/REMINDERS.md`). Additive `@Model` changes are covered by
lightweight migration as long as new properties are optional or defaulted — no
versioned schema needed.

## Navigation

`ContentView` uses a `NavigationSplitView` at regular width and a `TabView` on
compact iOS. Home, Chats, Workspace, and Research are the main destinations;
Settings is also a top-level compact destination on iOS. Feature views own
their nested `NavigationStack`s where needed.

Email, Calendar, Reminders, and Notes live inside `WorkspaceView`. Their
`WorkspaceFeature` toggles control the Workspace items and feature-backed
Settings sections.

Notes uses a filesystem-backed vault rather than SwiftData for user content.
See `docs/features/NOTES.md`: `NotesFeatureModel.shared` owns the active
vault/repository/editor/reconciler/indexer lifecycle, while the view adapts
between the macOS split and compact iOS navigation.

## Repository pattern

Introduced by Email: views usually touch `ModelContext` directly, but features
with heavier persistence use a `@MainActor final class FooRepository` as the
single mutation boundary. `EmailRepository` is the canonical example. Mutations
stay MainActor-isolated.

Notes follows this pattern even though files are authoritative:
`NotesRepository` owns the visible catalog and every mutation;
`NotesVault` alone touches vault paths. Its SQLite search/link stores are
rebuildable caches, and private revisions live outside the vault. Views, chat
tools, and review services never reach around the repository to mutate files.

## Singletons and actors

- **UI-facing state**: `@MainActor @Observable final class` + `static let shared`
  (`ToolActivityMonitor`, `MailSyncMonitor`).
- **Background work**: `actor` (`BraveRateGate`, `MailSyncWorker`).
- **Notes resources**: actors isolate vault I/O, revisions, reconciliation,
  indexing, and SQLite connections. `VaultOperationLeaseCoordinator` is a
  MainActor gate that drains in-flight proposal/revision operations before a
  vault reset or switch.
