#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELP="$("$ROOT/cleaner.sh" --help)"
MAN="$ROOT/cleaner.1"

# Plain grep, captured through command substitution: a missing tool or unreadable
# source must abort under set -e rather than leave an empty list that checks nothing.
flags="$(grep -rh -- 'cleaner ' "$ROOT/RUNBOOK.md" "$ROOT/examples" \
  | grep -oE -- '--[[:alnum:]][[:alnum:]_-]*' | sort -u)"
if [[ -z "$flags" ]]; then
  echo "no cleaner flags found in RUNBOOK.md or examples"
  exit 1
fi
# Whole names only: a truncated --action must not pass because --action-timeout exists.
help_flags="$(grep -oE -- '--[[:alnum:]][[:alnum:]_-]*' <<< "$HELP" | sort -u)"
while read -r f; do
  grep -qxF -- "$f" <<< "$help_flags" || { echo "missing in help: $f"; exit 1; }
done <<< "$flags"

# Env mirrors named in operator examples must appear in the man ENVIRONMENT section.
env_names="$(grep -rhoE 'LINUX_CLEANER_[A-Z0-9_]+' "$ROOT/RUNBOOK.md" "$ROOT/examples" | sort -u)"
man_env_names="$(grep -oE 'LINUX_CLEANER_[A-Z0-9_]+' "$MAN" | sort -u)"
while read -r env_name; do
  [[ -z "$env_name" ]] && continue
  grep -qxF -- "$env_name" <<< "$man_env_names" || { echo "missing in cleaner.1: $env_name"; exit 1; }
done <<< "$env_names"
