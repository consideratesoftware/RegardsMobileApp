#!/usr/bin/env bash

set -euo pipefail

if [[ $# -gt 1 ]]; then
  echo "usage: $0 [xcresult-path]" >&2
  exit 64
fi

result_bundle="${1:-ios/build/RegardsTests.xcresult}"
minimum="${DOMAIN_COVERAGE_MIN:-95}"

if [[ ! -e "$result_bundle" ]]; then
  echo "::error::Coverage result bundle does not exist: $result_bundle" >&2
  exit 1
fi

xcrun xccov view --report --json "$result_bundle" | ruby -rjson -e '
  def fail_gate(message)
    warn("::error::#{message}")
    exit(1)
  end

  begin
    minimum = Float(ARGV.fetch(0))
  rescue ArgumentError
    fail_gate("Domain coverage minimum must be numeric")
  end
  fail_gate("Domain coverage minimum must be between 0 and 100") unless (0.0..100.0).cover?(minimum)

  report = JSON.parse(STDIN.read)
  target = report.fetch("targets").find { |candidate| candidate.fetch("name") == "Regards.app" }
  fail_gate("Regards.app coverage target is missing") unless target

  files = target.fetch("files").select do |file|
    file.fetch("path", "").include?("/ios/Regards/Domain/")
  end
  fail_gate("Domain coverage files are missing") if files.empty?

  covered = files.sum { |file| file.fetch("coveredLines") }
  executable = files.sum { |file| file.fetch("executableLines") }
  fail_gate("Domain executable-line count is zero") if executable.zero?

  percentage = covered.fdiv(executable) * 100
  puts format(
    "Domain coverage: %d/%d lines (%.2f%%); required %.2f%%",
    covered,
    executable,
    percentage,
    minimum
  )

  if percentage < minimum
    warn format("::error::Domain coverage %.2f%% is below the %.2f%% floor", percentage, minimum)
    exit 1
  end
' "$minimum"
