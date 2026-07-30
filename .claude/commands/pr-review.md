---
description: Run the staged multi-agent PR review (correctness, security/privacy, tests, accessibility, code quality, fit-and-finish) and merge the verdicts into one review.
---

Review the current branch against `main`, or use the target in `$ARGUMENTS`.
Treat the literal target `worktree` as all tracked and untracked changes against
`HEAD`. Follow this workflow exactly.

## Stage 0 — pre-flight gate (do this yourself; no agents yet)

1. Resolve the target:
   - No argument: `main...HEAD`.
   - Branch/ref argument: use that exact diff target.
   - `worktree`: use `git status --short`, `git diff HEAD`, and full reads of
     every untracked file.
   If the target is empty, stop and say so.
2. Run the cheap mechanical checks an agent shouldn't burn tokens on:
   - Copy `ios/` into a temporary directory, run `xcodegen generate` inside the
     temporary `ios/`, then compare its `Regards.xcodeproj` with the working
     tree. Never generate into the working tree during review.
   - `swiftlint --strict`
   - The privacy-grep and domain-purity patterns from `.github/workflows/guards.yml` against the diff
3. If any pre-flight check fails: STOP. Report the failures as the review; do not dispatch agents against a red baseline.

## Stage 1 — dispatch (parallel, conditional)

Decide the agent set from the diff's touched paths:

| Agent | Model | When |
|---|---|---|
| pr-correctness | opus | always |
| pr-security-privacy | sonnet | always |
| pr-tests | sonnet | always (code or test changes) |
| pr-code-quality | haiku | always |
| pr-accessibility | sonnet | only if diff touches Features/, DesignSystem/, App/ view code, RegardsAccessibilityTests/, or ios/docs/accessibility* |
| pr-fit-finish | haiku | only if diff touches Features/, DesignSystem/, user-facing strings, docs, or .github/ |

Launch all selected agents **in a single parallel batch**. Each agent prompt
must contain: the resolved target, the stable `TF-##` work item when present,
the §14 scope alias and acceptance-criteria row pasted verbatim, and the list
of R-numbers the PR claims to close. Do not paste the diff itself into agent
prompts; agents pull it with git.

## Stage 2 — cross-checks (sequential, only if needed)

- If pr-correctness returned COVERAGE HOLES and pr-tests has already reported: send the holes list to a fresh pr-tests run scoped to just those holes (haiku-cheap follow-up is fine via model override).
- If pr-code-quality returned ESCALATE items: forward them to pr-correctness via SendMessage for a ruling; its answer joins the findings.

## Stage 3 — merge into one review

Produce exactly this structure:

```
## PR Review — <branch> — <date>
PRE-FLIGHT: determinism ✅/❌ | swiftlint ✅/❌ | guards ✅/❌
VERDICT: APPROVE | REQUEST_CHANGES

### Blockers (must fix before merge)
- [agent] [file:line] finding → fix → ref

### Should fix (before or in fast-follow, owner's call)
...

### Nits (take or leave)
...

### Questions for Sid
...

### Audit trail
- Invariants verified (from pr-security-privacy, verbatim)
- Process line (from pr-accessibility, if run)
- Docs line (from pr-fit-finish, if run)
- Criteria map (from pr-tests, verbatim)
```

Merge rules:
- Deduplicate: same file:line from multiple agents becomes one entry crediting both; keep the most severe rating.
- Any single BLOCKER from any agent ⇒ overall REQUEST_CHANGES. No exceptions, no averaging.
- An agent that contradicts ARCHITECTURE.md is wrong by definition; note it and drop the finding (then flag the doc §, in case the doc needs a look).
- Cap the merged review at 10 nits total; drop the rest silently.
- Do not soften findings. Do not add praise. The review is a work order, not a performance evaluation.

## Stage 4 — register hygiene

If the PR claims R-closures (§19): verify each acceptance check yourself against the diff and mark each claim CONFIRMED or NOT MET in the merged review. NOT MET is automatically a blocker (§17: never mark a remediation item done without meeting its acceptance check).
