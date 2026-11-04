#!/usr/bin/env bash
# Decides whether a reviewer's earlier approval may carry to a newer head.
#
#   scripts/check-carried-approval.sh <lane worktree> <carried sha> <head sha>
#
# Run it with bash. Exit codes:
#   0   prints "CARRY PASSES"; the approval carries.
#   1   prints "CARRY FAILS: <reason>"; the reviewer reruns. This includes a
#       failed mktemp, which prints it too.
#   64  usage error (printed to stderr).
#   any other nonzero exit is a script error and fails the carry too.
#
# The rule, applied to the net change between the two shas (not per commit):
# an approval carries only when every changed path is a Markdown file (*.md,
# lower-case suffix; Note.MD is not one) and none of these hold:
#   - the path is under .claude/, .codex/, .agents/, scripts/ or .github/,
#     nested copies included;
#   - the path is named AGENTS*.md or CLAUDE*.md at any depth
#     (AGENTS.override.md, CLAUDE.local.md);
#   - the path is named ARCHITECTURE.md (pr-tests maps its section 14 rows
#     from it, so an edit there changes what the tests must prove);
#   - the path is under ios/Regards*/ or android/app/ (the bundled trees);
#   - the entry has a mode change (only 100644, or add/delete, is allowed).
# An added or deleted .md file is docs. Agent contracts, commands, skills,
# scripts, CI and the instruction files are behavior, so a change there never
# carries. Every other path fails: source, config, project files, plists,
# toml, anything. Renames are never detected, so a move is a delete plus an
# add.
#
# Why Markdown alone is safe: the app and its tests read files only from the
# bundled trees, and those trees are excluded as a whole, so a Markdown file
# added there (a future resource, say) never carries. Elsewhere a Markdown
# file is documentation, except the instruction files and ARCHITECTURE.md
# named above, which agents read as instructions or as the contract.

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

tmp="$(mktemp -d)" || fail "cannot create a temp directory"
trap 'rm -rf "$tmp"' EXIT

git -C "$lane" merge-base --is-ancestor "$from" "$to" \
  || fail "not an ancestor, or a git error"

# diff-tree is plumbing, so the diff.* settings (ignoreSubmodules, relative,
# external, textconv) do not apply to it. It still reads submodule.<name>.ignore
# from .gitmodules, so --ignore-submodules=none overrides that and a gitlink
# change always shows. -r recurses into directories and -z prints
# ":<old mode> <new mode> <old sha> <new sha> <status>" and the path as
# separate NUL-terminated fields, so no path is ever quoted or split.
git -C "$lane" diff-tree -r -z --no-renames --ignore-submodules=none \
  "$from" "$to" > "$tmp/raw" \
  || fail "git error reading the diff"

while IFS= read -r -d '' meta; do
  IFS= read -r -d '' path || fail "git output ended inside a record"
  read -r old_mode new_mode _ <<< "${meta#:}"
  for mode in "$old_mode" "$new_mode"; do
    case "$mode" in
      000000 | 100644 ) ;;
      * ) fail "mode $mode on $path" ;;
    esac
  done
  # Directory and agent-file names match in any case: a case-insensitive
  # checkout (macOS) treats .CLAUDE/ and .claude/ as the same directory. The
  # .md suffix below is case-sensitive, so Note.MD is not a Markdown file.
  shopt -s nocasematch
  case "$path" in
    .claude/* | */.claude/* | .codex/* | */.codex/* | .agents/* | */.agents/* \
      | scripts/* | */scripts/* | .github/* | */.github/* )
      fail "behavior path never carries: $path" ;;
    AGENTS*.md | */AGENTS*.md | CLAUDE*.md | */CLAUDE*.md )
      fail "agent instruction file never carries: $path" ;;
    ARCHITECTURE.md | */ARCHITECTURE.md )
      fail "ARCHITECTURE.md never carries: $path" ;;
    ios/Regards*/* | android/app/* )
      fail "bundled tree never carries: $path" ;;
  esac
  shopt -u nocasematch
  case "$path" in
    ?*.md ) ;;
    * ) fail "not a Markdown file: $path" ;;
  esac
done < "$tmp/raw"

echo "CARRY PASSES"
