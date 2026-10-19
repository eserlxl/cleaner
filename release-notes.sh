#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

# Release-notes helper for CHANGELOG.md (Keep a Changelog format).
#
#   release-notes.sh extract <version>         Print that version's changelog section.
#   release-notes.sh roll <version> [<date>]   Move the [Unreleased] entries under a new
#                                              "## [<version>] - <date>" heading and
#                                              rewrite the compare/tag link footer.
#
# This lives as a tracked, tested script rather than as inline awk inside the release
# workflow: an extractor embedded in YAML is covered by no test, and this one decides
# what a published release says.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHANGELOG="${CHANGELOG:-$SCRIPT_DIR/CHANGELOG.md}"

usage() {
  echo "Usage: $(basename "$0") extract <version> | roll <version> [<YYYY-MM-DD>]" >&2
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

# Move the [Unreleased] entries under "## [<version>] - <date>" and rewrite the footer:
# the [Unreleased] compare link moves its base to v<version>, and a tag link for
# <version> follows it. Every refusal happens before CHANGELOG is touched, and the
# result replaces it atomically, so a failed roll leaves the file byte-identical.
roll() {
  local version="$1" date="${2:-$(date +%F)}" base tmp

  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: version '$version' is not X.Y.Z." >&2
    exit 1
  fi
  if [[ ! "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "Error: date '$date' is not YYYY-MM-DD." >&2
    exit 1
  fi
  if [[ ! -f "$CHANGELOG" ]]; then
    echo "Error: changelog not found at '$CHANGELOG'." >&2
    exit 1
  fi
  if grep -qF "## [$version]" "$CHANGELOG"; then
    echo "Error: '$CHANGELOG' already has a section for version '$version'." >&2
    exit 1
  fi
  if ! base=$(sed -n 's|^\[Unreleased\]: \(.*\)/compare/v[0-9][0-9.]*\.\.\.HEAD$|\1|p' "$CHANGELOG" | head -n 1) \
     || [[ -z "$base" ]]; then
    echo "Error: no '[Unreleased]: <url>/compare/v<version>...HEAD' link found in '$CHANGELOG'." >&2
    exit 1
  fi
  if ! awk '
    /^## \[Unreleased\]/ { inblk = 1; next }
    inblk && (/^## \[/ || /^\[[^]]+\]: /) { exit }
    inblk && NF { found = 1; exit }
    END { exit !found }
  ' "$CHANGELOG"; then
    echo "Error: the [Unreleased] section of '$CHANGELOG' has no entries to roll." >&2
    exit 1
  fi

  tmp=$(mktemp "$CHANGELOG.roll.XXXXXX")
  if ! awk -v ver="$version" -v date="$date" -v base="$base" '
    /^## \[Unreleased\]/ { print; print ""; print "## [" ver "] - " date; next }
    /^\[Unreleased\]: / {
      print "[Unreleased]: " base "/compare/v" ver "...HEAD"
      print "[" ver "]: " base "/releases/tag/v" ver
      next
    }
    { print }
  ' "$CHANGELOG" > "$tmp" || ! chmod --reference="$CHANGELOG" -- "$tmp" || ! mv -- "$tmp" "$CHANGELOG"; then
    rm -f -- "$tmp"
    echo "Error: failed to rewrite '$CHANGELOG'." >&2
    exit 1
  fi
  echo "Rolled [Unreleased] into [$version] - $date in $CHANGELOG"
}

case "${1:-}" in
  roll)
    if [[ -z "${2:-}" ]]; then
      echo "Error: roll requires a version argument." >&2
      usage
      exit 1
    fi
    roll "$2" "${3:-}"
    ;;
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
