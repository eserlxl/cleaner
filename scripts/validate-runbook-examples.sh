#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELP="$("$ROOT/cleaner.sh" --help)"
while read -r f; do
  echo "$HELP" | grep -q "$f" || { echo "missing in help: $f"; exit 1; }
done < <(rg -o --no-filename '\-\-[a-z-]+' "$ROOT/RUNBOOK.md" "$ROOT/examples" 2>/dev/null | sort -u)
