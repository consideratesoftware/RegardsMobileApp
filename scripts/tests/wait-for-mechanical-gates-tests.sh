#!/usr/bin/env bash

# Drives scripts/wait-for-mechanical-gates.sh against a fake `gh` that replays
# a scripted sequence of `gh pr checks --json` payloads, one per invocation.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
subject="$repo_root/scripts/wait-for-mechanical-gates.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
mkdir -p "$work_dir/bin"

# Fake gh: prints the Nth payload from $FIXTURE_DIR, N tracked in a counter file.
cat > "$work_dir/bin/gh" <<'FAKE'
#!/usr/bin/env bash
counter_file="$FIXTURE_DIR/.calls"
count="$(cat "$counter_file" 2>/dev/null || echo 0)"
count=$((count + 1))
echo "$count" > "$counter_file"
payload="$FIXTURE_DIR/$count.json"
[[ -f "$payload" ]] || payload="$(ls "$FIXTURE_DIR"/[0-9]*.json | sort -V | tail -1)"
cat "$payload"
FAKE
chmod +x "$work_dir/bin/gh"

# Must not rely on shared state: callers use $(new_fixture_dir), which runs in
# a subshell, so any counter incremented here would be discarded.
new_fixture_dir() {
  mktemp -d "$work_dir/fixture-XXXXXX"
}

run_subject() {
  local dir="$1"
  PATH="$work_dir/bin:$PATH" \
  FIXTURE_DIR="$dir" \
  POLL_SECONDS=0 \
  TIMEOUT_SECONDS="${TIMEOUT_OVERRIDE:-3600}" \
    "$subject" 23
}

failures=0
expect_pass() {
  local label="$1" dir="$2"
  if output="$(run_subject "$dir" 2>&1)"; then
    echo "PASS: $label"
  else
    echo "FAIL: $label (expected exit 0)"
    echo "$output" | sed 's/^/    /'
    failures=$((failures + 1))
  fi
}
expect_fail() {
  local label="$1" dir="$2" needle="$3"
  if output="$(run_subject "$dir" 2>&1)"; then
    echo "FAIL: $label (expected non-zero exit)"
    echo "$output" | sed 's/^/    /'
    failures=$((failures + 1))
  elif ! grep -qF "$needle" <<< "$output"; then
    echo "FAIL: $label (missing \"$needle\")"
    echo "$output" | sed 's/^/    /'
    failures=$((failures + 1))
  else
    echo "PASS: $label"
  fi
}

all_green='[{"name":"Build","bucket":"pass"},{"name":"SwiftLint","bucket":"pass"},{"name":"review","bucket":"pending"}]'
one_pending='[{"name":"Build","bucket":"pending"},{"name":"SwiftLint","bucket":"pass"},{"name":"review","bucket":"pending"}]'
one_red='[{"name":"Build","bucket":"fail"},{"name":"SwiftLint","bucket":"pass"},{"name":"review","bucket":"pending"}]'
cancelled='[{"name":"Build","bucket":"cancel"},{"name":"review","bucket":"pending"}]'
only_self='[{"name":"review","bucket":"pending"}]'
late_arrival='[{"name":"Build","bucket":"pass"},{"name":"SwiftLint","bucket":"pass"},{"name":"Accessibility audit","bucket":"pending"},{"name":"review","bucket":"pending"}]'

d="$(new_fixture_dir)"; echo "$all_green" > "$d/1.json"; echo "$all_green" > "$d/2.json"
expect_pass "passes once a stable green sibling set is seen twice" "$d"

d="$(new_fixture_dir)"; echo "$one_pending" > "$d/1.json"; echo "$one_pending" > "$d/2.json"
echo "$all_green" > "$d/3.json"; echo "$all_green" > "$d/4.json"
expect_pass "waits out a pending sibling, then passes" "$d"

d="$(new_fixture_dir)"; echo "$one_red" > "$d/1.json"
expect_fail "stops on a failed sibling" "$d" "Red baseline: Build"

d="$(new_fixture_dir)"; echo "$cancelled" > "$d/1.json"
expect_fail "stops on a cancelled sibling" "$d" "Red baseline: Build"

d="$(new_fixture_dir)"; echo "$one_pending" > "$d/1.json"
TIMEOUT_OVERRIDE=0 expect_fail "times out while a sibling stays pending" "$d" "Timed out"

d="$(new_fixture_dir)"; echo "$only_self" > "$d/1.json"
TIMEOUT_OVERRIDE=0 expect_fail "never treats a review-only check set as complete" "$d" "Timed out"

# The first poll shows two green siblings; a third check appears afterwards.
# Without the stability rule this would exit 0 before the audit even started.
d="$(new_fixture_dir)"; echo "$all_green" > "$d/1.json"; echo "$late_arrival" > "$d/2.json"
TIMEOUT_OVERRIDE=0 expect_fail "does not pass on a sibling set that is still growing" "$d" "Timed out"

d="$(new_fixture_dir)"; echo '' > "$d/1.json"
TIMEOUT_OVERRIDE=0 expect_fail "survives gh returning nothing" "$d" "Timed out"

if (( failures > 0 )); then
  echo "$failures test(s) failed." >&2
  exit 1
fi
