#!/usr/bin/env bash

set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_directory/../.." && pwd)"
fixtures_directory="$script_directory/fixtures/prepare-audit-simulator"
target="$repository_root/scripts/prepare-audit-simulator.sh"
single_device_udid="11111111-2222-3333-4444-555555555555"

expect_resolve() {
  local label="$1"
  local fixture="$2"
  local expected_udid="$3"
  local raw_output
  local actual

  # Guarded (not a bare `actual="$(...)"` under `set -e`): a regression that
  # makes resolution fail here would otherwise kill this whole test script
  # via errexit instead of reporting a clean FAIL line.
  if ! raw_output="$("$target" "iPhone 17 Pro" --resolve-only <"$fixtures_directory/$fixture" 2>&1)"; then
    echo "FAIL: $label unexpectedly failed to resolve" >&2
    echo "$raw_output" >&2
    exit 1
  fi

  actual="$(cut -d" " -f1 <<<"$raw_output")"
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

expect_usage_error() {
  local label="$1"
  shift
  local output
  local status

  set +e
  output="$("$target" "$@" 2>&1)"
  status=$?
  set -e

  if [[ "$status" -ne 64 ]]; then
    echo "FAIL: $label expected exit 64, got $status" >&2
    echo "$output" >&2
    exit 1
  fi

  if ! grep -qF "usage: $target <device-name> [--resolve-only]" <<<"$output"; then
    echo "FAIL: $label did not print the usage message" >&2
    echo "$output" >&2
    exit 1
  fi
}

# (a) The newest iOS runtime wins even when neither hash-iteration order nor
# a naive string comparison of the runtime identifiers would give the right
# answer (see the fixture's deliberate ordering).
expect_resolve "newest runtime wins over hash order and string order" \
  multiple-runtimes.json NEW-UDID

# (b) An isAvailable:false device in the newest runtime is skipped in favor
# of an available device in an older runtime.
expect_resolve "unavailable newest runtime falls back to an older one" \
  unavailable-newest.json FALLBACK-UDID

# (c) tvOS, watchOS, and a malformed (non-CoreSimulator) runtime key holding
# a same-named device are all ignored, and so is a key that would have
# matched the old *unanchored* `iOS-(\d+)-(\d+)` regex (iOS-99-0-experimental
# has "iOS-99-0" as a substring but isn't the trailing `.iOS-<major>-<minor>`
# token) -- proving the anchor actually excludes it rather than merely
# happening not to be exercised.
expect_resolve "non-iOS, malformed, and anchor-defeating runtime keys are ignored" \
  non-ios-runtimes.json REAL-UDID

# (d) --resolve-only alone: no matching device fails with the expected
# ::error:: line.
expect_resolve_failure "no matching device fails closed" \
  no-match.json \
  '::error::No available simulator named "iPhone 17 Pro" found'

# (e) Two available devices tied at the newest iOS runtime fail loudly
# instead of picking one arbitrarily (the exact risk of `Array#max_by`), and
# the error names both tied UDIDs so an operator can tell which runtime to
# delete.
expect_resolve_failure "a tie at the newest runtime refuses to guess" \
  tied-newest-runtime.json \
  '::error::Multiple available simulators named "iPhone 17 Pro" tie at the newest iOS runtime: TIED-A-UDID on com.apple.CoreSimulator.SimRuntime.iOS-26-0; TIED-B-UDID on com.apple.CoreSimulator.SimRuntime.iOS-26-0'

# (f) CLI usage errors: zero arguments, too many arguments, and an
# unrecognized second argument all exit 64 with the usage message.
expect_usage_error "zero arguments"
expect_usage_error "too many arguments" "iPhone 17 Pro" --resolve-only extra
expect_usage_error "unrecognized second argument" "iPhone 17 Pro" --bogus-flag

# --- End-to-end cases: drive the full script (not --resolve-only) against a
# stub xcrun on PATH. All temp files live under one scratch directory removed
# wholesale in cleanup -- a per-call array populated inside `fresh_call_log`
# would be mutated inside the command-substitution subshell that captures its
# return value and never be visible to the parent shell's trap.

fake_bin="$(mktemp -d "${TMPDIR:-/tmp}/regards-prepare-audit-simulator-bin.XXXXXX")"
ln -s "$fixtures_directory/xcrun" "$fake_bin/xcrun"

scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/regards-prepare-audit-simulator-scratch.XXXXXX")"
cleanup() {
  rm -rf -- "$fake_bin" "$scratch_dir"
}
trap cleanup EXIT

fresh_call_log() {
  mktemp "$scratch_dir/calls.XXXXXX"
}

# (d) End to end: a missing device is proven to fail *before* any
# bootstatus/status_bar call -- the regression a future edit could introduce
# by moving code above the resolution step. `list` itself still runs (that
# is how the fixture gets read), so this checks for the absence of
# bootstatus/status_bar specifically, not an empty log.
no_match_call_log="$(fresh_call_log)"
no_match_output=""
if no_match_output="$(
  env \
    PATH="$fake_bin:$PATH" \
    PREPARE_AUDIT_SIMULATOR_FIXTURE="$fixtures_directory/no-match.json" \
    PREPARE_AUDIT_SIMULATOR_CALL_LOG="$no_match_call_log" \
    PREPARE_AUDIT_SIMULATOR_RETRY_SLEEP=0 \
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

if grep -qE '^(bootstatus|status_bar) ' "$no_match_call_log"; then
  echo "FAIL: simctl bootstatus/status_bar was invoked despite resolution failing" >&2
  cat "$no_match_call_log" >&2
  exit 1
fi

# Regression check for the boot/bootstatus fix: `simctl boot` must never be
# called by this script (it fails deterministically on retry once the device
# leaves Shutdown; `bootstatus -b` replaces it). The stub treats a `boot`
# call as an unexpected invocation and fails the process on its own, so a
# successful run here already covers this; assert directly too.
solo_call_log="$(fresh_call_log)"
if ! env \
  PATH="$fake_bin:$PATH" \
  PREPARE_AUDIT_SIMULATOR_FIXTURE="$fixtures_directory/single-device.json" \
  PREPARE_AUDIT_SIMULATOR_CALL_LOG="$solo_call_log" \
  PREPARE_AUDIT_SIMULATOR_RETRY_SLEEP=0 \
  "$target" "iPhone 17 Pro" >/dev/null 2>&1; then
  echo "FAIL: end-to-end run with one available device unexpectedly failed" >&2
  exit 1
fi
if grep -q '^boot ' "$solo_call_log"; then
  echo "FAIL: a bare simctl boot call was made" >&2
  cat "$solo_call_log" >&2
  exit 1
fi

# Retry recovery: bootstatus fails transiently once (the shape of the real
# CoreSimulator "Unable to boot device in current state: Booting" error),
# and the loop must retry and still reach status_bar instead of giving up.
# PREPARE_AUDIT_SIMULATOR_RETRY_SLEEP=0 skips the real 15s backoff.
retry_call_log="$(fresh_call_log)"
retry_output=""
if ! retry_output="$(
  env \
    PATH="$fake_bin:$PATH" \
    PREPARE_AUDIT_SIMULATOR_FIXTURE="$fixtures_directory/single-device.json" \
    PREPARE_AUDIT_SIMULATOR_CALL_LOG="$retry_call_log" \
    PREPARE_AUDIT_SIMULATOR_BOOTSTATUS_FAIL_COUNT=1 \
    PREPARE_AUDIT_SIMULATOR_RETRY_SLEEP=0 \
    "$target" "iPhone 17 Pro" 2>&1
)"; then
  echo "FAIL: end-to-end run did not recover from a transient bootstatus failure" >&2
  echo "$retry_output" >&2
  exit 1
fi

retry_bootstatus_call_count="$(grep -cE "^bootstatus $single_device_udid -b\$" "$retry_call_log" || true)"
if [[ "$retry_bootstatus_call_count" -ne 2 ]]; then
  echo "FAIL: expected 2 bootstatus attempts (1 transient failure + 1 recovery), saw $retry_bootstatus_call_count" >&2
  cat "$retry_call_log" >&2
  exit 1
fi
if ! grep -qE "^status_bar $single_device_udid override " "$retry_call_log"; then
  echo "FAIL: status_bar was never reached after the retry recovered" >&2
  cat "$retry_call_log" >&2
  exit 1
fi

# BLOCKER coverage: exhaust all 3 bootstatus attempts and confirm the script
# fails closed -- non-zero exit, the "failed after 3 attempts" ::error::
# line, exactly 3 bootstatus calls (no fourth attempt), and status_bar is
# never reached. PREPARE_AUDIT_SIMULATOR_RETRY_SLEEP=0 keeps this at
# effectively zero cost instead of the real 2x15s backoff.
exhaustion_call_log="$(fresh_call_log)"
exhaustion_output=""
if exhaustion_output="$(
  env \
    PATH="$fake_bin:$PATH" \
    PREPARE_AUDIT_SIMULATOR_FIXTURE="$fixtures_directory/single-device.json" \
    PREPARE_AUDIT_SIMULATOR_CALL_LOG="$exhaustion_call_log" \
    PREPARE_AUDIT_SIMULATOR_BOOTSTATUS_FAIL_COUNT=3 \
    PREPARE_AUDIT_SIMULATOR_RETRY_SLEEP=0 \
    "$target" "iPhone 17 Pro" 2>&1
)"; then
  echo "FAIL: end-to-end run with 3 consecutive bootstatus failures unexpectedly succeeded" >&2
  echo "$exhaustion_output" >&2
  exit 1
fi

if ! grep -qF "::error::xcrun simctl bootstatus $single_device_udid -b failed after 3 attempts" <<<"$exhaustion_output"; then
  echo "FAIL: exhaustion run did not emit the expected ::error:: line" >&2
  echo "$exhaustion_output" >&2
  exit 1
fi

exhaustion_bootstatus_call_count="$(grep -cE "^bootstatus $single_device_udid -b\$" "$exhaustion_call_log" || true)"
if [[ "$exhaustion_bootstatus_call_count" -ne 3 ]]; then
  echo "FAIL: expected exactly 3 bootstatus attempts before giving up, saw $exhaustion_bootstatus_call_count" >&2
  cat "$exhaustion_call_log" >&2
  exit 1
fi

if grep -qE '^status_bar ' "$exhaustion_call_log"; then
  echo "FAIL: status_bar was reached despite bootstatus exhausting all 3 attempts" >&2
  cat "$exhaustion_call_log" >&2
  exit 1
fi

# Success path: assert the call order (resolve -> bootstatus -> status_bar)
# and that SIMULATOR_UDID lands in $GITHUB_ENV exactly once for later
# workflow steps to pin their -destination to.
success_call_log="$(fresh_call_log)"
fake_github_env="$(mktemp "$scratch_dir/env.XXXXXX")"

if ! env \
  PATH="$fake_bin:$PATH" \
  PREPARE_AUDIT_SIMULATOR_FIXTURE="$fixtures_directory/single-device.json" \
  PREPARE_AUDIT_SIMULATOR_CALL_LOG="$success_call_log" \
  PREPARE_AUDIT_SIMULATOR_RETRY_SLEEP=0 \
  GITHUB_ENV="$fake_github_env" \
  "$target" "iPhone 17 Pro" >/dev/null 2>&1; then
  echo "FAIL: end-to-end success-path run unexpectedly failed" >&2
  exit 1
fi

expected_order="list devices available -j
bootstatus $single_device_udid -b
status_bar $single_device_udid override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100"
if [[ "$(cat "$success_call_log")" != "$expected_order" ]]; then
  echo "FAIL: call order was not resolve -> bootstatus -> status_bar" >&2
  cat "$success_call_log" >&2
  exit 1
fi

github_env_udid_count="$(grep -cF "SIMULATOR_UDID=$single_device_udid" "$fake_github_env" || true)"
if [[ "$github_env_udid_count" -ne 1 ]]; then
  echo "FAIL: expected exactly one SIMULATOR_UDID line in \$GITHUB_ENV, saw $github_env_udid_count" >&2
  cat "$fake_github_env" >&2
  exit 1
fi

echo "PASS: prepare-audit-simulator picks the newest tie-free runtime, retries and fails closed on bootstatus, and validates its usage and GITHUB_ENV output"
