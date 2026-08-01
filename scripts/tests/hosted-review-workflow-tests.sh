#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workflow="$script_dir/../../.github/workflows/claude-pr-review.yml"

ruby - "$workflow" <<'RUBY'
require "yaml"

workflow = YAML.safe_load(
  File.read(ARGV.fetch(0)),
  permitted_classes: [],
  permitted_symbols: [],
  aliases: false
)
jobs = workflow.fetch("jobs")
open_check = jobs.fetch("open_check")
preflight = jobs.fetch("preflight")
analyze = jobs.fetch("analyze")
publish = jobs.fetch("publish")

raise "preflight must wait for the pending head check" unless preflight.fetch("needs") == "open_check"
raise "analysis must wait for trusted preflight" unless analyze.fetch("needs") == "preflight"
raise "head check must use the protected environment" unless open_check.fetch("environment") == "hosted-review"
raise "publisher must use the protected environment" unless publish.fetch("environment") == "hosted-review"
raise "publisher token permissions expanded" unless publish.fetch("permissions") == {"contents" => "read"}

open_steps = open_check.fetch("steps")
open_token_step = open_steps.find { |step| step["id"] == "review_app_token" }
raise "head check App token step missing" unless open_token_step
raise "head check App token action must stay pinned" unless open_token_step.fetch("uses") == "actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1"
raise "head check must be opened before preflight" unless open_steps.any? { |step| step["id"] == "head_check" }
raise "head check ID must cross the job boundary" unless open_check.fetch("outputs").fetch("check_id") == "${{ steps.head_check.outputs.id }}"
open_check_text = open_check.to_s
raise "dedicated check name missing" unless open_check_text.include?("Regards staged review")
raise "head check must use the dedicated App token" unless open_check_text.include?("steps.review_app_token.outputs.token")

steps = publish.fetch("steps")
token_step = steps.find { |step| step["id"] == "review_app_token" }
raise "dedicated App token step missing" unless token_step
raise "App token action must stay pinned" unless token_step.fetch("uses") == "actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1"

token_inputs = token_step.fetch("with")
raise "App client ID must come from environment configuration" unless token_inputs.fetch("client-id") == "${{ vars.REGARDS_REVIEW_APP_CLIENT_ID }}"
raise "App key must come from the protected environment" unless token_inputs.fetch("private-key") == "${{ secrets.REGARDS_REVIEW_APP_PRIVATE_KEY }}"
permission_keys = token_inputs.keys.grep(/^permission-/).sort
permissions_are_narrow = token_inputs.fetch("permission-checks") == "write" &&
  token_inputs.fetch("permission-issues") == "write" &&
  permission_keys == %w[permission-checks permission-issues]
raise "publisher App token permissions expanded" unless permissions_are_narrow

publisher_text = publish.to_s
raise "publisher must not use the generic Actions token" if publisher_text.include?("github.token")
raise "publisher must not use pull-request mutation APIs" if publisher_text.include?("permission-pull-requests") || publisher_text.include?("gh pr")
raise "dedicated App token is not used" unless publisher_text.include?("steps.review_app_token.outputs.token")
raise "publisher must complete the initial check" unless publisher_text.include?("needs.open_check.outputs.check_id")
RUBY

echo "PASS: hosted review trust wiring is pinned"
