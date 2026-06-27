# SwiftClaw — AI Agent Guide

## Build & Test

- `xcodebuild -scheme SwiftClaw -destination 'platform=macOS' build -derivedDataPath /tmp/DerivedData` — app bundle build. Run from the repo root.
- `xcodebuild -scheme SwiftClaw -destination 'platform=macOS' test -derivedDataPath /tmp/DerivedData` — runs all `SwiftClawTests` suites (Swift Testing). Run from the repo root.
- To run a single suite: `xcodebuild -scheme SwiftClaw -destination 'platform=macOS' test -derivedDataPath /tmp/DerivedData -only-testing:SwiftClawTests/<SuiteName>`.
- The Xcode project uses `PBXFileSystemSynchronizedRootGroup`, so new files under `SwiftClaw/` are picked up automatically.
- Piping through `xcbeautify --quiet` makes the `xcodebuild` output readable.
- macOS only today (`Package.swift` declares `.macOS("27.0")`); iOS target is planned (Phase 0.5).
- No linter — the Swift 6 strict-concurrency checker (`-swift-version 6`) is the static-analysis gate.

## Architecture

- SwiftUI + SwiftData (`@main SwiftClawApp`). The `Schema([...])` lives in `SwiftClawApp.swift`. Additive `@Model` changes are covered by lightweight migration as long as new properties are optional or defaulted — no versioned schema needed.
- `NavigationSplitView` two-pane UI: `AccentSidebarList` + `ContentView.destination(for:)`. Settings-gated nav items are filtered in `ContentView.visibleNavigationItems` (e.g. Email against `SettingsStorage.isEmailEnabled()`).
- **Repository pattern** (introduced by Email): views usually touch `ModelContext` directly, but features with heavier persistence use a `@MainActor final class FooRepository` as the single mutation boundary. `EmailRepository` is the example. Mutations stay MainActor-isolated.
- **Singletons**: UI-facing state is `@MainActor @Observable final class` + `static let shared` (`ToolActivityMonitor`, `MailSyncMonitor`); background work is an `actor` (`BraveRateGate`, `MailSyncWorker`).

## Settings persistence

All in `Settings/`:

1. **`SettingsKeys`** (`AppSettings.swift`) — string constants for every persisted key.
2. **`@AppStorage(SettingsKeys.foo)`** — non-secret primitives in views.
3. **`@KeychainStorage(SettingsKeys.bar)`** (`KeychainStorage.swift`) — secrets (API keys, IMAP/SMTP passwords). Use `Keychain.set/delete/string(forKey:)` outside SwiftUI. Per-account keys are runtime values, so account passwords use `Keychain.set(...)` directly rather than the property wrapper.
4. **`SettingsStorage`** — static helpers with an injectable `UserDefaults` for tests (template: `isWebSearchEnabled(userDefaults:)`). Defaults/ranges live as `static let defaultX` / `xRange` next to the helper. Tests pass a `UserDefaultsFixture`.

## SwiftData model conventions

- `@Model final class` with `@Attribute(.unique) var id: UUID`.
- Enums persisted as a raw `String` plus a computed accessor (template: `ChatMessage.roleRawValue` / `.role`).
- `@Relationship(deleteRule: .cascade, inverse: \Child.parent)` for owned-to-many (template: `Chat.messages`).
- JSON blobs on a `Data?` property (template: `ChatMessage.imageAttachmentsData`; reused for `reviewCardData` ↔ `reviewCard`).
- New domain types are `Codable, Sendable, Hashable` where it applies (Swift 6 strict concurrency).

## Tools

- `Tool` protocol (`Services/Tools/Tool.swift`) — a model-callable capability.
- `ToolRegistry.shared` lists tools offered on every normal chat (`WebSearchTool`, `InvestigateTool`). **System-only tools** (e.g. `EmailReviewNotifyTool`) must NOT be registered there — construct a scoped `ToolRegistry(tools:)` at the call site so the assistant can't invoke them during user chats.
- `InferenceService.shared.complete(messages:model:tools:systemPromptMode:)` runs an 8-round agentic tool loop. Use `.standalone` for system-work prompts (no persona); `.prependPersona` (default) for user chats.
- Long-running status is surfaced via `@MainActor @Observable` monitors (`ToolActivityMonitor`, `MailSyncMonitor`).

## Email feature notes

- **Mail client**: `SwiftMailClient` (one per `StoredEmailAccount`) reads host/port/username from the account and passwords from the Keychain per call. For the add-account sheet's Test button (before passwords are persisted), pass `imapPasswordOverride` / `smtpPasswordOverride` so `isConfigured` doesn't short-circuit on an empty Keychain.
- **Folders**: archive/delete/send resolve the account's real Archive/Trash/Sent folders via IMAP `LIST (SPECIAL-USE)` (Gmail's archive is `[Gmail]/All Mail`, not "Archive"), cached on `StoredEmailAccount`. `delete` is a recoverable move to Trash; `deletePermanently` is the explicit expunge.
- **Incremental sync**: `fetchMailbox(name:sinceUID:)` returns `MailboxFetchResult { messages, uidValidity, maxUID }`. `MailSyncWorker` keeps a per-`(account, mailbox)` high-water mark in `MailboxSyncStateStore`; it fetches `UID > lastSeenUID` when the recorded UIDVALIDITY still matches, and re-fetches the whole mailbox when it changed (folder rebuild). Per `syncOnce()` the worker iterates `[INBOX, account's resolved Sent folder]` and runs the upsert + reconciliation against each. Inject `clientFactory` / `syncStateProvider` / `syncStateUpdater` to test with `MockMailClient`.
- **Server-side reconciliation**: after each incremental upsert the worker runs a cheap `.uidFlagsOnly` UID-set scan (`MailClient.fetchMailboxUIDSet(name:)` → `MailboxUIDSet { uidValidity, uids, flagsByUID }`) — no body fetch, one round-trip — and reconciles the local store: `EmailRepository.reconcileDeletions(...)` soft-deletes (`isDeleted = true`) local rows whose UID is no longer on the server (preserves the row + `EmailNote`s + `EmailThread` linkage + `lastReviewedAt`; skipped for already-archived rows; surfaces in Trash), and `EmailRepository.reconcileFlagsFromSnapshot(...)` refreshes `\Seen`/`\Flagged` drift on persisting rows. MVP scope: INBOX only. Soft-deleted rows naturally clean up stale old-UID rows after a UIDVALIDITY-rebuild.
- **Threading**: `EmailRepository.resolveThreads()` is incremental and identity-preserving — it reuses an `EmailThread.id` when a cluster's messages already belonged to it, so a re-cluster doesn't yank the user's open thread. Only runs when new messages were inserted.
- **Review loop**: `EmailReviewService.runOnce()` sends up to `maxThreadsPerPass` (40) unreviewed threads to the model and stamps `EmailThread.lastReviewedAt` **only after** a successful inference call — a failure retries next pass instead of suppressing the threads forever. Suppression is via `lastReviewedAt`, not AI notes.
- **Replies** populate `In-Reply-To` / `References` from the replied message and best-effort APPEND to Sent; `EmailRepository.upsertSentMessage` also seeds a local row (synthetic uid, `isLocallySynthetic = true`) so the reply appears immediately. The Sent-mailbox sync reconciles the synthetic row to the real one: when the real server message (matching Message-ID) arrives via `upsertMessages`, the synthetic row's `uid` is rewritten + the marker flag is cleared — no duplicate insert.
- **Known limitation**: server→local reconciliation is **INBOX only** for the deletion-reconciliation pass that soft-deletes, plus per-account Sent for the upsert + flag/deletion reconciliation. The `MailSyncWorker.syncOnce()` runs the UID-set scan + deletion/flag reconciliation against every mailbox it syncs (INBOX + the account's resolved Sent folder). For Sent-mailbox reconciliation, the locally-synthetic rows `upsertSentMessage` produces are preserved until a real Sent-folder sync lands the matching Message-ID (recognized by the `isLocallySynthetic` flag, set on send and cleared on promotion). Extending to Archive/Trash belongs with further multi-mailbox-sync work — those mailboxes are reflected as local soft-delete flags today, so server-side membership reconciliation on them is lower priority.

## Cross-platform & previews

- `#if os(macOS)` guards wrap AppKit code even though only macOS ships today, so iOS lands cleanly later.
- Previews must avoid Keychain / network / live SwiftData work — guard entry points with `ProcessInfo.processInfo.isRunningInPreview`.

## Logs & errors

- `os.Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.caffeineplz.SwiftClaw", category: <feature>)`. Privacy-annotate interpolated values: `.public` only for non-sensitive data (mailbox names, counts); leave error payloads and account identity at default privacy (they can echo hostnames/usernames).
- Errors: `LocalizedError` enums with `errorDescription` (templates: `InferenceError`, `ToolError`, `MailClientError`).

## Adding a feature (settings + sidebar + view)

1. Add `SettingsKeys.foo*` + a `SettingsStorage.isFooEnabled(userDefaults:)` helper.
2. Add a `SettingsSection.foo` case + a `FooSettingsView` (Form / Section / `.formStyle(.grouped)`).
3. Add a `NavigationItem.foo` case + `destination` branch; filter in `ContentView.visibleNavigationItems` if gated.
4. For system-only AI work, add a dedicated `*ReviewService` + `*ReviewNotifyTool` invoked from the scheduler/loop — do NOT register the tool on `ToolRegistry.shared`.
