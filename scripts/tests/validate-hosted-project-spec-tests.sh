#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
validator="$script_dir/../validate-hosted-project-spec.sh"
fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

expect_accept() {
  local name="$1"
  local fixture="$2"
  "$validator" "$fixture"
  echo "PASS: $name"
}

expect_reject() {
  local name="$1"
  local fixture="$2"
  if "$validator" "$fixture" >/dev/null 2>&1; then
    echo "FAIL: $name" >&2
    exit 1
  fi
  echo "PASS: $name"
}

cp "$script_dir/../../ios/project.yml" "$fixture_root/safe.yml"
expect_accept "accepts the repository project specification" \
  "$fixture_root/safe.yml"

printf '%s\n' '"preGenCommand": "touch /tmp/escaped"' \
  > "$fixture_root/quoted-hook.yml"
expect_reject "rejects a quoted command-hook key" \
  "$fixture_root/quoted-hook.yml"

printf '%s\n' 'options:' '  "postGenCommand": "touch /tmp/escaped"' \
  > "$fixture_root/nested-hook.yml"
expect_reject "rejects a nested command-hook key" \
  "$fixture_root/nested-hook.yml"

printf '%s\n' 'name: Regards' 'include:' '  - attacker.yml' \
  > "$fixture_root/include.yml"
expect_reject "rejects included XcodeGen specifications" \
  "$fixture_root/include.yml"
