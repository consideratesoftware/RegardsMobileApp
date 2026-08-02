#!/usr/bin/env bash

# Asserts the exact strings scripts/render-review-check-summary.sh produces.
# Exact, not fuzzy: this line is the only signal separating "reviewed, clean"
# from "reviewed, blockers found" now that a REQUEST_CHANGES verdict passes the
# check, so wording drift is a real regression and not cosmetic.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
subject="$repo_root/scripts/render-review-check-summary.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

failures=0
n=0

# expect <label> <expected> <verdict> <blockers> <should_fix> <nits>
expect() {
  local label="$1" expected="$2" verdict="$3" b="$4" s="$5" nits="$6"
  n=$((n + 1))
  local file="$work_dir/$n.json"
  jq -n --arg v "$verdict" --argjson b "$b" --argjson s "$s" --argjson n "$nits" '{
    verdict: $v,
    blockers: [range($b) | "[a] [f:1] blocker"],
    should_fix: [range($s) | "[a] [f:1] should fix"],
    nits: [range($n) | "[a] [f:1] nit"]
  }' > "$file"
  local actual
  actual="$("$subject" "$file")"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $label"
  else
    echo "FAIL: $label"
    echo "    expected: $expected"
    echo "    actual:   $actual"
    failures=$((failures + 1))
  fi
}

expect 'request changes, singular blocker and nit' \
  'Changes requested: 1 blocker, 2 should-fix, 1 nit. The review ran; the gate does not block on the verdict.' \
  REQUEST_CHANGES 1 2 1

expect 'request changes, plural blockers and nits' \
  'Changes requested: 3 blockers, 0 should-fix, 4 nits. The review ran; the gate does not block on the verdict.' \
  REQUEST_CHANGES 3 0 4

expect 'approve is never reported as fully clean when findings exist' \
  'Approved: no blockers, 30 should-fix, 2 nits.' \
  APPROVE 0 30 2

expect 'approve with nothing at all' \
  'Approved: no blockers, 0 should-fix, 0 nits.' \
  APPROVE 0 0 0

# An unrecognized verdict is unreachable while the JSON schema holds, but the
# schema and this renderer can drift independently; say so rather than
# silently printing an approval-shaped line.
n=$((n + 1))
printf '%s\n' '{"verdict":"MAYBE","blockers":[],"should_fix":[],"nits":[]}' > "$work_dir/$n.json"
actual="$("$subject" "$work_dir/$n.json")"
expected='Unrecognized verdict MAYBE; see the review below.'
if [[ "$actual" == "$expected" ]]; then
  echo 'PASS: unrecognized verdict is called out, not smoothed over'
else
  echo "FAIL: unrecognized verdict (expected '$expected', got '$actual')"
  failures=$((failures + 1))
fi

missing_expected='No verified review artifact was produced. The review did not run — see the run log.'
for label in '--missing flag' 'empty artifact file'; do
  if [[ "$label" == '--missing flag' ]]; then
    actual="$("$subject" --missing)"
  else
    : > "$work_dir/empty.json"
    actual="$("$subject" "$work_dir/empty.json")"
  fi
  if [[ "$actual" == "$missing_expected" ]]; then
    echo "PASS: $label reports the review did not run"
  else
    echo "FAIL: $label (got '$actual')"
    failures=$((failures + 1))
  fi
done

if "$subject" >/dev/null 2>&1; then
  echo 'FAIL: missing argument should exit non-zero'
  failures=$((failures + 1))
else
  echo 'PASS: rejects a missing argument'
fi

if (( failures > 0 )); then
  echo "$failures test(s) failed." >&2
  exit 1
fi
