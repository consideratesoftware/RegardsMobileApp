# TestFlight execution plan

This file is the durable control plane for taking Regards from `main` to
TestFlight. `ARCHITECTURE.md` remains the product and technical source of truth.
This file replaces only the stale calendar dates and overloaded PR numbers in
§14 with stable work IDs, live state, and a restart protocol.

The Android track has its own queue (`AN-##`) in `ANDROID_PORT.md`. Nothing in
this file governs `android/`, TF items never depend on AN items, and the
Android gate line is decision #41 — an agent resuming from this file should
never pick up Android work.

## Current checkpoint

- Updated: 2026-10-29
- Baseline: `main` at `0b784d7` (merge of PR #66, `TF-07a`, the engine,
  merged 2026-10-28). PR #65, `TF-07b` (schema v3 and `observeSchedule`),
  merged as `a09138d` on 2026-10-17. PR #64, the `TF-05` and `TF-06`
  fast-follow, merged as `3ebe90e`. `TF-05` merged as PR #63 (`a887ece`),
  and `TF-06` merged as PR #62 (`de33098`).
- Active work: `TF-07c` is PR #67 (`claude/tf-07c-pass-core`), in review, database half only. `TF-07d` through
  `TF-07g` follow it in the same lane. `TF-11` is in progress on `claude/tf-11-onboarding` in its own lane.
  Owner ruling 8 moved every device-only check to the pre-release device pass (see `Owner gates`), so TF-03's
  device acceptance no longer blocks `TF-07` or `TF-11`. `TF-03`'s code is merged in PR #48.
- Next ready work: none. `TF-07d` through `TF-07g` wait for `TF-07c`.
- Blocked: none on `TF-03`. Each `BLOCKED` row still waits on its own
  dependency column.
- Open pull requests: #67 (`TF-07c`, `claude/tf-07c-pass-core`). Checked with `gh pr list --state open` on 2026-10-29.
- Worktree hazard: a file-sync process in this worktree creates byte-identical
  `"* 2"` copies of recently written files, and `git add -A` sweeps them into
  commits. PR #43 carried twelve before review caught them; `main` has none.
  Standing mitigation for any agent in this worktree: never `git add -A`.
  Stage explicit paths, and check `find . -name "* 2.*"` before committing.
- Stress job: the nightly `Audit stress` run has been red or cancelled since
  about 2026-09-21, with 1 pass in the last 20 runs. Each 5x iteration takes
  about 13 minutes (39 tests). Five iterations take about 65 minutes, and
  setup, boot, and build add about 8 more, so a full run needs about 73 minutes
  against the old 75-minute limit. Two runs failed at the 10-minute boot step
  limit. On 2026-10-09, `bootstatus` took 8.7 minutes, and the status-bar setup
  after it pushed the step past 10 minutes.
- Green CI on `0b784d7`: Lint (`40753820101`), Guards (`40753820056`), and
  iOS CI (`40753820180`) all passed. Checked with `gh run list` on 2026-10-28.
- Owner action needed: the pre-release device pass, which runs before release.
  See `Owner gates`. No queue item waits on it.

- Internal TestFlight gate: after both `TF-08` and `TF-11`
- External TestFlight gate: after `TF-18`
- Continuation: active Codex heartbeat `continue-regards-work-after-pr-20`,
  every 3 hours, targeting this persistent task
- Copyright owner: repository, product, and App Store references use
  `Considerate Software LLC`; the PolyForm Noncommercial terms are unchanged.

- Owner rulings, 2026-10-11 ([PR #58 comment](https://github.com/consideratesoftware/RegardsMobileApp/pull/58#issuecomment-6113801644)):
  - `TF-05` and `TF-06` run in parallel despite sharing the `RegardsApp`,
    generated-project, and execution-docs locks. The second to merge rebases
    and regates.
  - `R55` moves to `TF-07`.
  - `TF-06`'s on-device exit checks (a notification fires at a window
    boundary; its actions round-trip) move to `TF-07`'s airplane-mode device
    test.
  - `TF-05` rulings (extra repair rounds on slices 1 and 3; silent discard of
    unsaved editor edits; the Overdue footer's time removed, with nothing
    computed in its place): recorded in the TF-05 PR's first comment
    (https://github.com/consideratesoftware/RegardsMobileApp/pull/63#issuecomment-6170431309;
    owner rulings 2, 3, 5, and 6).
- Owner decisions (rulings 4 to 6, [rulings comment](https://github.com/consideratesoftware/RegardsMobileApp/pull/62#issuecomment-6138950217)): keep the Settings row's copy permission-only until TF-07 schedules reminders; the Snooze action label is "Snooze 1 week"; ship the Settings row in TF-06. The first TestFlight build waits for TF-08 and TF-11 (Internal TestFlight gate, Current checkpoint).
- History: the PR that carries each closed item's evidence.
  - TF-02: PR #44 (merged as `b10f9ac`) and PR #45 (merged as `ee601a5`). The
    physical-device acceptance, including the
    `NSFileProtectionCompleteUntilFirstUserAuthentication` check on
    2026-08-09, is in PR #45's checkpoint text (`git show
    ee601a5:TESTFLIGHT_PLAN.md`).
  - TF-03: code merged in PR #48 (merged as `6886be3` on 2026-08-11). PR
    #48's description records a corruption-banner VoiceOver check run
    against `--regards-mock-runtime`, with no iOS version or findings line,
    so it does not meet `accessibility-smoke.md`'s contract; a recorded
    corruption-banner VoiceOver smoke is step 7 of the acceptance run (see
    `Owner gates`).
  - TF-04: PR #49 (merged as `02873e8` on 2026-09-14).
  - TF-05: PR #63 (merged as `a887ece` on 2026-10-15). Evidence: owner
    VoiceOver smoke passed at `9caeaaa`, recorded on PR #63.
  - TF-06: PR #62 (merged as `de33098` on 2026-10-15).
  - TF-07a: PR #66 (merged as `0b784d7` on 2026-10-28).
  - Earlier checkpoint text, including the round-by-round TF-02 and TF-03
    review history, is in the git history of this file.

Only change `Active work`, `Next ready work`, and the queue status in the same
pull request that changes the corresponding implementation. A run that stops
before a commit leaves its branch and worktree as the checkpoint.

## Restart protocol

Every fresh or scheduled agent run follows this order:

1. Read `AGENTS.md`, then `ARCHITECTURE.md` §18 → §19 → §14, then this file.
2. Run `git fetch --prune origin` and inspect the branch, worktree, open pull
   requests, review comments, required checks, and the latest completed
   default-branch `Accessibility audit` and `Accessibility audit stress (5x)`
   runs.
3. If the worktree is dirty, resume it. Do not discard, stash, or overwrite it.
4. If any open pull request carries a `TF-##` marker, resume it before taking
   new work, even when the checkout is on `main` or another branch. Safely
   check out its branch when needed, address review findings, repair CI, run
   the Regards multi-agent review, and merge only when every required check is
   green and no blocker remains. Follow the dependency order in `Current
   checkpoint`. All of `TF-01`'s slices are merged: GitHub PRs #23, #37, #24,
   #39, and #42. Start no additional work while any TF branch, worktree, or
   pull request is unresolved — that general rule already opens this step, and
   it is the gate, not a hardcoded list of PR numbers that goes stale.
5. Otherwise, fast-forward `main` and reconcile this queue against merged pull
   requests carrying a `TF-##` marker. If either scheduled accessibility run
   failed on the current `main`, triage that failure before taking new feature
   work and create the smallest repair PR when it is reproducible. Otherwise
   take the first `READY` item whose dependencies are `DONE`.
6. Maintain at most three implementation lanes, and start a lane only when every
   dependency listed in this queue is `DONE`. Use linked worktrees for
   independent lanes and stacked pull requests within a dependent lane. Keep
   each diff reviewable and include its `TF-##`, §14 scope alias, and R-items
   in the pull-request body. Review and CI monitoring do not consume a lane.
7. Run proportionate local checks before push. Every pull request must pass the
   repository gates and `$regards-pr-review` (or `/pr-review`) before merge.
   The Claude Code org runs both and needs both verdicts
   (`ENGINEERING_ORG.md` merge conditions).
8. Update this checkpoint in the same pull request. Never mark an item `DONE`
   before its acceptance evidence and required checks exist.

If token capacity ends at any point, stop at the next filesystem-safe boundary.
The branch, worktree, GitHub pull request, CI state, and this file are the
handoff; chat history is never required to recover.

## Automation contract

The schedule is owner-managed Codex app state, not a repository workflow:
`/Users/sdahiya/.codex/automations/continue-regards-work-after-pr-20/automation.toml`.
It is active and targets the persistent TestFlight task. The self-contained
prompt tells each run to start with this file, so a token or context reset does
not erase execution state. If that local automation is removed or the workspace
moves to another machine, recreate one heartbeat at the owner's current cadence
from this contract. Do not add a GitHub Actions implementation that would
require a hosted coding credential.

The recurring task may create branches, edit files, run tests, commit, push,
open pull requests, address reviews, and merge a pull request once every
required check is green. The `Regards staged review` check passes whenever a
valid review ran for the current head, including one that requests changes, so
green is not the same as approved: read the check output and clear or
consciously defer every blocker before merging. It must not:

- weaken the privacy, accessibility, data-integrity, or layer-purity gates;
- discard user work or use destructive Git operations;
- invent signing, legal, pricing, privacy-label, or App Store answers;
- upload a build, change App Store Connect, contact testers, publish content,
  or perform a physical-device check without the required owner access;
- exceed the three-lane implementation WIP limit or bypass an explicit queue
  dependency. Review and CI monitoring may continue alongside all three lanes.

When an owner-only action blocks the next acceptance criterion, mark the item
`OWNER`, write one exact checklist under `Owner gates`, and continue any
independent `READY` work. Ask once, not on every scheduled run.

## Release gates

### Internal TestFlight

The first internal build is useful when production storage and import are live,
the core caught-up/snooze flow persists, reminder windows shape persisted
notifications, notification actions round-trip, deep links execute, onboarding
has grant and denial paths, all visible controls are real, and CI plus the
structural accessibility audit are green. Both `TF-08` and `TF-11` must be
`DONE` before this internal gate opens.

The owner then supplies signing/App Store access and performs the device-only
checks. Internal feedback may add P0/P1 fixes ahead of `TF-09`; it does not
silently expand V1 scope.

### External TestFlight

The external beta is feature-complete for the architecture's V1: edit,
virtual merge, calendar occasions, widgets, StoreKit trial/lifetime purchase,
export/delete, full-category accessibility, privacy-manifest declarations,
performance, release metadata, and clean archive/upload evidence. That is the
exit of `TF-18`.

## Work queue

Statuses are `DONE`, `ACTIVE`, `READY`, `BLOCKED`, or `OWNER`. Scope aliases
refer to the legacy rows in `ARCHITECTURE.md` §14; they are not GitHub PR
numbers.

| ID | Status | Depends on | Scope and exit evidence | §14 alias / R-items |
|---|---|---|---|---|
| TF-00 | DONE | — | Install this durable control plane, make both agent adapters share the same review contract, and schedule continuation | execution infrastructure; GitHub PR #22 |
| TF-01 | DONE | TF-00 | Truth, platform modernization, and hygiene pass: complete the remaining mock-state, stable-identity, dead-asset, and preservation-safe cleanup work; the completed platform, CI, package, and documentation slices agree with the repository | dedicated modernization slice in GitHub PR #24; PR18–PR19; R13 escape route, R16, R19–R22, R27–R34, R40, R42–R43 |
| TF-02 | DONE | TF-01 | Production DB v2, shared repository contracts, real environment at launch, resumable first import, and a basic onboarding gate; fresh simulator install reaches populated tabs. Includes flipping the boot path from `AppRuntime.makeMock` to `makeProduction`, the remaining half of R9a | PR20; R9a, R23, R39 |
| TF-03 | OWNER | TF-02 | Contacts reconciliation on launch/foreground/change, archive safety, limited-authorization handling, per-row import tolerance, corruption-aware All Contacts reads, and an off-cooperative-pool 5k synthetic path. Deferred to the pre-release device pass, not blocking (owner ruling 8, 2026-10-28). | PR21; R25, R35, R50 |
| TF-04 | DONE | TF-02 | Caught up, Snooze, and Log other persist from every surface they appear on (Contact Detail: all three, as buttons; Overdue: Caught up and Snooze as native `List`/`.swipeActions`, swipe right and left; Upcoming: Caught up only, cadence rows only, swipe right; neither list screen has a Log-other row action, and Upcoming ships no Snooze action; tapping a list row previews the channel action pending TF-08; both screens migrated from `ScrollView`/`RegardsCard` per-row buttons to `List` in round 12, which R52 records); Snooze via a narrow `SchedulingPass` DB-only stub (single cadence `ScheduledReminder` write, no window/engine/reconciliation — PR25 absorbs it); live lists update via `ContactRepository.observeTracked()`; interaction, action, and mock/GRDB parity tests pass | PR22; R11, R24, R34, R36, R46, R52 |
| TF-05 | DONE | TF-04 | Reminder-window editor persists valid global/per-contact windows and visibly reshapes lists; zero-capacity saves fail clearly; the editor never changes a timezone: the global editor writes back the one it loaded and a per-contact override copies the global window's (`saveNeverChangesTimezone`, the R55 ruling of 2026-10-11) | PR23; R4, R9; PR #63 (`a887ece`, 2026-10-15) |
| TF-06 | DONE | TF-04 | Local notification adapter, permission UI, categories, actions, and deterministic adapter tests. **Hard gate (owner ruling 2026-08-22): must not ship notification *scheduling* until R57 is resolved.** `SchedulingPass.snooze` writes a raw `now + 7d` with no `nextAllowedSlot` call, so a snoozed reminder's `scheduledFor` can sit outside the user's declared window. That is only a wrong displayed date today; the moment this lane wires real notifications it becomes a reminder that actually fires outside the window — the one promise §9 calls unbreakable. R57's fix is owned by TF-07, which is queued *after* this lane, so the ordering has to be enforced here rather than assumed | PR24; R11, R57 |
| TF-07 | ACTIVE | TF-04, TF-05, TF-06 (TF-03: device acceptance deferred, owner ruling 8) | SchedulingPass is the sole idempotent reminder writer; reconciliation, batching, occasions, no-double-up, orphan cancellation, and reactive Upcoming are proved. Also owns (owner rulings 2026-10-11, [PR #58 comment](https://github.com/consideratesoftware/RegardsMobileApp/pull/58#issuecomment-6113801644)): R55, and TF-06's on-device exit checks (a local notification fires at a window boundary; its Caught up and Snooze actions round-trip), run in the airplane-mode device test. TF-06 handoff (R57): restore TF-06's request builder and its tests from `fec13d7`, add `schedule`, `cancel`, and `pendingIdentifiers` reading `now` once per request, add `willPresent`, and delete `NotificationSchedulingGateTests` in the PR that resolves R57. Also closes a gap that PR #64 review (pr-correctness) found: a notification Caught up for a contact that becomes untracked between the handler's eligibility fetch and the write still logs an interaction, because `InteractionLogging.markCaughtUp` checks only `isActive`. TF-07 slice (d) keeps the notification path's eligibility check, `isCadenceEligible`, under the same lock as the interaction write, which closes it. TF-07 ships as 7 PRs: (a) engine, (b) schema v3 and observation, (c) pass core, (d) interaction consolidation, (e) OS scheduling (resolves R57), (f) reactive lists, (g) labels, badge and device acceptance. (a) merged as PR #66 (`0b784d7`, 2026-10-28); (b) merged as PR #65 (`a09138d`, 2026-10-17); (c) is PR #67 (`claude/tf-07c-pass-core`), in review; (d) to (g) follow (c). Carry-forward nits for TF-07f: `AllContactsScreen` renders an empty `Text("")` footnote when a contact has no cadence and no last interaction; Save has no progress cue while the pass runs. TF-07f MUST build Overdue and Upcoming from the `observeSchedule` snapshot, never from `fetchAllPending()` (test `corruptPendingRowKeepsOtherSnoozesAndOccasions`). | PR25; R4–R6, R10–R11, R24, R55, R57 |
| TF-08 | BLOCKED | TF-07 | Channel and notification deep-link execution works on every surface; Discord scheme is minimal; a global default channel (`.sms`) is settable in Settings and drives importer-derived per-contact preferreds; interaction logging and routing tests pass | PR26; R11, R37, R58 |
| TF-09 | BLOCKED | TF-08, TF-11 | Real Edit Contact form with dirty-field partial write-back, denial/error states, re-fetch, safe navigation, purpose string, and audit coverage. Any tracking or cadence write calls `scheduler.run(for:)` for the affected contacts. | PR27; R13, R16–R17 |
| TF-10 | BLOCKED | TF-08, TF-11 | Virtual merge, unmerge, skip, manual link, full-handle detection, grouped reminders/lists, persistence, and audits. Group collapse in the scheduling pass (one cadence reminder per group, member-max interaction) is part of this item, moved from TF-07 by owner ruling 6 (2026-10-28). | PR28; R11–R12, R24 |
| TF-11 | ACTIVE | TF-06 (TF-03: device acceptance deferred, owner ruling 8, 2026-10-28) | Three-screen onboarding, starter contacts, grant/deny/limited paths, relaunch state, notification ask, and no inert controls. In progress on `claude/tf-11-onboarding`: slices 1 to 3 are done (tracking write; starter picker from Settings; onboarding concept, contacts, and starter flow). Slices 4 (Settings Contacts re-entry) and 5 (notification ask) remain. Starter saves and later tracking or cadence writes must call `scheduler.run(for:)` for the affected contacts. Whichever of TF-07c and TF-11 merges second wires that call after the starter saves. | PR29; R11, R14 |
| TF-12 | BLOCKED | TF-09, TF-10 | Read-only EventKit occasions merge with Contacts precedence; revocation degrades safely; purpose string and tests are complete | PR30; R17 |
| TF-13 | BLOCKED | TF-12 | Widget target and App Group migration preserve the DB; read-only small/medium/lock widgets refresh from SchedulingPass | PR31 |
| TF-14 | BLOCKED | TF-02, TF-11 | StoreKit trial/lifetime entitlement, paywall, soft lock, tips, restore, and StoreKitTest suite pass without eroding no-network app code | PR32 |
| TF-15 | BLOCKED | TF-11, TF-13, TF-14 | Settings export/delete/support/transparency/entitlement surfaces work; JSON covers every table and delete returns to onboarding | PR33; R11, R15 |
| TF-16 | BLOCKED | TF-08, TF-09, TF-15, TF-17 | Full accessibility categories and 5× stress pass, snapshot gate, contrast registry, privacy required-reason entries, category/export keys, and Dynamic Type smoke | PR34; R18, R41, R44 |
| TF-17 | BLOCKED | TF-15 | String Catalog, final copy, and launch polish are complete before snapshot and accessibility baselines freeze | PR35 |
| TF-18 | BLOCKED | TF-16 | Clean archive, monotonic build number, internal feedback triage, A15 performance confirmation, device matrix, privacy/network evidence, beta metadata, signing, upload, processing, and external-group approval | §20 release playbook |

`BLOCKED` in this queue normally means “waiting on the listed dependency,” not
an implementation problem. Promote the next item to `READY` when its dependency
is merged. The owner-authorized default implementation WIP limit is three, but
the current dependency column remains authoritative until a reviewed DAG change
promotes independent items. Linked worktrees isolate independent lanes;
dependent changes use stacked pull requests in one lane.

### Three-lane dependency waves

The queue is a dependency graph, not a blanket sequence. A lane starts as soon
as its row's dependencies are `DONE`, without waiting for unrelated work in a
nominal wave. Expected concurrency is: TF-02 alone; TF-03 + TF-04; then TF-03
may continue while TF-05 + TF-06 occupy the other two lanes; TF-07 + TF-11;
TF-08 with TF-14 when ready; TF-09 + TF-10 + TF-14; TF-12 with TF-14 when
needed; then the TF-13 → TF-15 → TF-17 → TF-16 → TF-18 joins. Joins branch
from the combined current `main`, never from only one parent. Independent
siblings use separate linked worktrees. Stacks are reserved for real
dependency edges and are rebased and retargeted to `main` after their parent
merges. `TF-05` (PR #63) and `TF-06` (PR #62) both merged on 2026-10-15.

Treat shared schema/location transitions and high-collision composition as
locks, not artificial global dependencies. Only one lane may own a schema or
database-location transition. Coordinate ownership before concurrent edits to
`AppEnvironment`, `RegardsApp`, repository/migration files, SchedulingPass,
Upcoming/Overdue/Contact Detail, Onboarding/Settings, `project.yml` and its
generated Xcode project, shared accessibility helpers, or execution docs.
Simulator-heavy gates run serially unless lanes use distinct simulator clones
and DerivedData paths. A staged six-role review may temporarily consume all
subagent capacity; implementation lanes yield at a filesystem-safe checkpoint
and resume after review consolidation.

### TF-01 serial chain

TF-01 has one completed merge-gate prerequisite followed by a serial sequence
of bounded reviewable slices. The order is fixed; do not overlap them:

1. DONE: GitHub PR #26 installed the trusted hosted-review workflow, dedicated
   App check, and shared source-boundary guards. Branch protection now binds
   `Regards staged review` to App ID `4461672`; R32 is closed.
2. DONE: GitHub PR #23 merged as `a8c9c01`, completing the repository and
   documentation truth slice. It merged before the smoke-driven responsive
   accessibility and navigation-harness changes were pushed.
3. DONE: GitHub PR #37 merged as `209171c`, carrying the TF-01 accessibility
   follow-up with those exact-source changes, the completed manual smoke, and
   their review evidence.
   This closes the remaining R13, R16, R27, R28, and R43 acceptance evidence
   and confirms R29's earlier closure.
4. DONE: GitHub PR #24 merged as `a35fce9`, completing the owner-directed
   platform-modernization slice, its focused checks, exact-source manual
   accessibility smoke, and hosted-review closures.
5. DONE: GitHub PR #38 merged as `3e391c6`, repairing the current-main R49
   audit failure. Earlier iOS CI run `30842392233` and
   audit-stress run `30842392398` both failed because Upcoming discarded an
   already-overdue contact when `ReminderEngine` returned the start of the
   currently active batching slot. The 5× workflow reproduced the same three
   downstream XCUI failures in every run. Preserve the slot-start identity,
   keep the row visible, pin the active-slot regression, and require focused
   XCUI, mechanical gates, staged review, hosted review, and protected checks
   before merge. The one-run audit remains post-merge; repeated 5× stress
   remains owned by nightly automation and pre-release manual dispatch.
   The current-source focused XCUI rerun passed on the pinned simulator:
   `testAccessibility5AdaptiveContentDoesNotOverlap`,
   `testContactDetailFromUpcomingPassesAudit`, and
   `testEditContactBackReturnsToUpcomingContactDetail`.
   Manual accessibility smoke completed 2026-08-03 on the pinned iOS 26.5
   iPhone 17 Pro using Accessibility Inspector emulation. Dynamic Type was
   tested at `accessibility5`; Reduce Motion and Increased Contrast were each
   tested both on and off. Upcoming exposed a heading, selected segment, date
   heading, and 10 natural-language button rows with activation hints. A row
   remained tappable at `accessibility5`, opened Contact Detail, and retained a
   visible return path. The stacked segment, rows, icons, and priority treatment
   remained legible without clipping, washed-out pairs, or color-only meaning.
   Findings: none. Simulator settings were restored to large text, Reduce
   Motion off, and Increased Contrast off after the smoke. Exact-main iOS CI
   run `30858964352`, including the one-run accessibility audit, and 5× stress
   run `30858964211` both passed after merge.
6. DONE: GitHub PR #39 merged as `ade40e3`, closing R19, R21, R22, R31, and
   R33. It committed `Package.resolved`, removed the ownerless placeholders,
   extended root Markdown checks, installed a fail-closed 95% Domain coverage
   floor (96.88% on the merged head), removed dead SwiftLint configuration,
   and reconciled audit and merge-method documentation. Exact-head iOS CI run
   `30870019501`, hosted review run `30870018471`, and every required check
   passed. Post-merge iOS CI run `30870432645` and 5× stress run
   `30870432634` also passed.
7. DONE: GitHub PR #42 merged as `d8193ff`, completing TF-01. It seeded
   representative group, interaction, and occasion states, gave Upcoming rows
   stable IDs, and removed dead assets and their misleading comments, closing
   R34, R36, and R40. Five hosted review rounds ran against it; the repairs and
   the four consciously deferred findings are recorded below. R30 remains open:
   18 merged remote and 38 merged local branches were removed and automatic source-branch
   deletion was enabled, but the live `crazy-franklin-75fc28` worktree still
   contains 32 untracked files and `codex/pr24-pre-stack-rebase-20260730` has
   three patch-inequivalent commits. `git worktree prune --dry-run --verbose`
   finds nothing safely prunable. The patch-equivalent Android branch and
   empty `.git/t9FBrGy` are removable only after their active worktree is
   switched and the exact targets are rechecked; unique work stays preserved.
   Current-source evidence on the pinned iOS 26.5 iPhone 17 Pro: all 175 unit
   tests pass; the Overdue, Upcoming, Contact Detail representative-state
   audits and `testAccessibility5AdaptiveContentDoesNotOverlap` pass; strict
   SwiftLint, privacy/domain/Android guards, source-boundary fixtures, review
   parity, workflow YAML, diff checks, and temporary-copy XcodeGen determinism
   pass. Accessibility Inspector targeted the final Regards process and
   reported no warnings; hierarchy traversal confirmed the merged-contact,
   birthday, anniversary, and combined interaction narration. The simulator
   remained at large text with Reduce Motion and Increased Contrast off after
   the smoke.

   Hosted-review repair (2026-08-04, verdict REQUEST_CHANGES on `44ba20a`:
   1 blocker, 6 should-fix, 9 nits). Owner directed clearing the blocker and
   every should-fix and leaving the nits. Closures:

   - Blocker (`pr-tests`, ARCHITECTURE.md §13 "and failures"):
     `UpcomingViewModelStateTests` now drives `loadState == .failed` from a
     throwing contact fetch, from a throwing `fetchAllPending()` — the branch
     `fetchAllPending` newly made reachable — and after a successful load, each
     asserting empty groups and `totalCount == 0`. §13 names the suite instead
     of claiming coverage generically.
   - §9 contract 6 no-double-up: owner directed deferral to TF-07. The
     deviation is now explicit at the `buildRows` call site and in
     ARCHITECTURE.md §9 contract 6, both naming `SchedulingPass` (PR25 / TF-07,
     R6) as the owner and noting the rows keep distinct IDs (R36) meanwhile.
   - Spoken occasion label: the derivation moved off the view onto
     `UpcomingRowState.accessibilityLabel`, so it is assertable without
     instantiating `UpcomingRow`. Tests pin "Leia Organa, Jedi Order
     anniversary at {time}" verbatim, assert the raw `customOccasion` case name
     is absent, cover the cadence row, and cover the text-less row.
   - Duplicate fakes: `BoundaryReminderRepository` and
     `StaticReminderRepository` collapsed into
     `RegardsTests/Support/RepositoryFakes.swift`
     (`StubContactRepository`/`StubReminderRepository`, each with a `failing()`
     variant), reused by both files.
   - Coverage holes: a zero-capacity window drops cadence rows but keeps
     occasion rows; an untracked contact's pending occasion never reaches
     Upcoming; `Contact+Accessibility`'s `isVirtualMerged` branch gets direct
     Domain tests for tracked/untracked and inner-circle/acquaintance in the
     new `ContactMergeAccessibilityTests` (split out to keep
     `ContactAccessibilityTests` under the type-body-length limit).

   Repair evidence on the pinned iOS 26.5 iPhone 17 Pro: 187 unit tests pass
   (was 175); Domain coverage 843/870 lines = 96.90% against the 95% floor;
   strict SwiftLint zero violations across 82 files; domain-purity,
   no-network, Android domain/manifest/network, and review-parity guards pass;
   XcodeGen regenerated and deterministic. Focused XCUI
   `testUpcomingTabPassesAudit`, `testOverdueTabPassesAudit`, and
   `testContactDetailFromUpcomingPassesAudit` pass. One earlier trio run
   reported `testContactDetailFromUpcomingPassesAudit` as failing with zero
   test assertions failing: the runner exited during app launch and the
   harness restarted, which is a runner crash, not a product regression. The
   test passes in isolation and in the clean rerun.

   Second hosted review (2026-08-04, verdict APPROVE on `b58e9d9`: no
   blockers, 7 should-fix, 8 nits). Owner directed clearing every should-fix
   and leaving the nits. Closures:

   - R9 split. `AppRuntime` now composes `UpcomingViewModel` with the
     persisted window, so the global half is closed as R9a; per-contact
     override resolution and live refresh stay open as R9b against TF-05.
     §9 "Per-contact override" prose matches.
   - The documented §9 contract-6 deviation is now pinned by a test: one
     contact with both a cadence-eligible slot and a same-local-day occasion
     yields two rows with non-colliding IDs. TF-07 replaces the expectation
     with suppression.
   - `load()`'s two independent awaits are documented as accepted, one-frame,
     self-healing staleness, with the invariant TF-07's `ValueObservation`
     swap must preserve stated explicitly.
   - §13 attributes representative-state and stable-identity coverage to
     `MockRepositoriesTests`, boundaries to `UpcomingViewModelBoundaryTests`,
     and off-happy-path states to `UpcomingViewModelStateTests`.
   - `navigateToRow` polls for hittability before scrolling and adds a bounded
     scroll-back, so a row that is on screen but not yet settled is no longer
     scrolled out of the viewport. All six dependent XCUI regressions were run
     locally: `testContactDetailFromOverduePassesAudit`,
     `testContactDetailFromUpcomingPassesAudit`,
     `testEditContactBackReturnsToOverdueContactDetail`,
     `testEditContactBackReturnsToUpcomingContactDetail`,
     `testOverdueNavigationShowsDistinctContacts`, and
     `testUnavailableActionsAreDescribedAndNoninteractive`.
   - Occasion seeding routes through `MockStore.occasionInstant`, which
     handles a nil wall-clock instant instead of silently dropping the
     birthday and anniversary. Measured finding worth recording: the reported
     DST-gap drop does not reproduce — `date(bySettingHour:)` forgives a
     skipped hour and snaps forward (verified on US Pacific 2026-03-08, hour
     2), so the guard is defensive against API surface, not a fixed bug. The
     tests assert the invariant the seeds actually depend on: both occasions
     seed across four DST-transition days in three zones.
   - `ContactDetailScreen.interactionAccessibilityLabel` moved onto
     `InteractionEntry.accessibilityLabel`, matching the
     `UpcomingRowState.accessibilityLabel` move, and gained four unit tests
     including one over every `InteractionSource`.

   Second-round evidence on the pinned iOS 26.5 iPhone 17 Pro: 195 unit tests
   pass (was 187); Domain coverage holds at 843/870 = 96.90%; strict SwiftLint
   zero violations across 84 files.

   Third hosted review (2026-08-05, verdict APPROVE on `c4fb052`: no blockers,
   4 should-fix, 7 nits). Owner directed clearing every should-fix. Two of the
   four were defects this slice's own work exposed:

   - `matchedTransitionSource` was keyed by contact id while this slice's seeds
     and the documented §9 contract-6 deviation let one contact hold both a
     cadence and an occasion row inside the horizon. Two rows therefore
     declared the same id in one namespace and the zoom into Contact Detail
     resolved against an arbitrary row. `UpcomingViewModel` now elects one
     owner per contact in display order, the row modifier takes an `isActive`
     flag, and two tests assert exactly one owner per contact — including in
     the duplicate case.
   - The consolidated `StubContactRepository.fetchTracked()` filtered on
     `tracked` alone while both production implementations also exclude
     `archivedAt != nil`. Since that fake now backs the whole Upcoming suite,
     an archived-but-tracked contact would have kept rows in every fake-driven
     test — the exact R23 mock/production drift. Filter aligned, regression
     added.
   - The horizon-end fallback collapsed to `now`, which silently empties the
     screen and is indistinguishable from "nothing upcoming". It now degrades
     to elapsed time: a visible superset instead of a hidden subset.
   - The `make*ViewModel` factories keep their single production call site
     with a written justification: `AppRuntimeTests` calls each one to prove
     window injection (R9a), shared clock, and no retained mock timing, and
     none of that is reachable against a view model constructed inline inside
     a `State` initializer. Inlining would trade a named seam for silently
     untested composition, which is how R9 survived.

   Third-round evidence on the pinned iOS 26.5 iPhone 17 Pro: 197 unit tests
   pass (was 195); Domain coverage holds at 96.90%; strict SwiftLint zero
   violations across 84 files.

   Fourth hosted review (2026-08-05, verdict APPROVE on `fb8176a`: no
   blockers, 7 should-fix, 7 nits). Owner standing direction is to clear every
   should-fix. Closures:

   - `UpcomingViewModel.init` no longer defaults `reminders:` or `window:`. A
     defaulted window is exactly how R9 shipped — a call site that forgot to
     inject the persisted window fell back to `.defaultV1()` and the feature
     became fiction with nothing failing. A missed injection is now a compile
     error. Four test call sites updated.
   - `StubReminderRepository` filters on `state == .pending` like both
     production repositories, with a parametric regression over every
     `ReminderState` proving a fired, cancelled, or caught-up reminder keeps
     no row.
   - `transitionSourceRowIDs` gains the cross-day-group case: one contact
     whose cadence and occasion rows land in different sections still elects
     exactly one owner, and the non-owning row keeps its tap target.
   - The shipped mock fixture is now guarded against silently reintroducing a
     §9 contract-6 same-day duplicate through a future offset edit.
   - Seeded occasion `osNotificationId`s use the §9 contract-5
     `contact-{uuid}-{kind}` identity instead of a mock-only shape TF-07's
     reconcile and orphan-cancellation logic would not recognize.
   - `MockStore.occasionInstant`'s terminal fallback is exercised directly,
     plus a parametric proof that no plausible seed offset yields nil.
   - The R24 register row distinguishes ContactDetail's spoken-label coverage
     from its still-absent VM-behavior suite, so §13 and §19 no longer
     contradict each other.

   `UpcomingViewModelStateTests` was split: the duplicate-row and
   transition-source cases moved to `UpcomingViewModelDuplicateRowTests` and
   the shared contacts, clock, and windows moved to
   `Support/UpcomingFixtures.swift`, keeping both suites under the
   type-body-length limit without duplicating fixtures.

   Fourth-round evidence on the pinned iOS 26.5 iPhone 17 Pro: 203 unit tests
   pass (was 197); Domain coverage holds at 96.90%; strict SwiftLint zero
   violations across 86 files.

   Fifth hosted review (2026-08-05, verdict APPROVE on `107a9e4`: no blockers,
   7 should-fix, 10 nits). The first attempt failed closed for an
   infrastructure reason, not a verdict: the reviewer errored after one turn
   and produced no artifact, so `require-hosted-review-output.sh` refused to
   publish. Re-running the failed jobs produced the verdict above.

   Three findings were corrections to this round's own work and are closed:

   - The zero-capacity guard's comment still claimed the window "always has
     capacity, so nil never happens today". False once R9a made the window
     caller-supplied, and this slice's own test drives that branch. The
     comment now says so and warns against deleting the guard as dead code,
     which would silently reintroduce R4.
   - `shippedFixtureHasNoSameDayDuplicate` built its window with
     `.defaultV1(timezone: UTC)` instead of the shipped
     `MockRepositories.defaultWindow` (Asia/Kolkata), so it did not guard the
     fixture it claimed to. Now uses the shipped window; still passes.
   - R9a overclaimed. `AppRuntime.makeProduction` resolves the persisted
     window, but the shipping app still boots `makeMock`, so the production
     path has zero callers until TF-02. The register now says what is actually
     closed — the hardcode and the silent-default hazard — and names the boot
     flip as TF-02 work, which removes the contradiction with §18.

   Four are consciously deferred, with owners, because they are other queue
   items' scope rather than this slice's:

   - Threading `isVirtualMerged` into Upcoming and All Contacts rows so a
     merged contact is announced consistently on every tab. Virtual merge is
     TF-10's subject (R11–R12); doing it here would mean inventing the
     grouped-row semantics TF-10 exists to define.
   - A wiring test for `OverdueViewModel.makeOverdueRow` asserting a
     non-grouped contact reports `isVirtualMerged == false`. The Domain branch
     is covered; the missing piece is the Overdue VM's own suite, which R24
     assigns to TF-04/TF-07.
   - Strengthening `assertCadenceBoundary` to distinguish calendar-day from
     elapsed-seconds horizon arithmetic. Worth doing, and it belongs with
     TF-07's rewrite of this code path rather than as a late addition to a
     hygiene slice.
   - Asserting the resulting `occasionDate`/`monthDayString` for Feb-29 and
     year-crossing offsets in the seeding helper. Annual recurrence is
     engine-owned and already covered there; the seeding helper's contract is
     non-nil, which is what its tests assert.

   Fifth-round evidence on the pinned iOS 26.5 iPhone 17 Pro: 203 unit tests
   still pass with the fixture guard now running under the shipped
   Asia/Kolkata window.

## Owner gates

### Pre-release device pass

Owner ruling 8 (2026-10-28): every device-only check is deferred to this one pass, which runs before release. No queue item waits on it. Each item records its own result line. Each later PR's device smoke is appended here as that PR merges.

- TF-03 acceptance (OWNER, deferred to the pre-release device pass, not blocking). The owner runs these steps on a physical iPhone,
  using a production build from `main` at `6c0d633` or later. Steps 1-6 use
  no `--regards-mock-runtime` and no `REGARDS_UI_TEST_*` flag; step 7 needs
  both. Full Contacts access is required (`.authorized`). Limited Access
  never archives, so the delete steps prove nothing under Limited Access.
  The 5k off-pool half of R25 is already proven by the synthetic regression
  test in PR #48, so these steps cover the PR21 exit check plus the
  corruption-banner VoiceOver smoke.

  1. Complete onboarding with full Contacts access. Use two test contacts in
     the system Contacts app: Contact A to rename and Contact B to delete.
  2. Rename Contact A in the Contacts app. Foreground Regards. Confirm All
     Contacts shows the new name.
  3. Delete Contact B in the Contacts app. Foreground Regards and note the
     time. Confirm Contact B is still in All Contacts. The first miss is
     recorded but not archived yet.
  4. Between 2 and 3 minutes after step 3, force-quit and relaunch
     Regards, and note the time. Confirm Contact B is still in All Contacts.
  5. Between 5 and 6 minutes after step 3, and so less than 5 minutes after
     step 4, foreground Regards. Confirm Contact B is gone from All Contacts.
     Both bounds matter. If the relaunch had lost the debounce state, the
     launch pass at step 4 would record the miss again, and Contact B could
     not archive until 5 minutes after step 4, which is after this window.
     `AppLaunchArchivePersistenceTests.archiveDebounceStateSurvivesRelaunch`
     proves the same in unit form.
  6. Re-add Contact B in the Contacts app. Foreground Regards. Confirm a
     Contact B row is back in All Contacts. A re-added contact gets a new
     system identifier, so it imports as a new row; that is expected.
     Un-archiving a row whose identifier reappears (the PR21 "un-archive"
     clause) can't be produced from the Contacts app on demand and is
     proven by `ContactsReconcilerTests.reconcileUnarchivesReappearingContact`.

  The PR21 clause "history survives archive" isn't visible in the UI: the
  archived row is hidden, and a re-added contact is a new row. It is proven
  by `ContactsReconcilerResilienceTests`
  (`archiveSurvivesWithScheduledReminderAndInteractionLogHistory` and
  `deleteThenReAddLandsAsNewRowKeepingArchivedHistory`, both from PR #48).

  7. Corruption banner VoiceOver smoke. A corrupt row can't be produced on
     demand in a production build; the `REGARDS_UI_TEST_SEED_CORRUPT_ROW`
     fixture works only under the Debug mock runtime. So for this step
     only, launch a Debug build of the same sha with `--regards-mock-runtime`
     and `REGARDS_UI_TEST_SEED_CORRUPT_ROW=1`, run the corruption-banner item
     in `ios/docs/accessibility-smoke.md` with VoiceOver on, and record it in
     that file's Reporting format, including the iOS version and a Findings
     line.

  Result: pending. Date: ___. Device: ___. iOS: ___. Build: ___ (sha ___).
  Findings: ___.
- PR #66, Remove-range focus (2 cases). In `ios/docs/accessibility-smoke.md`, under Reminder windows, the item "Activate Remove on a range":
  - Case 1: with two or more ranges, activate Remove on a range. Focus lands on "Add range, button", and VoiceOver announces "Range N removed. M range(s) left."
  - Case 2: with the remaining range ending at 11:59 PM (23:59 in a 24-hour region), focus lands on "Add range, dimmed, button", and VoiceOver reads the hint.
  Result: pending. Date: ___. Device: ___. iOS: ___. Build: ___ (sha ___). Findings: ___.
- PR #64, Contact Detail "Snooze 1 week" label, checked by eye on a device.
  Result: pending. Date: ___. Device: ___. iOS: ___. Build: ___ (sha ___). Findings: ___.
- TF-11, starter contacts: the "Saved…" announcement survives the screen pop.
  Result: pending. Date: ___. Device: ___. iOS: ___. Build: ___ (sha ___). Findings: ___.
- TF-11 fresh-install device pass: grant, deny, and limited paths; relaunch in the middle of the starter contacts; the notification ask; and a VoiceOver smoke.
  Result: pending. Date: ___. Device: ___. iOS: ___. Build: ___ (sha ___). Findings: ___.
- TF-07g airplane-mode device run, moved here from TF-06's on-device exit checks (owner ruling of 2026-10-11, recorded in the TF-07 row). On a physical iPhone in airplane mode: an overdue contact gets a digest at the next window open; a single notification fires at a window boundary; and Caught up and Snooze 1 week round-trip from a notification.
  Result: pending. Date: ___. Device: ___. iOS: ___. Build: ___ (sha ___). Findings: ___.

- PR #67 (TF-07c), four device steps, one result line.
  1. All Contacts, cadence under 1 day (seeded or corrupt): the row reads sensibly with VoiceOver, with no dangling " · " and no last-interaction text.
  2. Save latency: global window and contact override saves on a real-sized contact list. Note how long Save stays dimmed and whether VoiceOver says anything. Upcoming follows the new window without leaving the tab.
  3. DEBUG mock launch: VoiceOver focus after the splash lands on Upcoming, and the birthday and anniversary rows are on the first render.
  4. Snooze return: snooze from Overdue and from Contact Detail. Overdue and Upcoming agree on when a snooze outside window hours lapses.
  Result: pending. Date: ___. Device: ___. iOS: ___. Build: ___ (sha ___). Findings: ___.

Current gates:

- R30 stays intentionally open; no unique work may be removed merely to close a hygiene row.

### PR #24 modernization accessibility evidence

- Implementation `0188901` was built, installed, and launched with Xcode 26.6
  on the pinned iOS 26.5 iPhone 17 Pro simulator. Accessibility Inspector was
  targeted to the running Regards process; its inspection pointer and the
  Simulator accessibility hierarchy supplied the documented VoiceOver
  emulation gate.
- The traversal reached Overdue, Upcoming, Contacts, Settings, Contact Detail,
  and Reminder Windows. It exposed screen and section headings, selected
  segments, natural-language row labels, action hints, search-field traits,
  tab reachability, and labeled Back escapes. Unavailable channel and logging
  actions had no button trait. Upcoming and Contacts both reached Contact
  Detail and returned without trapping focus.
- The traversal found one defect the structural audit did not: the second
  `T` day pill announced “Tuesday” instead of “Thursday,” and both `S` pills
  shared one ambiguous name. Implementation `0188901` binds every day to its
  full name. The focused Reminder Windows audit now asserts “Thursday
  allowed,” “Sunday not allowed,” and “Saturday not allowed” and passes.
- Dynamic Type `accessibility5` exposed the corrected labels and complete
  Reminder Windows content. Reduce Motion and Increased Contrast were tested
  on and off; dark increased-contrast content, selection, rings, icons, and
  navigation remained visible and usable. The simulator was restored to
  light appearance, `large` text, standard contrast, and Reduce Motion off.
- SwiftLint passed with zero violations. No local 5× sweep was run; the latest
  current-`main` one-run audit and scheduled 5× stress workflow are green, and
  those workflows continue to own broad repetition.
- The first hosted semantic review found that overlapping initial-load and
  retry tasks could complete out of order. Overdue, Upcoming, and Contacts now
  generation-gate every completion so a stale failure cannot overwrite newer
  loaded data. Six focused unit tests deterministically interleave requests
  across all three ViewModels and verify that every root keeps existing
  content visible during a refresh. A seventh focused test covers the
  case-insensitive Contacts search filter, including empty and no-match
  queries.
- The current branch also compiles and launches on the installed iOS 17.2
  runtime. On 2026-08-03, an exact-source `xcodebuild` for the iPhone 15 Pro
  destination succeeded; `simctl` installed the resulting app and launched
  `com.consideratesoftware.regards` as process 42801. Visual inspection
  confirmed the Overdue root and the legacy four-item Overdue, Upcoming,
  Contacts, and Settings tab bar. Two attempted legacy XCUITest actions are
  not counted as evidence: their runners were killed before test bootstrap,
  with no app assertion executed. The direct build/install/launch result is
  the durable fallback acceptance gate missing from the hosted review, not a
  repeated broad audit sweep.
- A later hosted correctness pass found that `MergeDuplicatesScreen` accepted
  a fresh view model from its navigation-destination factory but stored it as
  a plain value. Parent re-rendering could therefore replace the pushed
  screen's model and discard in-progress primary/selection choices. The
  Settings tab root now owns one observable model with `@State`, and its
  initial load is idempotent, so destination reconstruction cannot discard or
  reload in-progress choices. A DEBUG-only duplicate fixture and focused XCUI
  regression verify the visible phone remains in the VoiceOver label, change
  both selection and primary contact, switch tabs, return to the pushed
  screen, and prove both choices survive. Two isolated unit regressions prove
  a repeated load preserves those choices without refetching and a failed
  initial load remains retryable. Two more cover phone/email classification,
  confidence-based default selection, and targeted selection/primary
  mutations, completing the Merge Duplicates ViewModel suite recorded in R24.
- The final Merge Duplicates review closure adds the previously missing
  name-only `.low` confidence proof and makes repository failures explicit.
  A failed duplicate scan now renders an unavailable state with a retry action
  instead of falsely claiming that no duplicates were found; the unit suite
  asserts failed → loaded recovery, and the focused Merge Duplicates
  accessibility audit passes on the corrected screen.
- App-Shortcut root navigation now owns Contacts search state alongside the
  Contacts navigation path. Opening Contacts from a system request clears both
  the pushed path and any stale filter; the focused router test proves the
  reset while preserving the other tabs' stacks. Architecture §10 and R11 now
  also record that the obsolete inert Horizon/All controls were removed, with
  the real horizon editor still owned by TF-05.

### PR #37 accessibility evidence

- Full manual smoke source `11cf095` was built, installed, launched, and
  inspected with Xcode 26.6 on the pinned iOS 26.5 iPhone 17 Pro simulator.
  Responsive-layout implementation commit `ddbb80d` and speakable email-label
  implementation commit `886d03e` are both present in that source.
- VoiceOver: Accessibility Inspector and the Simulator accessibility hierarchy
  exposed the launch heading, screen headings, all four tab destinations,
  natural-language rows, button traits, action hints, and logical reading
  order. Overdue, Contacts, and Upcoming each reached Contact Detail, Contact
  Preview, and the standard labeled Back escape route. The exact-source rerun
  reached Obi-Wan Kenobi's Contact Preview and exposed its email field as one
  element spoken as “personal, obiwan at jeditemple dot org”; the visible
  address remained `obiwan@jeditemple.org`.
- Dynamic Type: the first `accessibility5` pass found truncated selector text,
  compressed nav and digest copy, clipped list metadata, and narrow Contact
  Detail actions. Commit `ddbb80d` makes those layouts stack at accessibility
  sizes. The repeated pass showed complete selector labels, names, metadata,
  CTA copy, secondary actions, and detail rows across all three entry paths;
  the normal `large` text-size layout remained compact.
- Reduce Motion: on and off tested. Navigation remained coherent through the
  documented reduced-motion and standard-transition paths.
- Increased Contrast: on and off tested. Text, icons, segmented selection, and
  the inner-circle ring remained visible.
- 2026-08-02 follow-up exact-source stress evidence: at `886d03e`,
  `ios/scripts/audit-stress.sh 5` completed five consecutive full
  accessibility-suite passes on the branch based on merged PR #23. Each run
  executed 18 tests; all 90 test executions passed. The prior sweep exposed a
  raw email address that the structural audit could not recognize as a
  human-readable label; the contextual, speakable label fix then passed its
  focused audit 5/5 before the clean full sweep. Subsequent hosted-review
  refinements and their replacement exact-source sweep are recorded next.
- 2026-08-02 hosted-review refinement: commit `40e7d95` makes email fields opt
  into a typed punctuation-to-speech policy explicitly instead of inferring it
  from arbitrary field contents. Unit coverage proves both email conversion
  and literal non-email `@`/`.` preservation; all 120 unit tests passed after
  the hosted review added empty-field, multi-dot, and plus-address coverage.
  SwiftLint passed with zero violations, the Upcoming-to-Contact-Preview
  regression passed 5/5, and the exact implementation was installed and
  re-inspected. Its email remained visible as `obiwan@jeditemple.org` and
  exposed the single accessibility element “personal, obiwan at jeditemple dot
  org.”
- 2026-08-02 final hosted-review closure: commit `bf3d24e` adds empty-field,
  placeholder, multi-dot email, plus-address, and case-preservation coverage;
  removes empty spoken-value punctuation; restores full-width accessibility
  rows and 44-point contact targets; preserves wrapping selector labels; and
  replaces stale-coordinate taps with a non-failing live/hittable poll. The
  first replacement stress attempt passed two full sweeps before exposing a
  third-sweep Edit activation race. Commit `75d6f9c` varies the three bounded
  activation paths while re-resolving live elements and confirming source and
  destination state after each attempt. That candidate passed a focused 5/5
  and one 90/90 sweep, but the next exact-head sweep reproduced the same Edit
  activation failure; that evidence is superseded. Commit `8f3f373` replaces
  the toolbar `NavigationLink` with state-driven navigation and gives the Edit
  control a stable accessibility identifier. The failing regression then
  passed 10/10 focused launches. A fresh `ios/scripts/audit-stress.sh 5`
  completed five consecutive 18-test suites at `8f3f373`; all 90 executions
  passed, including the formerly flaky test in every sweep. SwiftLint, all 120
  unit tests, XcodeGen determinism, review-agent parity, source-boundary guards,
  YAML, and diff checks also passed.
- 2026-08-02 second hosted-review closure candidate: Contact Detail and Contact
  Preview now share one typed contact-value speech policy, including trimmed
  empty values, punctuation boundaries, and the spoken meaning of the
  preferred-field dot. Repeated two-branch accessibility layouts now use one
  shared adaptive-layout builder; small per-control size choices remain inline.
  The nav header, interaction dates, and Contact Preview field labels no longer
  rely on fixed heights or widths at accessibility sizes. Contact Preview
  navigation binds the concrete `Contact`
  destination, and unavailable Caught up / Snooze / Log other stubs are muted
  text rather than inert buttons until TF-04 wires their persistence. The
  unwired Contact Detail and Overdue channel actions follow the same muted,
  noninteractive convention until TF-08 adds real routing. FaceTime values now
  choose phone or email placement and speech from the value itself. All 126
  unit tests and the new deterministic
  `accessibility5` XCUI non-overlap regression pass locally. The repository's
  `a8c9c01` baseline is intentional: it is the merge commit for GitHub PR #23,
  not the older pre-PR23 / PR35 planning baseline. At exact implementation
  commit `6c9b53a`, four consecutive full accessibility suites passed: 19 tests
  per run, 76/76 executions total, including the formerly flaky Edit routes
  and the new `accessibility5` regression. The fifth local run was intentionally
  stopped in progress after the owner removed repeated local sweeps from the
  PR policy; it did not report a test failure. The one-run audit now runs after
  merges, while nightly automation and pre-release manual dispatch own repeated
  5× stress. The final implementation source at `57c2f37` then
  built in Release and was installed and launched on the pinned iOS 26.5
  iPhone 17 Pro. Its current-source Simulator hierarchy confirmed the Contact
  Detail → Contact Preview route, the standard Back button labelled “Contact,”
  return to Contact Detail, and Obi-Wan Kenobi's preferred channel as the
  single element “Email, obiwan at jeditemple dot org, preferred.” The
  deterministic `accessibility5` layout regression passed against that source.
  Follow-up implementation `fe3e411` closes the final local-review findings:
  the remaining Contact Detail and Overdue no-op actions are now muted,
  noninteractive elements; FaceTime email and phone values choose the correct
  field and speech policy; and that intermediate source's census was 125 unit
  tests plus 19 XCUI tests. All 126 unit tests and the focused Contact Detail and Contact
  Preview audits passed. The installed exact-source hierarchy exposed the
  unavailable actions without button traits. Only the final staged-review
  verdict remains before merge.
- 2026-08-02 App-hosted review closure: implementation `4ab305b` removes the
  last stale local-sweep requirement from the PR18 acceptance row; makes
  navigation retries coordinate-only and bounded; derives phone/email field
  placement from `ChannelCatalog`; covers every channel branch plus malformed
  email speech; labels Change stubs unavailable; and registers Muted on Hair
  Soft contrast. Final staged-review follow-up removes sleep-based UI-test
  synchronization and routes Contact Preview's rendered field label through
  the same channel-aware speech policy, including a malformed-email regression.
  All 127 unit tests passed, as did the focused Overdue, Contact
  Detail, Contact Preview, and Overdue → Preview → Back tests. No repeated
  local sweep was run; scheduled post-merge 1× plus nightly/pre-release 5×
  workflows own that evidence. The final local staged verdict is `APPROVE`;
  the final hosted verdict and required checks remain before merge.
- 2026-08-03 hosted-review response: unavailable Contact Detail and Overdue
  actions now have stable identifiers and focused XCUI coverage proving their
  “unavailable” labels and lack of button traits. The accessibility5 regression
  covers the navigation header, secondary actions, and channel card; Edit →
  Detail regressions now continue back to both originating tab roots. Empty
  preferred values no longer expose a dot or “preferred” annotation. Decision
  #39 records the scheduled-audit policy without replacing PR18's historical
  5/5 ×3 evidence. The exact final SHA and smoke results will be bound together
  in the required PR comment after the final push.
- 2026-08-03 exact-head hosted-review response: the App review of `95c60c6`
  caught one remaining empty preferred-value annotation in Contact Detail.
  The shared label path now gates “preferred” on a nonblank value and has a
  matching unit regression. The response also reconciles AGENTS.md's ATS
  wording, restores two-second default hittability polling, verifies nonzero
  frames before overlap comparisons, covers the no-channel Contact Preview
  speech branch, and extends the focused `accessibility5` regression across
  the segmented control, digest, Overdue and Upcoming rows, Contact Detail
  cadence layout, and Contact Preview fields. The 21-test contact-accessibility
  unit suite, all 131 unit tests, the expanded focused XCUI regression, and the
  unavailable-action contract regression pass. No repeated local stress sweep
  was run; the exact final SHA and current-source smoke will be recorded in the
  PR comment after the final push.
- Prior implementation stress evidence: the same command completed five full
  passes at `f069297` on 2026-08-02, with all 90 test executions passing.
- Historical regression evidence before the `ddbb80d` smoke fixes: four
  earlier five-run sweeps also passed,
  including the earlier `a454313` hosted-feedback run and the 2026-07-31
  acceptance run. Across those previously recorded sweeps, all 30 runs and
  525 test executions passed.
- Hosted-review follow-up: the `d5449e4` App-authored review requested changes.
  Implementation commit `a454313` closes its route-fallback, tab-preservation,
  repeated-navigation, copy-coverage, contrast-registry, local-destination,
  stale-comment, and register-truth findings. Commit `f069297` centralizes the
  destination initializer, corrects the canonical test census, and closes the
  navigation-helper findings. Commit `b9e88fb` removes the unused initializer
  callback surface and corrects the final census and audit-schedule wording.
  The App-authored review of `be215a3` then requested the current-head smoke
  plus corrections to state ownership, navigation waits, entry-path audit
  coverage, contrast documentation, and register truth. Commit `36f86e2`
  closes those source and documentation findings; the smoke then exposed the
  accessibility-size layout defects fixed by `ddbb80d`. The integrated branch
  is sent through exact-source staged review before merge.

### Review-gate App, for the record

The `TF-01` GitHub App checklist is **DONE (2026-08-02)**. No owner action
remains for it. What was done, for the record:

1. App `regards-staged-review` (app id `4461672`) created under
   `consideratesoftware`, webhooks disabled, installed on
   `consideratesoftware/RegardsMobileApp` only.
2. `hosted-review` environment holds variable `REGARDS_REVIEW_APP_CLIENT_ID`
   and secret `REGARDS_REVIEW_APP_PRIVATE_KEY`; the environment is restricted
   to protected branches.
3. The App-authored `Regards staged review` check was exercised end to end
   (run `30737416020`) and bound in branch protection pinned to app id
   `4461672`, so a same-repository Actions job cannot satisfy it. The spoofable
   Actions `review` requirement was removed at the same time, along with the
   `Accessibility audit` and `Accessibility audit stress (5x)` contexts, which
   moved off the pull-request path the same day.

The App's granted permissions are `Checks: Read and write` and
`Issues: Read and write`; the workflow requests only `checks: write`, because
the review is published as the check run's output rather than a comment.
Commenting on a pull request would require `pull_requests: write`, and a token
holding that could also approve the pull request it gates.

The remaining owner actions cannot be completed from repository automation and
will be requested when their owning gate becomes active:

- `TF-08`: Apple Development signing access, App Store Connect role, a physical
  iPhone, a small contacts fixture, and installed target messaging apps for the
  internal device pass.
- `TF-14`: confirm product/pricing/localization values in App Store Connect and
  complete any agreements, tax, banking, or Small Business Program steps.
- `TF-18`: approve privacy/legal copy, tester list and outbound invitation,
  screenshots/icon, export-compliance answers, and the actual build upload.

## Scope and schedule policy

There is no credible fixed launch date until `TF-08` has produced an internal
build and measured the remaining device/account work. Preserve sequence and
quality gates instead of pretending the expired 2026-08-31 target still
controls the work. After internal TestFlight, re-estimate `TF-09`–`TF-18` from
observed throughput and beta defects.

If scope must move, cut only in the order already allowed by §14: localization
scaffolding, medium widget, then snapshot breadth. Accessibility, privacy,
notification correctness, data migration, export/delete, and the §9 reminder
contract never move out of the TestFlight gate.
