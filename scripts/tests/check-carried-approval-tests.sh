#!/usr/bin/env bash
# Fixture tests for scripts/check-carried-approval.sh. Each case builds a
# change on top of a base commit in a throwaway repository and checks the
# script's exit status: 0 = the carry is allowed, 1 = it fails.
#
# CARRY_CHECKER=<path> runs the cases against another copy of the script, for
# mutation checks (remove one rule, confirm the matching case then fails).

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
checker="${CARRY_CHECKER:-$repo_root/scripts/check-carried-approval.sh}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

repo="$work/repo"
git init -q -b main "$repo"
git -C "$repo" config core.fileMode true

put() { # put <path> <content>
  mkdir -p "$repo/$(dirname "$1")"
  printf '%s\n' "$2" > "$repo/$1"
}

put docs/guide.md '# Guide'
put docs/old.md '# Old'
put docs/gone.md '# Gone'
put 'docs/Café.md' '# Café'
put .agents/README.md '# Agents'
put .codex/skills/s/SKILL.md '# Skill'
put .claude/agents/x.md '# Agent'
put scripts/x.md '# Script doc'
put .github/x.md '# Github doc'
put ios/Regards/App/A.swift '// note
let x = 1'
put 'ios/Café.swift' 'let y = 1'
put tools/run.sh '#!/usr/bin/env bash
echo hi'
put tools/t.py 'print(1)'
put tools/config.yml 'key: value'
put .codex/agents/y.toml 'name = "y"'
put ios/Info.plist '<plist></plist>'
put project.yml 'name: Regards'
# The attribute lives in the base commit, so the external-diff case below
# changes nothing but a .swift file.
put .gitattributes '*.swift diff=hidden'
git -C "$repo" add -A
git -C "$repo" commit -q -m base
base="$(git -C "$repo" rev-parse HEAD)"

# check <name> <expected status> <from sha> <head sha>
check() {
  local name="$1"
  local expected="$2"
  local output status

  set +e
  output="$(bash "$checker" "$repo" "$3" "$4" 2>&1)"
  status=$?
  set -e
  git -C "$repo" config --unset diff.external 2>/dev/null || true
  git -C "$repo" config --unset diff.hidden.textconv 2>/dev/null || true
  if [[ "$status" -ne "$expected" ]]; then
    echo "FAIL: $name (expected $expected, got $status): $output" >&2
    exit 1
  fi
  echo "PASS: $name"
}

# expect <name> <expected status> <mutation function>
# Commits the working-tree change the function makes on top of the base commit.
expect() {
  git -C "$repo" checkout -q -B case "$base"
  "$3"
  git -C "$repo" add -A
  git -C "$repo" commit -q --allow-empty -m "$1"
  check "$1" "$2" "$base" "$(git -C "$repo" rev-parse HEAD)"
}

# expect_index <name> <expected status> <index function>
# Builds the commit from a scratch index with git update-index, never touching
# the working tree. Needed for paths a case-insensitive checkout would fold
# into an existing one, and for gitlinks.
expect_index() {
  local tree head

  export GIT_INDEX_FILE="$work/scratch-index"
  rm -f "$GIT_INDEX_FILE"
  git -C "$repo" read-tree "$base"
  "$3"
  tree="$(git -C "$repo" write-tree)"
  head="$(git -C "$repo" commit-tree "$tree" -p "$base" -m "$1")"
  unset GIT_INDEX_FILE
  check "$1" "$2" "$base" "$head"
}

md_change() { put docs/guide.md '# Guide, reworded'; }
md_added() { put docs/new.md '# New'; }
md_deleted() { git -C "$repo" rm -q docs/gone.md; }
md_moved() { git -C "$repo" mv docs/old.md docs/new-name.md; }
md_non_ascii() { put 'docs/Café.md' '# Café, reworded'; }
no_change() { :; }
md_mode() { chmod +x "$repo/docs/guide.md"; }
agents_md() { put .agents/README.md '# Agents, changed'; }
codex_md() { put .codex/skills/s/SKILL.md '# Skill, changed'; }
claude_md() { put .claude/agents/x.md '# Agent, changed'; }
scripts_md() { put scripts/x.md '# Script doc, changed'; }
github_md() { put .github/x.md '# Github doc, changed'; }
swift_comment() { put ios/Regards/App/A.swift '// note, reworded
let x = 1'; }
swift_code() { put ios/Regards/App/A.swift '// note
let x = 2'; }
swift_non_ascii() { put 'ios/Café.swift' 'let y = 2'; }
sh_comment() { put tools/run.sh '#!/usr/bin/env bash
# new comment
echo hi'; }
py_change() { put tools/t.py 'print(2)'; }
yml_comment() { put tools/config.yml '# note
key: value'; }
toml_change() { put .codex/agents/y.toml 'name = "z"'; }
plist_change() { put ios/Info.plist '<plist>x</plist>'; }
project_yml() { put project.yml 'name: Other'; }
plist_to_md() { git -C "$repo" mv ios/Info.plist docs/Info.md; }
md_plus_plist() { put docs/guide.md '# Guide, again'; put ios/Info.plist '<plist>y</plist>'; }
upper_claude_dir() {
  git -C "$repo" update-index --add --cacheinfo \
    "100644,$(git -C "$repo" rev-parse "$base:.claude/agents/x.md"),.CLAUDE/agents/x.md"
}
swift_with_external_diff() {
  git -C "$repo" config diff.external true
  git -C "$repo" config diff.hidden.textconv true
  put ios/Regards/App/A.swift '// note
let x = 3'
}

expect 'a docs .md change passes' 0 md_change
expect 'an added docs .md passes' 0 md_added
expect 'a deleted docs .md passes' 0 md_deleted
expect 'an .md move passes' 0 md_moved
expect 'a non-ASCII-named .md change passes' 0 md_non_ascii
expect 'an empty change passes' 0 no_change
expect 'an .md mode change fails' 1 md_mode
expect 'an .agents/ .md change fails' 1 agents_md
expect 'a .codex/ .md change fails' 1 codex_md
expect 'a .claude/ .md change fails' 1 claude_md
expect 'a scripts/ .md change fails' 1 scripts_md
expect 'a .github/ .md change fails' 1 github_md
expect 'a Swift comment-only change fails' 1 swift_comment
expect 'a Swift code change fails' 1 swift_code
expect 'a non-ASCII-named .swift change fails' 1 swift_non_ascii
expect 'a .sh comment change fails' 1 sh_comment
expect 'a .py change fails' 1 py_change
expect 'a .yml comment change fails' 1 yml_comment
expect 'a .toml change fails' 1 toml_change
expect 'a .plist change fails' 1 plist_change
expect 'a project.yml change fails' 1 project_yml
expect 'a rename from .plist to .md fails' 1 plist_to_md
expect 'an .md change plus a .plist change fails' 1 md_plus_plist
expect 'a Swift change still fails with diff.external and textconv set' 1 swift_with_external_diff
expect_index 'an upper-case .CLAUDE/ .md add fails' 1 upper_claude_dir

# Two sibling commits that each change only a docs .md file: the diff between
# them is Markdown-only, so only the ancestor check can reject the carry.
git -C "$repo" checkout -q -B sibling-a "$base"
put docs/guide.md '# Guide, sibling a'
git -C "$repo" commit -q -am sibling-a
sibling_a="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -q -B sibling-b "$base"
put docs/guide.md '# Guide, sibling b'
git -C "$repo" commit -q -am sibling-b
sibling_b="$(git -C "$repo" rev-parse HEAD)"

set +e
bash "$checker" "$repo" "$sibling_a" "$sibling_b" > /dev/null 2>&1
backwards=$?
bash "$checker" "$repo" deadbeef "$base" > /dev/null 2>&1
bad_sha=$?
bash "$checker" > /dev/null 2>&1
usage=$?
set -e
[[ "$backwards" -eq 1 ]] || { echo "FAIL: a non-ancestor carry should fail, got $backwards" >&2; exit 1; }
echo 'PASS: a non-ancestor sha fails'
[[ "$bad_sha" -eq 1 ]] || { echo "FAIL: an unknown sha should fail, got $bad_sha" >&2; exit 1; }
echo 'PASS: an unknown sha fails'
[[ "$usage" -eq 64 ]] || { echo "FAIL: usage error should exit 64, got $usage" >&2; exit 1; }
echo 'PASS: usage error exits 64'
