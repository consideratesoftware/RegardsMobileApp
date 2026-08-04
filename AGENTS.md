# AGENTS.md

This file provides guidance to any implementation or review agent working with
code in this repository. Provider-specific files are adapters, not independent
sources of project law.

## Source of truth

`ARCHITECTURE.md` at the repo root is the canonical design doc — now at
**v1.0 (2026-07-01 rebaseline)**. `TESTFLIGHT_PLAN.md` is the live execution
queue and restart protocol. When code and `ARCHITECTURE.md` disagree, either
the code is wrong or the doc needs a sibling change. Read §18 → §19 → §14,
then `TESTFLIGHT_PLAN.md`, before implementing anything non-trivial. Section
cross-references in code comments point into `ARCHITECTURE.md`; §1–§17 must
never be renumbered.

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
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -onlyUsePackageVersionsFromResolvedFile build

# Full test action (both unit + accessibility suites):
xcodebuild -project Regards.xcodeproj -scheme Regards \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -onlyUsePackageVersionsFromResolvedFile test
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

The unused `RegardsUITests` placeholder target was removed in TF-01. User-flow
automation belongs in `RegardsAccessibilityTests` until a real general UI suite
has an owned release criterion.

### Lint

```bash
swiftlint --strict   # CI uses --strict; warnings fail
```

Notable SwiftLint customizations in `.swiftlint.yml`: a custom rule (`button_requires_accessibility`) flags `Button { Image/Spacer/EmptyView }` without an explicit `.accessibilityLabel`. Warnings are treated as errors in both Debug and Release via `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`.

## Architecture — layer purity is CI-enforced

The app follows a strict layered design (ARCHITECTURE.md §5). Two of those layer boundaries are enforced by grep-based CI guards in `.github/workflows/guards.yml`:

1. **Domain purity (§5).** `ios/Regards/Domain/**` must be pure Swift. No imports from `UIKit`, `SwiftUI`, `Contacts`, `EventKit`, `UserNotifications`, `GRDB`, `StoreKit`, or `Network`, including preconcurrency and selective imports. Platform-dependent code belongs in `Regards/Platform/` or `Regards/Data/`.
2. **No networking anywhere in app sources (§11).** The shared privacy guard scans `ios/Regards` for call sites of `URLSession*`, `NWConnection/Endpoint/Listener/PathMonitor/Interface/Path`, `URLRequest`, `URLProtocol`, `NSURLConnection`, `CFSocket*`, and `CF{Read,Write}Stream*`. The pattern matches `Foo.` or `Foo(`, so the same names may appear as bare tokens in user-facing copy without tripping the gate. Narrow any new copy around these terms carefully.

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

UI-test flakiness rule (learned in PRs #11/#12): don't `waitForExistence` on predicate-matched queries — plain element queries for waits, predicates for read-after-known. PRs run the focused accessibility regressions affected by the diff; repeated 5× stress belongs to the post-merge, nightly, and pre-release automation. Use `ios/scripts/audit-stress.sh` locally only to investigate a reproduced flake or an explicitly requested release candidate, not as a routine PR gate.

Manual VoiceOver smoke (`ios/docs/accessibility-smoke.md`) is expected before any UI-touching merge.

## Info.plist privacy invariants

The app target in `project.yml` keeps ATS strict with every developer-added
exception disabled:

```yaml
NSAppTransportSecurity:
  NSAllowsArbitraryLoads: false
  NSAllowsArbitraryLoadsInWebContent: false
  NSAllowsLocalNetworking: false
```

Do not loosen these. Any channel deep link that needs `canOpenURL` must be added to `LSApplicationQueriesSchemes` in `project.yml`; prefer universal HTTPS links (wa.me, t.me, ig.me) where available so the declaration isn't needed.

## CI map

- `.github/workflows/ios-ci.yml` — xcodegen determinism → build → unit tests with a ≥95% Domain coverage floor; the post-merge accessibility audit runs separately. No snapshot job exists yet — only a deferral comment at the bottom of the file; PR34 adds the real job.
- `.github/workflows/guards.yml` — privacy-grep, domain-purity-grep, project.yml YAML syntax, and Markdown link checks for root docs plus `ios/docs/`.
- `.github/workflows/lint.yml` — `swiftlint --strict`.
- `.github/workflows/audit-stress.yml` — builds the a11y bundle once, runs it 5× (flake detector). Since 2026-08-02 it runs on merges to `main`, nightly, and `workflow_dispatch`, not on pull requests; dispatch it and require green before cutting a release.
- `.github/workflows/claude-pr-review.yml` — runs the staged hosted review from
  default-branch policy, gives the model only sanitized regular-file review
  data with a read-only token, then validates and publishes the typed verdict
  from a separate trusted job.

Three workflows gate merges through required checks. The hosted staged review
is bound as a fourth required context (`Regards staged review`, pinned to the
dedicated App's identity), but it gates on *evidence, not agreement*: it fails
when no valid review ran for the current head, and passes when a review ran,
including one that requests changes. The blockers are published in the check
summary and output; acting on them is the author's call. Path filters were
deliberately removed (PR #15) so required checks always report. The
accessibility audits moved off the PR path on 2026-08-02 and are
release-blocking rather than merge-blocking (ARCHITECTURE.md §10).

## Durable execution

Every autonomous run begins with the restart protocol in
`TESTFLIGHT_PLAN.md`. Resume dirty work and open pull requests before taking a
new item. Work on one stable `TF-##` item at a time and update its checkpoint
in the same pull request. Git branches, the worktree, pull-request checks, and
the plan file are the durable handoff; never depend on chat history. Scheduled
runs also inspect the latest completed default-branch accessibility audit and
5× stress workflows. A reproducible failure on current `main` becomes the next
repair before new feature work.

## PR review

Every PR gets the same multi-agent review before merge. Codex invokes
`$regards-pr-review`; Claude Code invokes `/pr-review`. Both pre-flight the
mechanical gates, then use the mirrored read-only agents:
`pr-correctness`, `pr-security-privacy`, and `pr-code-quality` always;
`pr-tests` for code/test changes; and `pr-accessibility` plus
`pr-fit-finish` when their UI/docs path rules match. Any blocker means
`REQUEST_CHANGES`. Claimed R-closures are verified against §19 acceptance
checks. `.agents/README.md` describes the adapters, and
`scripts/check-review-agent-parity.sh` prevents their contracts from drifting.
The hosted review check is bound to the dedicated Regards review GitHub App
(app id `4461672`), not only to its context name, so a same-repository Actions
job cannot satisfy it. A blocker still means `REQUEST_CHANGES`, but the check
reports whether a valid review ran, not whether it approved; read the check
output and clear or consciously defer each blocker before merging. The workflow
runs only when a PR targets the default branch, so a stacked draft stays on its
parent until the parent merges. Retarget and rebase the child, publish it, then
push the rebased head to trigger the hosted review against the final base.

## Things to avoid

- Hand-editing `Regards.xcodeproj/` — always go via `project.yml` + `xcodegen generate`.
- Importing Apple frameworks from `Domain/`.
- Adding any networking primitive — even via an indirect wrapper — without explicitly updating ARCHITECTURE.md §11 and the privacy-grep guard first.
- Writing back to system Contacts outside the partial-field `CNSaveRequest` pattern described in §7 (never delete, never bulk-edit, never merge system contacts — merges are virtual via the local `ContactGroup` table).
- Adding an OAuth calendar integration. This is an explicit non-goal (§3); local EventKit only.
- Marking a remediation item done without meeting its acceptance check — the open register is ARCHITECTURE.md §19; every fix PR cites its R-numbers.

## Imported Claude Cowork project instructions
