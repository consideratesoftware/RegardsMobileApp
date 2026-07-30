# Regards — iOS

Native iOS app built against ARCHITECTURE.md §6 (Swift 6 / SwiftUI / GRDB,
iOS 17+). Source of truth for the Xcode project is [`project.yml`](project.yml);
the `Regards.xcodeproj` is regenerated from it.

## One-time setup

```bash
brew install xcodegen
```

You need Xcode 16 or newer. Swift 6 strict concurrency is on by default.

## Regenerate the Xcode project

Any time `project.yml` changes:

```bash
cd ios
xcodegen generate
```

Commit both `project.yml` and the regenerated `Regards.xcodeproj/`.

CI runs `xcodegen generate && git diff --exit-code` on every push — if the
committed xcodeproj drifts from `project.yml`, the build fails.

## Build + test

```bash
cd ios
xcodebuild \
  -project Regards.xcodeproj \
  -scheme Regards \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  build

xcodebuild \
  -project Regards.xcodeproj \
  -scheme Regards \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  test
```

The `test` action runs:

- **`RegardsTests`** — `swift-testing` unit suite for Domain, Data, Platform,
  and feature behavior.
- **`RegardsAccessibilityTests`** — XCUITest suite that launches the app and
  calls `XCUIApplication.performAccessibilityAudit()`. A failing audit blocks
  merge. See [`docs/accessibility.md`](docs/accessibility.md) for the standing
  rules.

`RegardsUITests` is a separate target for general UI automation and is not
wired into the default test plan yet.

## Execution plan

See [`../TESTFLIGHT_PLAN.md`](../TESTFLIGHT_PLAN.md) for the live queue and
restart checkpoint. `ARCHITECTURE.md` §14 remains the canonical scope and
acceptance-criteria map.
