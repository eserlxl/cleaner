#!/usr/bin/env bash

# Release-notes helper for CHANGELOG.md (Keep a Changelog format).
#
#   release-notes.sh extract <version>   Print that version's changelog section.
#
# This lives as a tracked, tested script rather than as inline awk inside the release
# workflow: an extractor embedded in YAML is covered by no test, and this one decides
# what a published release says.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHANGELOG="${CHANGELOG:-$SCRIPT_DIR/CHANGELOG.md}"

usage() {
  echo "Usage: $(basename "$0") extract <version>" >&2
}

# Print the changelog block for <version>. The block ends at the next '## [' heading,
# at the trailing link-definition footer ('[1.0.0]: https://...'), or at EOF. The footer
# stop is not cosmetic: a link definition does not start with '## [', so an extractor
# that stops only on headings drags the whole footer into the newest release's notes.
extract() {
  local version="$1"

  if [[ ! -f "$CHANGELOG" ]]; then
    echo "Error: changelog not found at '$CHANGELOG'." >&2
    exit 1
  fi

  local notes
  notes=$(awk -v ver="$version" '
    BEGIN { gsub(/\./, "\\.", ver) }
    $0 ~ ("^## \\[" ver "\\]") { inblk = 1; next }
    inblk && /^## \[/          { exit }
    inblk && /^\[[^]]+\]: /    { exit }
    inblk                      { print }
  ' "$CHANGELOG")

  # No section for this version. Fail loudly: a release published with an empty body is
  # worse than a release that refused to publish, and it cannot be un-published cleanly.
  if [[ -z "${notes//[[:space:]]/}" ]]; then
    echo "Error: no changelog section found for version '$version' in '$CHANGELOG'." >&2
    exit 1
  fi

  printf '%s\n' "$notes"
}

case "${1:-}" in
  extract)
    if [[ -z "${2:-}" ]]; then
      echo "Error: extract requires a version argument." >&2
      usage
      exit 1
    fi
    extract "$2"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage
    exit 1
    ;;
esac
