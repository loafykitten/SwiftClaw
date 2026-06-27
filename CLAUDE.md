# SwiftClaw

A Swift / Xcode app (iOS + macOS). Primary active area: the email feature
(fetch, repository, review/triage) under `SwiftClaw/Services/Email/`.

See `AGENTS.md` for architecture, conventions, and the email subsystem in
depth. The shared CLI toolset (rg, fd, ast-grep, …) lives in `~/.claude/CLAUDE.md`.

## Build & test

```bash
# Full build
xcodebuild -scheme SwiftClaw -destination 'platform=macOS' build \
  -derivedDataPath /tmp/DerivedData

# Full test suite (Swift Testing)
xcodebuild -scheme SwiftClaw -destination 'platform=macOS' test \
  -derivedDataPath /tmp/DerivedData

# Run only one suite
xcodebuild -scheme SwiftClaw -destination 'platform=macOS' test \
  -derivedDataPath /tmp/DerivedData \
  -only-testing:SwiftClawTests/EmailReviewServiceTests
```

Pipe through `xcbeautify --quiet` for readable output. Run from the repo root.
