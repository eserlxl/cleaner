#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

# Linux Cache and Temp File Cleaner
# A script to safely clean unnecessary files and folders.

set -euo pipefail

# Elapsed time for the result report. $SECONDS is seconds since this shell started.
CLEANER_START_SECONDS=$SECONDS

# Determine script directory to find the default configuration file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Config resolution: an explicit -c/--config wins; otherwise the default is
# resolved by search order (XDG user > /etc > dev checkout) after arg parsing.
CONFIG_FILE=""

# Single source of truth for the tool version (semantic version).
readonly VERSION="1.4.2"

# Colors for terminal output
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  GREEN='\033[0;32m'
  RED='\033[0;31m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  BOLD='\033[1m'
  NC='\033[0m' # No Color
else
  GREEN=''
  RED=''
  YELLOW=''
  BLUE=''
  BOLD=''
  NC=''
fi

# Print helper usage information
show_usage() {
  cat << EOF
Usage: $(basename "$0") [OPTIONS]

Safely clean cache and temporary files defined in a configuration file.

Options:
  -c, --config FILE          Path to a configuration file (default search order: XDG user config, then /etc/linux-cleaner/cleaner.conf, then cleaner.conf beside the script).
  -d, --dry-run              Calculate and display potential space savings without deleting anything (default).
  --clean                    Perform cleanup with a summary confirmation prompt.
  -i, --interactive          Prompt for confirmation before cleaning each target.
  -f, --force                Perform cleaning immediately without any confirmation prompts (except danger level).
  --yes-danger               Bypass manual confirmation prompt for danger risk targets.
  -t, --trash                Move files to quarantine instead of permanent deletion.
  -r, --risk LEVEL           Max risk level to clean: safe, medium, danger (default: safe).
  -e, --exclude PATTERNS     Comma-separated glob patterns to exclude (Warning: Incorrect patterns can affect deletion semantics or exclude everything).
  --list-sessions            List quarantine sessions (read-only) and exit.
  --report                   Print the saved last cleanup report and exit.
  --list-targets             List configured cleanup targets (read-only) and exit.
  --check-config             Validate the configuration file and exit (no disk analysis).
  --init-config              Copy the active config to your user config path (never overwrites).
  --restore SESSION          Restore files from quarantine session (latest or timestamp).
  --only PATTERN             With --restore: restore only targets whose original path contains PATTERN; the rest stay quarantined.
  --only-target PATTERN      With cleanup: process only config targets whose NAME contains PATTERN (substring match).
  --exclude-target PATTERN   With cleanup: skip config targets whose NAME contains PATTERN (substring match).
  --min-reclaim SIZE         With cleanup: skip the run when the planned reclaim is below SIZE (e.g. 500M, 2G).
  --purge-sessions SESSION   Permanently delete quarantine session(s) to reclaim space (latest, all, older-than:DAYS, or timestamp). Irreversible.
  --allow-outside-home       Deprecated no-op; targets outside HOME are always allowed.
  --log [FILE]               Append an operation log (opt-in, off by default; kept under your HOME).
  -q, --quiet                Suppress per-target status lines; keep errors, totals, and final summary.
  --debug                    Show per-target FOUND, CLEAN and PROTECTED lines (suppressed by default; overridden by --quiet).
  --json                     Emit machine-readable JSON (--dry-run summary, --list-targets inventory, or --list-sessions inventory).
  -h, --help                 Display this help message and exit.
  -V, --version              Print the tool version and exit.
EOF
}

# Default flags
DRY_RUN=true
DRY_RUN_EXPLICIT=false
INTERACTIVE=false
FORCE=false
YES_DANGER=false
QUIET=false
DEBUG=false
JSON_OUTPUT=false
TRASH_MODE=false
MAX_RISK="safe"
EXCLUDE_PATTERNS=""
RESTORE_TARGET=""
RESTORE_ONLY=""
ONLY_TARGET=""
EXCLUDE_TARGET=""
MIN_RECLAIM=""
MIN_RECLAIM_BYTES=0
PURGE_TARGET=""
LIST_SESSIONS=false
LIST_TARGETS=false
CHECK_CONFIG=false
INIT_CONFIG=false
REPORT=false
PLAN_REPORT_TEXT=""
RESULT_REPORT_TEXT=""

# Set by any operation that was attempted and failed (a delete, a quarantine move,
# a predefined action, a purge). The tool exits non-zero when it is set, per the
# contract in cleaner.1 ("non-zero on ... a failed operation") -- an unattended run
# must be able to detect a failure it only printed to stderr. Deliberate skips (a
# declined danger target, a blocked process, an unsafe path, a target whose root
# privileges are not available, an action whose binary
# is absent) are not failures and leave this false.
OPERATION_FAILED=false

# Operation log (opt-in, OFF by default). Enable via --log or by setting the
# LINUX_CLEANER_LOG environment variable. The log lives under $HOME (see the
# writer). When disabled, no log file is created or written.
LOG_ENABLED=false
LOG_FILE=""
if [[ -n "${LINUX_CLEANER_LOG:-}" ]]; then
  LOG_ENABLED=true
  LOG_FILE="$LINUX_CLEANER_LOG"
fi

# Env mirrors for automation (same truthy set as common shell tools).
if [[ -n "${LINUX_CLEANER_CONFIG:-}" ]]; then
  CONFIG_FILE="$LINUX_CLEANER_CONFIG"
fi
case "${LINUX_CLEANER_QUIET:-}" in
  1|true|TRUE|yes|YES) QUIET=true ;;
esac
case "${LINUX_CLEANER_DEBUG:-}" in
  1|true|TRUE|yes|YES) DEBUG=true ;;
esac
case "${LINUX_CLEANER_JSON:-}" in
  1|true|TRUE|yes|YES) JSON_OUTPUT=true ;;
esac
if [[ -n "${LINUX_CLEANER_ONLY_TARGET:-}" ]]; then
  ONLY_TARGET="$LINUX_CLEANER_ONLY_TARGET"
fi
if [[ -n "${LINUX_CLEANER_EXCLUDE_TARGET:-}" ]]; then
  EXCLUDE_TARGET="$LINUX_CLEANER_EXCLUDE_TARGET"
fi
if [[ -n "${LINUX_CLEANER_MIN_RECLAIM:-}" ]]; then
  MIN_RECLAIM="$LINUX_CLEANER_MIN_RECLAIM"
fi
if [[ -n "${LINUX_CLEANER_RISK:-}" ]]; then
  MAX_RISK="$LINUX_CLEANER_RISK"
fi
case "${LINUX_CLEANER_TRASH:-}" in
  1|true|TRUE|yes|YES) TRASH_MODE=true ;;
esac
if [[ -n "${LINUX_CLEANER_EXCLUDE:-}" ]]; then
  EXCLUDE_PATTERNS="$LINUX_CLEANER_EXCLUDE"
fi
case "${LINUX_CLEANER_FORCE:-}" in
  1|true|TRUE|yes|YES) FORCE=true; DRY_RUN=false ;;
esac
case "${LINUX_CLEANER_YES_DANGER:-}" in
  1|true|TRUE|yes|YES) YES_DANGER=true ;;
esac
# Deprecated no-op. Warn at most once per run (the CLI flag uses the same guard).
ALLOW_OUTSIDE_HOME_DEPRECATION_WARNED=false
case "${LINUX_CLEANER_ALLOW_OUTSIDE_HOME:-}" in
  1|true|TRUE|yes|YES)
    ALLOW_OUTSIDE_HOME_DEPRECATION_WARNED=true
    echo "Warning: LINUX_CLEANER_ALLOW_OUTSIDE_HOME is deprecated and has no effect; targets outside HOME are always allowed." >&2
    ;;
esac

# Parse command line options
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--config)
      if [[ -z "${2:-}" ]]; then
        echo -e "${RED}Error: --config requires a file path argument.${NC}" >&2
        exit 1
      fi
      CONFIG_FILE="$2"
      shift 2
      ;;
    -d|--dry-run)
      DRY_RUN=true
      DRY_RUN_EXPLICIT=true
      shift
      ;;
    --clean)
      DRY_RUN=false
      DRY_RUN_EXPLICIT=false
      shift
      ;;
    -i|--interactive)
      INTERACTIVE=true
      DRY_RUN=false
      DRY_RUN_EXPLICIT=false
      shift
      ;;
    -f|--force)
      FORCE=true
      DRY_RUN=false
      DRY_RUN_EXPLICIT=false
      shift
      ;;
    -q|--quiet)
      QUIET=true
      shift
      ;;
    --debug)
      DEBUG=true
      shift
      ;;
    --json)
      JSON_OUTPUT=true
      shift
      ;;
    --yes-danger)
      YES_DANGER=true
      shift
      ;;
    -t|--trash)
      TRASH_MODE=true
      shift
      ;;
    -r|--risk)
      if [[ -z "${2:-}" ]]; then
        echo -e "${RED}Error: --risk requires a level argument (safe, medium, danger).${NC}" >&2
        exit 1
      fi
      MAX_RISK="$2"
      shift 2
      ;;
    -e|--exclude)
      if [[ -z "${2:-}" ]]; then
        echo -e "${RED}Error: --exclude requires a pattern argument.${NC}" >&2
        exit 1
      fi
      EXCLUDE_PATTERNS="$2"
      shift 2
      ;;
    --restore)
      if [[ -z "${2:-}" ]]; then
        echo -e "${RED}Error: --restore requires a session argument (latest or timestamp).${NC}" >&2
        exit 1
      fi
      RESTORE_TARGET="$2"
      shift 2
      ;;
    --only)
      if [[ -z "${2:-}" ]]; then
        echo -e "${RED}Error: --only requires a pattern argument.${NC}" >&2
        exit 1
      fi
      RESTORE_ONLY="$2"
      shift 2
      ;;
    --only-target)
      if [[ -z "${2:-}" ]]; then
        echo -e "${RED}Error: --only-target requires a pattern argument.${NC}" >&2
        exit 1
      fi
      ONLY_TARGET="$2"
      shift 2
      ;;
    --exclude-target)
      if [[ -z "${2:-}" ]]; then
        echo -e "${RED}Error: --exclude-target requires a pattern argument.${NC}" >&2
        exit 1
      fi
      EXCLUDE_TARGET="$2"
      shift 2
      ;;
    --min-reclaim)
      if [[ -z "${2:-}" ]]; then
        echo -e "${RED}Error: --min-reclaim requires a size argument.${NC}" >&2
        exit 1
      fi
      MIN_RECLAIM="$2"
      shift 2
      ;;
    --purge-sessions)
      if [[ -z "${2:-}" ]]; then
        echo -e "${RED}Error: --purge-sessions requires a session argument (latest, all, older-than:DAYS, or timestamp).${NC}" >&2
        exit 1
      fi
      PURGE_TARGET="$2"
      shift 2
      ;;
    --allow-outside-home)
      if [[ "$ALLOW_OUTSIDE_HOME_DEPRECATION_WARNED" != true ]]; then
        ALLOW_OUTSIDE_HOME_DEPRECATION_WARNED=true
        echo "Warning: --allow-outside-home is deprecated and has no effect; targets outside HOME are always allowed." >&2
      fi
      shift
      ;;
    --log)
      LOG_ENABLED=true
      # Optional explicit path: consume the next token only if it is not a flag.
      if [[ -n "${2:-}" && "$2" != -* ]]; then
        LOG_FILE="$2"
        shift 2
      else
        shift
      fi
      ;;
    -V|--version)
      echo "$(basename "$0") $VERSION"
      exit 0
      ;;
    --list-sessions)
      LIST_SESSIONS=true
      shift
      ;;
    --report)
      REPORT=true
      shift
      ;;
    --list-targets)
      LIST_TARGETS=true
      shift
      ;;
    --check-config)
      CHECK_CONFIG=true
      shift
      ;;
    --init-config)
      INIT_CONFIG=true
      shift
      ;;
    -h|--help)
      show_usage
      exit 0
      ;;
    *)
      echo -e "${RED}Error: Unknown option '$1'${NC}" >&2
      show_usage
      exit 1
      ;;
  esac
done

# HOME is the tool's entire safety boundary: every target path is expanded,
# canonicalized, and bounded against it. Refuse to run without it -- a bare $HOME
# deref under set -u would otherwise abort mid-parse, or (via expand_path_safe's
# swallowed command substitution) silently collapse a target to the current
# directory. USER is only a convenience placeholder; normalize it once so an
# unset USER (cron, systemd, containers, 'su' without -) cannot trigger the same
# collapse.
if [[ -z "${HOME:-}" ]]; then
  echo -e "${RED}Error: HOME is not set; refusing to run without a home-directory boundary.${NC}" >&2
  exit 1
fi
USER="${USER:-$(id -un 2>/dev/null || true)}"

if [[ -n "$MIN_RECLAIM" ]]; then
  if [[ ! "$MIN_RECLAIM" =~ ^([0-9]+)([KMGTkmgt]?)$ ]]; then
    echo -e "${RED}Error: --min-reclaim expects a size such as 500M or 2G, got '${MIN_RECLAIM}'.${NC}" >&2
    exit 1
  fi
  min_reclaim_num="${BASH_REMATCH[1]}"
  min_reclaim_unit="${BASH_REMATCH[2]}"
  case "$min_reclaim_unit" in
    "") min_reclaim_mult=1 ;;
    k|K) min_reclaim_mult=1024 ;;
    m|M) min_reclaim_mult=$((1024 * 1024)) ;;
    g|G) min_reclaim_mult=$((1024 * 1024 * 1024)) ;;
    t|T) min_reclaim_mult=$((1024 * 1024 * 1024 * 1024)) ;;
  esac
  # Refuse values whose byte count would overflow 64-bit shell arithmetic.
  if [[ ${#min_reclaim_num} -gt 18 ]] \
     || (( 10#$min_reclaim_num > 9223372036854775807 / min_reclaim_mult )); then
    echo -e "${RED}Error: --min-reclaim size '${MIN_RECLAIM}' is too large.${NC}" >&2
    exit 1
  fi
  MIN_RECLAIM_BYTES=$((10#$min_reclaim_num * min_reclaim_mult))
fi

# Restore and purge are mutating modes that bypass the cleanup dry-run exit.
# Distinguish an explicit active --dry-run from the default DRY_RUN=true so
# ordinary restore/purge requests keep their established behavior.
if [[ "$DRY_RUN_EXPLICIT" == true && ( -n "$RESTORE_TARGET" || -n "$PURGE_TARGET" ) ]]; then
  echo -e "${RED}Error: --dry-run cannot be combined with --restore or --purge-sessions.${NC}" >&2
  exit 1
fi

# --only only means anything as a filter on --restore; silently ignoring it would
# let a user believe a cleanup or purge was narrowed when it was not.
if [[ -n "$RESTORE_ONLY" && -z "$RESTORE_TARGET" ]]; then
  echo -e "${RED}Error: --only requires --restore (it filters which quarantined targets are restored).${NC}" >&2
  exit 1
fi

if [[ -n "$ONLY_TARGET" && ( -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" || "$LIST_SESSIONS" == true || "$LIST_TARGETS" == true || "$REPORT" == true || "$INIT_CONFIG" == true ) ]]; then
  echo -e "${RED}Error: --only-target applies only to cleanup runs (not --restore, --purge-sessions, --list-sessions, --list-targets, --report, or --init-config).${NC}" >&2
  exit 1
fi

if [[ -n "$EXCLUDE_TARGET" && ( -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" || "$LIST_SESSIONS" == true || "$LIST_TARGETS" == true || "$REPORT" == true || "$INIT_CONFIG" == true ) ]]; then
  echo -e "${RED}Error: --exclude-target applies only to cleanup runs (not --restore, --purge-sessions, --list-sessions, --list-targets, --report, or --init-config).${NC}" >&2
  exit 1
fi

if [[ -n "$MIN_RECLAIM" && ( -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" || "$LIST_SESSIONS" == true || "$LIST_TARGETS" == true || "$REPORT" == true || "$INIT_CONFIG" == true ) ]]; then
  echo -e "${RED}Error: --min-reclaim applies only to cleanup runs (not --restore, --purge-sessions, --list-sessions, --list-targets, --report, or --init-config).${NC}" >&2
  exit 1
fi

if [[ "$LIST_TARGETS" == true && ( -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" || "$LIST_SESSIONS" == true || "$REPORT" == true || "$INIT_CONFIG" == true ) ]]; then
  echo -e "${RED}Error: --list-targets cannot be combined with --restore, --purge-sessions, --list-sessions, --report, or --init-config.${NC}" >&2
  exit 1
fi

if [[ "$CHECK_CONFIG" == true && ( -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" || "$LIST_SESSIONS" == true || "$LIST_TARGETS" == true || "$REPORT" == true || "$INIT_CONFIG" == true ) ]]; then
  echo -e "${RED}Error: --check-config cannot be combined with --restore, --purge-sessions, --list-sessions, --list-targets, --report, or --init-config.${NC}" >&2
  exit 1
fi

if [[ "$REPORT" == true && ( -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" || "$LIST_SESSIONS" == true || "$LIST_TARGETS" == true || "$CHECK_CONFIG" == true || "$INIT_CONFIG" == true ) ]]; then
  echo -e "${RED}Error: --report cannot be combined with --restore, --purge-sessions, --list-sessions, --list-targets, --check-config, or --init-config.${NC}" >&2
  exit 1
fi

if [[ "$INIT_CONFIG" == true && ( -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" || "$LIST_SESSIONS" == true || "$LIST_TARGETS" == true || "$CHECK_CONFIG" == true || "$REPORT" == true ) ]]; then
  echo -e "${RED}Error: --init-config cannot be combined with --restore, --purge-sessions, --list-sessions, --list-targets, --check-config, or --report.${NC}" >&2
  exit 1
fi

if [[ -n "$ONLY_TARGET" && "$CHECK_CONFIG" == true ]]; then
  echo -e "${RED}Error: --only-target applies only to cleanup runs (not --check-config).${NC}" >&2
  exit 1
fi

if [[ -n "$EXCLUDE_TARGET" && "$CHECK_CONFIG" == true ]]; then
  echo -e "${RED}Error: --exclude-target applies only to cleanup runs (not --check-config).${NC}" >&2
  exit 1
fi

if [[ -n "$MIN_RECLAIM" && "$CHECK_CONFIG" == true ]]; then
  echo -e "${RED}Error: --min-reclaim applies only to cleanup runs (not --check-config).${NC}" >&2
  exit 1
fi

if [[ "$JSON_OUTPUT" == true && ( \
      -n "$RESTORE_TARGET" || -n "$PURGE_TARGET" || "$CHECK_CONFIG" == true || "$REPORT" == true || "$INIT_CONFIG" == true || \
      ( "$DRY_RUN" != true && "$LIST_TARGETS" != true && "$LIST_SESSIONS" != true ) \
    ) ]]; then
  echo -e "${RED}Error: --json is valid only with --dry-run (machine-readable preview), --list-targets, or --list-sessions.${NC}" >&2
  exit 1
fi

if [[ "$JSON_OUTPUT" == true ]]; then
  QUIET=true
fi

# Print the effective XDG base directory for variable NAME (arg 1), using its
# environment value only when it is an absolute path (starts with /), or
# DEFAULT (arg 2) when unset, empty, or relative (per XDG Base Directory spec).
_xdg_dir() {
  local name="$1" default="$2"
  local val="${!name:-}"
  if [[ "$val" == /* ]]; then
    printf '%s' "$val"
  else
    printf '%s' "$default"
  fi
}

# Copy the active configuration file to the user config path without overwriting.
init_user_config() {
  local xdg_parent dest_dir dest src="" candidate tmp
  xdg_parent="$(_xdg_dir XDG_CONFIG_HOME "$HOME/.config")"
  dest_dir="$xdg_parent/linux-cleaner"
  dest="$dest_dir/cleaner.conf"

  if [[ -L "$xdg_parent" ]]; then
    echo -e "${RED}Error: Refusing to initialize config; parent directory '$xdg_parent' is a symlink.${NC}" >&2
    return 1
  fi
  if [[ -L "$dest_dir" ]]; then
    echo -e "${RED}Error: Refusing to initialize config; directory '$dest_dir' is a symlink.${NC}" >&2
    return 1
  fi
  if [[ -e "$dest" || -L "$dest" ]]; then
    echo -e "${RED}Error: User config already exists at '$dest'; refusing to overwrite.${NC}" >&2
    return 1
  fi

  if [[ -n "$CONFIG_FILE" ]]; then
    if [[ -f "$CONFIG_FILE" && "$CONFIG_FILE" != "$dest" ]]; then
      src="$CONFIG_FILE"
    fi
  else
    for candidate in "/etc/linux-cleaner/cleaner.conf" "$SCRIPT_DIR/cleaner.conf"; do
      if [[ -f "$candidate" && "$candidate" != "$dest" ]]; then
        src="$candidate"
        break
      fi
    done
  fi

  if [[ -z "$src" ]]; then
    echo -e "${RED}Error: No source configuration file found to copy.${NC}" >&2
    return 1
  fi

  if ! (umask 077; mkdir -p -- "$dest_dir"); then
    echo -e "${RED}Error: Failed to create user config directory '$dest_dir'.${NC}" >&2
    return 1
  fi
  if [[ -L "$xdg_parent" || -L "$dest_dir" || ! -d "$dest_dir" ]]; then
    echo -e "${RED}Error: Refusing to initialize config; '$dest_dir' is not a real directory.${NC}" >&2
    return 1
  fi

  tmp="$dest.tmp.$$"
  if ! cp -- "$src" "$tmp"; then
    rm -f -- "$tmp" || true
    echo -e "${RED}Error: Failed to copy '$src' to '$tmp'.${NC}" >&2
    return 1
  fi
  if ! chmod 0644 "$tmp"; then
    rm -f -- "$tmp" || true
    echo -e "${RED}Error: Failed to set permissions on '$tmp'.${NC}" >&2
    return 1
  fi
  if [[ -e "$dest" || -L "$dest" ]]; then
    rm -f -- "$tmp" || true
    echo -e "${RED}Error: User config already exists at '$dest'; refusing to overwrite.${NC}" >&2
    return 1
  fi
  if ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp" || true
    echo -e "${RED}Error: Failed to move '$tmp' to '$dest'.${NC}" >&2
    return 1
  fi

  echo "Created $dest from $src; edit it, then preview with: cleaner --dry-run"
  return 0
}

if [[ "$INIT_CONFIG" == true ]]; then
  init_user_config
  exit $?
fi

# Check if config file exists (only if not restoring, purging, or listing sessions)
if [[ -z "${RESTORE_TARGET:-}" && -z "${PURGE_TARGET:-}" && "$LIST_SESSIONS" != true && "$REPORT" != true ]]; then
  # Resolve the default config by search order when -c/--config was not given:
  # XDG user config > system config > dev-checkout config beside the script.
  if [[ -z "$CONFIG_FILE" ]]; then
    for candidate in \
        "$(_xdg_dir XDG_CONFIG_HOME "$HOME/.config")/linux-cleaner/cleaner.conf" \
        "/etc/linux-cleaner/cleaner.conf" \
        "$SCRIPT_DIR/cleaner.conf"; do
      if [[ -f "$candidate" ]]; then
        CONFIG_FILE="$candidate"
        break
      fi
    done
    # No candidate exists: keep the dev path so the not-found error is actionable.
    [[ -z "$CONFIG_FILE" ]] && CONFIG_FILE="$SCRIPT_DIR/cleaner.conf"
  fi
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}Error: Configuration file not found at '$CONFIG_FILE'${NC}" >&2
    exit 1
  fi
fi

# Trim whitespace from variables
trim() {
  local var="$*"
  # remove leading whitespace
  var="${var#"${var%%[![:space:]]*}"}"
  # remove trailing whitespace
  var="${var%"${var##*[![:space:]]}"}"
  echo -n "$var"
}

name_matches_any() {
  local name="$1" p
  shift
  for p in "$@"; do
    if [[ "$name" == *"$p"* ]]; then
      return 0
    fi
  done
  return 1
}

# Split a comma-separated --only-target / --exclude-target value into trimmed
# substrings. An empty entry would match every NAME, so it is refused.
split_name_patterns() {
  local flag="$1" value="$2" pat
  local -n patterns_out="$3"
  local -a raw=() raw_fields=()
  patterns_out=()
  [[ -z "$value" ]] && return 0
  # read -a drops a trailing empty field, so check for it explicitly.
  [[ "$value" == *, ]] && raw=("")
  IFS=',' read -r -a raw_fields <<< "$value"
  raw=("${raw_fields[@]}" "${raw[@]}")
  for pat in "${raw[@]}"; do
    pat=$(trim "$pat")
    if [[ -z "$pat" ]]; then
      echo -e "${RED}Error: ${flag} contains an empty pattern in '${value}'.${NC}" >&2
      exit 1
    fi
    patterns_out+=("$pat")
  done
}

ONLY_TARGET_PATTERNS=()
EXCLUDE_TARGET_PATTERNS=()
split_name_patterns --only-target "$ONLY_TARGET" ONLY_TARGET_PATTERNS
split_name_patterns --exclude-target "$EXCLUDE_TARGET" EXCLUDE_TARGET_PATTERNS

# User-facing status lines (per-target progress, headers). Suppressed by --quiet;
# errors and final summaries still print via echo/stderr.
status_echo() {
  if [[ "$QUIET" == true ]]; then
    return 0
  fi
  echo -e "$@"
}

debug_echo() {
  if [[ "$DEBUG" != true ]]; then
    return 0
  fi
  status_echo "$@"
}

json_escape() {
  local s="$1" code octal control escaped
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\b'/\\b}
  s=${s//$'\f'/\\f}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}

  # Bash strings cannot contain NUL; encode every other representable C0 byte.
  for ((code = 1; code < 32; code++)); do
    case "$code" in 8|9|10|12|13) continue ;; esac
    printf -v octal '%03o' "$code"
    printf -v control '%b' "\\$octal"
    printf -v escaped '\\u%04x' "$code"
    s=${s//"$control"/"$escaped"}
  done
  printf '%s' "$s"
}

emit_dry_run_json() {
  local i first=true size_human
  printf '{'
  printf '"config":"%s",' "$(json_escape "$CONFIG_FILE")"
  printf '"total_reclaimable_bytes":%s,' "$total_reclaimable_bytes"
  printf '"total_reclaimable_human":"%s",' "$(json_escape "$(format_bytes "$total_reclaimable_bytes")")"
  printf '"targets":['
  for i in "${!json_names[@]}"; do
    if [[ "$first" == true ]]; then
      first=false
    else
      printf ','
    fi
    size_human=$(format_bytes "${json_bytes[$i]}")
    [[ "${json_runtime_sized[$i]:-false}" == true ]] && size_human="size at run time"
    printf '{"name":"%s","path":"%s","risk":"%s","bytes":%s,"size_human":"%s","status":"%s","description":"%s","min_age_days":"%s","size_at_run_time":%s,"reason":"%s"}' \
      "$(json_escape "${json_names[$i]}")" \
      "$(json_escape "${json_paths[$i]}")" \
      "$(json_escape "${json_risks[$i]}")" \
      "${json_bytes[$i]}" \
      "$(json_escape "$size_human")" \
      "$(json_escape "${json_statuses[$i]}")" \
      "$(json_escape "${json_descs[$i]}")" \
      "$(json_escape "${json_ages[$i]}")" \
      "${json_runtime_sized[$i]:-false}" \
      "$(json_escape "${json_reasons[$i]:-}")"
  done
  printf ']}'
  printf '\n'
}

emit_list_targets_json() {
  local -a lt_names=() lt_risks=() lt_paths=() lt_descs=() lt_min_ages=() lt_procs=() lt_actions=()
  local config_line
  local risk name raw_path desc min_age check_procs custom_clean_cmd
  local i first=true

  while IFS= read -r config_line || [[ -n "$config_line" ]]; do
    config_line="${config_line#*$'\t'}"
    # validate_config_file already rejected malformed records before this runs.
    IFS='|' read -r risk name raw_path desc min_age check_procs custom_clean_cmd <<< "$config_line"
    risk=$(trim "$risk")
    [[ -z "$risk" || "$risk" =~ ^# ]] && continue
    name=$(trim "$name")
    raw_path=$(trim "$raw_path")
    desc=$(trim "$desc")
    min_age=$(trim "$min_age")
    check_procs=$(trim "${check_procs:-}")
    custom_clean_cmd=$(trim "${custom_clean_cmd:-}")
    lt_names+=("$name")
    lt_risks+=("$risk")
    lt_paths+=("$raw_path")
    lt_descs+=("$desc")
    lt_min_ages+=("$min_age")
    lt_procs+=("$check_procs")
    lt_actions+=("$custom_clean_cmd")
  done < <(expand_config_globs)

  printf '{'
  printf '"config":"%s",' "$(json_escape "$CONFIG_FILE")"
  printf '"targets":['
  for i in "${!lt_names[@]}"; do
    if [[ "$first" == true ]]; then
      first=false
    else
      printf ','
    fi
    printf '{"name":"%s","risk":"%s","path":"%s","description":"%s","min_age_days":"%s","check_processes":"%s","custom_action":"%s"}' \
      "$(json_escape "${lt_names[$i]}")" \
      "$(json_escape "${lt_risks[$i]}")" \
      "$(json_escape "${lt_paths[$i]}")" \
      "$(json_escape "${lt_descs[$i]}")" \
      "$(json_escape "${lt_min_ages[$i]}")" \
      "$(json_escape "${lt_procs[$i]}")" \
      "$(json_escape "${lt_actions[$i]}")"
  done
  printf ']}'
  printf '\n'
}

# Replace every whole-token occurrence of $NAME (arg 2) with VALUE (arg 3) in
# STRING (arg 1). "Whole token" means the $NAME is not immediately followed by
# an identifier character, so $HOMEDATA / $USERNAME are left literal -- only the
# explicit $HOME / $USER / $XDG_*_HOME placeholders are resolved (no eval, no
# substring creep).
_expand_var_token() {
  local str="$1" name="$2" value="$3"
  local token="\$$name"
  local out="" rest="$str" before after nextc
  while [[ "$rest" == *"$token"* ]]; do
    before="${rest%%"$token"*}"
    after="${rest#*"$token"}"
    nextc="${after:0:1}"
    if [[ -z "$nextc" || "$nextc" != [A-Za-z0-9_] ]]; then
      out+="$before$value"
    else
      out+="$before$token"
    fi
    rest="$after"
  done
  printf '%s' "$out$rest"
}

# Expand standard environment variables in a safe way (avoiding eval):
# leading ~, $HOME, $USER, $XDG_CACHE_HOME, $XDG_CONFIG_HOME, $XDG_DATA_HOME,
# and $XDG_STATE_HOME (XDG variables fall back to their spec default when unset
# or relative).
expand_path_safe() {
  local raw_path="$1"
  local expanded="$raw_path"

  # Safe leading ~ expansion
  # shellcheck disable=SC2088
  if [[ "$expanded" == "~" ]]; then
    expanded="$HOME"
  elif [[ "$expanded" == "~/"* ]]; then
    expanded="$HOME/${expanded:2}"
  fi

  # Replace $HOME, $USER, and the four XDG base-directory variables only as
  # whole tokens (so $HOMEDATA / $USERNAME / $XDG_CACHE_HOMEX stay literal,
  # matching the documented "explicit placeholders only" contract).
  expanded=$(_expand_var_token "$expanded" "HOME" "${HOME:-}")
  expanded=$(_expand_var_token "$expanded" "USER" "${USER:-}")
  expanded=$(_expand_var_token "$expanded" "XDG_CACHE_HOME" "$(_xdg_dir "XDG_CACHE_HOME" "${HOME:-}/.cache")")
  expanded=$(_expand_var_token "$expanded" "XDG_CONFIG_HOME" "$(_xdg_dir "XDG_CONFIG_HOME" "${HOME:-}/.config")")
  expanded=$(_expand_var_token "$expanded" "XDG_DATA_HOME" "$(_xdg_dir "XDG_DATA_HOME" "${HOME:-}/.local/share")")
  expanded=$(_expand_var_token "$expanded" "XDG_STATE_HOME" "$(_xdg_dir "XDG_STATE_HOME" "${HOME:-}/.local/state")")

  echo "$expanded"
}

# How many directory levels below the literal prefix a "**" pattern component may
# span. Bounded on purpose: a mistyped recursive pattern must not walk an
# arbitrarily deep tree. Documented in README.md and cleaner.1.
GLOB_RECURSION_MAX_DEPTH=10

# True when a directory looks like a C or C++ build tree. Checked by contents, not
# by name: a directory called "builder" or "buildMatchFn" holds source, and one
# called "build" may hold documentation, so only a build-system marker settles it.
# maxdepth 2 covers the marker sitting in the directory itself and one level below,
# which is where a qmake per-kit layout (build/Desktop-Debug) keeps it.
is_cxx_build_dir() {
  local dir="$1"
  [[ -d "$dir" ]] || return 1
  [[ -n $(find "$dir" -mindepth 1 -maxdepth 2 \
            \( -name CMakeCache.txt -o -name CMakeFiles -o -name build.ninja \
               -o -name meson-info -o -name compile_commands.json \
               -o -name .qmake.stash \) \
            -print -quit 2>/dev/null) ]]
}

# True when a candidate path relative to the literal prefix ($1) matches a
# pattern tail ($2) component by component. A "**" component spans one or more
# whole directory components; any other pattern component matches exactly one
# component via [[ "$comp" == $pat ]] (pattern matching, not pathname expansion).
_glob_parts_match() {
  local ci="$1" pi="$2" cn="${#cand_parts[@]}" pn="${#pat_parts[@]}"
  local pat rem
  while [[ "$pi" -lt "$pn" ]]; do
    pat="${pat_parts[$pi]}"
    if [[ "$pat" == "**" ]]; then
      while [[ $((pi + 1)) -lt "$pn" && "${pat_parts[$((pi + 1))]}" == "**" ]]; do
        pi=$((pi + 1))
        ci=$((ci + 1))
      done
      # "**" must consume at least one component.
      ci=$((ci + 1))
      [[ "$ci" -gt "$cn" ]] && return 1
      pi=$((pi + 1))
      [[ "$pi" -eq "$pn" ]] && return 0
      rem=$((pn - pi))
      while [[ "$ci" -le $((cn - rem)) ]]; do
        _glob_parts_match "$ci" "$pi" && return 0
        ci=$((ci + 1))
      done
      return 1
    fi
    [[ "$ci" -ge "$cn" ]] && return 1
    # Intentionally unquoted on the right side of == inside [[ ]] for pattern matching.
    # shellcheck disable=SC2053
    [[ "${cand_parts[$ci]}" == $pat ]] || return 1
    ci=$((ci + 1))
    pi=$((pi + 1))
  done
  [[ "$ci" -eq "$cn" ]]
}

glob_components_match() {
  local rel_cand="$1" rel_pat="$2"
  local -a cand_parts=() pat_parts=()
  IFS='/' read -r -a cand_parts <<< "$rel_cand"
  IFS='/' read -r -a pat_parts <<< "$rel_pat"
  _glob_parts_match 0 0
}

# Stream the configuration file with wildcard PATH_EXPRESSION lines expanded into
# one line per matching directory. Expansion runs through find, never a shell glob
# and never eval, so the documented no-wildcard-eval contract still holds: only the
# $HOME / ~ / $USER placeholders are substituted, and every expanded match re-enters
# the same safety pipeline (check_path_safety, canonicalize_physical) as a literal
# target. Each emitted line carries its physical source line number and a tab, so a
# line that expands into many still reports config errors against the real line.
expand_config_globs() {
  local line lineno=0 risk raw_path f1 f2 f3 frest pipes fields
  local prefix depth max_depth head tail_part slashes leaf match target_filter ancestor has_globstar
  local -a prune_args
  local -A accepted_matches

  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    pipes="${line//[^|]/}"
    fields=$(( ${#pipes} + 1 ))
    IFS='|' read -r f1 f2 f3 frest <<< "$line"
    risk=$(trim "$f1")
    [[ "$risk" == "protect" ]] && continue
    raw_path=$(trim "$f3")
    # Leave malformed lines intact for the field-count validator.
    if [[ -z "$risk" || "$risk" =~ ^# || "$fields" -lt 5 || "$fields" -gt 7 ]]; then
      printf '%s\t%s\n' "$lineno" "$line"
      continue
    fi

    target_filter=""
    [[ "$fields" -eq 7 ]] && target_filter=$(trim "${frest##*|}")
    if [[ "$raw_path" != *[*?]* ]]; then
      if [[ "$target_filter" == "filter:cxx_build" ]] \
         && ! is_cxx_build_dir "$(expand_path_safe "$raw_path")"; then
        continue
      fi
      printf '%s\t%s\n' "$lineno" "$line"
      continue
    fi

    raw_path=$(expand_path_safe "$raw_path")
    # Collapse redundant slashes and strip trailing slashes to match the literal-path
    # pipeline, so a trailing or doubled slash cannot silently drop the line.
    while [[ "$raw_path" == *//* ]]; do
      raw_path="${raw_path//\/\//\/}"
    done
    raw_path=$(strip_trailing_slashes "$raw_path")

    # Split into the longest wildcard-free leading prefix and the depth of the
    # remaining pattern components, so find scans only below a literal root.
    # This uses parameter expansion only: an unquoted split would itself undergo
    # pathname expansion, which is exactly the shell globbing this must avoid.
    head="${raw_path%%[*?]*}"
    prefix="${head%/*}"
    tail_part="${raw_path#"$prefix"/}"
    slashes="${tail_part//[^\/]/}"
    depth=$(( ${#slashes} + 1 ))
    max_depth="$depth"

    # A "**" component matches one or more intervening directories, so the pattern
    # spans a range of depths instead of one exact depth. Because GNU find's -path
    # lets a plain * cross '/', widen the search bounds here and then verify each
    # candidate component by component via glob_components_match so only a "**"
    # component spans multiple directory levels while * and ? match within a single
    # component. The ceiling is fixed rather than unbounded so a mistyped pattern
    # cannot walk an arbitrarily deep tree; a "**" in the first component is still
    # refused below, because the prefix is then empty.
    has_globstar=false
    if [[ "/$tail_part/" == *"/**/"* || "$tail_part" == "**" ]]; then
      has_globstar=true
      max_depth="$GLOB_RECURSION_MAX_DEPTH"
      [[ "$depth" -gt "$max_depth" ]] && max_depth="$depth"
    fi

    # A wildcard in the first component would make find walk the whole filesystem.
    # Refuse to expand it and pass the line through untouched: the literal pattern
    # then fails the ordinary existence and HOME-boundary checks, so nothing is
    # scanned and nothing is deleted. This runs inside a process substitution, so
    # it warns and degrades rather than trying to abort the run from a subshell.
    if [[ -z "$prefix" ]]; then
      echo -e "${YELLOW}Warning: ${CONFIG_FILE}:${lineno}: wildcard must follow a literal directory, not the filesystem root; leaving '${raw_path}' unexpanded${NC}" >&2
      printf '%s\t%s\n' "$lineno" "$line"
      continue
    fi

    # The last pattern component names the directory itself, so it is matched with
    # -name, which never crosses '/'. -path alone would not do: its * spans slashes,
    # so once the depth bounds widen for "**" a trailing "build*" would also swallow
    # "build/CMakeFiles" and every path below it.
    leaf="${raw_path##*/}"

    # Stop at unfiltered matches. When "**" widens the search depth or a filter is
    # active, find must walk through rejected parents so a candidate rejected by
    # glob_components_match or the filter cannot prune a valid deeper match;
    # descendants of accepted matches are suppressed in bash below.
    #
    # A pattern that matches nothing emits no target and is not an error, matching
    # the existing status of a configured path that does not exist.
    # A filter: token in CUSTOM_ACTION (field 7) constrains which expanded matches
    # become targets. Every accepted directory must still match the path pattern.
    prune_args=(-prune)
    [[ "$target_filter" == "filter:cxx_build" || "$has_globstar" == true ]] && prune_args=()
    accepted_matches=()
    while IFS= read -r -d '' match; do
      [[ -z "$match" ]] && continue
      # Config records are line/pipe-delimited and consumers trim and expand the
      # path again. Refuse a match whose identity would change in that transport.
      if [[ "$match" == *$'\n'* || "$match" == *'|'* \
            || "$match" != "$(trim "$match")" \
            || "$match" != "$(expand_path_safe "$match")" ]]; then
        printf 'Warning: %s:%s: skipping wildcard match that cannot be represented safely: %q\n' \
          "$CONFIG_FILE" "$lineno" "$match" >&2
        continue
      fi
      glob_components_match "${match#"$prefix"/}" "$tail_part" || continue
      if [[ "${#prune_args[@]}" -eq 0 ]]; then
        ancestor="${match%/*}"
        while [[ "$ancestor" == "$prefix"/* ]]; do
          [[ -n "${accepted_matches[$ancestor]:-}" ]] && continue 2
          ancestor="${ancestor%/*}"
        done
      fi
      if [[ "$target_filter" == "filter:cxx_build" ]]; then
        is_cxx_build_dir "$match" || continue
      fi
      [[ "${#prune_args[@]}" -eq 0 ]] && accepted_matches["$match"]=1
      printf '%s\t%s|%s|%s|%s\n' "$lineno" "$f1" "$f2" "$match" "$frest"
    done < <(find "$prefix" -mindepth "$depth" -maxdepth "$max_depth" \
                  -type d -name "$leaf" -path "$raw_path" "${prune_args[@]}" -print0 2>/dev/null | sort -z)
  done < "$CONFIG_FILE"
}

# Resolve a user-supplied log path (--log / LINUX_CLEANER_LOG) with the same
# placeholder rules as config targets, so ~ and $HOME in documented examples work.
if [[ -n "$LOG_FILE" ]]; then
  LOG_FILE=$(expand_path_safe "$LOG_FILE")
fi

# Strip trailing slashes safely (except when path is just "/")
strip_trailing_slashes() {
  local p="$1"
  if [[ "$p" =~ ^/+$ ]]; then
    echo "/"
    return 0
  fi
  while [[ "$p" == */ ]]; do
    p="${p%/}"
  done
  echo "$p"
}

# Canonicalize paths physically (resolves nonexistent paths physically by resolving the closest existing parent directory)
canonicalize_physical() {
  local target="$1"
  if [[ "$target" != /* ]]; then
    target="$PWD/$target"
  fi
  
  # Split the path by '/' using IFS
  local IFS='/'
  local parts
  read -r -a parts <<< "$target"
  
  local resolved="/"
  local comp
  for comp in "${parts[@]}"; do
    if [[ -z "$comp" || "$comp" == "." ]]; then
      continue
    fi
    if [[ "$comp" == ".." ]]; then
      if [[ -e "$resolved" || -L "$resolved" ]]; then
        resolved=$(realpath "$resolved" 2>/dev/null || echo "$resolved")
      fi
      resolved=$(dirname "$resolved")
    else
      local next
      if [[ "$resolved" == "/" ]]; then
        next="/$comp"
      else
        next="$resolved/$comp"
      fi
      if [[ -e "$next" || -L "$next" ]]; then
        resolved=$(realpath "$next" 2>/dev/null || echo "$next")
      else
        resolved="$next"
      fi
    fi
  done
  echo "$resolved"
}

# Build find arguments using the same patterns for global and per-target exclusions.
EXCLUDE_FIND_ARGS=()
build_exclude_find_args() {
  local patterns="${1-${EXCLUDE_PATTERNS:-}}"
  EXCLUDE_FIND_ARGS=()
  if [[ -z "$patterns" ]]; then
    return
  fi
  
  local IFS=','
  local -a pats
  read -r -a pats <<< "$patterns"
  
  if [[ ${#pats[@]} -eq 0 ]]; then
    return
  fi
  
  local -a clauses=()
  local pat
  for pat in "${pats[@]}"; do
    pat=$(trim "$pat")
    if [[ -z "$pat" ]]; then
      continue
    fi
    if [[ ${#clauses[@]} -gt 0 ]]; then
      clauses+=("-o")
    fi
    
    # Check if the pattern contains a slash
    if [[ "$pat" == *"/"* ]]; then
      clauses+=("-path" "$pat" "-o" "-path" "*/$pat" "-o" "-path" "$pat/*" "-o" "-path" "*/$pat/*")
    else
      clauses+=("-name" "$pat" "-o" "-path" "*/$pat/*")
    fi
  done
  
  if [[ ${#clauses[@]} -gt 0 ]]; then
    EXCLUDE_FIND_ARGS+=("!" "(" "${clauses[@]}" ")")
  fi
}

# Rebuild from the global list each time so row exclusions never leak.
set_target_exclusions() {
  TARGET_EXCLUDE_PATTERNS="${EXCLUDE_PATTERNS:-}"
  if [[ "$1" == exclude:* ]]; then
    TARGET_EXCLUDE_PATTERNS+="${TARGET_EXCLUDE_PATTERNS:+,}${1#exclude:}"
  fi
  build_exclude_find_args "$TARGET_EXCLUDE_PATTERNS"
}

# Append one human-readable operation-log line (opt-in). The log is confined to
# $HOME: an out-of-$HOME LINUX_CLEANER_LOG/--log path is refused and logging is
# disabled. Records only path/metadata the tool already prints -- never file
# contents, environment values, or credentials. Non-fatal: a failed write warns
# but never aborts a cleanup under set -euo pipefail.
log_operation() {
  [[ "$LOG_ENABLED" == true ]] || return 0
  local message="$1"
  local target="${LOG_FILE:-}"
  [[ -z "$target" ]] && target="$HOME/.cache/linux-cleaner/operations.log"
  local literal_dir resolved_target
  literal_dir=$(dirname "$target")
  # Canonicalize the FULL target (not just its parent) so a symlinked leaf that
  # resolves outside $HOME is refused, not silently followed by the append.
  resolved_target=$(canonicalize_physical "$target")
  if [[ "$resolved_target" != "$HOME" && "$resolved_target" != "$HOME"/* ]]; then
    echo -e "  [${YELLOW}LOG${NC}] Refusing to write log outside \$HOME ('$target'); logging disabled." >&2
    LOG_ENABLED=false
    return 0
  fi
  if ! { mkdir -p "$literal_dir" && printf '%s\n' "$message" >> "$target"; } 2>/dev/null; then
    echo -e "  [${YELLOW}LOG${NC}] Warning: could not write to log '$target'." >&2
  fi
}

# Print configured cleanup targets (strictly read-only): NAME, risk, path, and
# description for every active config line. No disk analysis or mutation.
list_config_targets() {
  local config_line
  local risk name raw_path desc min_age check_procs custom_clean_cmd

  if [[ "$JSON_OUTPUT" == true ]]; then
    emit_list_targets_json
    return 0
  fi

  echo -e "${BOLD}${BLUE}=== Configured Targets ===${NC}"
  echo -e "Config file: ${YELLOW}$CONFIG_FILE${NC}"
  echo

  while IFS= read -r config_line || [[ -n "$config_line" ]]; do
    config_line="${config_line#*$'\t'}"
    # validate_config_file already rejected malformed records before this runs.
    IFS='|' read -r risk name raw_path desc min_age check_procs custom_clean_cmd <<< "$config_line"
    risk=$(trim "$risk")
    [[ -z "$risk" || "$risk" =~ ^# ]] && continue
    name=$(trim "$name")
    raw_path=$(trim "$raw_path")
    desc=$(trim "$desc")
    printf '%s\t%s\t%s\t%s\n' "$name" "$risk" "$raw_path" "$desc"
  done < <(expand_config_globs)
}

# Validate every active config line with the same structural checks as the
# cleanup parser (field count, required fields, CHECK_PROCESSES, MIN_AGE_DAYS,
# known actions, known risks) without path expansion or disk analysis.
validate_config_file() {
  local config_line config_lineno=0 config_pipes field_count
  local risk name raw_path desc min_age check_procs custom_clean_cmd
  local target_count=0 exclusion_patterns

  while IFS= read -r config_line || [[ -n "$config_line" ]]; do
    config_lineno=$((config_lineno + 1))
    config_pipes="${config_line//[^|]/}"
    field_count=$(( ${#config_pipes} + 1 ))
    IFS='|' read -r risk name raw_path desc min_age check_procs custom_clean_cmd <<< "$config_line"
    risk=$(trim "$risk")
    [[ -z "$risk" || "$risk" =~ ^# ]] && continue
    if [[ "$risk" == "protect" ]]; then
      if [[ "$field_count" -ne 2 ]]; then
        echo -e "${RED}Error: ${CONFIG_FILE}:${config_lineno}: protect line requires 2 fields (protect|PATH), found ${field_count}${NC}" >&2
        exit 1
      fi
      name=$(trim "$name")
      if [[ -z "$name" ]]; then
        echo -e "${RED}Error: ${CONFIG_FILE}:${config_lineno}: protect PATH is empty${NC}" >&2
        exit 1
      fi
      name=$(expand_path_safe "$name")
      if [[ "$name" != /* ]]; then
        echo -e "${RED}Error: ${CONFIG_FILE}:${config_lineno}: protect PATH '${name}' must be absolute${NC}" >&2
        exit 1
      fi
      if [[ "$name" == *[*?\[]* ]]; then
        echo -e "${RED}Error: ${CONFIG_FILE}:${config_lineno}: protect PATH '${name}' cannot contain glob characters${NC}" >&2
        exit 1
      fi
      continue
    fi
    if [[ "$field_count" -lt 5 || "$field_count" -gt 7 ]]; then
      echo -e "${RED}Error: ${CONFIG_FILE}:${config_lineno}: expected 5-7 fields, found ${field_count}${NC}" >&2
      exit 1
    fi
    name=$(trim "$name")
    raw_path=$(trim "$raw_path")
    desc=$(trim "$desc")
    min_age=$(trim "$min_age")
    check_procs=$(trim "${check_procs:-}")
    custom_clean_cmd=$(trim "${custom_clean_cmd:-}")
    if [[ -z "$name" ]]; then
      echo -e "${RED}Error: ${CONFIG_FILE}:${config_lineno}: NAME (field 2) is empty${NC}" >&2
      exit 1
    fi
    if [[ -z "$raw_path" ]]; then
      echo -e "${RED}Error: ${CONFIG_FILE}:${config_lineno}: PATH (field 3) is empty${NC}" >&2
      exit 1
    fi
    if [[ -n "$check_procs" && "$check_procs" =~ (^|,)[[:space:]]*(,|$) ]]; then
      echo -e "${RED}Error: ${CONFIG_FILE}:${config_lineno}: malformed CHECK_PROCESSES '${check_procs}' (empty or stray comma-separated token)${NC}" >&2
      exit 1
    fi
    # A cmdline: token with nothing after the prefix would match every process.
    if [[ "$check_procs" =~ (^|,)[[:space:]]*cmdline:[[:space:]]*(,|$) ]]; then
      echo -e "${RED}Error: ${CONFIG_FILE}:${config_lineno}: malformed CHECK_PROCESSES '${check_procs}' (empty pattern after 'cmdline:')${NC}" >&2
      exit 1
    fi
    if [[ -n "$custom_clean_cmd" ]]; then
      case "$custom_clean_cmd" in
        exclude:*)
          exclusion_patterns="${custom_clean_cmd#exclude:}"
          if [[ -z "$exclusion_patterns" || "$exclusion_patterns" =~ (^|,)[[:space:]]*(,|$) \
                || "$exclusion_patterns" == *'|'* || "$exclusion_patterns" == *$'\n'* \
                || "$exclusion_patterns" == *$'\r'* ]]; then
            echo -e "${RED}Error: ${CONFIG_FILE}:${config_lineno}: malformed CUSTOM_ACTION '${custom_clean_cmd}' (unsafe or empty exclusion pattern)${NC}" >&2
            exit 1
          fi
          ;;
        action:paccache_keep1|action:paccache_keep2|action:paccache_keep3|action:pacman_clean|action:apt_clean|action:dnf_clean|action:zypper_clean|action:apk_clean|action:uv_cache_prune|action:pnpm_store_prune|action:hf_cache_prune|filter:cxx_build)
          ;;
        *)
          echo -e "${RED}${CONFIG_FILE}:${config_lineno}: Error: Unknown action '$custom_clean_cmd' in target '$name'.${NC}" >&2
          exit 1
          ;;
      esac
    fi
    risk_to_int "$risk" "${CONFIG_FILE}:${config_lineno}: " >/dev/null || exit 1
    if [[ -z "$min_age" ]]; then
      :
    elif [[ ! "$min_age" =~ ^[0-9]+$ ]]; then
      echo -e "${RED}Error: ${CONFIG_FILE}:${config_lineno}: invalid MIN_AGE_DAYS '${min_age}'${NC}" >&2
      exit 1
    fi
    target_count=$((target_count + 1))
  done < "$CONFIG_FILE"

  echo "OK: ${target_count} targets in ${CONFIG_FILE}"
}

# Named SESSION arguments for --restore / --purge-sessions must be an immediate
# child of the quarantine base. Reject path separators and `.`/`..` so neither
# mode can escape ~/.cache/linux-cleaner/quarantine/ via a crafted SESSION.
validate_quarantine_session_name() {
  local target="$1"
  if [[ "$target" == */* || "$target" == "." || "$target" == ".." ]]; then
    echo -e "${RED}Error: Invalid session name '$target'.${NC}" >&2
    exit 1
  fi
}

# Print what one quarantine session holds -- the type (full/aged) and original
# path of every record in its quarantine.meta. Strictly read-only. Shared by the
# --list-sessions query and the irreversible purge confirmation, so the safety
# prompt can never be less informative than the read-only one.
print_session_contents() {
  local session="$1"
  local meta="$session/quarantine.meta"
  local mtype morig

  if [[ ! -f "$meta" ]]; then
    echo -e "      ${YELLOW}(no metadata)${NC}"
    return 0
  fi
  while IFS='|' read -r mtype _ morig _ || [[ -n "$mtype" ]]; do
    mtype=$(trim "$mtype")
    [[ -z "$mtype" || "$mtype" =~ ^# ]] && continue
    morig=$(trim "${morig:-}")
    echo -e "      ${mtype}  ${morig}"
  done < "$meta"
}

# List quarantine sessions (strictly read-only): print each session's
# timestamp (directory name), size, and modification date, plus the targets it
# holds. Never moves, deletes, or modifies any session or its metadata.
# With --json, emit a machine-readable inventory instead of human banners.
emit_list_sessions_json() {
  local quarantine_base="$HOME/.cache/linux-cleaner/quarantine"
  local -a sessions=()
  local s session ts size_bytes size_human mdate meta mtype morig
  local sess_first=true tgt_first

  if [[ -d "$quarantine_base" ]]; then
    while IFS= read -r s; do
      [[ -n "$s" ]] && sessions+=("$s")
    done < <(find "$quarantine_base" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
  fi

  printf '{'
  printf '"sessions":['
  for session in "${sessions[@]}"; do
    if [[ "$sess_first" == true ]]; then
      sess_first=false
    else
      printf ','
    fi
    ts=$(basename "$session")
    size_bytes=$({ du -sb "$session" 2>/dev/null || true; } | awk '{s=$1} END {print s+0}')
    [[ -z "$size_bytes" ]] && size_bytes=0
    size_human=$(format_bytes "$size_bytes")
    mdate=$(stat -c '%y' "$session" 2>/dev/null | cut -d'.' -f1)
    printf '{"timestamp":"%s","size_bytes":%s,"size_human":"%s","date":"%s","targets":[' \
      "$(json_escape "$ts")" "$size_bytes" "$(json_escape "$size_human")" "$(json_escape "${mdate:-}")"
    tgt_first=true
    meta="$session/quarantine.meta"
    if [[ -f "$meta" ]]; then
      while IFS='|' read -r mtype _ morig _ || [[ -n "$mtype" ]]; do
        mtype=$(trim "$mtype")
        [[ -z "$mtype" || "$mtype" =~ ^# ]] && continue
        morig=$(trim "${morig:-}")
        if [[ "$tgt_first" == true ]]; then
          tgt_first=false
        else
          printf ','
        fi
        printf '{"type":"%s","path":"%s"}' \
          "$(json_escape "$mtype")" "$(json_escape "$morig")"
      done < "$meta"
    fi
    printf ']}'
  done
  printf ']}\n'
}

list_quarantine_sessions() {
  if [[ "$JSON_OUTPUT" == true ]]; then
    emit_list_sessions_json
    return 0
  fi

  local quarantine_base="$HOME/.cache/linux-cleaner/quarantine"
  local -a sessions=()
  if [[ -d "$quarantine_base" ]]; then
    local s
    while IFS= read -r s; do
      [[ -n "$s" ]] && sessions+=("$s")
    done < <(find "$quarantine_base" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
  fi
  # Empty/missing quarantine is not an error for an informational query.
  if [[ ${#sessions[@]} -eq 0 ]]; then
    echo -e "${YELLOW}No quarantine sessions found.${NC}"
    return 0
  fi
  echo -e "${BOLD}${BLUE}=== Quarantine Sessions ===${NC}"
  local session ts size mdate
  for session in "${sessions[@]}"; do
    ts=$(basename "$session")
    size=$({ du -sh "$session" 2>/dev/null || true; } | awk '{print $1}')
    mdate=$(stat -c '%y' "$session" 2>/dev/null | cut -d'.' -f1)
    echo -e "  ${ts}  size=${size:-?}  date=${mdate:-?}"
    print_session_contents "$session"
  done
}

# Purge (permanently delete) quarantine sessions to reclaim the disk space that
# trash mode holds. Irreversible: purged sessions can no longer be restored. Only
# ever removes directories under the tool-owned quarantine base -- never a path
# outside it. Honors -f/--force to skip the confirmation prompt.
purge_quarantine_sessions() {
  local target="$1"
  local quarantine_base="$HOME/.cache/linux-cleaner/quarantine"

  local days=""

  if [[ "$target" == older-than:* ]]; then
    # Age-based retention: what makes trash mode viable unattended. Without it a
    # cron '--trash --force' accumulates one session per run forever, so the tool
    # would hold the very space it claims to reclaim.
    days="${target#older-than:}"
    if [[ ! "$days" =~ ^[0-9]+$ ]]; then
      echo -e "${RED}Error: Invalid day count in '$target'. Use older-than:<days>, e.g. older-than:30.${NC}" >&2
      exit 1
    fi
    if [[ ! -d "$quarantine_base" ]]; then
      echo -e "${YELLOW}No quarantine sessions older than ${days} day(s).${NC}"
      return 0
    fi
  fi

  if [[ ! -d "$quarantine_base" ]]; then
    echo -e "${RED}Error: No quarantine directory exists at '$quarantine_base'.${NC}" >&2
    exit 1
  fi

  # Resolve the set of session directories to purge.
  local -a targets=()
  if [[ "$target" == "all" ]]; then
    local s
    while IFS= read -r s; do
      [[ -n "$s" ]] && targets+=("$s")
    done < <(find "$quarantine_base" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
    if ! wait "$!"; then
      echo "Error: Failed to enumerate quarantine sessions." >&2
      return 1
    fi
    if [[ ${#targets[@]} -eq 0 ]]; then
      echo -e "${YELLOW}No quarantine sessions found.${NC}"
      return 0
    fi
  elif [[ "$target" == "latest" ]]; then
    local latest
    if ! latest=$(find "$quarantine_base" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n 1); then
      echo "Error: Failed to enumerate quarantine sessions." >&2
      return 1
    fi
    if [[ -z "$latest" ]]; then
      echo -e "${RED}Error: No quarantined sessions found in '$quarantine_base'.${NC}" >&2
      exit 1
    fi
    targets+=("$latest")
  elif [[ "$target" == older-than:* ]]; then
    local s
    while IFS= read -r s; do
      [[ -n "$s" ]] && targets+=("$s")
    done < <(find "$quarantine_base" -mindepth 1 -maxdepth 1 -type d -mtime +"$days" 2>/dev/null | sort)
    if ! wait "$!"; then
      echo "Error: Failed to enumerate quarantine sessions." >&2
      return 1
    fi
    # Nothing old enough is a success for a cron wrapper, not an error.
    if [[ ${#targets[@]} -eq 0 ]]; then
      echo -e "${YELLOW}No quarantine sessions older than ${days} day(s).${NC}"
      return 0
    fi
  else
    # A named session must be an immediate child of the base.
    validate_quarantine_session_name "$target"
    local dir="$quarantine_base/$target"
    if [[ ! -d "$dir" ]]; then
      echo -e "${RED}Error: Quarantine session directory '$dir' does not exist.${NC}" >&2
      exit 1
    fi
    targets+=("$dir")
  fi

  # Show what will be freed -- and exactly which targets are about to be destroyed
  # -- before touching anything. This is the last thing a user sees before the
  # data is gone, so it names every item, not just the session size.
  echo -e "${BOLD}${BLUE}=== Purge Quarantine Sessions ===${NC}"
  local d ts size
  for d in "${targets[@]}"; do
    ts=$(basename "$d")
    size=$({ du -sh "$d" 2>/dev/null || true; } | awk '{print $1}')
    echo -e "  ${ts}  size=${size:-?}"
    print_session_contents "$d"
  done

  # Confirm unless forced -- purge is irreversible.
  if [[ "$FORCE" != true ]]; then
    echo -n -e "${RED}Permanently delete the above quarantine session(s)? This cannot be undone. [y/N]: ${NC}"
    local reply
    read -r reply || true
    if [[ ! "$reply" =~ ^[yY](es)?$ ]]; then
      echo -e "${YELLOW}Aborted. No sessions were purged.${NC}"
      return 0
    fi
  fi

  local purged=0
  for d in "${targets[@]}"; do
    if rm -rf "$d"; then
      echo -e "${GREEN}Purged $(basename "$d")${NC}"
      purged=$((purged + 1))
      log_operation "$(date '+%Y-%m-%dT%H:%M:%S') mode=purge session='$(basename "$d")' outcome=success"
    else
      echo -e "${RED}Error: Failed to purge '$d'.${NC}" >&2
      OPERATION_FAILED=true
      log_operation "$(date '+%Y-%m-%dT%H:%M:%S') mode=purge session='$(basename "$d")' outcome=failed"
    fi
  done

  # Remove the base directory if it is now empty (mirrors restore cleanup).
  rmdir "$quarantine_base" 2>/dev/null || true

  echo -e "${BOLD}Purged ${purged} session(s).${NC}"
}

# Run CMD directly, or through sudo when USE_SUDO (arg 1) is true. Every
# privileged operation goes through here so it is written once, not twice.
with_sudo() {
  local use_sudo="$1"
  shift
  if [[ "$use_sudo" = true ]]; then
    sudo "$@"
  else
    "$@"
  fi
}

# True when PATH exists, including a dangling symlink.
path_present() {
  with_sudo "$1" test -e "$2" || with_sudo "$1" test -L "$2"
}

# True when PATH is a directory and not a symlink to one.
path_is_real_dir() {
  with_sudo "$1" test -d "$2" && ! with_sudo "$1" test -L "$2"
}

# Move a whole target into quarantine and record it in quarantine.meta. The
# record is written ONLY after the move actually succeeded: a record for a file
# that never moved makes every later --restore of the session fail on a missing
# source (and keep the session forever), even though nothing was lost.
# Returns non-zero if the move (or the sudo chown that follows it) failed.
quarantine_move_full() {
  local src="$1" dest="$2" rel="$3" use_sudo="$4" owner_info="$5"
  local moved=false ok=true

  if with_sudo "$use_sudo" mv "$src" "$dest"; then
    moved=true
    if [[ "$use_sudo" = true ]]; then
      sudo chown -R "$(id -u):$(id -g)" "$dest" || ok=false
    fi
  else
    ok=false
  fi

  if [[ "$moved" = true ]]; then
    echo "full|$rel|$src|$use_sudo|$owner_info" >> "$QUARANTINE_DIR/quarantine.meta" || ok=false
  fi
  [[ "$ok" = true ]]
}

# Permanently delete a whole target and account for it. Sets OPERATION_FAILED on a
# failed delete so an unattended run exits non-zero, per cleaner.1's EXIT STATUS
# contract. Adds the target's size to the running total only when the delete worked.
delete_path_full() {
  local target="$1" label="$2" use_sudo="$3" bytes="$4"
  local via=""
  [[ "$use_sudo" = true ]] && via=" with sudo"

  echo -e "  Cleaning ${YELLOW}$label${NC} at '$target'${via}..."
  if with_sudo "$use_sudo" rm -rf "$target"; then
    total_deleted_bytes=$((total_deleted_bytes + bytes))
    return 0
  fi
  echo -e "  ${RED}Error: Failed to delete '$target'${via}${NC}" >&2
  OPERATION_FAILED=true
  # Flag the failure for the result report; a non-zero return would abort the run under set -e.
  target_failed=true
}

# Log one restored (or skipped) quarantine record; a no-op unless logging is on.
log_restore_outcome() {
  log_operation "$(date '+%Y-%m-%dT%H:%M:%S') mode=restore session='$(basename "$1")' path='$2' outcome=$3"
}

# Restore files and folders from a quarantine session
restore_quarantine() {
  local target="$1"
  local quarantine_base="$HOME/.cache/linux-cleaner/quarantine"
  
  if [[ ! -d "$quarantine_base" ]]; then
    echo -e "${RED}Error: No quarantine directory exists at '$quarantine_base'.${NC}" >&2
    exit 1
  fi
  
  local restore_dir=""
  if [[ "$target" == "latest" ]]; then
    # Find the latest subdirectory by sorting
    local latest
    latest=$(find "$quarantine_base" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n 1)
    if [[ -z "$latest" ]]; then
      echo -e "${RED}Error: No quarantined sessions found in '$quarantine_base'.${NC}" >&2
      exit 1
    fi
    restore_dir="$latest"
  else
    # Named session must be an immediate child of the base (same rule as purge).
    validate_quarantine_session_name "$target"
    restore_dir="$quarantine_base/$target"
    if [[ ! -d "$restore_dir" ]]; then
      echo -e "${RED}Error: Quarantine session directory '$restore_dir' does not exist.${NC}" >&2
      exit 1
    fi
  fi
  
  local meta_file="$restore_dir/quarantine.meta"
  if [[ ! -f "$meta_file" ]]; then
    echo -e "${RED}Error: Metadata file 'quarantine.meta' not found in '$restore_dir'.${NC}" >&2
    exit 1
  fi
  
  echo -e "${BOLD}${BLUE}=== Restoring from Quarantine Session: $(basename "$restore_dir") ===${NC}"
  
  # Read metadata line by line
  # Format: TYPE|RELATIVE_PATH|ORIGINAL_PATH|USE_SUDO|UID|GID
  local type rel_path original_path use_sudo uid gid meta_line
  local overall_success=true
  local matched_any=false
  # rel_paths actually moved back out of quarantine. Under --only, the metadata is
  # rewritten from this so every remaining record still points at a file that is
  # present in quarantine -- the same invariant the failed-move fix established.
  local -a restored_rels=()
  while IFS= read -r meta_line || [[ -n "$meta_line" ]]; do
    IFS='|' read -r type rel_path original_path use_sudo uid gid _ <<< "$meta_line"
    type=$(trim "$type")
    [[ -z "$type" || "$type" =~ ^# ]] && continue

    original_path=$(trim "$original_path")
    # --only: leave every non-matching target quarantined, untouched.
    if [[ -n "${RESTORE_ONLY:-}" && "$original_path" != *"$RESTORE_ONLY"* ]]; then
      continue
    fi
    matched_any=true

    rel_path=$(trim "$rel_path")
    original_path=$(trim "$original_path")
    use_sudo=$(trim "$use_sudo")
    uid=$(trim "${uid:-}")
    gid=$(trim "${gid:-}")
    
    if [[ -z "$uid" || -z "$gid" ]]; then
      if [[ "$use_sudo" = true ]]; then
        uid=0
        gid=0
      else
        uid=$(id -u)
        gid=$(id -g)
      fi
    fi
    
    local src_path="$restore_dir/$rel_path"
    if [[ ! -e "$src_path" ]]; then
      echo -e "${YELLOW}Warning: Quarantined source path '$src_path' not found. Skipping.${NC}"
      overall_success=false
      log_restore_outcome "$restore_dir" "$original_path" missing
      continue
    fi
    
    echo -e "Restoring ${YELLOW}$original_path${NC}..."
    
    local success=true had_conflict=false
    # Authenticate before the first privileged probe, so sudo never prompts
    # without the tool's explanation. A failed authentication fails this record
    # only: exiting here would skip the metadata reconciliation below.
    if [[ "$use_sudo" = true ]] && ! ensure_sudo; then
      echo -e "${RED}Error: sudo authentication failed; '$original_path' was not restored.${NC}" >&2
      overall_success=false
      log_restore_outcome "$restore_dir" "$original_path" failed
      continue
    fi
    if [[ "$type" == "full" ]]; then
      if path_present "$use_sudo" "$original_path"; then
        echo -e "${RED}Error: Restore destination '$original_path' already exists. Conflict detected, skipping.${NC}" >&2
        overall_success=false
        log_restore_outcome "$restore_dir" "$original_path" conflict
        continue
      fi

      # A failed mkdir must reach the reconciliation below, not abort under set -e.
      if ! with_sudo "$use_sudo" mkdir -p "$(dirname "$original_path")"; then
        success=false
      elif with_sudo "$use_sudo" mv "$src_path" "$original_path"; then
        with_sudo "$use_sudo" chown -hR "$uid:$gid" "$original_path" 2>/dev/null || true
      else
        success=false
      fi
    elif [[ "$type" == "aged" ]]; then
      if with_sudo "$use_sudo" test -L "$original_path"; then
        echo -e "${RED}Error: Restore destination '$original_path' is a symlink. Conflict detected, skipping.${NC}" >&2
        overall_success=false
        log_restore_outcome "$restore_dir" "$original_path" conflict
        continue
      fi
      if ! with_sudo "$use_sudo" mkdir -p "$original_path"; then
        success=false
      else
        while IFS= read -r -d '' file; do
          local file_rel="${file#"$src_path"/}"
          local dest_file="$original_path/$file_rel"
          local dest_parent check_dir="$original_path" rel_dir part symlink_conflict=false
          dest_parent=$(dirname "$dest_file")
          if [[ "$dest_parent" != "$original_path" ]]; then
            rel_dir="${file_rel%/*}"
            while [[ -n "$rel_dir" ]]; do
              part="${rel_dir%%/*}"
              check_dir="$check_dir/$part"
              if with_sudo "$use_sudo" test -L "$check_dir"; then
                echo -e "${RED}Error: Restore destination path '$check_dir' is a symlink. Conflict detected, skipping '$dest_file'.${NC}" >&2
                symlink_conflict=true
                break
              fi
              [[ "$rel_dir" == "$part" ]] && break
              rel_dir="${rel_dir#*/}"
            done
          fi
          if [[ "$symlink_conflict" = true ]]; then
            success=false
            had_conflict=true
            continue
          fi
          if path_present "$use_sudo" "$dest_file"; then
            echo -e "${RED}Error: Restore destination file '$dest_file' already exists. Conflict detected, skipping.${NC}" >&2
            success=false
            had_conflict=true
            continue
          fi
          if ! with_sudo "$use_sudo" mkdir -p "$dest_parent"; then
            success=false
            continue
          fi
          if with_sudo "$use_sudo" mv "$file" "$dest_file"; then
            with_sudo "$use_sudo" chown -h "$uid:$gid" "$dest_file" 2>/dev/null || true
          else
            success=false
          fi
        done < <(find "$src_path" -mindepth 1 \( -type f -o -type l \) -print0)
        wait "$!" || success=false
      fi
    else
      echo -e "${RED}Error: Unknown restore type '$type' for '$original_path'. Skipping.${NC}" >&2
      overall_success=false
      log_restore_outcome "$restore_dir" "$original_path" failed
      continue
    fi
    
    if [[ "$success" = false ]]; then
      echo -e "${RED}Error: Failed to restore '$original_path'.${NC}" >&2
      overall_success=false
      if [[ "$had_conflict" = true ]]; then
        log_restore_outcome "$restore_dir" "$original_path" conflict
      else
        log_restore_outcome "$restore_dir" "$original_path" failed
      fi
    else
      restored_rels+=("$rel_path")
      log_restore_outcome "$restore_dir" "$original_path" success
      if [[ "$type" == "aged" ]]; then
        find "$src_path" -depth -type d -empty -delete 2>/dev/null || true
      fi
    fi
  done < "$meta_file"

  # A --only pattern that matched nothing restored nothing: say so, don't succeed silently.
  if [[ -n "${RESTORE_ONLY:-}" && "$matched_any" != true ]]; then
    echo -e "${RED}Error: No quarantined target in this session matches '--only ${RESTORE_ONLY}'.${NC}" >&2
    exit 1
  fi

  # Keep metadata aligned with the files still in quarantine. This is required
  # after a partial failure as well as --only: successful sibling restores have
  # already moved out and must not poison a later retry as missing sources.
  local -a retained=()
  if [[ "$overall_success" != true || -n "${RESTORE_ONLY:-}" ]]; then
    local line rp r keep
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" ]] && continue
      IFS='|' read -r _ rp _ <<< "$line"
      rp=$(trim "$rp")
      keep=true
      for r in "${restored_rels[@]}"; do
        if [[ "$r" == "$rp" ]]; then
          keep=false
          break
        fi
      done
      [[ "$keep" == true ]] && retained+=("$line")
    done < "$meta_file"

    if [[ ${#retained[@]} -eq 0 ]]; then
      if [[ "$overall_success" != true ]]; then
        : > "$meta_file"
      fi
    else
      printf '%s\n' "${retained[@]}" > "$meta_file"
    fi
  fi

  if [[ "$overall_success" != true ]]; then
    echo -e "${RED}Error: Restoration completed with some errors. The quarantine session has been kept at '$restore_dir' for recovery.${NC}" >&2
    exit 1
  fi

  # A complete restore may retire the session only when every payload entry was
  # represented by metadata. This catches a move whose post-move metadata write
  # failed, including hidden entries and empty top-level target directories.
  if [[ -z "${RESTORE_ONLY:-}" || ${#retained[@]} -eq 0 ]]; then
    local remaining_path=""
    if ! remaining_path=$(find "$restore_dir" -mindepth 1 -maxdepth 1 ! -name quarantine.meta -print -quit 2>/dev/null); then
      echo -e "${RED}Error: Unable to verify quarantine session contents. The session and metadata have been kept for recovery at '$restore_dir'.${NC}" >&2
      exit 1
    fi
    if [[ -n "$remaining_path" ]]; then
      echo -e "${RED}Error: Unrecorded quarantine payload remains at '$remaining_path'. The session and metadata have been kept for manual recovery.${NC}" >&2
      exit 1
    fi
    rm -rf "$restore_dir"
    rmdir "$quarantine_base" 2>/dev/null || true
    echo -e "${BOLD}${GREEN}Restoration complete!${NC}"
    return 0
  fi

  echo -e "${BOLD}${GREEN}Restoration complete!${NC}"
  if [[ ${#retained[@]} -gt 0 ]]; then
    echo -e "Session ${YELLOW}$(basename "$restore_dir")${NC} kept: ${#retained[@]} target(s) still quarantined."
  fi
}



# Authenticate for sudo. Returns non-zero when privileges are not available so a
# cleanup target can be skipped. No stdin TTY means never prompt (the daily timer).
# A failed or cancelled prompt is remembered for the rest of the run.
SUDO_AUTH_FAILED=false
ensure_sudo() {
  if [[ "$SUDO_AUTH_FAILED" == true ]]; then
    return 1
  fi
  if sudo -n true 2>/dev/null; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    SUDO_AUTH_FAILED=true
    return 1
  fi
  echo -e "${YELLOW}Target(s) require root privileges. Please authenticate for sudo:${NC}"
  if ! sudo -v; then
    SUDO_AUTH_FAILED=true
    return 1
  fi
}

# One stderr warning (--quiet does not hide it) and one opt-in log line.
warn_root_skip() {
  local name="$1" path="$2" risk="$3" mode=delete
  echo "Warning: skipping '$name' ($path): requires root privileges that are not available." >&2
  if [[ "$TRASH_MODE" == true ]]; then
    mode=quarantine
  fi
  log_operation "$(date '+%Y-%m-%dT%H:%M:%S') mode=${mode} risk=${risk} target='${name}' path='${path}' outcome=skipped reason=requires-root"
}

# Check if the path is safe to delete
# Returns:
#   0 if safe
#   1 if it is a sensitive system directory
#   2 if it is outside the user's HOME directory
#   3 if it is a symlink itself
check_path_safety() {
  local target_path="$1"
  
  if [[ -z "$target_path" ]]; then
    return 1
  fi
  
  # Symlink Guard: Refuse to delete the target if it is a symlink itself
  if [[ -L "$target_path" ]]; then
    return 3
  fi
  
  local normalized normalized_home
  normalized=$(canonicalize_physical "$target_path")
  normalized_home=$(canonicalize_physical "$HOME")

  # Never clean HOME itself or any ancestor of HOME, including trailing-slash and dot-dot aliases.
  if [[ "$normalized" == "$normalized_home" || "$normalized_home" == "$normalized"/* ]]; then
    return 1
  fi
  
  # Block critical root and system directories
  if [[ "$normalized" =~ ^/+$ ]] || \
     [[ "$normalized" == "/home" ]] || \
     [[ "$normalized" == "/root" ]] || \
     [[ "$normalized" == "/usr" ]] || \
     [[ "$normalized" == "/var" ]] || \
     [[ "$normalized" == "/etc" ]] || \
     [[ "$normalized" == "/boot" ]] || \
     [[ "$normalized" == "/sys" ]] || \
     [[ "$normalized" == "/proc" ]] || \
     [[ "$normalized" == "/dev" ]] || \
     [[ "$normalized" == "/bin" ]] || \
     [[ "$normalized" == "/sbin" ]] || \
     [[ "$normalized" == "/opt" ]] || \
     [[ "$normalized" == "/srv" ]] || \
     [[ "$normalized" == "/tmp" ]] || \
     [[ "$normalized" == "/run" ]] || \
     [[ "$normalized" == "/mnt" ]] || \
     [[ "$normalized" == "/media" ]] || \
     [[ "$normalized" =~ ^/lib ]]; then
    return 1
  fi
  
  # Warn/error if outside HOME directory
  if [[ "$normalized" != "$normalized_home"/* ]]; then
    return 2
  fi
  
  return 0
}

# Count tracked files without exposing filenames or querying Git with privileges.
# The scanned repository is untrusted: its .git/config can name a core.fsmonitor
# command that ls-files would run, so fsmonitor is forced off on every call.
count_git_tracked() {
  local target_path="$1" git_dir="$1" pathspec=. count=0 inside_work_tree
  if [[ "$EUID" -ne 0 ]] && command -v git >/dev/null 2>&1; then
    if [[ ! -d "$target_path" ]]; then
      git_dir=$(dirname "$target_path")
      pathspec=${target_path##*/}
    fi
    if inside_work_tree=$(git -c core.fsmonitor=false -C "$git_dir" rev-parse --is-inside-work-tree 2>/dev/null) \
       && [[ "$inside_work_tree" == true ]]; then
      count=$(git -c core.fsmonitor=false --literal-pathspecs -C "$git_dir" ls-files -z -- "$pathspec" 2>/dev/null \
        | tr -cd '\000' | wc -c) || count=0
    fi
  fi
  echo "$count"
}

# Treat validated digit-only ages as decimal strings. Bash arithmetic parses a
# leading zero as octal and can overflow on long values; only zero/nonzero is
# needed to choose the age-filter path.
has_positive_age() {
  [[ "$1" =~ [1-9] ]]
}

# Check if there are files that match the age filter criteria
has_matching_files() {
  local target_path="$1"
  local age_days="$2"
  local use_sudo="${3:-false}"

  # Check if the target itself is excluded
  if [[ -n "${TARGET_EXCLUDE_PATTERNS:-}" ]]; then
    if [[ -z $(with_sudo "$use_sudo" find "$target_path" "${EXCLUDE_FIND_ARGS[@]}" -print -quit 2>/dev/null) ]]; then
      return 1
    fi
  fi

  if ! has_positive_age "$age_days"; then
    path_present "$use_sudo" "$target_path"
    return
  fi
  
  if path_is_real_dir "$use_sudo" "$target_path"; then
    # Check if there is any file or symlink inside older than age_days
    # find -print -quit exits 0 if a match is found
    [[ -n $(with_sudo "$use_sudo" find "$target_path" -mindepth 1 "${EXCLUDE_FIND_ARGS[@]}" \( -type f -o -type l \) -mtime +"$age_days" -print -quit 2>/dev/null) ]] && return 0
  else
    # Single file or symlink
    [[ -n $(with_sudo "$use_sudo" find "$target_path" -mtime +"$age_days" -print -quit 2>/dev/null) ]] && return 0
  fi
  return 1
}

# Calculate size in bytes using du (takes into account min_age and exclusions if set)
get_size_bytes() {
  local target_path="$1"
  local age_days="${2:-0}"
  local use_sudo="${3:-false}"

  if ! path_present "$use_sudo" "$target_path"; then
    echo 0
    return
  fi
  
  # Check if the target itself is excluded
  if [[ -n "${TARGET_EXCLUDE_PATTERNS:-}" ]]; then
    if [[ -z $(with_sudo "$use_sudo" find "$target_path" "${EXCLUDE_FIND_ARGS[@]}" -print -quit 2>/dev/null) ]]; then
      echo 0
      return
    fi
  fi

  if path_is_real_dir "$use_sudo" "$target_path"; then
    # Sum size of files/symlinks older than age_days within the directory
    # Exclusions require file-by-file handling even when age_days is 0.
    if [[ -n "${TARGET_EXCLUDE_PATTERNS:-}" ]]; then
      local find_mtime_args=()
      if has_positive_age "$age_days"; then
        find_mtime_args+=("-mtime" "+$age_days")
      fi
      { with_sudo "$use_sudo" find "$target_path" -mindepth 1 "${EXCLUDE_FIND_ARGS[@]}" \( -type f -o -type l \) "${find_mtime_args[@]}" -exec du -sb {} + 2>/dev/null || true; } | awk '{sum+=$1} END {print sum+0}'
    else
      if has_positive_age "$age_days"; then
        { with_sudo "$use_sudo" find "$target_path" -mindepth 1 \( -type f -o -type l \) -mtime +"$age_days" -exec du -sb {} + 2>/dev/null || true; } | awk '{sum+=$1} END {print sum+0}'
      else
        { with_sudo "$use_sudo" du -sb "$target_path" 2>/dev/null || true; } | awk '{s=$1} END {print s+0}'
      fi
    fi
  else
    # If target is a file or symlink, check if it's older than age_days
    if has_positive_age "$age_days"; then
      if [[ -n $(with_sudo "$use_sudo" find "$target_path" -mtime +"$age_days" -print -quit 2>/dev/null) ]]; then
        { with_sudo "$use_sudo" du -sb "$target_path" 2>/dev/null || true; } | awk '{s=$1} END {print s+0}'
      else
        echo 0
      fi
    else
      { with_sudo "$use_sudo" du -sb "$target_path" 2>/dev/null || true; } | awk '{s=$1} END {print s+0}'
    fi
  fi
}

# Format bytes to human readable format
format_bytes() {
  local bytes=$1
  if [[ -z "$bytes" || "$bytes" -eq 0 ]]; then
    echo "0 B"
    return
  fi
  
  local -a units=("B" "KB" "MB" "GB" "TB")
  local unit_idx=0
  local size=$bytes
  
  # Use awk to handle comparison and division with float precision
  while [[ $(awk "BEGIN {print ($size >= 1024 ? 1 : 0)}") -eq 1 && $unit_idx -lt 4 ]]; do
    size=$(awk "BEGIN {printf \"%.2f\", $size / 1024}")
    unit_idx=$((unit_idx + 1))
  done
  
  # Strip unnecessary trailing .00
  size=${size%.00}
  echo "$size ${units[$unit_idx]}"
}

# Compact plan after the savings total. Plain printf (no color, ignores --quiet);
# the caller prints it unless --quiet and always keeps the text for the saved copy.
# --json exits before this runs.
print_plan_report() {
  local i status bytes mode=dry-run shown=0
  local found=0 clean_missing=0 skipped=0 blocked=0 unsafe_symlink=0 root_n=0 protected_n=0
  local safe_b=0 med_b=0 dang_b=0
  local reason name age_note size_label protected_names=""
  local -a rank=()
  local -A skip_groups=() block_groups=()
  [[ "$DRY_RUN" != true ]] && mode=clean
  printf '%s\n' "Plan: mode=${mode} risk=${MAX_RISK} config=${CONFIG_FILE}"
  for i in "${!parsed_names[@]}"; do
    status="${parsed_statuses[$i]:-skipped}"
    bytes="${parsed_sizes[$i]:-0}"
    name="${parsed_names[$i]}"
    case "$status" in
      found) found=$((found + 1)) ;;
      clean|missing) clean_missing=$((clean_missing + 1)) ;;
      skipped)
        skipped=$((skipped + 1))
        reason="${parsed_reasons[$i]:-unspecified}"
        skip_groups["$reason"]="${skip_groups[$reason]:+${skip_groups[$reason]}, }$name"
        ;;
      blocked)
        blocked=$((blocked + 1))
        reason="${parsed_reasons[$i]:-unspecified}"
        block_groups["$reason"]="${block_groups[$reason]:+${block_groups[$reason]}, }$name"
        ;;
      protected)
        protected_n=$((protected_n + 1))
        protected_names+="${protected_names:+, }$name"
        ;;
      unsafe|symlink) unsafe_symlink=$((unsafe_symlink + 1)) ;;
      root) root_n=$((root_n + 1)) ;;
    esac
    if [[ "$status" == found || "$status" == root ]]; then
      case "${parsed_risks[$i],,}" in
        safe) safe_b=$((safe_b + bytes)) ;;
        medium) med_b=$((med_b + bytes)) ;;
        danger|dangerous) dang_b=$((dang_b + bytes)) ;;
      esac
    fi
  done
  printf '%s\n' "Targets: found=${found} clean/missing=${clean_missing} skipped=${skipped} blocked=${blocked} protected=${protected_n} unsafe/symlink=${unsafe_symlink} root=${root_n}"
  printf '%s\n' "Reclaimable by risk: safe=$(format_bytes "$safe_b") medium=$(format_bytes "$med_b") danger=$(format_bytes "$dang_b")"
  if [[ "$found" -gt 0 ]]; then
    mapfile -t rank < <(
      for i in "${!parsed_names[@]}"; do
        if [[ "${parsed_statuses[$i]:-}" == found ]]; then
          printf '%s\t%s\n' "${parsed_sizes[$i]}" "$i"
        fi
      done | sort -nr | cut -f2
    )
    printf '%s\n' "Largest targets:"
    for i in "${rank[@]}"; do
      if [[ "$shown" -ge 10 ]]; then
        printf '%s\n' "  ... and $((${#rank[@]} - 10)) more"
        break
      fi
      age_note=""
      if has_positive_age "${parsed_idle[$i]:-0}"; then
        age_note=" (idle > ${parsed_idle[$i]} days)"
      elif has_positive_age "${parsed_ages[$i]}"; then
        age_note=" (files > ${parsed_ages[$i]} days)"
      fi
      size_label=$(format_bytes "${parsed_sizes[$i]}")
      # User-level prune actions are not sized in advance; 0 B would mislead.
      action_is_user_level "${parsed_cmds[$i]:-}" && size_label="(size at run time)"
      printf '%s\n' "  ${size_label} ${parsed_risks[$i]} ${parsed_names[$i]} ${parsed_paths[$i]}${age_note}"
      shown=$((shown + 1))
    done
  fi
  for reason in "${!skip_groups[@]}"; do
    printf '%s\n' "Skipped (${reason}): ${skip_groups[$reason]}"
  done
  for reason in "${!block_groups[@]}"; do
    printf '%s\n' "Blocked (${reason}): ${block_groups[$reason]}"
  done
  if [[ "$protected_n" -gt 0 ]]; then
    printf '%s\n' "Protected (by config): ${protected_names}"
  fi
  printf '\n'
}

# Always printed, like the final summary. Counts are filled in by the cleanup loop.
print_result_report() {
  local quarantined=0 permanent="$total_deleted_bytes" elapsed
  if [[ "$TRASH_MODE" = true ]]; then
    quarantined=$((total_deleted_bytes - total_action_bytes))
    permanent=$total_action_bytes
  fi
  elapsed=$((SECONDS - CLEANER_START_SECONDS))
  echo "Result: cleaned=${result_cleaned} skipped=${result_skipped} failed=${result_failed} elapsed=${elapsed}s"
  if [[ "$result_failed" -gt 0 ]]; then
    echo "Failed targets: ${result_failed_names}"
  fi
  echo "Reclaimed: quarantined=$(format_bytes "$quarantined") permanent=$(format_bytes "$permanent")"
  if [[ -n "$QUARANTINE_DIR" ]]; then
    echo "Quarantine session: ${QUARANTINE_DIR}"
  fi
}

# Read-only print of the last saved cleanup report. A symlink is not followed.
show_last_report() {
  local state_dir report_file
  state_dir="$(_xdg_dir XDG_STATE_HOME "$HOME/.local/state")/linux-cleaner"
  report_file="${state_dir}/last-report.txt"
  if [[ -L "$state_dir" || -L "$report_file" || ! -f "$report_file" ]]; then
    echo "No cleanup report yet." >&2
    exit 1
  fi
  cat -- "$report_file"
}

# Save the plan plus the result. Non-fatal: a bad state path or a write error
# warns and leaves the cleanup's exit status unchanged. The state path is
# untrusted, so a symlink is never followed and readers never see a partial file.
save_last_cleanup_report() {
  local state_dir report_file tmp body
  state_dir="$(_xdg_dir XDG_STATE_HOME "$HOME/.local/state")/linux-cleaner"
  report_file="${state_dir}/last-report.txt"
  if [[ -L "$state_dir" || -L "$report_file" ]]; then
    echo "Warning: refusing to write the cleanup report; the state path is a symlink." >&2
    return 0
  fi
  if ! (
    umask 077
    mkdir -p -- "$state_dir"
  ); then
    echo "Warning: could not create the cleanup report directory." >&2
    return 0
  fi
  if [[ -L "$state_dir" || -L "$report_file" ]]; then
    echo "Warning: refusing to write the cleanup report; the state path is a symlink." >&2
    return 0
  fi
  if [[ ! -d "$state_dir" ]] || ! chmod 700 -- "$state_dir"; then
    echo "Warning: could not create the cleanup report directory." >&2
    return 0
  fi
  tmp=$(mktemp "${state_dir}/last-report.XXXXXX" 2>/dev/null) || {
    echo "Warning: could not create a temporary cleanup report." >&2
    return 0
  }
  body=$(printf 'Saved: %s\n%s\n\n%s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$PLAN_REPORT_TEXT" "$RESULT_REPORT_TEXT" | sed $'s/\033\\[[0-9;]*m//g') || {
    rm -f -- "$tmp" || true
    echo "Warning: could not format the cleanup report." >&2
    return 0
  }
  if ! printf '%s\n' "$body" > "$tmp"; then
    rm -f -- "$tmp" || true
    echo "Warning: could not write the cleanup report." >&2
    return 0
  fi
  if ! mv -f -- "$tmp" "$report_file"; then
    rm -f -- "$tmp" || true
    echo "Warning: could not save the cleanup report." >&2
    return 0
  fi
}

# Check if any specified process is running
# True when some process OTHER than this run matches PATTERN on its command line.
# The whole ancestry is excluded, not just our own PID: an invoking shell, wrapper
# script or scheduler carries our arguments in its command line too, so matching one
# of those would block every target forever while nothing is actually running.
_cmdline_match() {
  local pattern="$1" pid ancestry=" "
  [[ -z "$pattern" ]] && return 1

  # Seed from $$, not $BASHPID: at script level the two are equal, so seeding with
  # BASHPID would make the first loop test fail and the walk never start.
  pid=$$
  while [[ -n "$pid" && "$pid" != 0 && "$ancestry" != *" $pid "* ]]; do
    ancestry+="$pid "
    # Read PPid from status rather than stat: a comm containing spaces or parens
    # shifts stat's positional fields and would give the wrong parent.
    pid=$(awk '/^PPid:/{print $2}' "/proc/$pid/status" 2>/dev/null)
  done
  # Differs from $$ only inside a subshell, so add it after the walk.
  ancestry+="$BASHPID "

  while read -r pid; do
    [[ -z "$pid" ]] && continue
    # A process that has already exited cannot be the application running, and the
    # match set routinely contains short-lived helpers (pgrep itself, subshells).
    [[ -r "/proc/$pid/cmdline" ]] || continue
    [[ "$ancestry" == *" $pid "* ]] && continue
    _is_own_descendant "$pid" && continue
    return 0
  done < <(pgrep -f -- "$pattern" 2>/dev/null)
  return 1
}

# True when PID sits below this run in the process tree. A subshell or helper we
# spawned inherits our arguments, so it can match our own pattern; it is never the
# application we are guarding against. Bounded so a malformed /proc cannot loop.
_is_own_descendant() {
  local pid="$1" hops=0
  while [[ -n "$pid" && "$pid" != 0 && "$hops" -lt 32 ]]; do
    [[ "$pid" == "$$" ]] && return 0
    pid=$(awk '/^PPid:/{print $2}' "/proc/$pid/status" 2>/dev/null)
    hops=$((hops + 1))
  done
  return 1
}

is_process_running() {
  local procs="$1"
  if [[ -z "$procs" ]]; then
    return 1
  fi
  
  # Split with read, not an unquoted expansion: word splitting would also
  # pathname-expand each token against the current directory, so a pattern such
  # as "app*" could turn into a stray file name and silently miss the process.
  local proc
  local -a proc_list
  IFS=',' read -r -a proc_list <<< "$procs"
  for proc in "${proc_list[@]}"; do
    proc=$(trim "$proc")
    if [[ "$proc" == cmdline:* ]]; then
      # A tool launched through a shared runtime (Electron, node) has a comm that is
      # not its own name, so exact-comm matching silently never fires. Match the full
      # command line instead -- but pgrep -f also matches THIS script whenever the
      # pattern appears in our own argv (a config path, or --only-target naming the
      # tool), which would block every target forever. Drop our own PIDs first and
      # treat an otherwise-empty result as "not running".
      if _cmdline_match "${proc#cmdline:}"; then
        echo "$proc"
        return 0
      fi
    else
      # The kernel keeps only the first 15 characters of a process name, and
      # pgrep -x refuses a longer plain name outright, so compare such a name on
      # its first 15. Regex-bearing tokens are the user's own and pass unchanged.
      local comm="$proc"
      [[ ${#comm} -gt 15 && "$comm" =~ ^[A-Za-z0-9_-]+$ ]] && comm="${comm:0:15}"
      if pgrep -x "$comm" >/dev/null; then
        echo "$proc"
        return 0
      fi
    fi
  done
  return 1
}

# Map risk level string to integer weight
risk_to_int() {
  case "${1,,}" in
    safe) echo 1 ;;
    medium) echo 2 ;;
    danger|dangerous) echo 3 ;;
    *)
      echo -e "${RED}${2:-}Error: Unknown risk level '$1'. Valid levels are: safe, medium, danger.${NC}" >&2
      exit 1
      ;;
  esac
}

# Single source of truth: map each predefined action to the binary its execution
# arm actually invokes. This is the binary the safe-degradation guard checks --
# note paccache ships separately from pacman (in pacman-contrib), so checking the
# package manager alone would not catch a missing paccache. New actions extend
# exactly this one structure (empty for an unknown token).
action_required_binary() {
  case "${1#action:}" in
    paccache_keep1|paccache_keep2|paccache_keep3) echo "paccache" ;;
    pacman_clean) echo "pacman" ;;
    apt_clean) echo "apt-get" ;;
    dnf_clean) echo "dnf" ;;
    zypper_clean) echo "zypper" ;;
    apk_clean) echo "apk" ;;
    uv_cache_prune) echo "uv" ;;
    pnpm_store_prune) echo "pnpm" ;;
    hf_cache_prune) echo "hf" ;;
    *) echo "" ;;
  esac
}

# True when a predefined action runs as the invoking user without sudo and
# measures reclaimed bytes from filesystem free-space delta at run time.
action_is_user_level() {
  case "${1:-}" in
    action:uv_cache_prune|action:pnpm_store_prune|action:hf_cache_prune) return 0 ;;
    *) return 1 ;;
  esac
}

action_display_command() {
  case "${1:-}" in
    action:uv_cache_prune) echo "uv cache prune" ;;
    action:pnpm_store_prune) echo "pnpm store prune" ;;
    action:hf_cache_prune) echo "hf cache prune --yes" ;;
    *) echo "" ;;
  esac
}

# Free space in bytes on the filesystem holding PATH.
get_fs_avail_bytes() {
  { df -B1 --output=avail -- "$1" 2>/dev/null || true; } | awk 'NR>1 && $1 ~ /^[0-9]+$/ {v=$1} END {print v+0}'
}

# Preflight: probe the GNU-coreutils behaviors this tool depends on (du -sb,
# stat -c, find -print0/-quit, GNU realpath) against a throwaway temp path.
# Returns 0 if all pass. No side effects beyond a self-cleaned temp dir.
check_gnu_userland() {
  local probe_dir probe_file ok=0
  probe_dir=$(mktemp -d 2>/dev/null) || return 1
  probe_file="$probe_dir/probe"
  : > "$probe_file"
  du -sb "$probe_file" >/dev/null 2>&1 || ok=1
  stat -c '%u' "$probe_file" >/dev/null 2>&1 || ok=1
  find "$probe_dir" -print0 -quit >/dev/null 2>&1 || ok=1
  realpath "$probe_file" >/dev/null 2>&1 || ok=1
  rm -rf "$probe_dir"
  return "$ok"
}

MAX_RISK_INT=$(risk_to_int "$MAX_RISK") || exit 1

# Build exclude arguments for find
build_exclude_find_args

# Read-only: print the saved last cleanup report and exit.
if [[ "$REPORT" == true ]]; then
  show_last_report
  exit 0
fi

# Read-only: list quarantine sessions and exit
if [[ "$LIST_SESSIONS" == true ]]; then
  list_quarantine_sessions
  exit 0
fi

# Validate physical records before an unmatched wildcard or a filter can remove
# one from the stream. Session operations intentionally do not require a config.
if [[ -z "$RESTORE_TARGET" && -z "$PURGE_TARGET" && "$CHECK_CONFIG" != true ]]; then
  validate_config_file >/dev/null
fi

if [[ "$LIST_TARGETS" == true ]]; then
  list_config_targets
  exit 0
fi

if [[ "$CHECK_CONFIG" == true ]]; then
  validate_config_file
  exit 0
fi

# Serialize mutating runs (restore, purge, and non-dry-run cleanup) with an
# exclusive non-blocking flock so overlapping timer and manual invocations
# cannot race on the same files or quarantine sessions. Dry-run and read-only
# modes never take the lock; if flock is not installed, continue unlocked.
if [[ -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" || "$DRY_RUN" != true ]]; then
  if command -v flock >/dev/null 2>&1; then
    lock_dir="$HOME/.cache/linux-cleaner"
    lock_file="$lock_dir/cleaner.lock"
    if [[ -L "$lock_dir" || -L "$lock_file" ]]; then
      echo -e "${RED}Error: Refusing to open symlinked lock path '$lock_file'.${NC}" >&2
      exit 1
    fi
    if ! (umask 077; mkdir -p -- "$lock_dir"); then
      echo -e "${RED}Error: Failed to create lock directory '$lock_dir'.${NC}" >&2
      exit 1
    fi
    if [[ -L "$lock_dir" || -L "$lock_file" || ! -d "$lock_dir" ]]; then
      echo -e "${RED}Error: Refusing to open symlinked lock path '$lock_file'.${NC}" >&2
      exit 1
    fi
    if ! (umask 077; : >> "$lock_file") 2>/dev/null || [[ -L "$lock_file" ]] || ! exec 9>"$lock_file"; then
      echo -e "${RED}Error: Failed to open lock file '$lock_file'.${NC}" >&2
      exit 1
    fi
    if ! flock -n 9; then
      echo -e "${RED}Error: another linux-cleaner run is in progress (lock: ${lock_file}).${NC}" >&2
      exit 1
    fi
  fi
fi

# Check if restore mode is active
if [[ -n "${RESTORE_TARGET:-}" ]]; then
  restore_quarantine "$RESTORE_TARGET"
  exit 0
fi

# Check if purge mode is active
if [[ -n "${PURGE_TARGET:-}" ]]; then
  purge_quarantine_sessions "$PURGE_TARGET"
  if [[ "$OPERATION_FAILED" = true ]]; then
    exit 1
  fi
  exit 0
fi

# Header output
status_echo "${BOLD}${BLUE}=== Linux Cache & Temp File Cleaner ===${NC}"
status_echo "Config file: ${YELLOW}$CONFIG_FILE${NC}"
status_echo "Max Risk Level: ${YELLOW}$MAX_RISK${NC}"
if [[ "$TRASH_MODE" = true ]]; then
  status_echo "Trash mode: ${GREEN}ON (Quarantine)${NC}"
else
  status_echo "Trash mode: ${RED}OFF (Permanent deletion)${NC}"
fi
status_echo ""

# Arrays to store processed target info
parsed_names=()
parsed_paths=()
parsed_descs=()
parsed_sizes=()
parsed_exists=()
parsed_safety=()
parsed_ages=()
parsed_idle=()
parsed_risks=()
parsed_cmds=()
parsed_sudos=()
parsed_statuses=()
parsed_reasons=()

json_names=()
json_paths=()
json_risks=()
json_bytes=()
json_runtime_sized=()
json_statuses=()
json_reasons=()
json_descs=()
json_ages=()

total_reclaimable_bytes=0
only_target_matched=false
name_filter_kept=false

# Collect canonical paths from protect|PATH config lines before target analysis.
PROTECTED_PATHS=()
collect_protected_paths() {
  local line f1 f2 expanded stripped
  PROTECTED_PATHS=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    IFS='|' read -r f1 f2 _ <<< "$line"
    [[ "$(trim "$f1")" == "protect" ]] || continue
    expanded=$(expand_path_safe "$(trim "$f2")")
    stripped=$(strip_trailing_slashes "$expanded")
    PROTECTED_PATHS+=("$(canonicalize_physical "$stripped")")
  done < "$CONFIG_FILE"
}

# True when canonical target path equals, lies under, or contains a protected path
# (whole path components only: /opt/a does not match /opt/ab).
is_path_protected() {
  local target="$1" p
  for p in "${PROTECTED_PATHS[@]}"; do
    if [[ "$p" == / || "$target" == "$p" || "$target" == "$p"/* || "$p" == "$target"/* ]]; then
      return 0
    fi
  done
  return 1
}

collect_protected_paths

# First pass: Parse config line-by-line safely and analyze targets
status_echo "${BOLD}Analyzing targets...${NC}"

# Read configuration file line by line
config_lineno=0
while IFS= read -r config_line || [[ -n "$config_line" ]]; do
  # The physical (1-based) source line number arrives as a tab-prefixed field from
  # expand_config_globs, so a wildcard line that expands into many targets still
  # reports errors against the real config line.
  config_lineno="${config_line%%$'\t'*}"
  config_line="${config_line#*$'\t'}"
  # validate_config_file already rejected malformed records (field count, empty
  # NAME/PATH, CHECK_PROCESSES, CUSTOM_ACTION, risk, MIN_AGE_DAYS) before this runs.
  IFS='|' read -r risk name raw_path desc min_age check_procs custom_clean_cmd <<< "$config_line"
  risk=$(trim "$risk")
  [[ -z "$risk" || "$risk" =~ ^# ]] && continue

  name=$(trim "$name")
  raw_path=$(trim "$raw_path")
  desc=$(trim "$desc")
  min_age=$(trim "$min_age")
  check_procs=$(trim "${check_procs:-}")
  custom_clean_cmd=$(trim "${custom_clean_cmd:-}")
  set_target_exclusions "$custom_clean_cmd"

  if [[ -n "$ONLY_TARGET" ]]; then
    if ! name_matches_any "$name" "${ONLY_TARGET_PATTERNS[@]}"; then
      continue
    fi
    only_target_matched=true
  fi
  if [[ -n "$EXCLUDE_TARGET" ]]; then
    if name_matches_any "$name" "${EXCLUDE_TARGET_PATTERNS[@]}"; then
      continue
    fi
  fi
  name_filter_kept=true

  # Map risk levels
  target_risk_int=$(risk_to_int "$risk" "${CONFIG_FILE}:${config_lineno}: ") || exit 1
  if [[ $target_risk_int -gt $MAX_RISK_INT ]]; then
    # Skip target quietly or verbosely
    continue
  fi
  
  # An empty age means the whole directory (effective 0).
  [[ -z "$min_age" ]] && min_age=0
  effective_age="$min_age"
  idle_age=0
  if [[ "$custom_clean_cmd" == "filter:cxx_build" ]] && has_positive_age "$min_age"; then
    effective_age=0
    idle_age="$min_age"
  fi
  
  # Safe path expansions & cleanup trailing slashes
  expanded_path=$(expand_path_safe "$raw_path")
  stripped_path=$(strip_trailing_slashes "$expanded_path")
  
  # Resolve to canonical
  path=$(canonicalize_physical "$stripped_path")
  
  # Run safety check
  safety_status=0
  if [[ -L "$stripped_path" ]]; then
    safety_status=3
  else
    check_path_safety "$path" || safety_status=$?
  fi
  
  exists=false
  size_bytes=0
  runtime_sized=false
  use_sudo=false
  target_status=""
  target_reason=""
  
  if [[ $safety_status -eq 1 ]]; then
    target_status=unsafe
    status_echo "  [${RED}UNSAFE${NC}] $name: Path '$path' is a protected system directory! Skipping."
  elif [[ $safety_status -eq 3 ]]; then
    target_status=symlink
    status_echo "  [${RED}SYMLINK${NC}] $name: Refusing to delete symlink target '$path'. Skipping."
    safety_status=1 # Treat as completely unsafe to skip deletion later
  elif is_path_protected "$path"; then
    target_status=protected
    target_reason="protected by config"
    debug_echo "  [PROTECTED] $name: '$path' is protected by the config. Skipping."
    safety_status=1 # Treat as unsafe to skip deletion later
  else
    # safety_status 2 (outside HOME) is cleaned like an in-HOME target.
    if [[ "$custom_clean_cmd" == action:* ]] \
         && required_bin=$(action_required_binary "$custom_clean_cmd") \
         && ! command -v "$required_bin" >/dev/null 2>&1; then
      target_status=skipped
      target_reason="'$required_bin' not available"
      status_echo "  [${YELLOW}SKIP${NC}] $name: skipped: '$required_bin' not available on this platform."
    else
      # Check if running processes block this target
      running_proc=$(is_process_running "$check_procs" || true)
      if [[ -n "$running_proc" ]]; then
        target_status=blocked
        target_reason="process '$running_proc' is active"
        status_echo "  [${YELLOW}BLOCKED${NC}] $name: Skip cleanup because process '$running_proc' is active."
      else
        # Determine if sudo is needed. A dry-run only probes with sudo -n and
        # never prompts. A real run skips the target when privileges are unavailable.
        requires_sudo=false
        root_unavailable=false
        if { [[ "$custom_clean_cmd" == action:* ]] && ! action_is_user_level "$custom_clean_cmd"; } || \
           [[ -e "$path" && ! -r "$path" ]] || \
           { [[ ! -e "$path" ]] && [[ "$safety_status" -eq 2 ]] && [[ ! -w "$(dirname "$path" 2>/dev/null || echo /)" ]]; }; then
          requires_sudo=true
          if [[ "$DRY_RUN" = false ]]; then
            if ensure_sudo; then
              use_sudo=true
            else
              root_unavailable=true
              use_sudo=false
              target_status=skipped
              target_reason="requires root"
              warn_root_skip "$name" "$path" "$risk"
            fi
          elif sudo -n true 2>/dev/null; then
            use_sudo=true
          else
            use_sudo=false
          fi
        fi

        git_tracked_count=0
        if [[ "$root_unavailable" != true && -e "$path" && "$requires_sudo" != true ]]; then
          git_tracked_count=$(count_git_tracked "$path")
        fi
        if [[ "$root_unavailable" == true ]]; then
          :
        elif [[ "$git_tracked_count" -gt 0 ]]; then
          target_status=skipped
          target_reason="$git_tracked_count git-tracked file(s)"
          status_echo "  [${YELLOW}SKIP${NC}] $name: skipped: contains $git_tracked_count git-tracked file(s) under '$path'."
        elif [[ "$DRY_RUN" = true ]] && [[ "$requires_sudo" = true ]] && [[ "$use_sudo" = false ]]; then
          # Try to get size without sudo. If it's readable, we show it, but warn that sudo is required for cleanup
          size_bytes=$(get_size_bytes "$path" "$effective_age" false)
          readable_size=$(format_bytes "$size_bytes")
          if [[ "$size_bytes" -gt 0 ]]; then
            target_status=root
            status_echo "  [${YELLOW}ROOT${NC}] $name ($readable_size): Requires sudo; size may be inaccurate and sudo is required for cleanup."
            total_reclaimable_bytes=$((total_reclaimable_bytes + size_bytes))
          else
            target_status=root
            status_echo "  [${YELLOW}ROOT${NC}] $name: Requires sudo; size is unavailable in dry-run."
          fi
          exists=true
        else
          if path_present "$use_sudo" "$path"; then
            if action_is_user_level "$custom_clean_cmd"; then
              size_bytes=0
              runtime_sized=true
              exists=true
              target_status=found
              outside_home_suffix=""
              [[ $safety_status -eq 2 ]] && outside_home_suffix=" (outside HOME)"
              debug_echo "  [${GREEN}FOUND${NC}] $name: size measured at run time ($(action_display_command "$custom_clean_cmd"))$outside_home_suffix"
            elif has_positive_age "$idle_age" \
               && [[ -n $(with_sudo "$use_sudo" find "$path" "${EXCLUDE_FIND_ARGS[@]}" -mtime -"$idle_age" -print -quit 2>/dev/null) ]]; then
              target_status=clean
              debug_echo "  [${BLUE}CLEAN${NC}] $name: active within $idle_age days."
            else
              size_bytes=$(get_size_bytes "$path" "$effective_age" "$use_sudo")
              readable_size=$(format_bytes "$size_bytes")
              
              should_clean=false
              if has_positive_age "$effective_age" || [[ -n "${TARGET_EXCLUDE_PATTERNS:-}" ]]; then
                if has_matching_files "$path" "$effective_age" "$use_sudo"; then
                  should_clean=true
                fi
              else
                if ! path_is_real_dir "$use_sudo" "$path" || [[ "$size_bytes" -gt 0 ]]; then
                  should_clean=true
                fi
              fi
              
              if [[ "$should_clean" = true ]]; then
                exists=true
                total_reclaimable_bytes=$((total_reclaimable_bytes + size_bytes))
                
                target_status=found
                outside_home_suffix=""
                [[ $safety_status -eq 2 ]] && outside_home_suffix=" (outside HOME)"
                if has_positive_age "$idle_age"; then
                  debug_echo "  [${GREEN}FOUND${NC}] $name ($readable_size): $desc (Idle > $idle_age days)$outside_home_suffix"
                elif has_positive_age "$effective_age"; then
                  debug_echo "  [${GREEN}FOUND${NC}] $name ($readable_size): $desc (Files > $effective_age days)$outside_home_suffix"
                else
                  debug_echo "  [${GREEN}FOUND${NC}] $name ($readable_size): $desc$outside_home_suffix"
                fi
              else
                target_status=clean
                if has_positive_age "$effective_age"; then
                  debug_echo "  [${BLUE}CLEAN${NC}] $name: No files older than $effective_age days."
                else
                  debug_echo "  [${BLUE}CLEAN${NC}] $name: Target size is 0 B."
                fi
              fi
            fi
          else
            target_status=missing
            debug_echo "  [${BLUE}CLEAN${NC}] $name: Path '$path' does not exist."
          fi
        fi
      fi
    fi
  fi
  
  if [[ "$JSON_OUTPUT" == true ]]; then
    json_names+=("$name")
    json_paths+=("$path")
    json_risks+=("$risk")
    json_bytes+=("$size_bytes")
    json_runtime_sized+=("$runtime_sized")
    json_statuses+=("${target_status:-skipped}")
    json_reasons+=("${target_reason:-}")
    json_descs+=("$desc")
    json_ages+=("$min_age")
  fi

  # Keep track of valid targets for execution
  parsed_names+=("$name")
  parsed_paths+=("$path")
  parsed_descs+=("$desc")
  parsed_sizes+=("$size_bytes")
  parsed_exists+=("$exists")
  parsed_safety+=("$safety_status")
  parsed_ages+=("$effective_age")
  parsed_idle+=("$idle_age")
  parsed_risks+=("$risk")
  parsed_cmds+=("$custom_clean_cmd")
  parsed_sudos+=("$use_sudo")
  parsed_statuses+=("${target_status:-skipped}")
  parsed_reasons+=("${target_reason:-}")

done < <(expand_config_globs)

if [[ -n "$ONLY_TARGET" && "$only_target_matched" != true ]]; then
  echo -e "${RED}Error: No config target NAME matches '--only-target ${ONLY_TARGET}'.${NC}" >&2
  exit 1
fi

if [[ -n "$EXCLUDE_TARGET" && "$name_filter_kept" != true ]]; then
  echo -e "${RED}Error: --exclude-target ${EXCLUDE_TARGET} left no config targets to process.${NC}" >&2
  exit 1
fi

if [[ "$JSON_OUTPUT" == true ]]; then
  emit_dry_run_json
  exit 0
fi

echo
echo -e "${BOLD}Total potential space savings: ${GREEN}$(format_bytes "$total_reclaimable_bytes")${NC}"
echo

# Captured once, with no color codes (the printer uses printf, not the color vars).
PLAN_REPORT_TEXT=$(print_plan_report)
if [[ "$QUIET" != true ]]; then
  printf '%s\n\n' "$PLAN_REPORT_TEXT"
fi

# Whether any analyzed target is cleanable (user-level prune rows count even at 0 B).
has_cleanable_target=false
for i in "${!parsed_exists[@]}"; do
  if [[ "${parsed_exists[$i]}" == true && "${parsed_safety[$i]}" -ne 1 ]]; then
    has_cleanable_target=true
    break
  fi
done

# If dry-run is specified, we stop here
if [[ "$DRY_RUN" = true ]]; then
  status_echo "${YELLOW}Dry-run mode active. No files were modified.${NC}"
  if [[ -n "$MIN_RECLAIM" && "$total_reclaimable_bytes" -lt "$MIN_RECLAIM_BYTES" ]]; then
    status_echo "Below --min-reclaim ${MIN_RECLAIM}: a cleanup run would skip."
  elif [[ "$total_reclaimable_bytes" -gt 0 || "$has_cleanable_target" == true ]]; then
    status_echo "Next: run 'cleaner --clean' to apply this plan, or 'cleaner --clean --trash' to quarantine instead of deleting."
  fi
  exit 0
fi

if [[ -n "$MIN_RECLAIM" && "$total_reclaimable_bytes" -lt "$MIN_RECLAIM_BYTES" ]]; then
  echo "Planned reclaim $(format_bytes "$total_reclaimable_bytes") is below --min-reclaim ${MIN_RECLAIM}; nothing was cleaned."
  RESULT_REPORT_TEXT="Result: skipped below --min-reclaim ${MIN_RECLAIM}"
  save_last_cleanup_report
  exit 0
fi

# Check if there is anything to clean
if [[ "$total_reclaimable_bytes" -eq 0 && "$has_cleanable_target" != true ]]; then
  echo -e "${GREEN}No files need cleaning. Everything is already clean!${NC}"
  # Overwrite the previous report so --report never shows a stale run as the last one.
  RESULT_REPORT_TEXT="Result: nothing to clean"
  save_last_cleanup_report
  exit 0
fi

# Determine whether to proceed based on options
proceed_all=false
if [[ "$FORCE" = true ]]; then
  proceed_all=true
elif [[ "$INTERACTIVE" = false ]]; then
  # Default mode: ask for confirmation once for everything
  echo -n -e "${BOLD}Do you want to clean all the found items? [y/N]: ${NC}"
  read -r reply || true
  if [[ "$reply" =~ ^[yY](es)?$ ]]; then
    proceed_all=true
  else
    echo -e "${YELLOW}Cleanup aborted.${NC}"
    exit 0
  fi
fi

# GNU-userland preflight: this tool relies on GNU coreutils/findutils flags on
# the deletion path; check them before any destructive operation.
if check_gnu_userland; then GNU_USERLAND_OK=true; else GNU_USERLAND_OK=false; fi
if [[ "$GNU_USERLAND_OK" != true ]]; then
  echo -e "${RED}Error: GNU coreutils are required for cleanup (du -sb, stat -c, find -print0/-quit, GNU realpath). Refusing to delete on a non-GNU userland; re-run with --dry-run for a best-effort preview.${NC}" >&2
  exit 1
fi

# Second pass: Perform deletion or move to quarantine
status_echo "${BOLD}Starting cleanup...${NC}"
total_deleted_bytes=0
total_action_bytes=0
result_cleaned=0
result_skipped=0
# Analysis-time skips (requires root, git-tracked files, missing binary) never
# reach the loop below; count them so the result agrees with the plan's skipped=.
for i in "${!parsed_statuses[@]}"; do
  if [[ "${parsed_statuses[$i]}" == skipped ]]; then
    result_skipped=$((result_skipped + 1))
  fi
done
result_failed=0
result_failed_names=""

QUARANTINE_DIR=""

handle_cleanup_signal() {
  local sig="$1" code="$2"
  trap - INT TERM
  RESULT_REPORT_TEXT="$(print_result_report)"$'\n'"Interrupted: ${sig} before all targets finished"
  printf '%s\n' "$RESULT_REPORT_TEXT"
  save_last_cleanup_report
  log_operation "$(date '+%Y-%m-%dT%H:%M:%S') mode=run outcome=interrupted signal=${sig}"
  exit "$code"
}
trap 'handle_cleanup_signal SIGINT 130' INT
trap 'handle_cleanup_signal SIGTERM 143' TERM

for i in "${!parsed_names[@]}"; do
  name="${parsed_names[$i]}"
  target_failed=false
  path="${parsed_paths[$i]}"
  size="${parsed_sizes[$i]}"
  exists="${parsed_exists[$i]}"
  safety="${parsed_safety[$i]}"
  age="${parsed_ages[$i]}"
  risk_level="${parsed_risks[$i]}"
  
  # Skip targets that don't exist, are unsafe, or had 0 B reclaimable size
  if [[ "$exists" != true || "$safety" -eq 1 ]]; then
    continue
  fi

  use_sudo="${parsed_sudos[$i]:-false}"
  if [[ "$use_sudo" == true ]] && ! ensure_sudo; then
    warn_root_skip "$name" "$path" "$risk_level"
    result_skipped=$((result_skipped + 1))
    continue
  fi

  # Dangerous Confirmation Guard
  danger_prompted=false
  if [[ "${risk_level,,}" =~ ^danger(ous)?$ && "$YES_DANGER" != true ]]; then
    echo -n -e "${RED}Danger target '$name' ($path) requires explicit confirmation. Clean anyway? [y/N]: ${NC}"
    read -r reply || true
    if [[ ! "$reply" =~ ^[yY](es)?$ ]]; then
      status_echo "  Skipping $name..."
      result_skipped=$((result_skipped + 1))
      continue
    fi
    danger_prompted=true
  fi
  
  # Interactive mode confirmation (ask for each target)
  if [[ "$INTERACTIVE" = true && "$proceed_all" = false && "$danger_prompted" != true ]]; then
    readable_size=$(format_bytes "$size")
    # User-level prune actions are not sized in advance; 0 B would mislead.
    action_is_user_level "${parsed_cmds[$i]:-}" && readable_size="size at run time"
    if has_positive_age "$age"; then
      echo -n -e "Clean old files (> $age days) in '$name' ($readable_size) at '$path'? [y/N]: "
    else
      echo -n -e "Clean target '$name' ($readable_size) at '$path'? [y/N]: "
    fi
    read -r reply || true
    if [[ ! "$reply" =~ ^[yY](es)?$ ]]; then
      status_echo "  Skipping $name..."
      result_skipped=$((result_skipped + 1))
      continue
    fi
  fi
  
  # Handle Cleanup
  custom_clean_cmd="${parsed_cmds[$i]:-}"
  set_target_exclusions "$custom_clean_cmd"

  if [[ "$custom_clean_cmd" == action:* ]]; then
    # Safe degradation: skip an action whose actual binary is absent, before any
    # sudo call (e.g. paccache when pacman-contrib is not installed, or apt/dnf on
    # the wrong distro), so it is a clean skip rather than a failed sudo call.
    required_bin=$(action_required_binary "$custom_clean_cmd")
    if [[ -n "$required_bin" ]] && ! command -v "$required_bin" >/dev/null 2>&1; then
      status_echo "  [${YELLOW}SKIP${NC}] $name: skipped: '$required_bin' not available on this platform."
      result_skipped=$((result_skipped + 1))
      continue
    fi
    if [[ "$TRASH_MODE" = true ]]; then
      status_echo "  ${YELLOW}WARNING:${NC} Target '$name' uses a predefined action. This action will bypass quarantine and run directly (irreversible deletion)!"
    else
      status_echo "  Executing action for ${YELLOW}$name${NC}..."
    fi
    avail_before=0
    if action_is_user_level "$custom_clean_cmd"; then
      avail_before=$(get_fs_avail_bytes "$path")
    fi
    action_success=false
    case "$custom_clean_cmd" in
      action:paccache_keep1)
        if sudo paccache -rk1; then
          action_success=true
        fi
        ;;
      action:paccache_keep2)
        if sudo paccache -rk2; then
          action_success=true
        fi
        ;;
      action:paccache_keep3)
        if sudo paccache -rk3; then
          action_success=true
        fi
        ;;
      action:pacman_clean)
        if sudo pacman -Sc --noconfirm; then
          action_success=true
        fi
        ;;
      action:apt_clean)
        if sudo apt-get clean; then
          action_success=true
        fi
        ;;
      action:dnf_clean)
        if sudo dnf clean all; then
          action_success=true
        fi
        ;;
      action:zypper_clean)
        if sudo zypper clean -a; then
          action_success=true
        fi
        ;;
      action:apk_clean)
        if sudo apk cache clean; then
          action_success=true
        fi
        ;;
      action:uv_cache_prune)
        if uv cache prune --cache-dir "$path"; then
          action_success=true
        fi
        ;;
      action:pnpm_store_prune)
        if pnpm store prune --store-dir "$path"; then
          action_success=true
        fi
        ;;
      action:hf_cache_prune)
        if hf cache prune --yes --cache-dir "$path"; then
          action_success=true
        fi
        ;;
    esac
    if [[ "$action_success" = true ]]; then
      credited_bytes="$size"
      if action_is_user_level "$custom_clean_cmd"; then
        avail_after=$(get_fs_avail_bytes "$path")
        credited_bytes=$((avail_after - avail_before))
        if [[ "$credited_bytes" -lt 0 ]]; then
          credited_bytes=0
        fi
      fi
      total_deleted_bytes=$((total_deleted_bytes + credited_bytes))
      total_action_bytes=$((total_action_bytes + credited_bytes))
      result_cleaned=$((result_cleaned + 1))
      log_operation "$(date '+%Y-%m-%dT%H:%M:%S') mode=action risk=${risk_level} target='${name}' path='${path}' action=${custom_clean_cmd} outcome=success"
    else
      echo -e "  ${RED}Error: Action '$custom_clean_cmd' for '$name' failed.${NC}" >&2
      OPERATION_FAILED=true
      result_failed=$((result_failed + 1))
      result_failed_names+="${result_failed_names:+, }${name}"
      log_operation "$(date '+%Y-%m-%dT%H:%M:%S') mode=action risk=${risk_level} target='${name}' path='${path}' action=${custom_clean_cmd} outcome=failed"
    fi
    continue
  fi

  if [[ "$TRASH_MODE" = true ]]; then
    # Allocate one session lazily, after confirmation and only for a target
    # that will actually be moved to quarantine.
    if [[ -z "$QUARANTINE_DIR" ]]; then
      time_stamp=$(date +%Y-%m-%d_%H-%M-%S)
      quarantine_base="$HOME/.cache/linux-cleaner/quarantine"
      (umask 077; mkdir -p "$quarantine_base")
      session_suffix=0
      while true; do
        if [[ "$session_suffix" -eq 0 ]]; then
          QUARANTINE_DIR="$quarantine_base/$time_stamp"
        else
          printf -v session_suffix_text '%06d' "$session_suffix"
          QUARANTINE_DIR="$quarantine_base/${time_stamp}_${session_suffix_text}"
        fi
        if mkdir -m 700 "$QUARANTINE_DIR" 2>/dev/null; then
          break
        fi
        if [[ -e "$QUARANTINE_DIR" || -L "$QUARANTINE_DIR" ]]; then
          session_suffix=$((session_suffix + 1))
          continue
        fi
        echo -e "${RED}Error: Failed to create quarantine session '$QUARANTINE_DIR'.${NC}" >&2
        exit 1
      done
      status_echo "Quarantine directory: ${YELLOW}$QUARANTINE_DIR${NC}"
    fi

    status_echo "  Moving ${YELLOW}$name${NC} to quarantine..."
    
    safe_name=$(printf '%s' "$name" | tr '/[:space:]' '__')
    q_target="$QUARANTINE_DIR/${i}_${safe_name}"
    
    success=true
    # Failures below are recorded per target; under set -e a bare failing
    # command would otherwise end the whole run and skip every later target.
    with_sudo "$use_sudo" mkdir -p "$(dirname "$q_target")" || success=false
    # Unknown ownership falls back to root for a privileged target, else to us.
    owner_fallback="$(id -u)|$(id -g)"
    [[ "$use_sudo" = true ]] && owner_fallback="0|0"
    owner_info=$(with_sudo "$use_sudo" stat -c '%u|%g' "$path" 2>/dev/null || echo "$owner_fallback")

    if has_positive_age "$age" || [[ -n "${TARGET_EXCLUDE_PATTERNS:-}" ]]; then
      # File-by-file quarantine
      if path_is_real_dir "$use_sudo" "$path"; then
        find_mtime_args=()
        if has_positive_age "$age"; then
          find_mtime_args+=("-mtime" "+$age")
        fi
        
        aged_moved=false
        with_sudo "$use_sudo" mkdir -p "$q_target" || success=false
        while IFS= read -r -d '' file; do
          rel_path="${file#"$path"/}"
          dest_file="$q_target/$rel_path"
          if ! with_sudo "$use_sudo" mkdir -p "$(dirname "$dest_file")"; then
            success=false
            continue
          fi
          if with_sudo "$use_sudo" mv "$file" "$dest_file"; then
            if [[ "$aged_moved" = false ]]; then
              aged_moved=true
              echo "aged|${i}_${safe_name}|$path|$use_sudo|$owner_info" >> "$QUARANTINE_DIR/quarantine.meta" || success=false
            fi
          else
            success=false
          fi
        done < <(with_sudo "$use_sudo" find "$path" -mindepth 1 "${EXCLUDE_FIND_ARGS[@]}" \( -type f -o -type l \) "${find_mtime_args[@]}" -print0)
        wait "$!" || success=false
        with_sudo "$use_sudo" find "$q_target" -depth -type d -empty -delete 2>/dev/null || true
        if [[ "$aged_moved" = true && "$use_sudo" = true ]]; then
          sudo chown -R "$(id -u):$(id -g)" "$q_target" || success=false
        fi
        with_sudo "$use_sudo" find "$path" -mindepth 1 "${EXCLUDE_FIND_ARGS[@]}" -type d -empty -delete 2>/dev/null || true
      else
        # Single file or symlink
        if ! quarantine_move_full "$path" "$q_target" "${i}_${safe_name}" "$use_sudo" "$owner_info"; then
          success=false
        fi
      fi
    else
      # Full folder/file quarantine (no age limit, no exclusions)
      if ! quarantine_move_full "$path" "$q_target" "${i}_${safe_name}" "$use_sudo" "$owner_info"; then
        success=false
      fi
    fi
    
    if [[ "$success" = true ]]; then
      total_deleted_bytes=$((total_deleted_bytes + size))
    else
      echo -e "  ${RED}Error: Failed to move some files for '$name' to quarantine.${NC}" >&2
      OPERATION_FAILED=true
      target_failed=true
    fi
    
  else
    # Permanent Deletion Mode
    if has_positive_age "$age" || [[ -n "${TARGET_EXCLUDE_PATTERNS:-}" ]]; then
      if path_is_real_dir "$use_sudo" "$path"; then
        find_mtime_args=()
        if has_positive_age "$age"; then
          find_mtime_args+=("-mtime" "+$age")
        fi
        via=""
        [[ "$use_sudo" = true ]] && via=" with sudo"

        status_echo "  Cleaning filtered files in ${YELLOW}$name${NC}${via}..."
        if with_sudo "$use_sudo" find "$path" -mindepth 1 "${EXCLUDE_FIND_ARGS[@]}" \( -type f -o -type l \) "${find_mtime_args[@]}" -delete && \
           with_sudo "$use_sudo" find "$path" -mindepth 1 "${EXCLUDE_FIND_ARGS[@]}" -type d -empty -delete 2>/dev/null; then
          total_deleted_bytes=$((total_deleted_bytes + size))
        else
          echo -e "  ${RED}Error: Failed to completely clean aged/filtered files in '$path'${via}${NC}" >&2
          OPERATION_FAILED=true
          target_failed=true
        fi
      else
        # Single file or symlink deletion
        delete_path_full "$path" "$name" "$use_sudo" "$size"
      fi
    else
      # Full folder/file deletion
      delete_path_full "$path" "$name" "$use_sudo" "$size"
    fi
  fi

  # Log the quarantine/delete outcome for this target (opt-in; the predefined
  # action path logs and continues before reaching here). Records only
  # path/metadata the tool already prints -- never file contents.
  if [[ "$LOG_ENABLED" == true ]]; then
    if [[ "$target_failed" == true ]]; then
      op_outcome=failed
    else
      op_outcome=success
    fi
    if [[ "$TRASH_MODE" = true ]]; then
      log_operation "$(date '+%Y-%m-%dT%H:%M:%S') mode=quarantine risk=${risk_level} target='${name}' path='${path}' outcome=${op_outcome}"
    else
      log_operation "$(date '+%Y-%m-%dT%H:%M:%S') mode=delete risk=${risk_level} target='${name}' path='${path}' outcome=${op_outcome}"
    fi
  fi
  if [[ "$target_failed" == true ]]; then
    result_failed=$((result_failed + 1))
    result_failed_names+="${result_failed_names:+, }${name}"
  else
    result_cleaned=$((result_cleaned + 1))
  fi
done
trap - INT TERM

RESULT_REPORT_TEXT=$(print_result_report)
printf '%s\n' "$RESULT_REPORT_TEXT"
save_last_cleanup_report

echo
if [[ "$TRASH_MODE" = true ]]; then
  if [[ "$total_action_bytes" -gt 0 ]]; then
    quarantine_bytes=$((total_deleted_bytes - total_action_bytes))
    echo -e "${BOLD}${GREEN}Cleanup finished! Total space quarantined: $(format_bytes "$quarantine_bytes"); permanently reclaimed by actions: $(format_bytes "$total_action_bytes")${NC}"
  else
    echo -e "${BOLD}${GREEN}Cleanup finished! Total space quarantined: $(format_bytes "$total_deleted_bytes")${NC}"
  fi
else
  echo -e "${BOLD}${GREEN}Cleanup finished! Total space permanently reclaimed: $(format_bytes "$total_deleted_bytes")${NC}"
fi

# Report a non-zero status when any target failed, so an unattended run (cron,
# systemd) can detect a failure that was otherwise only printed to stderr.
if [[ "$OPERATION_FAILED" = true ]]; then
  echo -e "${RED}One or more targets failed to clean; see the errors above.${NC}" >&2
  exit 1
fi
