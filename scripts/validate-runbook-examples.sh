#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELP="$("$ROOT/cleaner.sh" --help)"
MAN="$ROOT/cleaner.1"

# Plain grep, captured through command substitution: a missing tool or unreadable
# source must abort under set -e rather than leave an empty list that checks nothing.
flags="$(grep -rh -- 'cleaner ' "$ROOT/RUNBOOK.md" "$ROOT/examples" \
  | grep -oE -- '--[a-z][a-z-]*' | sort -u)"
if [[ -z "$flags" ]]; then
  echo "no cleaner flags found in RUNBOOK.md or examples"
  exit 1
fi
while read -r f; do
  grep -qF -- "$f" <<< "$HELP" || { echo "missing in help: $f"; exit 1; }
done <<< "$flags"

# Env mirrors named in operator examples must appear in the man ENVIRONMENT section.
env_names="$(grep -rhoE 'LINUX_CLEANER_[A-Z0-9_]+' "$ROOT/RUNBOOK.md" "$ROOT/examples" | sort -u)"
while read -r env_name; do
  [[ -z "$env_name" ]] && continue
  grep -qF -- "$env_name" "$MAN" || { echo "missing in cleaner.1: $env_name"; exit 1; }
done <<< "$env_names"
