# Headless iOS-simulator UI verification (idb)

macOS 27 removed Simulator.app (Device Hub replaced it), and Device Hub does
not reliably expose the simulator's UI to macOS accessibility — so GUI
automation of the *host* cannot tap inside the simulator. `idb` (Facebook's
iOS Debug Bridge) injects taps into the simulator directly, no host GUI
involved. Combined with `simctl io booted screenshot`, an agent can navigate
and visually verify iOS UI entirely from the shell.

Verified working 2026-07-16 against Xcode 27 / iOS 27 simulators.

## One-time setup

The paths below under `~/.local/share/idb/` are the conventional install
location this doc's snippets assume; check for them before reinstalling.

- Companion: `brew install facebook/fb/idb-companion`
- Python client (`fb-idb`) in a venv:
  `python3 -m venv ~/.local/share/idb/venv && ~/.local/share/idb/venv/bin/pip install fb-idb`
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

- **Stale CoreSimulatorService after host sleep/lock**: taps (and even
  `ui button HOME`) silently no-op on every simulator while AX reads and
  `simctl io screenshot` keep working, and the companion still logs
  "hid succeeded". Fix: `xcrun simctl shutdown all`, kill the
  `CoreSimulatorService.xpc` process (it relaunches on demand), reboot the
  device, restart the companion. Rebooting only the simulator does NOT help.
  **2026-07-18: the fix is not reliable.** One session had taps working but
  `ui text` no-oping, and after the CoreSimulatorService restart *all*
  input (taps included) stayed dead across app relaunches, fresh
  companions, and a device reboot; only screenshots and AX kept working.
  When input dies mid-session, don't burn time on restarts — switch to
  launch-argument driving (below) and screenshot verification.
  **2026-07-19: confirmed host-level and reboot-proof** — after a full
  machine reboot, fresh boots of two different devices, and a fresh
  companion, no HID landed at all (taps, HOME, swipes) while AX reads and
  screenshots worked and the companion logged "hid succeeded" throughout.
  Xcode (27A5218g) and idb-companion (1.1.8) versions unchanged from when
  it worked, so treat idb HID injection as unreliable on this setup.
  **Working alternative: drive through Device Hub via codex computer use**
  (`/Applications/Xcode.app/Contents/Applications/DeviceHub.app`) — clicks
  and typing into its streamed simulator display work, combined with
  `simctl io ... screenshot` for framebuffer captures. One caveat: typed
  text can drop keystrokes (a trailing character went missing), so avoid
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
