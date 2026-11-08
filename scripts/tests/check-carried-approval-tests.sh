#!/usr/bin/env bash
# Fixture tests for scripts/check-carried-approval.sh. Each case builds a
# change on top of a base commit in a throwaway repository and checks the
# script's exit status and its output text: exit 0 with the output
# CARRY PASSES means the carry is allowed, and exit 1 with an output starting
# "CARRY FAILS: " means it fails. The usage case checks exit 64 only.
#
# CARRY_CHECKER=<path> runs the cases against another copy of the script, for
# mutation checks (remove one rule, confirm the matching case then fails).
#
# Fixture layout. The script allows only the doc roots (the repository root,
# ios/, android/, ios/docs/, android/docs/), so every case that tests one
# exclusion puts its path under ios/docs/, where the allowlist alone would
# pass it. The 4 android exclusion cases (android_docs_src_md,
# android_docs_schemas_md and their nested twins, android_docs_nested_src_md
# and android_docs_nested_schemas_md) use android/docs/ for the same reason,
# because their exclusions match only android paths. The 4 root
# instruction-file cases (root_claude_local_md,
# root_architecture_md, root_agents_md, root_claude_md) are the exception:
# they sit at the root, which the allowlist also passes, so they too fail only
# on their exclusion. Deleting one pattern from the script's exclusion list
# breaks its own case. Five patterns also break another case (checked by
# deleting each pattern in turn): `*/.claude/*` breaks upper_claude_dir too,
# `CLAUDE*.md` breaks root_claude_local_md too, `*/AGENTS*.md` breaks
# nested_agents_override_md and lower_case_agents_override_md too,
# `android/*/src/*` breaks android_docs_nested_src_md too, and
# `android/*/schemas/*` breaks android_docs_nested_schemas_md too. The script
# has no exclusion for a behavior folder at the root, so the cases there
# (.claude/x.md and the like) fail on the allowlist alone and check the
# outcome.

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
lane="$repo" # the path handed to the checker; a case may point it at a subdirectory
git init -q -b main "$repo"
git -C "$repo" config core.fileMode true

put() { # put <path> <content>
  mkdir -p "$repo/$(dirname "$1")"
  printf '%s\n' "$2" > "$repo/$1"
}

put ios/docs/guide.md '# Guide'
put ios/docs/old.md '# Old'
put ios/docs/gone.md '# Gone'
put ios/docs/run.md '# Executable doc'
chmod +x "$repo/ios/docs/run.md"
put 'ios/docs/Café.md' '# Café'
put TESTFLIGHT_PLAN.md '# Plan'
put .agents/README.md '# Agents'
put .codex/skills/s/SKILL.md '# Skill'
put .claude/agents/x.md '# Agent'
put scripts/x.md '# Script doc'
put AGENTS.md '# Agents file'
put CLAUDE.md '# Claude file'
put ARCHITECTURE.md '# Architecture'
put ios/docs/AGENTS.md '# Nested agents file'
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
put scripts/run.sh '#!/usr/bin/env bash
echo run'
git -C "$repo" add -A
git -C "$repo" commit -q -m base
base="$(git -C "$repo" rev-parse HEAD)"

# check <name> <expected status> <from sha> <head sha>
check() {
  local name="$1"
  local expected="$2"
  local output status

  set +e
  output="$(bash "$checker" "$lane" "$3" "$4" 2>&1)"
  status=$?
  set -e
  lane="$repo"
  git -C "$repo" config --unset diff.ignoreSubmodules 2>/dev/null || true
  git -C "$repo" config --unset diff.relative 2>/dev/null || true
  if [[ "$status" -ne "$expected" ]]; then
    echo "FAIL: $name (expected $expected, got $status): $output" >&2
    exit 1
  fi
  # release-manager.md passes a carry only on exit 0 with the output exactly
  # CARRY PASSES, and a failure prints CARRY FAILS: <reason>. The output holds
  # stderr too, so a stray warning on a pass fails the case.
  if [[ "$expected" -eq 0 && "$output" != "CARRY PASSES" ]]; then
    echo "FAIL: $name (expected the output CARRY PASSES, got: $output)" >&2
    exit 1
  fi
  if [[ "$expected" -eq 1 && "$output" != "CARRY FAILS: "* ]]; then
    echo "FAIL: $name (expected the output to start with \"CARRY FAILS: \", got: $output)" >&2
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

md_change() { put ios/docs/guide.md '# Guide, reworded'; }
md_added() { put ios/docs/new.md '# New'; }
md_deleted() { git -C "$repo" rm -q ios/docs/gone.md; }
md_moved() { git -C "$repo" mv ios/docs/old.md ios/docs/new-name.md; }
md_non_ascii() { put 'ios/docs/Café.md' '# Café, reworded'; }
no_change() { :; }
md_mode() { chmod +x "$repo/ios/docs/guide.md"; }
agents_md() { put .agents/README.md '# Agents, changed'; }
codex_md() { put .codex/skills/s/SKILL.md '# Skill, changed'; }
claude_md() { put .claude/agents/x.md '# Agent, changed'; }
scripts_md() { put scripts/x.md '# Script doc, changed'; }
github_md() { put .github/x.md '# Github doc, changed'; }
nested_claude_md() { put ios/docs/.claude/n.md '# Nested'; }
nested_codex_md() { put ios/docs/.codex/n.md '# Nested'; }
nested_agents_dir_md() { put ios/docs/.agents/n.md '# Nested'; }
nested_scripts_md() { put ios/docs/scripts/n.md '# Nested'; }
nested_github_md() { put ios/docs/.github/n.md '# Nested'; }
md_symlink() { ln -s ../Info.plist "$repo/ios/docs/link.md"; }
executable_md_deleted() { git -C "$repo" rm -q ios/docs/run.md; }
gitlink_on_md_path() {
  git -C "$repo" update-index --add --cacheinfo "160000,$base,ios/docs/sub.md"
}
upper_case_md_suffix() { put ios/docs/Note.MD '# Note'; }
root_md_tail() { put Package.md.swift 'let x = 1'; }
docs_mdx() { put ios/docs/x.mdx '# x'; }
docs_md_dir_file() { put ios/docs/x.md/payload.swift 'let x = 1'; }
docs_md_sh() { put ios/docs/x.md.sh 'echo x'; }
docs_notes_md() { put ios/docs/notes_md '# x'; }
docs_cmd() { put ios/docs/x.cmd 'echo x'; }
docs_png() { put ios/docs/diagram.png 'x'; }
ios_md_dir_file() { put ios/Regards.md/App.swift 'let x = 1'; }
root_claude_local_md() { put CLAUDE.local.md '# Local claude file'; }
nested_agents_override_md() { put ios/docs/AGENTS.override.md '# Agents override'; }
root_architecture_md() { put ARCHITECTURE.md '# Architecture, changed'; }
lower_case_architecture_md() { put ios/docs/architecture.md '# Architecture notes'; }
lower_case_agents_override_md() { put ios/docs/agents.override.md '# Agents override notes'; }
android_docs_src_md() { put android/docs/src/x.md '# Read as data'; }
android_docs_schemas_md() { put android/docs/schemas/x.md '# Read as data'; }
android_docs_nested_src_md() { put android/docs/guide/src/x.md '# Read as data'; }
android_docs_nested_schemas_md() { put android/docs/guide/schemas/x.md '# Read as data'; }
android_app_notes_md() { put android/app/notes.md '# Notes'; }
ios_bundle_md() { put ios/Regards/Resources/x.md '# Resource'; }
android_app_md() { put android/app/src/main/x.md '# Resource'; }
android_module_asset_md() { put android/feature/overdue/src/main/assets/x.md '# Asset'; }
android_schemas_md() { put android/data/schemas/x.md '# Schema notes'; }
shared_testvectors_md() { put shared/testvectors/x.md '# Vector notes'; }
android_docs_md() { put android/docs/notes.md '# Android notes'; }
ios_docs_md() { put ios/docs/x.md '# Doc'; }
ios_docs_deep_md() { put ios/docs/sub/dir/x.md '# Deep doc'; }
ios_readme_md() { put ios/README.md '# iOS'; }
root_plan_md() { put TESTFLIGHT_PLAN.md '# Plan, changed'; }
nested_claude_instruction_md() { put ios/docs/CLAUDE.md '# Nested claude file'; }
root_docs_folder_md() { put docs/x.md '# A new root folder'; }
ios_test_data_md() { put ios/TestData/x.md '# Test data'; }
tools_notes_md() { put tools/notes.md '# Notes'; }
upper_case_ios_docs_md() {
  git -C "$repo" update-index --add --cacheinfo \
    "100644,$(git -C "$repo" rev-parse "$base:ios/docs/guide.md"),IOS/docs/x.md"
}
android_readme_md() { put android/README.md '# Android'; }
root_agents_md() { put AGENTS.md '# Agents file, changed'; }
root_claude_md() { put CLAUDE.md '# Claude file, changed'; }
nested_agents_md() { put ios/docs/AGENTS.md '# Nested agents file, changed'; }
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
plist_to_md() { git -C "$repo" mv ios/Info.plist ios/docs/Info.md; }
md_plus_plist() { put ios/docs/guide.md '# Guide, again'; put ios/Info.plist '<plist>y</plist>'; }
upper_claude_dir() {
  git -C "$repo" update-index --add --cacheinfo \
    "100644,$(git -C "$repo" rev-parse "$base:.claude/agents/x.md"),ios/docs/.CLAUDE/n.md"
}
gitlink_ignored_by_diff_config() {
  git -C "$repo" config diff.ignoreSubmodules all
  git -C "$repo" update-index --add --cacheinfo "160000,$base,vendor/lib"
}
script_change_outside_relative_lane() {
  git -C "$repo" config diff.relative true
  lane="$repo/ios/docs"
  put scripts/run.sh '#!/usr/bin/env bash
echo changed'
}

expect 'an ios/docs .md change passes' 0 md_change
expect 'an added ios/docs .md passes' 0 md_added
expect 'a deleted ios/docs .md passes' 0 md_deleted
expect 'an .md move inside ios/docs passes' 0 md_moved
expect 'a non-ASCII-named ios/docs .md change passes' 0 md_non_ascii
expect 'an empty change passes' 0 no_change
expect 'an .md mode change fails' 1 md_mode
expect 'an .agents/ .md change fails' 1 agents_md
expect 'a .codex/ .md change fails' 1 codex_md
expect 'a .claude/ .md change fails' 1 claude_md
expect 'a scripts/ .md change fails' 1 scripts_md
expect 'a .github/ .md change fails' 1 github_md
expect 'a nested ios/docs/.claude/ .md add fails' 1 nested_claude_md
expect 'a nested ios/docs/.codex/ .md add fails' 1 nested_codex_md
expect 'a nested ios/docs/.agents/ .md add fails' 1 nested_agents_dir_md
expect 'a nested ios/docs/scripts/ .md add fails' 1 nested_scripts_md
expect 'a nested ios/docs/.github/ .md add fails' 1 nested_github_md
expect 'an ios/docs/link.md symlink to ios/Info.plist fails' 1 md_symlink
expect 'a deleted executable ios/docs/run.md fails' 1 executable_md_deleted
expect_index 'a gitlink added on a .md path fails' 1 gitlink_on_md_path
expect 'an added ios/docs/Note.MD (upper-case suffix) fails' 1 upper_case_md_suffix
expect 'an added root Package.md.swift fails' 1 root_md_tail
expect 'an added ios/docs/x.mdx fails' 1 docs_mdx
expect 'an added ios/docs/x.md/payload.swift fails' 1 docs_md_dir_file
expect 'an added ios/docs/x.md.sh fails' 1 docs_md_sh
expect 'an added ios/docs/notes_md (no dot before md) fails' 1 docs_notes_md
expect 'an added ios/docs/x.cmd (ends in md, no dot) fails' 1 docs_cmd
expect 'an added ios/docs/diagram.png (non-Markdown in a doc root) fails' 1 docs_png
expect 'an added ios/Regards.md/App.swift fails' 1 ios_md_dir_file
expect 'a root AGENTS.md change fails' 1 root_agents_md
expect 'a root CLAUDE.md change fails' 1 root_claude_md
expect 'a root ARCHITECTURE.md change fails' 1 root_architecture_md
expect 'an added lower-case ios/docs/architecture.md fails' 1 lower_case_architecture_md
expect 'an added lower-case ios/docs/agents.override.md fails' 1 lower_case_agents_override_md
expect 'an added android/docs/src/x.md fails' 1 android_docs_src_md
expect 'an added android/docs/schemas/x.md fails' 1 android_docs_schemas_md
expect 'an added android/docs/guide/src/x.md (src below another folder) fails' 1 android_docs_nested_src_md
expect 'an added android/docs/guide/schemas/x.md (schemas below another folder) fails' 1 android_docs_nested_schemas_md
expect 'an added android/app/notes.md (a folder below android/) fails' 1 android_app_notes_md
expect 'an added ios/Regards/Resources/x.md fails' 1 ios_bundle_md
expect 'an added android/app/src/main/x.md fails' 1 android_app_md
expect 'an added android/feature/overdue/src/main/assets/x.md fails' 1 android_module_asset_md
expect 'an added android/data/schemas/x.md fails' 1 android_schemas_md
expect 'an added shared/testvectors/x.md fails' 1 shared_testvectors_md
expect 'an added android/docs/notes.md passes' 0 android_docs_md
expect 'an added android/README.md passes' 0 android_readme_md
expect 'an added ios/docs/x.md passes' 0 ios_docs_md
expect 'an added ios/docs/sub/dir/x.md passes' 0 ios_docs_deep_md
expect 'an added ios/README.md passes' 0 ios_readme_md
expect 'a root TESTFLIGHT_PLAN.md change passes' 0 root_plan_md
expect 'an added ios/docs/CLAUDE.md fails' 1 nested_claude_instruction_md
expect 'an added docs/x.md (a new root folder) fails' 1 root_docs_folder_md
expect 'an added ios/TestData/x.md fails' 1 ios_test_data_md
expect 'an added tools/notes.md fails' 1 tools_notes_md
expect_index 'an added IOS/docs/x.md (upper-case ios) fails' 1 upper_case_ios_docs_md
expect 'a nested ios/docs/AGENTS.md change fails' 1 nested_agents_md
expect 'an added root CLAUDE.local.md fails' 1 root_claude_local_md
expect 'an added ios/docs/AGENTS.override.md fails' 1 nested_agents_override_md
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
expect 'a scripts/run.sh change fails under diff.relative with the lane in ios/docs/' 1 script_change_outside_relative_lane
expect_index 'an upper-case ios/docs/.CLAUDE/ .md add fails' 1 upper_claude_dir
expect_index 'a gitlink add fails with diff.ignoreSubmodules=all in config (plumbing ignores it)' 1 gitlink_ignored_by_diff_config

# Two sibling commits that each change only an ios/docs .md file: the diff between
# them is Markdown-only, so only the ancestor check can reject the carry.
git -C "$repo" checkout -q -B sibling-a "$base"
put ios/docs/guide.md '# Guide, sibling a'
git -C "$repo" commit -q -am sibling-a
sibling_a="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -q -B sibling-b "$base"
put ios/docs/guide.md '# Guide, sibling b'
git -C "$repo" commit -q -am sibling-b
sibling_b="$(git -C "$repo" rev-parse HEAD)"

# A merge: the carried commit is docs-only, then a .swift change from main is
# merged in. The net change from the carried commit to the merge includes it.
git -C "$repo" checkout -q -B merge-main "$base"
put ios/Regards/App/A.swift '// note
let x = 4'
git -C "$repo" commit -q -am main-swift
git -C "$repo" checkout -q -B merge-lane "$base"
put ios/docs/guide.md '# Guide, carried'
git -C "$repo" commit -q -am carried
carried="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" merge -q --no-edit merge-main
check 'a merge that brings a .swift change from main fails' 1 \
  "$carried" "$(git -C "$repo" rev-parse HEAD)"

# A gitlink bump on a submodule that .gitmodules marks "ignore = all". Plain
# diff-tree hides the bump; --ignore-submodules=none shows it. Built by hand
# because the carried commit must already hold .gitmodules and the gitlink.
git -C "$repo" checkout -q -B submodule-lane "$base"
printf '[submodule "vendor/lib"]\n\tpath = vendor/lib\n\turl = ../lib\n\tignore = all\n' \
  > "$repo/.gitmodules"
git -C "$repo" add .gitmodules
git -C "$repo" update-index --add --cacheinfo "160000,$base,vendor/lib"
git -C "$repo" commit -q -m submodule-from
submodule_from="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" update-index --cacheinfo "160000,$submodule_from,vendor/lib"
git -C "$repo" commit -q -m submodule-bump
check 'a gitlink bump fails when .gitmodules says ignore = all' 1 \
  "$submodule_from" "$(git -C "$repo" rev-parse HEAD)"

# A mktemp that always fails, put first on PATH.
mkdir "$work/bin"
printf '#!/bin/sh\nexit 1\n' > "$work/bin/mktemp"
chmod +x "$work/bin/mktemp"

set +e
no_tmp_output="$(PATH="$work/bin:$PATH" bash "$checker" "$repo" "$base" "$base" 2>&1)"
no_tmp=$?
backwards_output="$(bash "$checker" "$repo" "$sibling_a" "$sibling_b" 2>&1)"
backwards=$?
# git writes "fatal: Not a valid object name" to stderr ahead of the CARRY
# FAILS line, so this case reads stdout only.
bad_sha_output="$(bash "$checker" "$repo" deadbeef "$base" 2>/dev/null)"
bad_sha=$?
bash "$checker" > /dev/null 2>&1
usage=$?
set -e
[[ "$backwards" -eq 1 && "$backwards_output" == CARRY\ FAILS:* ]] \
  || { echo "FAIL: a non-ancestor carry should print CARRY FAILS and exit 1, got $backwards: $backwards_output" >&2; exit 1; }
echo 'PASS: a non-ancestor sha fails'
[[ "$no_tmp" -eq 1 && "$no_tmp_output" == CARRY\ FAILS:* ]] \
  || { echo "FAIL: a failed mktemp should print CARRY FAILS and exit 1, got $no_tmp: $no_tmp_output" >&2; exit 1; }
echo 'PASS: a failed mktemp prints CARRY FAILS'
[[ "$bad_sha" -eq 1 && "$bad_sha_output" == CARRY\ FAILS:* ]] \
  || { echo "FAIL: an unknown sha should print CARRY FAILS and exit 1, got $bad_sha: $bad_sha_output" >&2; exit 1; }
echo 'PASS: an unknown sha fails'
[[ "$usage" -eq 64 ]] || { echo "FAIL: usage error should exit 64, got $usage" >&2; exit 1; }
echo 'PASS: usage error exits 64'
