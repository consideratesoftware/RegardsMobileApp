#!/usr/bin/env bash
# Counts the blockers in a saved `Regards staged review` check-run text.
#
#   scripts/count-hosted-blockers.sh <review text file>
#
# Prints exactly one line and exits 0:
#   PENDING: <why>      the file is missing or empty; the review hasn't run on
#                       this head yet. Wait; never treat it as zero.
#   BLOCKERS <n>        the number of bullets under "### Blockers". 0 is printed
#                       only when the text also says "VERDICT: APPROVE".
#   MALFORMED: <why>    fail closed: treat as unresolved blockers.
# Bullets are "-", "*", or numbered ("1." or "1)"). A bullet that reads only
# "None" is not a blocker. Exit 64 means a usage error.

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <review text file>" >&2
  exit 64
fi

file="$1"
if [[ ! -s "$file" ]]; then
  echo "PENDING: no review text for this head yet"
  exit 0
fi

awk '
  /^VERDICT:/ && !v { v = $2 }
  /^### Blockers/ { found = 1; s = 1; next }
  /^### /         { s = 0 }
  s && /^[[:space:]]*([-*]|[0-9]+[.)])[[:space:]]+None\.?[[:space:]]*$/ { next }
  s && /^[[:space:]]*([-*]|[0-9]+[.)]) / { n++; next }
  s && NF && !/^None\.?[[:space:]]*$/ { other++ }
  END {
    if (NR == 0)                       print "PENDING: empty review text"
    else if (!found)                   print "MALFORMED: no Blockers section"
    else if (n == 0 && other > 0)      print "MALFORMED: Blockers section has text but no bullets"
    else if (n == 0 && v != "APPROVE") print "MALFORMED: no blockers listed but VERDICT is " (v == "" ? "missing" : v)
    else                               print "BLOCKERS " n + 0
  }
' "$file"
