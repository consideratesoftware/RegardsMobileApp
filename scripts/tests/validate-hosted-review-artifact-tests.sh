#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
artifact_validator="$repo_root/scripts/validate-hosted-review-artifact.sh"
output_guard="$repo_root/scripts/require-hosted-review-output.sh"
head_sha="0123456789abcdef0123456789abcdef01234567"
base_sha="76543210fedcba9876543210fedcba9876543210"
pr_number=23
run_id=30638934931

expect_artifact_status() {
  local name="$1"
  local expected_status="$2"
  local body="$3"
  local artifact_file
  local status

  artifact_file="$(mktemp)"
  printf '%s\n' "$body" > "$artifact_file"
  set +e
  "$artifact_validator" \
    "$artifact_file" "$head_sha" "$base_sha" "$pr_number" "$run_id" \
    > "$artifact_file.out" 2>/dev/null
  status=$?
  set -e
  if [[ "$status" -ne "$expected_status" ]]; then
    echo "FAIL: $name (expected $expected_status, got $status)" >&2
    exit 1
  fi
  rm -f "$artifact_file" "$artifact_file.out"
  echo "PASS: $name"
}

approval="$(jq -nc \
  --arg head_sha "$head_sha" \
  --arg base_sha "$base_sha" \
  --argjson pr_number "$pr_number" \
  --arg run_id "$run_id" '
    {
      head_sha: $head_sha,
      base_sha: $base_sha,
      pr_number: $pr_number,
      run_id: $run_id,
      verdict: "APPROVE",
      blockers: [],
      should_fix: [],
      nits: [],
      questions_for_sid: [],
      audit_trail: {
        security_invariants: "INVARIANTS VERIFIED: checks 1-8 pass or are not applicable.",
        accessibility_process: "PROCESS: not dispatched",
        fit_finish_docs: "DOCS: register yes; accessibility docs not applicable; PR cites §14 yes.",
        tests_criteria_map: "CRITERIA MAP: trusted gate cases pass."
      }
    }
  ')"
request_changes="$(jq '
  .verdict = "REQUEST_CHANGES"
  | .blockers = ["[pr-security-privacy] [.github/workflows/review.yml:1] unsafe token"]
' <<< "$approval")"

expect_artifact_status 'accepts bound approval' 0 "$approval"
expect_artifact_status 'publishes and fails request changes' 2 "$request_changes"
expect_artifact_status 'rejects malformed JSON' 1 '{'
expect_artifact_status \
  'rejects wrong head identity' 1 \
  "$(jq '.head_sha = "ffffffffffffffffffffffffffffffffffffffff"' <<< "$approval")"
expect_artifact_status \
  'rejects wrong base identity' 1 \
  "$(jq '.base_sha = "ffffffffffffffffffffffffffffffffffffffff"' <<< "$approval")"
expect_artifact_status \
  'rejects wrong PR identity' 1 \
  "$(jq '.pr_number = 24' <<< "$approval")"
expect_artifact_status \
  'rejects wrong run identity' 1 \
  "$(jq '.run_id = "30638934932"' <<< "$approval")"
expect_artifact_status \
  'rejects unsupported verdict' 1 \
  "$(jq '.verdict = "PENDING"' <<< "$approval")"
expect_artifact_status \
  'rejects approval with blocker' 1 \
  "$(jq '.blockers = ["[pr-correctness] [file.swift:1] blocker"]' <<< "$approval")"
expect_artifact_status \
  'rejects request changes without blocker' 1 \
  "$(jq '.verdict = "REQUEST_CHANGES"' <<< "$approval")"
expect_artifact_status \
  'rejects missing audit category' 1 \
  "$(jq 'del(.audit_trail.tests_criteria_map)' <<< "$approval")"
expect_artifact_status \
  'rejects malformed audit category' 1 \
  "$(jq '.audit_trail.security_invariants = "fabricated audit"' <<< "$approval")"
expect_artifact_status \
  'rejects untrusted extra fields' 1 \
  "$(jq '.publisher = "any bot"' <<< "$approval")"
expect_artifact_status \
  'rejects malformed finding prefix' 1 \
  "$(jq '.should_fix = ["not a finding"]' <<< "$approval")"
expect_artifact_status \
  'rejects multiline findings' 1 \
  "$(jq '.should_fix = ["[pr-tests] [file.swift:1] first line\nsecond line"]' <<< "$approval")"

publishable_boundary="$(jq '
  .should_fix = [range(0; 30) |
    "[pr-tests] [file.swift:1] " + ("x" * 1650)]
  | .nits = [range(0; 10) |
    "[pr-code-quality] [file.swift:1] " + ("x" * 950)]
' <<< "$approval")"
expect_artifact_status \
  'accepts a publishable large review' 0 "$publishable_boundary"

oversized_comment="$(jq '
  .should_fix = [range(0; 30) |
    "[pr-tests] [file.swift:1] " + ("x" * 1950)]
  | .nits = [range(0; 10) |
    "[pr-code-quality] [file.swift:1] " + ("x" * 1950)]
' <<< "$approval")"
expect_artifact_status \
  'rejects a review above the comment boundary' 1 "$oversized_comment"

request_changes_file="$(mktemp)"
printf '%s\n' "$request_changes" > "$request_changes_file"
set +e
"$artifact_validator" \
  "$request_changes_file" "$head_sha" "$base_sha" "$pr_number" "$run_id" \
  > "$request_changes_file.out" 2>/dev/null
request_changes_status=$?
set -e
test "$request_changes_status" -eq 2
grep -q '^### Blockers (must fix before merge)$' "$request_changes_file.out"
grep -q '^VERDICT: REQUEST_CHANGES$' "$request_changes_file.out"
grep -q 'unsafe token' "$request_changes_file.out"
grep -q '^### Audit trail$' "$request_changes_file.out"
rm -f "$request_changes_file" "$request_changes_file.out"
echo 'PASS: renders request changes before failing'

output_file="$(mktemp)"
printf '%s\n' "$approval" > "$output_file"
"$output_guard" success success "$output_file" >/dev/null
echo 'PASS: accepts successful analysis and preflight with artifact'

whitespace_file="$(mktemp)"
printf '\n' > "$whitespace_file"
set +e
"$output_guard" failure success "$output_file" >/dev/null 2>&1
failed_analysis_status=$?
"$output_guard" success failure "$output_file" >/dev/null 2>&1
failed_preflight_status=$?
"$output_guard" success success "$whitespace_file" >/dev/null 2>&1
empty_artifact_status=$?
set -e
test "$failed_analysis_status" -ne 0
test "$failed_preflight_status" -ne 0
test "$empty_artifact_status" -ne 0
rm -f "$output_file" "$whitespace_file"
echo 'PASS: rejects failed analysis'
echo 'PASS: rejects failed trusted preflight'
echo 'PASS: rejects whitespace-only artifact'
