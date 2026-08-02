#!/usr/bin/env bash

# Validates the --json-schema passed to the analyze job in
# .github/workflows/claude-pr-review.yml.
#
# The schema is a single-quoted JSON blob inside a YAML workflow, which makes
# it easy to get subtly wrong and impossible to notice until a run fails. It
# already did: `[^]\r\n]` was shipped where `[^\]\r\n]` was meant. In a regex
# `[^]` is an empty negated class, so that pattern
#   * failed to compile at all under the Unicode flag, which is how the CLI
#     compiles it -- "Invalid regular expression: unmatched ] or } bracket",
#     failing the whole analyze job, and
#   * would never have matched a real finding even without the flag, because
#     `[^]` consumes any single character and then demands a literal `\r\n]`.
#
# So this asserts three things: the blob is valid JSON, every `pattern` in it
# compiles under `u`, and the finding pattern actually accepts the
# `[agent] [path:line] text` shape that .claude/commands/pr-review.md
# specifies while rejecting text that omits it.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow="$repo_root/.github/workflows/claude-pr-review.yml"

for tool in python3 grep sed; do
  command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 1; }
done

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
schema_file="$work_dir/schema.json"

grep -oE "\-\-json-schema '.*'" "$workflow" \
  | sed "s/^--json-schema '//; s/'$//" > "$schema_file"

if [[ ! -s "$schema_file" ]]; then
  echo "FAIL: could not extract --json-schema from $workflow" >&2
  exit 1
fi

python3 - "$schema_file" <<'PY'
import json, re, sys

schema_path = sys.argv[1]
failures = []

try:
    with open(schema_path, encoding="utf-8") as handle:
        schema = json.load(handle)
except json.JSONDecodeError as error:
    print(f"FAIL: --json-schema is not valid JSON: {error}")
    sys.exit(1)
print("PASS: --json-schema is valid JSON")

# Collect every "pattern" anywhere in the schema.
patterns = []
def walk(node, path="$"):
    if isinstance(node, dict):
        if isinstance(node.get("pattern"), str):
            patterns.append((path, node["pattern"]))
        for key, value in node.items():
            walk(value, f"{path}.{key}")
    elif isinstance(node, list):
        for index, value in enumerate(node):
            walk(value, f"{path}[{index}]")

walk(schema)
if not patterns:
    print("FAIL: schema declares no patterns; extraction is probably broken")
    sys.exit(1)

# An empty negated class `[^]` is the specific trap. Python's re does not
# reject it the way a Unicode-mode JS regex does, so check for it directly
# as well as compiling each pattern.
for path, pattern in patterns:
    if "[^]" in pattern:
        failures.append(
            f"{path}: contains an empty negated class `[^]`; "
            r"a literal ] inside a class must be escaped as [^\]...]"
        )
    try:
        re.compile(pattern)
    except re.error as error:
        failures.append(f"{path}: does not compile: {error}")

if failures:
    for failure in failures:
        print(f"FAIL: {failure}")
    sys.exit(1)
print(f"PASS: all {len(patterns)} schema patterns compile and none use `[^]`")

# The finding shape pr-review.md requires: [agent] [path:line] text
finding = re.compile(schema["properties"]["blockers"]["items"]["pattern"])
accepted = [
    "[pr-correctness] [ios/Regards/App/RegardsApp.swift:84] navigation path diverges",
    "[pr-tests] [ios/RegardsAccessibilityTests/ScreensAccessibilityTests.swift:120] no Back assertion",
]
rejected = [
    "no agent or path here",
    "[pr-correctness] missing the bracketed path",
    "[pr-correctness] [ios/App.swift:0] line numbers start at 1",
    "[pr-correctness] [ios/App.swift] no line number",
]
for sample in accepted:
    if not finding.match(sample):
        failures.append(f"finding pattern rejects a valid finding: {sample}")
for sample in rejected:
    if finding.match(sample):
        failures.append(f"finding pattern accepts a malformed finding: {sample}")

if failures:
    for failure in failures:
        print(f"FAIL: {failure}")
    sys.exit(1)
print("PASS: finding pattern accepts the [agent] [path:line] shape and rejects malformed lines")

# Every list of findings shares the pattern; guard against them drifting apart.
for field in ("blockers", "should_fix", "nits"):
    actual = schema["properties"][field]["items"]["pattern"]
    if actual != schema["properties"]["blockers"]["items"]["pattern"]:
        print(f"FAIL: {field} pattern has drifted from blockers")
        sys.exit(1)
print("PASS: blockers, should_fix and nits share one finding pattern")
PY
