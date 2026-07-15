#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELP="$("$ROOT/cleaner.sh" --help)"
MAN="$ROOT/cleaner.1"

while read -r f; do
  grep -qF -- "$f" <<< "$HELP" || { echo "missing in help: $f"; exit 1; }
done < <(
  rg 'cleaner ' "$ROOT/RUNBOOK.md" "$ROOT/examples" 2>/dev/null \
    | rg -o --no-filename '\-\-[a-z][a-z-]*' \
    | sort -u
)

# Env mirrors named in operator examples must appear in the man ENVIRONMENT section.
while read -r env_name; do
  grep -qF -- "$env_name" "$MAN" || { echo "missing in cleaner.1: $env_name"; exit 1; }
done < <(
  rg -o --no-filename 'LINUX_CLEANER_[A-Z0-9_]+' "$ROOT/RUNBOOK.md" "$ROOT/examples" 2>/dev/null \
    | sort -u
)
