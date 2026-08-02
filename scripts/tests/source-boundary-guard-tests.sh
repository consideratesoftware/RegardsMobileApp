#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
network_guard="$repo_root/scripts/check-no-network.sh"
domain_guard="$repo_root/scripts/check-domain-purity.sh"
fixture_root="$(mktemp -d)"

cleanup() {
  rm -rf "$fixture_root"
}
trap cleanup EXIT

mkdir -p "$fixture_root/ios/Regards/Domain"
printf 'struct CleanDomainValue {}\n' \
  > "$fixture_root/ios/Regards/Domain/CleanDomainValue.swift"

"$network_guard" "$fixture_root/ios/Regards" >/dev/null
"$domain_guard" "$fixture_root/ios/Regards/Domain" >/dev/null

printf 'let session = URLSession.shared\n' \
  > "$fixture_root/ios/Regards/NetworkRegression.swift"
if "$network_guard" "$fixture_root/ios/Regards" >/dev/null 2>&1; then
  echo "FAIL: URLSession regression was accepted" >&2
  exit 1
fi
rm -f "$fixture_root/ios/Regards/NetworkRegression.swift"

printf 'let connection = NSURLConnection()\n' \
  > "$fixture_root/ios/Regards/NetworkRegression.swift"
if "$network_guard" "$fixture_root/ios/Regards" >/dev/null 2>&1; then
  echo "FAIL: NSURLConnection regression was accepted" >&2
  exit 1
fi
rm -f "$fixture_root/ios/Regards/NetworkRegression.swift"

printf 'let socket = CFSocketCreate(nil, 0, 0, 0, 0, nil, nil)\n' \
  > "$fixture_root/ios/Regards/NetworkRegression.swift"
if "$network_guard" "$fixture_root/ios/Regards" >/dev/null 2>&1; then
  echo "FAIL: CFSocket regression was accepted" >&2
  exit 1
fi
rm -f "$fixture_root/ios/Regards/NetworkRegression.swift"

printf 'import Network\n' \
  > "$fixture_root/ios/Regards/Domain/PlatformRegression.swift"
if "$domain_guard" "$fixture_root/ios/Regards/Domain" >/dev/null 2>&1; then
  echo "FAIL: Network import regression was accepted" >&2
  exit 1
fi

printf '@preconcurrency import SwiftUI\n' \
  > "$fixture_root/ios/Regards/Domain/PlatformRegression.swift"
if "$domain_guard" "$fixture_root/ios/Regards/Domain" >/dev/null 2>&1; then
  echo "FAIL: preconcurrency import regression was accepted" >&2
  exit 1
fi

printf 'import class Contacts.CNContact\n' \
  > "$fixture_root/ios/Regards/Domain/PlatformRegression.swift"
if "$domain_guard" "$fixture_root/ios/Regards/Domain" >/dev/null 2>&1; then
  echo "FAIL: selective platform import regression was accepted" >&2
  exit 1
fi

ruby - "$repo_root/.github/workflows/guards.yml" \
  "$repo_root/.github/workflows/claude-pr-review.yml" <<'RUBY'
require "yaml"

guards = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: false).fetch("jobs")
review = YAML.safe_load(File.read(ARGV.fetch(1)), aliases: false).fetch("jobs")

privacy_runs = guards.fetch("privacy-grep").fetch("steps").map { |step| step["run"] }.compact
domain_runs = guards.fetch("domain-purity-grep").fetch("steps").map { |step| step["run"] }.compact
preflight_runs = review.fetch("preflight").fetch("steps").map { |step| step["run"] }.compact

raise "canonical privacy job does not call the shared guard" unless privacy_runs == ["scripts/check-no-network.sh"]
raise "canonical Domain job does not call the shared guard" unless domain_runs == ["scripts/check-domain-purity.sh"]

preflight = preflight_runs.join("\n")
privacy_call_is_bound = preflight.scan("scripts/check-no-network.sh").length == 1 &&
  preflight.include?('"$RUNNER_TEMP/pr-tree/ios/Regards"')
domain_call_is_bound = preflight.scan("scripts/check-domain-purity.sh").length == 1 &&
  preflight.include?('"$RUNNER_TEMP/pr-tree/ios/Regards/Domain"')

raise "trusted preflight does not call the shared privacy guard" unless privacy_call_is_bound
raise "trusted preflight does not call the shared Domain guard" unless domain_call_is_bound
RUBY

echo "PASS: source-boundary guards reject regressions and share one implementation"
