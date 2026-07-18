---
name: verify
description: Build, launch, and drive SwiftClaw on the iOS simulator to verify changes at the UI surface — headless screenshots + idb taps, plus defaults seeding for model/provider state.
---

# Verifying SwiftClaw changes at runtime

Mechanics for headless simulator driving (idb setup, shadow-Xcode
workaround, tap/screenshot commands) live in
`docs/testing/SIMULATOR_UI_VERIFICATION.md` — read that first.
This file adds the build/seed/launch recipe that works end to end.

## Build + install (iOS simulator)

```bash
UDID=$(xcrun simctl list devices booted | rg -o '[0-9A-F-]{36}' | head -1)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -scheme SwiftClaw -destination "platform=iOS Simulator,id=$UDID" \
  build -derivedDataPath /tmp/DerivedData-iOS CODE_SIGNING_ALLOWED=NO
APP=$(fd -a "SwiftClaw.app" /tmp/DerivedData-iOS/Build/Products/Debug-iphonesimulator -t d | head -1)
xcrun simctl install $UDID "$APP" && xcrun simctl launch $UDID com.caffeineplz.SwiftClaw
```

Gotcha: `fd SwiftClaw.app` over all of `Build/Products` can match a stale
`Debug-iphoneos` (device) build that fails to install — scope the search to
`Debug-iphonesimulator`.

## Seeding app state via defaults

The composer/pickers need provider models configured. `ProviderModel` arrays
are stored as JSON `Data`; write them as hex:

```bash
JSON='[{"id":"11111111-1111-1111-1111-111111111111","name":"reasoner","capabilities":["reasoning","tools","vision","json"]}]'
xcrun simctl spawn $UDID defaults write com.caffeineplz.SwiftClaw \
  settings.neuralwatt.models -data "$(printf '%s' "$JSON" | xxd -p | tr -d '\n')"
xcrun simctl spawn $UDID defaults write com.caffeineplz.SwiftClaw \
  settings.home.model -string "Neuralwatt: reasoner"
```

Key names are in `SettingsKeys` (`Settings/AppSettings.swift`); model
selections are prefixed `"<Provider>: "` per `InferenceProviderID.modelPrefix`.
Seed **before** launching; terminate the app first if already running.
Clean up seeded keys afterwards (`defaults delete`) so later sessions don't
inherit fake providers.

## Data stores (for grounding a bug in real data)

- macOS app (non-sandboxed dev build): `~/Library/Application Support/default.store`
  — this is the live one; the container copy under
  `~/Library/Containers/com.caffeineplz.SwiftClaw/` can be stale.
- Simulator: `<sim-data>/Containers/Data/Application/<app>/Library/Application Support/default.store`
- Copy `.store` + `-wal` + `-shm` to the scratchpad and query with `sqlite3`
  (SwiftData tables are `ZCHAT`, `ZEMAIL`, `ZMEMORYCOLLECTION`, …; text
  columns like `ZMEMORYENTRY.ZBODY`).

## Driving

An "Enable notifications?" alert appears on first launch — dismiss with a
tap on "Not Now" before driving. Coordinates for `idb ui tap` are logical
points: screenshot pixels ÷ 3 on iPhone 17-class devices.
