#!/usr/bin/env bash

set -euo pipefail

if [[ $# -gt 1 ]]; then
  echo "usage: $0 [android-directory]" >&2
  exit 64
fi

android_directory="${1:-android}"

if [[ ! -d "$android_directory" ]]; then
  echo "::error::Android directory does not exist: $android_directory" >&2
  exit 1
fi

# §11: no networking call sites in Android sources. Matches imports, fully
# qualified use, and construction/member access of the named families. WebView
# is included: remote content is a network vector even without our own sockets.
network_pattern='^[[:space:]]*import[[:space:]]+(java\.net\.|javax\.net\.|okhttp3|retrofit2|io\.ktor|org\.chromium\.net|android\.webkit)|\b(java\.net|javax\.net|okhttp3|retrofit2|io\.ktor)\.|\b(HttpURLConnection|HttpsURLConnection|CronetEngine|WebView)[.(]'

if LC_ALL=C grep -REn --include='*.kt' --include='*.java' "$network_pattern" -- "$android_directory" 2>/dev/null | grep -v '/build/'; then
  echo "::error::Networking call sites found in Android sources (§11)." >&2
  exit 1
fi

echo "No networking call sites found in Android sources."
