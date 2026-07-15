#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELP="$("$ROOT/cleaner.sh" --help)"
while read -r f; do
  grep -qF -- "$f" <<< "$HELP" || { echo "missing in help: $f"; exit 1; }
done < <(
  rg 'cleaner ' "$ROOT/RUNBOOK.md" "$ROOT/examples" 2>/dev/null \
    | rg -o --no-filename '\-\-[a-z][a-z-]*' \
    | sort -u
)
