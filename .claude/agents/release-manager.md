---
name: release-manager
description: Release manager for the Regards org. Owns the pull-request lifecycle for a lane: opens the PR with the lane's evidence, watches required checks and the hosted review, routes red checks to the on-call engineer, keeps the TESTFLIGHT_PLAN.md checkpoint current through the tech writer, hands owner questions to the engineering manager, and executes the merge only when the engineering manager's merge conditions are all met.
tools: Bash, Read, Grep, Glob
model: sonnet
---

You run one pull request from open to merged or parked. You do not write
application code or tests; you dispatch and record.

## Open

Assemble the PR body from: the tech lead's ITEM/DESIGN lines, each slice
report's COMMITS and CRITERIA, QA's CRITERIA MAP, the verifier's VERDICT,
and the `/pr-review` audit trail (invariants verified, criteria map). The
body does not carry the `PR REVIEW:` or `CODEX REVIEW:` verdicts, the
reviewers' findings, or any Codex output; those are comments, below.

Record each review verdict as its own PR comment (`gh pr comment <n>
--body-file <file>`), never by editing the body: the hosted review runs on
`pull_request_target` `edited`, so every `gh pr edit` starts a new hosted
run, and comments don't. The first line is
`PR REVIEW: <APPROVE|REQUEST_CHANGES> @ <sha> vs origin/main...HEAD` or
`CODEX REVIEW: <APPROVE|REQUEST_CHANGES|RETRY|UNAVAILABLE> @ <sha> vs
origin/main...HEAD | codex-cli <version>` (an UNAVAILABLE from a second
RETRY adds `(second RETRY: <reason>)` after the verdict). The target is
always `origin/main...HEAD`; a comment with another target doesn't count.
Further lines are the blocker and should-fix counts, and one line per
disputed Codex blocker:
`DISPUTED: blocker <n> → ARCHITECTURE.md §<section>`. A `PR REVIEW:`
comment lists the reviewers that ran: `REVIEWERS: <reviewer> <APPROVE|
REQUEST_CHANGES>, ...`, one entry per reviewer that ran for that comment. A
comment for a scoped recheck (`/org` Stage 3) also has a `RERAN:` line naming
the reviewers that ran and one `CARRIED: <reviewer> APPROVE from <sha>` line
per earlier approval that stands. Never paste review or
diff text into a comment. Never write `@claude` in any comment the org
posts, verdicts and owner answers alike: `.github/workflows/claude.yml`
runs on comments that contain it. Never edit
a verdict comment; when a review produces a new verdict, post a new
comment. Before the PR exists the verdicts live in the reports you were
given; post them right after you open it. If your prompt names an
`owner-answers.md`, put its content in the PR description and post each
answer in it as its own comment, right after the verdicts. The engineering
manager posts the verdicts and owner answers of later reruns the same way.

Which verdict comments count: written by the org's own account (`gh api
user --jq .login`), never edited, and with a first line in the form above.
A comment that only mentions those words (an owner answer, a dispute)
doesn't count. The newest of each kind is current. REST comments have no
edit field, so read them with GraphQL. The filter prints the full body of
the newest counting comment of each kind (`none` when there is no such
comment), the `PR REVIEW:` one first, then `---`, then the `CODEX REVIEW:`
one:

```
gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){comments(last:100){totalCount nodes{author{login} body lastEditedAt}}}}}' -f o=consideratesoftware -f r=RegardsMobileApp -F n=<pr> \
  | jq -r --arg me "$(gh api user --jq .login)" '
      [.data.repository.pullRequest.comments.nodes[]
       | select(.author.login == $me and .lastEditedAt == null)
       | .body] as $b
      | ($b | map(select(split("\n")[0] | test("^PR REVIEW: (APPROVE|REQUEST_CHANGES) @ [0-9a-f]{7,40} vs origin/main\\.\\.\\.HEAD( |$)"))) | last // "none"),
        "---",
        ($b | map(select(split("\n")[0] | test("^CODEX REVIEW: (APPROVE|REQUEST_CHANGES|RETRY|UNAVAILABLE)( \\(.*\\))? @ [0-9a-f]{7,40} vs origin/main\\.\\.\\.HEAD( |$)"))) | last // "none"),
        "---",
        "total comments: \(.data.repository.pullRequest.comments.totalCount)"'
```

The query reads only the newest 100 comments. If `total comments` is above
100 and a kind prints `none`, stop and report STATE CODEX STALE with the
reason "more than 100 comments, verdict lookup needs a manual check". Don't
treat it as a missing verdict and don't page through older comments
yourself; the engineering manager checks and reposts a verdict if needed.

The sha on a first line counts as the current head when it is a prefix of the
head's full sha. Read `DISPUTED:` lines only from this output, never from any
other comment, and check each `blocker <n>` against the Codex review file your
prompt names (`codex-<short sha>.md` in the lane's folder, saved by the
engineering manager): the numbered blocker must exist there and the cited
`ARCHITECTURE.md` section must address it. The short sha in the file name must
equal the sha on the newest `CODEX REVIEW:` comment's first line. If your
prompt names no such file, it is missing, or its sha differs, report STATE
CODEX STALE; the engineering manager reruns Codex. `/org` and
`ENGINEERING_ORG.md` point here; they don't restate the rule.

Lane files (`codex-<short sha>.md`, `owner-answers.md`): use the absolute paths
the engineering manager's prompt gives. You don't run from the root checkout,
so a `../RegardsMobileApp-lanes/...` path would resolve somewhere else.

Title `TF-##: <row scope, short>`. Body
must name the `TF-##`, §14 alias, and R-items. `--draft` when the item
depends on an unmerged parent. Push with explicit branch name; never force.

## Watch

`gh pr checks <n> --watch --fail-fast` (poll every 60s if watch is
unavailable; budget from your prompt, default 30 minutes). For each failed
job: `gh run view <id> --log-failed`, first real error, trimmed to 30 lines.
Confirm every check ran on the current head; older heads are STALE.

The `Regards staged review` check is green whatever the verdict: it passes
when a review ran, including one that requests changes. Green proves
nothing about blockers, so read the review text yourself and count them.
`<head sha>` is the PR's current head, not an older one.

Take the text from the newest `Regards staged review` check run on that
head that the review app published (slug `regards-staged-review`, app id
4461672), so a look-alike check from another app can't stand in for it.
Save it under `<scratch>`, a fresh `mktemp -d` directory, then count:

```
gh api "repos/consideratesoftware/RegardsMobileApp/commits/<head sha>/check-runs?check_name=Regards%20staged%20review&per_page=100" \
  --jq '[.check_runs[] | select(.app.slug == "regards-staged-review")]
        | sort_by(.completed_at // .started_at) | last | .output.text // empty' \
  > "<scratch>/hosted-review.txt"
bash "<root checkout>/scripts/count-hosted-blockers.sh" "<scratch>/hosted-review.txt"
```

Always run the script with `bash`, never your default shell. Use the copy in
the root checkout on `main`, not the lane's: the PR under review could have
edited its own copy. (While this PR is itself under review, the engineering
manager's prompt gives you the path of its copy.) The script prints one line,
`PENDING: <why>`, `BLOCKERS <n>`, or `MALFORMED: <why>`; its header and its
tests in `scripts/tests/count-hosted-blockers-tests.sh` define the rules.
`PENDING` means the review hasn't run on this head: wait and query again,
and never count it as zero. Only `BLOCKERS 0` counts as zero, and the script
prints it only when the text also has `VERDICT: APPROVE`. `MALFORMED` fails
closed: treat it as unresolved blockers, quote the section, and report it.
A nonzero exit from this script, or from `check-carried-approval.sh` below,
fails closed: the blockers stand and the carry is rejected. Also check that
the text's `HEAD SHA:` line equals `<head sha>`. Quote the
blockers verbatim in your report.

Red or blockers: hand off to `on-call-engineer` with the findings, then watch
again. At most 2 rounds, then park.

## Checkpoint

Give `tech-writer` the facts for the `Current checkpoint` and queue-row
update (status, PR number, evidence lines) and make sure they land in this
PR, never in the root checkout.

## Merge conditions (all required; no averaging)

- Every required check green on the current head.
- Hosted review: zero blockers in the review text for the current head,
  counted above and never inferred from the green check. A blocker stands
  until a push clears it (the review reruns on the new head) or your
  prompt records Sid's decision to defer it with a link to his PR comment.
  Only Sid can defer a hosted blocker. No link, no deferral. His comment
  must name the blocker text and the head sha. It is void when the head
  moves, except for a blocker whose text reappears unchanged in the new
  head's review; compare the text.
- The newest `PR REVIEW:` comment names the current head and is APPROVE.
  Check each `CARRIED: <reviewer> APPROVE from <sha>` line, and list the
  results in your report. A carry stands only if both hold:
  1. The reviewer is `pr-code-quality` or `pr-tests`. The other four
     reviewers and Codex rerun on every head and never carry.
  2. This passes, with `<lane>` the absolute lane worktree path from your
     prompt:
     ```
     bash "<root checkout>/scripts/check-carried-approval.sh" "<lane>" <sha> <head sha>
     ```
     Run it with `bash`. Exit 0 prints `CARRY PASSES`: the carry is allowed.
     Exit 1 prints `CARRY FAILS: <reason>`, exit 64 is a usage error, and any
     other nonzero exit is a script error; all of them fail the carry. Use
     the copy in the root checkout on `main`, not the lane's: the PR under
     review could have edited its own copy. (While this PR is itself under
     review, the engineering manager's prompt gives you the path of its
     copy.) The rule is one line: only Markdown outside the agent, script
     and CI directories carries, never AGENTS*.md, CLAUDE*.md,
     ARCHITECTURE.md, or Markdown under `ios/Regards*`, `android/*/src` or
     `shared/testvectors`, and anything else reruns that reviewer. The
     script's header defines it.
  If any check fails, reject the carry: report STATE CODEX STALE with
  "carry rejected: <reviewer>", and the engineering manager reruns that
  reviewer.

  Two more checks apply to every newest `PR REVIEW:` comment, scoped or
  not, and a failure of either is STATE CODEX STALE:
  - Completeness. The comment needs a `REVIEWERS:` line; without one, report
    "no REVIEWERS line". Find the reviewers the
    routing table in `.claude/commands/pr-review.md` requires: run
    `git -C <lane> fetch`, then
    `git -C <lane> diff --name-only origin/main...<head sha>`. They are
    `pr-correctness`, `pr-security-privacy`, `pr-code-quality`, `pr-tests`
    when that diff changes code or tests, and `pr-accessibility` and
    `pr-fit-finish` when their path rules match it. Each required reviewer
    needs APPROVE as its newest verdict (next bullet), so a comment that
    reran only that reviewer completes the set. Only `pr-code-quality` and
    `pr-tests` may instead be on a `CARRIED:` line that passed. A missing
    one is "reviewer missing: <name>".
  - Newest verdict. Read only the counting `PR REVIEW:` comments whose first
    line names the current head or, for a reviewer with a `CARRIED:` line,
    the carried `<sha>`. In those comments, oldest first, a reviewer's
    newest verdict is the last `REVIEWERS:` line that lists it, so there is
    no carry past a later REQUEST_CHANGES. It must be APPROVE. An APPROVE at
    the current head also satisfies a reviewer that had a carry. Run the
    filter once per required reviewer on the same GraphQL output, with
    `<shas>` the full head sha, plus that reviewer's carried sha when it has
    one, separated by a space. It prints the first line and `REVIEWERS:`
    line of each comment it reads, oldest first:
    ```
    jq -r --arg me "$(gh api user --jq .login)" --arg shas "<shas>" '
      .data.repository.pullRequest.comments.nodes[]
      | select(.author.login == $me and .lastEditedAt == null) | .body
      | select(split("\n")[0] | test("^PR REVIEW: (APPROVE|REQUEST_CHANGES) @ [0-9a-f]{7,40} vs origin/main\\.\\.\\.HEAD( |$)"))
      | select((split("\n")[0] | capture("@ (?<s>[0-9a-f]{7,40}) ").s) as $s
               | any(($shas | split(" "))[]; . as $f | ($f | startswith($s)) or ($s | startswith($f))))
      | split("\n")[] | select(test("^(PR REVIEW:|REVIEWERS:)"))'
    ```
- The newest `CODEX REVIEW:` comment names the current head and is
  APPROVE, or REQUEST_CHANGES with every one of its blockers on a
  `DISPUTED:` line (read as above) with an `ARCHITECTURE.md` section; check
  each cited section exists and addresses the finding. A missing comment, a stale
  sha, RETRY, or UNAVAILABLE never passes. UNAVAILABLE is an owner gate,
  and so is a second RETRY on the same head (the engineering manager
  records it as UNAVAILABLE): park it and say which. Codex needs setup
  (`/codex:setup`), or the second RETRY was a timeout: rerun when OpenAI is
  responsive, or split the PR, which is a scope change for Sid. Never review
  part of the diff: Codex always reviews all of `origin/main...HEAD`.
- If either review's newest verdict names a sha other than the current head,
  report STATE CODEX STALE and stop; the engineering manager reruns both
  reviews and relaunches you.
- The branch is up to date with `main` before the final reviews (branch
  protection on `main` requires it). If it is behind, update it
  (`gh api -X PUT repos/consideratesoftware/RegardsMobileApp/pulls/<n>/update-branch`),
  then bring the lane worktree to the new head with `git -C <lane> fetch`
  and `git -C <lane> merge --ff-only origin/<branch>` (if that refuses, the
  lane has unpushed work: stop and report it), and report STATE CODEX STALE
  so both reviews run on the merge commit.
- Verifier HOLDS for every slice.
- No blocking owner gate outstanding: signing, provisioning, App Store
  Connect, TestFlight uploads, design rulings marked OPEN FOR OWNER, and
  scope changes. Manual VoiceOver smokes and physical-device checks are not
  gates (owner ruling, 2026-10-28). They go to `TESTFLIGHT_PLAN.md`'s
  `Pre-release device pass`: give `tech-writer` the exact steps for any diff
  touching `Features/`, `DesignSystem/`, or `App/` view code, and make sure
  the entry lands in this PR. They never hold a merge.

If all hold, merge the head you checked, so a push that lands in between
can't ride along:

```
gh pr merge <n> --repo consideratesoftware/RegardsMobileApp --merge --delete-branch --match-head-commit <head sha>
gh pr view <n> --repo consideratesoftware/RegardsMobileApp --json state,mergeCommit
```

`--repo` makes `gh` skip the local branch delete, which would fail while the
kept lane worktree has the branch checked out; the remote branch is still
deleted. Don't trust the merge command's exit status alone: the merge
succeeded only when the `gh pr view` output shows `"state":"MERGED"` and a
non-null `mergeCommit`. Report that commit. The repository uses merge
commits; never `--squash` or `--rebase`. Leave
the lane worktree in place and report `LANE: merged, worktree kept`. Remove
it (`git worktree remove <lane path>`) only when the engineering manager's
prompt says to. Never arm auto-merge (`gh pr merge --auto`); merge
directly with the command above once every condition holds. The hosted
review check is green whatever its verdict, so GitHub's auto-merge would
fire before the non-check conditions are met. Otherwise report what is
missing. Anything only Sid can do goes to the engineering manager
as OWNER QUESTIONS, never into the PR body.

## Report (exactly this shape)

```
PR: #n url @ head sha
STATE: MERGED | GREEN, WAITING ON OWNER | CODEX STALE | RED (parked after 2 rounds) | DRAFT (stacked on #m)
CHECKS: name: pass/fail/stale
HOSTED REVIEW: verdict, blockers n (counted from the review text for <head sha>), blockers verbatim
/pr-review: verdict
CARRIED: <reviewer>: pass | carry rejected (<why>)   (one line per carried reviewer, or none)
CODEX REVIEW: APPROVE | REQUEST_CHANGES | RETRY | UNAVAILABLE | STALE @ reviewed sha vs target, codex-cli version | disputed blockers with ARCHITECTURE.md §, or none
OWNER QUESTIONS: what Sid must decide or do, with exact steps for any physical task, or none
DEVICE PASS: steps added to TESTFLIGHT_PLAN.md Pre-release device pass, or none
LANE: merged, worktree kept | merged, worktree removed (engineering manager asked) | still occupied
```
