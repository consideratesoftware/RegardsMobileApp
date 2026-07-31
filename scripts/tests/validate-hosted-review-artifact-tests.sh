#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
validator="$repo_root/scripts/validate-hosted-review-artifact.sh"
started_at="2026-07-31T14:30:00Z"
head_sha="0123456789abcdef0123456789abcdef01234567"

approval_body="$(printf '%s\n' \
  '## PR Review — branch — 2026-07-31' \
  "HEAD SHA: $head_sha" \
  'PRE-FLIGHT: determinism ✅ | swiftlint ✅ | guards ✅' \
  'VERDICT: APPROVE' \
  '' \
  '### Blockers (must fix before merge)' \
  'None.' \
  '' \
  "### Should fix (before or in fast-follow, owner's call)" \
  'None.' \
  '' \
  '### Nits (take or leave)' \
  'None.' \
  '' \
  '### Questions for Sid' \
  'None.' \
  '' \
  '### Audit trail' \
  '- complete')"

request_changes_body="${approval_body/VERDICT: APPROVE/VERDICT: REQUEST_CHANGES}"
red_preflight_body="${approval_body/PRE-FLIGHT: determinism ✅ | swiftlint ✅ | guards ✅/PRE-FLIGHT: determinism ❌ | swiftlint ❌ | guards ❌}"
missing_heading_body="$(printf '%s\n' "$approval_body" | sed '/^### Questions for Sid$/d')"
malformed_body="$(printf '%s\n' \
  '## PR Review — branch — 2026-07-31' \
  "HEAD SHA: $head_sha" \
  'PRE-FLIGHT: determinism ✅ | swiftlint ✅ | guards ✅' \
  'VERDICT: APPROVE')"

comment_page() {
  local created_at="$1"
  local body="$2"
  local user_type="${3:-Bot}"
  jq -nc \
    --arg created_at "$created_at" \
    --arg body "$body" \
    --arg user_type "$user_type" \
    '[{user: {type: $user_type}, created_at: $created_at, body: $body}]'
}

expect_status() {
  local name="$1"
  local expected_status="$2"
  local pages="$3"
  local status

  set +e
  printf '%s\n' "$pages" \
    | "$validator" "$started_at" "$head_sha" >/dev/null 2>&1
  status=$?
  set -e

  if [[ "$status" -ne "$expected_status" ]]; then
    echo "FAIL: $name (expected $expected_status, got $status)" >&2
    exit 1
  fi
  echo "PASS: $name"
}

expect_status "fails without artifact" 1 '[]'

stale_page="$(comment_page "2026-07-31T14:29:59Z" "$approval_body")"
wrong_sha_body="${approval_body/$head_sha/ffffffffffffffffffffffffffffffffffffffff}"
wrong_sha_page="$(comment_page "2026-07-31T14:31:00Z" "$wrong_sha_body")"
expect_status \
  "rejects stale or wrong head SHA" 1 \
  "$(printf '%s\n%s' "$stale_page" "$wrong_sha_page")"

expect_status \
  "rejects malformed artifact" 1 \
  "$(comment_page "2026-07-31T14:31:00Z" "$malformed_body")"

expect_status \
  "rejects red preflight" 1 \
  "$(comment_page "2026-07-31T14:31:00Z" "$red_preflight_body")"

expect_status \
  "rejects missing Stage 3 heading" 1 \
  "$(comment_page "2026-07-31T14:31:00Z" "$missing_heading_body")"

expect_status \
  "fails for request changes" 1 \
  "$(comment_page "2026-07-31T14:31:00Z" "$request_changes_body")"

expect_status \
  "accepts current-head approval" 0 \
  "$(comment_page "2026-07-31T14:31:00Z" "$approval_body")"

first_page="$(comment_page "2026-07-31T14:31:00Z" "$malformed_body")"
second_page="$(comment_page "2026-07-31T14:32:00Z" "$approval_body")"
expect_status \
  "finds valid approval on later paginated page" 0 \
  "$(printf '%s\n%s' "$first_page" "$second_page")"
