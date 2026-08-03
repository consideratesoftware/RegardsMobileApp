# TestFlight execution plan

This file is the durable control plane for taking Regards from `main` to
TestFlight. `ARCHITECTURE.md` remains the product and technical source of truth.
This file replaces only the stale calendar dates and overloaded PR numbers in
§14 with stable work IDs, live state, and a restart protocol.

## Current checkpoint

- Updated: 2026-08-03
- Baseline: `main` at `209171c` (merged GitHub PR #37 accessibility follow-up)
- Active work: `TF-01` (GitHub PR #24 stable-platform modernization)
- Next ready work: none (`TF-02` follows completed `TF-01`)
- Open pull request: GitHub PR #24 (`ios/modern-platform-showcase`, published;
  exact-source manual smoke complete; hosted concurrency blocker repaired and
  awaiting exact-head re-review)
- Internal TestFlight gate: after `TF-08`
- External TestFlight gate: after `TF-18`
- Continuation: active Codex heartbeat `continue-regards-work-after-pr-20`,
  every 3 hours, targeting this persistent task
- Owner action needed now: none. The unlocked-Mac handoff for PR #24 is
  complete; no product, legal, signing, or App Store decision is required.
- Copyright owner: repository, product, and App Store references use
  `Considerate Software LLC`; the PolyForm Noncommercial terms are unchanged.

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
   checkpoint`; PR #23 and PR #37 are complete, and PR #24 is the only current
   implementation pull request. Start no additional work while it is open.
5. Otherwise, fast-forward `main` and reconcile this queue against merged pull
   requests carrying a `TF-##` marker. If either scheduled accessibility run
   failed on the current `main`, triage that failure before taking new feature
   work and create the smallest repair PR when it is reproducible. Otherwise
   take the first `READY` item whose dependencies are `DONE`.
6. Work on exactly one queue item. Use a branch named after its stable ID, keep
   the diff reviewable, meet its architecture acceptance criteria, and include
   its `TF-##`, §14 scope alias, and R-items in the pull-request body.
7. Run proportionate local checks before push. Every pull request must pass the
   repository gates and `$regards-pr-review` (or `/pr-review`) before merge.
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
- start a second work item while another branch, worktree, or pull request is
  unresolved.

When an owner-only action blocks the next acceptance criterion, mark the item
`OWNER`, write one exact checklist under `Owner gates`, and continue any
independent `READY` work. Ask once, not on every scheduled run.

## Release gates

### Internal TestFlight

The first internal build is useful when production storage and import are live,
the core caught-up/snooze flow persists, reminder windows shape persisted
notifications, notification actions round-trip, deep links execute, onboarding
has grant and denial paths, all visible controls are real, and CI plus the
structural accessibility audit are green. That is the exit of `TF-08`.

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
| TF-01 | ACTIVE | TF-00 | Truth, platform modernization, and hygiene pass: finish the still-open doc/audit/CI/package/mock-seed work; adopt the latest stable iOS composition with explicit fallbacks; current-state prose and checks agree with the repository | dedicated modernization slice in GitHub PR #24; PR18–PR19; R13 escape route, R16, R19–R23, R27–R34, R40, R42–R43 |
| TF-02 | BLOCKED | TF-01 | Production DB v2, shared repository contracts, real environment at launch, resumable first import, and a basic onboarding gate; fresh simulator install reaches populated tabs | PR20; R23, R39 |
| TF-03 | BLOCKED | TF-02 | Contacts reconciliation on launch/foreground/change, archive safety, limited-authorization handling, and per-row import tolerance | PR21; R35 |
| TF-04 | BLOCKED | TF-03 | Caught up, Snooze, and Log other persist from every surface; live lists update; interaction and ViewModel tests pass | PR22; R11, R24, R34, R36, R46 |
| TF-05 | BLOCKED | TF-04 | Reminder-window editor persists valid global/per-contact windows and visibly reshapes lists; zero-capacity saves fail clearly | PR23; R4, R9 |
| TF-06 | BLOCKED | TF-05 | Local notification adapter, permission UI, categories, actions, and deterministic adapter tests | PR24; R11 |
| TF-07 | BLOCKED | TF-06 | SchedulingPass is the sole idempotent reminder writer; reconciliation, batching, occasions, no-double-up, orphan cancellation, and reactive Upcoming are proved | PR25; R4–R6, R10–R11, R24 |
| TF-08 | BLOCKED | TF-07 | Channel and notification deep-link execution works on every surface; Discord scheme is minimal; interaction logging and routing tests pass | PR26; R11, R37 |
| TF-09 | BLOCKED | TF-08 | Real Edit Contact form with dirty-field partial write-back, denial/error states, re-fetch, safe navigation, purpose string, and audit coverage | PR27; R13, R16–R17 |
| TF-10 | BLOCKED | TF-09 | Virtual merge, unmerge, skip, manual link, full-handle detection, grouped reminders/lists, persistence, and audits | PR28; R11–R12, R24 |
| TF-11 | BLOCKED | TF-10 | Three-screen onboarding, starter contacts, grant/deny/limited paths, relaunch state, notification ask, and no inert controls | PR29; R11, R14 |
| TF-12 | BLOCKED | TF-11 | Read-only EventKit occasions merge with Contacts precedence; revocation degrades safely; purpose string and tests are complete | PR30; R17 |
| TF-13 | BLOCKED | TF-12 | Widget target and App Group migration preserve the DB; read-only small/medium/lock widgets refresh from SchedulingPass | PR31 |
| TF-14 | BLOCKED | TF-13 | StoreKit trial/lifetime entitlement, paywall, soft lock, tips, restore, and StoreKitTest suite pass without eroding no-network app code | PR32 |
| TF-15 | BLOCKED | TF-14 | Settings export/delete/support/transparency/entitlement surfaces work; JSON covers every table and delete returns to onboarding | PR33; R11, R15 |
| TF-16 | BLOCKED | TF-15 | Full accessibility categories and 5× stress pass, snapshot gate, contrast registry, privacy required-reason entries, category/export keys, and Dynamic Type smoke | PR34; R18, R41, R44 |
| TF-17 | BLOCKED | TF-16 | 5k-contact path is off the cooperative pool and meets the device budget; strings/copy and launch polish are complete | PR35; R25 |
| TF-18 | BLOCKED | TF-17 | Clean archive, monotonic build number, internal feedback triage, device matrix, privacy/network evidence, beta metadata, signing, upload, processing, and external-group approval | §20 release playbook |

`BLOCKED` in this queue normally means “waiting on the listed dependency,” not
an implementation problem. Promote the next item to `READY` when its dependency
is merged.

### TF-01 serial chain

TF-01 has one completed merge-gate prerequisite followed by four reviewable
slices. The order is fixed while the current pull requests remain open:

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
4. ACTIVE: GitHub PR #24 is the owner-directed platform-modernization slice.
   It is rebased onto current `main`; its focused checks and exact-source
   manual accessibility smoke are complete and it is published. The first
   hosted semantic review found an overlapping-load race in the three primary
   tab ViewModels; the branch now ignores stale completions, preserves loaded
   Contacts content during refresh, and proves both behaviors with controlled
   interleaving tests. Require the exact-head hosted verdict and all protected
   checks before guarded auto-merge. Broad 5× sweeps remain owned by post-merge,
   nightly, and pre-release automation.
5. Finish the remaining PR19 CI and reproducibility scope: commit
   `Package.resolved`, remove placeholders, extend root Markdown checks, add
   the Domain coverage floor, remove the dead SwiftLint `function_body_length`
   configuration and stale audit-stress comment, and reconcile merge-method
   documentation.
6. Finish mock and code hygiene: seed group, interaction, and occasion states;
   use stable Upcoming row IDs; remove or wire dead assets and comments; prune
   obsolete worktrees and merged branches after exact-target verification.

## Owner gates

Current gates:

- No owner gate is active. PR #24's unlocked-Mac handoff and manual
  accessibility traversal are complete. Publication, hosted review, required
  checks, and guarded auto-merge are agent-owned repository work.

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
  PR policy; it did not report a test failure. Post-merge/nightly automation now
  owns repeated 5× stress. The final implementation source at `57c2f37` then
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
  local sweep was run; scheduled post-merge/nightly/pre-release workflows own
  that evidence. The final local staged verdict is `APPROVE`; the final hosted
  verdict and required checks remain before merge.
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
