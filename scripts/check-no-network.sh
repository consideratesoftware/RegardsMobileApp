#!/usr/bin/env bash

set -euo pipefail

if [[ $# -gt 1 ]]; then
  echo "usage: $0 [regards-source-directory]" >&2
  exit 64
fi

source_directory="${1:-ios/Regards}"

if [[ ! -d "$source_directory" ]]; then
  echo "::error::Regards source directory does not exist: $source_directory" >&2
  exit 1
fi

# §11 permits names such as URLSession in user-facing copy. Match only member
# access, construction, or the named Core Foundation call families.
network_pattern='\b(URLSession\w*|NW(Connection|Endpoint|Listener|PathMonitor|Interface|Path)\w*|URLRequest|URLProtocol|NSURLConnection|CFSocket\w*)[.(]|\bCF(Read|Write)Stream(Create|Open|Read|Write|Ref|Client|Copy)'

if LC_ALL=C grep -REn "$network_pattern" -- "$source_directory" 2>/dev/null; then
  echo "::error::Networking call sites found in Regards sources (§11)." >&2
  exit 1
fi

echo "No networking call sites found."
