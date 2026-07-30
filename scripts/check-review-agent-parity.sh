#!/usr/bin/env bash

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

python3 - <<'PY'
from pathlib import Path
import re
import sys
import tomllib

claude_dir = Path(".claude/agents")
codex_dir = Path(".codex/agents")
claude_names = {path.stem for path in claude_dir.glob("*.md")}
codex_names = {path.stem for path in codex_dir.glob("*.toml")}

if claude_names != codex_names:
    print("Agent adapter sets differ.", file=sys.stderr)
    print(f"Claude only: {sorted(claude_names - codex_names)}", file=sys.stderr)
    print(f"Codex only: {sorted(codex_names - claude_names)}", file=sys.stderr)
    sys.exit(1)

failed = False
for name in sorted(claude_names):
    claude_text = (claude_dir / f"{name}.md").read_text()
    match = re.match(r"\A---\n.*?\n---\n\n?(.*)\Z", claude_text, re.DOTALL)
    if match is None:
        print(f"{name}: invalid Claude frontmatter", file=sys.stderr)
        failed = True
        continue

    claude_body = match.group(1).strip()
    with (codex_dir / f"{name}.toml").open("rb") as file:
        codex_body = tomllib.load(file)["developer_instructions"].strip()

    if claude_body != codex_body:
        print(f"{name}: reviewer instructions have drifted", file=sys.stderr)
        failed = True

if failed:
    sys.exit(1)

print(f"{len(claude_names)} review agent pairs are in sync.")
PY
