#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <review-started-at> <head-sha>" >&2
  exit 64
fi

started_at="$1"
head_sha="$2"

review_body="$(jq -rs --arg started_at "$started_at" --arg head_sha "$head_sha" '
  [
    .[][]
    | select(.user.type == "Bot")
    | select(.created_at >= $started_at)
    | .body
    | select(contains($head_sha))
    | select(test("^## PR Review"))
    | select(test("(^|\\n)PRE-FLIGHT:"))
    | select(test("(^|\\n)VERDICT: (APPROVE|REQUEST_CHANGES)($|\\n)"))
    | select(test("(^|\\n)### Audit trail($|\\n)"))
  ]
  | last // empty
')"

if [[ -z "$review_body" ]]; then
  echo "::error::The hosted reviewer did not post a current-head verdict artifact." >&2
  exit 1
fi

if grep -q '^VERDICT: REQUEST_CHANGES$' <<< "$review_body"; then
  echo "::error::The hosted reviewer requested changes." >&2
  exit 1
fi

printf '%s\n' "$review_body"
