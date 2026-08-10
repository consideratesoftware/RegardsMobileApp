#!/usr/bin/env bash

set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_directory/../.." && pwd)"
fixtures_directory="$script_directory/fixtures/prepare-audit-simulator"
target="$repository_root/scripts/prepare-audit-simulator.sh"

expect_resolve() {
  local label="$1"
  local fixture="$2"
  local expected_udid="$3"
  local actual

  actual="$("$target" "iPhone 17 Pro" --resolve-only <"$fixtures_directory/$fixture" | cut -d" " -f1)"
  if [[ "$actual" != "$expected_udid" ]]; then
    echo "FAIL: $label expected udid $expected_udid, got $actual" >&2
    exit 1
  fi
}

expect_resolve_failure() {
  local label="$1"
  local fixture="$2"
  local expected_message="$3"
  local output

  if output="$("$target" "iPhone 17 Pro" --resolve-only <"$fixtures_directory/$fixture" 2>&1)"; then
    echo "FAIL: $label unexpectedly succeeded: $output" >&2
    exit 1
  fi

  if ! grep -qF "$expected_message" <<<"$output"; then
    echo "FAIL: $label did not emit the expected message" >&2
    echo "$output" >&2
    exit 1
  fi
}

# (a) The newest iOS runtime wins even when neither hash-iteration order nor
# a naive string comparison of the runtime identifiers would give the right
# answer (see the fixture's comment-equivalent ordering).
expect_resolve "newest runtime wins over hash order and string order" \
  multiple-runtimes.json NEW-UDID

# (b) An isAvailable:false device in the newest runtime is skipped in favor
# of an available device in an older runtime.
expect_resolve "unavailable newest runtime falls back to an older one" \
  unavailable-newest.json FALLBACK-UDID

# (c) tvOS, watchOS, and a malformed (non-CoreSimulator) runtime key holding
# a same-named device are all ignored.
expect_resolve "non-iOS and malformed runtime keys are ignored" \
  non-ios-runtimes.json REAL-UDID

# (e) Two available devices tied at the newest iOS runtime fail loudly
# instead of picking one arbitrarily (the exact risk of `Array#max_by`).
expect_resolve_failure "a tie at the newest runtime refuses to guess" \
  tied-newest-runtime.json \
  '::error::Multiple available simulators named "iPhone 17 Pro" tie at the newest iOS runtime'

# (d) --resolve-only alone: no matching device fails with the expected
# ::error:: line.
expect_resolve_failure "no matching device fails closed" \
  no-match.json \
  '::error::No available simulator named "iPhone 17 Pro" found'

# (d) End to end: drive the full script (not --resolve-only) against a stub
# xcrun so a missing device is proven to fail *before* any simctl
# boot/bootstatus/status_bar call -- the regression a future edit could
# introduce by moving code above the resolution step.
fake_bin="$(mktemp -d "${TMPDIR:-/tmp}/regards-prepare-audit-simulator-bin.XXXXXX")"
call_log="$(mktemp "${TMPDIR:-/tmp}/regards-prepare-audit-simulator-calls.XXXXXX")"
cleanup() {
  rm -rf -- "$fake_bin"
  rm -f -- "$call_log"
}
trap cleanup EXIT

ln -s "$fixtures_directory/xcrun" "$fake_bin/xcrun"

no_match_output=""
if no_match_output="$(
  env \
    PATH="$fake_bin:$PATH" \
    PREPARE_AUDIT_SIMULATOR_FIXTURE="$fixtures_directory/no-match.json" \
    PREPARE_AUDIT_SIMULATOR_CALL_LOG="$call_log" \
    "$target" "iPhone 17 Pro" 2>&1
)"; then
  echo "FAIL: end-to-end run with no matching device unexpectedly succeeded" >&2
  echo "$no_match_output" >&2
  exit 1
fi

if ! grep -qF '::error::No available simulator named "iPhone 17 Pro" found' <<<"$no_match_output"; then
  echo "FAIL: end-to-end run did not emit the expected ::error:: line" >&2
  echo "$no_match_output" >&2
  exit 1
fi

if [[ -s "$call_log" ]]; then
  echo "FAIL: simctl boot/bootstatus/status_bar was invoked despite resolution failing" >&2
  cat "$call_log" >&2
  exit 1
fi

echo "PASS: prepare-audit-simulator picks the newest tie-free runtime and fails closed"
