---
description: Run the staged multi-agent PR review (correctness, security/privacy, tests, accessibility, code quality, fit-and-finish) and merge the verdicts into one review.
---

Review the current branch against `origin/main...HEAD`, or use the target in `$ARGUMENTS`.
Treat the literal target `worktree` as all tracked and untracked changes against
`HEAD`. Follow this workflow exactly.

## Stage 0 — pre-flight gate (do this yourself; no agents yet)

1. Resolve the target:
   - No argument: `origin/main...HEAD`, the target the org's verdict comments name.
   - Branch/ref argument: use that exact diff target.
   - `worktree`: use `git status --short`, `git diff HEAD`, and full reads of
     every untracked file.
   If the target is empty, stop and say so.
2. Run the cheap mechanical checks an agent shouldn't burn tokens on. These
   4 are the whole set, with the exact commands in steps 2 to 4 of
   `.claude/agents/build-engineer.md`:
   - XcodeGen determinism: copy `ios/` into a temporary directory, run
     `xcodegen generate` inside the temporary `ios/`, compare its
     `Regards.xcodeproj` with the working tree, and remove the temporary
     directory on both paths. Never generate into the working tree during
     review.
   - SwiftLint from the repo root, never from `ios/`:
     `(cd "<worktree root>" && swiftlint --strict)`.
   - The 2 iOS guard scripts this pre-flight uses, from the repo root:
     `scripts/check-no-network.sh` (the privacy grep) and
     `scripts/check-domain-purity.sh`. Each is its own check; a nonzero exit
     from either fails pre-flight. (CI also runs Android guards; this
     pre-flight doesn't.)
3. If any pre-flight check fails: STOP. Report the failures as the review; do not dispatch agents against a red baseline.

## Stage 1 — dispatch (parallel, conditional)

Decide the agent set from the diff's touched paths:

| Agent | Model | When |
|---|---|---|
| pr-correctness | opus | always |
| pr-security-privacy | sonnet | always |
| pr-tests | sonnet | only if the diff changes code or tests |
| pr-code-quality | haiku | always |
| pr-accessibility | sonnet | only if diff touches Features/, DesignSystem/, App/ view code, RegardsAccessibilityTests/, or ios/docs/accessibility* |
| pr-fit-finish | haiku | only if diff touches Features/, DesignSystem/, user-facing strings, docs, or .github/ |

Launch all selected agents **in a single parallel batch**. Each agent prompt
must contain: the resolved target, the stable `TF-##` work item when present,
the §14 scope alias and acceptance-criteria row pasted verbatim (or "infra, no
§14 row" for an infra PR), and the list
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

### Owner questions (interview in session)
...

### Audit trail
- Invariants verified (from pr-security-privacy, verbatim)
- Process line (from pr-accessibility, if run)
- Docs line (from pr-fit-finish, if run)
- Criteria map (from pr-tests, verbatim)
- Not checked (every agent's `NOT CHECKED:` line that isn't `none`)
```

Merge rules:
- Deduplicate: same file:line from multiple agents becomes one entry crediting both; keep the most severe rating.
- Any single BLOCKER from any agent ⇒ overall REQUEST_CHANGES. So is any
  agent's own REQUEST_CHANGES verdict, including one caused by a `NOT CHECKED:`
  entry. No exceptions, no averaging.
- An agent that contradicts ARCHITECTURE.md is wrong by definition; note it and drop the finding (then flag the doc §, in case the doc needs a look).
- Cap the merged review at 10 nits total; drop the rest silently.
- Do not soften findings. Do not add praise. The review is a work order, not a performance evaluation.

## Stage 4 — register hygiene

If the PR claims R-closures (§19): verify each acceptance check yourself against the diff and mark each claim CONFIRMED or NOT MET in the merged review. NOT MET is automatically a blocker (§17: never mark a remediation item done without meeting its acceptance check).

## Claude Code org only

The verified run is how the Claude Code org runs this review. It is the one
exception to the Stage 3 rule that any BLOCKER means REQUEST_CHANGES. The
hosted review reads this file but applies Stages 1 to 4 only, and its
`Workflow` tool is disabled by `--disallowedTools` in
`.github/workflows/claude-pr-review.yml`, so it never runs this section. The Codex
skill cannot run workflows either, so it does not use this section. The hosted
review stays a separate gate.

Use the verified run when the Workflow tool is available and someone can
approve its prompt in this session. Otherwise run Stages 1 to 3 as written,
with `codex-reviewer` in the same batch. An unattended `/org` run that cannot
approve the prompt takes the plain path.

Owner ruling, 2026-11-07: codify the verified run, and list every refuted
finding in the PR REVIEW comment so the owner can see what was dropped.

### The workflow's rules

1. A finding is refuted only when 2 of its 3 verifiers say `real=false`. A
   verifier that fails, returns nothing, or returns any answer other than an
   explicit `real: false` counts as a real vote.
2. Only BLOCKER and FIX findings go to verifiers. ESCALATE findings and
   coverage holes are returned untouched for Stage 2.
3. A pr-* reviewer's REQUEST_CHANGES becomes APPROVE only when at least one
   of its findings was refuted, none of its BLOCKERs survived, it has no NOT
   CHECKED entry, its `blockerCount` (its own `BLOCKERS: n` count) equals the
   number of BLOCKER findings it listed, and (pr-code-quality only) none of its
   FIX findings survived. A missing or non-integer `blockerCount` blocks the
   flip. The pr-code-quality clause is deliberately conservative.
   `pr-code-quality.md` makes a layering violation, a false comment or a
   hand-edited pbxproj a REQUEST_CHANGES on its own, and 3 or more FIX findings
   too. The workflow sees only severity, so it cannot tell those apart. The
   other reviewers' contracts do not turn a FIX finding into REQUEST_CHANGES, so
   their FIX findings are should-fix and do not block the flip.
4. A pr-* reviewer is REQUEST_CHANGES, whatever it reported, when it has a
   surviving BLOCKER of its own; when its `blockerCount` (its own `BLOCKERS: n`
   count) is not a whole number equal to the BLOCKER findings it listed; or when
   its report text is not empty and the first line starting with `VERDICT:` is
   not exactly `VERDICT: <the verdict it returned>`. These checks cover an APPROVE
   too, so an APPROVE cannot hide a blocker the reviewer counted but did not list.
5. Codex's verdict is Codex's own. The verifiers never change it. A refuted
   Codex BLOCKER still needs a fix or a `DISPUTED:` line (merge condition 4 in
   `ENGINEERING_ORG.md`), and it appears on a `REFUTED:` line. A Codex entry
   whose structured verdict and the verdict word in its first line disagree is
   FAILED, and so is one whose first line is blank or is not a verdict line. A
   Codex with no review text (absent or empty) keeps its reported verdict.
6. A pr-* reviewer whose `reviewedSha` is missing, under 7 characters, not
   lower-case hex, or not a prefix of head is FAILED, whatever it reported.
   Rerun that reviewer alone. Codex's sha is not checked here.
7. A pr-* reviewer's APPROVE becomes REQUEST_CHANGES when its `notChecked` is
   missing or not empty. Every pr-* contract says "Never APPROVE with a required
   check left unchecked." `notChecked` holds required checks only. Anything else
   a reviewer could not run goes in its report.

Each verifier votes under the finding-verification mode in
`.claude/agents/verifier.md`.

### How to run it

Run Stage 0 yourself. Start the workflow and every plain-run agent from a
session whose folder is the root checkout on `main`, never a PR checkout, so the
reviewer, verifier and codex-reviewer contracts load from main. Pass the PR head
only as `worktree`. Then start the workflow once:

```
Workflow({ scriptPath: "<copy exported from origin/main>", args: { title, worktree, branch, head, since, reviewers, codex, contextFile } })
```

- `title`: the PR's short name.
- `worktree`, `branch`: the lane worktree and its branch.
- `head`: the full 40-character head sha.
- `since`: scoped recheck only, the last reviewed head. Leave it out otherwise.
  After an update-branch merge, leave it out and run a full review. A two-dot
  range from any earlier head includes main's commits, whichever parent it
  starts from.
- `reviewers`: the pr-* reviewers this round runs: the Stage 1 set, or the set
  a scoped recheck reruns.
- `codex`: `true`, so Codex reviews in the same workflow. Use `false` while a
  Codex UNAVAILABLE owner gate is open (`org.md` Stage 3).
- `contextFile`: the absolute path of the lane's `review-context.md`. It must
  hold the §14 row (or "infra, no §14 row" for an infra PR) and the R-numbers
  verbatim. For the workflow it replaces
  Stage 1's per-prompt paste of those two.

Always start the workflow by `scriptPath`, never by `name`. Point `scriptPath`
at a copy of `.claude/workflows/pr-review-verified.js` exported from
`origin/main`, the same way `release-manager.md` takes
`check-carried-approval.sh`. Never run it by `name` from a lane: `name` resolves
from the session's folder, and the lane's copy is PR-controlled.

Self-edit PRs. A PR that adds or changes `.claude/workflows/pr-review-verified.js`
gets run (a) and, optionally, run (b), on the same head. Run (a) is the counting review
and the only run that includes Codex.

- (a) Main's copy. Export it with `git show origin/main:.claude/workflows/pr-review-verified.js > <scratch>/pr-review-verified.js`, and start that copy by `scriptPath`. When `origin/main` has no copy, the plain run takes its place: Stages 1 to 4 dispatched as individual agent calls, not through any workflow script, with Codex run by the `codex-reviewer` agent. In the plain run, every reviewer BLOCKER counts. Run (a) is the only run with Codex. Save its review as `codex-<short sha>.md` and post it as the `CODEX REVIEW:` comment.
- (b) Optional: the PR's own copy, in the lane worktree, started by `scriptPath` with `codex: false`. When it runs, each pr-* reviewer counts at the stricter of runs (a) and (b). Run (a) alone is a complete counting review.

When run (b) runs, each pr-* reviewer counts at the stricter of its 2 runs, in the order FAILED, then REQUEST_CHANGES, then APPROVE. BLOCKERS and SHOULD_FIX take the higher count. In run (b), they count every pr-* BLOCKER and FIX in `survivors` and `refuted`. A Codex RETRY or UNAVAILABLE follows the owner-gate rules under "Handle Codex by its case" below. A verdict from the PR's own copy never counts alone.

For run (b), also make these hand checks. FAILED when `reviewedSha` is missing, under 7 characters, not lower-case hex, or not a prefix of head. REQUEST_CHANGES when `notChecked` is missing or not empty, or when it raised any BLOCKER, in `survivors` or in `refuted`. Refuted findings still get their `REFUTED:` lines.

Then run Stage 2 on each verdict's `escalations` and `coverageHoles`, as fresh
pr-correctness and pr-tests runs (the workflow's reviewers can't take a
SendMessage), then Stage 4. Repair items come from `workOrder`; `survivors`
lists every surviving finding. Send each item to its owner as `org.md` Stage 3
says.

### What the workflow returns

- `verdicts`: one entry per reviewer. `verdict` is the verdict after
  verification, and the verdict comment uses it. `reportedVerdict` is what the
  reviewer said. A reviewer that returned nothing has `verdict: FAILED`.
  `reviewedSha` is the sha the reviewer checked. A pr-* reviewer whose sha is
  not a prefix of head comes back `FAILED`, so rerun it alone. `report` is its
  whole report. Stage 3's audit trail quotes INVARIANTS VERIFIED, CRITERIA MAP,
  PROCESS and DOCS from it. `notChecked` is the Not checked line. `escalations`
  and `coverageHoles` are Stage 2 input. `nits` is the Stage 3 Nits list, and
  `questions` is the Stage 3 Owner questions list.
- `codexReview`: Codex's full review, verbatim, or null. Save it as
  `codex-<short sha>.md` before you post. Its first line is the Codex verdict
  line, which the Codex entry's `codexLine` also carries. A Codex entry with
  APPROVE or REQUEST_CHANGES but `codexReview` null has no review to save;
  rerun `codex-reviewer` alone.
- `refuted`: one entry per refuted finding, with its reviewer, severity,
  location, claim and votes. Each vote names a `lens` (`truth`, `scope` or
  `impact`) and `real` (`true`, `false` or `'failed'`).
- `survivors`: one entry per surviving BLOCKER or FIX finding, with its
  reviewer, severity, location, claim, fix and votes.
- `workOrder`: the repair items. The synthesizer that writes it runs as the
  read-only `tech-lead` agent. When its `notes` say the synthesizer returned
  nothing, repair from `survivors`.

Don't post APPROVE while a pr-* reviewer is `FAILED` or has any verdict other than
APPROVE or REQUEST_CHANGES. Rerun a `FAILED` pr-* reviewer alone. The workflow
passes Codex's RETRY and UNAVAILABLE through as its `verdict`. Handle Codex by
its case:

- No Codex verdict on a run with `codex: true` (its entry is `FAILED` or
  missing): rerun `codex-reviewer` alone and use its report. RETRY and
  UNAVAILABLE follow their own bullets below, whatever `codexReview` holds. On a
  run with `codex: false` (an open UNAVAILABLE gate), don't launch it; the gate
  waits for Sid (`org.md` Stage 3).
- RETRY: the one automatic rerun that `org.md` Stage 3 allows. A second RETRY
  on that head, a timeout included, is an owner gate.
- UNAVAILABLE: an owner gate. Interview Sid before rerunning it (`org.md`
  Stage 1 and Stage 3).
- Run (b): any Codex entry or `codexReview` in run (b)'s result is ignored. Only
  run (a) gives Codex.

### The PR REVIEW comment

Post one `PR REVIEW:` comment per round. A plain run and a verified run use
this shape:

```
PR REVIEW: <APPROVE|REQUEST_CHANGES> @ <40-hex head sha> vs origin/main...HEAD
BLOCKERS: <n>
SHOULD_FIX: <n>
REVIEWERS: <pr-reviewer> <APPROVE|REQUEST_CHANGES>, ...
RERAN: <pr-reviewer>, ...                                  (scoped recheck only, as today)
CARRIED: <pr-code-quality|pr-tests> APPROVE from <sha>     (scoped recheck only; 1 per carry)
REFUTED: <reviewer> <BLOCKER|FIX> <path:line> (refuted on <lens>, <lens>): <paraphrase>   (verified run only; else "REFUTED: none")
```

- The first line is APPROVE only when no pr-* BLOCKER survived (in Stage 1 or
  Stage 2) and every pr-* reviewer's verdict is APPROVE. Otherwise it is
  REQUEST_CHANGES.
- BLOCKERS and SHOULD_FIX count the pr-* entries in `survivors` (BLOCKER and
  FIX respectively), plus any Stage 2 items. A plain run has no `survivors`: it
  refutes nothing, so every pr-* finding counts. Refuted findings count for
  neither, except on a self-edit PR (see "How to run it").
  Codex's counts stay on its own comment.
- REVIEWERS takes each reviewer's verdict: the verdict after verification in a
  verified run, or the Stage 1 verdict in a plain run. On a self-edit PR, the
  counting verdicts are the ones "How to run it" sets. A Stage 2
  blocker makes that reviewer REQUEST_CHANGES.
- Each refuted finding gets exactly one `REFUTED:` line, Codex's included.
  `<lens>` names the verifiers that voted `real=false`.
- The paraphrase is your own words: at most 15 words, one physical line, no
  `@`. Never paste reviewer text.
- `release-manager.md` reads the first line and the `REVIEWERS:` and
  `CARRIED:` lines of this comment. It reads `DISPUTED:` lines from the CODEX
  REVIEW comment. Its filter keeps only `REVIEWERS:` and `CARRIED:` lines, so a
  `REFUTED:` line never passes as a carry. `REFUTED:` lines are for Sid to see.
  They never count toward any check.

A scoped recheck passes `since`. Its comment carries `RERAN:` and `CARRIED:`
lines as `org.md` Stage 3 says.

## Cross-model review (Claude Code only)

The Codex verdict comes from the `codex-reviewer` agent type
(`subagent_type: codex-reviewer`), which runs `$regards-pr-review` read-only
against the same target. It is not a stage of this command: `/org` launches
it in the same batch as `/pr-review`, and the merge conditions in
`ENGINEERING_ORG.md` need both verdicts. Launch it by that type name, never
as a general-purpose agent told to read `.claude/agents/codex-reviewer.md`.
