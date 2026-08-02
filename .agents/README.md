# Agent adapters

Regards has one vendor-neutral review contract exposed through two adapters:

- `.codex/agents/*.toml` for Codex;
- `.claude/agents/*.md` for Claude Code.

The model and tool metadata are adapter-specific. The normalized reviewer
instructions after that metadata must remain equivalent. Run
`scripts/check-review-agent-parity.sh` after changing either side; CI runs the
same check.

The orchestrators are also equivalent:

- Codex: `$regards-pr-review`
- Claude Code: `/pr-review`

Both use the same role names and the same `APPROVE` / `REQUEST_CHANGES`
contract. Product-specific review law belongs in the mirrored reviewer
instructions or `ARCHITECTURE.md`, not in a provider-only workflow.

## Hosted review gate

`.github/workflows/claude-pr-review.yml` runs the same staged contract and
publishes its verdict through a dedicated GitHub App. The App setup and
branch-protection binding are pending the owner action recorded in
`TESTFLIGHT_PLAN.md`. The workflow uses `pull_request_target` only for PRs
targeting the default branch. The default-branch policy and publisher stay at
the workspace root. A trusted preparer converts the proposed head to regular
files, rejects symlinks and submodules, neutralizes Claude/Codex/plugin policy
paths, and moves the raw checkout outside the workspace before the model
starts.

The analysis job receives a read-only GitHub token, cannot call Bash or mutate
GitHub, and returns a typed JSON artifact. A separate trusted job runs XcodeGen
determinism, SwiftLint, and the privacy/Domain guards directly from
default-branch workflow code. Analysis depends on that preflight. The publisher
requires both jobs, validates the artifact against the event's head, base, PR,
and run identity, posts it through the dedicated App bot, and fails on
`REQUEST_CHANGES`. The publisher uses that App credential from the
`hosted-review` environment to create the head-bound `Regards staged review`
check. Branch protection binds that context to the dedicated App's identity, so
a same-repository PR cannot satisfy it with an identically named Actions job.
The preparer, validators, and fixtures live under `scripts/`.

For a stacked PR, keep the child draft on its parent. After the parent merges,
retarget and rebase the child to the default branch, publish it, then push the
rebased head. The synchronization event runs the required workflow against the
final base.
