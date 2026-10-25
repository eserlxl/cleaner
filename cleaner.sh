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
readonly VERSION="1.8.0"

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
  --check-health SECONDS     With --report: exit 0 only for a successful report at most SECONDS old (skips succeed).
  --list-targets             List configured cleanup targets (read-only) and exit.
  --check-config             Validate the configuration file and exit (no disk analysis).
  --init-config              Copy the active config to your user config path (never overwrites).
  --doctor                   Check the runtime environment a cleanup depends on (read-only) and exit.
  --restore SESSION          Restore files from quarantine session (latest or timestamp); --dry-run previews.
  --hold-session SESSION     Protect a quarantine session (latest or timestamp) from every purge and --trash-keep-days retention.
  --release-session SESSION  Remove a session hold so normal purge and retention apply again.
  --only PATTERN             With --restore: restore only targets whose original path contains PATTERN; the rest stay quarantined.
  --only-exact PATH          With --restore: match a literal original path from session inventory; excludes --only.
  --only-target PATTERN      With cleanup or --list-targets: select config targets whose NAME contains PATTERN.
  --exclude-target PATTERN   With cleanup or --list-targets: skip config targets whose NAME contains PATTERN.
  --only-path PATH           With cleanup or --list-targets: select ordinary targets at/below an existing absolute path; excludes action:* rows (env: LINUX_CLEANER_ONLY_PATH).
  --exclude-path PATH        With cleanup or --list-targets: skip targets at, below, or containing an existing absolute path (env: LINUX_CLEANER_EXCLUDE_PATH).
  --lock-wait SECONDS        With mutating runs: wait up to 0..2147483647 seconds for the lock (default: 0; env: LINUX_CLEANER_LOCK_WAIT).
  --min-reclaim SIZE         With cleanup: skip the run when the planned reclaim is below SIZE (e.g. 500M, 2G).
  --min-free SIZE            With cleanup: skip the run when the selected filesystem (default: HOME) has at least SIZE free (e.g. 10G).
  --min-free-path PATH       Measure PATH's filesystem for --min-free; requires an absolute existing path and --min-free.
  --min-age DAYS             With cleanup: raise every ordinary target's age threshold to at least DAYS days; skips action:* rows (env: LINUX_CLEANER_MIN_AGE).
  --action-timeout SECONDS   With cleanup: stop each action:* command after SECONDS seconds and count it failed (0: no limit; env: LINUX_CLEANER_ACTION_TIMEOUT).
  --trash-keep-days DAYS     With cleanup: purge quarantine sessions older than DAYS days after cleaning.
  --purge-sessions SESSION   Permanently delete quarantine session(s) to reclaim space (latest, all, older-than:DAYS, max-size:SIZE, keep-latest:N, or timestamp); --dry-run previews. Irreversible.
  --allow-outside-home       Deprecated no-op; targets outside HOME are always allowed.
  --log [FILE]               Append an operation log (opt-in, off by default; kept under your HOME).
  -q, --quiet                Suppress per-target status lines; keep errors, totals, and final summary.
  --debug                    Show per-target FOUND, CLEAN and PROTECTED lines (suppressed by default; overridden by --quiet).
  --show-matches             List eligible paths under each ordinary target in a text dry run (overridden by --quiet).
  --exit-code                Dry-run only: exit 2 if cleanup would run, 0 if it would skip (errors: 1).
  --notify                   With cleanup: send a desktop notification summarizing the result (no-op on dry-run; env: LINUX_CLEANER_NOTIFY).
  --fail-fast                With cleanup: stop after the first failed target and skip inline retention (env: LINUX_CLEANER_FAIL_FAST).
  --json                     Emit machine-readable JSON (--dry-run summary, --list-targets inventory, --list-sessions inventory, or --report summary).
  -h, --help                 Display this help message and exit.
  -V, --version              Print the tool version and exit.
EOF
}

# Default flags
DRY_RUN=true
DRY_RUN_EXPLICIT=false
CLEAN_EXPLICIT=false
INTERACTIVE=false
FORCE=false
YES_DANGER=false
QUIET=false
DEBUG=false
SHOW_MATCHES=false
EXIT_CODE=false
NOTIFY=false
# Only the flag is refused outside cleanup; an inherited mirror is ignored there.
NOTIFY_CLI=false
NOTIFY_SENT=false
FAIL_FAST=false
FAIL_FAST_CLI=false
JSON_OUTPUT=false
TRASH_MODE=false
MAX_RISK="safe"
EXCLUDE_PATTERNS=""
RESTORE_TARGET=""
RESTORE_ONLY=""
RESTORE_ONLY_MODE="--only"
HOLD_TARGET=""
RELEASE_TARGET=""
ONLY_TARGET=""
EXCLUDE_TARGET=""
ONLY_PATH=""
ONLY_PATH_CANONICAL=""
EXCLUDE_PATH=""
EXCLUDE_PATH_CANONICAL=""
MIN_RECLAIM=""
MIN_RECLAIM_BYTES=0
MIN_FREE=""
MIN_FREE_BYTES=0
MIN_FREE_PATH=""
MIN_AGE_OVERRIDE=""
ACTION_TIMEOUT=""
TRASH_KEEP_DAYS=""
LOCK_WAIT="${LINUX_CLEANER_LOCK_WAIT:-0}"
PURGE_TARGET=""
LIST_SESSIONS=false
LIST_TARGETS=false
CHECK_CONFIG=false
INIT_CONFIG=false
DOCTOR=false
CONFIG_DISCOVERED=false
CONFIG_EXPLICIT=false
REPORT=false
CHECK_HEALTH=""
PLAN_REPORT_TEXT=""
RESULT_REPORT_TEXT=""
RESULT_FAILED_TARGETS=()

# Set by any operation that was attempted and failed (a delete, a quarantine move,
# a predefined action, a purge). The tool exits non-zero when it is set, per the
# contract in cleaner.1 ("non-zero on ... a failed operation") -- an unattended run
# must be able to detect a failure it only printed to stderr. Deliberate skips (a
# declined danger target, a blocked process, an unsafe path, a target whose root
# privileges are not available, an action whose binary
# is absent) are not failures and leave this false.
OPERATION_FAILED=false
RETENTION_FAILED=false
CLEANUP_METRICS_WRITTEN=false

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
case "${LINUX_CLEANER_NOTIFY:-}" in
  1|true|TRUE|yes|YES) NOTIFY=true ;;
esac
case "${LINUX_CLEANER_FAIL_FAST:-}" in
  1|true|TRUE|yes|YES) FAIL_FAST=true ;;
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
if [[ -n "${LINUX_CLEANER_ONLY_PATH:-}" ]]; then
  ONLY_PATH="$LINUX_CLEANER_ONLY_PATH"
fi
if [[ -n "${LINUX_CLEANER_EXCLUDE_PATH:-}" ]]; then
  EXCLUDE_PATH="$LINUX_CLEANER_EXCLUDE_PATH"
fi
if [[ -n "${LINUX_CLEANER_MIN_RECLAIM:-}" ]]; then
  MIN_RECLAIM="$LINUX_CLEANER_MIN_RECLAIM"
fi
if [[ -n "${LINUX_CLEANER_MIN_FREE:-}" ]]; then
  MIN_FREE="$LINUX_CLEANER_MIN_FREE"
fi
if [[ -n "${LINUX_CLEANER_MIN_FREE_PATH:-}" ]]; then
  MIN_FREE_PATH="$LINUX_CLEANER_MIN_FREE_PATH"
fi
if [[ -n "${LINUX_CLEANER_MIN_AGE:-}" ]]; then
  MIN_AGE_OVERRIDE="$LINUX_CLEANER_MIN_AGE"
fi
if [[ -n "${LINUX_CLEANER_ACTION_TIMEOUT:-}" ]]; then
  ACTION_TIMEOUT="$LINUX_CLEANER_ACTION_TIMEOUT"
fi
if [[ -n "${LINUX_CLEANER_TRASH_KEEP_DAYS:-}" ]]; then
  TRASH_KEEP_DAYS="$LINUX_CLEANER_TRASH_KEEP_DAYS"
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

journal_error_line() {
  [[ -n "${JOURNAL_STREAM:-}" && "${JOURNAL_ERROR_WRITTEN:-false}" != true ]] || return 0
  local stderr_stream msg="$*"
  # Duplicate stderr before suppressing stat errors so the stream check stays valid.
  stderr_stream=$(stat -L -c '%d:%i' /dev/fd/3 3>&2 2>/dev/null) || return 0
  [[ "$JOURNAL_STREAM" == "$stderr_stream" ]] || return 0
  msg=${msg//$'\n'/ }
  msg=${msg//$'\r'/ }
  printf '<3>linux-cleaner: %s\n' "$msg" >&2 || return 0
  JOURNAL_ERROR_WRITTEN=true
}

notify_failed_exit() {
  local status=$?
  [[ "$status" -ne 0 ]] || return 0
  [[ "$status" -eq 2 && "${preview_exit_status:-0}" -eq 2 ]] && return "$status"
  # The retention unit runs purge mode; its early exits (lock timeout, bad selector) count too.
  if [[ -n "${PURGE_TARGET:-}" ]]; then
    journal_error_line "Quarantine purge ${PURGE_TARGET} failed with exit status ${status}."
    return "$status"
  fi
  if [[ -n "${RESTORE_TARGET:-}" || -n "${HOLD_TARGET:-}" || -n "${RELEASE_TARGET:-}" || "${LIST_SESSIONS:-false}" == true || "${LIST_TARGETS:-false}" == true || "${CHECK_CONFIG:-false}" == true || "${REPORT:-false}" == true || "${INIT_CONFIG:-false}" == true || "${DOCTOR:-false}" == true ]]; then
    return "$status"
  fi
  # Scheduled previews (the monitor unit) and argument errors stop before any cleanup.
  if [[ "${DRY_RUN:-true}" != false ]]; then
    journal_error_line "Run stopped with exit status ${status} before cleaning."
    return "$status"
  fi
  if [[ "${CLEANUP_METRICS_WRITTEN:-false}" != true ]] && declare -F write_cleanup_metrics >/dev/null 2>&1; then
    OPERATION_FAILED=true
    write_cleanup_metrics || true
  fi
  journal_error_line "Cleanup stopped with exit status ${status} before finishing."
  if [[ "${NOTIFY:-false}" != true || "${NOTIFY_SENT:-false}" == true ]]; then
    return "$status"
  fi
  if command -v notify-send >/dev/null 2>&1; then
    local msg="Cleanup stopped with exit status ${status} before finishing; see journalctl --user -t linux-cleaner."
    if command -v timeout >/dev/null 2>&1; then
      timeout 5 notify-send --app-name=linux-cleaner --urgency=critical "linux-cleaner" "$msg" >/dev/null 2>&1 || true
    else
      notify-send --app-name=linux-cleaner --urgency=critical "linux-cleaner" "$msg" >/dev/null 2>&1 || true
    fi
  fi
  exit "$status"
}
trap notify_failed_exit EXIT

# A missing value must not swallow the next flag: "-e $EMPTY --dry-run" would
# otherwise turn the requested preview into a cleanup. Other single-dash values
# stay valid (target NAMEs such as "-n" or "-e" are supported); only -d is refused.
require_non_option_value() {
  local flag="$1" val="$2"
  if [[ "$val" =~ ^--[[:alpha:]] || "$val" == -d ]]; then
    echo -e "${RED}Error: $flag requires a value, got option '$val'.${NC}" >&2
    exit 1
  fi
}

# Parse command line options
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--config)
      if [[ -z "${2:-}" ]]; then
        echo -e "${RED}Error: --config requires a file path argument.${NC}" >&2
        exit 1
      fi
      require_non_option_value "$1" "$2"
      CONFIG_FILE="$2"
      shift 2
      ;;
    -d|--dry-run)
      DRY_RUN=true
      DRY_RUN_EXPLICIT=true
      shift
      ;;
    --clean)
      CLEAN_EXPLICIT=true
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
    --show-matches)
      SHOW_MATCHES=true
      DEBUG=true
      shift
      ;;
    --exit-code)
      EXIT_CODE=true
      shift
      ;;
    --notify)
      NOTIFY=true
      NOTIFY_CLI=true
      shift
      ;;
    --fail-fast)
      FAIL_FAST=true
      FAIL_FAST_CLI=true
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
      require_non_option_value "$1" "$2"
      MAX_RISK="$2"
      shift 2
      ;;
    -e|--exclude)
      if [[ -z "${2:-}" ]]; then
        echo -e "${RED}Error: --exclude requires a pattern argument.${NC}" >&2
        exit 1
      fi
      require_non_option_value "$1" "$2"
      EXCLUDE_PATTERNS="$2"
      shift 2
      ;;
    --restore)
      if [[ -z "${2:-}" ]]; then
        echo -e "${RED}Error: --restore requires a session argument (latest or timestamp).${NC}" >&2
        exit 1
      fi
      require_non_option_value "$1" "$2"
      RESTORE_TARGET="$2"
      shift 2
      ;;
    --hold-session|--release-session)
      if [[ -z "${2:-}" ]]; then
        echo -e "${RED}Error: $1 requires a session argument (latest or timestamp).${NC}" >&2
        exit 1
      fi
      require_non_option_value "$1" "$2"
      if [[ "$1" == --hold-session ]]; then
        HOLD_TARGET="$2"
      else
        RELEASE_TARGET="$2"
      fi
      shift 2
      ;;
    --only|--only-exact)
      if [[ -z "${2:-}" ]]; then
        if [[ "$1" == --only ]]; then
          echo -e "${RED}Error: --only requires a pattern argument.${NC}" >&2
        else
          echo -e "${RED}Error: --only-exact requires a path argument.${NC}" >&2
        fi
        exit 1
      fi
      require_non_option_value "$1" "$2"
      if [[ -n "$RESTORE_ONLY" && "$RESTORE_ONLY_MODE" != "$1" ]]; then
        echo "Error: --only and --only-exact cannot be combined." >&2
        exit 1
      fi
      RESTORE_ONLY_MODE="$1"
      RESTORE_ONLY="$2"
      shift 2
      ;;
    --only-target)
      if [[ -z "${2:-}" ]]; then
        echo -e "${RED}Error: --only-target requires a pattern argument.${NC}" >&2
        exit 1
      fi
      require_non_option_value "$1" "$2"
      ONLY_TARGET="$2"
      shift 2
      ;;
    --exclude-target)
      if [[ -z "${2:-}" ]]; then
        echo -e "${RED}Error: --exclude-target requires a pattern argument.${NC}" >&2
        exit 1
      fi
      require_non_option_value "$1" "$2"
      EXCLUDE_TARGET="$2"
      shift 2
      ;;
    --only-path)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --only-path requires a literal absolute path without line feeds." >&2
        exit 1
      fi
      require_non_option_value "$1" "$2"
      if [[ "$2" != /* || "$2" == *$'\n'* ]]; then
        echo "Error: --only-path requires a literal absolute path without line feeds." >&2
        exit 1
      fi
      ONLY_PATH="$2"
      shift 2
      ;;
    --exclude-path)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --exclude-path requires a literal absolute path without line feeds." >&2
        exit 1
      fi
      require_non_option_value "$1" "$2"
      if [[ "$2" != /* || "$2" == *$'\n'* ]]; then
        echo "Error: --exclude-path requires a literal absolute path without line feeds." >&2
        exit 1
      fi
      EXCLUDE_PATH="$2"
      shift 2
      ;;
    --lock-wait)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --lock-wait requires a seconds argument." >&2
        exit 1
      fi
      require_non_option_value "$1" "$2"
      LOCK_WAIT="$2"
      shift 2
      ;;
    --min-reclaim)
      if [[ -z "${2:-}" ]]; then
        echo -e "${RED}Error: --min-reclaim requires a size argument.${NC}" >&2
        exit 1
      fi
      require_non_option_value "$1" "$2"
      MIN_RECLAIM="$2"
      shift 2
      ;;
    --min-free)
      if [[ -z "${2:-}" ]]; then
        echo -e "${RED}Error: --min-free requires a size argument.${NC}" >&2
        exit 1
      fi
      require_non_option_value "$1" "$2"
      MIN_FREE="$2"
      shift 2
      ;;
    --min-free-path)
      if [[ -z "${2:-}" ]]; then
        echo -e "${RED}Error: --min-free-path requires a path argument.${NC}" >&2
        exit 1
      fi
      require_non_option_value "$1" "$2"
      MIN_FREE_PATH="$2"
      shift 2
      ;;
    --min-age)
      if [[ -z "${2:-}" ]]; then
        echo -e "${RED}Error: --min-age requires a day count argument.${NC}" >&2
        exit 1
      fi
      require_non_option_value "$1" "$2"
      MIN_AGE_OVERRIDE="$2"
      shift 2
      ;;
    --action-timeout)
      if [[ -z "${2:-}" ]]; then
        echo -e "${RED}Error: --action-timeout requires a seconds argument.${NC}" >&2
        exit 1
      fi
      require_non_option_value "$1" "$2"
      ACTION_TIMEOUT="$2"
      shift 2
      ;;
    --trash-keep-days)
      if [[ -z "${2:-}" ]]; then
        echo -e "${RED}Error: --trash-keep-days requires a day count argument.${NC}" >&2
        exit 1
      fi
      require_non_option_value "$1" "$2"
      TRASH_KEEP_DAYS="$2"
      shift 2
      ;;
    --purge-sessions)
      if [[ -z "${2:-}" ]]; then
        echo -e "${RED}Error: --purge-sessions requires a session argument (latest, all, older-than:DAYS, max-size:SIZE, keep-latest:N, or timestamp).${NC}" >&2
        exit 1
      fi
      require_non_option_value "$1" "$2"
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
    --check-health)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --check-health requires a seconds argument." >&2
        exit 1
      fi
      require_non_option_value "$1" "$2"
      CHECK_HEALTH="$2"
      shift 2
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
    --doctor)
      DOCTOR=true
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

if [[ -n "$CHECK_HEALTH" ]]; then
  if [[ "$REPORT" != true ]]; then
    echo "Error: --check-health requires --report." >&2
    exit 1
  fi
  if [[ ! "$CHECK_HEALTH" =~ ^[[:digit:]]+$ ]]; then
    echo "Error: --check-health expects an integer from 0 to 9223372036854775807 seconds." >&2
    exit 1
  fi
  CHECK_HEALTH=${CHECK_HEALTH#"${CHECK_HEALTH%%[!0]*}"}
  CHECK_HEALTH=${CHECK_HEALTH:-0}
  # Compare decimal text before arithmetic to refuse overflow.
  # shellcheck disable=SC2071
  if [[ ${#CHECK_HEALTH} -gt 19 || ( ${#CHECK_HEALTH} -eq 19 && "$CHECK_HEALTH" > 9223372036854775807 ) ]]; then
    echo "Error: --check-health expects an integer from 0 to 9223372036854775807 seconds." >&2
    exit 1
  fi
fi

if [[ -n "$ONLY_PATH" && ( "$ONLY_PATH" != /* || "$ONLY_PATH" == *$'\n'* ) ]]; then
  echo "Error: --only-path requires a literal absolute path without line feeds." >&2
  exit 1
fi

if [[ -n "$EXCLUDE_PATH" && ( "$EXCLUDE_PATH" != /* || "$EXCLUDE_PATH" == *$'\n'* ) ]]; then
  echo "Error: --exclude-path requires a literal absolute path without line feeds." >&2
  exit 1
fi

# Validate only the effective value, so CLI can replace malformed inherited input.
if [[ ! "$LOCK_WAIT" =~ ^[[:digit:]]+$ ]]; then
  echo "Error: --lock-wait must be an integer from 0 to 2147483647 seconds." >&2
  exit 1
fi
LOCK_WAIT=${LOCK_WAIT#"${LOCK_WAIT%%[!0]*}"}
LOCK_WAIT=${LOCK_WAIT:-0}
# Compare normalized decimal text before any numeric conversion.
# shellcheck disable=SC2071
if [[ ${#LOCK_WAIT} -gt 10 || ( ${#LOCK_WAIT} -eq 10 && "$LOCK_WAIT" > 2147483647 ) ]]; then
  echo "Error: --lock-wait must be an integer from 0 to 2147483647 seconds." >&2
  exit 1
fi

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

# Parse a human-friendly SIZE token (integer with optional 1024-based K/M/G/T unit)
# into a byte count on stdout. Returns 1 on bad syntax, 2 on 64-bit overflow.
parse_size_bytes() {
  local raw="$1" num unit mult
  if [[ ! "$raw" =~ ^([[:digit:]]+)([KMGTkmgt]?)$ ]]; then
    return 1
  fi
  num="${BASH_REMATCH[1]}"
  unit="${BASH_REMATCH[2]}"
  case "$unit" in
    "") mult=1 ;;
    k|K) mult=1024 ;;
    m|M) mult=$((1024 * 1024)) ;;
    g|G) mult=$((1024 * 1024 * 1024)) ;;
    t|T) mult=$((1024 * 1024 * 1024 * 1024)) ;;
  esac
  # Refuse values whose byte count would overflow 64-bit shell arithmetic.
  if [[ ${#num} -gt 18 ]] \
     || (( 10#$num > 9223372036854775807 / mult )); then
    return 2
  fi
  printf '%s\n' "$((10#$num * mult))"
}

if [[ -n "$MIN_RECLAIM" ]]; then
  min_reclaim_rc=0
  MIN_RECLAIM_BYTES=$(parse_size_bytes "$MIN_RECLAIM") || min_reclaim_rc=$?
  if [[ "$min_reclaim_rc" -eq 1 ]]; then
    echo -e "${RED}Error: --min-reclaim expects a size such as 500M or 2G, got '${MIN_RECLAIM}'.${NC}" >&2
    exit 1
  elif [[ "$min_reclaim_rc" -ne 0 ]]; then
    echo -e "${RED}Error: --min-reclaim size '${MIN_RECLAIM}' is too large.${NC}" >&2
    exit 1
  fi
fi

if [[ -n "$MIN_FREE" ]]; then
  min_free_rc=0
  MIN_FREE_BYTES=$(parse_size_bytes "$MIN_FREE") || min_free_rc=$?
  if [[ "$min_free_rc" -eq 1 ]]; then
    echo -e "${RED}Error: --min-free expects a size such as 500M or 2G, got '${MIN_FREE}'.${NC}" >&2
    exit 1
  elif [[ "$min_free_rc" -ne 0 ]]; then
    echo -e "${RED}Error: --min-free size '${MIN_FREE}' is too large.${NC}" >&2
    exit 1
  fi
fi

if [[ -n "$MIN_FREE_PATH" ]]; then
  if [[ -z "$MIN_FREE" ]]; then
    echo -e "${RED}Error: --min-free-path requires --min-free.${NC}" >&2
    exit 1
  fi
  if [[ "$MIN_FREE_PATH" != /* || ! -e "$MIN_FREE_PATH" ]]; then
    echo -e "${RED}Error: --min-free-path requires an absolute existing path, got '${MIN_FREE_PATH}'.${NC}" >&2
    exit 1
  fi
fi

if [[ -n "$MIN_AGE_OVERRIDE" ]]; then
  if [[ ! "$MIN_AGE_OVERRIDE" =~ ^[[:digit:]]+$ ]]; then
    echo -e "${RED}Error: --min-age expects a non-negative integer day count, got '${MIN_AGE_OVERRIDE}'.${NC}" >&2
    exit 1
  fi
  MIN_AGE_OVERRIDE=${MIN_AGE_OVERRIDE#"${MIN_AGE_OVERRIDE%%[!0]*}"}
  MIN_AGE_OVERRIDE=${MIN_AGE_OVERRIDE:-0}
fi

if [[ -n "$ACTION_TIMEOUT" ]]; then
  if [[ ! "$ACTION_TIMEOUT" =~ ^[[:digit:]]+$ ]]; then
    echo -e "${RED}Error: --action-timeout expects a non-negative integer second count, got '${ACTION_TIMEOUT}'.${NC}" >&2
    exit 1
  fi
  ACTION_TIMEOUT=${ACTION_TIMEOUT#"${ACTION_TIMEOUT%%[!0]*}"}
  ACTION_TIMEOUT=${ACTION_TIMEOUT:-0}
fi

if [[ -n "$TRASH_KEEP_DAYS" ]]; then
  if [[ ! "$TRASH_KEEP_DAYS" =~ ^[[:digit:]]+$ ]]; then
    echo -e "${RED}Error: --trash-keep-days expects a non-negative integer day count, got '${TRASH_KEEP_DAYS}'.${NC}" >&2
    exit 1
  fi
fi

# A hold only flips one session's marker: refuse every other mode, filter, preview,
# or JSON request so nobody believes it also cleaned, restored, or narrowed something.
if [[ -n "$HOLD_TARGET" || -n "$RELEASE_TARGET" ]]; then
  hold_flag=--hold-session hold_other=--release-session
  [[ -n "$HOLD_TARGET" ]] || { hold_flag=--release-session; hold_other=--hold-session; }
  if [[ ( -n "$HOLD_TARGET" && -n "$RELEASE_TARGET" ) || -n "$RESTORE_TARGET" || -n "$PURGE_TARGET" || "$LIST_SESSIONS" == true || "$LIST_TARGETS" == true || "$CHECK_CONFIG" == true || "$REPORT" == true || "$INIT_CONFIG" == true || "$DOCTOR" == true \
        || -n "$ONLY_TARGET" || -n "$EXCLUDE_TARGET" || -n "$ONLY_PATH" || -n "$EXCLUDE_PATH" || -n "$MIN_RECLAIM" || -n "$MIN_FREE" || -n "$MIN_FREE_PATH" || -n "$MIN_AGE_OVERRIDE" || -n "$ACTION_TIMEOUT" || -n "$TRASH_KEEP_DAYS" \
        || "$NOTIFY_CLI" == true || "$FAIL_FAST_CLI" == true || "$SHOW_MATCHES" == true || "$EXIT_CODE" == true || "$DRY_RUN_EXPLICIT" == true || "$CLEAN_EXPLICIT" == true || "$INTERACTIVE" == true || "$JSON_OUTPUT" == true ]]; then
    echo -e "${RED}Error: ${hold_flag} cannot be combined with ${hold_other}, --restore, --purge-sessions, --list-sessions, --list-targets, --check-config, --report, --check-health, --init-config, --doctor, --only-target, --exclude-target, --only-path, --exclude-path, --min-reclaim, --min-free, --min-free-path, --min-age, --action-timeout, --trash-keep-days, --notify, --fail-fast, --show-matches, --exit-code, --dry-run, --clean, --interactive, or --json.${NC}" >&2
    exit 1
  fi
fi

# Exit status signaling is only meaningful for a cleanup preview.
if [[ "$EXIT_CODE" == true && ( "$DRY_RUN" != true || "$CLEAN_EXPLICIT" == true || "$FORCE" == true || "$INTERACTIVE" == true || -n "$RESTORE_TARGET" || -n "$PURGE_TARGET" || "$LIST_SESSIONS" == true || "$LIST_TARGETS" == true || "$CHECK_CONFIG" == true || "$REPORT" == true || "$INIT_CONFIG" == true || "$DOCTOR" == true ) ]]; then
  echo -e "${RED}Error: --exit-code cannot be combined with --clean, --force, --interactive, --restore, --purge-sessions, --list-sessions, --hold-session, --release-session, --list-targets, --check-config, --report, --check-health, --init-config, or --doctor.${NC}" >&2
  exit 1
fi

# Match listings are only meaningful for a text cleanup preview.
if [[ "$SHOW_MATCHES" == true && ( "$DRY_RUN" != true || "$CLEAN_EXPLICIT" == true || "$FORCE" == true || "$INTERACTIVE" == true || "$JSON_OUTPUT" == true || -n "$RESTORE_TARGET" || -n "$PURGE_TARGET" || "$LIST_SESSIONS" == true || "$LIST_TARGETS" == true || "$CHECK_CONFIG" == true || "$REPORT" == true || "$INIT_CONFIG" == true || "$DOCTOR" == true ) ]]; then
  echo -e "${RED}Error: --show-matches cannot be combined with --clean, --force, --interactive, --json, --restore, --purge-sessions, --list-sessions, --list-targets, --check-config, --report, --check-health, --init-config, or --doctor.${NC}" >&2
  exit 1
fi

# Restore selectors only mean anything as filters on --restore; ignoring one would
# let a user believe a cleanup or purge was narrowed when it was not.
if [[ -n "$RESTORE_ONLY" && -z "$RESTORE_TARGET" ]]; then
  echo -e "${RED}Error: ${RESTORE_ONLY_MODE} requires --restore (it filters which quarantined targets are restored).${NC}" >&2
  exit 1
fi

if [[ -n "$ONLY_TARGET" && ( -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" || "$LIST_SESSIONS" == true || "$CHECK_CONFIG" == true || "$REPORT" == true || "$INIT_CONFIG" == true || "$DOCTOR" == true ) ]]; then
  echo -e "${RED}Error: --only-target applies only to cleanup runs or --list-targets (not --restore, --purge-sessions, --list-sessions, --check-config, --report, --check-health, --init-config, or --doctor).${NC}" >&2
  exit 1
fi

if [[ -n "$EXCLUDE_TARGET" && ( -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" || "$LIST_SESSIONS" == true || "$CHECK_CONFIG" == true || "$REPORT" == true || "$INIT_CONFIG" == true || "$DOCTOR" == true ) ]]; then
  echo -e "${RED}Error: --exclude-target applies only to cleanup runs or --list-targets (not --restore, --purge-sessions, --list-sessions, --check-config, --report, --check-health, --init-config, or --doctor).${NC}" >&2
  exit 1
fi

if [[ -n "$ONLY_PATH" && ( -n "$RESTORE_TARGET" || -n "$PURGE_TARGET" || "$LIST_SESSIONS" == true || "$CHECK_CONFIG" == true || "$REPORT" == true || "$INIT_CONFIG" == true || "$DOCTOR" == true || -n "$TRASH_KEEP_DAYS" ) ]]; then
  echo "Error: --only-path applies only to cleanup runs or --list-targets and cannot be combined with --trash-keep-days." >&2
  exit 1
fi

if [[ -n "$EXCLUDE_PATH" && ( -n "$RESTORE_TARGET" || -n "$PURGE_TARGET" || "$LIST_SESSIONS" == true || "$CHECK_CONFIG" == true || "$REPORT" == true || "$INIT_CONFIG" == true || "$DOCTOR" == true ) ]]; then
  echo "Error: --exclude-path applies only to cleanup runs or --list-targets (not --restore, --purge-sessions, --list-sessions, --check-config, --report, --check-health, --init-config, or --doctor)." >&2
  exit 1
fi

if [[ -n "$MIN_RECLAIM" && ( -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" || "$LIST_SESSIONS" == true || "$LIST_TARGETS" == true || "$CHECK_CONFIG" == true || "$REPORT" == true || "$INIT_CONFIG" == true || "$DOCTOR" == true ) ]]; then
  echo -e "${RED}Error: --min-reclaim applies only to cleanup runs (not --restore, --purge-sessions, --list-sessions, --list-targets, --check-config, --report, --check-health, --init-config, or --doctor).${NC}" >&2
  exit 1
fi

if [[ ( -n "$MIN_FREE" || -n "$MIN_FREE_PATH" ) && ( -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" || "$LIST_SESSIONS" == true || "$LIST_TARGETS" == true || "$CHECK_CONFIG" == true || "$REPORT" == true || "$INIT_CONFIG" == true || "$DOCTOR" == true ) ]]; then
  min_free_flag=--min-free
  [[ -n "$MIN_FREE_PATH" ]] && min_free_flag=--min-free-path
  echo -e "${RED}Error: ${min_free_flag} applies only to cleanup runs (not --restore, --purge-sessions, --list-sessions, --list-targets, --check-config, --report, --check-health, --init-config, or --doctor).${NC}" >&2
  exit 1
fi

if [[ -n "$MIN_AGE_OVERRIDE" && ( -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" || "$LIST_SESSIONS" == true || "$LIST_TARGETS" == true || "$CHECK_CONFIG" == true || "$REPORT" == true || "$INIT_CONFIG" == true || "$DOCTOR" == true ) ]]; then
  echo -e "${RED}Error: --min-age applies only to cleanup runs (not --restore, --purge-sessions, --list-sessions, --list-targets, --check-config, --report, --check-health, --init-config, or --doctor).${NC}" >&2
  exit 1
fi

if [[ -n "$ACTION_TIMEOUT" && ( -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" || "$LIST_SESSIONS" == true || "$LIST_TARGETS" == true || "$CHECK_CONFIG" == true || "$REPORT" == true || "$INIT_CONFIG" == true || "$DOCTOR" == true ) ]]; then
  echo -e "${RED}Error: --action-timeout applies only to cleanup runs (not --restore, --purge-sessions, --list-sessions, --list-targets, --check-config, --report, --check-health, --init-config, or --doctor).${NC}" >&2
  exit 1
fi

if [[ -n "$TRASH_KEEP_DAYS" && ( -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" || "$LIST_SESSIONS" == true || "$LIST_TARGETS" == true || "$CHECK_CONFIG" == true || "$REPORT" == true || "$INIT_CONFIG" == true || "$DOCTOR" == true ) ]]; then
  echo -e "${RED}Error: --trash-keep-days applies only to cleanup runs (not --restore, --purge-sessions, --list-sessions, --list-targets, --check-config, --report, --check-health, --init-config, or --doctor).${NC}" >&2
  exit 1
fi

if [[ "$NOTIFY_CLI" == true && ( -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" || "$LIST_SESSIONS" == true || "$LIST_TARGETS" == true || "$CHECK_CONFIG" == true || "$REPORT" == true || "$INIT_CONFIG" == true || "$DOCTOR" == true ) ]]; then
  echo -e "${RED}Error: --notify applies only to cleanup runs (not --restore, --purge-sessions, --list-sessions, --list-targets, --check-config, --report, --check-health, --init-config, or --doctor).${NC}" >&2
  exit 1
fi

if [[ "$FAIL_FAST_CLI" == true && ( -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" || "$LIST_SESSIONS" == true || "$LIST_TARGETS" == true || "$CHECK_CONFIG" == true || "$REPORT" == true || "$INIT_CONFIG" == true || "$DOCTOR" == true ) ]]; then
  echo -e "${RED}Error: --fail-fast applies only to cleanup runs (not --restore, --purge-sessions, --list-sessions, --list-targets, --check-config, --report, --check-health, --init-config, or --doctor).${NC}" >&2
  exit 1
fi

if [[ "$LIST_TARGETS" == true && ( -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" || "$LIST_SESSIONS" == true || "$REPORT" == true || "$INIT_CONFIG" == true || "$DOCTOR" == true ) ]]; then
  echo -e "${RED}Error: --list-targets cannot be combined with --restore, --purge-sessions, --list-sessions, --report, --check-health, --init-config, or --doctor.${NC}" >&2
  exit 1
fi

if [[ "$CHECK_CONFIG" == true && ( -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" || "$LIST_SESSIONS" == true || "$LIST_TARGETS" == true || "$REPORT" == true || "$INIT_CONFIG" == true || "$DOCTOR" == true ) ]]; then
  echo -e "${RED}Error: --check-config cannot be combined with --restore, --purge-sessions, --list-sessions, --list-targets, --report, --check-health, --init-config, or --doctor.${NC}" >&2
  exit 1
fi

if [[ "$REPORT" == true && ( -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" || "$LIST_SESSIONS" == true || "$LIST_TARGETS" == true || "$CHECK_CONFIG" == true || "$INIT_CONFIG" == true || "$DOCTOR" == true ) ]]; then
  echo -e "${RED}Error: --report cannot be combined with --restore, --purge-sessions, --list-sessions, --list-targets, --check-config, --init-config, or --doctor.${NC}" >&2
  exit 1
fi

if [[ "$INIT_CONFIG" == true && ( -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" || "$LIST_SESSIONS" == true || "$LIST_TARGETS" == true || "$CHECK_CONFIG" == true || "$REPORT" == true || "$DOCTOR" == true ) ]]; then
  echo -e "${RED}Error: --init-config cannot be combined with --restore, --purge-sessions, --list-sessions, --list-targets, --check-config, --report, --check-health, or --doctor.${NC}" >&2
  exit 1
fi

if [[ "$DOCTOR" == true && ( -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" || "$LIST_SESSIONS" == true || "$LIST_TARGETS" == true || "$CHECK_CONFIG" == true || "$REPORT" == true || "$INIT_CONFIG" == true ) ]]; then
  echo -e "${RED}Error: --doctor cannot be combined with --restore, --purge-sessions, --list-sessions, --list-targets, --check-config, --report, --check-health, or --init-config.${NC}" >&2
  exit 1
fi

session_mode_count=0
[[ -n "${RESTORE_TARGET:-}" ]] && session_mode_count=$((session_mode_count + 1))
[[ -n "${PURGE_TARGET:-}" ]] && session_mode_count=$((session_mode_count + 1))
[[ "$LIST_SESSIONS" == true ]] && session_mode_count=$((session_mode_count + 1))
if [[ "$session_mode_count" -gt 1 ]]; then
  echo -e "${RED}Error: --restore, --purge-sessions and --list-sessions cannot be combined.${NC}" >&2
  exit 1
fi

if [[ "$JSON_OUTPUT" == true && ( \
      -n "$RESTORE_TARGET" || -n "$PURGE_TARGET" || "$CHECK_CONFIG" == true || "$INIT_CONFIG" == true || "$DOCTOR" == true || \
      ( "$DRY_RUN" != true && "$LIST_TARGETS" != true && "$LIST_SESSIONS" != true && "$REPORT" != true ) \
    ) ]]; then
  echo -e "${RED}Error: --json is valid only with --dry-run (machine-readable preview), --list-targets, --list-sessions, or --report.${NC}" >&2
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

# Default config search order into CONFIG_CANDIDATES: XDG user config >
# system config > dev-checkout config beside the script.
set_default_config_candidates() {
  local xdg_config_parent
  xdg_config_parent=$(_xdg_dir XDG_CONFIG_HOME "$HOME/.config" && printf '.') || return 1
  xdg_config_parent=${xdg_config_parent%.}
  CONFIG_CANDIDATES=(
    "$xdg_config_parent/linux-cleaner/cleaner.conf"
    "/etc/linux-cleaner/cleaner.conf"
    "$SCRIPT_DIR/cleaner.conf")
}

# Copy the active configuration file to the user config path without overwriting.
init_user_config() {
  local xdg_parent dest_dir dest src="" candidate tmp
  xdg_parent=$(_xdg_dir XDG_CONFIG_HOME "$HOME/.config" && printf '.') || return 1
  xdg_parent=${xdg_parent%.}
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
  if ! mv -n -T -- "$tmp" "$dest"; then
    rm -f -- "$tmp" || true
    echo -e "${RED}Error: Failed to move '$tmp' to '$dest'.${NC}" >&2
    return 1
  fi
  if [[ -e "$tmp" || -L "$tmp" ]]; then
    rm -f -- "$tmp" || true
    echo -e "${RED}Error: User config already exists at '$dest'; refusing to overwrite.${NC}" >&2
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
if [[ -z "${RESTORE_TARGET:-}" && -z "${PURGE_TARGET:-}" && -z "$HOLD_TARGET" && -z "$RELEASE_TARGET" && "$LIST_SESSIONS" != true && "$REPORT" != true && "$DOCTOR" != true ]]; then
  # Resolve the default config by search order when -c/--config was not given.
  CONFIG_CANDIDATES=()
  [[ -n "$CONFIG_FILE" ]] && CONFIG_EXPLICIT=true
  if [[ -z "$CONFIG_FILE" ]]; then
    set_default_config_candidates || exit 1
    for candidate in "${CONFIG_CANDIDATES[@]}"; do
      if [[ -f "$candidate" ]]; then
        CONFIG_FILE="$candidate"
        break
      fi
    done
    # No candidate exists: keep the dev path so the not-found error is actionable.
    [[ -z "$CONFIG_FILE" ]] && CONFIG_FILE="$SCRIPT_DIR/cleaner.conf"
    if [[ "$CONFIG_FILE" != "${CONFIG_CANDIDATES[0]}" ]]; then
      CONFIG_DISCOVERED=true
    fi
  fi
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}Error: Configuration file not found at '$CONFIG_FILE'${NC}" >&2
    if [[ ${#CONFIG_CANDIDATES[@]} -gt 0 ]]; then
      printf '  searched: %s\n' "${CONFIG_CANDIDATES[@]}" >&2
      echo "Run 'cleaner --doctor' to check the environment." >&2
    fi
    exit 1
  fi
  if [[ ! -r "$CONFIG_FILE" ]]; then
    echo -e "${RED}Error: Configuration file '$CONFIG_FILE' is not readable${NC}" >&2
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
  printf '%s' "$var"
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
  local flag="$1" value="$2" pat rest="$2"
  local -n patterns_out="$3"
  patterns_out=()
  [[ -z "$value" ]] && return 0
  while :; do
    pat=$(trim "${rest%%,*}")
    if [[ -z "$pat" ]]; then
      echo -e "${RED}Error: ${flag} contains an empty pattern in '${value}'.${NC}" >&2
      exit 1
    fi
    patterns_out+=("$pat")
    [[ "$rest" == *,* ]] || break
    rest="${rest#*,}"
  done
}

ONLY_TARGET_PATTERNS=()
EXCLUDE_TARGET_PATTERNS=()
split_name_patterns --only-target "$ONLY_TARGET" ONLY_TARGET_PATTERNS
split_name_patterns --exclude-target "$EXCLUDE_TARGET" EXCLUDE_TARGET_PATTERNS
only_target_matched=false
name_filter_kept=false
path_filter_matched=false
exclude_path_kept=false
age_filter_matched=false
SELECTED_TARGET_PATH=""

select_target_name() {
  local name="$1"
  if [[ -n "$ONLY_TARGET" ]]; then
    name_matches_any "$name" "${ONLY_TARGET_PATTERNS[@]}" || return 1
    only_target_matched=true
  fi
  if [[ -n "$EXCLUDE_TARGET" ]] && name_matches_any "$name" "${EXCLUDE_TARGET_PATTERNS[@]}"; then
    return 1
  fi
  name_filter_kept=true
}

resolve_existing_path() {
  local resolved
  # Preserve trailing line feeds until they can be rejected, not silently stripped.
  resolved=$(realpath -e -- "$1" 2>/dev/null && printf '.') || return 1
  resolved=${resolved%.}
  resolved=${resolved%$'\n'}
  [[ "$resolved" == /* && "$resolved" != *$'\n'* ]] || return 1
  RESOLVED_PATH="$resolved"
}

select_target_path() {
  local expanded stripped excl_lit
  if [[ -n "$ONLY_PATH" ]]; then
    [[ "$2" == action:* ]] && return 1
    expanded=$(expand_path_safe "$1") || return 1
    resolve_existing_path "$expanded" || return 1
    SELECTED_TARGET_PATH="$RESOLVED_PATH"
    if [[ "$ONLY_PATH_CANONICAL" == / || "$SELECTED_TARGET_PATH" == "$ONLY_PATH_CANONICAL" || "$SELECTED_TARGET_PATH" == "$ONLY_PATH_CANONICAL"/* ]]; then
      path_filter_matched=true
    else
      return 1
    fi
  fi
  if [[ -n "$EXCLUDE_PATH" ]]; then
    if expanded=$(expand_path_safe "$1"); then
      stripped=$(strip_trailing_slashes "$expanded")
      excl_lit=$(strip_trailing_slashes "$EXCLUDE_PATH")
      if [[ "$excl_lit" == / || "$stripped" == "$excl_lit" || "$stripped" == "$excl_lit"/* || "$excl_lit" == "$stripped"/* ]]; then
        return 1
      fi
      if resolve_existing_path "$expanded"; then
        if [[ "$EXCLUDE_PATH_CANONICAL" == / || "$RESOLVED_PATH" == "$EXCLUDE_PATH_CANONICAL" || "$RESOLVED_PATH" == "$EXCLUDE_PATH_CANONICAL"/* || "$EXCLUDE_PATH_CANONICAL" == "$RESOLVED_PATH"/* ]]; then
          return 1
        fi
      fi
    fi
    exclude_path_kept=true
  fi
  return 0
}

check_target_selection() {
  if [[ -n "$ONLY_TARGET" && "$only_target_matched" != true ]]; then
    echo -e "${RED}Error: No config target NAME matches '--only-target ${ONLY_TARGET}'.${NC}" >&2
    return 1
  fi
  if [[ -n "$EXCLUDE_TARGET" && "$name_filter_kept" != true ]]; then
    echo -e "${RED}Error: --exclude-target ${EXCLUDE_TARGET} left no config targets to process.${NC}" >&2
    return 1
  fi
  if [[ -n "$ONLY_PATH" && "$path_filter_matched" != true ]]; then
    echo "Error: No eligible config target resolves at or below '--only-path ${ONLY_PATH}'." >&2
    return 1
  fi
  if [[ -n "$EXCLUDE_PATH" && "$exclude_path_kept" != true ]]; then
    echo "Error: --exclude-path ${EXCLUDE_PATH} left no config targets to process." >&2
    return 1
  fi
  if [[ -n "$MIN_AGE_OVERRIDE" && "$age_filter_matched" != true ]]; then
    echo "Error: No eligible config target remains for '--min-age ${MIN_AGE_OVERRIDE}' (action:* rows are skipped)." >&2
    return 1
  fi
  return 0
}

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
  printf '"would_skip":%s,' "$preview_would_skip"
  printf '"hidden_by_risk":{"medium":%s,"danger":%s,"names":[' "$hidden_medium" "$hidden_danger"
  for i in "${!hidden_risk_name_list[@]}"; do
    [[ "$i" -gt 0 ]] && printf ','
    printf '"%s"' "$(json_escape "${hidden_risk_name_list[$i]}")"
  done
  printf ']},'
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
    select_target_name "$name" || continue
    raw_path=$(trim "$raw_path")
    desc=$(trim "$desc")
    min_age=$(trim "$min_age")
    check_procs=$(trim "${check_procs:-}")
    custom_clean_cmd=$(trim "${custom_clean_cmd:-}")
    select_target_path "$raw_path" "$custom_clean_cmd" || continue
    lt_names+=("$name")
    lt_risks+=("$risk")
    lt_paths+=("$raw_path")
    lt_descs+=("$desc")
    lt_min_ages+=("$min_age")
    lt_procs+=("$check_procs")
    lt_actions+=("$custom_clean_cmd")
  done < <(expand_config_globs)

  check_target_selection || return 1
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
    # Spelled out: before bash 5.2 (globasciiranges off), an A-Z range under tr_TR skips i and I.
    if [[ -z "$nextc" || "$nextc" != [abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_] ]]; then
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
  local expanded="$raw_path" name value default
  [[ "$raw_path" != *$'\n'* ]] || return 1

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
  for name in HOME USER XDG_CACHE_HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME; do
    case "$name" in
      HOME|USER) value="${!name:-}" ;;
      *)
        case "$name" in
          XDG_CACHE_HOME) default="${HOME:-}/.cache" ;;
          XDG_CONFIG_HOME) default="${HOME:-}/.config" ;;
          XDG_DATA_HOME) default="${HOME:-}/.local/share" ;;
          XDG_STATE_HOME) default="${HOME:-}/.local/state" ;;
        esac
        value=$(_xdg_dir "$name" "$default" && printf '.') || return 1
        value=${value%.}
        ;;
    esac
    # Helpers emit no delimiter; remove only the capture sentinel, preserving LF.
    expanded=$(_expand_var_token "$expanded" "$name" "$value" && printf '.') || return 1
    expanded=${expanded%.}
  done

  [[ "$expanded" != *$'\n'* ]] || return 1
  printf '%s' "$expanded"
}

# How many directory levels below the literal prefix a "**" pattern component may
# span. Bounded on purpose: a mistyped recursive pattern must not walk an
# arbitrarily deep tree. Documented in docs/configuration.md and cleaner.1.
GLOB_RECURSION_MAX_DEPTH=10

# True when a directory looks like a C or C++ build tree. Checked by contents, not
# by name: a directory called "builder" or "buildMatchFn" holds source, and one
# called "build" may hold documentation. Refuse source roots even for in-source
# builds, then require a real file or directory build-system marker.
# maxdepth 2 covers the marker sitting in the directory itself and one level below,
# which is where a qmake per-kit layout (build/Desktop-Debug) keeps it.
is_cxx_build_dir() {
  local dir="$1"
  [[ -d "$dir" ]] || return 1
  [[ ! -e "$dir/CMakeLists.txt" && ! -e "$dir/meson.build" ]] || return 1
  [[ -n $(find "$dir" -mindepth 1 -maxdepth 2 \
            \( -type f -o -type d \) \
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
  local line lineno=0 risk name raw_path f1 f2 f3 frest pipes fields
  local prefix depth max_depth head tail_part slashes leaf match target_filter ancestor has_globstar expanded
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
      if [[ "$target_filter" == "filter:cxx_build" ]]; then
        if ! expanded=$(expand_path_safe "$raw_path"); then
          printf 'Warning: %s:%s: skipping target with unsafe path expansion\n' "$CONFIG_FILE" "$lineno" >&2
          continue
        fi
        is_cxx_build_dir "$expanded" || continue
      fi
      printf '%s\t%s\n' "$lineno" "$line"
      continue
    fi

    name=$(trim "$f2")
    if { [[ -n "$ONLY_TARGET" ]] && ! name_matches_any "$name" "${ONLY_TARGET_PATTERNS[@]}"; } \
       || { [[ -n "$EXCLUDE_TARGET" ]] && name_matches_any "$name" "${EXCLUDE_TARGET_PATTERNS[@]}"; }; then
      printf '%s\t%s\n' "$lineno" "$line"
      continue
    fi

    if ! raw_path=$(expand_path_safe "$raw_path"); then
      printf 'Warning: %s:%s: skipping wildcard with unsafe path expansion\n' "$CONFIG_FILE" "$lineno" >&2
      continue
    fi
    if [[ "$raw_path" == *'['* || "$raw_path" == *']'* ]]; then
      printf 'Warning: %s:%s: skipping wildcard with bracket characters in expanded path\n' "$CONFIG_FILE" "$lineno" >&2
      continue
    fi
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
      if ! expanded=$(expand_path_safe "$match") \
         || [[ "$match" == *'|'* || "$match" == *[[:cntrl:]]* || "$match" == *\\* || "$match" != "$(trim "$match")" || "$match" != "$expanded" ]]; then
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
  if ! LOG_FILE=$(expand_path_safe "$LOG_FILE"); then
    echo "Warning: disabling log with unsafe path expansion." >&2
    LOG_ENABLED=false
    LOG_FILE=""
  fi
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
  
  [[ "$target" != *$'\n'* ]] || return 1

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
        resolved=$(realpath -- "$resolved" 2>/dev/null && printf '.') || return 1
        resolved=${resolved%.}
        resolved=${resolved%$'\n'}
        [[ "$resolved" == /* && "$resolved" != *$'\n'* ]] || return 1
      fi
      resolved=$(dirname -- "$resolved") || return 1
    else
      local next
      if [[ "$resolved" == "/" ]]; then
        next="/$comp"
      else
        next="$resolved/$comp"
      fi
      if [[ -e "$next" || -L "$next" ]]; then
        resolved=$(realpath -- "$next" 2>/dev/null && printf '.') || return 1
        resolved=${resolved%.}
        resolved=${resolved%$'\n'}
        [[ "$resolved" == /* && "$resolved" != *$'\n'* ]] || return 1
      else
        resolved="$next"
      fi
    fi
  done
  printf '%s' "$resolved"
}

# Build find arguments using the same patterns for global and per-target exclusions.
EXCLUDE_FIND_ARGS=()
build_exclude_find_args() {
  local patterns="${1-${EXCLUDE_PATTERNS:-}}"
  EXCLUDE_FIND_ARGS=()
  if [[ -z "$patterns" ]]; then
    return
  fi
  
  local rest="$patterns"
  local -a pats=()
  while [[ "$rest" == *,* ]]; do
    pats+=("${rest%%,*}")
    rest="${rest#*,}"
  done
  pats+=("$rest")
  
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
  local literal_dir resolved_target resolved_home
  # Canonicalize the FULL target (not just its parent) so a symlinked leaf that
  # resolves outside $HOME is refused, not silently followed by the append.
  # HOME is canonicalized too: a symlinked HOME must not disable a log inside it.
  if ! resolved_target=$(canonicalize_physical "$target") || ! literal_dir=$(dirname -- "$target") \
     || ! resolved_home=$(canonicalize_physical "$HOME"); then
    echo "Warning: could not resolve log path; logging disabled." >&2
    LOG_ENABLED=false
    return 0
  fi
  if [[ "$resolved_target" != "$resolved_home" && "$resolved_target" != "$resolved_home"/* ]]; then
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
    return $?
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
    select_target_name "$name" || continue
    raw_path=$(trim "$raw_path")
    custom_clean_cmd=$(trim "${custom_clean_cmd:-}")
    select_target_path "$raw_path" "$custom_clean_cmd" || continue
    desc=$(trim "$desc")
    printf '%s\t%s\t%s\t%s\n' "$name" "$risk" "$raw_path" "$desc"
  done < <(expand_config_globs)
  check_target_selection
}

# Validate every active config line with the same structural checks as the
# cleanup parser (field count, required fields, CHECK_PROCESSES, MIN_AGE_DAYS,
# known actions, known risks) without path expansion or disk analysis.
# Run a command, then print an empty NUL record and its exit status. Callers
# read that status from the stream: `wait "$!"` on a process substitution can
# miss an already-reaped child under load and report a false failure.
print0_with_status() {
  local rc=0
  "$@" || rc=$?
  printf '\0%s\0' "$rc"
}

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
      if ! name=$(expand_path_safe "$name"); then
        echo "Error: ${CONFIG_FILE}:${config_lineno}: protect PATH has unsafe path expansion" >&2
        exit 1
      fi
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
    if [[ ( "$raw_path" == *'*'* || "$raw_path" == *'?'* ) &&
          ( "$raw_path" == *'['* || "$raw_path" == *']'* ) ]]; then
      echo -e "${RED}Error: ${CONFIG_FILE}:${config_lineno}: PATH cannot contain '[' or ']' in a wildcard path${NC}" >&2
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
        action:paccache_keep1|action:paccache_keep2|action:paccache_keep3|action:pacman_clean|action:apt_clean|action:dnf_clean|action:zypper_clean|action:apk_clean|action:uv_cache_prune|action:pnpm_store_prune|action:hf_cache_prune|action:nix_store_gc|filter:cxx_build)
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
    elif [[ ! "$min_age" =~ ^[[:digit:]]+$ ]]; then
      echo -e "${RED}Error: ${CONFIG_FILE}:${config_lineno}: invalid MIN_AGE_DAYS '${min_age}'${NC}" >&2
      exit 1
    elif [[ "$custom_clean_cmd" == action:* ]] && has_positive_age "$min_age"; then
      # The action runs its own command over the whole cache; an age would only narrow the plan's estimate.
      echo -e "${RED}Error: ${CONFIG_FILE}:${config_lineno}: MIN_AGE_DAYS must be 0 for ${custom_clean_cmd} (the action ignores file age)${NC}" >&2
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

# Any entry named .hold holds the session, whatever its type: purge fails closed.
session_is_held() {
  [[ -e "$1/.hold" || -L "$1/.hold" ]]
}

# Count immediate entries not referenced by active metadata; no integrity claim.
quarantine_unrecorded_entry_count() {
  local session="$1" meta="$1/quarantine.meta" records="" entry mtype rel accounted count=0
  local -a references=()
  if [[ -f "$meta" ]]; then
    if ! records=$(cat -- "$meta" && printf '.'); then
      echo "Error: Failed to read quarantine metadata '$meta'." >&2
      return 1
    fi
    records=${records%.}
  fi
  while IFS='|' read -r mtype rel _ || [[ -n "$mtype" ]]; do
    mtype=$(trim "$mtype")
    [[ -z "$mtype" || "$mtype" == \#* ]] && continue
    references+=("$(trim "$rel")")
  done <<< "$records"
  local stream_rc=""
  while IFS= read -r -d '' entry; do
    if [[ -z "$entry" ]]; then
      IFS= read -r -d '' stream_rc
      break
    fi
    accounted=false
    for rel in "${references[@]}"; do
      if [[ "$rel" == "$entry" || "$rel" == "$entry/"* ]]; then
        accounted=true
        break
      fi
    done
    [[ "$accounted" == true ]] || count=$((count + 1))
  done < <(print0_with_status find "$session" -mindepth 1 -maxdepth 1 ! -name quarantine.meta ! -name .hold -printf '%f\0' 2>/dev/null)
  if [[ "$stream_rc" != 0 ]]; then
    echo "Error: Failed to enumerate quarantine entries in '$session'." >&2
    return 1
  fi
  printf '%s\n' "$count"
}

# Print what one quarantine session holds -- the type (full/aged) and original
# path of every record in its quarantine.meta. Strictly read-only. Shared by the
# --list-sessions query and the irreversible purge confirmation, so the safety
# prompt can never be less informative than the read-only one.
print_session_contents() {
  local session="$1"
  local meta="$session/quarantine.meta"
  local mtype morig unrecorded
  unrecorded=$(quarantine_unrecorded_entry_count "$session") || return 1
  if (( unrecorded > 0 )); then
    printf '      Unrecorded entries: %s — inspect this session manually before restore or purge.\n' "$unrecorded"
  fi

  if [[ ! -f "$meta" ]]; then
    echo -e "      ${YELLOW}(no metadata)${NC}"
    return 0
  fi
  while IFS='|' read -r mtype _ morig _ || [[ -n "$mtype" ]]; do
    mtype=$(trim "$mtype")
    [[ "$mtype" == aged-restored ]] && mtype=aged
    [[ -z "$mtype" || "$mtype" =~ ^# ]] && continue
    morig=$(trim "${morig:-}")
    # printf, not echo -e: a recorded path may hold backslashes such as \c.
    printf '      %s  %s\n' "$mtype" "$morig"
  done < "$meta"
}

# Exact session sizes are required for JSON inventory and purge budgets.
quarantine_size_bytes() {
  local output size
  if output=$(du -sb -- "$1" 2>/dev/null); then
    size=${output%%[[:space:]]*}
    if [[ "$size" =~ ^(0|[123456789][[:digit:]]*)$ ]]; then
      printf '%s\n' "$size"
      return 0
    fi
  fi
  echo "Error: Failed to measure quarantine session '$1'." >&2
  return 1
}

# List quarantine sessions (strictly read-only): print each session's
# timestamp (directory name), size, and modification date, plus the targets it
# holds. Never moves, deletes, or modifies any session or its metadata.
# With --json, emit a machine-readable inventory instead of human banners.
emit_list_sessions_json() {
  local quarantine_base="$HOME/.cache/linux-cleaner/quarantine"
  local -a sessions=() session_sizes=() session_unrecorded=()
  local s session idx ts size_bytes size_human mdate meta mtype morig unrecorded held
  local sess_first=true tgt_first

  if [[ -d "$quarantine_base" ]]; then
    local enum_rc=0 enum_list
    enum_list=$(find "$quarantine_base" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort) || enum_rc=$?
    while IFS= read -r s; do
      [[ -n "$s" ]] && sessions+=("$s")
    done <<< "$enum_list"
    if [[ "$enum_rc" -ne 0 ]]; then
      echo "Error: Failed to enumerate quarantine sessions." >&2
      return 1
    fi
  fi

  for session in "${sessions[@]}"; do
    size_bytes=$(quarantine_size_bytes "$session") || return 1
    session_sizes+=("$size_bytes")
    unrecorded=$(quarantine_unrecorded_entry_count "$session") || return 1
    session_unrecorded+=("$unrecorded")
  done

  printf '{'
  printf '"sessions":['
  for idx in "${!sessions[@]}"; do
    session=${sessions[idx]}
    size_bytes=${session_sizes[idx]}
    if [[ "$sess_first" == true ]]; then
      sess_first=false
    else
      printf ','
    fi
    ts=$(basename "$session")
    size_human=$(format_bytes "$size_bytes")
    mdate=$(stat -c '%y' "$session" 2>/dev/null | cut -d'.' -f1)
    held=false
    session_is_held "$session" && held=true
    printf '{"timestamp":"%s","size_bytes":%s,"size_human":"%s","date":"%s","unrecorded_entry_count":%s,"held":%s,"targets":[' \
      "$(json_escape "$ts")" "$size_bytes" "$(json_escape "$size_human")" "$(json_escape "${mdate:-}")" "${session_unrecorded[idx]}" "$held"
    tgt_first=true
    meta="$session/quarantine.meta"
    if [[ -f "$meta" ]]; then
      while IFS='|' read -r mtype _ morig _ || [[ -n "$mtype" ]]; do
        mtype=$(trim "$mtype")
        [[ "$mtype" == aged-restored ]] && mtype=aged
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

# find does not descend a symlinked start point, so a link at the quarantine
# base hides every session written through it. Refuse before any move or any
# "no sessions" report. A missing base is not a symlink and stays a normal empty result.
refuse_symlinked_quarantine() {
  local quarantine_base="$1"
  if [[ -L "$quarantine_base" ]]; then
    echo -e "${RED}Error: Refusing symlinked quarantine directory '$quarantine_base'.${NC}" >&2
    return 1
  fi
}

list_quarantine_sessions() {
  refuse_symlinked_quarantine "$HOME/.cache/linux-cleaner/quarantine" || return 1
  if [[ "$JSON_OUTPUT" == true ]]; then
    emit_list_sessions_json
    return "$?"
  fi

  local quarantine_base="$HOME/.cache/linux-cleaner/quarantine"
  local -a sessions=()
  if [[ -d "$quarantine_base" ]]; then
    local s
    local enum_rc=0 enum_list
    enum_list=$(find "$quarantine_base" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort) || enum_rc=$?
    while IFS= read -r s; do
      [[ -n "$s" ]] && sessions+=("$s")
    done <<< "$enum_list"
    if [[ "$enum_rc" -ne 0 ]]; then
      echo "Error: Failed to enumerate quarantine sessions." >&2
      return 1
    fi
  fi
  # Empty/missing quarantine is not an error for an informational query.
  if [[ ${#sessions[@]} -eq 0 ]]; then
    echo -e "${YELLOW}No quarantine sessions found.${NC}"
    return 0
  fi
  echo -e "${BOLD}${BLUE}=== Quarantine Sessions ===${NC}"
  local session ts size mdate held
  for session in "${sessions[@]}"; do
    ts=$(basename "$session")
    size=$({ du -sh "$session" 2>/dev/null || true; } | awk '{print $1}')
    mdate=$(stat -c '%y' "$session" 2>/dev/null | cut -d'.' -f1)
    held=""
    session_is_held "$session" && held="  held"
    echo -e "  ${ts}  size=${size:-?}  date=${mdate:-?}${held}"
    print_session_contents "$session" || return 1
  done
}

# Purge (permanently delete) quarantine sessions to reclaim the disk space that
# trash mode holds. Irreversible: purged sessions can no longer be restored. Only
# ever removes directories under the tool-owned quarantine base -- never a path
# outside it. Honors -f/--force to skip the confirmation prompt.
purge_quarantine_sessions() {
  local target="$1"
  local quarantine_base="$HOME/.cache/linux-cleaner/quarantine"
  # Return, not exit: inline retention must still record its failure.
  refuse_symlinked_quarantine "$quarantine_base" || return 1

  local days=""
  local max_size_spec="" max_size_bytes=0 max_size_rc=0
  local keep_count=""

  if [[ "$target" == older-than:* ]]; then
    # Age-based retention: what makes trash mode viable unattended. Without it a
    # cron '--trash --force' accumulates one session per run forever, so the tool
    # would hold the very space it claims to reclaim.
    days="${target#older-than:}"
    if [[ ! "$days" =~ ^[[:digit:]]+$ ]]; then
      echo -e "${RED}Error: Invalid day count in '$target'. Use older-than:<days>, e.g. older-than:30.${NC}" >&2
      exit 1
    fi
    if [[ ! -d "$quarantine_base" ]]; then
      echo -e "${YELLOW}No quarantine sessions older than ${days} day(s).${NC}"
      return 0
    fi
  elif [[ "$target" == max-size:* ]]; then
    max_size_spec="${target#max-size:}"
    max_size_bytes=$(parse_size_bytes "$max_size_spec") || max_size_rc=$?
    if [[ "$max_size_rc" -eq 1 ]]; then
      echo -e "${RED}Error: Invalid size in '$target'. Use max-size:<size>, e.g. max-size:5G.${NC}" >&2
      exit 1
    elif [[ "$max_size_rc" -ne 0 ]]; then
      echo -e "${RED}Error: max-size '${max_size_spec}' in '$target' is too large.${NC}" >&2
      exit 1
    fi
    if [[ ! -d "$quarantine_base" ]]; then
      echo -e "${YELLOW}No quarantine sessions beyond the max-size:${max_size_spec} budget.${NC}"
      return 0
    fi
  elif [[ "$target" == keep-latest:* ]]; then
    keep_count="${target#keep-latest:}"
    local keep_n_norm="${keep_count#"${keep_count%%[!0]*}"}"
    if [[ ! "$keep_count" =~ ^[[:digit:]]+$ || -z "$keep_n_norm" ]]; then
      echo -e "${RED}Error: Invalid count in '$target'. Use keep-latest:<count> with a count of at least 1, e.g. keep-latest:5.${NC}" >&2
      exit 1
    fi
    if [[ ! -d "$quarantine_base" ]]; then
      echo -e "${YELLOW}No quarantine sessions beyond the newest ${keep_count}.${NC}"
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
    local enum_rc=0 enum_list
    enum_list=$(find "$quarantine_base" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort) || enum_rc=$?
    while IFS= read -r s; do
      [[ -n "$s" ]] && targets+=("$s")
    done <<< "$enum_list"
    if [[ "$enum_rc" -ne 0 ]]; then
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
    local enum_rc=0 enum_list
    enum_list=$(find "$quarantine_base" -mindepth 1 -maxdepth 1 -type d -mtime +"$days" 2>/dev/null | sort) || enum_rc=$?
    while IFS= read -r s; do
      [[ -n "$s" ]] && targets+=("$s")
    done <<< "$enum_list"
    if [[ "$enum_rc" -ne 0 ]]; then
      echo "Error: Failed to enumerate quarantine sessions." >&2
      return 1
    fi
    # Nothing old enough is a success for a cron wrapper, not an error.
    if [[ ${#targets[@]} -eq 0 ]]; then
      echo -e "${YELLOW}No quarantine sessions older than ${days} day(s).${NC}"
      return 0
    fi
  elif [[ "$target" == max-size:* ]]; then
    local s sess_bytes running_bytes=0
    local -a all_sessions=() over_budget=()
    local enum_rc=0 enum_list
    enum_list=$(find "$quarantine_base" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r) || enum_rc=$?
    while IFS= read -r s; do
      [[ -n "$s" ]] && all_sessions+=("$s")
    done <<< "$enum_list"
    if [[ "$enum_rc" -ne 0 ]]; then
      echo "Error: Failed to enumerate quarantine sessions." >&2
      return 1
    fi
    for s in "${all_sessions[@]}"; do
      sess_bytes=$(quarantine_size_bytes "$s") || return 1
      running_bytes=$((running_bytes + sess_bytes))
      if (( running_bytes > max_size_bytes )); then
        over_budget+=("$s")
      fi
    done
    if [[ ${#over_budget[@]} -eq 0 ]]; then
      echo -e "${YELLOW}No quarantine sessions beyond the max-size:${max_size_spec} budget.${NC}"
      return 0
    fi
    local idx
    for (( idx=${#over_budget[@]}-1; idx>=0; idx-- )); do
      targets+=("${over_budget[idx]}")
    done
  elif [[ "$target" == keep-latest:* ]]; then
    local s
    local -a all_sessions=() over_count=()
    local enum_rc=0 enum_list
    enum_list=$(find "$quarantine_base" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r) || enum_rc=$?
    while IFS= read -r s; do
      [[ -n "$s" ]] && all_sessions+=("$s")
    done <<< "$enum_list"
    if [[ "$enum_rc" -ne 0 ]]; then
      echo "Error: Failed to enumerate quarantine sessions." >&2
      return 1
    fi
    # Compare as decimal text first: a huge count must keep everything, never
    # overflow into a negative index that would purge the newest sessions.
    local idx keep_n=${keep_count#"${keep_count%%[!0]*}"}
    keep_n=${keep_n:-0}
    if [[ ${#keep_n} -le 9 ]]; then
      for (( idx=keep_n; idx<${#all_sessions[@]}; idx++ )); do
        over_count+=("${all_sessions[idx]}")
      done
    fi
    if [[ ${#over_count[@]} -eq 0 ]]; then
      echo -e "${YELLOW}No quarantine sessions beyond the newest ${keep_count}.${NC}"
      return 0
    fi
    for (( idx=${#over_count[@]}-1; idx>=0; idx-- )); do
      targets+=("${over_count[idx]}")
    done
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

  if [[ "$DRY_RUN_EXPLICIT" == true ]]; then
    echo -e "${BOLD}${BLUE}=== Would purge Quarantine Sessions ===${NC}"
  fi

  # A hold only ever shrinks the purge set, even under --force: bulk selectors and
  # inline retention skip held sessions (they still count toward max-size and
  # keep-latest), and a held latest or named session is refused, never replaced.
  local d
  local -a unheld=()
  for d in "${targets[@]}"; do
    if ! session_is_held "$d"; then
      unheld+=("$d")
      continue
    fi
    case "$target" in
      all|older-than:*|max-size:*|keep-latest:*)
        echo -e "${YELLOW}Skipping held session $(basename "$d") (release it with --release-session $(basename "$d")).${NC}"
        ;;
      *)
        echo -e "${RED}Error: Quarantine session '$(basename "$d")' is held; run --release-session $(basename "$d") before purging it.${NC}" >&2
        exit 1
        ;;
    esac
  done
  if [[ ${#unheld[@]} -eq 0 ]]; then
    echo -e "${YELLOW}No quarantine sessions to purge; every selected session is held.${NC}"
    return 0
  fi
  targets=("${unheld[@]}")

  # Show what will be freed -- and exactly which targets are about to be destroyed
  # -- before touching anything. This is the last thing a user sees before the
  # data is gone, so it names every item, not just the session size.
  if [[ "$DRY_RUN_EXPLICIT" != true ]]; then
    echo -e "${BOLD}${BLUE}=== Purge Quarantine Sessions ===${NC}"
  fi
  local ts size
  for d in "${targets[@]}"; do
    ts=$(basename "$d")
    size=$({ du -sh "$d" 2>/dev/null || true; } | awk '{print $1}')
    echo -e "  ${ts}  size=${size:-?}"
    print_session_contents "$d" || return 1
  done

  [[ "$DRY_RUN_EXPLICIT" != true ]] || return 0

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

  local purged=0 purge_status=0
  for d in "${targets[@]}"; do
    if rm -rf "$d"; then
      echo -e "${GREEN}Purged $(basename "$d")${NC}"
      purged=$((purged + 1))
      log_operation "$(date '+%Y-%m-%dT%H:%M:%S') mode=purge session='$(basename "$d")' outcome=success"
    else
      echo -e "${RED}Error: Failed to purge '$d'.${NC}" >&2
      OPERATION_FAILED=true
      purge_status=1
      log_operation "$(date '+%Y-%m-%dT%H:%M:%S') mode=purge session='$(basename "$d")' outcome=failed"
    fi
  done

  # Remove the base directory if it is now empty (mirrors restore cleanup).
  rmdir "$quarantine_base" 2>/dev/null || true

  echo -e "${BOLD}Purged ${purged} session(s).${NC}"
  return "$purge_status"
}

# --trash-keep-days: retire old quarantine sessions at the end of every cleanup
# run, including one that had nothing to clean, so a skipped day still purges.
# A failed purge sets OPERATION_FAILED like any other failed operation.
apply_trash_keep_days() {
  if [[ -n "$TRASH_KEEP_DAYS" ]]; then
    local failed=false
    if ! purge_quarantine_sessions "older-than:$TRASH_KEEP_DAYS"; then
      failed=true
      OPERATION_FAILED=true
      RETENTION_FAILED=true
    fi
    RESULT_REPORT_TEXT+=$'\n'"Retention failed: $failed"
    printf 'Retention failed: %s\n' "$failed"
    save_last_cleanup_report
  fi
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

# True unless SRC sits on another filesystem than DEST and is larger than DEST's
# free space. A same-filesystem move is a rename and needs no room; a
# cross-filesystem one copies, and running out mid-copy would fill DEST. An
# empty BYTES sizes SRC only once the devices differ. An unreadable device or
# free-space figure falls back to trying the move. Sets MOVE_NEED_BYTES and
# MOVE_AVAIL_BYTES for the caller's message.
move_has_room() {
  local src="$1" src_sudo="$2" dest="$3" dest_sudo="$4" bytes="$5"
  local src_dev dest_dev avail
  src_dev=$(with_sudo "$src_sudo" stat -c '%d' "$src" 2>/dev/null) || return 0
  dest_dev=$(with_sudo "$dest_sudo" stat -c '%d' "$dest" 2>/dev/null) || return 0
  [[ "$src_dev" == "$dest_dev" ]] && return 0
  if [[ -z "$bytes" ]]; then
    bytes=$({ with_sudo "$src_sudo" du -sb "$src" 2>/dev/null || true; } | awk '{s=$1} END {print s+0}')
  fi
  MOVE_NEED_BYTES=$bytes
  avail=$(with_sudo "$dest_sudo" df -B1 --output=avail "$dest" 2>/dev/null | awk 'NR == 2 { print $1 }') || return 0
  [[ "$avail" =~ ^[[:digit:]]+$ ]] || return 0
  MOVE_AVAIL_BYTES=$avail
  [[ "$bytes" -le "$avail" ]]
}

# move_has_room for a target about to be quarantined under $HOME.
quarantine_has_room() {
  local target="$1" use_sudo="$2" bytes="$3" base
  base="$HOME/.cache/linux-cleaner/quarantine"
  (umask 077; mkdir -p "$base") || return 0
  move_has_room "$target" "$use_sudo" "$base" false "$bytes"
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

# Scratch stays beside the session so an interrupted rewrite is not payload.
write_quarantine_metadata() {
  local meta="$1" tmp
  shift
  tmp=$(mktemp "$(dirname "$(dirname "$meta")")/.restore-meta.XXXXXX") || return 1
  if { if [[ $# -gt 0 ]]; then printf '%s\n' "$@"; fi; } > "$tmp" \
     && mv -f -- "$tmp" "$meta"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

# A completed checkpoint authorizes only empty-directory removal, never payload.
retire_aged_staging() {
  local src="$1"
  [[ -L "$src" ]] && return 1
  if [[ -e "$src" ]]; then
    [[ -d "$src" ]] || return 1
    find "$src" -depth -type d -empty -delete 2>/dev/null || return 1
  fi
  [[ ! -e "$src" && ! -L "$src" ]]
}

# Best-effort: put a kept session's directory mtime back to SECONDS-SINCE-EPOCH (arg 2).
reset_session_mtime() {
  [[ -n "$2" ]] || return 0
  touch -m -d "@$2" -- "$1" 2>/dev/null || true
}

# --hold-session / --release-session (ACTION is hold or release): create or remove
# the private .hold marker that purge and --trash-keep-days retention honor. The
# session's mtime is put back, so a hold never changes its retention age.
set_session_hold() {
  local action="$1" target="$2" dir session_mtime
  local quarantine_base="$HOME/.cache/linux-cleaner/quarantine"
  refuse_symlinked_quarantine "$quarantine_base" || exit 1
  if [[ ! -d "$quarantine_base" ]]; then
    echo -e "${RED}Error: No quarantine directory exists at '$quarantine_base'.${NC}" >&2
    exit 1
  fi
  if [[ "$target" == "latest" ]]; then
    if ! dir=$(find "$quarantine_base" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n 1); then
      echo "Error: Failed to enumerate quarantine sessions." >&2
      exit 1
    fi
    if [[ -z "$dir" ]]; then
      echo -e "${RED}Error: No quarantined sessions found in '$quarantine_base'.${NC}" >&2
      exit 1
    fi
  else
    validate_quarantine_session_name "$target"
    dir="$quarantine_base/$target"
    if [[ -L "$dir" || ! -d "$dir" ]]; then
      echo -e "${RED}Error: Quarantine session directory '$dir' does not exist.${NC}" >&2
      exit 1
    fi
  fi
  local name marker="$dir/.hold"
  name=$(basename "$dir")
  if ! session_mtime=$(stat -c %Y "$dir" 2>/dev/null); then
    echo -e "${RED}Error: Failed to read the age of quarantine session '$dir'.${NC}" >&2
    exit 1
  fi

  if [[ "$action" == hold ]]; then
    if session_is_held "$dir"; then
      echo "Session $name is already held."
      return 0
    fi
    # noclobber opens with O_EXCL, so a racing symlink is never followed.
    if ! (umask 077; set -C; : > "$marker") 2>/dev/null; then
      echo -e "${RED}Error: Failed to create hold marker '$marker'.${NC}" >&2
      exit 1
    fi
    reset_session_mtime "$dir" "$session_mtime"
    echo -e "${GREEN}Held session $name; purges and --trash-keep-days retention skip it until --release-session $name.${NC}"
    return 0
  fi

  if [[ ! -e "$marker" && ! -L "$marker" ]]; then
    echo "Session $name is not held."
    return 0
  fi
  if [[ -d "$marker" && ! -L "$marker" ]] || ! rm -f -- "$marker"; then
    echo -e "${RED}Error: Failed to remove hold marker '$marker'; the session is still held.${NC}" >&2
    exit 1
  fi
  reset_session_mtime "$dir" "$session_mtime"
  echo -e "${GREEN}Released session $name; normal purge and retention apply again.${NC}"
}

# Structural check on a trimmed quarantine.meta record before path probes or sudo.
# Sets RESTORE_RECORD_ERROR to the failed rule description when returning non-zero.
validate_restore_record() {
  local rel_path="$1" original_path="$2" use_sudo="$3" uid="$4" gid="$5"
  RESTORE_RECORD_ERROR=""
  if [[ -z "$rel_path" || "$rel_path" == /* || "$rel_path" == ".." || "$rel_path" == ../* || "$rel_path" == */.. || "$rel_path" == */../* ]]; then
    RESTORE_RECORD_ERROR="invalid relative path '$rel_path'"
    return 1
  fi
  if [[ "$original_path" != /* || "$original_path" == ".." || "$original_path" == ../* || "$original_path" == */.. || "$original_path" == */../* ]]; then
    RESTORE_RECORD_ERROR="invalid original path '$original_path'"
    return 1
  fi
  if [[ "$use_sudo" != "true" && "$use_sudo" != "false" ]]; then
    RESTORE_RECORD_ERROR="invalid use_sudo '$use_sudo' (must be true or false)"
    return 1
  fi
  if [[ ( -n "$uid" && ! "$uid" =~ ^[[:digit:]]+$ ) || ( -n "$gid" && ! "$gid" =~ ^[[:digit:]]+$ ) ]]; then
    RESTORE_RECORD_ERROR="invalid uid/gid '$uid:$gid' (must be ASCII digits)"
    return 1
  fi
  return 0
}

# Restore files and folders from a quarantine session
restore_quarantine() {
  local target="$1" stream_rc=""
  local quarantine_base="$HOME/.cache/linux-cleaner/quarantine"
  refuse_symlinked_quarantine "$quarantine_base" || exit 1

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
  
  # A kept session must keep its retention age (older-than reads this mtime).
  local session_mtime=""
  session_mtime=$(stat -c %Y "$restore_dir" 2>/dev/null) || session_mtime=""

  local meta_file="$restore_dir/quarantine.meta"
  if [[ ! -f "$meta_file" ]]; then
    echo -e "${RED}Error: Metadata file 'quarantine.meta' not found in '$restore_dir'.${NC}" >&2
    exit 1
  fi
  
  echo -e "${BOLD}${BLUE}=== Restoring from Quarantine Session: $(basename "$restore_dir") ===${NC}"
  
  # Read metadata line by line
  # Format: TYPE|RELATIVE_PATH|ORIGINAL_PATH|USE_SUDO|UID|GID
  local type rel_path original_path use_sudo uid gid meta_line RESTORE_RECORD_ERROR=""
  local overall_success=true
  local matched_any=false
  # rel_paths actually moved back out of quarantine. Under --only, the metadata is
  # rewritten from this so every remaining record still points at a file that is
  # present in quarantine -- the same invariant the failed-move fix established.
  local -a restored_rels=()
  # Checkpoints atomically replace the pathname; this loop keeps its old inode.
  # shellcheck disable=SC2094
  while IFS= read -r meta_line || [[ -n "$meta_line" ]]; do
    IFS='|' read -r type rel_path original_path use_sudo uid gid _ <<< "$meta_line"
    type=$(trim "$type")
    [[ -z "$type" || "$type" =~ ^# ]] && continue

    original_path=$(trim "$original_path")
    # Leave every non-matching target quarantined, untouched.
    if [[ -n "${RESTORE_ONLY:-}" ]]; then
      if [[ "$RESTORE_ONLY_MODE" == --only-exact ]]; then
        [[ "$original_path" == "$RESTORE_ONLY" ]] || continue
      else
        [[ "$original_path" == *"$RESTORE_ONLY"* ]] || continue
      fi
    fi
    matched_any=true

    rel_path=$(trim "$rel_path")
    original_path=$(trim "$original_path")
    use_sudo=$(trim "$use_sudo")
    uid=$(trim "${uid:-}")
    gid=$(trim "${gid:-}")

    if ! validate_restore_record "$rel_path" "$original_path" "$use_sudo" "$uid" "$gid"; then
      if [[ "$DRY_RUN_EXPLICIT" == true ]]; then
        printf 'invalid record  %s\n' "$original_path"
      else
        echo -e "${RED}Error: Refusing malformed quarantine.meta record for '$original_path' (${RESTORE_RECORD_ERROR}). Skipping.${NC}" >&2
        overall_success=false
        log_restore_outcome "$restore_dir" "$original_path" failed
      fi
      continue
    fi
    
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
    if [[ "$DRY_RUN_EXPLICIT" == true ]]; then
      # Preview probes never elevate privileges or enter the mutating restore path.
      local preview_status="would restore" preview_file preview_dest preview_parent
      if [[ "$type" == aged-restored ]]; then
        preview_status="already restored"
      elif [[ ! -e "$src_path" ]]; then
        if [[ "$type" == full ]] && path_present false "$original_path"; then
          preview_status="already restored"
        else
          preview_status="missing"
        fi
      elif [[ "$type" != full && "$type" != aged ]]; then
        # The real restore skips this record as failed.
        preview_status="unknown type"
      elif [[ "$type" == full ]]; then
        if path_present false "$original_path"; then
          preview_status="conflict"
        fi
      elif [[ "$type" == aged ]]; then
        if [[ -L "$original_path" || ( -e "$original_path" && ! -d "$original_path" ) ]]; then
          preview_status="conflict"
        else
          stream_rc=""
          while IFS= read -r -d '' preview_file; do
            if [[ -z "$preview_file" ]]; then
              IFS= read -r -d '' stream_rc
              break
            fi
            preview_dest="$original_path/${preview_file#"$src_path"/}"
            if path_present false "$preview_dest"; then
              preview_status="conflict"
            fi
            preview_parent="${preview_dest%/*}"
            while [[ "$preview_parent" != "$original_path" && "$preview_parent" != / ]]; do
              if [[ -L "$preview_parent" || ( -e "$preview_parent" && ! -d "$preview_parent" ) ]]; then
                preview_status="conflict"
              fi
              preview_parent="${preview_parent%/*}"
            done
          done < <(print0_with_status find "$src_path" -mindepth 1 \( -type f -o -type l \) -print0)
          [[ "$stream_rc" == 0 ]] || preview_status="missing"
        fi
      fi
      printf '%s  %s\n' "$preview_status" "$original_path"
      continue
    fi
    if [[ "$type" == aged-restored ]]; then
      if retire_aged_staging "$src_path"; then
        restored_rels+=("$rel_path")
        log_restore_outcome "$restore_dir" "$original_path" success
      else
        echo -e "${RED}Error: Completed restore staging '$src_path' still contains payload or could not be removed. Keeping its recovery record.${NC}" >&2
        overall_success=false
        log_restore_outcome "$restore_dir" "$original_path" failed
      fi
      continue
    fi
    if [[ ! -e "$src_path" ]]; then
      # A whole-target payload that is gone while its original path is back was
      # restored by an interrupted earlier run. An aged target's directory always
      # survives quarantine, so its presence proves nothing there.
      if [[ "$type" == "full" ]] && path_present "$use_sudo" "$original_path"; then
        echo -e "Note: '$original_path' is already restored; dropping its stale record."
        restored_rels+=("$rel_path")
        log_restore_outcome "$restore_dir" "$original_path" success
        continue
      fi
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
      # Set umask after sudo; the child shell expands its positional path argument.
      # shellcheck disable=SC2016
      if ! with_sudo "$use_sudo" bash -c 'umask 077; mkdir -p -- "$1"' _ "$(dirname "$original_path")"; then
        success=false
      else
        if ! move_has_room "$src_path" "$use_sudo" "$(dirname "$original_path")" "$use_sudo" ""; then
          echo -e "${RED}Error: Not enough free space to restore '$original_path' (needs $(format_bytes "$MOVE_NEED_BYTES"), $(format_bytes "$MOVE_AVAIL_BYTES") free); kept in quarantine.${NC}" >&2
          success=false
        elif with_sudo "$use_sudo" mv "$src_path" "$original_path"; then
          with_sudo "$use_sudo" chown -hR "$uid:$gid" "$original_path" 2>/dev/null || true
        else
          success=false
        fi
      fi
    elif [[ "$type" == "aged" ]]; then
      if with_sudo "$use_sudo" test -L "$original_path"; then
        echo -e "${RED}Error: Restore destination '$original_path' is a symlink. Conflict detected, skipping.${NC}" >&2
        overall_success=false
        log_restore_outcome "$restore_dir" "$original_path" conflict
        continue
      fi
      # shellcheck disable=SC2016
      if ! with_sudo "$use_sudo" bash -c 'umask 077; mkdir -p -- "$1"' _ "$original_path"; then
        success=false
      else
        if ! move_has_room "$src_path" "$use_sudo" "$original_path" "$use_sudo" ""; then
          echo -e "${RED}Error: Not enough free space to restore '$original_path' (needs $(format_bytes "$MOVE_NEED_BYTES"), $(format_bytes "$MOVE_AVAIL_BYTES") free); kept in quarantine.${NC}" >&2
          success=false
        else
          stream_rc=""
          while IFS= read -r -d '' file; do
            if [[ -z "$file" ]]; then
              IFS= read -r -d '' stream_rc
              break
            fi
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
            # shellcheck disable=SC2016
            if ! with_sudo "$use_sudo" bash -c 'umask 077; mkdir -p -- "$1"' _ "$dest_parent"; then
              success=false
              continue
            fi
            if with_sudo "$use_sudo" mv "$file" "$dest_file"; then
              with_sudo "$use_sudo" chown -h "$uid:$gid" "$dest_file" 2>/dev/null || true
            else
              success=false
            fi
          done < <(print0_with_status find "$src_path" -mindepth 1 \( -type f -o -type l \) -print0)
          [[ "$stream_rc" == 0 ]] || success=false
        fi
      fi
    else
      echo -e "${RED}Error: Unknown restore type '$type' for '$original_path'. Skipping.${NC}" >&2
      overall_success=false
      log_restore_outcome "$restore_dir" "$original_path" failed
      continue
    fi
    
    if [[ "$success" == true && "$type" == aged ]]; then
      local -a checkpoint=()
      local checkpoint_line checkpoint_rel
      # Earlier checkpoints replaced the inode still read by the outer loop.
      while IFS= read -r checkpoint_line || [[ -n "$checkpoint_line" ]]; do
        IFS='|' read -r _ checkpoint_rel _ <<< "$checkpoint_line"
        if [[ "$(trim "$checkpoint_rel")" == "$rel_path" ]]; then
          checkpoint_line="aged-restored|${checkpoint_line#*|}"
        fi
        checkpoint+=("$checkpoint_line")
      done < "$meta_file"
      if ! write_quarantine_metadata "$meta_file" "${checkpoint[@]}" \
         || ! retire_aged_staging "$src_path"; then
        success=false
      fi
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
    fi
  done < "$meta_file"

  # A selector that matched nothing restored nothing: fail instead of succeeding silently.
  if [[ -n "${RESTORE_ONLY:-}" && "$matched_any" != true ]]; then
    echo -e "${RED}Error: No quarantined target in this session matches '${RESTORE_ONLY_MODE} ${RESTORE_ONLY}'.${NC}" >&2
    exit 1
  fi

  if [[ "$DRY_RUN_EXPLICIT" == true ]]; then
    echo "Dry-run: nothing restored."
    return 0
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

    if ! write_quarantine_metadata "$meta_file" "${retained[@]}"; then
      echo -e "${RED}Error: Failed to reconcile restore metadata; recovery records have been kept.${NC}" >&2
      overall_success=false
    fi
  fi

  if [[ "$overall_success" != true ]]; then
    reset_session_mtime "$restore_dir" "$session_mtime"
    echo -e "${RED}Error: Restoration completed with some errors. The quarantine session has been kept at '$restore_dir' for recovery.${NC}" >&2
    exit 1
  fi

  # A complete restore may retire the session only when every payload entry was
  # represented by metadata. This catches a move whose post-move metadata write
  # failed, including hidden entries and empty top-level target directories.
  if [[ -z "${RESTORE_ONLY:-}" || ${#retained[@]} -eq 0 ]]; then
    local remaining_path=""
    if ! remaining_path=$(find "$restore_dir" -mindepth 1 -maxdepth 1 ! -name quarantine.meta ! \( -name .hold -type f \) -print -quit 2>/dev/null); then
      reset_session_mtime "$restore_dir" "$session_mtime"
      echo -e "${RED}Error: Unable to verify quarantine session contents. The session and metadata have been kept for recovery at '$restore_dir'.${NC}" >&2
      exit 1
    fi
    if [[ -n "$remaining_path" ]]; then
      reset_session_mtime "$restore_dir" "$session_mtime"
      echo -e "${RED}Error: Unrecorded quarantine payload remains at '$remaining_path'. The session and metadata have been kept for manual recovery.${NC}" >&2
      exit 1
    fi
    rm -rf "$restore_dir"
    rmdir "$quarantine_base" 2>/dev/null || true
    echo -e "${BOLD}${GREEN}Restoration complete!${NC}"
    return 0
  fi

  reset_session_mtime "$restore_dir" "$session_mtime"
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
  normalized=$(canonicalize_physical "$target_path") || return 1
  normalized_home=$(canonicalize_physical "$HOME") || return 1

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
# Strip repository-selecting environment variables (set by hooks or git rebase
# --exec) so git always inspects the target's own repository and index.
# Returns 1 when a work tree's tracked files cannot be listed, or when git
# refuses the repository, so the caller fails closed.
git_isolated() {
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
    -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
    -u GIT_COMMON_DIR -u GIT_NAMESPACE git "$@"
}

count_git_tracked() {
  local target_path="$1" git_dir="$1" pathspec=. count=0 inside_work_tree
  if [[ "$EUID" -ne 0 ]] && command -v git >/dev/null 2>&1; then
    if [[ ! -d "$target_path" ]]; then
      git_dir=$(dirname "$target_path")
      pathspec=${target_path##*/}
    fi
    # rev-parse exits non-zero both for a refused repository and for a path
    # that is not a repository. Fail closed only when the same probe succeeds
    # with safe.directory='*' (git refused a real repository).
    if inside_work_tree=$(git_isolated -c core.fsmonitor=false -C "$git_dir" rev-parse --is-inside-work-tree 2>/dev/null); then
      if [[ "$inside_work_tree" == true ]]; then
        count=$(git_isolated -c core.fsmonitor=false --literal-pathspecs -C "$git_dir" ls-files -z -- "$pathspec" 2>/dev/null \
          | tr -cd '\000' | wc -c) || return 1
      fi
    elif git_isolated -c core.fsmonitor=false -c safe.directory='*' -C "$git_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      return 1
    fi
  fi
  echo "$count"
}

# Treat validated digit-only ages as decimal strings. Bash arithmetic parses a
# leading zero as octal and can overflow on long values; only zero/nonzero is
# needed to choose the age-filter path.
has_positive_age() {
  [[ "$1" =~ [123456789] ]]
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

# List the same eligible files/symlinks as has_matching_files; whole targets stay compact.
print_matching_paths() {
  local target_path="$1" age_days="$2" use_sudo="$3" match_path
  local -a mtime_args=()
  if has_positive_age "$age_days"; then
    mtime_args=(-mtime "+$age_days")
  fi
  {
    if path_is_real_dir "$use_sudo" "$target_path" && { has_positive_age "$age_days" || [[ -n "${TARGET_EXCLUDE_PATTERNS:-}" ]]; }; then
      # An unreadable subdirectory makes find exit non-zero; under pipefail that
      # would end the whole preview, so list what is readable and carry on.
      with_sudo "$use_sudo" find "$target_path" -mindepth 1 "${EXCLUDE_FIND_ARGS[@]}" \( -type f -o -type l \) "${mtime_args[@]}" -print0 2>/dev/null || true
    elif has_positive_age "$age_days"; then
      with_sudo "$use_sudo" find "$target_path" -mtime +"$age_days" -print0 2>/dev/null || true
    else
      printf '%s\0' "$target_path"
    fi
  } | while IFS= read -r -d '' match_path; do
    # Cache file names are not trusted: a control character (escape, newline)
    # could drive the terminal or forge a match line, so show those quoted.
    if [[ "$match_path" == *[[:cntrl:]]* ]]; then
      printf '    %q\n' "$match_path"
    else
      printf '    %s\n' "$match_path"
    fi
  done
}

# True when PATH itself is still older than AGE days. A whole-target rm or
# quarantine move does not pass -mtime, so the cleanup loop asks again.
path_still_older_than() {
  local use_sudo="$1" target_path="$2" age_days="$3"
  [[ -n $(with_sudo "$use_sudo" find "$target_path" -maxdepth 0 -mtime +"$age_days" -print -quit 2>/dev/null) ]]
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

# Print "<bytes> <true|false>": the get_size_bytes count, and whether the same
# should_clean rule as a found target holds. The caller has already rejected
# actions, missing paths, and idle-recent trees. Exclusions are TARGET_EXCLUDE_PATTERNS.
measure_eligible_size() {
  local target_path="$1" age_days="$2" use_sudo="$3" size_bytes should_clean=false
  size_bytes=$(get_size_bytes "$target_path" "$age_days" "$use_sudo")
  if has_positive_age "$age_days" || [[ -n "${TARGET_EXCLUDE_PATTERNS:-}" ]]; then
    if has_matching_files "$target_path" "$age_days" "$use_sudo"; then
      should_clean=true
    fi
  elif ! path_is_real_dir "$use_sudo" "$target_path" || [[ "$size_bytes" -gt 0 ]]; then
    should_clean=true
  fi
  printf '%s %s\n' "$size_bytes" "$should_clean"
}

# Bytes a process-blocked target would reclaim if it were not in use.
# No sudo, and the result is not stored in size_bytes: action:* rows are not
# measurable ahead of time, and a missing, unreadable, or recently idle path is 0.
blocked_in_use_bytes() {
  local path="$1" effective_age="$2" idle_age="$3" custom_clean_cmd="$4"
  local size_bytes should_clean
  if [[ "$custom_clean_cmd" == action:* ]]; then
    echo 0
    return
  fi
  if [[ ! -r "$path" ]] || { [[ -d "$path" ]] && [[ ! -x "$path" ]]; }; then
    echo 0
    return
  fi
  # Same recent-file probe as the plan's idle CLEAN branch, without sudo.
  if has_positive_age "$idle_age" \
     && [[ -n $(with_sudo false find "$path" "${EXCLUDE_FIND_ARGS[@]}" -mtime -"$idle_age" -print -quit 2>/dev/null) ]]; then
    echo 0
    return
  fi
  read -r size_bytes should_clean < <(measure_eligible_size "$path" "$effective_age" false)
  if [[ "$should_clean" == true ]]; then
    echo "$size_bytes"
  else
    echo 0
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
  local reason name name_label age_note size_label protected_names=""
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
        name_label="$name"
        if [[ "${parsed_in_use_bytes[$i]:-0}" -gt 0 ]]; then
          name_label="$name ($(format_bytes "${parsed_in_use_bytes[$i]}"))"
        fi
        block_groups["$reason"]="${block_groups[$reason]:+${block_groups[$reason]}, }$name_label"
        ;;
      protected)
        protected_n=$((protected_n + 1))
        protected_names+="${protected_names:+, }$name"
        ;;
      unsafe|symlink) unsafe_symlink=$((unsafe_symlink + 1)) ;;
      root) root_n=$((root_n + 1)) ;;
    esac
    if [[ "$status" == found || "$status" == root ]]; then
      case "$(risk_lower "${parsed_risks[$i]}")" in
        safe) safe_b=$((safe_b + bytes)) ;;
        medium) med_b=$((med_b + bytes)) ;;
        danger|dangerous) dang_b=$((dang_b + bytes)) ;;
      esac
    fi
  done
  printf '%s\n' "Targets: found=${found} clean/missing=${clean_missing} skipped=${skipped} blocked=${blocked} protected=${protected_n} unsafe/symlink=${unsafe_symlink} root=${root_n}"
  printf '%s\n' "Reclaimable by risk: safe=$(format_bytes "$safe_b") medium=$(format_bytes "$med_b") danger=$(format_bytes "$dang_b")"
  if [[ $((hidden_medium + hidden_danger)) -gt 0 ]]; then
    # danger also covers medium, so one valid --risk value previews every hidden target.
    local risk_hint=medium
    [[ "$hidden_danger" -gt 0 ]] && risk_hint=danger
    printf '%s\n' "Above --risk ${MAX_RISK} (not analysed): medium=${hidden_medium} danger=${hidden_danger}; preview with --risk ${risk_hint}"
    printf '%s\n' "Hidden by risk: ${hidden_risk_names}"
  fi
  if [[ "$total_in_use_bytes" -gt 0 ]]; then
    printf '%s\n' "In use: blocked=${blocked} would_reclaim=$(format_bytes "$total_in_use_bytes")"
  fi
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
  local plan_blocked=0 blocked_n=0 in_use_total=0 i
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
  # Plan-blocked rows never reach the cleanup loop; runtime blocks are counted apart.
  for i in "${!parsed_statuses[@]}"; do
    if [[ "${parsed_statuses[$i]}" == blocked ]]; then
      plan_blocked=$((plan_blocked + 1))
    fi
  done
  blocked_n=$((plan_blocked + runtime_blocked_count))
  if [[ "$blocked_n" -gt 0 ]]; then
    in_use_total=$((total_in_use_bytes + runtime_blocked_bytes))
    echo "In use: blocked=${blocked_n} would_reclaim=$(format_bytes "$in_use_total")"
  fi
  echo "Accounted bytes: quarantined=$quarantined permanent=$permanent"
  if [[ -n "$QUARANTINE_DIR" ]]; then
    echo "Quarantine session: ${QUARANTINE_DIR}"
  fi
}

# Read-only print of the last saved cleanup report. A symlink is not followed.
show_last_report() {
  local state_dir report_file
  state_dir=$(_xdg_dir XDG_STATE_HOME "$HOME/.local/state" && printf '.') || return 1
  state_dir="${state_dir%.}/linux-cleaner"
  report_file="${state_dir}/last-report.txt"
  if [[ -n "$CHECK_HEALTH" ]]; then
    if [[ -L "$state_dir" || -L "$report_file" ]]; then
      echo "Unhealthy: cleanup report or state directory is symlinked." >&2
      return 1
    elif [[ ! -e "$report_file" ]]; then
      echo "Unhealthy: cleanup report is missing." >&2
      return 1
    elif [[ ! -f "$report_file" || ! -r "$report_file" ]]; then
      echo "Unhealthy: cleanup report is unreadable." >&2
      return 1
    fi
  fi
  if [[ -L "$state_dir" || -L "$report_file" || ! -f "$report_file" ]]; then
    echo "No cleanup report yet." >&2
    exit 1
  fi
  if [[ "$JSON_OUTPUT" == true || -n "$CHECK_HEALTH" ]]; then
    local line saved="" result="" cleaned="null" skipped="null" failed="null" elapsed_seconds="null"
    local failed_raw="" rest item first=true quarantine_session="" interrupted="" retention_failed=null
    local quarantined_bytes=null permanent_bytes=null
    local -a failed_targets=() exact_failed_targets=()
    while IFS= read -r line || [[ -n "$line" ]]; do
      case "$line" in
        "Saved: "*)
          saved="${line#Saved: }"
          ;;
        "Result: nothing to clean")
          result="nothing_to_clean"
          ;;
        "Result: skipped below --min-reclaim"*)
          result="skipped_below_min_reclaim"
          ;;
        "Result: skipped at or above --min-free"*)
          result="skipped_at_or_above_min_free"
          ;;
        "Result: cleaned="*)
          result="completed"
          if [[ "$line" =~ ^Result:\ cleaned=([[:digit:]]+)\ skipped=([[:digit:]]+)\ failed=([[:digit:]]+)\ elapsed=([[:digit:]]+)s$ ]]; then
            cleaned="${BASH_REMATCH[1]}"
            skipped="${BASH_REMATCH[2]}"
            failed="${BASH_REMATCH[3]}"
            elapsed_seconds="${BASH_REMATCH[4]}"
          fi
          ;;
        "Failed targets: "*)
          failed_raw="${line#Failed targets: }"
          rest="$failed_raw"
          while [[ -n "$rest" ]]; do
            if [[ "$rest" == *", "* ]]; then
              item="${rest%%, *}"
              rest="${rest#*, }"
            else
              item="$rest"
              rest=""
            fi
            failed_targets+=("$item")
          done
          ;;
        "Failed target: "*)
          exact_failed_targets+=("${line#Failed target: }")
          ;;
        "Quarantine session: "*)
          quarantine_session="${line#Quarantine session: }"
          ;;
        "Interrupted: "*)
          interrupted="${line#Interrupted: }"
          interrupted="${interrupted%% *}"
          ;;
        "Retention failed: true"|"Retention failed: false")
          retention_failed="${line#Retention failed: }"
          ;;
        "Accounted bytes:"*)
          quarantined_bytes=null
          permanent_bytes=null
          if [[ "$line" =~ ^Accounted\ bytes:\ quarantined=(0|[123456789][[:digit:]]*)\ permanent=(0|[123456789][[:digit:]]*)$ ]]; then
            quarantined_bytes="${BASH_REMATCH[1]}"
            permanent_bytes="${BASH_REMATCH[2]}"
          fi
          ;;
      esac
    done < "$report_file" || {
      echo "Error: Cannot read cleanup report." >&2
      return 1
    }
    if [[ ${#exact_failed_targets[@]} -gt 0 ]]; then
      failed_targets=("${exact_failed_targets[@]}")
    fi
    if [[ "$JSON_OUTPUT" == true ]]; then
      printf '{"saved":"%s","result":"%s","cleaned":%s,"skipped":%s,"failed":%s,"elapsed_seconds":%s,"failed_targets":[' \
        "$(json_escape "$saved")" "$(json_escape "$result")" "$cleaned" "$skipped" "$failed" "$elapsed_seconds"
      for item in "${failed_targets[@]}"; do
        if [[ "$first" == true ]]; then
          first=false
        else
          printf ','
        fi
        printf '"%s"' "$(json_escape "$item")"
      done
      printf '],"quarantine_session":'
      if [[ -n "$quarantine_session" ]]; then
        printf '"%s"' "$(json_escape "$quarantine_session")"
      else
        printf 'null'
      fi
      printf ',"interrupted":'
      if [[ -n "$interrupted" ]]; then
        printf '"%s"' "$(json_escape "$interrupted")"
      else
        printf 'null'
      fi
      printf ',"retention_failed":%s,"quarantined_bytes":%s,"permanent_bytes":%s}\n' \
        "$retention_failed" "$quarantined_bytes" "$permanent_bytes"
    fi
  fi
  if [[ "$JSON_OUTPUT" != true ]]; then
    cat -- "$report_file" || return 1
  fi
  if [[ -n "$CHECK_HEALTH" ]]; then
    local mtime now reason=""
    if ! mtime=$(stat -c '%Y' -- "$report_file" 2>/dev/null) \
       || ! now=$(date +%s 2>/dev/null) \
       || [[ ! "$mtime" =~ ^[[:digit:]]+$ || ! "$now" =~ ^[[:digit:]]+$ ]]; then
      reason="cannot read cleanup report age"
    elif (( mtime > now )); then
      # A future mtime (clock skew) would otherwise read as fresh for the whole skew.
      reason="cleanup report is dated in the future"
    elif (( now - mtime > CHECK_HEALTH )); then
      reason="cleanup report is older than ${CHECK_HEALTH} seconds"
    elif [[ -n "$interrupted" ]]; then
      reason="cleanup was interrupted"
    elif [[ "$retention_failed" == true ]]; then
      reason="Retention failed: true"
    elif [[ "$failed" != null && ! "$failed" =~ ^0+$ ]]; then
      reason="cleanup failed (failed=${failed})"
    elif [[ "$result" != nothing_to_clean && "$result" != skipped_below_min_reclaim && "$result" != skipped_at_or_above_min_free \
            && ( "$result" != completed || "$failed" == null ) ]]; then
      reason="cleanup report has no successful result"
    fi
    if [[ -n "$reason" ]]; then
      printf 'Unhealthy: %s.\n' "$reason" >&2
      return 1
    fi
  fi
  return 0
}

# Send an opt-in desktop notification summarizing the cleanup result.
# Never fails or blocks: output and exit status are discarded, and a hanging
# notifier is bounded to 5 seconds when timeout(1) is available.
notify_cleanup_result() {
  [[ "${NOTIFY:-false}" == true && "${DRY_RUN:-true}" != true ]] || return 0
  if ! command -v notify-send >/dev/null 2>&1; then
    echo "Warning: --notify requested, but notify-send is not installed." >&2
    return 0
  fi
  local first_line="${RESULT_REPORT_TEXT%%$'\n'*}"
  local reclaimed_line="" interrupted_line="" retention_failed_line="" line msg
  while IFS= read -r line; do
    if [[ "$line" == "Reclaimed: "* ]]; then
      reclaimed_line="$line"
    elif [[ "$line" == "Interrupted: "* ]]; then
      interrupted_line="$line"
    elif [[ "$line" == "Retention failed: true" ]]; then
      retention_failed_line="$line"
    fi
  done <<< "$RESULT_REPORT_TEXT"
  msg="$first_line"
  if [[ -n "$reclaimed_line" ]]; then
    msg+=$'\n'"$reclaimed_line"
  fi
  if [[ -n "$interrupted_line" ]]; then
    msg+=$'\n'"$interrupted_line"
  fi
  if [[ -n "$retention_failed_line" ]]; then
    msg+=$'\n'"$retention_failed_line"
  fi
  local -a notify_args=(--app-name=linux-cleaner)
  if (( ${result_failed:-0} > 0 )) || [[ "${OPERATION_FAILED:-false}" == true || -n "$interrupted_line" ]]; then
    notify_args+=(--urgency=critical)
  fi
  NOTIFY_SENT=true
  if command -v timeout >/dev/null 2>&1; then
    timeout 5 notify-send "${notify_args[@]}" "linux-cleaner" "$msg" >/dev/null 2>&1 || true
  else
    notify-send "${notify_args[@]}" "linux-cleaner" "$msg" >/dev/null 2>&1 || true
  fi
}

# Point a confirmed manual cleanup at the installed-but-disabled daily timer.
suggest_daily_timer() {
  [[ "${FORCE:-false}" == false && "${QUIET:-false}" == false && "${JSON_OUTPUT:-false}" == false && "${OPERATION_FAILED:-false}" == false ]] || return 0
  [[ "${result_cleaned:-0}" -eq 0 ]] && return 0
  command -v systemctl >/dev/null 2>&1 || return 0
  local state=""
  if command -v timeout >/dev/null 2>&1; then
    state=$(timeout 5 systemctl --user is-enabled linux-cleaner-clean.timer 2>/dev/null || true)
  else
    state=$(systemctl --user is-enabled linux-cleaner-clean.timer 2>/dev/null || true)
  fi
  if [[ "$state" == "disabled" ]]; then
    status_echo "Tip: run this cleanup daily with 'systemctl --user enable --now linux-cleaner-clean.timer'."
    if [[ "$TRASH_MODE" == true ]]; then
      status_echo "The timer deletes permanently unless LINUX_CLEANER_TRASH=1 is set in ~/.config/linux-cleaner/env."
    fi
  fi
}

# Share path validation and atomic replacement between cleanup and preview metrics.
write_metrics_textfile() {
  local metrics_file="$1" env_name="$2" kind="$3" metrics_dir tmp
  shift 3
  if [[ "$metrics_file" != /* || "$metrics_file" == *$'\n'* || "$metrics_file" == / ]]; then
    echo "Warning: $env_name must be a literal absolute file path without line feeds; skipping metrics export." >&2
    return 1
  fi
  if [[ -L "$metrics_file" || -d "$metrics_file" ]]; then
    echo "Warning: refusing to write $kind metrics; '$metrics_file' is a symlink or directory." >&2
    return 1
  fi
  metrics_dir=$(dirname -- "$metrics_file") || {
    echo "Warning: could not resolve $kind metrics directory for '$metrics_file'." >&2
    return 1
  }
  if [[ -L "$metrics_dir" || ! -d "$metrics_dir" ]]; then
    echo "Warning: could not write $kind metrics; directory '$metrics_dir' does not exist or is a symlink." >&2
    return 1
  fi
  tmp=$(mktemp "${metrics_dir}/.linux-cleaner-metrics.XXXXXX" 2>/dev/null) || {
    echo "Warning: could not create temporary $kind metrics file in '$metrics_dir'." >&2
    return 1
  }
  chmod 0644 -- "$tmp" 2>/dev/null || true
  if ! printf '%s\n' "$@" > "$tmp"; then
    rm -f -- "$tmp" || true
    echo "Warning: could not write $kind metrics to '$metrics_file'." >&2
    return 1
  fi
  if [[ -L "$metrics_dir" || -L "$metrics_file" || -d "$metrics_file" ]]; then
    rm -f -- "$tmp" || true
    echo "Warning: refusing to write $kind metrics; '$metrics_file' is a symlink or directory." >&2
    return 1
  fi
  if ! mv -f -- "$tmp" "$metrics_file"; then
    rm -f -- "$tmp" || true
    echo "Warning: could not save $kind metrics to '$metrics_file'." >&2
    return 1
  fi
}

# Non-fatal: a bad path or write error warns and never changes exit status.
write_cleanup_metrics() {
  local metrics_file="${LINUX_CLEANER_METRICS_FILE:-}"
  [[ -n "$metrics_file" ]] || return 0
  local line cleaned=0 skipped=0 failed=0 quarantined_bytes=0 permanent_bytes=0 interrupted="" success=1 now elapsed=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      "Result: cleaned="*)
        if [[ "$line" =~ ^Result:\ cleaned=([[:digit:]]+)\ skipped=([[:digit:]]+)\ failed=([[:digit:]]+)\ elapsed=([[:digit:]]+)s$ ]]; then
          cleaned="${BASH_REMATCH[1]}"
          skipped="${BASH_REMATCH[2]}"
          failed="${BASH_REMATCH[3]}"
          elapsed="${BASH_REMATCH[4]}"
        fi
        ;;
      "Accounted bytes:"*)
        if [[ "$line" =~ ^Accounted\ bytes:\ quarantined=(0|[123456789][[:digit:]]*)\ permanent=(0|[123456789][[:digit:]]*)$ ]]; then
          quarantined_bytes="${BASH_REMATCH[1]}"
          permanent_bytes="${BASH_REMATCH[2]}"
        fi
        ;;
      "Interrupted: "*)
        interrupted="${line#Interrupted: }"
        ;;
    esac
  done <<< "${RESULT_REPORT_TEXT:-}"
  if [[ "${OPERATION_FAILED:-false}" == true || -n "$interrupted" ]]; then
    success=0
  fi
  local quarantine_base="$HOME/.cache/linux-cleaner/quarantine" quarantine_bytes=0
  local -a quarantine_metrics=()
  if [[ -e "$quarantine_base" || -L "$quarantine_base" ]]; then
    if [[ ! -d "$quarantine_base" ]] || ! quarantine_bytes=$(quarantine_size_bytes "$quarantine_base" 2>/dev/null); then
      echo "Warning: could not measure quarantine size at '$quarantine_base'; omitting linux_cleaner_quarantine_bytes." >&2
      quarantine_bytes=""
    fi
  fi
  if [[ -n "$quarantine_bytes" ]]; then
    quarantine_metrics=(
      "# HELP linux_cleaner_quarantine_bytes Current quarantine size in bytes."
      "# TYPE linux_cleaner_quarantine_bytes gauge"
      "linux_cleaner_quarantine_bytes ${quarantine_bytes}"
    )
  fi
  # Absent until the Result line is parsed, so an early exit does not report 0.
  local -a duration_metrics=()
  if [[ -n "$elapsed" ]]; then
    duration_metrics=(
      "# HELP linux_cleaner_last_run_duration_seconds Elapsed seconds of the last cleanup run."
      "# TYPE linux_cleaner_last_run_duration_seconds gauge"
      "linux_cleaner_last_run_duration_seconds ${elapsed}"
    )
  fi
  now=$(date +%s 2>/dev/null) || now=0
  if write_metrics_textfile "$metrics_file" LINUX_CLEANER_METRICS_FILE cleanup \
    "# HELP linux_cleaner_last_run_timestamp_seconds Unix timestamp of the last cleanup run." \
    "# TYPE linux_cleaner_last_run_timestamp_seconds gauge" \
    "linux_cleaner_last_run_timestamp_seconds ${now}" \
    "# HELP linux_cleaner_last_run_success Whether the last cleanup run succeeded (1) or failed/was interrupted (0)." \
    "# TYPE linux_cleaner_last_run_success gauge" \
    "linux_cleaner_last_run_success ${success}" \
    "# HELP linux_cleaner_targets Number of targets processed in the last cleanup run by result." \
    "# TYPE linux_cleaner_targets gauge" \
    "linux_cleaner_targets{result=\"cleaned\"} ${cleaned}" \
    "linux_cleaner_targets{result=\"skipped\"} ${skipped}" \
    "linux_cleaner_targets{result=\"failed\"} ${failed}" \
    "# HELP linux_cleaner_reclaimed_bytes Accounted bytes reclaimed in the last cleanup run by kind." \
    "# TYPE linux_cleaner_reclaimed_bytes gauge" \
    "linux_cleaner_reclaimed_bytes{kind=\"quarantined\"} ${quarantined_bytes}" \
    "linux_cleaner_reclaimed_bytes{kind=\"permanent\"} ${permanent_bytes}" \
    "${duration_metrics[@]}" \
    "${quarantine_metrics[@]}"; then
    CLEANUP_METRICS_WRITTEN=true
  fi
  return 0
}

write_preview_metrics() {
  local metrics_file="${LINUX_CLEANER_PREVIEW_METRICS_FILE:-}" now would_skip=0
  [[ -n "$metrics_file" ]] || return 0
  # -ef also catches a second spelling (//, ./) of an existing cleanup metrics file.
  # A matching parent directory and name catches the same path before the file exists.
  if [[ "$metrics_file" == "${LINUX_CLEANER_METRICS_FILE:-}" \
        || ( -n "${LINUX_CLEANER_METRICS_FILE:-}" && "$metrics_file" -ef "$LINUX_CLEANER_METRICS_FILE" ) \
        || ( -n "${LINUX_CLEANER_METRICS_FILE:-}" && "${metrics_file##*/}" == "${LINUX_CLEANER_METRICS_FILE##*/}" \
             && "${metrics_file%/*}/" -ef "${LINUX_CLEANER_METRICS_FILE%/*}/" ) ]]; then
    echo "Warning: LINUX_CLEANER_PREVIEW_METRICS_FILE equals LINUX_CLEANER_METRICS_FILE; skipping preview metrics export." >&2
    return 0
  fi
  [[ "$preview_would_skip" != null ]] && would_skip=1
  now=$(date +%s 2>/dev/null) || now=0
  write_metrics_textfile "$metrics_file" LINUX_CLEANER_PREVIEW_METRICS_FILE preview \
    "# HELP linux_cleaner_preview_timestamp_seconds Unix timestamp of the cleanup preview." \
    "# TYPE linux_cleaner_preview_timestamp_seconds gauge" \
    "linux_cleaner_preview_timestamp_seconds ${now}" \
    "# HELP linux_cleaner_preview_reclaimable_bytes Planned reclaimable bytes in the cleanup preview." \
    "# TYPE linux_cleaner_preview_reclaimable_bytes gauge" \
    "linux_cleaner_preview_reclaimable_bytes ${total_reclaimable_bytes}" \
    "# HELP linux_cleaner_preview_would_skip Whether cleanup would skip (1) or proceed (0)." \
    "# TYPE linux_cleaner_preview_would_skip gauge" \
    "linux_cleaner_preview_would_skip ${would_skip}" || true
}

# Save the plan plus the result. Non-fatal: a bad state path or a write error
# warns and leaves the cleanup's exit status unchanged. The state path is
# untrusted, so a symlink is never followed and readers never see a partial file.
write_last_report_file() {
  local state_dir report_file tmp body failed_name
  if ! state_dir=$(_xdg_dir XDG_STATE_HOME "$HOME/.local/state" && printf '.'); then
    echo "Warning: could not resolve the cleanup report directory." >&2
    return 0
  fi
  state_dir="${state_dir%.}/linux-cleaner"
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
  for failed_name in "${RESULT_FAILED_TARGETS[@]}"; do
    body+=$'\n'"Failed target: $failed_name"
  done
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

# Every cleanup exit records its outcome in both the saved report and the metrics file.
save_last_cleanup_report() {
  write_last_report_file
  write_cleanup_metrics
}

# Check if any specified process is running
# True when some process OTHER than this run matches PATTERN on its command line.
# The whole ancestry is excluded, not just our own PID: an invoking shell, wrapper
# script or scheduler carries our arguments in its command line too, so matching one
# of those would block every target forever while nothing is actually running.
_cmdline_match() {
  local pattern="$1" pid ancestry=" " pids query_status=0
  [[ -z "$pattern" ]] && return 1

  pids=$(pgrep -f -- "$pattern" 2>/dev/null) || query_status=$?
  case "$query_status" in
    0) ;;
    1) return 1 ;;
    *) return 2 ;;
  esac

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
    printf '%s\n' "$pid"
    return 0
  done <<< "$pids"
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

# Print the token and optional PID on separate lines; return 0 active, 1 idle, 2 unknown.
is_process_running() {
  local procs="$1"
  if [[ -z "$procs" ]]; then
    return 1
  fi
  
  # Split with read, not an unquoted expansion: word splitting would also
  # pathname-expand each token against the current directory, so a pattern such
  # as "app*" could turn into a stray file name and silently miss the process.
  local proc pid query_status
  local -a proc_list
  IFS=',' read -r -a proc_list <<< "$procs"
  for proc in "${proc_list[@]}"; do
    proc=$(trim "$proc")
    query_status=0
    if [[ "$proc" == cmdline:* ]]; then
      # A tool launched through a shared runtime (Electron, node) has a comm that is
      # not its own name, so exact-comm matching silently never fires. Match the full
      # command line instead -- but pgrep -f also matches THIS script whenever the
      # pattern appears in our own argv (a config path, or --only-target naming the
      # tool), which would block every target forever. Drop our own PIDs first and
      # treat an otherwise-empty result as "not running".
      # Whitespace after the colon is not part of the pattern: "cmdline: /path"
      # and "cmdline:/path" name the same command line. A blank remainder is
      # already rejected by validate_config_file.
      pid=$(_cmdline_match "$(trim "${proc#cmdline:}")") || query_status=$?
    else
      # The kernel keeps only the first 15 characters of a process name, and
      # pgrep -x refuses a longer plain name outright, so compare such a name on
      # its first 15. A plain name may contain '.' (python3.13-debug). Regex-bearing
      # tokens are the user's own and pass unchanged.
      local comm="$proc"
      [[ ${#comm} -gt 15 && "$comm" =~ ^[[:alnum:]._-]+$ ]] && comm="${comm:0:15}"
      pid=$(pgrep -x "$comm" 2>/dev/null) || query_status=$?
    fi
    case "$query_status" in
      0) printf '%s\n' "$proc" "${pid%%$'\n'*}"; return 0 ;;
      1) ;;
      *) printf '%s\n' "$proc"; return 2 ;;
    esac
  done
  return 1
}

# Map risk level string to integer weight
# Lowercase a risk name in ASCII: under tr_TR, ${x,,} turns I into a dotless ı.
risk_lower() {
  local LC_ALL=C
  printf '%s' "${1,,}"
}

risk_to_int() {
  case "$(risk_lower "$1")" in
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
    nix_store_gc) echo "nix-store" ;;
    *) echo "" ;;
  esac
}

# True when a predefined action runs as the invoking user without sudo and
# measures reclaimed bytes from filesystem free-space delta at run time.
action_is_user_level() {
  case "${1:-}" in
    action:uv_cache_prune|action:pnpm_store_prune|action:hf_cache_prune|action:nix_store_gc) return 0 ;;
    *) return 1 ;;
  esac
}

# Run one predefined action command, bounded by --action-timeout when it is set.
# sudo stays inside the wrapped command. ACTION_TIMED_OUT reports timeout(1)'s
# 124 (stopped by TERM) or 137 (killed after the grace period).
ACTION_TIMED_OUT=false
# Microseconds since the epoch. EPOCHREALTIME needs bash 5 (its radix is a comma
# under tr_TR, hence digits only); bash 4.4 falls back to GNU date.
now_us() {
  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    printf '%s' "${EPOCHREALTIME//[!0-9]/}"
  else
    date +%s%6N
  fi
}
run_action() {
  ACTION_TIMED_OUT=false
  if [[ -z "$ACTION_TIMEOUT" || "$ACTION_TIMEOUT" == 0 ]]; then
    "$@"
    return
  fi
  local rc=0 started elapsed_us
  started=$(now_us)
  local -a timeout_mode=()
  # On a terminal, stay in its process group so Ctrl-C still reaches the action.
  [[ -t 0 ]] && timeout_mode=(--foreground)
  timeout "${timeout_mode[@]}" --kill-after=10 "$ACTION_TIMEOUT" "$@" || rc=$?
  # 124/137 also come from an action's own status or an unrelated SIGKILL (OOM).
  # Microseconds: whole SECONDS ticks would call a 0.6 s exit a 1 s timeout.
  elapsed_us=$(( $(now_us) - started ))
  if [[ ( "$rc" -eq 124 || "$rc" -eq 137 ) ]] && (( elapsed_us >= ACTION_TIMEOUT * 1000000 )); then
    ACTION_TIMED_OUT=true
  fi
  return "$rc"
}

action_display_command() {
  case "${1:-}" in
    action:uv_cache_prune) echo "uv cache prune" ;;
    action:pnpm_store_prune) echo "pnpm store prune" ;;
    action:hf_cache_prune) echo "hf cache prune --yes" ;;
    action:nix_store_gc) echo "nix-store --gc" ;;
    *) echo "" ;;
  esac
}

# Free space in bytes on the filesystem holding PATH.
# Prints nothing when df fails or yields no integer, so a failed probe is not 0 free.
get_fs_avail_bytes() {
  local df_out
  if ! df_out=$(df -B1 --output=avail -- "$1" 2>/dev/null); then
    return 0
  fi
  awk 'NR>1 && $1 ~ /^[0-9]+$/ {v=$1} END {if (v ~ /^[0-9]+$/) print v+0}' <<< "$df_out"
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

# Read-only environment checklist: explain config resolution, GNU userland,
# optional helper binaries, user timer states, last cleanup, and quarantine count.
# Exits 0 when cleanup can run, or 1 when the config is missing, unreadable,
# or invalid, or GNU userland is missing.
run_doctor() {
  local doctor_rc=0 cfg_path="$CONFIG_FILE" cfg_source="explicit" bin_path i cfg_err="" cfg_rc=0
  local -a cfg_labels=(XDG /etc checkout)
  set_default_config_candidates || return 1
  if [[ -z "$cfg_path" ]]; then
    # Same fallback as discovery: the checkout path when no candidate exists.
    cfg_path="${CONFIG_CANDIDATES[2]}"
    cfg_source="checkout"
    for i in 0 1 2; do
      if [[ -f "${CONFIG_CANDIDATES[i]}" ]]; then
        cfg_path="${CONFIG_CANDIDATES[i]}"
        cfg_source="${cfg_labels[i]}"
        break
      fi
    done
  else
    for i in 0 1 2; do
      [[ "$cfg_path" == "${CONFIG_CANDIDATES[i]}" ]] && cfg_source="${cfg_labels[i]}" && break
    done
  fi
  if [[ ! -f "$cfg_path" ]]; then
    printf 'WARN: config: %s (%s, not found)\n' "$cfg_path" "$cfg_source"
    doctor_rc=1
  elif [[ ! -r "$cfg_path" ]]; then
    printf 'WARN: config: %s (%s, not readable)\n' "$cfg_path" "$cfg_source"
    doctor_rc=1
  else
    # Subshell: validate_config_file exits 1, and the checklist must continue.
    # The CONFIG_FILE prefix applies only there, so the caller's value stays put.
    cfg_err=$(CONFIG_FILE="$cfg_path" validate_config_file 2>&1 >/dev/null) || cfg_rc=$?
    if [[ "$cfg_rc" -ne 0 ]]; then
      cfg_err=$(printf '%s' "$cfg_err" | sed $'s/\033\\[[0-9;]*m//g')
      cfg_err="${cfg_err//$'\n'/ }"
      cfg_err=$(trim "$cfg_err")
      printf 'WARN: config: %s (%s, %s)\n' "$cfg_path" "$cfg_source" "$cfg_err"
      doctor_rc=1
    else
      printf 'OK: config: %s (%s)\n' "$cfg_path" "$cfg_source"
    fi
  fi

  if check_gnu_userland; then
    printf 'OK: check_gnu_userland: GNU userland available (du -sb, stat -c, find -print0/-quit, realpath)\n'
  else
    printf 'WARN: check_gnu_userland: missing required GNU userland support (du -sb, stat -c, find -print0/-quit, realpath)\n'
    doctor_rc=1
  fi

  if bin_path=$(command -v pgrep 2>/dev/null); then
    printf 'OK: pgrep: %s\n' "$bin_path"
  else
    printf 'WARN: pgrep: not found (CHECK_PROCESSES rows will fail process check and be skipped)\n'
  fi

  if bin_path=$(command -v flock 2>/dev/null); then
    printf 'OK: flock: %s\n' "$bin_path"
  else
    printf 'WARN: flock: not found (mutating runs will not be serialized)\n'
  fi

  if bin_path=$(command -v git 2>/dev/null); then
    printf 'OK: git: %s\n' "$bin_path"
  else
    printf 'WARN: git: not found (git-tracked file guard disabled)\n'
  fi

  if command -v sudo >/dev/null 2>&1 && sudo -n true </dev/null >/dev/null 2>&1; then
    printf 'OK: sudo -n: non-interactive sudo available\n'
  else
    printf 'INFO: sudo -n: non-interactive sudo unavailable (root targets will prompt or be skipped)\n'
  fi

  if bin_path=$(command -v notify-send 2>/dev/null); then
    printf 'OK: notify-send: %s\n' "$bin_path"
  else
    printf 'INFO: notify-send: not found (--notify unavailable)\n'
  fi

  local clean_timer="unavailable" retention_timer="unavailable" monitor_timer="unavailable" t_unit t_state
  if command -v systemctl >/dev/null 2>&1; then
    for t_unit in linux-cleaner-clean.timer linux-cleaner-retention.timer linux-cleaner-monitor.timer; do
      if command -v timeout >/dev/null 2>&1; then
        t_state=$(timeout 5 systemctl --user is-enabled "$t_unit" 2>/dev/null || true)
      else
        t_state=$(systemctl --user is-enabled "$t_unit" 2>/dev/null || true)
      fi
      t_state=$(trim "${t_state%%$'\n'*}")
      [[ -z "$t_state" ]] && t_state="not-found"
      case "$t_unit" in
        linux-cleaner-clean.timer) clean_timer="$t_state" ;;
        linux-cleaner-retention.timer) retention_timer="$t_state" ;;
        linux-cleaner-monitor.timer) monitor_timer="$t_state" ;;
      esac
    done
  fi
  printf 'INFO: timers (systemctl --user is-enabled): clean=%s retention=%s monitor=%s\n' "$clean_timer" "$retention_timer" "$monitor_timer"

  local state_dir report_file report_line saved="" result="" last_level=INFO report_mtime now retention_note=""
  state_dir="$(_xdg_dir XDG_STATE_HOME "$HOME/.local/state")/linux-cleaner"
  report_file="${state_dir}/last-report.txt"
  if [[ -L "$state_dir" || -L "$report_file" || ! -f "$report_file" ]]; then
    printf 'INFO: last cleanup: none recorded\n'
  elif [[ ! -r "$report_file" ]]; then
    printf 'WARN: last cleanup: report not readable\n'
  else
    while IFS= read -r report_line || [[ -n "$report_line" ]]; do
      case "$report_line" in
        "Saved: "*) saved="${report_line#Saved: }" ;;
        "Result: "*) result="${report_line#Result: }" ;;
        Interrupted:*) last_level=WARN ;;
        "Retention failed: true") last_level=WARN; retention_note="; retention failed" ;;
      esac
    done < "$report_file"
    if [[ "$result" =~ (^|[[:space:]])failed=0*[123456789][[:digit:]]*($|[[:space:]]) ]]; then
      last_level=WARN
    fi
    if [[ "$clean_timer" == enabled ]] \
       && report_mtime=$(stat -c %Y "$report_file" 2>/dev/null) \
       && now=$(date +%s) \
       && (( now - report_mtime > 2 * 24 * 60 * 60 )); then
      last_level=WARN
    fi
    printf '%s: last cleanup: %s %s%s\n' "$last_level" "$saved" "$result" "$retention_note"
  fi

  # The clean unit reads this env file; trash mode there needs a retention bound.
  # The monitor unit reads monitor.env beside it, under $HOME even when XDG_CONFIG_HOME differs.
  local timer_env="$HOME/.config/linux-cleaner/env" monitor_env="$HOME/.config/linux-cleaner/monitor.env" env_line env_risk="" env_config="" env_only="" env_trash="" env_keep="" mon_only="" mon_keep=""
  local timer_env_source="no env file" timer_deletion=permanent
  if [[ "$clean_timer" == enabled && -f "$timer_env" && -r "$timer_env" ]]; then
    timer_env_source="$timer_env"
    while IFS= read -r env_line || [[ -n "$env_line" ]]; do
      env_line=$(trim "$env_line")
      case "$env_line" in
        LINUX_CLEANER_RISK=*) env_risk="${env_line#*=}" ;;
        LINUX_CLEANER_CONFIG=*) env_config="${env_line#*=}" ;;
        LINUX_CLEANER_ONLY_PATH=*) env_only="${env_line#*=}" ;;
        LINUX_CLEANER_TRASH=*) env_trash="${env_line#*=}" ;;
        LINUX_CLEANER_TRASH_KEEP_DAYS=*) env_keep="${env_line#*=}" ;;
      esac
    done < "$timer_env"
    env_risk="${env_risk//[\"\']/}"
    env_config="${env_config//[\"\']/}"
    env_only="${env_only//[\"\']/}"
    env_trash="${env_trash//[\"\']/}"
    env_keep="${env_keep//[\"\']/}"
    # systemd strips whitespace around EnvironmentFile values.
    env_risk=$(trim "$env_risk")
    env_config=$(trim "$env_config")
    env_only=$(trim "$env_only")
    env_trash=$(trim "$env_trash")
    env_keep=$(trim "$env_keep")
    case "$env_trash" in
      1|true|TRUE|yes|YES)
        timer_deletion=quarantine
        if [[ -z "$env_keep" && "$retention_timer" != enabled ]]; then
          printf 'WARN: quarantine retention: %s enables LINUX_CLEANER_TRASH for the daily timer but neither LINUX_CLEANER_TRASH_KEEP_DAYS nor linux-cleaner-retention.timer bounds the quarantine\n' "$timer_env"
        fi
        ;;
    esac
  fi
  if [[ "$clean_timer" == enabled && -e "$timer_env" && "$timer_env_source" == "no env file" ]]; then
    # systemd's EnvironmentFile=- skips only a missing file, so every timer run fails.
    printf 'WARN: daily timer plan: env file not readable (%s)\n' "$timer_env"
  elif [[ "$clean_timer" == enabled ]]; then
    local plan_level=INFO plan_config="" plan_problems=""
    case "$(risk_lower "$env_risk")" in
      ""|safe|medium|danger|dangerous) ;;
      *) plan_level=WARN; plan_problems+="; invalid risk" ;;
    esac
    # The clean run refuses --only-path together with --trash-keep-days.
    if [[ -n "$env_only" && -n "$env_keep" ]]; then
      plan_level=WARN
      plan_problems+="; only-path with keep-days"
    fi
    if [[ -n "$env_keep" && "$env_keep" == *[![:digit:]]* ]]; then
      plan_level=WARN
      plan_problems+="; invalid keep-days"
    fi
    if [[ -n "$env_config" ]]; then
      plan_config=" config=$env_config"
      # The user service starts in HOME, so a relative path resolves there.
      local plan_config_path="$env_config"
      [[ "$plan_config_path" == /* ]] || plan_config_path="$HOME/$plan_config_path"
      if [[ ! -f "$plan_config_path" || ! -r "$plan_config_path" ]]; then
        plan_level=WARN
        plan_problems+="; config not readable"
      elif ! (CONFIG_FILE="$plan_config_path" validate_config_file >/dev/null 2>&1); then
        plan_level=WARN
        plan_problems+="; config invalid"
      fi
    fi
    printf '%s: daily timer plan: risk=%s deletion=%s keep-days=%s%s (%s)%s\n' "$plan_level" "${env_risk:-safe}" "$timer_deletion" "${env_keep:-none}" "$plan_config" "$timer_env_source" "$plan_problems"
  fi
  if [[ -f "$monitor_env" && -r "$monitor_env" ]]; then
    while IFS= read -r env_line || [[ -n "$env_line" ]]; do
      env_line=$(trim "$env_line")
      case "$env_line" in
        LINUX_CLEANER_ONLY_PATH=*) mon_only="${env_line#*=}" ;;
        LINUX_CLEANER_TRASH_KEEP_DAYS=*) mon_keep="${env_line#*=}" ;;
      esac
    done < "$monitor_env"
    mon_only="${mon_only//[\"\']/}"
    mon_keep="${mon_keep//[\"\']/}"
    if [[ -n "$mon_only" && -n "$mon_keep" ]]; then
      printf 'WARN: monitor env: %s combines LINUX_CLEANER_ONLY_PATH with LINUX_CLEANER_TRASH_KEEP_DAYS\n' "$monitor_env"
    fi
  elif [[ -e "$monitor_env" && ! -r "$monitor_env" ]]; then
    printf 'WARN: monitor env: %s (not readable)\n' "$monitor_env"
  fi

  local quarantine_base="$HOME/.cache/linux-cleaner/quarantine" session_dots=""
  if [[ -L "$quarantine_base" ]]; then
    printf 'WARN: quarantine: symlinked quarantine directory refused (%s)\n' "$quarantine_base"
  elif [[ -d "$quarantine_base" && ! -L "$quarantine_base" ]] && \
     ! session_dots=$(find "$quarantine_base" -mindepth 1 -maxdepth 1 -type d -printf '.' 2>/dev/null); then
    printf 'WARN: quarantine: cannot enumerate sessions (%s)\n' "$quarantine_base"
  else
    printf 'INFO: quarantine: %d session(s) (%s)\n' "${#session_dots}" "$quarantine_base"
  fi
  return "$doctor_rc"
}

MAX_RISK_INT=$(risk_to_int "$MAX_RISK") || exit 1

# Build exclude arguments for find
build_exclude_find_args

# Read-only: print the environment checklist and exit.
if [[ "$DOCTOR" == true ]]; then
  run_doctor
  exit $?
fi

# Read-only: print the saved last cleanup report and exit.
if [[ "$REPORT" == true ]]; then
  show_last_report
  exit $?
fi

# Read-only: list quarantine sessions and exit
if [[ "$LIST_SESSIONS" == true ]]; then
  list_quarantine_sessions
  exit 0
fi

# Validate physical records before an unmatched wildcard or a filter can remove
# one from the stream. Session operations intentionally do not require a config.
if [[ -z "$RESTORE_TARGET" && -z "$PURGE_TARGET" && -z "$HOLD_TARGET" && -z "$RELEASE_TARGET" && "$CHECK_CONFIG" != true ]]; then
  validate_config_file >/dev/null
fi

if [[ -n "$ONLY_PATH" ]]; then
  if ! resolve_existing_path "$ONLY_PATH"; then
    echo "Error: --only-path must resolve to an existing path without line feeds: '$ONLY_PATH'." >&2
    exit 1
  fi
  ONLY_PATH_CANONICAL="$RESOLVED_PATH"
fi

if [[ -n "$EXCLUDE_PATH" ]]; then
  if ! resolve_existing_path "$EXCLUDE_PATH"; then
    echo "Error: --exclude-path must resolve to an existing path without line feeds: '$EXCLUDE_PATH'." >&2
    exit 1
  fi
  EXCLUDE_PATH_CANONICAL="$RESOLVED_PATH"
fi

if [[ "$LIST_TARGETS" == true ]]; then
  list_config_targets || exit 1
  exit 0
fi

if [[ "$CHECK_CONFIG" == true ]]; then
  validate_config_file
  exit 0
fi

# Only a cleanup run with a positive limit wraps actions in timeout(1).
if [[ "$DRY_RUN" != true && -n "$ACTION_TIMEOUT" && "$ACTION_TIMEOUT" != 0 ]] && ! command -v timeout >/dev/null 2>&1; then
  echo "Error: --action-timeout requires timeout(1) for cleanup runs." >&2
  exit 1
fi

# Serialize mutating runs (non-preview restore/purge, hold/release, and cleanup)
# with an exclusive flock so overlapping timer and manual invocations cannot race on
# the same files or quarantine sessions. Zero waits fail fast and permit missing
# flock; positive waits require flock. Nonlocking modes ignore valid wait values.
if [[ ( ( -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" ) && "$DRY_RUN_EXPLICIT" != true ) || -n "$HOLD_TARGET" || -n "$RELEASE_TARGET" || "$DRY_RUN" != true ]]; then
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
    lock_args=(-n)
    [[ "$LOCK_WAIT" == 0 ]] || lock_args=(-w "$LOCK_WAIT")
    if ! flock "${lock_args[@]}" 9; then
      if [[ "$LOCK_WAIT" == 0 ]]; then
        echo -e "${RED}Error: another linux-cleaner run is in progress (lock: ${lock_file}).${NC}" >&2
      else
        echo "Error: Failed to acquire linux-cleaner lock within ${LOCK_WAIT} second(s) (lock: ${lock_file})." >&2
      fi
      exit 1
    fi
  elif [[ "$LOCK_WAIT" != 0 ]]; then
    echo "Error: --lock-wait requires flock for mutating runs." >&2
    exit 1
  fi
fi

if [[ -n "$HOLD_TARGET" ]]; then
  set_session_hold hold "$HOLD_TARGET"
  exit 0
fi
if [[ -n "$RELEASE_TARGET" ]]; then
  set_session_hold release "$RELEASE_TARGET"
  exit 0
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
# Blocked targets keep parsed_sizes at 0 so JSON bytes and --min-reclaim ignore
# them. This parallel array holds the would-reclaim estimate instead.
parsed_in_use_bytes=()
parsed_exists=()
parsed_safety=()
parsed_ages=()
parsed_idle=()
parsed_risks=()
parsed_cmds=()
parsed_procs=()
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
total_in_use_bytes=0
hidden_medium=0
hidden_danger=0
hidden_risk_names=""
hidden_risk_name_list=()
declare -A hidden_risk_seen=()
# Targets whose process starts after planning, blocked again in the cleanup loop.
runtime_blocked_count=0
runtime_blocked_bytes=0

# Collect configured and built-in protected paths before target analysis.
PROTECTED_PATHS=()
collect_protected_paths() {
  local line f1 f2 expanded stripped canonical
  PROTECTED_PATHS=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    IFS='|' read -r f1 f2 _ <<< "$line"
    [[ "$(trim "$f1")" == "protect" ]] || continue
    if ! expanded=$(expand_path_safe "$(trim "$f2")"); then
      echo "Error: protect PATH has unsafe path expansion" >&2
      return 1
    fi
    stripped=$(strip_trailing_slashes "$expanded")
    if ! canonical=$(canonicalize_physical "$stripped"); then
      echo "Error: could not resolve protect PATH" >&2
      return 1
    fi
    PROTECTED_PATHS+=("$canonical")
  done < "$CONFIG_FILE"
  # Keep undo data, operation history and the live lock out of cleanup targets.
  # An unresolvable HOME needs no entry: the safety check already marks targets
  # under it unsafe.
  if canonical=$(canonicalize_physical "$HOME/.cache/linux-cleaner"); then
    PROTECTED_PATHS+=("$canonical")
  fi
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

collect_protected_paths || exit 1

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

  select_target_name "$name" || continue
  select_target_path "$raw_path" "$custom_clean_cmd" || continue

  # Map risk levels
  target_risk_int=$(risk_to_int "$risk" "${CONFIG_FILE}:${config_lineno}: ") || exit 1
  if [[ $target_risk_int -gt $MAX_RISK_INT ]]; then
    case "$target_risk_int" in
      2) hidden_medium=$((hidden_medium + 1)) ;;
      3) hidden_danger=$((hidden_danger + 1)) ;;
    esac
    # A wildcard row expands to one record per match; name it once.
    if [[ -z "${hidden_risk_seen[$name]+set}" ]]; then
      hidden_risk_seen[$name]=1
      hidden_risk_names+="${hidden_risk_names:+, }$name"
      hidden_risk_name_list+=("$name")
    fi
    continue
  fi
  
  # An empty age means the whole directory (effective 0).
  [[ -z "$min_age" ]] && min_age=0
  if [[ -n "$MIN_AGE_OVERRIDE" ]]; then
    [[ "$custom_clean_cmd" == action:* ]] && continue
    age_filter_matched=true
    row_age=${min_age#"${min_age%%[!0]*}"}
    row_age=${row_age:-0}
    # shellcheck disable=SC2071
    if [[ ${#MIN_AGE_OVERRIDE} -gt ${#row_age} || ( ${#MIN_AGE_OVERRIDE} -eq ${#row_age} && "$MIN_AGE_OVERRIDE" > "$row_age" ) ]]; then
      min_age="$MIN_AGE_OVERRIDE"
    fi
  fi
  effective_age="$min_age"
  idle_age=0
  if [[ "$custom_clean_cmd" == "filter:cxx_build" ]] && has_positive_age "$min_age"; then
    effective_age=0
    idle_age="$min_age"
  fi
  
  # Safe path expansions & cleanup trailing slashes
  if ! expanded_path=$(expand_path_safe "$raw_path"); then
    echo "Error: ${CONFIG_FILE}:${config_lineno}: target PATH has unsafe path expansion" >&2
    exit 1
  fi
  stripped_path=$(strip_trailing_slashes "$expanded_path")
  
  # Resolve to canonical; a failed final symlink stays display-only and refused.
  safety_status=0
  if [[ -n "$ONLY_PATH" ]]; then
    path="$SELECTED_TARGET_PATH"
  elif ! path=$(canonicalize_physical "$stripped_path"); then
    if [[ -L "$stripped_path" ]]; then
      path="$stripped_path"
      safety_status=3
    else
      echo "Error: ${CONFIG_FILE}:${config_lineno}: could not resolve target PATH" >&2
      exit 1
    fi
  fi

  # Quarantine records split on '|', so a resolved path holding one would restore
  # to a truncated path. (A resolved newline already aborts in canonicalize_physical.)
  if [[ "$path" == *'|'* ]]; then
    safety_status=4
  fi

  # Keep a failed-resolution symlink refused even if the leaf changes afterward.
  if [[ "$safety_status" -eq 0 ]]; then
    if [[ -L "$stripped_path" ]]; then
      safety_status=3
    else
      check_path_safety "$path" || safety_status=$?
    fi
  fi
  
  exists=false
  size_bytes=0
  in_use_bytes=0
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
  elif [[ $safety_status -eq 4 ]]; then
    target_status=skipped
    target_reason="resolved path contains '|'"
    status_echo "  [${YELLOW}SKIP${NC}] $name: skipped: $target_reason."
    safety_status=1
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
      process_status=0
      running_proc=$(is_process_running "$check_procs") || process_status=$?
      running_pid=""
      if [[ "$running_proc" == *$'\n'* ]]; then
        running_pid="${running_proc#*$'\n'}"
        running_proc="${running_proc%%$'\n'*}"
      fi
      if [[ "$process_status" -eq 2 ]]; then
        target_status=skipped
        target_reason="process check failed for '$running_proc'"
        status_echo "  [${YELLOW}SKIP${NC}] $name: skipped: $target_reason."
      elif [[ "$process_status" -eq 0 ]]; then
        target_status=blocked
        target_reason="process '$running_proc' is active"
        # set_target_exclusions already ran for this row, so the estimate uses its patterns.
        in_use_bytes=$(blocked_in_use_bytes "$path" "$effective_age" "$idle_age" "$custom_clean_cmd")
        in_use_note=""
        if [[ "$in_use_bytes" -gt 0 ]]; then
          in_use_note="; $(format_bytes "$in_use_bytes") would be reclaimable otherwise"
        fi
        status_echo "  [${YELLOW}BLOCKED${NC}] $name: Skip cleanup because process '$running_proc' is active${in_use_note}.${running_pid:+ (pid $running_pid)}"
      else
        # Determine if sudo is needed. A dry-run only probes with sudo -n and
        # never prompts. A real run skips the target when privileges are unavailable.
        requires_sudo=false
        root_unavailable=false
        if { [[ "$custom_clean_cmd" == action:* ]] && ! action_is_user_level "$custom_clean_cmd"; } || \
           [[ -e "$path" && ! -r "$path" ]] || \
           { [[ "$custom_clean_cmd" != action:* ]] && [[ "$safety_status" -eq 2 ]] && [[ ! -w "$(dirname "$path" 2>/dev/null || echo /)" ]] && \
             { [[ ! -e "$path" ]] || { ! has_positive_age "$effective_age" && [[ -z "${TARGET_EXCLUDE_PATTERNS:-}" ]]; }; }; }; then
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
        git_tracked_status=0
        if [[ "$root_unavailable" != true && -e "$path" && -r "$path" && ( ! -d "$path" || -x "$path" ) ]]; then
          git_tracked_count=$(count_git_tracked "$path") || git_tracked_status=$?
        fi
        if [[ "$root_unavailable" == true ]]; then
          :
        elif [[ "$git_tracked_status" -ne 0 ]]; then
          target_status=skipped
          target_reason="git-tracked check failed"
          status_echo "  [${YELLOW}SKIP${NC}] $name: skipped: $target_reason."
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
            activity_out=""
            activity_rc=0
            if has_positive_age "$idle_age"; then
              activity_out=$(with_sudo "$use_sudo" find "$path" "${EXCLUDE_FIND_ARGS[@]}" -mtime -"$idle_age" -print -quit 2>/dev/null) || activity_rc=$?
            fi
            if action_is_user_level "$custom_clean_cmd"; then
              size_bytes=0
              runtime_sized=true
              exists=true
              target_status=found
              outside_home_suffix=""
              [[ $safety_status -eq 2 ]] && outside_home_suffix=" (outside HOME)"
              debug_echo "  [${GREEN}FOUND${NC}] $name: size measured at run time ($(action_display_command "$custom_clean_cmd"))$outside_home_suffix"
            elif [[ -n "$activity_out" ]]; then
              target_status=clean
              debug_echo "  [${BLUE}CLEAN${NC}] $name: active within $idle_age days."
            elif [[ "$activity_rc" -ne 0 ]]; then
              target_status=skipped
              target_reason="activity check failed"
              status_echo "  [${YELLOW}SKIP${NC}] $name: skipped: $target_reason."
            else
              read -r size_bytes should_clean < <(measure_eligible_size "$path" "$effective_age" "$use_sudo")
              readable_size=$(format_bytes "$size_bytes")

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
                if [[ "$SHOW_MATCHES" == true && "$QUIET" != true && "$custom_clean_cmd" != action:* ]]; then
                  print_matching_paths "$path" "$effective_age" "$use_sudo"
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
  parsed_in_use_bytes+=("$in_use_bytes")
  total_in_use_bytes=$((total_in_use_bytes + in_use_bytes))
  parsed_exists+=("$exists")
  parsed_safety+=("$safety_status")
  parsed_ages+=("$effective_age")
  parsed_idle+=("$idle_age")
  parsed_risks+=("$risk")
  parsed_cmds+=("$custom_clean_cmd")
  parsed_procs+=("$check_procs")
  parsed_sudos+=("$use_sudo")
  parsed_statuses+=("${target_status:-skipped}")
  parsed_reasons+=("${target_reason:-}")

done < <(expand_config_globs)

check_target_selection || exit 1

if [[ "$JSON_OUTPUT" != true ]]; then
  echo
  echo -e "${BOLD}Total potential space savings: ${GREEN}$(format_bytes "$total_reclaimable_bytes")${NC}"
  if [[ "$total_in_use_bytes" -gt 0 ]]; then
    echo "Held by active processes: $(format_bytes "$total_in_use_bytes") (not counted above)"
  fi
  echo

  # Captured once, with no color codes (the printer uses printf, not the color vars).
  PLAN_REPORT_TEXT=$(print_plan_report)
  if [[ "$QUIET" != true ]]; then
    printf '%s\n\n' "$PLAN_REPORT_TEXT"
  fi
fi

# Whether any analyzed target is cleanable (user-level prune rows count even at 0 B).
has_cleanable_target=false
for i in "${!parsed_exists[@]}"; do
  if [[ "${parsed_exists[$i]}" == true && "${parsed_safety[$i]}" -ne 1 ]]; then
    has_cleanable_target=true
    break
  fi
done

home_free_bytes=0
# A zero threshold disables the gate, like --min-reclaim 0.
if [[ "$MIN_FREE_BYTES" -gt 0 ]]; then
  # An unreadable value stays empty so it is not mistaken for 0 free.
  home_free_bytes=$({ df -B1 --output=avail -- "${MIN_FREE_PATH:-$HOME}" 2>/dev/null || true; } | awk 'NR>1 && $1 ~ /^[0-9]+$/ {v=$1} END {print v}')
  if [[ -z "$home_free_bytes" ]]; then
    echo -e "${YELLOW}Warning: cannot read free space on the filesystem holding ${MIN_FREE_PATH:-HOME}; --min-free ${MIN_FREE} is ignored this run.${NC}" >&2
    home_free_bytes=0
  fi
fi

preview_would_skip=null
if [[ -n "$MIN_RECLAIM" && "$total_reclaimable_bytes" -lt "$MIN_RECLAIM_BYTES" ]]; then
  preview_would_skip='"skipped_below_min_reclaim"'
elif [[ "$MIN_FREE_BYTES" -gt 0 && "$home_free_bytes" -ge "$MIN_FREE_BYTES" ]]; then
  preview_would_skip='"skipped_at_or_above_min_free"'
elif [[ "$total_reclaimable_bytes" -eq 0 && "$has_cleanable_target" != true ]]; then
  preview_would_skip='"nothing_to_clean"'
fi
if [[ "$DRY_RUN" == true ]]; then
  write_preview_metrics
fi
preview_exit_status=0
if [[ "$EXIT_CODE" == true && "$preview_would_skip" == null ]]; then
  preview_exit_status=2
fi

if [[ "$JSON_OUTPUT" == true ]]; then
  emit_dry_run_json
  exit "$preview_exit_status"
fi

# If dry-run is specified, we stop here
if [[ "$DRY_RUN" = true ]]; then
  status_echo "${YELLOW}Dry-run mode active. No files were modified.${NC}"
  if [[ -n "$MIN_RECLAIM" && "$total_reclaimable_bytes" -lt "$MIN_RECLAIM_BYTES" ]]; then
    status_echo "Below --min-reclaim ${MIN_RECLAIM}: a cleanup run would skip."
  elif [[ "$MIN_FREE_BYTES" -gt 0 && "$home_free_bytes" -ge "$MIN_FREE_BYTES" ]]; then
    status_echo "Free space $(format_bytes "$home_free_bytes") is at or above --min-free ${MIN_FREE}: a cleanup run would skip."
  elif [[ "$total_reclaimable_bytes" -gt 0 || "$has_cleanable_target" == true ]]; then
    # Repeat the options that shaped this preview, so the apply run plans the same targets.
    next_args=(cleaner --clean)
    [[ "$CONFIG_EXPLICIT" == true ]] && next_args+=(--config "$CONFIG_FILE")
    # A CLI --risk safe that overrides LINUX_CLEANER_RISK must be repeated too.
    [[ "$MAX_RISK" != safe || -n "${LINUX_CLEANER_RISK:-}" ]] && next_args+=(--risk "$MAX_RISK")
    [[ "$TRASH_MODE" == true ]] && next_args+=(--trash)
    [[ -n "$EXCLUDE_PATTERNS" ]] && next_args+=(--exclude "$EXCLUDE_PATTERNS")
    [[ -n "$ONLY_TARGET" ]] && next_args+=(--only-target "$ONLY_TARGET")
    [[ -n "$EXCLUDE_TARGET" ]] && next_args+=(--exclude-target "$EXCLUDE_TARGET")
    [[ -n "$ONLY_PATH" ]] && next_args+=(--only-path "$ONLY_PATH")
    [[ -n "$EXCLUDE_PATH" ]] && next_args+=(--exclude-path "$EXCLUDE_PATH")
    [[ -n "$MIN_RECLAIM" ]] && next_args+=(--min-reclaim "$MIN_RECLAIM")
    [[ -n "$MIN_FREE" ]] && next_args+=(--min-free "$MIN_FREE")
    [[ -n "$MIN_FREE_PATH" ]] && next_args+=(--min-free-path "$MIN_FREE_PATH")
    [[ -n "$MIN_AGE_OVERRIDE" ]] && next_args+=(--min-age "$MIN_AGE_OVERRIDE")
    [[ -n "$TRASH_KEEP_DAYS" ]] && next_args+=(--trash-keep-days "$TRASH_KEEP_DAYS")
    [[ "$FAIL_FAST" == true ]] && next_args+=(--fail-fast)
    # An explicit 0 must survive replay over an inherited LINUX_CLEANER_ACTION_TIMEOUT.
    [[ -n "$ACTION_TIMEOUT" ]] && next_args+=(--action-timeout "$ACTION_TIMEOUT")
    if [[ ${#next_args[@]} -eq 2 ]]; then
      status_echo "Next: run 'cleaner --clean' to apply this plan, or 'cleaner --clean --trash' to quarantine instead of deleting."
    else
      next_trash_note=""
      [[ "$TRASH_MODE" != true ]] && next_trash_note=" (add --trash to quarantine instead of deleting)"
      next_cmd=$(printf '%q ' "${next_args[@]}")
      next_cmd=${next_cmd% }
      status_echo "Next: run 'cleaner --clean' to apply this plan, repeating this preview's options${next_trash_note}:"
      # status_echo uses echo -e: double backslashes so the %q quoting prints unchanged.
      status_echo "  ${next_cmd//\\/\\\\}"
    fi
  fi
  if [[ "$CONFIG_DISCOVERED" == true ]]; then
    user_config_parent=$(_xdg_dir XDG_CONFIG_HOME "$HOME/.config" && printf '.') || exit 1
    user_config_parent=${user_config_parent%.}
    user_config="$user_config_parent/linux-cleaner/cleaner.conf"
    if [[ ! -e "$user_config" ]]; then
      status_echo "Customize: run 'cleaner --init-config' to copy this config to $user_config and edit it."
    fi
  fi
  exit "$preview_exit_status"
fi

# GNU-userland preflight: this tool relies on GNU coreutils/findutils flags on
# the deletion path; check them before any destructive operation.
if check_gnu_userland; then GNU_USERLAND_OK=true; else GNU_USERLAND_OK=false; fi
if [[ "$GNU_USERLAND_OK" != true ]]; then
  echo -e "${RED}Error: GNU coreutils are required for cleanup (du -sb, stat -c, find -print0/-quit, GNU realpath). Refusing to delete on a non-GNU userland; re-run with --dry-run for a best-effort preview.${NC}" >&2
  exit 1
fi

handle_cleanup_signal() {
  local sig="$1" code="$2" context="${3:-before all targets finished}"
  trap - INT TERM
  # During retention the report was already printed; add only the interruption line.
  if (( $# < 3 )); then
    RESULT_REPORT_TEXT=$(print_result_report)
    printf '%s\n' "$RESULT_REPORT_TEXT"
  fi
  RESULT_REPORT_TEXT+=$'\n'"Interrupted: ${sig} ${context}"
  printf '%s\n' "Interrupted: ${sig} ${context}"
  journal_error_line "Cleanup interrupted: ${sig} ${context}."
  save_last_cleanup_report
  notify_cleanup_result
  log_operation "$(date '+%Y-%m-%dT%H:%M:%S') mode=run outcome=interrupted signal=${sig}"
  exit "$code"
}

run_retention_trapped() {
  trap 'handle_cleanup_signal SIGINT 130 "during quarantine retention"' INT
  trap 'handle_cleanup_signal SIGTERM 143 "during quarantine retention"' TERM
  apply_trash_keep_days
  trap - INT TERM
}

if [[ -n "$MIN_RECLAIM" && "$total_reclaimable_bytes" -lt "$MIN_RECLAIM_BYTES" ]]; then
  echo "Planned reclaim $(format_bytes "$total_reclaimable_bytes") is below --min-reclaim ${MIN_RECLAIM}; nothing was cleaned."
  RESULT_REPORT_TEXT="Result: skipped below --min-reclaim ${MIN_RECLAIM}"
  RESULT_REPORT_TEXT+=$'\nAccounted bytes: quarantined=0 permanent=0'
  save_last_cleanup_report
  run_retention_trapped
  notify_cleanup_result
  if [[ "$OPERATION_FAILED" = true ]]; then
    journal_error_line "Retention purge failed after the cleanup was skipped."
    exit 1
  fi
  exit 0
fi

if [[ "$MIN_FREE_BYTES" -gt 0 && "$home_free_bytes" -ge "$MIN_FREE_BYTES" ]]; then
  echo "Free space $(format_bytes "$home_free_bytes") is at or above --min-free ${MIN_FREE}; nothing was cleaned."
  RESULT_REPORT_TEXT="Result: skipped at or above --min-free ${MIN_FREE}"
  RESULT_REPORT_TEXT+=$'\nAccounted bytes: quarantined=0 permanent=0'
  save_last_cleanup_report
  run_retention_trapped
  notify_cleanup_result
  if [[ "$OPERATION_FAILED" = true ]]; then
    journal_error_line "Retention purge failed after the cleanup was skipped."
    exit 1
  fi
  exit 0
fi

# Check if there is anything to clean
if [[ "$total_reclaimable_bytes" -eq 0 && "$has_cleanable_target" != true ]]; then
  echo -e "${GREEN}No files need cleaning. Everything is already clean!${NC}"
  # Overwrite the previous report so --report never shows a stale run as the last one.
  RESULT_REPORT_TEXT="Result: nothing to clean"
  RESULT_REPORT_TEXT+=$'\nAccounted bytes: quarantined=0 permanent=0'
  save_last_cleanup_report
  run_retention_trapped
  notify_cleanup_result
  if [[ "$OPERATION_FAILED" = true ]]; then
    journal_error_line "Retention purge failed after the cleanup was skipped."
    exit 1
  fi
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
fail_fast_stopped=""

QUARANTINE_DIR=""

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
  if [[ "$(risk_lower "$risk_level")" =~ ^danger(ous)?$ && "$YES_DANGER" != true ]]; then
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

  # A process can start after analysis, while the user confirms or earlier
  # targets are cleaned. Leave it in place and count the skip, not a failure.
  check_procs="${parsed_procs[$i]:-}"
  if [[ -n "$check_procs" ]]; then
    process_status=0
    running_proc=$(is_process_running "$check_procs") || process_status=$?
    running_pid=""
    if [[ "$running_proc" == *$'\n'* ]]; then
      running_pid="${running_proc#*$'\n'}"
      running_proc="${running_proc%%$'\n'*}"
    fi
    if [[ "$process_status" -eq 2 ]]; then
      status_echo "  [${YELLOW}SKIP${NC}] $name: skipped: process check failed for '$running_proc'."
      result_skipped=$((result_skipped + 1))
      continue
    elif [[ "$process_status" -eq 0 ]]; then
      runtime_blocked_count=$((runtime_blocked_count + 1))
      runtime_blocked_bytes=$((runtime_blocked_bytes + size))
      runtime_note=""
      if [[ "$size" -gt 0 ]]; then
        runtime_note="; $(format_bytes "$size") would be reclaimable otherwise"
      fi
      status_echo "  [${YELLOW}BLOCKED${NC}] $name: Skip cleanup because process '$running_proc' is active${runtime_note}.${running_pid:+ (pid $running_pid)}"
      result_skipped=$((result_skipped + 1))
      continue
    fi
  fi

  # Handle Cleanup
  custom_clean_cmd="${parsed_cmds[$i]:-}"
  set_target_exclusions "$custom_clean_cmd"

  # A single file or an idle build tree can be rewritten after analysis, while
  # the user confirms or earlier targets are cleaned. Whole-target rm and
  # quarantine do not reapply -mtime. Leave it in place and count the skip.
  # Directories with a positive age already delete through find -mtime.
  idle_limit="${parsed_idle[$i]:-0}"
  if [[ "$custom_clean_cmd" == "filter:cxx_build" ]] && has_positive_age "$idle_limit"; then
    activity_rc=0
    activity_out=$(with_sudo "$use_sudo" find "$path" "${EXCLUDE_FIND_ARGS[@]}" -mtime -"$idle_limit" -print -quit 2>/dev/null) || activity_rc=$?
    if [[ -n "$activity_out" ]]; then
      status_echo "  [${YELLOW}SKIP${NC}] $name: skipped: active within $idle_limit days."
    elif [[ "$activity_rc" -ne 0 ]]; then
      status_echo "  [${YELLOW}SKIP${NC}] $name: skipped: activity check failed."
    fi
    if [[ -n "$activity_out" || "$activity_rc" -ne 0 ]]; then
      result_skipped=$((result_skipped + 1))
      continue
    fi
  fi
  if has_positive_age "$age" && ! path_is_real_dir "$use_sudo" "$path" \
     && ! path_still_older_than "$use_sudo" "$path" "$age"; then
    status_echo "  [${YELLOW}SKIP${NC}] $name: skipped: no longer older than $age days."
    result_skipped=$((result_skipped + 1))
    continue
  fi

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
        if run_action sudo paccache -rk1; then
          action_success=true
        fi
        ;;
      action:paccache_keep2)
        if run_action sudo paccache -rk2; then
          action_success=true
        fi
        ;;
      action:paccache_keep3)
        if run_action sudo paccache -rk3; then
          action_success=true
        fi
        ;;
      action:pacman_clean)
        if run_action sudo pacman -Sc --noconfirm; then
          action_success=true
        fi
        ;;
      action:apt_clean)
        if run_action sudo apt-get clean; then
          action_success=true
        fi
        ;;
      action:dnf_clean)
        if run_action sudo dnf clean all; then
          action_success=true
        fi
        ;;
      action:zypper_clean)
        if run_action sudo zypper clean -a; then
          action_success=true
        fi
        ;;
      action:apk_clean)
        if run_action sudo apk cache clean; then
          action_success=true
        fi
        ;;
      action:uv_cache_prune)
        if run_action uv cache prune --cache-dir "$path"; then
          action_success=true
        fi
        ;;
      action:pnpm_store_prune)
        if run_action pnpm store prune --store-dir "$path"; then
          action_success=true
        fi
        ;;
      action:hf_cache_prune)
        if run_action hf cache prune --yes --cache-dir "$path"; then
          action_success=true
        fi
        ;;
      action:nix_store_gc)
        if run_action nix-store --gc; then
          action_success=true
        fi
        ;;
    esac
    if [[ "$action_success" = true ]]; then
      credited_bytes="$size"
      if action_is_user_level "$custom_clean_cmd"; then
        avail_after=$(get_fs_avail_bytes "$path")
        if [[ -n "$avail_before" && -n "$avail_after" ]]; then
          credited_bytes=$((avail_after - avail_before))
          if [[ "$credited_bytes" -lt 0 ]]; then
            credited_bytes=0
          fi
        else
          credited_bytes=0
        fi
      fi
      total_deleted_bytes=$((total_deleted_bytes + credited_bytes))
      total_action_bytes=$((total_action_bytes + credited_bytes))
      result_cleaned=$((result_cleaned + 1))
      log_operation "$(date '+%Y-%m-%dT%H:%M:%S') mode=action risk=${risk_level} target='${name}' path='${path}' action=${custom_clean_cmd} outcome=success"
    else
      if [[ "$ACTION_TIMED_OUT" == true ]]; then
        echo -e "  ${RED}Error: Action '$custom_clean_cmd' for '$name' timed out after ${ACTION_TIMEOUT} seconds.${NC}" >&2
      else
        echo -e "  ${RED}Error: Action '$custom_clean_cmd' for '$name' failed.${NC}" >&2
      fi
      OPERATION_FAILED=true
      result_failed=$((result_failed + 1))
      result_failed_names+="${result_failed_names:+, }${name}"
      RESULT_FAILED_TARGETS+=("$name")
      log_operation "$(date '+%Y-%m-%dT%H:%M:%S') mode=action risk=${risk_level} target='${name}' path='${path}' action=${custom_clean_cmd} outcome=failed"
      if [[ "$FAIL_FAST" == true ]]; then
        fail_fast_stopped="$name"
        break
      fi
    fi
    continue
  fi

  if [[ "$TRASH_MODE" = true ]] && ! quarantine_has_room "$path" "$use_sudo" "$size"; then
    echo -e "  ${RED}Error: Not enough free space to quarantine '$name' (needs $(format_bytes "$size"), $(format_bytes "$MOVE_AVAIL_BYTES") free); left in place.${NC}" >&2
    OPERATION_FAILED=true
    target_failed=true
  elif [[ "$TRASH_MODE" = true ]]; then
    # Allocate one session lazily, after confirmation and only for a target
    # that will actually be moved to quarantine.
    if [[ -z "$QUARANTINE_DIR" ]]; then
      time_stamp=$(date +%Y-%m-%d_%H-%M-%S)
      quarantine_base="$HOME/.cache/linux-cleaner/quarantine"
      refuse_symlinked_quarantine "$quarantine_base" || exit 1
      (umask 077; mkdir -p "$quarantine_base")
      # mkdir -p can race with a swap of the base for a symlink.
      refuse_symlinked_quarantine "$quarantine_base" || exit 1
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
        stream_rc=""
        while IFS= read -r -d '' file; do
          if [[ -z "$file" ]]; then
            IFS= read -r -d '' stream_rc
            break
          fi
          rel_path="${file#"$path"/}"
          dest_file="$q_target/$rel_path"
          if ! with_sudo "$use_sudo" mkdir -p "$(dirname "$dest_file")"; then
            success=false
            continue
          fi
          if with_sudo "$use_sudo" mv "$file" "$dest_file"; then
            if [[ "$aged_moved" = false ]]; then
              aged_moved=true
              # A missed record would leave every later file unrestorable.
              echo "aged|${i}_${safe_name}|$path|$use_sudo|$owner_info" >> "$QUARANTINE_DIR/quarantine.meta" || { success=false; break; }
            fi
          else
            success=false
          fi
        done < <(print0_with_status with_sudo "$use_sudo" find "$path" -mindepth 1 "${EXCLUDE_FIND_ARGS[@]}" \( -type f -o -type l \) "${find_mtime_args[@]}" -print0)
        [[ "$stream_rc" == 0 ]] || success=false
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
    RESULT_FAILED_TARGETS+=("$name")
    if [[ "$FAIL_FAST" == true ]]; then
      fail_fast_stopped="$name"
      break
    fi
  else
    result_cleaned=$((result_cleaned + 1))
  fi
done
trap - INT TERM

RESULT_REPORT_TEXT=$(print_result_report)
if [[ -n "$fail_fast_stopped" ]]; then
  RESULT_REPORT_TEXT+=$'\n'"Stopped early: --fail-fast after ${fail_fast_stopped}; $((${#parsed_names[@]} - i - 1)) targets not attempted"
fi
printf '%s\n' "$RESULT_REPORT_TEXT"
save_last_cleanup_report
if [[ -z "$fail_fast_stopped" ]]; then
  run_retention_trapped
fi
if [[ "$OPERATION_FAILED" == true ]] || (( result_failed > 0 )); then
  journal_error_line "Cleanup failed: failed=${result_failed}; targets: ${result_failed_names:-none}; operation_failed=${OPERATION_FAILED}; retention_failed=${RETENTION_FAILED:-false}."
fi
notify_cleanup_result

echo
if [[ "$TRASH_MODE" = true ]]; then
  if [[ "$total_action_bytes" -gt 0 ]]; then
    quarantine_bytes=$((total_deleted_bytes - total_action_bytes))
    echo -e "${BOLD}${GREEN}Cleanup finished! Total space quarantined: $(format_bytes "$quarantine_bytes"); permanently reclaimed by actions: $(format_bytes "$total_action_bytes")${NC}"
  else
    echo -e "${BOLD}${GREEN}Cleanup finished! Total space quarantined: $(format_bytes "$total_deleted_bytes")${NC}"
  fi
  # A session without metadata (e.g. an aged target with nothing old) has nothing to restore.
  if [[ -n "$QUARANTINE_DIR" && -s "$QUARANTINE_DIR/quarantine.meta" ]]; then
    status_echo "Undo: cleaner --restore ${QUARANTINE_DIR##*/}"
  fi
else
  echo -e "${BOLD}${GREEN}Cleanup finished! Total space permanently reclaimed: $(format_bytes "$total_deleted_bytes")${NC}"
fi

suggest_daily_timer

# Report a non-zero status when any target failed, so an unattended run (cron,
# systemd) can detect a failure that was otherwise only printed to stderr.
if [[ "$OPERATION_FAILED" = true ]]; then
  echo -e "${RED}One or more targets failed to clean; see the errors above.${NC}" >&2
  exit 1
fi
