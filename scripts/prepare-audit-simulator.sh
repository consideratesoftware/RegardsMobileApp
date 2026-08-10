#!/usr/bin/env bash

set -euo pipefail

# Runner-image dependencies: the JSON parsing below uses the runner's system
# Ruby (no Gemfile pins a version), and this script assumes `env bash` on the
# runner's PATH resolves to bash >= 4, not macOS's preinstalled bash 3.2.

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 <device-name> [--resolve-only]" >&2
  exit 64
fi

device_name="$1"
resolve_only=0
if [[ $# -eq 2 ]]; then
  if [[ "$2" != "--resolve-only" ]]; then
    echo "usage: $0 <device-name> [--resolve-only]" >&2
    exit 64
  fi
  resolve_only=1
fi

# The accessibility-audit jobs were tripped by simulator system-UI
# intrusions: a "Ready for Apple Intelligence" onboarding notification
# overlaid the app mid-run and Apple's audit flagged its text as
# "Potentially inaccessible text" (iOS CI run 31346143276); the same class of
# intrusion produced a timeout at 8adeb0d on 2026-08-08. A rerun against an
# identical build passed both times, which means the finding was runner
# noise, not a product regression.
#
# `macos-latest` jobs are fresh ephemeral VMs -- CoreSimulator state does not
# persist across jobs, so there is no "stale simulator" to clean up, and
# `simctl erase` is not part of this script. Erase wipes the data volume that
# holds first-run "seen" flags; on a VM that never saw a first run, that does
# nothing for the banner class, and on one that already has state it can
# re-arm first-run onboarding nags instead of suppressing them. No documented
# simctl or `defaults` toggle disables the Apple Intelligence banner itself
# (checked; none found), so this script cannot prevent that class of
# intrusion. What it does instead:
#
#   1. Resolve the target device to one exact UDID up front (below) and have
#      every later xcodebuild invocation pin its `-destination` to
#      `platform=iOS Simulator,id=<udid>` instead of `name=...,OS=latest`.
#      That makes "the device this script prepared" and "the device the test
#      run uses" the same device by construction -- no separate
#      cross-check needed, and no risk of the two destination strings
#      resolving differently.
#   2. Normalize the status bar (below) so a real runner glyph -- a spinning
#      "searching" wifi icon, an actual low-battery state -- can't itself
#      become a separate audit finding.
#   3. Bound the boot with a timeout (retry loop below, plus
#      `timeout-minutes` on the calling workflow step) so a hang in this
#      class -- the 8adeb0d timeout -- fails fast and legibly instead of
#      running out the clock.
#
# The system-banner intrusion class remains possible after all of the above.
# When it recurs, rerun the exact failed job and triage per
# ios/docs/accessibility.md's "Known system-UI audit interruption" section --
# that response is unchanged by this script.

# A runner can hold more than one iOS runtime (each `xcodebuild
# -downloadPlatform iOS` call before this step may add one), and each
# runtime has its own "iPhone 17 Pro" device. xcodebuild's destination
# (`name=iPhone 17 Pro,OS=latest`) resolves to the newest installed runtime,
# so this must pick the same one. Runtime identifiers encode the version
# (com.apple.CoreSimulator.SimRuntime.iOS-18-0), so parse and compare that
# instead of relying on hash/array ordering. If two available devices with
# the same name tie at the newest version, refuse to guess: `max_by` would
# pick one arbitrarily, and a silent arbitrary pick is exactly the kind of
# heuristic divergence this script exists to avoid.
#
# The selection logic reads the `simctl list devices available -j` JSON from
# stdin rather than shelling out itself, so `--resolve-only` can drive it
# from a fixture in scripts/tests/prepare-audit-simulator-tests.sh without
# touching a real simulator.
resolve_device() {
  ruby -rjson -e '
    data = JSON.parse(STDIN.read)
    name = ARGV.fetch(0)

    candidates = data.fetch("devices").flat_map do |runtime_id, devices|
      version_match = runtime_id.match(/iOS-(\d+)-(\d+)/)
      next [] unless version_match

      version = [version_match[1].to_i, version_match[2].to_i]
      devices
        .select { |d| d["name"] == name && d["isAvailable"] }
        .map { |d| { udid: d.fetch("udid"), runtime_id: runtime_id, version: version } }
    end

    if candidates.empty?
      warn("::error::No available simulator named #{name.inspect} found")
      exit 1
    end

    max_version = candidates.map { |c| c[:version] }.max
    tied = candidates.select { |c| c[:version] == max_version }
    if tied.length > 1
      runtimes = tied.map { |c| c[:runtime_id] }.join(", ")
      warn("::error::Multiple available simulators named #{name.inspect} tie at the newest iOS runtime (#{runtimes}); refusing to pick one arbitrarily")
      exit 1
    end

    chosen = tied.first
    puts "#{chosen[:udid]} #{chosen[:runtime_id]}"
  ' -- "$device_name"
}

if [[ "$resolve_only" -eq 1 ]]; then
  resolved="$(resolve_device)"
else
  resolved="$(xcrun simctl list devices available -j | resolve_device)"
fi

udid="$(cut -d" " -f1 <<<"$resolved")"
runtime_id="$(cut -d" " -f2 <<<"$resolved")"

if [[ "$resolve_only" -eq 1 ]]; then
  echo "$udid $runtime_id"
  exit 0
fi

echo "Resolved \"$device_name\" to $udid on $runtime_id (newest available runtime)"

# Publish the resolved UDID as a job-scoped environment variable so the
# workflow's later xcodebuild steps can pin `-destination
# platform=iOS Simulator,id=$SIMULATOR_UDID` to this exact device instead of
# re-resolving `name=...,OS=latest` and risking a different answer.
if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "SIMULATOR_UDID=$udid" >>"$GITHUB_ENV"
fi

# Boot with the same bounded-retry shape as the "Install iOS platform" step
# (ios-ci.yml's `xcodebuild -downloadPlatform iOS` loop): CoreSimulator boot
# failures on these runners are occasionally transient, and a bounded retry
# turns a flake into a pass instead of a job failure, without masking a
# genuinely broken simulator (which still fails after 3 attempts).
booted=0
for attempt in 1 2 3; do
  if xcrun simctl boot "$udid"; then
    booted=1
    [[ "$attempt" -gt 1 ]] && echo "simctl boot succeeded on attempt $attempt (after retries)"
    break
  fi
  echo "::warning::simctl boot $udid failed on attempt $attempt; sleeping 15s before retry"
  sleep 15
done
if [[ "$booted" -ne 1 ]]; then
  echo "::error::xcrun simctl boot $udid failed after 3 attempts" >&2
  exit 1
fi

# `bootstatus -b` is the wait mechanism: it blocks until the device finishes
# booting (or times out on its own), so there is no separate polling loop
# here.
xcrun simctl bootstatus "$udid" -b

xcrun simctl status_bar "$udid" override \
  --time "9:41" \
  --dataNetwork wifi \
  --wifiMode active \
  --wifiBars 3 \
  --cellularMode active \
  --cellularBars 4 \
  --batteryState charged \
  --batteryLevel 100

echo "Booted \"$device_name\" ($udid on $runtime_id) with a normalized status bar."
