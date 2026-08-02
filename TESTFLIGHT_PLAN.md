# TestFlight execution plan

This file is the durable control plane for taking Regards from `main` to
TestFlight. `ARCHITECTURE.md` remains the product and technical source of truth.
This file replaces only the stale calendar dates and overloaded PR numbers in
§14 with stable work IDs, live state, and a restart protocol.

## Current checkpoint

- Updated: 2026-08-02
- Baseline: `main` at `a8c9c01` (merged GitHub PR #23 repository-truth slice)
- Active work: `TF-01` (merge GitHub PR #37, then its stacked
  platform-modernization slice)
- Next ready work: none (`TF-02` follows completed `TF-01`)
- Open work, in required completion order: GitHub PR #37
  (`codex/tf-01-a11y-follow-up`, ready for review), then GitHub PR #24
  (`ios/modern-platform-showcase`, draft; still based on merged PR #23 until
  #37 lands)
- Internal TestFlight gate: after `TF-08`
- External TestFlight gate: after `TF-18`
- Continuation: active Codex heartbeat `continue-regards-work-after-pr-20`,
  every 3 hours, targeting this persistent task
- Owner action needed now: none. The PR #23 Simulator accessibility smoke and
  the dedicated GitHub App setup are complete.
- Copyright owner: repository, product, and App Store references use
  `Considerate Software LLC`; the PolyForm Noncommercial terms are unchanged.

Only change `Active work`, `Next ready work`, and the queue status in the same
pull request that changes the corresponding implementation. A run that stops
before a commit leaves its branch and worktree as the checkpoint.

## Restart protocol

Every fresh or scheduled agent run follows this order:

1. Read `AGENTS.md`, then `ARCHITECTURE.md` §18 → §19 → §14, then this file.
2. Run `git fetch --prune origin` and inspect the branch, worktree, open pull
   requests, review comments, and required checks.
3. If the worktree is dirty, resume it. Do not discard, stash, or overwrite it.
4. If any open pull request carries a `TF-##` marker, resume it before taking
   new work, even when the checkout is on `main` or another branch. Safely
   check out its branch when needed, address review findings, repair CI, run
   the Regards multi-agent review, and merge only when every required check is
   green and no blocker remains. Follow the dependency order in `Current
   checkpoint`; PR #23 is complete, and the current order is PR #37, then PR
   #24. Start no additional work while this chain is open.
5. Otherwise, fast-forward `main`, reconcile this queue against merged pull
   requests carrying a `TF-##` marker, and take the first `READY` item whose
   dependencies are `DONE`.
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
| TF-01 | ACTIVE | TF-00 | Truth and hygiene pass: finish the still-open doc/audit/CI/package/mock-seed work; current-state prose and checks agree with the repository | PR18–PR19; R13 escape route, R16, R19, R21–R22, R27–R34, R40, R42–R43 |
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
3. Merge GitHub PR #37, the TF-01 accessibility follow-up carrying those
   exact-source changes, the completed manual smoke, and their review evidence.
   This closes the remaining R13, R16, R27, R28, and R43 acceptance evidence
   and confirms R29's earlier closure before the stack advances.
4. GitHub PR #24 is the owner-directed platform-modernization slice. Only
   after the accessibility follow-up merges, retarget and rebase #24 onto the
   resulting `main`, publish it, then rerun its full checks, staged review, and
   manual accessibility smoke.
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

- `TF-01` slice 1 follow-up / PR #37: PR #23 merged before the smoke-driven
  responsive layouts and navigation-harness fixes were pushed. PR #37 carries
  those verified changes. No owner action remains; exact-source mechanical
  gates and all six staged reviewers must be green before it merges.
- `TF-01` slice 2 / PR #24: merge the accessibility follow-up first, then
  retarget and rebase the child onto `main`. Rerun its checks, staged review,
  and manual accessibility smoke before publication or auto-merge.

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
  focused audit 5/5 before the clean full sweep. Changes after `886d03e` are
  evidence-only documentation except for the scoped formatting refinement
  recorded next.
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
