# SwiftClaw — AI Agent Guide

SwiftUI + SwiftData app (iOS + macOS). macOS-only today (`Package.swift`
declares `.macOS("27.0")`); iOS target is planned.

## Where things are documented

Read the relevant doc when your task touches that subject — they're kept out of
this file to stay scannable:

- **App architecture** (SwiftUI/SwiftData layout, nav, repository pattern, singletons/actors)
  → `docs/architecture/OVERVIEW.md`
- **Creating or changing SwiftData models** → `docs/conventions/MODELS.md`
- **Settings & secret/keychain persistence** → `docs/conventions/SETTINGS.md`
- **Model-callable tools / inference loop** → `docs/conventions/TOOLS.md`
- **The Email subsystem** (mail client, sync, reconciliation, threading, review loop, scope & status)
  → `docs/features/EMAIL.md`
- **The Calendar subsystem** (events/recurrence model, import/export, alerts, review loop, overlay, dormant CloudKit sync)
  → `docs/features/CALENDAR.md`
- **The Reminders subsystem** (roll-forward recurrence, quick entry, import/export, due-date alerts, review loop, calendar chips)
  → `docs/features/REMINDERS.md`
- **End-of-feature/phase user-facing test catalog**
  → `docs/testing/USER_FACING_TESTS.md`

`docs/testing/USER_FACING_TESTS.md` is irrelevant during ordinary implementation
and review. Do not read it as requirements or implementation guidance. Only open
it at the end of a feature or phase, then add or update tests for changed
user-facing behavior.

## Working-task memory (`docs/memory/`)

`docs/memory/` holds state for currently in-flight tasks so work can continue
across an agent switch or a cleared session. **At the start of a session,
check it** — if a file there matches the task you were given, read it and
resume from its "Next steps". For any multi-session task, create/update a
`<task-slug>.md` file there as you go, and delete it when the task ships.
Format and rules: `docs/memory/README.md`.

Small tasks and bug fixes must be handled as normal work, not deferred.

## Additional Agent-friendly CLI tools
`rg` - text/regex search (`rg -n "pattern" --type swift`)
`fd` - finding files (`fd -e swift Review`)
`ast-grep` - structural/AST search & safe refactors — matches syntax, not strings in comments
`bat` - syntax-highlighted file view
`delta` - pretty git diffs (human-facing)
`difft` - structural diff — is a change real or just reformatting?
`sd` - find/replace (sane regex, fewer escapes than sed)
`tokei` - repo shape / lines per language
`jq` - JSON query
`yq` - YAML / plist-ish query
`gron` - make unknown JSON greppable, then ungron
`gh` - GitHub PRs/issues/CI — prefer `--json` output
`xcbeautify` - make `xcodebuild` output readable
`swiftformat` - format Swift — `swiftformat --lint .` to check only
`swiftlint` - lint Swift for style/correctness
`shellcheck` - validate shell scripts before running

Rule of thumb: `rg`/`fd` to locate, `ast-grep` for surgical multi-file edits, `difft` when a diff looks noisy and you need to know what actually changed.

## Build & Test

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme SwiftClaw -destination 'platform=macOS' build -derivedDataPath /tmp/DerivedData CODE_SIGNING_ALLOWED=NO` — SSH-safe app bundle build. Run from the repo root.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme SwiftClaw -destination 'platform=macOS' test -derivedDataPath /tmp/DerivedData CODE_SIGNING_ALLOWED=NO` — runs all `SwiftClawTests` suites (Swift Testing). Run from the repo root.
- To run a single suite: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme SwiftClaw -destination 'platform=macOS' test -derivedDataPath /tmp/DerivedData CODE_SIGNING_ALLOWED=NO -only-testing:SwiftClawTests/<SuiteName>`.
- The SSH host may have Command Line Tools selected globally. `DEVELOPER_DIR` selects the installed Xcode without changing system settings; unsigned builds avoid requiring a local development certificate.
- The Xcode project uses `PBXFileSystemSynchronizedRootGroup`, so new files under `SwiftClaw/` are picked up automatically.
- Piping through `xcbeautify --quiet` makes the `xcodebuild` output readable.
- No linter — the Swift 6 strict-concurrency checker (`-swift-version 6`) is the static-analysis gate.

## Cross-platform & previews

- `#if os(macOS)` guards wrap AppKit code even though only macOS ships today, so iOS lands cleanly later.
- Previews must avoid Keychain / network / live SwiftData work — guard entry points with `ProcessInfo.processInfo.isRunningInPreview`.

## Logs & errors

- `os.Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.caffeineplz.SwiftClaw", category: <feature>)`. Privacy-annotate interpolated values: `.public` only for non-sensitive data (mailbox names, counts); leave error payloads and account identity at default privacy (they can echo hostnames/usernames).
- Errors: `LocalizedError` enums with `errorDescription` (templates: `InferenceError`, `ToolError`, `MailClientError`).

## Adding a feature (settings + sidebar + view)

1. Add `SettingsKeys.foo*` + a `SettingsStorage.isFooEnabled(userDefaults:)` helper — see `docs/conventions/SETTINGS.md`.
2. Add a `SettingsSection.foo` case + a `FooSettingsView` (Form / Section / `.formStyle(.grouped)`).
3. Add a `NavigationItem.foo` case + `destination` branch; filter in `ContentView.visibleNavigationItems` if gated — see `docs/architecture/OVERVIEW.md`.
4. For system-only AI work, add a dedicated `*ReviewService` + `*ReviewNotifyTool` invoked from the scheduler/loop — see `docs/conventions/TOOLS.md`. Do NOT register the tool on `ToolRegistry.shared`.

## Token economy

Locate before you read. Reading a large source file in full is the most
expensive thing you'll do in a session, and most of it is usually irrelevant
to the task at hand.

- Prefer `rg`/`fd` to pin down the file and line range first, then `read`
  with `offset`/`limit` to pull only the relevant slice. Expand with further
  `rg`/`read` calls as the picture sharpens — several small reads beat one
  full-file read.
- Don't re-derive architecture or conventions from source when a focused
  doc exists. Read `docs/architecture/OVERVIEW.md` or the relevant
  `docs/conventions/*.md` instead of pawing through a 1k+ line view file.
- Reserve full-file reads for genuinely small files or when you must edit
  across most of the file in one pass.
- Scope `xcodebuild` test runs with `-only-testing:` and pipe through
  `xcbeautify --quiet` to keep the returned output small.

## Side Note
When doing this work, it's okay if you make mistakes. If you encounter any issues unrelated to the task at hand, let me know about them at the end rather than trying to address them in your thought process. If you don't know a solution to a problem, it's okay to ask me for clarification.
