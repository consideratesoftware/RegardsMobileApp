#!/usr/bin/env bash
# Run the RegardsAccessibilityTests audit suite N times locally to catch
# probabilistic flakes before pushing.
#
# Usage:
#   ios/scripts/audit-stress.sh           # default 5 runs
#   ios/scripts/audit-stress.sh 3         # custom run count
#
# Override the simulator destination via SIMULATOR_DESTINATION:
#   SIMULATOR_DESTINATION='platform=iOS Simulator,name=iPhone 17 Pro' \
#     ios/scripts/audit-stress.sh
#
# Exits non-zero on any audit failure so this is safe to wire into a
# pre-push hook. Builds once, then test-without-building 5x to keep
# total runtime under ~5 min on a recent Mac.

set -euo pipefail
set -o pipefail

# Always run from the ios/ directory regardless of where the user invoked us.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

RUNS="${1:-5}"
DESTINATION="${SIMULATOR_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro}"
SCHEME="Regards"
PROJECT="Regards.xcodeproj"

if ! [[ "$RUNS" =~ ^[0-9]+$ ]] || [ "$RUNS" -lt 1 ]; then
  echo "error: expected a positive integer run count, got '$RUNS'" >&2
  exit 2
fi

# xcbeautify is optional. If missing, fall back to raw xcodebuild output.
if command -v xcbeautify >/dev/null 2>&1; then
  PIPE='xcbeautify --quiet'
else
  PIPE='cat'
fi

echo "==> Building accessibility test bundle once (destination: $DESTINATION)"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -configuration Debug \
  -only-testing:RegardsAccessibilityTests \
  -onlyUsePackageVersionsFromResolvedFile \
  build-for-testing \
  | eval $PIPE

failed=0
for run in $(seq 1 "$RUNS"); do
  echo
  echo "==> Audit run $run/$RUNS"
  if xcodebuild \
      -project "$PROJECT" \
      -scheme "$SCHEME" \
      -destination "$DESTINATION" \
      -configuration Debug \
      -only-testing:RegardsAccessibilityTests \
      -onlyUsePackageVersionsFromResolvedFile \
      test-without-building \
      | eval $PIPE
  then
    echo "    pass"
  else
    failed=$((failed + 1))
    echo "    FAIL"
  fi
done

echo
if [ "$failed" -eq 0 ]; then
  echo "✅ All $RUNS audit runs passed."
  exit 0
else
  echo "❌ $failed of $RUNS audit runs failed."
  exit 1
fi
