#!/usr/bin/env bash

set -euo pipefail

if [[ $# -gt 1 ]]; then
  echo "usage: $0 [domain-source-directory]" >&2
  exit 64
fi

domain_directory="${1:-ios/Regards/Domain}"

if [[ ! -d "$domain_directory" ]]; then
  echo "::error::Domain source directory does not exist: $domain_directory" >&2
  exit 1
fi

platform_import_pattern='^(@preconcurrency[[:space:]]+)?import[[:space:]]+((typealias|struct|class|enum|protocol|let|var|func)[[:space:]]+)?(UIKit|SwiftUI|Contacts|EventKit|UserNotifications|GRDB|StoreKit|Network)([.]|$)'

if LC_ALL=C grep -RE "$platform_import_pattern" -- "$domain_directory" 2>/dev/null; then
  echo "::error::Domain layer contains a platform import (§5)." >&2
  exit 1
fi

echo "Domain layer is platform-free."
