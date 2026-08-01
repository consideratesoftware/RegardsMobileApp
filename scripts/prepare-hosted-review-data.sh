#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: $0 <source-repo> <head-sha> <safe-tree> <policy-dir>" >&2
  exit 64
fi

source_repo="$1"
head_sha="$2"
safe_tree="$3"
policy_dir="$4"

if [[ ! -d "$source_repo/.git" ]] \
  || [[ ! "$head_sha" =~ ^[0-9a-f]{40}$ ]]; then
  echo "::error::Review source or head identity is invalid." >&2
  exit 1
fi

mkdir -p "$safe_tree" "$policy_dir"
: > "$policy_dir/manifest.tsv"

file_count=0
while IFS= read -r -d '' entry; do
  metadata="${entry%%$'\t'*}"
  path="${entry#*$'\t'}"
  read -r mode object_type object_id <<< "$metadata"

  if [[ "$path" == *$'\n'* || "$path" == *$'\r'* || "$path" == *$'\t'* ]]; then
    echo "::error::Control characters are not allowed in reviewed paths." >&2
    exit 1
  fi
  if [[ "$mode" == 120000 || "$object_type" != blob ]]; then
    echo "::error::Symlinks and submodules are not allowed in hosted review data: $path" >&2
    exit 1
  fi
  if [[ "$mode" != 100644 && "$mode" != 100755 ]]; then
    echo "::error::Unsupported Git mode $mode for $path." >&2
    exit 1
  fi

  basename="${path##*/}"
  policy_path=0
  case "/$path/" in
    */.claude/*|*/.codex/*|*/.claude-plugin/*|*/.husky/*)
      policy_path=1
      ;;
  esac
  case "$basename" in
    AGENTS.md|CLAUDE.md|CLAUDE.local.md|.mcp.json|.claude.json|.gitmodules|.ripgreprc)
      policy_path=1
      ;;
  esac

  if [[ "$policy_path" -eq 1 ]]; then
    neutral_name="$(printf '%s' "$path" | shasum -a 256 | awk '{print $1}')"
    git -C "$source_repo" cat-file blob "$object_id" \
      > "$policy_dir/$neutral_name.txt"
    printf '%s\t%s.txt\n' "$path" "$neutral_name" \
      >> "$policy_dir/manifest.tsv"
  else
    destination="$safe_tree/$path"
    mkdir -p -- "${destination%/*}"
    git -C "$source_repo" cat-file blob "$object_id" > "$destination"
    chmod 600 "$destination"
  fi
  file_count=$((file_count + 1))
done < <(git -C "$source_repo" ls-tree -rz --full-tree "$head_sha")

if [[ "$file_count" -eq 0 ]]; then
  echo "::error::Hosted review source tree is empty." >&2
  exit 1
fi

echo "Prepared $file_count regular review files with policy paths neutralized."
