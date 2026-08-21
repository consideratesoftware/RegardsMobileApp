---
description: Run the TestFlight queue with up to three parallel implementation lanes. Resumes open TF PRs first, then dispatches READY items to tf-lane agents in linked worktrees, gates, reviews, and opens PRs.
---

Drive `TESTFLIGHT_PLAN.md` forward. Optional argument: `$ARGUMENTS` may be a
list of item ids to restrict to (for example `TF-04 TF-05`) or `--review-only`.

You are the orchestrator. You do not implement anything yourself; you read
state, dispatch agents, and consolidate. Follow the restart protocol in
`TESTFLIGHT_PLAN.md` exactly; this command only adds parallelism to it.

## Stage 0: state (do this yourself)

1. `git fetch --prune origin`. Confirm the root checkout is on `main` and
   clean; if it is not, stop and report. Never work in the root checkout.
2. `git worktree list`. Note any existing `RegardsMobileApp-TF##` worktrees
   and whether they are dirty.
3. `gh pr list --state open --json number,title,headRefName,isDraft`. Every PR
   whose title or branch carries a `TF-##` marker is "open work".
4. Read the `Work queue` table and `Current checkpoint` in
   `TESTFLIGHT_PLAN.md`. Compute READY items whose dependencies are all DONE.
   If `CLAUDE_CODE_HANDOFF.md` exists, read its "Where to pick up" state; it
   is more current than the plan when they disagree.
5. Check the latest completed default-branch `Accessibility audit` and
   `Accessibility audit stress (5x)` runs
   (`gh run list --workflow <name> --branch main --limit 1`). A failure on
   current `main` becomes a repair item ahead of new feature work.

## Stage 1: resume before starting (parallel, not lane-consuming)

For every open TF PR, launch `tf-repair` with the PR number and its worktree
(create `../RegardsMobileApp-TF##` with `git worktree add` if missing). These
run in parallel with each other and with Stage 2. Skip PRs whose last check
run is green and whose hosted review has zero blockers; just list them as
"waiting on owner merge".

## Stage 2: dispatch lanes (parallel)

Lane budget = 3 minus the number of TF items that already have an open PR or
dirty worktree. If the budget is 0, skip to Stage 4.

For each READY item, in queue order, up to the budget:

1. Pick a slug from the row's scope and create the lane:
   ```
   git worktree add ../RegardsMobileApp-TF## -b claude/tf-##-<slug> origin/main
   ```
   Joins (items with 2+ dependencies) branch from `main` only after every
   parent has merged; otherwise they are not READY.
2. Check collision locks: two lanes may not both own `AppEnvironment`,
   `RegardsApp`, migrations, `project.yml`, SchedulingPass, or the execution
   docs. If two READY items collide, run the earlier one and say why the
   other waited.
3. Launch `tf-lane` with: item id, worktree path, branch, simulator
   `RegardsTF##`, DerivedData `/tmp/RegardsTF##DerivedData`, the queue row
   verbatim, and the §14 acceptance criteria pasted verbatim. Use
   `model: opus` for TF-07 and for any item whose row mentions schema,
   migration, or App Group.

Launch all lanes in one parallel batch.

## Stage 3: gate, review, PR (per lane, as each finishes)

When a lane reports:

1. If RESULT is BLOCKED with OWNER NEEDED, write its checklist under the
   item's entry in the report and leave the branch as is.
2. Otherwise run `/pr-review worktree` from inside that lane's worktree
   (it dispatches the six reviewers). If the verdict is REQUEST_CHANGES,
   send the blockers to the same `tf-lane` agent via SendMessage for one
   repair round, then review again. At most 2 rounds; then report.
3. Push and open the PR:
   ```
   gh pr create --base main --title "TF-##: <row scope, shortened>" \
     --body-file <file containing the lane's report plus the review's audit trail>
   ```
   Use `--draft` when the item depends on an unmerged parent.
4. Launch `ci-watch` on the new PR. If it reports FAILED, hand the PR to
   `tf-repair` (one round).

## Stage 4: report

```
## /lanes: <date>
MAIN: sha | a11y audit: pass/fail | 5x stress: pass/fail
RESUMED:
- PR #n TF-##: tf-repair RESULT, ci-watch RESULT
LANES:
- TF-##: branch, tf-lane status, /pr-review verdict, PR #n, ci-watch RESULT
WAITED: items that were READY but not started, with the lock or budget reason
OWNER NEEDED: merged checklist across all lanes
NEXT RUN: what the next /lanes invocation will find
```

Merging: a PR may be merged (`gh pr merge --squash --delete-branch`) only when
every required check is green on the current head, the hosted review has zero
unresolved blockers, `/pr-review` returned APPROVE, and no owner-only gate is
outstanding (manual VoiceOver smoke for any diff touching `Features/`,
`DesignSystem/`, or `App/` view code; device checks; signing). If any of those
is missing, leave it open and list it under OWNER NEEDED. After a merge, remove
that lane's worktree with `git worktree remove` and free the budget.

Never delete a worktree or branch for any other reason. Never edit
`TESTFLIGHT_PLAN.md` from the root checkout; lanes update their checkpoint
inside their own PR.
