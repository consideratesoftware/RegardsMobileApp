#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 || ! -f "$1" ]]; then
  echo "usage: $0 <project.yml>" >&2
  exit 64
fi

ruby - "$1" <<'RUBY'
require "yaml"

path = ARGV.fetch(0)
document = YAML.safe_load(
  File.read(path),
  permitted_classes: [],
  permitted_symbols: [],
  aliases: false
)

forbidden = %w[include preGenCommand postGenCommand].freeze
found = []

visit = lambda do |value, location|
  case value
  when Hash
    value.each do |key, child|
      child_location = "#{location}.#{key}"
      found << child_location if forbidden.include?(key.to_s)
      visit.call(child, child_location)
    end
  when Array
    value.each_with_index do |child, index|
      visit.call(child, "#{location}[#{index}]")
    end
  end
end

visit.call(document, "project")
unless found.empty?
  warn "::error::Untrusted XcodeGen includes and command hooks are not allowed: #{found.join(", ")}"
  exit 1
end
RUBY
