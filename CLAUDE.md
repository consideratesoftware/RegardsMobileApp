# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Source of truth

`ARCHITECTURE.md` at the repo root is the canonical design doc — now at **v1.0 (2026-07-01 rebaseline)**. It contains the vision, V1 scope, data model, channel catalog, reminder-window engine, privacy stack, the rebaselined PR-level plan (§14), the current-state ground truth (§18), the remediation register (§19), and the release/maintenance playbooks (§20/§21). When a code change and `ARCHITECTURE.md` disagree, either the code is wrong or the doc needs a sibling PR. Read §18 → §19 → §14 before implementing anything non-trivial. Section cross-references in code comments (e.g. "§11", "§5") point into this file; §1–§17 numbering is stable and must never be renumbered.

Regards is a **local-first, no-backend, no-network** mobile app. Privacy is a merge-gated invariant (see the privacy-grep guard below), not a marketing claim.

Status: pre-alpha, iOS-first. The `android/` directory does not exist yet. PRs are not currently accepted (solo project under PolyForm Noncommercial 1.0.0).

## iOS — the only live platform today

All iOS work lives under `ios/`. The Xcode project is generated from `ios/project.yml` by **XcodeGen**; never hand-edit `Regards.xcodeproj`.

### Setup

```bash
brew install xcodegen swiftlint
# Xcode 16+; Swift 6 strict concurrency is on by default.
```

### Regenerate the project after editing project.yml

```bash
cd ios && xcodegen generate
```

Commit both `project.yml` *and* the regenerated `Regards.xcodeproj/`. CI runs `xcodegen generate && git diff --exit-code` — a drifted xcodeproj fails the `xcodegen-determinism` job.

### Build and test

```bash
cd ios
xcodebuild -project Regards.xcodeproj -scheme Regards \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# Full test action (both unit + accessibility suites):
xcodebuild -project Regards.xcodeproj -scheme Regards \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

(iPhone 17 Pro matches CI's pinned simulator — `SIMULATOR` in `ios-ci.yml`. Keep them in sync.)

Run a single suite or test:

```bash
# Only the swift-testing unit bundle
xcodebuild ... -only-testing:RegardsTests test
# Only the accessibility XCUITest bundle
xcodebuild ... -only-testing:RegardsAccessibilityTests test
# A specific test identifier
xcodebuild ... -only-testing:RegardsTests/OverdueViewModelTests/testName test
```

`RegardsUITests` exists but is **not** in the default test plan — it's a placeholder for general UI automation.

### Lint

```bash
swiftlint --strict   # CI uses --strict; warnings fail
```

Notable SwiftLint customizations in `.swiftlint.yml`: a custom rule (`button_requires_accessibility`) flags `Button { Image/Spacer/EmptyView }` without an explicit `.accessibilityLabel`. Warnings are treated as errors in both Debug and Release via `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`.

## Architecture — layer purity is CI-enforced

The app follows a strict layered design (ARCHITECTURE.md §5). Two of those layer boundaries are enforced by grep-based CI guards in `.github/workflows/guards.yml`:

1. **Domain purity (§5).** `ios/Regards/Domain/**` must be pure Swift. No `import UIKit | SwiftUI | Contacts | EventKit | UserNotifications | GRDB | StoreKit`. Platform-dependent code belongs in `Regards/Platform/` or `Regards/Data/`.
2. **No networking anywhere in app sources (§11).** The `privacy-grep` job scans `ios/Regards` for call sites of `URLSession*`, `NWConnection/Endpoint/Listener/PathMonitor/Interface/Path`, `URLRequest`, `URLProtocol`, `CF{Read,Write}Stream*`. The pattern matches `Foo.` or `Foo(` — not the bare token — so the same names may appear in user-facing copy (e.g. the Transparency screen) without tripping the gate. Narrow any new copy around these terms carefully.

Layout inside `ios/Regards/`:

- `App/` — `@main` app entry (`RegardsApp.swift`) and `AppEnvironment` (the repository bundle injected at the root view).
- `Domain/` — pure-Swift entities (`Contact`, `Channel`, `TimeOfDay`, `DayOfWeek`, `ReminderWindow`, …), the `ReminderEngine`, `DuplicateDetector`, `ChannelCatalog`, `DeepLinkBuilder`. Unit-tested in isolation.
- `Data/` — GRDB records, migrations, repositories, and `MockRepositories` (seeded with the JSX-mock cast for Phase 0).
- `Platform/` — Apple-framework adapters. `Contacts/` exists (`ContactsSource` CNContactStore adapter + `ContactsImporter`, landed PR #10, currently dormant — no app callers). `Notifications/`, `Calendar/`, `DeepLinks/`, `Billing/` arrive in Phases 1C–2 (ARCHITECTURE.md §12).
- `DesignSystem/` — `RegardsDS` tokens (colors, typography, WCAG contrast helpers) and shared primitives (`Avatar`, `ChannelGlyph`, `Tag`, `Wordmark`).
- `Features/` — one folder per screen (`Overdue`, `Upcoming`, `Contacts`, `ContactDetail`, `EditContact`, `MergeDuplicates`, `ReminderWindows`, `Onboarding`, `Settings`, `Shared`). Each screen owns its `*Screen.swift` view and a `*ViewModel.swift` where stateful.
- `Resources/` — `Info.plist`, asset catalog. (`PrivacyInfo.xcprivacy` lives at `ios/Regards/PrivacyInfo.xcprivacy`, not under `Resources/` — it's added as an explicit resource in `project.yml`.)

### Phase 0 → Phase 1 dependency injection

`AppEnvironment` holds the six repositories the UI needs. In Phase 0 it's wired with `MockRepositories` (`AppEnvironment.makeMock()`) — **the real GRDB stack exists but isn't wired in yet**. The Phase 1 switch is a one-line change at the `@main` struct in `RegardsApp.swift`; no view code needs to move. Keep all new feature code talking to the `any *Repository` protocols, not concrete types.

Navigation uses **one `NavigationStack` per tab** with per-tab `NavigationPath` state, so a push inside Overdue doesn't bleed into Upcoming and tab state is preserved. `ContactDetailScreen` is constructed by a factory (`contactDetail(for:)`) so each push gets a fresh VM — don't rely on SwiftUI view identity to reset it.

## Accessibility is merge-blocking

`RegardsAccessibilityTests` runs `XCUIApplication.performAccessibilityAudit()` on every screen and fails CI on any audit finding. See `ios/docs/accessibility.md` for the standing rules (VoiceOver label completeness, Dynamic Type through `accessibility5`, WCAG AA contrast, Reduce Motion, 44×44pt touch targets, focus order). Every new screen gets a row in the "screens audited" table in that doc.

The **structural** audit categories gate merges today (`elementDetection`, `sufficientElementDescription`, `trait`) via the `structuralAuditCategories` constant in `ScreensAccessibilityTests`. The **sensory** categories (`contrast`, `hitRegion`, `dynamicType`, `textClipped`) are temporarily off and tracked in the "Sensory-audit carve-outs" section of `accessibility.md`; PR34 (ARCHITECTURE.md §14) flips the constant to all categories.

UI-test flakiness rule (learned in PRs #11/#12): don't `waitForExistence` on predicate-matched queries — plain element queries for waits, predicates for read-after-known. Run `ios/scripts/audit-stress.sh` (5 consecutive audit runs) before pushing any UI-test change.

Manual VoiceOver smoke (`ios/docs/accessibility-smoke.md`) is expected before any UI-touching merge.

## Info.plist privacy invariants

The app target in `project.yml` pins ATS to deny all loads:

```yaml
NSAppTransportSecurity:
  NSAllowsArbitraryLoads: false
  NSAllowsArbitraryLoadsInWebContent: false
  NSAllowsLocalNetworking: false
```

Do not loosen these. Any channel deep link that needs `canOpenURL` must be added to `LSApplicationQueriesSchemes` in `project.yml`; prefer universal HTTPS links (wa.me, t.me, ig.me) where available so the declaration isn't needed.

## CI map

- `.github/workflows/ios-ci.yml` — xcodegen determinism → build → (unit tests + coverage) + (accessibility audit). No snapshot job exists yet — only a deferral comment at the bottom of the file; PR34 adds the real job.
- `.github/workflows/guards.yml` — privacy-grep, domain-purity-grep, project.yml YAML syntax, markdown link check for `ios/docs/` (PR19 extends it to root markdown).
- `.github/workflows/lint.yml` — `swiftlint --strict`.
- `.github/workflows/audit-stress.yml` — builds the a11y bundle once, runs it 5× per PR (flake detector).

All four workflows gate merges; path filters were deliberately removed (PR #15) so required checks always report.

## Things to avoid

- Hand-editing `Regards.xcodeproj/` — always go via `project.yml` + `xcodegen generate`.
- Importing Apple frameworks from `Domain/`.
- Adding any networking primitive — even via an indirect wrapper — without explicitly updating ARCHITECTURE.md §11 and the privacy-grep guard first.
- Writing back to system Contacts outside the partial-field `CNSaveRequest` pattern described in §7 (never delete, never bulk-edit, never merge system contacts — merges are virtual via the local `ContactGroup` table).
- Adding an OAuth calendar integration. This is an explicit non-goal (§3); local EventKit only.
- Marking a remediation item done without meeting its acceptance check — the open register is ARCHITECTURE.md §19; every fix PR cites its R-numbers.
