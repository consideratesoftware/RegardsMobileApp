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

# --- End-to-end cases: drive the full script (not --resolve-only) against a
# stub xcrun on PATH. Each case gets its own fake PATH dir and call log so
# they can't leak state into each other.

fake_bin="$(mktemp -d "${TMPDIR:-/tmp}/regards-prepare-audit-simulator-bin.XXXXXX")"
ln -s "$fixtures_directory/xcrun" "$fake_bin/xcrun"

end_to_end_tmp_files=()
cleanup() {
  rm -rf -- "$fake_bin"
  if [[ "${#end_to_end_tmp_files[@]}" -gt 0 ]]; then
    rm -f -- "${end_to_end_tmp_files[@]}"
  fi
}
trap cleanup EXIT

fresh_call_log() {
  local path
  path="$(mktemp "${TMPDIR:-/tmp}/regards-prepare-audit-simulator-calls.XXXXXX")"
  end_to_end_tmp_files+=("$path" "$path.bootstatus-attempts")
  echo "$path"
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

# Regression check for the exact bug this round fixed: `simctl boot` must
# never be called by this script (it fails deterministically on retry once
# the device leaves Shutdown; `bootstatus -b` replaces it). The stub treats
# a `boot` call as an unexpected invocation, so proving the full-script run
# below succeeds already covers this, but assert directly on a fixture where
# boot would have been the naive first move.
solo_call_log="$(fresh_call_log)"
if ! env \
  PATH="$fake_bin:$PATH" \
  PREPARE_AUDIT_SIMULATOR_FIXTURE="$fixtures_directory/single-device.json" \
  PREPARE_AUDIT_SIMULATOR_CALL_LOG="$solo_call_log" \
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
retry_call_log="$(fresh_call_log)"
retry_output=""
if ! retry_output="$(
  env \
    PATH="$fake_bin:$PATH" \
    PREPARE_AUDIT_SIMULATOR_FIXTURE="$fixtures_directory/single-device.json" \
    PREPARE_AUDIT_SIMULATOR_CALL_LOG="$retry_call_log" \
    PREPARE_AUDIT_SIMULATOR_BOOTSTATUS_FAIL_COUNT=1 \
    "$target" "iPhone 17 Pro" 2>&1
)"; then
  echo "FAIL: end-to-end run did not recover from a transient bootstatus failure" >&2
  echo "$retry_output" >&2
  exit 1
fi

bootstatus_call_count="$(grep -cE '^bootstatus SOLO-UDID -b$' "$retry_call_log" || true)"
if [[ "$bootstatus_call_count" -ne 2 ]]; then
  echo "FAIL: expected 2 bootstatus attempts (1 transient failure + 1 recovery), saw $bootstatus_call_count" >&2
  cat "$retry_call_log" >&2
  exit 1
fi
if ! grep -qE '^status_bar SOLO-UDID override ' "$retry_call_log"; then
  echo "FAIL: status_bar was never reached after the retry recovered" >&2
  cat "$retry_call_log" >&2
  exit 1
fi

# Success path: assert the call order (resolve -> bootstatus -> status_bar)
# and that SIMULATOR_UDID actually lands in $GITHUB_ENV for later workflow
# steps to pin their -destination to.
success_call_log="$(fresh_call_log)"
fake_github_env="$(mktemp "${TMPDIR:-/tmp}/regards-prepare-audit-simulator-env.XXXXXX")"
end_to_end_tmp_files+=("$fake_github_env")

if ! env \
  PATH="$fake_bin:$PATH" \
  PREPARE_AUDIT_SIMULATOR_FIXTURE="$fixtures_directory/single-device.json" \
  PREPARE_AUDIT_SIMULATOR_CALL_LOG="$success_call_log" \
  GITHUB_ENV="$fake_github_env" \
  "$target" "iPhone 17 Pro" >/dev/null 2>&1; then
  echo "FAIL: end-to-end success-path run unexpectedly failed" >&2
  exit 1
fi

expected_order="list devices available -j
bootstatus SOLO-UDID -b
status_bar SOLO-UDID override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100"
if [[ "$(cat "$success_call_log")" != "$expected_order" ]]; then
  echo "FAIL: call order was not resolve -> bootstatus -> status_bar" >&2
  cat "$success_call_log" >&2
  exit 1
fi

if ! grep -qF "SIMULATOR_UDID=SOLO-UDID" "$fake_github_env"; then
  echo "FAIL: SIMULATOR_UDID was not appended to \$GITHUB_ENV" >&2
  cat "$fake_github_env" >&2
  exit 1
fi

echo "PASS: prepare-audit-simulator picks the newest tie-free runtime, retries bootstatus, and fails closed"
