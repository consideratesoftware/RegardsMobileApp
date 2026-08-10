#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <device-name>" >&2
  exit 64
fi

device_name="$1"

# The accessibility-audit jobs were tripped by simulator system-UI
# intrusions: a "Ready for Apple Intelligence" onboarding notification
# overlaid the app mid-run and Apple's audit flagged its text as
# "Potentially inaccessible text" (iOS CI run 31346143276; the same class of
# intrusion produced a timeout at 8adeb0d on 2026-08-08). A rerun against an
# identical build passed, which means the finding was runner noise, not a
# product regression.
#
# `xcodebuild -destination "name=$device_name,..."` reuses whatever instance
# of that device macos-latest already has around, and CoreSimulator state
# (onboarding "seen" flags, queued notifications, Setup Assistant progress)
# persists on that instance across jobs. Erasing and rebooting it here gives
# every audit run a factory-fresh simulator instead of an unknown-age one.
# This narrows the window for system banners; it cannot guarantee they never
# fire, so it is a probability reduction, not a fix for the underlying
# Apple Intelligence bug.
#
# The status_bar override is a separate, unrelated hardening: it pins the
# time/network/battery readout to fixed values so no real-runner glyph in the
# status bar (a spinning "searching" wifi icon, an actual low-battery state)
# can itself become an audit finding.

# A runner can hold more than one iOS runtime (each `xcodebuild
# -downloadPlatform iOS` call before this step may add one), and each
# runtime has its own "iPhone 17 Pro" device. xcodebuild's destination
# (`name=iPhone 17 Pro,OS=latest`) resolves to the newest installed runtime,
# so this must pick the same one -- an unordered pick could erase and boot a
# device xcodebuild never touches, leaving the real target unhardened with
# no error to signal it. Runtime identifiers encode the version
# (com.apple.CoreSimulator.SimRuntime.iOS-18-0), so parse and compare that
# instead of relying on hash/array ordering.
resolved="$(xcrun simctl list devices available -j | ruby -rjson -e '
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

  chosen = candidates.max_by { |c| c[:version] }
  puts "#{chosen[:udid]} #{chosen[:runtime_id]}"
' -- "$device_name")"

udid="$(cut -d" " -f1 <<<"$resolved")"
runtime_id="$(cut -d" " -f2 <<<"$resolved")"

echo "Resolved \"$device_name\" to $udid on $runtime_id (newest available runtime)"

# Shutdown is a no-op error if the device is already shut down (the common
# case on a fresh runner); erase requires the Shutdown state either way.
xcrun simctl shutdown "$udid" 2>/dev/null || true
xcrun simctl erase "$udid"
xcrun simctl boot "$udid"
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

echo "Booted a fresh \"$device_name\" ($udid on $runtime_id) with a normalized status bar."
