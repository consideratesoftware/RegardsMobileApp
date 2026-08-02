#!/usr/bin/env bash

# Renders the one-line summary shown on the `Regards staged review` check run.
#
# This line carries the whole weight of the gate's contract. The check passes
# whenever a valid review ran for the current head, including one that requests
# changes, so the summary is the only thing distinguishing "reviewed, nothing
# found" from "reviewed, three blockers". If it is wrong or vague, a green
# check reads as "no findings" and the gate silently stops meaning anything --
# the exact failure this workflow exists to prevent.
#
# Reads the validated artifact rather than the rendered markdown: a heading
# rename in the renderer must not be able to turn a real blocker count into 0.
#
# usage: render-review-check-summary.sh <artifact.json>
#        render-review-check-summary.sh --missing

set -euo pipefail

readonly MISSING_SUMMARY='No verified review artifact was produced. The review did not run — see the run log.'

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <artifact.json>|--missing" >&2
  exit 64
fi

if [[ "$1" == "--missing" ]]; then
  printf '%s\n' "$MISSING_SUMMARY"
  exit 0
fi

artifact="$1"
if [[ ! -s "$artifact" ]]; then
  printf '%s\n' "$MISSING_SUMMARY"
  exit 0
fi

jq -r '
  def plural($n; $word): "\($n) \($word)\(if $n == 1 then "" else "s" end)";

  (.blockers // [] | length) as $b
  | (.should_fix // [] | length) as $s
  | (.nits // [] | length) as $n
  | if .verdict == "REQUEST_CHANGES" then
      "Changes requested: \(plural($b; "blocker")), \($s) should-fix, \(plural($n; "nit"))."
      + " The review ran; the gate does not block on the verdict."
    elif .verdict == "APPROVE" then
      "Approved: no blockers, \($s) should-fix, \(plural($n; "nit"))."
    else
      "Unrecognized verdict \(.verdict | tostring); see the review below."
    end
' "$artifact"
