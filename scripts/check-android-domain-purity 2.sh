#!/usr/bin/env bash

set -euo pipefail

if [[ $# -gt 1 ]]; then
  echo "usage: $0 [android-domain-source-directory]" >&2
  exit 64
fi

domain_directory="${1:-android/domain/src}"

if [[ ! -d "$domain_directory" ]]; then
  echo "::error::Android domain source directory does not exist: $domain_directory" >&2
  exit 1
fi

# §5, Kotlin edition: :domain is pure Kotlin/JVM. No Android frameworks, no
# AndroidX (Room/Compose included), no networking, no SQLCipher.
platform_import_pattern='^[[:space:]]*import[[:space:]]+(android\.|androidx\.|java\.net\.|javax\.net\.|okhttp3|retrofit2|io\.ktor|net\.zetetic)'

if LC_ALL=C grep -REn --include='*.kt' --include='*.java' "$platform_import_pattern" -- "$domain_directory" 2>/dev/null; then
  echo "::error::Android domain layer contains a platform import (§5)." >&2
  exit 1
fi

echo "Android domain layer is platform-free."
