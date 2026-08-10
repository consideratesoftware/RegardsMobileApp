# Regards iOS — accessibility rules

The app must be fully usable by someone who relies on VoiceOver, larger text,
reduced motion, or high-contrast modes. This is a **release-blocking** concern,
not a polish-phase one.

As of 2026-08-02 the one-run automated audit runs after merges to `main`. The
five-run sweep runs nightly and on demand before release; neither runs on pull
requests (ARCHITECTURE.md §10 has the reasoning). On a pull request the gate is
the `pr-accessibility` reviewer plus the manual VoiceOver smoke. Before cutting
a release, run the five-run sweep with `workflow_dispatch` on `Audit stress`
and require it green. UI pull requests run focused regressions for their
affected flows because a regression now surfaces on `main`. Repeated local
sweeps are reserved for investigating a reproduced flake or an explicitly
requested release candidate.

Keep this file up to date. Every new screen gets a line in the *screens
audited* table.

## Standing rules (every UI change)

1. **Automated audit.** `XCUIApplication.performAccessibilityAudit()` runs in
   `RegardsAccessibilityTests`: once after merges to `main`, five times nightly,
   and five times by manual dispatch before release. The enabled structural
   categories catch missing descriptions, elements trapped from VoiceOver
   focus, and incorrect traits. The sensory categories remain carved out below.
   A failing sweep blocks release and must be repaired before the next
   TestFlight build.
2. **VoiceOver label completeness.** Every interactive element has an
   `.accessibilityLabel`. Decorative glyphs (channel icons inside labeled rows)
   are `.accessibilityHidden(true)` so they don't pollute the rotor. Compound
   rows collapse into **one** accessibility element with a natural-language
   label and a meaningful hint.
3. **Dynamic Type through `accessibility5`.** System fonts scale automatically;
   custom sizes use `@ScaledMetric`. Layouts use `ViewThatFits` or stacked
   variants at the largest sizes so text never clips or truncates mid-word.
4. **Color contrast verified in code.** `ColorContrastTests` (lands in PR2)
   asserts every foreground/background pair the design system exposes meets
   WCAG AA (≥4.5:1 for body text, ≥3:1 for large text and icons). Palette
   tweaks that drop a pair below threshold fail CI before they ever land in a
   screen.
5. **Reduce Motion honored.** All transitions respect
   `@Environment(\.accessibilityReduceMotion)`. No parallax, no spring bounces,
   no auto-advancing carousels. Contact-row matched zoom transitions are
   explicitly replaced by the standard navigation push when Reduce Motion is
   enabled.
6. **High-contrast + Differentiate Without Color tested.** Snapshot tests
   (PR3) cover `colorSchemeContrast = .increased` and
   `accessibilityDifferentiateWithoutColor = true`. Information conveyed by
   color (e.g., priority tiers) has a non-color indicator too.
7. **Touch targets ≥ 44×44pt.** Enforced by the audit plus a design-system
   `MinTapArea` modifier on anything interactive.
8. **Keyboard / Switch Control / Voice Control.** Focus order follows reading
   order; use `.accessibilitySortPriority` only when the default is wrong.
   Every tappable view responds to the default accessibility action.
9. **VoiceOver manual smoke before merge.** See
   [`accessibility-smoke.md`](accessibility-smoke.md) — work through the
   script on a simulator (or real device) before merging any PR that changes
   UI. Note the result in the PR description.
10. **Documentation.** Every new screen gets a row in the table below.

## Contrast-pair registry

`RegardsPalette` is the single source of truth for rendered design-system
colors and their sRGB contrast inputs. The asset catalog retains only colors
used by system-owned surfaces (`AccentColor` and `LaunchBackground`).

| Foreground | Background | Ratio (light) | Ratio (dark) | Required | OK |
|---|---|---|---|---|---|
| Ink | Background | ~13.5:1 | ~15.2:1 | 4.5:1 | ✅ |
| Muted | Background | ~5.6:1 | ~5.8:1 | 4.5:1 | ✅ |
| Muted | Hair Soft | ~4.7:1 | ~6.0:1 | 4.5:1 | ✅ |
| Accent Ink | Accent Soft | ~6.9:1 | ~6.6:1 | 4.5:1 | ✅ |
| Accent Ink | Background | ~7.8:1 | ~8.6:1 | 4.5:1 | ✅ |
| Background | Accent Ink | ~7.8:1 | ~8.6:1 | 4.5:1 | ✅ |
| White | AccentColor | ~3.4:1 | ~3.1:1 | 3:1 (large/icon) | ✅ |

PR2 adds `ColorContrastTests` so these ratios are asserted automatically; the
table becomes the human-readable mirror of the test data.

**PR1 validation.** The initial Muted value derived from the JSX mock
(`oklch(0.52 …)`) computed to ~3.9:1 vs Background in sRGB. The launch-screen
accessibility audit caught this on first run and the value was darkened to
`#6B6359` (light) to pass ≥4.5:1. Keep the next palette edit honest —
`performAccessibilityAudit()` will catch regressions, but the contrast-pair
test in PR2 will catch them *before* they ship.

## Screens audited

The gate is `ScreensAccessibilityTests.structuralAuditCategories`
(`elementDetection + sufficientElementDescription + trait`). Sensory findings
are documented below under *Sensory-audit carve-outs*.

`ChannelMetadata.helpText` is not rendered by the current Phase 0 shell.
When the channel form begins consuming it, that PR must include the text in its
screen-level VoiceOver smoke and automated audit coverage.

| Screen | PR | Notes |
|---|---|---|
| Launch / root placeholder | PR1 (`9501d57`) | One-view smoke — superseded by the Overdue landing check in PR3. |
| Launch failure | TF-02 / PR20 | Triggered by a production database-open failure; audits `launch.failure` and verifies “Try Again” recovers into onboarding. |
| Overdue (landing after splash) | PR3 / TF-01 | Default tab after splash; native large title and iOS 26 route-control glass. |
| Upcoming | PR3 / TF-01 | Native large title and modern empty state. |
| All Contacts | PR3 / TF-01; corruption banner TF-03 / PR21 | Search-role destination on iOS 18+; embedded search fallback on iOS 17. R50: when `fetchAllWithDiagnostics()` reports one or more undecodable rows, a conditional banner (`contacts.corruption-banner`, `.accessibilityElement(children: .combine)`, icon `.accessibilityHidden(true)`) renders above the list with a combined label equal to the visible "N contact(s) couldn't be read and need attention." message — proven by `AllContactsCorruptionAccessibilityTests` (unit-level UIKit accessibility-tree inspection, since the XCUITest mock fixtures never produce a corrupt row). Manual VoiceOver smoke for this state is outstanding — see `accessibility-smoke.md`. |
| Settings | PR3 | |
| Contact Detail (via Contacts → row) | PR3 / TF-01 | Stable-ID destination with a fresh ViewModel per push. |
| Contact Detail (via Overdue → row) | PR5 (`ios/phase-0-a11y-tighten`) | Factory-built VM per push. |
| Contact Detail (via Upcoming → row) | PR5 | Factory-built VM per push. |
| Contact Preview (via Contacts → Contact Detail → Edit) | TF-01 / GitHub PRs #23, #37 | Structural audit coverage, speakable preferred-field state, and standard Back escape route; the real form remains TF-09. |
| Reminder Windows | PR3 | Reached via Settings → Reminder windows. |
| Merge Duplicates | PR3 / TF-01 | Reached via Settings → Find duplicate contacts; candidate choices survive a tab-root round trip. |
| Transparency | PR3 | Reached via Settings → Transparency. |
| Onboarding | PR3 / TF-02 | First-launch Contacts pre-prompt plus Settings preview. TF-02 audits the fresh flow at `accessibility5` before import and verifies the production-backed tab transition. |

## Known system-UI audit interruption

Every automated finding defaults to an app finding. The iOS **Ready for Apple
Intelligence** notification can overlay the simulator during an audit. Run
`31334462438` attempt 2 captured "Potentially inaccessible text" against that
banner; its xcresult screenshot and failure attachment identified the targeted
element inside the iOS notification rather than the Regards hierarchy.

Classify a future finding as system UI only when the failed xcresult identifies
the targeted element inside an operating-system banner or hierarchy and the
screenshot shows that overlay. Inspect both artifacts and rerun the exact
failed job. Without both proofs, or when an app-owned failure repeats under
§17, treat it as a product finding.

## Sensory-audit carve-outs

The enabled automated audit set uses the **structural** categories
(`elementDetection`, `sufficientElementDescription`, `trait`) in the one-run
post-merge audit and the five-run nightly or pre-release sweep. The **sensory**
categories — `contrast`, `hitRegion`, `dynamicType`, `textClipped` — are not
part of that release gate. The residual findings after PR4's sweep fall into
two buckets, both intentional:

### Bucket 1 — fixed

- **Contrast** on high-traffic pills / buttons / system chrome: swapped
  from `RegardsDS.accent` (~3.4–3.7:1 against white / translucent-white,
  below AA body) to `RegardsDS.accentInk` (~8:1). Applies to the tab-bar
  `.tint`, Transparency hero claim card, Merge Duplicates "Merge virtually"
  button, Reminder Windows active day pill, Onboarding "Allow contacts access"
  button, and every in-card nav-link text / toolbar "Edit" label.
- **Unwired actions**: Contact Detail's primary channel, Caught up, Snooze, and
  Log other actions plus Overdue's channel pills are muted, noninteractive
  content until TF-04 and TF-08 supply persistence and routing. Their labels
  include “unavailable” without exposing a false button trait.
- **Navigation**: Overdue / Upcoming row taps now push Contact Detail via
  per-tab `NavigationPath`; the tab-root factory creates a fresh VM per
  push so tapping two different contacts in succession shows the right
  data. iOS 18 matched zoom is disabled under Reduce Motion.
- **Dynamic Type on screen content**: repeated two-branch container layouts in
  the Overdue / Upcoming selector, digest, list rows, Contact Detail
  actions/interactions/cards, and Contact Preview fields use the shared
  adaptive-layout policy. Small per-control sizing choices remain inline. At
  `accessibility5`, labels, names, metadata, and CTA copy wrap without clipping
  or mid-word truncation while the standard-size layouts remain compact. Native
  navigation titles inherit the system's Dynamic Type behavior. An XCUI
  regression launches directly at `accessibility5` and verifies representative
  adaptive content occupies non-overlapping stacked frames.
- **Contact Preview field semantics**: each read-only field exposes one
  contextual label instead of separate key/value fragments. Email punctuation
  is spoken as “at” and “dot” so the structural audit and VoiceOver receive a
  human-readable label while the visible address stays unchanged. The
  preferred-field dot is included as “preferred” in the composite label.
- **Contact Detail channel semantics**: the preferred-channel summary is one
  accessibility element and uses the same typed value-speech policy as Contact
  Preview, including natural email punctuation.

### Bucket 2 — design-intent trade-offs the audit flags

Each is a decorative-brand element or a caller-tuned sizing where
matching the audit's expectation would visibly break the design:

- **Dynamic Type on decorative primitives** — `Avatar` initials,
  `Wordmark`, and `ChannelGlyph` render at fixed sizes so they fit
  inside fixed-diameter circles / fixed-height nav bars / fixed-size
  action pills at every Dynamic Type setting. All three are
  `.accessibilityHidden(true)`; the readable content is owned by each
  parent row's spoken label. Scaling broke visual bounds at
  accessibility tiers without unlocking the audit cleanly.
- **Accent color on white cards** — a few low-traffic accent-colored
  stylistic elements (pitch card accent dots in Onboarding, decorative
  ring around inner-circle avatars, the accent checkmark badge in
  Transparency) keep the bright terracotta for brand consistency even
  though the audit's strict contrast check flags them at small sizes.
- **Transparency hero card copy wrapping** — the claim card intentionally
  uses small-font footnote copy on the accent-ink surface to keep the
  hero-line serif prominent; the audit flags that line at accessibility
  sizes, but it stays readable and wraps vertically before clipping.

A future sensory-audit tightening PR can revisit any of these if the
design evolves (e.g., a brighter accent-ink, a scaled brand mark, a
redesigned hero card) — but the gate stays at the structural set
until there's a design change to chase.

## Test patterns

How you wait for a UI element matters as much as which element you wait for.
Three rules for `RegardsAccessibilityTests`, learned from real flakes.

### 1. Don't `waitForExistence` on a predicate-matched query

`waitForExistence(timeout:)` on a plain element query
(`staticTexts.firstMatch`, `descendants(matching: .any)["screen.id"]`)
resolves the moment the element appears in the tree. Fast and reliable.

`waitForExistence(timeout:)` on a predicate-matched query
(`staticTexts.matching(NSPredicate(format: "traits & %llu != 0", ...))`)
is fragile. XCUI's predicate-matching pass evaluates lazily and observes
element existence faster than it observes element traits or other
attributes. Under simulator slowness this lag can exceed the 10s
timeout, even when the underlying element is visible.

**Rule:** use predicates only for *read-after-known* (read a value when
you already know the screen is rendered), never for *wait-until-true*.

Rapid simulator relaunches can also leave duplicate tab-button elements in the
automation hierarchy or drop a synthesized tap. Wait on the plain tab bar,
resolve the named button again for every attempt, then use the canonical
non-failing bounded `exists && isHittable` poll before activation. Do not use an
XCTest predicate expectation for hittability: that path can record a test
failure while a transient element has no activation frame. Verify the
destination with its plain screen identifier while the source screen
disappears, and allow two bounded re-resolution retries with varied activation
paths. `navigateToTab` and `waitUntilLiveAndHittable` in
`ScreensAccessibilityTests` are the canonical implementation.

Apply the same pattern to pushed navigation: resolve the current trigger
element for every attempt, use the same bounded poll and varied activations,
and require the plain destination identifier to appear while the source screen
identifier disappears. `launchToContactDetailFromContacts`,
`navigateFromSettings`, `navigateToRow`, and the consolidated `navigate` helper
are the canonical implementations.

The varied activation paths are synchronization workarounds for dropped
Simulator events. They do not replace hit-region coverage: the sensory audit
owns that check when its temporary carve-out is removed.

This was the underlying race behind `testContactDetailPassesAudit`
flaking on three consecutive main runs in May 2026. The current tests wait on
the plain toolbar `Edit` button, which appears only after the contact finishes
loading and avoids both predicate timing and ScrollView descendant-query
instability.

### 2. ContactDetail "settled" means visible content exists, not only the screen identifier

`screen.contact-detail` becomes findable as soon as the identifier is
added to the tree, which can happen mid-transition. `viewModel.load()`
is async; the screen renders a `ProgressView` (no static text) until it
resolves. Wait for the visible toolbar `Edit` button instead — it exists only
after the if-let-loaded body branch has rendered, which is when the audit can
run cleanly. Do not reintroduce a predicate-backed wait helper or scope the
load signal beneath the ScrollView identifier.

### 3. Let scheduled automation own repeated stress

Run the focused `RegardsAccessibilityTests` cases affected by a UI or UI-test
diff before pushing. Do not make a repeated full-suite sweep a routine PR gate.
If a scheduled run reproduces a flake, or a release candidate explicitly needs
local validation, use:

```bash
ios/scripts/audit-stress.sh    # default 5 runs
ios/scripts/audit-stress.sh 3  # custom run count
```

The script builds once and runs the audit suite N times via
`test-without-building`, exits non-zero on any failure. Total runtime
on a recent Mac: ~3 min.

CI runs one audit after merges through `.github/workflows/ios-ci.yml`. The 5x
sweep runs nightly and through `workflow_dispatch` in
`.github/workflows/audit-stress.yml`. Those runs own broad flake detection. A
failure blocks the next release and becomes the next repair item; it does not
justify rerunning the full suite during every PR.
