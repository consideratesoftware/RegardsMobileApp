# Android accessibility — standing rules (seed)

Pattern source: `ios/docs/accessibility.md`. This file becomes binding at
AN-10; the rules below apply from the first composable regardless.

- Touch targets ≥ 48dp.
- Every icon-only actionable element has a `contentDescription`; Android
  Lint's `ContentDescription` check is promoted to error (the Compose analog
  of the SwiftLint `button_requires_accessibility` rule).
- Font scale honored through the largest system setting; no clipped text.
- Reduce-motion (`ANIMATOR_DURATION_SCALE` 0) respected.
- TalkBack manual smoke before any UI-touching merge (script lands at AN-10,
  mirroring `ios/docs/accessibility-smoke.md`).
- Accessibility Test Framework checks wired into screen tests (AN-10).
- Same flake discipline as iOS: reproduce ≥ 2/5 before fixing; prefer deleting
  cleverness over adding waits; repeated stress belongs to post-merge/nightly
  automation, not PRs (decision #39).

## Screens audited

| Screen | ATF checks | TalkBack smoke | Notes |
|---|---|---|---|
| — | — | — | Table fills as screens land (AN-08+). |
