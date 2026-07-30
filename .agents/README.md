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
