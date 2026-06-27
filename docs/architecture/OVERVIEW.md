# SwiftClaw — App Architecture

SwiftUI + SwiftData app (`@main SwiftClawApp`). The `Schema([...])` lives in
`SwiftClawApp.swift`. Additive `@Model` changes are covered by lightweight
migration as long as new properties are optional or defaulted — no versioned
schema needed.

## Navigation

`NavigationSplitView` two-pane UI: `AccentSidebarList` +
`ContentView.destination(for:)`. Settings-gated nav items are filtered in
`ContentView.visibleNavigationItems` (e.g. Email against
`SettingsStorage.isEmailEnabled()`).

## Repository pattern

Introduced by Email: views usually touch `ModelContext` directly, but features
with heavier persistence use a `@MainActor final class FooRepository` as the
single mutation boundary. `EmailRepository` is the canonical example. Mutations
stay MainActor-isolated.

## Singletons and actors

- **UI-facing state**: `@MainActor @Observable final class` + `static let shared`
  (`ToolActivityMonitor`, `MailSyncMonitor`).
- **Background work**: `actor` (`BraveRateGate`, `MailSyncWorker`).
