# Claude Code adapter

Read and follow `AGENTS.md`. It is the provider-neutral repository instruction
file. `ARCHITECTURE.md` is the product and technical source of truth, and
`TESTFLIGHT_PLAN.md` is the live execution queue and restart protocol.

For a pull-request review, invoke `/pr-review` from
`.claude/commands/pr-review.md`. The reviewer contracts in `.claude/agents/`
must stay equivalent to their `.codex/agents/` adapters; CI enforces that with
`scripts/check-review-agent-parity.sh`.

Delivery agents live alongside the reviewers and are Claude Code only:
`tf-lane` (one per work item, in its own linked worktree), `ios-gate` (the
mechanical gates), and `tf-repair` (red checks and review blockers). `/lanes`
runs the `TESTFLIGHT_PLAN.md` restart protocol with up to three lanes in
parallel. The parity check covers only the `pr-*` reviewers.
