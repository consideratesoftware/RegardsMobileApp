#!/usr/bin/env bash

set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_directory/../.." && pwd)"
fixtures_directory="$script_directory/fixtures/domain-coverage"
gate="$repository_root/scripts/check-domain-coverage.sh"
fake_bin="$(mktemp -d "${TMPDIR:-/tmp}/regards-coverage-gate.XXXXXX")"
trap 'rm -rf -- "$fake_bin"' EXIT

ln -s "$fixtures_directory/xcrun" "$fake_bin/xcrun"

run_gate() {
  local fixture="$1"
  local minimum="$2"

  env \
    PATH="$fake_bin:$PATH" \
    DOMAIN_COVERAGE_FIXTURE="$fixtures_directory/$fixture" \
    DOMAIN_SOURCE_DIRECTORY="$fixtures_directory/source" \
    DOMAIN_COVERAGE_ZERO_LINE_FILES= \
    DOMAIN_COVERAGE_MIN="$minimum" \
    "$gate" "$fixtures_directory/$fixture"
}

expect_failure() {
  local label="$1"
  shift

  if "$@" >/dev/null 2>&1; then
    echo "FAIL: $label unexpectedly passed" >&2
    exit 1
  fi
}

expect_error_failure() {
  local label="$1"
  shift
  local failure_output

  if failure_output="$("$@" 2>&1)"; then
    echo "FAIL: $label unexpectedly passed" >&2
    exit 1
  fi

  if ! grep -q '^::error::' <<<"$failure_output"; then
    echo "FAIL: $label did not emit a GitHub error" >&2
    echo "$failure_output" >&2
    exit 1
  fi
}

run_gate valid.json 95 >/dev/null
expect_failure "below-threshold coverage" run_gate valid.json 95.01
expect_failure "minimum above 100" run_gate valid.json 150
expect_failure "negative minimum" run_gate valid.json -5
expect_failure "option-like minimum" run_gate valid.json --version
expect_failure "non-numeric minimum" run_gate valid.json invalid
expect_failure "missing Regards.app target" run_gate missing-app.json 95
expect_failure "missing Domain files" run_gate missing-domain.json 95
expect_failure "incomplete Domain file set" run_gate partial-domain.json 95
expect_failure "zero executable Domain lines" run_gate zero-domain.json 95
expect_error_failure "malformed coverage report" run_gate malformed.json 95
expect_failure \
  "missing result bundle" \
  env \
    PATH="$fake_bin:$PATH" \
    DOMAIN_SOURCE_DIRECTORY="$fixtures_directory/source" \
    DOMAIN_COVERAGE_ZERO_LINE_FILES= \
    DOMAIN_COVERAGE_MIN=95 \
    "$gate" "$fixtures_directory/missing.json"
expect_failure \
  "too many CLI arguments" \
  "$gate" "$fixtures_directory/valid.json" extra

echo "PASS: Domain coverage gate accepts the floor and fails closed"
