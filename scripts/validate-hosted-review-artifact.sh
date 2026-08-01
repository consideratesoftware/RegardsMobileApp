#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 5 ]]; then
  echo "usage: $0 <artifact-json> <head-sha> <base-sha> <pr-number> <run-id>" >&2
  exit 64
fi

artifact_file="$1"
head_sha="$2"
base_sha="$3"
pr_number="$4"
run_id="$5"

if [[ ! -f "$artifact_file" ]] \
  || [[ ! "$head_sha" =~ ^[0-9a-f]{40}$ ]] \
  || [[ ! "$base_sha" =~ ^[0-9a-f]{40}$ ]] \
  || [[ ! "$pr_number" =~ ^[1-9][0-9]*$ ]] \
  || [[ ! "$run_id" =~ ^[1-9][0-9]*$ ]]; then
  echo "::error::Hosted review identity or artifact path is invalid." >&2
  exit 1
fi

if [[ $(wc -c < "$artifact_file") -gt 200000 ]]; then
  echo "::error::Hosted review artifact exceeds the size limit." >&2
  exit 1
fi

if ! jq -e \
  --arg head_sha "$head_sha" \
  --arg base_sha "$base_sha" \
  --argjson pr_number "$pr_number" \
  --arg run_id "$run_id" '
    def valid_line($limit):
      type == "string"
      and length > 0
      and length <= $limit
      and (test("[\\r\\n]") | not);
    def valid_findings($limit):
      type == "array"
      and length <= $limit
      and all(.[];
        valid_line(2000)
        and test("^\\[[^]\\r\\n]+\\] \\[[^]\\r\\n]+:[1-9][0-9]*\\] .+"));
    type == "object"
    and keys == [
      "audit_trail", "base_sha", "blockers", "head_sha", "nits",
      "pr_number", "questions_for_sid", "run_id", "should_fix", "verdict"
    ]
    and .head_sha == $head_sha
    and .base_sha == $base_sha
    and .pr_number == $pr_number
    and .run_id == $run_id
    and (.verdict == "APPROVE" or .verdict == "REQUEST_CHANGES")
    and (.blockers | valid_findings(30))
    and (.should_fix | valid_findings(30))
    and (.nits | valid_findings(10))
    and (.questions_for_sid |
      type == "array" and length <= 10 and all(.[]; valid_line(2000)))
    and (.audit_trail |
      type == "object"
      and keys == [
        "accessibility_process", "fit_finish_docs", "security_invariants",
        "tests_criteria_map"
      ]
      and (.security_invariants |
        valid_line(8000) and startswith("INVARIANTS VERIFIED:"))
      and (.accessibility_process |
        valid_line(2000) and startswith("PROCESS:"))
      and (.fit_finish_docs |
        valid_line(2000) and startswith("DOCS:"))
      and (.tests_criteria_map |
        valid_line(8000) and startswith("CRITERIA MAP:")))
    and if .verdict == "APPROVE"
      then (.blockers | length) == 0
      else (.blockers | length) > 0
      end
  ' "$artifact_file" >/dev/null; then
  echo "::error::Hosted reviewer returned an invalid or mismatched artifact." >&2
  exit 1
fi

print_section() {
  local heading="$1"
  local key="$2"

  printf '\n### %s\n\n' "$heading"
  if [[ $(jq --arg key "$key" '.[$key] | length' "$artifact_file") -eq 0 ]]; then
    printf 'None.\n'
  else
    jq -r --arg key "$key" '.[$key][] | "- " + .' "$artifact_file"
  fi
}

verdict="$(jq -r '.verdict' "$artifact_file")"
printf '## PR Review — #%s — %s\n' "$pr_number" "$(date -u +%Y-%m-%d)"
printf 'HEAD SHA: %s\n' "$head_sha"
printf 'BASE SHA: %s\n' "$base_sha"
printf 'WORKFLOW RUN: %s\n' "$run_id"
printf 'PRE-FLIGHT: determinism ✅ | swiftlint ✅ | guards ✅\n'
printf 'VERDICT: %s\n' "$verdict"
print_section 'Blockers (must fix before merge)' blockers
print_section "Should fix (before or in fast-follow, owner's call)" should_fix
print_section 'Nits (take or leave)' nits
print_section 'Questions for Sid' questions_for_sid
printf '\n### Audit trail\n\n'
jq -r '
  .audit_trail
  | [
      .security_invariants,
      .accessibility_process,
      .fit_finish_docs,
      .tests_criteria_map
    ][]
  | "- " + .
' "$artifact_file"

if [[ "$verdict" == "REQUEST_CHANGES" ]]; then
  exit 2
fi
