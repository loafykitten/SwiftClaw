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

## Repository pattern

Introduced by Email: views usually touch `ModelContext` directly, but features
with heavier persistence use a `@MainActor final class FooRepository` as the
single mutation boundary. `EmailRepository` is the canonical example. Mutations
stay MainActor-isolated.

## Singletons and actors

- **UI-facing state**: `@MainActor @Observable final class` + `static let shared`
  (`ToolActivityMonitor`, `MailSyncMonitor`).
- **Background work**: `actor` (`BraveRateGate`, `MailSyncWorker`).
