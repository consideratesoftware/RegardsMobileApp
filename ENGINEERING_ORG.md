# Engineering org

Regards is built by a small engineering organization made of Claude Code
agents, with Sid as owner. This file is the org contract: who does what,
which model each role runs on, how work moves between roles, and what the
owner alone decides. `AGENTS.md`, `ARCHITECTURE.md`, and
`TESTFLIGHT_PLAN.md` stay the sources of truth for the product and the
queue; this file only says how the org executes them.

The org optimizes for correctness over velocity. Parallelism comes from
running up to 3 work items at once, each in its own linked worktree, not
from skipping steps inside an item.

## Org chart

| Role | Agent | Model | Edits code? | Why this model |
|---|---|---|---|---|
| Engineering manager | `/org` command (the main session) | session model | no | Holds the whole state; decides staffing, locks, merges |
| Tech lead | `tech-lead` | opus | no | Design, slicing, and rulings are judgment work; read-only keeps cost bounded |
| Senior iOS engineer | `senior-ios-engineer` | opus | yes | Engine, schema, migrations, Swift 6 concurrency; errors here are expensive |
| iOS engineer | `ios-engineer` | sonnet | yes | Features, views, adapters from an approved plan |
| QA engineer | `qa-engineer` | sonnet | tests only | Writes the test plan's tests, runs suites, investigates flakes |
| Verifier | `verifier` | opus | no | Tries to refute a slice's correctness claim before review |
| Build engineer | `build-engineer` | haiku | no | Mechanical gates; no judgment needed |
| On-call engineer | `on-call-engineer` | sonnet | yes | Red checks and review blockers on open PRs |
| Release manager | `release-manager` | sonnet | no | PR lifecycle, CI, checkpoint, merge execution |
| Tech writer | `tech-writer` | haiku | docs only | Sibling doc edits from facts other roles supply |
| Review board | `pr-correctness` (opus), `pr-security-privacy` (sonnet), `pr-tests` (sonnet), `pr-accessibility` (sonnet), `pr-code-quality` (haiku), `pr-fit-finish` (haiku) via `/pr-review` | as listed | no | Unchanged; mirrored to `.codex/agents/` and checked by CI |

Only the `pr-*` reviewers are mirrored for Codex. Every other role is Claude
Code only; `scripts/check-review-agent-parity.sh` ignores them by prefix, so
a new non-reviewer role must not be named `pr-*`.

## How one work item moves

```
TF-## READY
  → tech-lead: design, slices, test plan, ownership, locks
  → engineering manager: lock check, worktree, simulator
  → per slice, in parallel: engineer (production files) + qa-engineer (test files)
      → build-engineer gates each before commit
      → verifier tries to refute the slice
  → tech-writer: doc siblings, register, a11y rows
  → /pr-review (review board)
  → release-manager: PR, CI, hosted review, on-call repairs, checkpoint
  → merge when every condition below holds, else parked with an owner checklist
```

Handoffs are the structured report blocks at the end of each agent file.
The engineering manager pastes them forward verbatim; nothing is retold from
memory. Branch, worktree, PR body, and `TESTFLIGHT_PLAN.md` are the durable
state, as the restart protocol already requires.

## Lanes

- At most 3 implementation lanes. A dirty worktree or an open TF PR occupies
  a lane even when no agent is running in it, including a lane a human or
  another Claude session is driving by hand.
- Each lane gets `../RegardsMobileApp-TF##`, branch `claude/tf-##-<slug>`,
  simulator `RegardsTF##`, and `/tmp/RegardsTF##DerivedData`. Lanes never
  share a simulator or DerivedData.
- Lock files (from `TESTFLIGHT_PLAN.md`): `AppEnvironment`, `RegardsApp`,
  repository and migration files, `project.yml` and the generated project,
  SchedulingPass, Upcoming/Overdue/Contact Detail, Onboarding/Settings,
  shared accessibility helpers, execution docs. One lane per lock at a time.
- Review, CI watching, on-call repair, and release management do not consume
  a lane.

## Merge conditions

All of these, on the current head, with no averaging:

1. Every required check green.
2. Hosted `Regards staged review`: zero unresolved blockers.
3. `/pr-review` verdict APPROVE.
4. Verifier verdict HOLDS for every slice.
5. No owner-only gate outstanding (below).

The release manager executes the merge. Any role that finds itself wanting
to skip one of these is wrong by definition.

## Owner gates

Only Sid can do these. The org writes an exact checklist and parks the PR;
it never pretends the step happened.

- Manual VoiceOver smoke (`ios/docs/accessibility-smoke.md`) for any diff
  touching `Features/`, `DesignSystem/`, or `App/` view code.
- Physical-device runs (A15 budget, device matrix, TF-18).
- Signing, provisioning, App Store Connect, TestFlight uploads.
- Design rulings the tech lead marks OPEN FOR OWNER.
- Scope changes to the queue or dependency graph.

Simulator gates run on this Mac through `build-engineer`; GitHub-hosted
macOS runners run the same gates plus the hosted review on every PR.

## What the org will not do

Everything in the `Automation contract` section of `TESTFLIGHT_PLAN.md`,
plus: amend or force-push a reviewed branch, `git add -A`, edit the plan in
the root checkout, dispatch into a worktree another session is using, or
name a non-reviewer agent `pr-*`.

## Starting the org

From a clean `main` in the root checkout:

```bash
claude "/org"
```

Read-only standup:

```bash
claude "/org status"
```

Restrict to items:

```bash
claude "/org TF-05 TF-06"
```

Each run is idempotent against the durable state: it resumes open PRs
first, then staffs free lanes, and reports what the next run will find.
