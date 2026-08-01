# TestFlight execution plan

This file is the durable control plane for taking Regards from `main` to
TestFlight. `ARCHITECTURE.md` remains the product and technical source of truth.
This file replaces only the stale calendar dates and overloaded PR numbers in
§14 with stable work IDs, live state, and a restart protocol.

## Current checkpoint

- Updated: 2026-07-29
- Baseline: `main` at `63a4f0f` (merged GitHub PR #21)
- Active work: `TF-00`
- Next ready work: none (`TF-01` follows merged `TF-00`)
- Open pull request: GitHub PR #22 (`chore/tf-00-execution-control`)
- Internal TestFlight gate: after `TF-08`
- External TestFlight gate: after `TF-18`
- Continuation: active Codex heartbeat `continue-regards-work-after-pr-20`,
  daily at 19:30 host-local time, targeting this persistent task
- Owner action needed now: create and install the dedicated Regards review
  GitHub App listed under `Owner gates`

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
   green and no blocker remains. If more than one exists, start nothing new;
   finish the oldest first and restore the one-item invariant.
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
moves to another machine, recreate one daily heartbeat from this contract;
do not add a GitHub Actions implementation that would require a hosted coding
credential.

The recurring task may create branches, edit files, run tests, commit, push,
open pull requests, address reviews, and merge a pull request after every
required check and the staged review approve it. It must not:

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
| TF-00 | ACTIVE | — | Install this durable control plane, make both agent adapters share the same review contract, and schedule continuation | execution infrastructure |
| TF-01 | BLOCKED | TF-00 | Truth and hygiene pass: finish the still-open doc/audit/CI/package/mock-seed work; current-state prose and checks agree with the repository | PR18–PR19; R16, R19, R21–R22, R27–R34, R40, R42–R43 |
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

## Owner gates

The current owner action for `TF-01` is one GitHub App setup checklist:

1. Create a GitHub App owned by `consideratesoftware` named `Regards Review
   Gate`. Disable webhooks. Grant repository permissions `Checks: Read and
   write` and `Issues: Read and write`; grant nothing else.
2. Install it only on `consideratesoftware/RegardsMobileApp`, generate one
   private key, then configure the repository's `hosted-review` environment:
   set variable `REGARDS_REVIEW_APP_CLIENT_ID` to the App's client ID and secret
   `REGARDS_REVIEW_APP_PRIVATE_KEY` to the complete PEM private key. Delete the
   downloaded key after GitHub confirms the secret.
3. Tell Codex the setup is complete. Codex will verify the environment is
   restricted to protected branches, exercise the App-authored `Regards staged
   review` check on the open PR, bind that context to the App's ID in branch
   protection, remove the spoofable GitHub Actions `review` requirement, and
   delete the one-time `bootstrap_review` compatibility job while integrating
   PR #23.

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
