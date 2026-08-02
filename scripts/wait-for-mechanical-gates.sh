#!/usr/bin/env bash

# Block until every check on this PR except the review job itself has
# finished, and fail if any of them is red.
#
# pr-review.md Stage 0 says not to dispatch agents against a red baseline. The
# review job runs concurrently with ios-ci, lint and guards, so without this
# the reviewer inspects them mid-flight and writes "pending" into its
# PRE-FLIGHT line -- accurate, but the artifact validator rejects it.
#
# Reads `gh pr checks --json name,bucket`, whose bucket is one of
# pass / fail / pending / skipping / cancel. The sibling set has to be stable
# across two consecutive polls before it counts as complete, so a check that
# GitHub has not created yet is not mistaken for a finished run.

set -euo pipefail

readonly SELF_CHECK_NAME="${SELF_CHECK_NAME:-review}"
readonly POLL_SECONDS="${POLL_SECONDS:-20}"
readonly TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-3600}"

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <pr-number>" >&2
  exit 64
fi

pr_number="$1"
started_at=$SECONDS
previous_names=""

while :; do
  # gh exits non-zero while checks are pending or failing; the JSON is what
  # matters, so keep the exit status from killing the loop under `set -e`.
  checks_json="$(gh pr checks "$pr_number" --json name,bucket 2>/dev/null || true)"

  if [[ -z "$checks_json" ]]; then
    siblings='[]'
  else
    siblings="$(jq --arg self "$SELF_CHECK_NAME" \
      '[.[] | select(.name != $self)]' <<< "$checks_json")"
  fi

  failed="$(jq -r '[.[] | select(.bucket == "fail" or .bucket == "cancel")]
                   | map(.name) | join(", ")' <<< "$siblings")"
  if [[ -n "$failed" ]]; then
    echo "::error::Red baseline: $failed. Stage 0 says stop, so no review was dispatched."
    exit 1
  fi

  pending="$(jq -r '[.[] | select(.bucket == "pending")] | map(.name) | join(", ")' \
    <<< "$siblings")"
  names="$(jq -r 'map(.name) | sort | join(",")' <<< "$siblings")"

  # Complete only when nothing is pending, something exists to be complete,
  # and the sibling set has not changed since the previous poll.
  if [[ -z "$pending" && -n "$names" && "$names" == "$previous_names" ]]; then
    echo "All mechanical gates finished green:"
    jq -r '.[] | "  \(.bucket)  \(.name)"' <<< "$siblings" | sort
    exit 0
  fi

  if (( SECONDS - started_at > TIMEOUT_SECONDS )); then
    echo "::error::Timed out after ${TIMEOUT_SECONDS}s waiting for: ${pending:-<no checks reported>}"
    exit 1
  fi

  if [[ -n "$pending" ]]; then
    echo "waiting on: $pending"
  else
    echo "waiting for the check set to settle (currently: ${names:-none})"
  fi

  previous_names="$names"
  sleep "$POLL_SECONDS"
done
