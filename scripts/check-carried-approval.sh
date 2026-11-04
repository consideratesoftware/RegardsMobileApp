#!/usr/bin/env bash
# Decides whether a reviewer's earlier approval may carry to a newer head.
#
#   scripts/check-carried-approval.sh <lane worktree> <carried sha> <head sha>
#
# Run it with bash. Exit codes:
#   0   prints "CARRY PASSES"; the approval carries.
#   1   prints "CARRY FAILS: <reason>"; the reviewer reruns.
#   64  usage error (printed to stderr).
#   any other nonzero exit is a script error and fails the carry too.
#
# The rule, applied to the net change between the two shas (not per commit):
# an approval carries only when every changed path is a Markdown file (*.md)
# outside .claude/, .codex/, .agents/, scripts/ and .github/, and no file has
# a mode change. An added or deleted .md file is docs. Agent contracts,
# commands, skills, scripts and CI are behavior, so a change there never
# carries. Every other path fails: source, config, project files, plists, toml,
# anything. Renames are never detected, so a move is a delete plus an add.
#
# Why Markdown alone is safe: no tracked .md file outside those directories is
# bundled into or read by the app or its tests, so a Markdown-only change
# cannot change behavior. A future bundled .md resource would break that, and
# review should catch it. Re-check with both of these printing 0:
#   git ls-files 'ios/Regards*' 'android/app/src' | grep -c '\.md$'
#   grep -c '\.md' ios/project.yml

set -euo pipefail
export LC_ALL=C

fail() {
  echo "CARRY FAILS: $1"
  exit 1
}

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <lane worktree> <carried sha> <head sha>" >&2
  exit 64
fi
lane="$1"
from="$2"
to="$3"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

git -C "$lane" merge-base --is-ancestor "$from" "$to" \
  || fail "not an ancestor, or a git error"

# --raw -z prints ":<old mode> <new mode> <old sha> <new sha> <status>" and the
# path as separate NUL-terminated fields, so no path is ever quoted or split.
git -C "$lane" diff --raw -z --no-renames --no-ext-diff --no-textconv \
  "$from" "$to" > "$tmp/raw" || fail "git error reading the diff"

while IFS= read -r -d '' meta; do
  IFS= read -r -d '' path || fail "git output ended inside a record"
  read -r old_mode new_mode _ <<< "${meta#:}"
  for mode in "$old_mode" "$new_mode"; do
    case "$mode" in
      000000 | 100644 ) ;;
      * ) fail "mode $mode on $path" ;;
    esac
  done
  case "$path" in
    .claude/* | */.claude/* | .codex/* | */.codex/* | .agents/* | */.agents/* \
      | scripts/* | */scripts/* | .github/* | */.github/* )
      fail "behavior path never carries: $path" ;;
    ?*.md ) ;;
    * ) fail "not a Markdown file: $path" ;;
  esac
done < "$tmp/raw"

echo "CARRY PASSES"
