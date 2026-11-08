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
# an approval carries only when every changed path is a Markdown file with a
# lower-case .md suffix (Note.MD is not one) at the repository root, directly
# under ios/ or android/, or anywhere under ios/docs/ or android/docs/ (the
# doc roots, matched case-sensitively), and none of these hold (the exclusions
# match in any letter case):
#   - the path is inside a .claude/, .codex/, .agents/, scripts/ or .github/
#     folder below the repository root (ios/docs/scripts/x.md). Paths that
#     start with one of these folders (scripts/x.md) are not listed: the
#     allowlist rejects them, as it rejects any root folder but ios/ and
#     android/;
#   - the path is named AGENTS*.md or CLAUDE*.md at any depth
#     (AGENTS.override.md, CLAUDE.local.md);
#   - the path is named ARCHITECTURE.md (pr-tests maps its section 14 rows
#     from it, so an edit there changes what the tests must prove);
#   - the entry has a mode change (only 100644, or add/delete, is allowed).
# An added or deleted .md file is docs. Agent contracts, commands, skills,
# scripts, CI and the instruction files are behavior, so a change there never
# carries. Every other path fails: source, config, project files, plists,
# toml, and Markdown outside the doc roots. Renames are never detected, so a
# move is a delete plus an add.
#
# Why a list of doc roots: the apps and their tests read repository files as
# data from folders such as ios/Regards*/ and android/*/src/.
# shared/testvectors/ has no reader yet, but ANDROID_PORT.md (A6, AN-02) plans
# readers in the 2 test suites that shared/testvectors/README.md names:
# ios/RegardsTests and android/domain/src/test. A Markdown file there would be
# read as data once one lands. Only the doc roots carry, and a new folder fails
# closed until someone adds it here on purpose.

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
  # checkout (macOS) treats .CLAUDE/ and .claude/ as the same directory.
  # The behavior folders are listed only as nested copies (*/scripts/*). A path
  # that starts with one (scripts/x.md) fails the allowlist below.
  # Only this one case block may sit between shopt -s and shopt -u. nocasematch
  # also applies to every other case and [[ =~ ]] test while it is on, and the
  # doc-path test below must stay case-sensitive.
  shopt -s nocasematch
  case "$path" in
    */.claude/* | */.codex/* | */.agents/* | */scripts/* | */.github/* )
      fail "behavior path never carries: $path" ;;
    AGENTS*.md | */AGENTS*.md | CLAUDE*.md | */CLAUDE*.md )
      fail "agent instruction file never carries: $path" ;;
    ARCHITECTURE.md | */ARCHITECTURE.md )
      fail "ARCHITECTURE.md never carries: $path" ;;
  esac
  shopt -u nocasematch
  # The allowlist: a lower-case .md at the root, directly under ios/ or
  # android/, or anywhere under ios/docs/ or android/docs/. Case-sensitive, so
  # Note.MD and IOS/docs/x.md fail.
  [[ "$path" =~ ^([^/]+|ios/[^/]+|android/[^/]+|(ios|android)/docs/.+)\.md$ ]] \
    || fail "not a doc path: $path"
done < "$tmp/raw"

echo "CARRY PASSES"
