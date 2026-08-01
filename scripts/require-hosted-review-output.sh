#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <analysis-result> <preflight-result> <artifact-json>" >&2
  exit 64
fi

analysis_result="$1"
preflight_result="$2"
artifact_file="$3"

if [[ "$analysis_result" != success ]]; then
  echo "::error::Hosted review analysis finished with $analysis_result." >&2
  exit 1
fi

if [[ "$preflight_result" != success ]]; then
  echo "::error::Trusted review preflight finished with $preflight_result." >&2
  exit 1
fi

if [[ ! -f "$artifact_file" ]] \
  || ! grep -q '[^[:space:]]' "$artifact_file"; then
  echo "::error::Hosted review analysis returned no artifact." >&2
  exit 1
fi

echo "Hosted review analysis and trusted preflight succeeded."
