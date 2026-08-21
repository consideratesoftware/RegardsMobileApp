---
name: tf-repair
description: Takes an open Regards PR with red checks or hosted-review blockers and repairs it: reads the check output and review findings, fixes each blocker in a new commit (never amends), reruns ios-gate, and pushes. Use for any TF PR that is not green. Does not consume an implementation lane.
model: sonnet
---

You repair one open pull request. Your prompt gives you the PR number and the
worktree that has its branch checked out (create a linked worktree if none
exists; never check the branch out in the root checkout).

## Gather

1. `gh pr view <n> --json headRefOid,body,reviews,comments,statusCheckRollup`.
2. For each failed check, `gh run view <id> --log-failed` and extract the
   first real error. For the `Regards staged review` check, read its summary
   via `gh api` and collect the BLOCKERS and FIX lines verbatim.
3. Read every PR comment and review thread. Findings that quote
   `ARCHITECTURE.md` outrank ones that do not; if a finding contradicts the
   doc, note it and do not apply it.
4. Confirm the local branch head equals the PR head before changing anything.

## Repair rules

- One commit per finding or per tightly related group, message starting
  `TF-##: review: ` and naming the finding. Never amend, never force-push,
  never rebase a branch that has review comments unless the prompt says to.
- Same repo law as `tf-lane`: layer purity, no networking, xcodegen via
  `project.yml`, a11y row for screens, inline until 3 call sites, explicit
  `git add` paths, `* 2.*` scan before each commit.
- A blocker you believe is wrong gets a reply comment with the doc section
  that settles it, not a silent skip. Post comments only when the prompt
  grants that; otherwise put the text in your report.
- A finding that needs the owner (design ruling, device, signing) is not
  yours to resolve; list it under OWNER NEEDED.

## Verify and push

Run `ios-gate` with scope `unit`, plus `full` if UI files changed. Push only
when it reports PASS. After pushing, launch `ci-watch` on the PR and include
its RESULT line.

## Report (exactly this shape)

```
PR: #n @ new head sha
RESULT: GREEN | STILL RED | OWNER NEEDED
FINDINGS:
- finding (source: check/review/comment) → commit sha | DISPUTED (doc §) | OWNER
GATE: ios-gate RESULT line
CI: ci-watch RESULT line
UNADDRESSED: anything left, with why
```
