# SwiftClaw — AI Agent Guide

SwiftUI + SwiftData app for macOS and iOS.

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
- **The Notes subsystem and remaining implementation phases**
  → `docs/NOTES_PLAN.md`
- **End-of-feature/phase user-facing test catalog**
  → `docs/testing/USER_FACING_TESTS.md`
- **Headless iOS-simulator UI verification** (idb taps, screenshots, Xcode 27 setup)
  → `docs/testing/SIMULATOR_UI_VERIFICATION.md`

`docs/testing/USER_FACING_TESTS.md` is an end-of-feature/phase inventory, not
implementation guidance. Only open or update it at those checkpoints.

## Working-task memory (`docs/memory/`)

At the start of a session, check `docs/memory/` for a file matching the task and
resume from its "Next steps." For multi-session work, maintain a
`<task-slug>.md` file and delete it when the task ships. Format and rules:
`docs/memory/README.md`.

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
`idb` / `idb_companion` - tap & inspect the booted iOS simulator headlessly — setup and caveats in `docs/testing/SIMULATOR_UI_VERIFICATION.md`
`node` - run JavaScript tooling and skill helpers (`node --version`)
`opencode` - alternate model runner and independent review CLI (`opencode models neuralwatt`)

Rule of thumb: `rg`/`fd` to locate, `ast-grep` for surgical multi-file edits, `difft` when a diff looks noisy and you need to know what actually changed.

## Build & Test

Run these from the repo root. The macOS commands are SSH-safe:

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme SwiftClaw -destination 'platform=macOS' build -derivedDataPath /tmp/DerivedData CODE_SIGNING_ALLOWED=NO` — builds the macOS app.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme SwiftClaw -destination 'platform=macOS' test -derivedDataPath /tmp/DerivedData CODE_SIGNING_ALLOWED=NO` — runs all `SwiftClawTests` suites (Swift Testing).
- To run a single suite: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme SwiftClaw -destination 'platform=macOS' test -derivedDataPath /tmp/DerivedData CODE_SIGNING_ALLOWED=NO -only-testing:SwiftClawTests/<SuiteName>`.
- The SSH host may have Command Line Tools selected globally. `DEVELOPER_DIR` selects the installed Xcode without changing system settings; unsigned builds avoid requiring a local development certificate.
- The Xcode project uses `PBXFileSystemSynchronizedRootGroup`, so new files under `SwiftClaw/` are picked up automatically.
- Piping through `xcbeautify --quiet` makes the `xcodebuild` output readable.
- No project linter is configured; builds and tests are the code-quality gates.

## Cross-platform & previews

- Keep AppKit and UIKit code behind `#if os(macOS)` and `#if os(iOS)`; shared
  code must keep building on both platforms.
- Previews must avoid Keychain / network / live SwiftData work — guard entry points with `ProcessInfo.processInfo.isRunningInPreview`.

## Logs & errors

- `os.Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.caffeineplz.SwiftClaw", category: <feature>)`. Privacy-annotate interpolated values: `.public` only for non-sensitive data (mailbox names, counts); leave error payloads and account identity at default privacy (they can echo hostnames/usernames).
- Errors: `LocalizedError` enums with `errorDescription` (templates: `InferenceError`, `ToolError`, `MailClientError`).

## Adding a Workspace feature

1. Add `SettingsKeys.foo*` and a `SettingsStorage.isFooEnabled(userDefaults:)`
   helper; extend `WorkspaceFeature` and its switches in `SettingsStorage` and
   `ToolsView` — see `docs/conventions/SETTINGS.md`.
2. Add `SettingsSection.foo`, its feature mapping, and a `FooSettingsView`.
3. Add `WorkspaceItem.foo`, its feature mapping, and its destination in
   `WorkspaceView` — see `docs/architecture/OVERVIEW.md`.
4. For system-only AI work, add a dedicated `*ReviewService` + `*ReviewNotifyTool` invoked from the scheduler/loop — see `docs/conventions/TOOLS.md`. Do NOT register the tool on `ToolRegistry.shared`.

## Token economy

Locate before you read. Reading a large source file in full is the most
expensive thing you'll do in a session, and most of it is usually irrelevant
to the task at hand.

- Prefer `rg`/`fd` to pin down the file and line range, then use
  `bat --line-range <start>:<end> <path>`. Expand as needed; several small reads
  beat one full-file read.
- Don't re-derive architecture or conventions from source when a focused
  doc exists. Read `docs/architecture/OVERVIEW.md` or the relevant
  `docs/conventions/*.md` instead of pawing through a 1k+ line view file.
- Reserve full-file reads for genuinely small files or when you must edit
  across most of the file in one pass.
- Scope `xcodebuild` test runs with `-only-testing:` and pipe through
  `xcbeautify --quiet` to keep the returned output small.

## Scope discipline

Report unrelated issues at the end instead of fixing them. Ask Ember when the
requirements or solution remain unclear.
