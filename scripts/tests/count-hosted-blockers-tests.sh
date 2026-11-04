#!/usr/bin/env bash
# Fixture tests for scripts/count-hosted-blockers.sh.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
counter="$repo_root/scripts/count-hosted-blockers.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

expect_output() {
  local name="$1"
  local expected="$2"
  local body="$3"
  local actual

  printf '%s' "$body" > "$work/review.txt"
  actual="$(bash "$counter" "$work/review.txt")"
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL: $name (expected '$expected', got '$actual')" >&2
    exit 1
  fi
  echo "PASS: $name"
}

expect_output 'empty file is PENDING' \
  'PENDING: no review text for this head yet' ''
expect_output 'a "None." paragraph is zero blockers' 'BLOCKERS 0' \
  $'VERDICT: APPROVE\n### Blockers (must fix before merge)\n\nNone.\n\n### Should fix\n- a\n'
expect_output 'a "- None" bullet is zero blockers' 'BLOCKERS 0' \
  $'VERDICT: APPROVE\n### Blockers\n\n- None\n\n### Should fix\n'
expect_output 'a "* None." bullet is zero blockers' 'BLOCKERS 0' \
  $'VERDICT: APPROVE\n### Blockers\n* None.\n'
expect_output 'a numbered "1. None" bullet is zero blockers' 'BLOCKERS 0' \
  $'VERDICT: APPROVE\n### Blockers\n\n1. None\n\n### Should fix\n'
expect_output 'dash and numbered bullets are counted' 'BLOCKERS 3' \
  $'VERDICT: REQUEST_CHANGES\n### Blockers\n- a\n2. b\n3) c\n### Should fix\n- d\n'
expect_output 'star bullets are counted' 'BLOCKERS 2' \
  $'VERDICT: REQUEST_CHANGES\n### Blockers\n* a\n* b\n'
expect_output 'a bullet marker followed by a tab is counted' 'BLOCKERS 2' \
  $'VERDICT: REQUEST_CHANGES\n### Blockers\n- first\n-\tsecond\n'
expect_output 'a non-bullet line next to bullets is MALFORMED' \
  'MALFORMED: Blockers section has lines that are not bullets' \
  $'VERDICT: REQUEST_CHANGES\n### Blockers\n- first\n**2.** second\n'
expect_output 'REQUEST_CHANGES with no bullets is MALFORMED' \
  'MALFORMED: no blockers listed but VERDICT is REQUEST_CHANGES' \
  $'VERDICT: REQUEST_CHANGES\n### Blockers\n\nNone.\n'
expect_output 'a missing VERDICT with no bullets is MALFORMED' \
  'MALFORMED: no blockers listed but VERDICT is missing' \
  $'### Blockers\n\nNone.\n'
expect_output 'prose only is MALFORMED' \
  'MALFORMED: Blockers section has lines that are not bullets' \
  $'VERDICT: APPROVE\n### Blockers\n\nSomething odd happened.\n\n### Should fix\n- a\n'
expect_output 'no Blockers section is MALFORMED' \
  'MALFORMED: no Blockers section' \
  $'VERDICT: APPROVE\n### Should fix\n- a\n'

set +e
bash "$counter" > /dev/null 2>&1
status=$?
set -e
if [[ "$status" -ne 64 ]]; then
  echo "FAIL: usage error (expected 64, got $status)" >&2
  exit 1
fi
echo 'PASS: usage error exits 64'

set +e
missing="$(bash "$counter" "$work/does-not-exist")"
set -e
if [[ "$missing" != PENDING* ]]; then
  echo "FAIL: missing file should be PENDING, got '$missing'" >&2
  exit 1
fi
echo 'PASS: a missing file is PENDING'
