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
# bootstrap_review was a one-time compatibility job named `review` whose body
# was an echo, kept only so the legacy Actions-authored required context still
# resolved while the dedicated App check was being bound. Binding completed
# 2026-08-02 and `review` was removed from branch protection, so the job is
# gone. A required context satisfied by `echo` is the exact silent-green hole
# this workflow exists to close; it must not come back.
raise "the echo-only bootstrap review job must stay deleted" if jobs.key?("bootstrap_review")
raise "workflow must not run on the PR-controlled pull_request event" if workflow.fetch(true).key?("pull_request")

raise "preflight must wait for the pending head check" unless preflight.fetch("needs") == "open_check"
raise "analysis must wait for trusted preflight" unless analyze.fetch("needs") == "preflight"
raise "head check must use the protected environment" unless open_check.fetch("environment") == "hosted-review"
raise "publisher must use the protected environment" unless publish.fetch("environment") == "hosted-review"
raise "publisher token permissions expanded" unless publish.fetch("permissions") == {"contents" => "read"}
[open_check, preflight, analyze, publish].each do |job|
  raise "trusted job can run on a PR-controlled workflow" unless job.fetch("if").include?("github.event_name == 'pull_request_target'")
end

open_steps = open_check.fetch("steps")
open_token_step = open_steps.find { |step| step["id"] == "review_app_token" }
raise "head check App token step missing" unless open_token_step
raise "head check App token action must stay pinned" unless open_token_step.fetch("uses") == "actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1"
raise "head check must be opened before preflight" unless open_steps.any? { |step| step["id"] == "head_check" }
raise "head check ID must cross the job boundary" unless open_check.fetch("outputs").fetch("check_id") == "${{ steps.head_check.outputs.id }}"
open_check_text = open_check.to_s
raise "dedicated check name missing" unless open_check_text.include?("Regards staged review")
raise "head check must use the dedicated App token" unless open_check_text.include?("steps.review_app_token.outputs.token")

reviewer_step = analyze.fetch("steps").find { |step| step["id"] == "reviewer" }
raise "hosted reviewer step missing" unless reviewer_step
reviewer_inputs = reviewer_step.fetch("with")
reviewer_prompt = reviewer_inputs.fetch("prompt")
reviewer_args = reviewer_inputs.fetch("claude_args")
same_turn_directives = [
  "This run is non-interactive",
  "Wait for every Stage 1 agent in this same turn",
  "Consolidate their results, and return the required JSON before stopping",
  "nothing resumes this session"
]
same_turn_directives.each do |directive|
  raise "reviewer same-turn directive missing: #{directive}" unless reviewer_prompt.include?(directive)
end
raise "review turn budget regressed" unless reviewer_args.include?("--max-turns 120")

steps = publish.fetch("steps")
token_step = steps.find { |step| step["id"] == "review_app_token" }
raise "dedicated App token step missing" unless token_step
raise "App token action must stay pinned" unless token_step.fetch("uses") == "actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1"

token_inputs = token_step.fetch("with")
raise "App client ID must come from environment configuration" unless token_inputs.fetch("client-id") == "${{ vars.REGARDS_REVIEW_APP_CLIENT_ID }}"
raise "App key must come from the protected environment" unless token_inputs.fetch("private-key") == "${{ secrets.REGARDS_REVIEW_APP_PRIVATE_KEY }}"
permission_keys = token_inputs.keys.grep(/^permission-/).sort
permissions_are_narrow = token_inputs.fetch("permission-checks") == "write" &&
  permission_keys == %w[permission-checks]
raise "publisher App token permissions expanded" unless permissions_are_narrow

publisher_text = publish.to_s
raise "publisher must not use the generic Actions token" if publisher_text.include?("github.token")
pull_request_api = %r{repos/\$REPOSITORY/pulls/}
raise "publisher must not use pull-request mutation APIs" if publisher_text.include?("permission-pull-requests") || publisher_text.include?("gh pr") || publisher_text.match?(pull_request_api)
malicious_pull_request_call = 'gh api --method PATCH "repos/$REPOSITORY/pulls/$PR_NUMBER"'
raise "pull-request REST mutation regression fixture no longer matches" unless malicious_pull_request_call.match?(pull_request_api)
raise "dedicated App token is not used" unless publisher_text.include?("steps.review_app_token.outputs.token")
raise "publisher must complete the initial check" unless publisher_text.include?("needs.open_check.outputs.check_id")

# The review is delivered as the check run's output, never as a pull-request
# comment. Commenting on a pull request requires pull_requests:write, and a
# token holding that can also submit and approve reviews on the same pull
# request. Posting via the issue-comments endpoint is the shape that tempts
# someone back into needing it -- issues:write does not authorize it on a pull
# request, which is what the 403 on run 30736565965 was.
issue_comment_api = %r{repos/\$REPOSITORY/issues/\$PR_NUMBER/comments}
raise "publisher must not post pull-request comments" if publisher_text.match?(issue_comment_api)
malicious_comment_call = 'gh api --method POST "repos/$REPOSITORY/issues/$PR_NUMBER/comments"'
raise "issue-comment regression fixture no longer matches" unless malicious_comment_call.match?(issue_comment_api)
raise "publisher must deliver the review as check output" unless publisher_text.include?("hosted-review.md") && publisher_text.include?("output")

# The gate asserts that a review RAN, not that the reviewer agreed.
# validate-hosted-review-artifact.sh exits 1 for a missing, malformed or
# stale-head artifact (the review did not happen -> fail the check) and 2 for a
# valid current-head review requesting changes (it did happen -> publish the
# findings and pass). Conflating them means a reviewer's opinion blocks the
# merge queue, and the author loses the ability to take a finding as a
# fast-follow. Keep the two exit codes distinguished here.
# publisher_text comes from Hash#to_s, so embedded quotes arrive escaped;
# match the shape rather than a literal quoted string.
raise "publisher must not fail the gate on a REQUEST_CHANGES verdict" unless publisher_text.match?(/\$status\S* -eq 2/)
RUBY

echo "PASS: hosted review trust wiring is pinned"
