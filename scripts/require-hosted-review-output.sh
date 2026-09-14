#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <analysis-result> <artifact-json>" >&2
  exit 64
fi

analysis_result="$1"
artifact_file="$2"

if [[ "$analysis_result" != success ]]; then
  echo "::error::Hosted review analysis finished with $analysis_result." >&2
  exit 1
fi

if [[ ! -f "$artifact_file" ]] \
  || ! grep -q '[^[:space:]]' "$artifact_file"; then
  echo "::error::Hosted review analysis returned no artifact." >&2
  exit 1
fi

echo "Hosted review analysis succeeded."
