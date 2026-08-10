#!/usr/bin/env bash

set -euo pipefail

# Runner-image dependency: the JSON parsing below uses the runner's system
# Ruby (no Gemfile pins a version).

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

# Overridable so scripts/tests/prepare-audit-simulator-tests.sh can drive the
# retry loop below with zero real sleeps.
retry_sleep_seconds="${PREPARE_AUDIT_SIMULATOR_RETRY_SLEEP:-15}"

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
# so this must pick the same one. Runtime identifiers end in a two-component
# version token (com.apple.CoreSimulator.SimRuntime.iOS-26-0) -- SimRuntime
# identifiers never carry a third numeric component, so patch releases share
# one: 26.3.1 and 26.3 both report as iOS-26-3. The match is anchored to
# that trailing `.iOS-<major>-<minor>` token (`\.iOS-(\d+)-(\d+)\z`) so an
# "iOS-N-N"-shaped substring anywhere else in a malformed key can't be
# mistaken for it.
#
# Ties at the newest version are a real, observed scenario, not a defensive
# hypothetical: two distinct installed runtimes can report the same
# identifier -- e.g. 26.4 build 23E244 and 26.4.1 build 23E254a both report
# as iOS-26-4, each with its own "iPhone 17 Pro" device and UDID. `max_by`
# would pick one of those arbitrarily and silently, so refuse instead and
# name every tied UDID and runtime id in the error -- an operator resolves
# it by deleting the stale runtime, which needs the UDID to find.
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
      version_match = runtime_id.match(/\.iOS-(\d+)-(\d+)\z/)
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
      described = tied.map { |c| "#{c[:udid]} on #{c[:runtime_id]}" }.join("; ")
      warn("::error::Multiple available simulators named #{name.inspect} tie at the newest iOS runtime: #{described}; refusing to pick one arbitrarily. Delete the stale runtime to resolve.")
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
#
# Require the UDID to actually look like one before it goes anywhere near
# $GITHUB_ENV: simctl UDIDs are always this shape, so a value that isn't
# means something upstream (a future edit to resolve_device, an
# unanticipated `simctl` output format) already went wrong, and the safety
# of appending it into a file GitHub Actions re-exports as shell environment
# should be obvious by inspection rather than assumed.
if [[ -n "${GITHUB_ENV:-}" ]]; then
  if [[ ! "$udid" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
    echo "::error::Resolved udid \"$udid\" is not UUID-shaped; refusing to write it into \$GITHUB_ENV" >&2
    exit 1
  fi
  echo "SIMULATOR_UDID=$udid" >>"$GITHUB_ENV"
fi

# `bootstatus -b` boots the device if it isn't already booted and then
# blocks until it finishes -- it is both the boot call and the wait
# mechanism, so there is no separate `simctl boot` call and no separate
# polling loop here.
#
# That "boot if needed" behavior is exactly why this must NOT be a plain
# `simctl boot` retried 3x: `boot` fails once the device has left the
# Shutdown state ("Unable to boot device in current state:
# Booting"/"Booted"), so a boot call that errors mid-transition would make
# every retry fail deterministically instead of recovering. `bootstatus -b`
# has no such failure mode -- retrying it is safe whether the previous
# attempt made no progress, left the device mid-boot, or actually finished.
#
# Same bounded-retry shape as the "Install iOS platform" step (ios-ci.yml's
# `xcodebuild -downloadPlatform iOS` loop): CoreSimulator boot failures on
# these runners are occasionally transient, and a bounded retry turns a
# flake into a pass instead of a job failure, without masking a genuinely
# broken simulator (which still fails after 3 attempts).
booted=0
for attempt in 1 2 3; do
  if xcrun simctl bootstatus "$udid" -b; then
    booted=1
    [[ "$attempt" -gt 1 ]] && echo "simctl bootstatus succeeded on attempt $attempt (after retries)"
    break
  fi
  echo "::warning::simctl bootstatus $udid -b failed on attempt $attempt; sleeping ${retry_sleep_seconds}s before retry"
  sleep "$retry_sleep_seconds"
done
if [[ "$booted" -ne 1 ]]; then
  echo "::error::xcrun simctl bootstatus $udid -b failed after 3 attempts" >&2
  exit 1
fi

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
