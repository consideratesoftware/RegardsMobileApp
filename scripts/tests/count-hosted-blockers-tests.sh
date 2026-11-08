#!/usr/bin/env bash
# Fixture tests for scripts/count-hosted-blockers.sh (the counter), and a
# contract check that runs it with 2 other scripts. The last cases
# (expect_contract) run scripts/validate-hosted-review-artifact.sh (the
# validator; its stdout is the rendered review) and
# scripts/render-review-check-summary.sh (the check-summary renderer) on one
# artifact, and require the validator's exit status, the counter's count of the
# rendered review and the check summary to agree. A change to either of those
# scripts can fail this file.

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
expect_output 'the first VERDICT line wins over a later one' \
  'MALFORMED: no blockers listed but VERDICT is REQUEST_CHANGES' \
  $'VERDICT: REQUEST_CHANGES\n### Blockers\n\nNone.\n\n### Should fix\n- a\nVERDICT: APPROVE\n'
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

# The counter, the hosted renderer and the check summary must agree on the
# blocker count. The check summary carries counts only, and the release manager
# quotes blockers from the rendered review, so a renderer change that the
# counter cannot read must fail here. The renderer is the stdout of
# scripts/validate-hosted-review-artifact.sh, which the hosted job publishes.
validator="$repo_root/scripts/validate-hosted-review-artifact.sh"
summary_renderer="$repo_root/scripts/render-review-check-summary.sh"
head_sha="0123456789abcdef0123456789abcdef01234567"
base_sha="76543210fedcba9876543210fedcba9876543210"
pr_number=23
run_id=30638934931

# expect_contract <blocker count> <phrase the check summary must contain>
expect_contract() {
  local blockers="$1"
  local phrase="$2"
  local artifact="$work/artifact-$blockers.json"
  local rendered="$work/rendered-$blockers.md"
  local expected_status=2
  local status counted expected summary

  if [[ "$blockers" -eq 0 ]]; then
    expected_status=0
  fi

  jq -n \
    --arg head_sha "$head_sha" \
    --arg base_sha "$base_sha" \
    --argjson pr_number "$pr_number" \
    --arg run_id "$run_id" \
    --argjson blockers "$blockers" '
      {
        head_sha: $head_sha,
        base_sha: $base_sha,
        pr_number: $pr_number,
        run_id: $run_id,
        verdict: (if $blockers == 0 then "APPROVE" else "REQUEST_CHANGES" end),
        blockers: [range($blockers) | "[pr-correctness] [file.swift:\(. + 1)] blocker \(. + 1)"],
        should_fix: [],
        nits: [],
        questions_for_sid: [],
        audit_trail: {
          security_invariants: "INVARIANTS VERIFIED: checks 1-8 pass or are not applicable.",
          accessibility_process: "PROCESS: not dispatched",
          fit_finish_docs: "DOCS: register yes; accessibility docs not applicable.",
          tests_criteria_map: "CRITERIA MAP: trusted gate cases pass."
        }
      }
    ' > "$artifact"

  set +e
  "$validator" "$artifact" "$head_sha" "$base_sha" "$pr_number" "$run_id" > "$rendered"
  status=$?
  set -e
  if [[ "$status" -ne "$expected_status" ]]; then
    echo "FAIL: validator with $blockers blocker(s) (expected exit $expected_status, got $status)" >&2
    exit 1
  fi

  counted="$(bash "$counter" "$rendered")"
  expected="BLOCKERS $(jq '.blockers | length' "$artifact")"
  if [[ "$counted" != "$expected" ]]; then
    echo "FAIL: counter on the rendered review with $blockers blocker(s) (expected '$expected', got '$counted')" >&2
    exit 1
  fi

  # Each blocker's text comes through verbatim, as a bullet of its own. The
  # counter counts bullets, so a renderer that shortened a blocker would still
  # count right.
  while IFS= read -r blocker; do
    if ! grep -qxF -- "- $blocker" "$rendered"; then
      echo "FAIL: rendered review with $blockers blocker(s) lacks the bullet '- $blocker'" >&2
      exit 1
    fi
  done < <(jq -r '.blockers[]' "$artifact")

  summary="$("$summary_renderer" "$artifact")"
  if [[ "$summary" != *"$phrase"* ]]; then
    echo "FAIL: check summary with $blockers blocker(s) lacks '$phrase' (got '$summary')" >&2
    exit 1
  fi
  echo "PASS: renderer, counter and check summary agree on $blockers blocker(s)"
}

expect_contract 0 'no blockers'
expect_contract 1 'Changes requested: 1 blocker,'
expect_contract 3 'Changes requested: 3 blockers,'
