# Headless iOS-simulator UI verification (idb)

macOS 27 removed Simulator.app (Device Hub replaced it), and Device Hub does
not reliably expose the simulator's UI to macOS accessibility — so GUI
automation of the *host* cannot tap inside the simulator. `idb` (Facebook's
iOS Debug Bridge) injects taps into the simulator directly, no host GUI
involved. Combined with `simctl io booted screenshot`, an agent can navigate
and visually verify iOS UI entirely from the shell.

Verified working 2026-07-19 against Xcode 27 / iOS 27 simulators
(macOS 27.0 build 26A5378n).

## One-time setup

The paths below under `~/.local/share/idb/` are the conventional install
location this doc's snippets assume; check for them before reinstalling.

- Companion: **must be built from facebook/idb HEAD** — do NOT
  `brew install facebook/fb/idb-companion`. The brew release (1.1.8, Aug
  2022) injects through the legacy Indigo mach channel, which macOS 27
  suppresses (see Caveats), and the formula's `--HEAD` mode is broken (it
  expects a prebuilt tarball layout). Source lives at
  `~/.local/share/idb/src`, binary is symlinked to
  `/opt/homebrew/bin/idb_companion`. To (re)build after an upstream pull:

  ```bash
  brew install xcodegen protobuf swift-protobuf   # build deps
  cd ~/.local/share/idb/src && ./build.sh build idb_companion
  ln -sf ~/.local/share/idb/src/Build/Products/Release/idb_companion /opt/homebrew/bin/idb_companion
  ```

  Build gotchas: on a fresh clone the first run generates the Xcode
  project before the gRPC sources exist ("no such module 'IDBGRPCSwift'")
  — just run it again; the OSS `Companion/project.yml` is missing a
  `ReplProtocol` framework target the companion imports (the local clone
  carries the patch — re-add it if a pull clobbers it); don't build under
  `/tmp`-ish paths (build.sh's xattr workaround mangles them).
- Python client (`fb-idb`) in a venv:
  `python3 -m venv ~/.local/share/idb/venv && ~/.local/share/idb/venv/bin/pip install fb-idb`
  (client 1.1.7 works fine against the HEAD companion)
- **Xcode 27 workaround**: idb hardcodes
  `<DEVELOPER_DIR>/Library/PrivateFrameworks/SimulatorKit.framework`, but
  Xcode 27 moved SimulatorKit to `Contents/SharedFrameworks/`, and Xcode.app
  itself is not writable (macOS App Management). Fix: build a shadow developer
  dir of symlinks at `~/.local/share/idb/shadow-xcode` that mirrors the real
  `Contents/` and adds the missing SimulatorKit symlink at the old path.
  Rerun the snippet after Xcode updates if links break:

  ```bash
  REAL=/Applications/Xcode.app/Contents
  FAKE=~/.local/share/idb/shadow-xcode/Contents
  mkdir -p "$FAKE/Developer/Library/PrivateFrameworks"
  for i in "$REAL"/*; do n=$(basename "$i"); [ "$n" = Developer ] || ln -sfn "$i" "$FAKE/$n"; done
  for i in "$REAL/Developer"/*; do n=$(basename "$i"); [ "$n" = Library ] || ln -sfn "$i" "$FAKE/Developer/$n"; done
  for i in "$REAL/Developer/Library"/*; do ln -sfn "$i" "$FAKE/Developer/Library/$(basename "$i")"; done
  ln -sfn "$REAL/SharedFrameworks/SimulatorKit.framework" "$FAKE/Developer/Library/PrivateFrameworks/SimulatorKit.framework"
  ```

## Usage

The client's companion auto-spawn is flaky — start the companion manually
(with the shadow DEVELOPER_DIR) and pass `--companion` **before** the
subcommand:

```bash
UDID=$(xcrun simctl list devices booted | rg -o '[0-9A-F-]{36}' | head -1)
DEVELOPER_DIR=~/.local/share/idb/shadow-xcode/Contents/Developer \
  idb_companion --udid "$UDID" --grpc-port 10882 &   # leave running

IDB=~/.local/share/idb/venv/bin/idb
"$IDB" --companion localhost:10882 ui tap 201 820          # logical points
"$IDB" --companion localhost:10882 ui describe-all | jq .  # AX labels + frames
"$IDB" --companion localhost:10882 ui text "hello"         # type into focus
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun simctl io booted screenshot /tmp/shot.png          # verify result
```

Coordinates are logical points (iPhone 17: 402×874); screenshot pixels ÷ 3
(scale) = points.

## Driving without input injection (launch arguments)

DEBUG builds expose launch arguments that reach key screens with zero taps —
the reliable path when HID input is broken (see Caveats):

```bash
xcrun simctl launch $UDID com.caffeineplz.SwiftClaw \
  -SwiftClawInitialNavigationItem research   # land on a tab (home/chats/workspace/research/settings)
# Research fixtures: seed 4 sessions (completed w/ citations+evidence+⚠,
# partial w/ degradation notes, awaiting-plan-approval, failed):
xcrun simctl launch $UDID com.caffeineplz.SwiftClaw -research-fixture
# ...and deep-link straight to the completed report via the real
# notification-routing path:
xcrun simctl launch $UDID com.caffeineplz.SwiftClaw -research-fixture -research-fixture-open
```

Notes: fixtures only seed an empty store (uninstall the app or erase the
sim to reseed); suppress the first-launch notification offer with
`defaults write com.caffeineplz.SwiftClaw state.notifications.launchPromptCompleted -bool true`
before launching. `NoteProposalFixtureLaunch` is the equivalent for Notes.

## Caveats

- **Why the HEAD companion is required (resolved 2026-07-19)**: a macOS
  27.0 seed update (auto-installed 2026-07-17, build 26A5378n) activated
  `dtuhidd` (`/usr/libexec/dtuhidd`), a per-simulator HID daemon that
  launchd respawns on every device boot. While it's in the sim's process
  tree, the simulator suppresses the legacy Indigo HID channel that
  idb-companion 1.1.8 used: mach sends still return success (the companion
  logs "hid succeeded") but backboardd receives nothing — taps, HOME, and
  swipes all silently no-op while AX reads and screenshots (different
  channels) keep working. No amount of killing dtuhidd /
  CoreSimulatorService, rebooting sims, or rebooting the host restores the
  legacy path. HEAD's `FBSimulatorDTUHIDTransport` speaks dtuhidd's XPC
  protocol instead and is auto-selected when dtuhidd is present; tap,
  swipe, and `ui text` are all verified working through it. Not
  implemented on that transport yet (throws `notImplementedOnDTUHID...`
  instead of no-oping): trackpad gestures and some `ui button` presses
  (e.g. HOME) — pull + rebuild to pick these up as upstream adds them.
  If input injection is ever unavailable again, the fallbacks are
  launch-argument driving (below) or driving Device Hub
  (`/Applications/Xcode.app/Contents/Applications/DeviceHub.app`) via
  codex computer use — clicks and typing into its streamed simulator
  display work, though typed text can drop a trailing keystroke, so avoid
  asserting on exact typed strings.
- SwiftUI sheets sometimes collapse `ui describe-all` to just the app root
  element — fall back to a screenshot plus coordinate math.
- An occasional tap silently misses; re-tap once before concluding a control
  is broken.
- Kill the companion (`pkill -f idb_companion`) when done.
- Host-side (macOS app) GUI automation is a separate problem — accessibility
  APIs *read* fine from an agent shell, but synthetic AX "typing" does not
  make an NSTextView first responder, so key events and caret-dependent UI
  (e.g. completion-popup anchoring) will misbehave under AX-injected input
  even though the app is correct under real input. Verify keyboard paths
  with hosted-NSTextView integration tests instead (see
  `SwiftClawTests/Notes/NoteEditorViewKeyboardTests.swift`).
