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

# §11 nuclear tier: no manifest may declare INTERNET or ACCESS_NETWORK_STATE,
# and the app manifest must keep the tools:node="remove" strip lines so a
# library-injected permission dies at manifest merge. Elements may span lines,
# so each manifest is flattened before matching.

status=0

while IFS= read -r manifest; do
  flattened=$(tr '\n' ' ' < "$manifest")
  while IFS= read -r element; do
    if [[ "$element" == *INTERNET* || "$element" == *ACCESS_NETWORK_STATE* ]]; then
      if [[ "$element" != *'tools:node="remove"'* ]]; then
        echo "::error file=$manifest::Network permission declared without tools:node=\"remove\" (§11): $element" >&2
        status=1
      fi
    fi
  done < <(grep -oE '<uses-permission[^>]*>' <<< "$flattened" || true)
done < <(find "$android_directory" -name AndroidManifest.xml -not -path '*/build/*')

app_manifest="$android_directory/app/src/main/AndroidManifest.xml"
if [[ ! -f "$app_manifest" ]]; then
  echo "::error::App manifest missing: $app_manifest" >&2
  exit 1
fi
app_flattened=$(tr '\n' ' ' < "$app_manifest")
for permission in android.permission.INTERNET android.permission.ACCESS_NETWORK_STATE; do
  if ! grep -oE '<uses-permission[^>]*>' <<< "$app_flattened" \
    | grep -F "$permission" \
    | grep -qF 'tools:node="remove"'; then
    echo "::error file=$app_manifest::Missing tools:node=\"remove\" strip line for $permission (§11)." >&2
    status=1
  fi
done

if [[ $status -ne 0 ]]; then
  exit 1
fi

echo "Android manifests are network-permission-free with strip lines intact."
