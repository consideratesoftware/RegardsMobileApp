#!/usr/bin/env bash
# Fixture tests for scripts/check-carried-approval.sh. Each case builds a
# throwaway repository, commits one change on top of a base commit, and checks
# the script's exit status (0 = carry allowed, 1 = carry fails).

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
checker="$repo_root/scripts/check-carried-approval.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

repo="$work/repo"
git init -q -b main "$repo"
git -C "$repo" config core.fileMode true

mkdir -p "$repo/docs" "$repo/ios/Regards.xcodeproj" "$repo/ios/Regards/App" \
  "$repo/.claude/agents" "$repo/.codex/agents" "$repo/.github/workflows" \
  "$repo/scripts" "$repo/tools"
printf '# Doc\n\ntext\n' > "$repo/docs/guide.md"
printf '<plist></plist>\n' > "$repo/ios/Info.plist"
printf '<plist></plist>\n' > "$repo/ios/My File.plist"
printf 'name: Regards\n' > "$repo/project.yml"
printf '// pbx\n' > "$repo/ios/Regards.xcodeproj/project.pbxproj"
printf -- '---\nname: x\n---\n\n# Heading\n' > "$repo/.claude/agents/x.md"
printf 'developer_instructions = """\n## Checklist\n"""\n' > "$repo/.codex/agents/y.toml"
printf 'name: ci\n' > "$repo/.github/workflows/w.yml"
printf '#!/usr/bin/env bash\n# note\necho hi\n' > "$repo/tools/run.sh"
printf '#!/usr/bin/env bash\necho hi\n' > "$repo/scripts/helper.sh"
printf 'import Foundation\n\n// note\nlet x = 1\n#if DEBUG\nlet y = 2\n#endif\n' > "$repo/ios/Regards/App/A.swift"
printf '# config\nkey: value\n' > "$repo/tools/config.yml"
git -C "$repo" add -A
git -C "$repo" commit -q -m base
base="$(git -C "$repo" rev-parse HEAD)"

# expect <name> <expected status> <mutation function>
expect() {
  local name="$1"
  local expected="$2"
  local mutate="$3"
  local output status

  git -C "$repo" checkout -q -B case "$base"
  "$mutate"
  git -C "$repo" add -A
  git -C "$repo" commit -q --allow-empty -m "$name"
  set +e
  output="$(bash "$checker" "$repo" "$base" "$(git -C "$repo" rev-parse HEAD)" 2>&1)"
  status=$?
  set -e
  if [[ "$status" -ne "$expected" ]]; then
    echo "FAIL: $name (expected $expected, got $status): $output" >&2
    exit 1
  fi
  echo "PASS: $name"
}

plist_and_md() { printf '<plist>x</plist>\n' > "$repo/ios/Info.plist"; printf '# Doc\n\nmore\n' > "$repo/docs/guide.md"; }
spaced_plist_and_md() { printf '<plist>x</plist>\n' > "$repo/ios/My File.plist"; printf '# Doc\n\nmore\n' > "$repo/docs/guide.md"; }
rename_to_md() { git -C "$repo" mv ios/Info.plist docs/Info.md; }
shebang_edit() { printf '#!/bin/bash\n# note\necho hi\n' > "$repo/tools/run.sh"; }
sh_line_one() { printf '# new first line\n#!/usr/bin/env bash\n# note\necho hi\n' > "$repo/tools/run.sh"; }
sh_mid_comment() { printf '#!/usr/bin/env bash\n# note changed\necho hi\n' > "$repo/tools/run.sh"; }
mode_change() { chmod +x "$repo/docs/guide.md"; }
swift_if_change() { printf 'import Foundation\n\n// note\nlet x = 1\n#if RELEASE\nlet y = 2\n#endif\n' > "$repo/ios/Regards/App/A.swift"; }
swiftlint_directive() { printf 'import Foundation\n\n// note\n// swiftlint:disable all\nlet x = 1\n#if DEBUG\nlet y = 2\n#endif\n' > "$repo/ios/Regards/App/A.swift"; }
swift_comment_only() { printf 'import Foundation\n\n// note, reworded\n\n// another note\nlet x = 1\n#if DEBUG\nlet y = 2\n#endif\n' > "$repo/ios/Regards/App/A.swift"; }
swift_code_change() { printf 'import Foundation\n\n// note\nlet x = 2\n#if DEBUG\nlet y = 2\n#endif\n' > "$repo/ios/Regards/App/A.swift"; }
swift_trailing_comment() { printf 'import Foundation\n\n// note\nlet x = 1 // trailing\n#if DEBUG\nlet y = 2\n#endif\n' > "$repo/ios/Regards/App/A.swift"; }
claude_contract_md() { printf -- '---\nname: x\n---\n\n# Heading\n\nmore\n' > "$repo/.claude/agents/x.md"; }
toml_heading() { printf 'developer_instructions = """\n## Other heading\n"""\n' > "$repo/.codex/agents/y.toml"; }
ci_comment() { printf '# a comment\nname: ci\n' > "$repo/.github/workflows/w.yml"; }
scripts_comment() { printf '#!/usr/bin/env bash\n# new comment\necho hi\n' > "$repo/scripts/helper.sh"; }
project_yml() { printf '# comment\nname: Regards\n' > "$repo/project.yml"; }
pbxproj_comment() { printf '// pbx changed\n' > "$repo/ios/Regards.xcodeproj/project.pbxproj"; }
docs_md_only() { printf '# Doc\n\nmore text\n' > "$repo/docs/guide.md"; printf '# New\n' > "$repo/docs/new.md"; }
yml_comment_only() { printf '# config, reworded\nkey: value\n' > "$repo/tools/config.yml"; }
yml_value_change() { printf '# config\nkey: other\n' > "$repo/tools/config.yml"; }
new_file_comment_only() { printf '// only a comment\n' > "$repo/ios/Regards/App/B.swift"; }
no_change() { :; }

expect 'plist plus md fails' 1 plist_and_md
expect 'a plist with a space in its name plus md fails' 1 spaced_plist_and_md
expect 'a rename to .md fails' 1 rename_to_md
expect 'a shebang edit fails' 1 shebang_edit
expect 'a change to line 1 of a .sh file fails' 1 sh_line_one
expect 'a mid-file .sh comment change passes' 0 sh_mid_comment
expect 'a mode change fails' 1 mode_change
expect 'a Swift #if change fails' 1 swift_if_change
expect 'a swiftlint directive comment fails' 1 swiftlint_directive
expect 'a Swift code change fails' 1 swift_code_change
expect 'a Swift trailing comment on a code line fails' 1 swift_trailing_comment
expect 'a .claude agent contract .md change fails' 1 claude_contract_md
expect 'a .toml heading change fails' 1 toml_heading
expect 'a CI workflow comment change fails' 1 ci_comment
expect 'a scripts/ comment change fails' 1 scripts_comment
expect 'a project.yml change fails' 1 project_yml
expect 'an xcodeproj change fails' 1 pbxproj_comment
expect 'a new Swift file fails even if it is only a comment' 1 new_file_comment_only
expect 'a YAML value change fails' 1 yml_value_change
expect 'docs/*.md changes pass' 0 docs_md_only
expect 'a Swift comment-only change passes' 0 swift_comment_only
expect 'a YAML comment-only change passes' 0 yml_comment_only
expect 'an empty change passes' 0 no_change

set +e
bash "$checker" "$repo" "$(git -C "$repo" rev-parse HEAD)" "$base" > /dev/null 2>&1
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
