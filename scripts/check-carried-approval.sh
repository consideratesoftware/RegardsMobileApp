#!/usr/bin/env bash
# Decides whether a reviewer's earlier approval may carry to a newer head.
#
#   scripts/check-carried-approval.sh <lane worktree> <carried sha> <head sha>
#
# Exit 0 prints "CARRY PASSES". Any other exit prints "CARRY FAILS: <reason>".
# Run it with bash, never the agent's default shell: the loop below depends on
# bash semantics (zsh does not word-split an unquoted variable).
#
# An approval carries only when every commit between the two shas changes docs
# or comments and nothing else:
#   - *.md files outside .claude/, .codex/, .agents/, scripts/ and .github/
#     (agent contracts, commands, skills, scripts and CI are behavior, so a
#     change there never carries);
#   - *.swift, *.yml, *.sh and *.py files outside those directories, when
#     every changed line is a comment or blank. A shebang, line 1 of a .sh
#     file, and a Swift comment holding a `swiftlint:` directive count as
#     code, as do mode changes and added, deleted or renamed files;
#   - nothing else: .toml (its # lines are prompt headings), project.yml,
#     ios/Regards.xcodeproj, plists, json and so on never carry.
# Renames are never detected (--no-renames), so a move shows up as a delete
# plus an add; an added or deleted .md file is still docs. Any git or awk error
# fails the carry.

set -euo pipefail

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

git -C "$lane" diff --no-renames --name-only -z "$from" "$to" > "$tmp/names" \
  || fail "git error listing files"

count=0
while IFS= read -r -d '' path; do
  count=$((count + 1))
  case "$path" in
    project.yml | */project.yml | ios/Regards.xcodeproj/* )
      fail "project file: $path" ;;
    .claude/* | .codex/* | .agents/* | scripts/* | .github/* )
      fail "behavior path never carries: $path" ;;
    *.md | *.swift | *.yml | *.sh | *.py )
      ;;
    * )
      fail "path outside the allowlist: $path" ;;
  esac
done < "$tmp/names"

if [[ "$count" -eq 0 ]]; then
  echo "CARRY PASSES"
  exit 0
fi

git -C "$lane" diff --no-renames --unified=0 --no-color "$from" "$to" \
  > "$tmp/diff" || fail "git error reading the diff"

awk '
  /^diff --git / {
    hdr = 1
    file = $NF
    sub(/^b\//, "", file)
    next
  }
  hdr && /^(old mode|new mode|rename |similarity |Binary files)/ {
    print "mode, rename or binary change: " file
    next
  }
  hdr && /^(new file mode|deleted file mode)/ {
    if (file !~ /\.md$/) print "added or deleted file: " file
    next
  }
  /^@@ / {
    hdr = 0
    if (file ~ /\.sh$/ && ($0 ~ /^@@ -1( |,[1-9])/ || $0 ~ /^@@ -0,0 / || $0 ~ / \+1( |,[1-9])/)) {
      print "line 1 of " file
    }
    next
  }
  hdr { next }
  /^[+-]/ {
    if (file ~ /\.md$/) next
    body = substr($0, 2)
    if (body ~ /^[[:space:]]*$/) next
    if (file ~ /\.swift$/) {
      if (body ~ /^[[:space:]]*\/\// && body !~ /swiftlint:/) next
    } else if (body ~ /^#!/) {
      print "shebang in " file ": " $0
      next
    } else if (body ~ /^[[:space:]]*#/) {
      next
    }
    print file ": " $0
  }
' "$tmp/diff" > "$tmp/bad" || fail "awk error reading the diff"

if [[ -s "$tmp/bad" ]]; then
  fail "non-comment change: $(head -n 3 "$tmp/bad" | tr '\n' ' ')"
fi

echo "CARRY PASSES"
