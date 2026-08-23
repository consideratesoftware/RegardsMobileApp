# Claude Code adapter

Read and follow `AGENTS.md`. It is the provider-neutral repository instruction
file. `ARCHITECTURE.md` is the product and technical source of truth, and
`TESTFLIGHT_PLAN.md` is the live execution queue and restart protocol.

For a pull-request review, invoke `/pr-review` from
`.claude/commands/pr-review.md`. The reviewer contracts in `.claude/agents/`
must stay equivalent to their `.codex/agents/` adapters; CI enforces that with
`scripts/check-review-agent-parity.sh`.

The delivery side is an engineering org of Claude-only agents described in
`ENGINEERING_ORG.md`: `/org` is the engineering manager; `tech-lead`,
`senior-ios-engineer`, `ios-engineer`, `qa-engineer`, `verifier`,
`build-engineer`, `on-call-engineer`, `release-manager`, and `tech-writer`
are the roles. The parity check covers only the `pr-*` reviewers.
