#!/usr/bin/env bash

set -euo pipefail

if [[ $# -gt 1 ]]; then
  echo "usage: $0 [xcresult-path]" >&2
  exit 64
fi

result_bundle="${1:-ios/build/RegardsTests.xcresult}"
minimum="${DOMAIN_COVERAGE_MIN:-95}"
script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_directory/.." && pwd)"
domain_directory="${DOMAIN_SOURCE_DIRECTORY:-$repository_root/ios/Regards/Domain}"
zero_executable_files="${DOMAIN_COVERAGE_ZERO_LINE_FILES-PriorityTier.swift}"

if [[ ! -e "$result_bundle" ]]; then
  echo "::error::Coverage result bundle does not exist: $result_bundle" >&2
  exit 1
fi

if [[ ! -d "$domain_directory" ]]; then
  echo "::error::Domain source directory does not exist: $domain_directory" >&2
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

  begin
    report = JSON.parse(STDIN.read)
  rescue JSON::ParserError
    fail_gate("Coverage report is not valid JSON")
  end
  fail_gate("Coverage report root is not an object") unless report.is_a?(Hash)

  targets = report["targets"]
  fail_gate("Coverage report targets are missing") unless targets.is_a?(Array)

  target = targets.find { |candidate| candidate["name"] == "Regards.app" }
  fail_gate("Regards.app coverage target is missing") unless target

  target_files = target["files"]
  fail_gate("Regards.app coverage files are missing") unless target_files.is_a?(Array)

  domain_marker = "/ios/Regards/Domain/"
  files = target_files.select do |file|
    file.fetch("path", "").include?(domain_marker)
  end
  fail_gate("Domain coverage files are missing") if files.empty?

  domain_directory = File.expand_path(ARGV.fetch(1))
  expected_files = Dir.glob(File.join(domain_directory, "**", "*.swift"))
    .select { |path| File.file?(path) }
    .map { |path| path.delete_prefix("#{domain_directory}/") }
    .sort
  fail_gate("Domain source files are missing") if expected_files.empty?

  # xccov omits source files with no executable lines. Keep that exception
  # explicit: if an allowlisted file gains executable code, xccov reports it as
  # unexpected and this gate requires the allowlist to be reviewed.
  zero_executable_files = ARGV.fetch(2).split(",").reject(&:empty?).sort
  missing_allowlisted_files = zero_executable_files - expected_files
  unless missing_allowlisted_files.empty?
    fail_gate("Zero-line Domain allowlist is stale: #{missing_allowlisted_files.join(", ")}")
  end
  expected_files -= zero_executable_files

  reported_files = files.map do |file|
    file.fetch("path").split(domain_marker, 2).fetch(1)
  end.sort
  missing_files = expected_files - reported_files
  unexpected_files = reported_files - expected_files
  unless missing_files.empty? && unexpected_files.empty?
    details = []
    details << "missing: #{missing_files.join(", ")}" unless missing_files.empty?
    details << "unexpected: #{unexpected_files.join(", ")}" unless unexpected_files.empty?
    fail_gate("Domain coverage file set does not match sources (#{details.join("; ")})")
  end

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
' -- "$minimum" "$domain_directory" "$zero_executable_files"
