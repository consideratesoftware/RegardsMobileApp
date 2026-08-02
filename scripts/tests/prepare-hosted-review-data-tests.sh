#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
preparer="$repo_root/scripts/prepare-hosted-review-data.sh"
fixture_root="$(mktemp -d)"
fixture_repo="$fixture_root/repo"
safe_tree="$fixture_root/safe"
policy_dir="$fixture_root/policy"

git init -q "$fixture_repo"
git -C "$fixture_repo" config user.email test@example.com
git -C "$fixture_repo" config user.name 'Review gate test'
mkdir -p "$fixture_repo/Sources" \
  "$fixture_repo/.claude/skills/unsafe" \
  "$fixture_repo/ios"
printf 'let value = 1\n' > "$fixture_repo/Sources/Value.swift"
printf 'untrusted skill\n' \
  > "$fixture_repo/.claude/skills/unsafe/SKILL.md"
printf 'untrusted Codex policy\n' > "$fixture_repo/AGENTS.md"
printf 'untrusted nested Codex policy\n' > "$fixture_repo/ios/AGENTS.md"
printf 'untrusted nested policy\n' > "$fixture_repo/ios/CLAUDE.md"
git -C "$fixture_repo" add .
git -C "$fixture_repo" commit -qm 'add fixture files'
fixture_head="$(git -C "$fixture_repo" rev-parse HEAD)"

"$preparer" "$fixture_repo" "$fixture_head" "$safe_tree" "$policy_dir" \
  >/dev/null
test -f "$safe_tree/Sources/Value.swift"
test ! -e "$safe_tree/.claude"
test ! -e "$safe_tree/AGENTS.md"
test ! -e "$safe_tree/ios/AGENTS.md"
test ! -e "$safe_tree/ios/CLAUDE.md"
grep -q $'^.claude/skills/unsafe/SKILL.md\t' "$policy_dir/manifest.tsv"
grep -q $'^AGENTS.md\t' "$policy_dir/manifest.tsv"
grep -q $'^ios/AGENTS.md\t' "$policy_dir/manifest.tsv"
grep -q $'^ios/CLAUDE.md\t' "$policy_dir/manifest.tsv"
test "$(find "$safe_tree" -type l | wc -l | tr -d ' ')" -eq 0
echo 'PASS: neutralizes policy files and materializes regular review data'

ln -s Sources/Value.swift "$fixture_repo/value-link"
git -C "$fixture_repo" add value-link
git -C "$fixture_repo" commit -qm 'add unsafe symlink'
set +e
"$preparer" \
  "$fixture_repo" "$(git -C "$fixture_repo" rev-parse HEAD)" \
  "$fixture_root/safe-with-link" "$fixture_root/policy-with-link" \
  >/dev/null 2>&1
symlink_status=$?
set -e
test "$symlink_status" -ne 0
echo 'PASS: rejects symlinks from review data'

git -C "$fixture_repo" rm -q value-link
git -C "$fixture_repo" commit -qm 'remove unsafe symlink'
submodule_repo="$fixture_root/submodule"
git init -q "$submodule_repo"
git -C "$submodule_repo" config user.email test@example.com
git -C "$submodule_repo" config user.name 'Review gate test'
printf 'submodule\n' > "$submodule_repo/README.md"
git -C "$submodule_repo" add README.md
git -C "$submodule_repo" commit -qm 'add submodule fixture'
git -c protocol.file.allow=always -C "$fixture_repo" submodule add -q \
  "$submodule_repo" Vendor/Child
git -C "$fixture_repo" commit -qam 'add unsafe submodule'
set +e
"$preparer" \
  "$fixture_repo" "$(git -C "$fixture_repo" rev-parse HEAD)" \
  "$fixture_root/safe-with-submodule" "$fixture_root/policy-with-submodule" \
  >/dev/null 2>&1
submodule_status=$?
set -e
test "$submodule_status" -ne 0
echo 'PASS: rejects submodules from review data'

rm -R "$fixture_root"
