#!/usr/bin/env bash

set -euo pipefail

usage() {
  echo "Usage:"
  echo "  scripts/run-and-review.sh \"<implementation task>\""
  echo "  scripts/run-and-review.sh --review-only [target]"
}

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

if ! command -v claude >/dev/null 2>&1; then
  echo "claude is not installed or is not on PATH." >&2
  exit 127
fi

if [[ "${1:-}" == "--review-only" ]]; then
  review_target="${2:-main...HEAD}"
  exec claude --permission-mode plan --print "/pr-review ${review_target}"
fi

if [[ $# -eq 0 ]]; then
  usage
  exit 64
fi

if ! command -v codex >/dev/null 2>&1; then
  echo "codex is not installed or is not on PATH." >&2
  exit 127
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Start from a clean worktree so the review covers only this task." >&2
  exit 1
fi

task="$*"

codex exec --cd "$repo_root" \
  "Act as the builder for Regards. Implement the task completely with tests. Do not stage or commit changes. Task: ${task}"

if [[ -z "$(git status --porcelain)" ]]; then
  echo "Codex completed without changing the worktree; there is nothing to review."
  exit 0
fi

exec claude --permission-mode plan --print "/pr-review worktree"
