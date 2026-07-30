# Claude Code adapter

Read and follow `AGENTS.md`. It is the provider-neutral repository instruction
file. `ARCHITECTURE.md` is the product and technical source of truth, and
`TESTFLIGHT_PLAN.md` is the live execution queue and restart protocol.

For a pull-request review, invoke `/pr-review` from
`.claude/commands/pr-review.md`. The reviewer contracts in `.claude/agents/`
must stay equivalent to their `.codex/agents/` adapters; CI enforces that with
`scripts/check-review-agent-parity.sh`.
