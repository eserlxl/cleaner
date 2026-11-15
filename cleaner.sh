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
readonly VERSION="1.9.1"

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
  --exclude-from FILE        File of literal glob patterns to exclude, one per line (# comments and blank lines ignored; env: LINUX_CLEANER_EXCLUDE_FROM).
  --list-sessions            List quarantine sessions (read-only) and exit.
  --report                   Print the saved last cleanup report and exit.
  --check-health SECONDS     With --report: exit 0 only for a successful report at most SECONDS old (skips succeed).
  --list-targets             List configured cleanup targets (read-only) and exit.
  --check-config             Validate the configuration file (supports --json) and exit (no disk analysis).
  --init-config              Copy the active config to your user config path (never overwrites).
  --overlay                  With --init-config: write a minimal include| overlay layered over the active config.
  --init-env                 Copy the shipped systemd timer env template to ~/.config/linux-cleaner/env (add --trash for 30d quarantine; never overwrites).
  --doctor                   Check the runtime environment a cleanup depends on (read-only; supports --json) and exit.
  --strict                   With --doctor: exit 1 if any diagnostic warning is present.
  --restore SESSION          Restore files from quarantine session (latest or timestamp); --dry-run previews.
  --hold-session SESSION     Protect a quarantine session (latest or timestamp) from every purge, --trash-keep-days, and --trash-max-size retention.
  --release-session SESSION  Remove a session hold so normal purge and retention apply again.
  --only PATTERN             With --restore: restore only targets whose original path contains PATTERN; the rest stay quarantined.
  --only-exact PATH          With --restore: match a literal original path from session inventory; excludes --only.
  --backup-conflicts         With --restore: move colliding non-symlink destinations to .pre-restore-<session> backups before restoring.
  --only-target PATTERN      With cleanup or --list-targets: select config targets whose NAME contains PATTERN.
  --only-target-exact NAME   With cleanup or --list-targets: select config targets whose NAME equals literal NAME.
  --exclude-target PATTERN   With cleanup or --list-targets: skip config targets whose NAME contains PATTERN.
  --exclude-target-exact NAME With cleanup or --list-targets: skip config targets whose NAME equals literal NAME.
  --only-path PATH           With cleanup or --list-targets: select ordinary targets at/below an existing absolute path; excludes action:* rows (env: LINUX_CLEANER_ONLY_PATH).
  --exclude-path PATH        With cleanup or --list-targets: skip targets at, below, or containing an existing absolute path (env: LINUX_CLEANER_EXCLUDE_PATH).
  --skip-actions             With cleanup or --list-targets: exclude all action:* targets (env: LINUX_CLEANER_SKIP_ACTIONS).
  --no-sudo                  With cleanup or --restore: never probe or invoke sudo; skip privileged paths/records cleanly (env: LINUX_CLEANER_NO_SUDO).
  --lock-wait SECONDS        With mutating runs: wait up to 0..2147483647 seconds for the lock (default: 0; env: LINUX_CLEANER_LOCK_WAIT).
  --min-reclaim SIZE         With cleanup: skip the run when the planned reclaim is below SIZE (e.g. 500M, 2G).
  --min-free SIZE            With cleanup: skip the run when the selected filesystem (default: HOME) has at least SIZE free (e.g. 10G).
  --min-free-path PATH       Measure PATH's filesystem for --min-free; requires an absolute existing path and --min-free.
  --min-age DAYS             With cleanup: raise every ordinary target's age threshold to at least DAYS days; skips action:* rows (env: LINUX_CLEANER_MIN_AGE).
  --action-timeout SECONDS   With cleanup: stop each action:* command after SECONDS seconds and count it failed (0: no limit; env: LINUX_CLEANER_ACTION_TIMEOUT).
  --trash-keep-days DAYS     With cleanup: purge quarantine sessions older than DAYS days after cleaning.
  --trash-max-size SIZE      With cleanup: purge oldest quarantine sessions beyond SIZE total after cleaning (env: LINUX_CLEANER_TRASH_MAX_SIZE).
  --purge-sessions SESSION   Permanently delete quarantine session(s) to reclaim space (latest, all, older-than:DAYS, max-size:SIZE, keep-latest:N, or timestamp); --dry-run previews. Irreversible.
  --allow-outside-home       Deprecated no-op; targets outside HOME are always allowed.
  --log [FILE]               Append an operation log (opt-in, off by default; kept under your HOME).
  --log-max-size SIZE        With --log: rotate the log to <log>.1 once it reaches SIZE bytes (0 disables; env: LINUX_CLEANER_LOG_MAX_SIZE).
  -q, --quiet                Suppress per-target status lines; keep errors, totals, and final summary.
  --debug                    Show per-target FOUND, CLEAN and PROTECTED lines (suppressed by default; overridden by --quiet).
  --show-matches             List eligible paths under each ordinary target in a text dry run (overridden by --quiet).
  --exit-code                Dry-run only: exit 2 if cleanup would run, 0 if it would skip (errors: 1).
  --notify                   With cleanup: send a desktop notification summarizing the result (no-op on dry-run; env: LINUX_CLEANER_NOTIFY).
  --fail-fast                With cleanup: stop after the first failed target and skip inline retention (env: LINUX_CLEANER_FAIL_FAST).
  --json                     Emit machine-readable JSON (--dry-run summary, --restore --dry-run preview, --purge-sessions --dry-run preview, --list-targets inventory, --list-sessions inventory, --report summary, --doctor checklist, or --check-config summary).
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
SKIP_ACTIONS=false
SKIP_ACTIONS_CLI=false
NO_SUDO=false
NO_SUDO_CLI=false
JSON_OUTPUT=false
TRASH_MODE=false
TRASH_CLI=false
MAX_RISK="safe"
EXCLUDE_PATTERNS=""
EXCLUDE_FROM=""
EXCLUDE_FROM_CLI=false
EXCLUDE_FROM_PATTERNS=()
TARGET_EXCLUDE_ACTIVE=false
RESTORE_TARGET=""
RESTORE_ONLY=""
RESTORE_ONLY_MODE="--only"
BACKUP_CONFLICTS=false
HOLD_TARGET=""
RELEASE_TARGET=""
ONLY_TARGET=""
ONLY_TARGET_EXACT=""
EXCLUDE_TARGET=""
EXCLUDE_TARGET_EXACT=""
ONLY_TARGET_CLI=false
ONLY_TARGET_EXACT_CLI=false
EXCLUDE_TARGET_CLI=false
EXCLUDE_TARGET_EXACT_CLI=false
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
TRASH_MAX_SIZE=""
LOCK_WAIT="${LINUX_CLEANER_LOCK_WAIT:-0}"
PURGE_TARGET=""
LIST_SESSIONS=false
LIST_TARGETS=false
CHECK_CONFIG=false
INIT_CONFIG=false
INIT_OVERLAY=false
INIT_ENV=false
DOCTOR=false
DOCTOR_STRICT=false
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
CLEANUP_METRICS_ARMED=false

# Operation log (opt-in, OFF by default). Enable via --log or by setting the
# LINUX_CLEANER_LOG environment variable. The log lives under $HOME (see the
# writer). When disabled, no log file is created or written.
LOG_ENABLED=false
LOG_FILE=""
if [[ -n "${LINUX_CLEANER_LOG:-}" ]]; then
  LOG_ENABLED=true
  LOG_FILE="$LINUX_CLEANER_LOG"
fi
LOG_MAX_SIZE="${LINUX_CLEANER_LOG_MAX_SIZE:-}"
LOG_MAX_SIZE_BYTES=0

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
case "${LINUX_CLEANER_SKIP_ACTIONS:-}" in
  1|true|TRUE|yes|YES) SKIP_ACTIONS=true ;;
esac
case "${LINUX_CLEANER_NO_SUDO:-}" in
  1|true|TRUE|yes|YES) NO_SUDO=true ;;
esac
case "${LINUX_CLEANER_JSON:-}" in
  1|true|TRUE|yes|YES) JSON_OUTPUT=true ;;
esac
if [[ -n "${LINUX_CLEANER_ONLY_TARGET:-}" ]]; then
  ONLY_TARGET="$LINUX_CLEANER_ONLY_TARGET"
fi
if [[ -n "${LINUX_CLEANER_ONLY_TARGET_EXACT:-}" ]]; then
  ONLY_TARGET_EXACT="$LINUX_CLEANER_ONLY_TARGET_EXACT"
fi
if [[ -n "${LINUX_CLEANER_EXCLUDE_TARGET:-}" ]]; then
  EXCLUDE_TARGET="$LINUX_CLEANER_EXCLUDE_TARGET"
fi
if [[ -n "${LINUX_CLEANER_EXCLUDE_TARGET_EXACT:-}" ]]; then
  EXCLUDE_TARGET_EXACT="$LINUX_CLEANER_EXCLUDE_TARGET_EXACT"
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
if [[ -n "${LINUX_CLEANER_TRASH_MAX_SIZE:-}" ]]; then
  TRASH_MAX_SIZE="$LINUX_CLEANER_TRASH_MAX_SIZE"
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
if [[ -n "${LINUX_CLEANER_EXCLUDE_FROM:-}" ]]; then
  EXCLUDE_FROM="$LINUX_CLEANER_EXCLUDE_FROM"
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

# Invoke notify-send (bounded to 5s when timeout(1) is available) without passing
# cleaner.lock fd 9 so spawned notification helpers cannot hold the lock after exit.
_send_desktop_notification() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 5 notify-send "$@" >/dev/null 2>&1 9>&- || true
  else
    notify-send "$@" >/dev/null 2>&1 9>&- || true
  fi
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
  if [[ -n "${RESTORE_TARGET:-}" || -n "${HOLD_TARGET:-}" || -n "${RELEASE_TARGET:-}" || "${LIST_SESSIONS:-false}" == true || "${LIST_TARGETS:-false}" == true || "${CHECK_CONFIG:-false}" == true || "${REPORT:-false}" == true || "${INIT_CONFIG:-false}" == true || "${INIT_ENV:-false}" == true || "${DOCTOR:-false}" == true ]]; then
    return "$status"
  fi
  # Scheduled previews (the monitor unit) and argument errors stop before any cleanup.
  if [[ "${DRY_RUN:-true}" != false ]]; then
    journal_error_line "Run stopped with exit status ${status} before cleaning."
    return "$status"
  fi
  if [[ "${CLEANUP_METRICS_ARMED:-false}" == true && "${CLEANUP_METRICS_WRITTEN:-false}" != true ]] && declare -F write_cleanup_metrics >/dev/null 2>&1; then
    OPERATION_FAILED=true
    write_cleanup_metrics || true
  fi
  journal_error_line "Cleanup stopped with exit status ${status} before finishing."
  if [[ "${NOTIFY:-false}" != true || "${NOTIFY_SENT:-false}" == true ]]; then
    return "$status"
  fi
  if command -v notify-send >/dev/null 2>&1; then
    local msg="Cleanup stopped with exit status ${status} before finishing; see journalctl --user -t linux-cleaner."
    _send_desktop_notification --app-name=linux-cleaner --urgency=critical "linux-cleaner" "$msg"
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
      FORCE=false
      DRY_RUN=false
      DRY_RUN_EXPLICIT=false
      shift
      ;;
    -f|--force)
      FORCE=true
      INTERACTIVE=false
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
    --skip-actions)
      SKIP_ACTIONS=true
      SKIP_ACTIONS_CLI=true
      shift
      ;;
    --no-sudo)
      NO_SUDO=true
      NO_SUDO_CLI=true
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
      TRASH_CLI=true
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
    --exclude-from)
      if [[ -z "${2:-}" ]]; then
        echo -e "${RED}Error: --exclude-from requires a file path argument.${NC}" >&2
        exit 1
      fi
      require_non_option_value "$1" "$2"
      EXCLUDE_FROM="$2"
      EXCLUDE_FROM_CLI=true
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
    --backup-conflicts)
      BACKUP_CONFLICTS=true
      shift
      ;;
    --only-target)
      if [[ -z "${2:-}" ]]; then
        echo -e "${RED}Error: --only-target requires a pattern argument.${NC}" >&2
        exit 1
      fi
      require_non_option_value "$1" "$2"
      if [[ "$ONLY_TARGET_EXACT_CLI" == true ]]; then
        echo -e "${RED}Error: --only-target and --only-target-exact cannot be combined.${NC}" >&2
        exit 1
      fi
      ONLY_TARGET_CLI=true
      ONLY_TARGET="$2"
      ONLY_TARGET_EXACT=""
      shift 2
      ;;
    --only-target-exact)
      if [[ -z "${2:-}" ]]; then
        echo -e "${RED}Error: --only-target-exact requires a target name argument.${NC}" >&2
        exit 1
      fi
      require_non_option_value "$1" "$2"
      if [[ "$ONLY_TARGET_CLI" == true ]]; then
        echo -e "${RED}Error: --only-target and --only-target-exact cannot be combined.${NC}" >&2
        exit 1
      fi
      ONLY_TARGET_EXACT_CLI=true
      ONLY_TARGET_EXACT="$2"
      ONLY_TARGET=""
      shift 2
      ;;
    --exclude-target)
      if [[ -z "${2:-}" ]]; then
        echo -e "${RED}Error: --exclude-target requires a pattern argument.${NC}" >&2
        exit 1
      fi
      require_non_option_value "$1" "$2"
      if [[ "$EXCLUDE_TARGET_EXACT_CLI" == true ]]; then
        echo -e "${RED}Error: --exclude-target and --exclude-target-exact cannot be combined.${NC}" >&2
        exit 1
      fi
      EXCLUDE_TARGET_CLI=true
      EXCLUDE_TARGET="$2"
      EXCLUDE_TARGET_EXACT=""
      shift 2
      ;;
    --exclude-target-exact)
      if [[ -z "${2:-}" ]]; then
        echo -e "${RED}Error: --exclude-target-exact requires a target name argument.${NC}" >&2
        exit 1
      fi
      require_non_option_value "$1" "$2"
      if [[ "$EXCLUDE_TARGET_CLI" == true ]]; then
        echo -e "${RED}Error: --exclude-target and --exclude-target-exact cannot be combined.${NC}" >&2
        exit 1
      fi
      EXCLUDE_TARGET_EXACT_CLI=true
      EXCLUDE_TARGET_EXACT="$2"
      EXCLUDE_TARGET=""
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
    --trash-max-size)
      if [[ -z "${2:-}" ]]; then
        echo -e "${RED}Error: --trash-max-size requires a size argument.${NC}" >&2
        exit 1
      fi
      require_non_option_value "$1" "$2"
      TRASH_MAX_SIZE="$2"
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
    --log-max-size)
      if [[ -z "${2:-}" ]]; then
        echo -e "${RED}Error: --log-max-size requires a size argument.${NC}" >&2
        exit 1
      fi
      require_non_option_value "$1" "$2"
      LOG_MAX_SIZE="$2"
      shift 2
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
    --overlay)
      INIT_OVERLAY=true
      shift
      ;;
    --init-env)
      INIT_ENV=true
      shift
      ;;
    --doctor)
      DOCTOR=true
      shift
      ;;
    --strict)
      DOCTOR_STRICT=true
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

is_valid_lock_wait() {
  local val="$1"
  [[ "$val" =~ ^[0123456789]+$ ]] || return 1
  val=${val#"${val%%[!0]*}"}
  val=${val:-0}
  # Decimal text fits in signed 64-bit once length <= 10.
  [[ ${#val} -le 10 ]] && (( 10#$val <= 2147483647 ))
}

# Validate only the effective value, so CLI can replace malformed inherited input.
if ! is_valid_lock_wait "$LOCK_WAIT"; then
  echo "Error: --lock-wait must be an integer from 0 to 2147483647 seconds." >&2
  exit 1
fi
LOCK_WAIT=${LOCK_WAIT#"${LOCK_WAIT%%[!0]*}"}
LOCK_WAIT=${LOCK_WAIT:-0}

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
elif [[ "$HOME" != /* ]]; then
  echo -e "${RED}Error: HOME must be an absolute path; refusing to run without a valid home-directory boundary.${NC}" >&2
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
  num="${num#"${num%%[!0]*}"}"
  [[ -z "$num" ]] && num=0
  # Refuse values whose byte count would overflow 64-bit shell arithmetic.
  if [[ ${#num} -gt 18 ]] \
     || (( num > 9223372036854775807 / mult )); then
    return 2
  fi
  printf '%s\n' "$((num * mult))"
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

if [[ -n "$TRASH_MAX_SIZE" ]]; then
  trash_max_size_rc=0
  parse_size_bytes "$TRASH_MAX_SIZE" >/dev/null || trash_max_size_rc=$?
  if [[ "$trash_max_size_rc" -eq 1 ]]; then
    echo -e "${RED}Error: --trash-max-size expects a size such as 500M or 10G, got '${TRASH_MAX_SIZE}'.${NC}" >&2
    exit 1
  elif [[ "$trash_max_size_rc" -ne 0 ]]; then
    echo -e "${RED}Error: --trash-max-size '${TRASH_MAX_SIZE}' is too large.${NC}" >&2
    exit 1
  fi
fi

if [[ -n "$LOG_MAX_SIZE" ]]; then
  if [[ "$LOG_ENABLED" != true ]]; then
    echo -e "${RED}Error: --log-max-size requires --log or LINUX_CLEANER_LOG.${NC}" >&2
    exit 1
  fi
  log_max_size_rc=0
  LOG_MAX_SIZE_BYTES=$(parse_size_bytes "$LOG_MAX_SIZE") || log_max_size_rc=$?
  if [[ "$log_max_size_rc" -eq 1 ]]; then
    echo -e "${RED}Error: --log-max-size expects a size such as 1M or 10M (0 disables rotation), got '${LOG_MAX_SIZE}'.${NC}" >&2
    exit 1
  elif [[ "$log_max_size_rc" -ne 0 ]]; then
    echo -e "${RED}Error: --log-max-size '${LOG_MAX_SIZE}' is too large.${NC}" >&2
    exit 1
  fi
fi

# A hold only flips one session's marker: refuse every other mode, filter, preview,
# or JSON request so nobody believes it also cleaned, restored, or narrowed something.
if [[ -n "$HOLD_TARGET" || -n "$RELEASE_TARGET" ]]; then
  hold_flag=--hold-session hold_other=--release-session
  [[ -n "$HOLD_TARGET" ]] || { hold_flag=--release-session; hold_other=--hold-session; }
  if [[ ( -n "$HOLD_TARGET" && -n "$RELEASE_TARGET" ) || -n "$RESTORE_TARGET" || -n "$PURGE_TARGET" || "$LIST_SESSIONS" == true || "$LIST_TARGETS" == true || "$CHECK_CONFIG" == true || "$REPORT" == true || "$INIT_CONFIG" == true || "$INIT_ENV" == true || "$DOCTOR" == true \
        || "$EXCLUDE_FROM_CLI" == true || "$SKIP_ACTIONS_CLI" == true || "$NO_SUDO_CLI" == true || -n "$ONLY_TARGET" || -n "$ONLY_TARGET_EXACT" || -n "$EXCLUDE_TARGET" || -n "$EXCLUDE_TARGET_EXACT" || -n "$ONLY_PATH" || -n "$EXCLUDE_PATH" || -n "$MIN_RECLAIM" || -n "$MIN_FREE" || -n "$MIN_FREE_PATH" || -n "$MIN_AGE_OVERRIDE" || -n "$ACTION_TIMEOUT" || -n "$TRASH_KEEP_DAYS" || -n "$TRASH_MAX_SIZE" \
        || "$NOTIFY_CLI" == true || "$FAIL_FAST_CLI" == true || "$SHOW_MATCHES" == true || "$EXIT_CODE" == true || "$DRY_RUN_EXPLICIT" == true || "$CLEAN_EXPLICIT" == true || "$INTERACTIVE" == true || "$JSON_OUTPUT" == true ]]; then
    echo -e "${RED}Error: ${hold_flag} cannot be combined with ${hold_other}, --restore, --purge-sessions, --list-sessions, --list-targets, --check-config, --report, --check-health, --init-config, --init-env, --doctor, --exclude-from, --skip-actions, --no-sudo, --only-target, --only-target-exact, --exclude-target, --exclude-target-exact, --only-path, --exclude-path, --min-reclaim, --min-free, --min-free-path, --min-age, --action-timeout, --trash-keep-days, --trash-max-size, --notify, --fail-fast, --show-matches, --exit-code, --dry-run, --clean, --interactive, or --json.${NC}" >&2
    exit 1
  fi
fi

# Exit status signaling is only meaningful for a cleanup preview.
if [[ "$EXIT_CODE" == true && ( "$DRY_RUN" != true || "$CLEAN_EXPLICIT" == true || "$FORCE" == true || "$INTERACTIVE" == true || -n "$RESTORE_TARGET" || -n "$PURGE_TARGET" || "$LIST_SESSIONS" == true || "$LIST_TARGETS" == true || "$CHECK_CONFIG" == true || "$REPORT" == true || "$INIT_CONFIG" == true || "$INIT_ENV" == true || "$DOCTOR" == true ) ]]; then
  echo -e "${RED}Error: --exit-code cannot be combined with --clean, --force, --interactive, --restore, --purge-sessions, --list-sessions, --hold-session, --release-session, --list-targets, --check-config, --report, --check-health, --init-config, --init-env, or --doctor.${NC}" >&2
  exit 1
fi

# Match listings are only meaningful for a text cleanup preview.
if [[ "$SHOW_MATCHES" == true && ( "$DRY_RUN" != true || "$CLEAN_EXPLICIT" == true || "$FORCE" == true || "$INTERACTIVE" == true || "$JSON_OUTPUT" == true || -n "$RESTORE_TARGET" || -n "$PURGE_TARGET" || "$LIST_SESSIONS" == true || "$LIST_TARGETS" == true || "$CHECK_CONFIG" == true || "$REPORT" == true || "$INIT_CONFIG" == true || "$INIT_ENV" == true || "$DOCTOR" == true ) ]]; then
  echo -e "${RED}Error: --show-matches cannot be combined with --clean, --force, --interactive, --json, --restore, --purge-sessions, --list-sessions, --list-targets, --check-config, --report, --check-health, --init-config, --init-env, or --doctor.${NC}" >&2
  exit 1
fi

# Restore selectors only mean anything as filters on --restore; ignoring one would
# let a user believe a cleanup or purge was narrowed when it was not.
if [[ -n "$RESTORE_ONLY" && -z "$RESTORE_TARGET" ]]; then
  echo -e "${RED}Error: ${RESTORE_ONLY_MODE} requires --restore (it filters which quarantined targets are restored).${NC}" >&2
  exit 1
fi
if [[ "$BACKUP_CONFLICTS" == true && -z "$RESTORE_TARGET" ]]; then
  echo -e "${RED}Error: --backup-conflicts requires --restore (it backs up colliding restore destinations).${NC}" >&2
  exit 1
fi

if [[ "$INIT_OVERLAY" == true && "$INIT_CONFIG" != true ]]; then
  echo -e "${RED}Error: --overlay requires --init-config.${NC}" >&2
  exit 1
fi

if [[ "$DOCTOR_STRICT" == true && "$DOCTOR" != true ]]; then
  echo -e "${RED}Error: --strict applies only to --doctor.${NC}" >&2
  exit 1
fi

if [[ -n "$ONLY_TARGET" && -n "$ONLY_TARGET_EXACT" ]]; then
  echo -e "${RED}Error: --only-target and --only-target-exact cannot be combined.${NC}" >&2
  exit 1
fi

if [[ -n "$EXCLUDE_TARGET" && -n "$EXCLUDE_TARGET_EXACT" ]]; then
  echo -e "${RED}Error: --exclude-target and --exclude-target-exact cannot be combined.${NC}" >&2
  exit 1
fi

if [[ -n "$ONLY_TARGET" && ( -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" || "$LIST_SESSIONS" == true || "$CHECK_CONFIG" == true || "$REPORT" == true || "$INIT_CONFIG" == true || "$INIT_ENV" == true || "$DOCTOR" == true ) ]]; then
  echo -e "${RED}Error: --only-target applies only to cleanup runs or --list-targets (not --restore, --purge-sessions, --list-sessions, --check-config, --report, --check-health, --init-config, --init-env, or --doctor).${NC}" >&2
  exit 1
fi

if [[ -n "$ONLY_TARGET_EXACT" && ( -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" || "$LIST_SESSIONS" == true || "$CHECK_CONFIG" == true || "$REPORT" == true || "$INIT_CONFIG" == true || "$INIT_ENV" == true || "$DOCTOR" == true ) ]]; then
  echo -e "${RED}Error: --only-target-exact applies only to cleanup runs or --list-targets (not --restore, --purge-sessions, --list-sessions, --check-config, --report, --check-health, --init-config, --init-env, or --doctor).${NC}" >&2
  exit 1
fi

if [[ -n "$EXCLUDE_TARGET" && ( -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" || "$LIST_SESSIONS" == true || "$CHECK_CONFIG" == true || "$REPORT" == true || "$INIT_CONFIG" == true || "$INIT_ENV" == true || "$DOCTOR" == true ) ]]; then
  echo -e "${RED}Error: --exclude-target applies only to cleanup runs or --list-targets (not --restore, --purge-sessions, --list-sessions, --check-config, --report, --check-health, --init-config, --init-env, or --doctor).${NC}" >&2
  exit 1
fi

if [[ -n "$EXCLUDE_TARGET_EXACT" && ( -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" || "$LIST_SESSIONS" == true || "$CHECK_CONFIG" == true || "$REPORT" == true || "$INIT_CONFIG" == true || "$INIT_ENV" == true || "$DOCTOR" == true ) ]]; then
  echo -e "${RED}Error: --exclude-target-exact applies only to cleanup runs or --list-targets (not --restore, --purge-sessions, --list-sessions, --check-config, --report, --check-health, --init-config, --init-env, or --doctor).${NC}" >&2
  exit 1
fi

if [[ -n "$ONLY_PATH" && ( -n "$RESTORE_TARGET" || -n "$PURGE_TARGET" || "$LIST_SESSIONS" == true || "$CHECK_CONFIG" == true || "$REPORT" == true || "$INIT_CONFIG" == true || "$INIT_ENV" == true || "$DOCTOR" == true || -n "$TRASH_KEEP_DAYS" || -n "$TRASH_MAX_SIZE" ) ]]; then
  echo "Error: --only-path applies only to cleanup runs or --list-targets and cannot be combined with --trash-keep-days or --trash-max-size." >&2
  exit 1
fi

if [[ -n "$EXCLUDE_PATH" && ( -n "$RESTORE_TARGET" || -n "$PURGE_TARGET" || "$LIST_SESSIONS" == true || "$CHECK_CONFIG" == true || "$REPORT" == true || "$INIT_CONFIG" == true || "$INIT_ENV" == true || "$DOCTOR" == true ) ]]; then
  echo "Error: --exclude-path applies only to cleanup runs or --list-targets (not --restore, --purge-sessions, --list-sessions, --check-config, --report, --check-health, --init-config, --init-env, or --doctor)." >&2
  exit 1
fi

if [[ "$EXCLUDE_FROM_CLI" == true && ( -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" || "$LIST_SESSIONS" == true || "$LIST_TARGETS" == true || "$CHECK_CONFIG" == true || "$REPORT" == true || "$INIT_CONFIG" == true || "$INIT_ENV" == true || "$DOCTOR" == true ) ]]; then
  echo -e "${RED}Error: --exclude-from applies only to cleanup runs (not --restore, --purge-sessions, --list-sessions, --list-targets, --check-config, --report, --check-health, --init-config, --init-env, or --doctor).${NC}" >&2
  exit 1
fi

if [[ "$SKIP_ACTIONS_CLI" == true && ( -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" || "$LIST_SESSIONS" == true || "$CHECK_CONFIG" == true || "$REPORT" == true || "$INIT_CONFIG" == true || "$INIT_ENV" == true || "$DOCTOR" == true ) ]]; then
  echo -e "${RED}Error: --skip-actions applies only to cleanup runs or --list-targets (not --restore, --purge-sessions, --list-sessions, --check-config, --report, --check-health, --init-config, --init-env, or --doctor).${NC}" >&2
  exit 1
fi
if [[ "$NO_SUDO_CLI" == true && ( -n "${PURGE_TARGET:-}" || "$LIST_SESSIONS" == true || "$LIST_TARGETS" == true || "$CHECK_CONFIG" == true || "$REPORT" == true || "$INIT_CONFIG" == true || "$INIT_ENV" == true || "$DOCTOR" == true ) ]]; then
  echo -e "${RED}Error: --no-sudo applies only to cleanup runs or --restore (not --purge-sessions, --list-sessions, --hold-session, --release-session, --list-targets, --check-config, --report, --check-health, --init-config, --init-env, or --doctor).${NC}" >&2
  exit 1
fi

if [[ -n "$MIN_RECLAIM" && ( -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" || "$LIST_SESSIONS" == true || "$LIST_TARGETS" == true || "$CHECK_CONFIG" == true || "$REPORT" == true || "$INIT_CONFIG" == true || "$INIT_ENV" == true || "$DOCTOR" == true ) ]]; then
  echo -e "${RED}Error: --min-reclaim applies only to cleanup runs (not --restore, --purge-sessions, --list-sessions, --list-targets, --check-config, --report, --check-health, --init-config, --init-env, or --doctor).${NC}" >&2
  exit 1
fi

if [[ ( -n "$MIN_FREE" || -n "$MIN_FREE_PATH" ) && ( -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" || "$LIST_SESSIONS" == true || "$LIST_TARGETS" == true || "$CHECK_CONFIG" == true || "$REPORT" == true || "$INIT_CONFIG" == true || "$INIT_ENV" == true || "$DOCTOR" == true ) ]]; then
  min_free_flag=--min-free
  [[ -n "$MIN_FREE_PATH" ]] && min_free_flag=--min-free-path
  echo -e "${RED}Error: ${min_free_flag} applies only to cleanup runs (not --restore, --purge-sessions, --list-sessions, --list-targets, --check-config, --report, --check-health, --init-config, --init-env, or --doctor).${NC}" >&2
  exit 1
fi

if [[ -n "$MIN_AGE_OVERRIDE" && ( -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" || "$LIST_SESSIONS" == true || "$LIST_TARGETS" == true || "$CHECK_CONFIG" == true || "$REPORT" == true || "$INIT_CONFIG" == true || "$INIT_ENV" == true || "$DOCTOR" == true ) ]]; then
  echo -e "${RED}Error: --min-age applies only to cleanup runs (not --restore, --purge-sessions, --list-sessions, --list-targets, --check-config, --report, --check-health, --init-config, --init-env, or --doctor).${NC}" >&2
  exit 1
fi

if [[ -n "$ACTION_TIMEOUT" && ( -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" || "$LIST_SESSIONS" == true || "$LIST_TARGETS" == true || "$CHECK_CONFIG" == true || "$REPORT" == true || "$INIT_CONFIG" == true || "$INIT_ENV" == true || "$DOCTOR" == true ) ]]; then
  echo -e "${RED}Error: --action-timeout applies only to cleanup runs (not --restore, --purge-sessions, --list-sessions, --list-targets, --check-config, --report, --check-health, --init-config, --init-env, or --doctor).${NC}" >&2
  exit 1
fi

if [[ -n "$TRASH_KEEP_DAYS" && ( -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" || "$LIST_SESSIONS" == true || "$LIST_TARGETS" == true || "$CHECK_CONFIG" == true || "$REPORT" == true || "$INIT_CONFIG" == true || "$INIT_ENV" == true || "$DOCTOR" == true ) ]]; then
  echo -e "${RED}Error: --trash-keep-days applies only to cleanup runs (not --restore, --purge-sessions, --list-sessions, --list-targets, --check-config, --report, --check-health, --init-config, --init-env, or --doctor).${NC}" >&2
  exit 1
fi

if [[ -n "$TRASH_MAX_SIZE" && ( -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" || "$LIST_SESSIONS" == true || "$LIST_TARGETS" == true || "$CHECK_CONFIG" == true || "$REPORT" == true || "$INIT_CONFIG" == true || "$INIT_ENV" == true || "$DOCTOR" == true ) ]]; then
  echo -e "${RED}Error: --trash-max-size applies only to cleanup runs (not --restore, --purge-sessions, --list-sessions, --list-targets, --check-config, --report, --check-health, --init-config, --init-env, or --doctor).${NC}" >&2
  exit 1
fi

if [[ "$NOTIFY_CLI" == true && ( -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" || "$LIST_SESSIONS" == true || "$LIST_TARGETS" == true || "$CHECK_CONFIG" == true || "$REPORT" == true || "$INIT_CONFIG" == true || "$INIT_ENV" == true || "$DOCTOR" == true ) ]]; then
  echo -e "${RED}Error: --notify applies only to cleanup runs (not --restore, --purge-sessions, --list-sessions, --list-targets, --check-config, --report, --check-health, --init-config, --init-env, or --doctor).${NC}" >&2
  exit 1
fi

if [[ "$FAIL_FAST_CLI" == true && ( -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" || "$LIST_SESSIONS" == true || "$LIST_TARGETS" == true || "$CHECK_CONFIG" == true || "$REPORT" == true || "$INIT_CONFIG" == true || "$INIT_ENV" == true || "$DOCTOR" == true ) ]]; then
  echo -e "${RED}Error: --fail-fast applies only to cleanup runs (not --restore, --purge-sessions, --list-sessions, --list-targets, --check-config, --report, --check-health, --init-config, --init-env, or --doctor).${NC}" >&2
  exit 1
fi

if [[ "$LIST_TARGETS" == true && ( -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" || "$LIST_SESSIONS" == true || "$REPORT" == true || "$INIT_CONFIG" == true || "$INIT_ENV" == true || "$DOCTOR" == true ) ]]; then
  echo -e "${RED}Error: --list-targets cannot be combined with --restore, --purge-sessions, --list-sessions, --report, --check-health, --init-config, --init-env, or --doctor.${NC}" >&2
  exit 1
fi

if [[ "$CHECK_CONFIG" == true && ( -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" || "$LIST_SESSIONS" == true || "$LIST_TARGETS" == true || "$REPORT" == true || "$INIT_CONFIG" == true || "$INIT_ENV" == true || "$DOCTOR" == true ) ]]; then
  echo -e "${RED}Error: --check-config cannot be combined with --restore, --purge-sessions, --list-sessions, --list-targets, --report, --check-health, --init-config, --init-env, or --doctor.${NC}" >&2
  exit 1
fi

if [[ "$REPORT" == true && ( -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" || "$LIST_SESSIONS" == true || "$LIST_TARGETS" == true || "$CHECK_CONFIG" == true || "$INIT_CONFIG" == true || "$INIT_ENV" == true || "$DOCTOR" == true ) ]]; then
  echo -e "${RED}Error: --report cannot be combined with --restore, --purge-sessions, --list-sessions, --list-targets, --check-config, --init-config, --init-env, or --doctor.${NC}" >&2
  exit 1
fi

if [[ "$INIT_CONFIG" == true && ( -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" || "$LIST_SESSIONS" == true || "$LIST_TARGETS" == true || "$CHECK_CONFIG" == true || "$REPORT" == true || "$INIT_ENV" == true || "$DOCTOR" == true ) ]]; then
  echo -e "${RED}Error: --init-config cannot be combined with --restore, --purge-sessions, --list-sessions, --list-targets, --check-config, --report, --check-health, --init-env, or --doctor.${NC}" >&2
  exit 1
fi

if [[ "$INIT_ENV" == true && ( -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" || "$LIST_SESSIONS" == true || "$LIST_TARGETS" == true || "$CHECK_CONFIG" == true || "$REPORT" == true || "$INIT_CONFIG" == true || "$DOCTOR" == true ) ]]; then
  echo -e "${RED}Error: --init-env cannot be combined with --restore, --purge-sessions, --list-sessions, --list-targets, --check-config, --report, --check-health, --init-config, or --doctor.${NC}" >&2
  exit 1
fi

if [[ "$DOCTOR" == true && ( -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" || "$LIST_SESSIONS" == true || "$LIST_TARGETS" == true || "$CHECK_CONFIG" == true || "$REPORT" == true || "$INIT_CONFIG" == true || "$INIT_ENV" == true ) ]]; then
  echo -e "${RED}Error: --doctor cannot be combined with --restore, --purge-sessions, --list-sessions, --list-targets, --check-config, --report, --check-health, --init-config, or --init-env.${NC}" >&2
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
      ( ( -n "$RESTORE_TARGET" || -n "$PURGE_TARGET" ) && "$DRY_RUN_EXPLICIT" != true ) || "$INIT_CONFIG" == true || "$INIT_ENV" == true || \
      ( "$DRY_RUN" != true && "$LIST_TARGETS" != true && "$LIST_SESSIONS" != true && "$REPORT" != true && "$DOCTOR" != true && "$CHECK_CONFIG" != true ) \
    ) ]]; then
  echo -e "${RED}Error: --json is valid only with --dry-run (cleanup, --restore, or --purge-sessions preview), --list-targets, --list-sessions, --report, --doctor, or --check-config.${NC}" >&2
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

# Trim whitespace from variables
trim() {
  local var="$*"
  # remove leading whitespace
  var="${var#"${var%%[![:space:]]*}"}"
  # remove trailing whitespace
  var="${var%"${var##*[![:space:]]}"}"
  printf '%s' "$var"
}

trim_to() {
  local trimmed="$2"
  if [[ "$trimmed" == [[:space:]]* ]]; then
    trimmed="${trimmed#"${trimmed%%[![:space:]]*}"}"
  fi
  if [[ "$trimmed" == *[[:space:]] ]]; then
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
  fi
  printf -v "$1" '%s' "$trimmed"
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
  local _eps_raw="$1"
  local _eps_expanded="$_eps_raw" _eps_name _eps_value _eps_default
  [[ "$_eps_raw" != *$'\n'* ]] || return 1

  # Safe leading ~ expansion
  # shellcheck disable=SC2088
  if [[ "$_eps_expanded" == "~" ]]; then
    _eps_expanded="$HOME"
  elif [[ "$_eps_expanded" == "~/"* ]]; then
    _eps_expanded="$HOME/${_eps_expanded:2}"
  fi

  # Replace $HOME, $USER, and the four XDG base-directory variables only as
  # whole tokens (so $HOMEDATA / $USERNAME / $XDG_CACHE_HOMEX stay literal,
  # matching the documented "explicit placeholders only" contract).
  for _eps_name in HOME USER XDG_CACHE_HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME; do
    [[ "$_eps_expanded" == *"\$$_eps_name"* ]] || continue
    case "$_eps_name" in
      HOME|USER) _eps_value="${!_eps_name:-}" ;;
      *)
        case "$_eps_name" in
          XDG_CACHE_HOME) _eps_default="${HOME:-}/.cache" ;;
          XDG_CONFIG_HOME) _eps_default="${HOME:-}/.config" ;;
          XDG_DATA_HOME) _eps_default="${HOME:-}/.local/share" ;;
          XDG_STATE_HOME) _eps_default="${HOME:-}/.local/state" ;;
        esac
        _eps_value=$(_xdg_dir "$_eps_name" "$_eps_default" && printf '.') || return 1
        _eps_value=${_eps_value%.}
        ;;
    esac
    # Helpers emit no delimiter; remove only the capture sentinel, preserving LF.
    _eps_expanded=$(_expand_var_token "$_eps_expanded" "$_eps_name" "$_eps_value" && printf '.') || return 1
    _eps_expanded=${_eps_expanded%.}
  done

  [[ "$_eps_expanded" != *$'\n'* ]] || return 1
  if [[ "$#" -gt 1 ]]; then
    printf -v "$2" '%s' "$_eps_expanded"
  else
    printf '%s' "$_eps_expanded"
  fi
}

# Verify parent/destination paths have no symlinks and do not overwrite existing files.
_check_user_file_dest() {
  local parent="$1" dest_dir="$2" dest="$3" label="$4" init_kind="$5"
  if [[ -L "$parent" ]]; then
    echo -e "${RED}Error: Refusing to initialize ${init_kind}; parent directory '$parent' is a symlink.${NC}" >&2
    return 1
  fi
  if [[ -L "$dest_dir" ]]; then
    echo -e "${RED}Error: Refusing to initialize ${init_kind}; directory '$dest_dir' is a symlink.${NC}" >&2
    return 1
  fi
  if [[ -e "$dest" || -L "$dest" ]]; then
    echo -e "${RED}Error: ${label} already exists at '$dest'; refusing to overwrite.${NC}" >&2
    return 1
  fi
}

# Create DEST_DIR safely with 0700 umask and re-verify it is a real directory.
_prepare_user_file_dir() {
  local parent="$1" dest_dir="$2" init_kind="$3"
  if ! (umask 077; mkdir -p -- "$dest_dir"); then
    echo -e "${RED}Error: Failed to create user config directory '$dest_dir'.${NC}" >&2
    return 1
  fi
  if [[ -L "$parent" || -L "$dest_dir" || ! -d "$dest_dir" ]]; then
    echo -e "${RED}Error: Refusing to initialize ${init_kind}; '$dest_dir' is not a real directory.${NC}" >&2
    return 1
  fi
}

# Publish a staged temporary file TMP to DEST atomically with mode 0644 and no-overwrite semantics.
_publish_staged_user_file() {
  local tmp="$1" dest="$2" label="$3"
  if ! chmod 0644 "$tmp"; then
    rm -f -- "$tmp" || true
    echo -e "${RED}Error: Failed to set permissions on '$tmp'.${NC}" >&2
    return 1
  fi
  if [[ -e "$dest" || -L "$dest" ]]; then
    rm -f -- "$tmp" || true
    echo -e "${RED}Error: ${label} already exists at '$dest'; refusing to overwrite.${NC}" >&2
    return 1
  fi
  if ! mv -n -T -- "$tmp" "$dest"; then
    rm -f -- "$tmp" || true
    echo -e "${RED}Error: Failed to move '$tmp' to '$dest'.${NC}" >&2
    return 1
  fi
  if [[ -e "$tmp" || -L "$tmp" ]]; then
    rm -f -- "$tmp" || true
    echo -e "${RED}Error: ${label} already exists at '$dest'; refusing to overwrite.${NC}" >&2
    return 1
  fi
}

# Copy the active configuration file (or write a thin include| overlay) to the user config path without overwriting.
init_user_config() {
  local xdg_parent dest_dir dest src="" candidate tmp inc_src="" inc_trimmed="" inc_exp=""
  xdg_parent=$(_xdg_dir XDG_CONFIG_HOME "$HOME/.config" && printf '.') || return 1
  xdg_parent=${xdg_parent%.}
  dest_dir="$xdg_parent/linux-cleaner"
  dest="$dest_dir/cleaner.conf"

  _check_user_file_dest "$xdg_parent" "$dest_dir" "$dest" "User config" "config" || return 1

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
  if [[ ! -r "$src" ]]; then
    echo -e "${RED}Error: Configuration file '$src' is not readable.${NC}" >&2
    return 1
  fi

  if [[ "$INIT_OVERLAY" == true ]]; then
    inc_src=$(realpath -e -- "$src" 2>/dev/null && printf '.') || {
      echo -e "${RED}Error: Could not resolve source configuration file '$src'.${NC}" >&2
      return 1
    }
    inc_src=${inc_src%.}
    inc_src=${inc_src%$'\n'}
    trim_to inc_trimmed "$inc_src"
    if [[ -z "$inc_src" || "$inc_src" != /* || "$inc_src" != "$inc_trimmed" || "$inc_src" == *'|'* || "$inc_src" == *$'\n'* || "$inc_src" == *$'\r'* || "$inc_src" == *[*?\[]* ]] \
       || ! expand_path_safe "$inc_src" inc_exp || [[ "$inc_exp" != "$inc_src" ]]; then
      echo -e "${RED}Error: Source configuration path '$src' cannot be represented safely in an include directive.${NC}" >&2
      return 1
    fi
  fi

  _prepare_user_file_dir "$xdg_parent" "$dest_dir" "config" || return 1

  tmp="$dest.tmp.$$"
  if [[ "$INIT_OVERLAY" == true ]]; then
    if ! printf '%s\n' \
      "# User overlay configuration for linux-cleaner" \
      "# Inherits upstream targets from the included config; add protect| or custom rows below." \
      "# Validate edits with: cleaner --check-config" \
      "include|${inc_src}" \
      "" \
      "# Example: protect a directory from cleanup rules" \
      "# protect|\$HOME/Projects" \
      "" \
      "# Example: add a custom cleanup target" \
      "# safe|My App Cache|\$HOME/.cache/my-app|Application cache files|7||" \
      > "$tmp"; then
      rm -f -- "$tmp" || true
      echo -e "${RED}Error: Failed to write overlay config to '$tmp'.${NC}" >&2
      return 1
    fi
  else
    if ! cp -- "$src" "$tmp"; then
      rm -f -- "$tmp" || true
      echo -e "${RED}Error: Failed to copy '$src' to '$tmp'.${NC}" >&2
      return 1
    fi
  fi

  _publish_staged_user_file "$tmp" "$dest" "User config" || return 1

  if [[ "$INIT_OVERLAY" == true ]]; then
    echo "Created $dest layering over $inc_src; edit it, then check with: cleaner --check-config && cleaner --dry-run"
  else
    echo "Created $dest from $src; edit it, then preview with: cleaner --dry-run"
  fi
  return 0
}

if [[ "$INIT_CONFIG" == true ]]; then
  init_user_config
  exit $?
fi

# Copy the shipped systemd timer environment template to ~/.config/linux-cleaner/env without overwriting.
init_timer_env() {
  local dest_parent dest_dir dest src="" candidate tmp
  dest_parent="${HOME%/}/.config"
  dest_dir="$dest_parent/linux-cleaner"
  dest="$dest_dir/env"

  _check_user_file_dest "$dest_parent" "$dest_dir" "$dest" "Timer env file" "timer env" || return 1

  for candidate in \
    "$SCRIPT_DIR/examples/linux-cleaner.env.example" \
    "$SCRIPT_DIR/../share/linux-cleaner/linux-cleaner.env.example" \
    "/usr/local/share/linux-cleaner/linux-cleaner.env.example" \
    "/usr/share/linux-cleaner/linux-cleaner.env.example"; do
    if [[ -f "$candidate" && ! -L "$candidate" && -r "$candidate" ]]; then
      src="$candidate"
      break
    fi
  done

  if [[ -z "$src" ]]; then
    echo -e "${RED}Error: No timer environment template (linux-cleaner.env.example) found to copy.${NC}" >&2
    return 1
  fi

  local src_real
  if src_real=$(realpath -e -- "$src" 2>/dev/null && printf '.'); then
    src="${src_real%.}"
    src="${src%$'\n'}"
  fi

  _prepare_user_file_dir "$dest_parent" "$dest_dir" "timer env" || return 1

  tmp="$dest.tmp.$$"
  if ! cp -- "$src" "$tmp"; then
    rm -f -- "$tmp" || true
    echo -e "${RED}Error: Failed to copy '$src' to '$tmp'.${NC}" >&2
    return 1
  fi

  if [[ "$TRASH_CLI" == true ]]; then
    local tmp_trash rc=0
    tmp_trash="$dest.tmp-trash.$$"
    LC_ALL=C awk '
      BEGIN { seen_trash = 0; seen_keep = 0; conflict = 0 }
      {
        if ($0 ~ /^[[:blank:]]*LINUX_CLEANER_TRASH=(1|true|TRUE|yes|YES)[[:blank:]]*$/) {
          if (seen_trash) { conflict = 1 }
          seen_trash = 1
          print
          next
        }
        if ($0 ~ /^[[:blank:]]*LINUX_CLEANER_TRASH=/) {
          conflict = 1
        }
        if ($0 ~ /^[[:blank:]]*LINUX_CLEANER_TRASH_KEEP_DAYS=[0123456789]+[[:blank:]]*$/) {
          if (seen_keep) { conflict = 1 }
          seen_keep = 1
          print
          next
        }
        if ($0 ~ /^[[:blank:]]*LINUX_CLEANER_TRASH_KEEP_DAYS=/) {
          conflict = 1
        }
        if (!seen_trash && $0 ~ /^#[[:blank:]]*LINUX_CLEANER_TRASH=1[[:blank:]]*$/) {
          print "LINUX_CLEANER_TRASH=1"
          seen_trash = 1
          next
        }
        if (!seen_keep && $0 ~ /^#[[:blank:]]*LINUX_CLEANER_TRASH_KEEP_DAYS=30[[:blank:]]*$/) {
          print "LINUX_CLEANER_TRASH_KEEP_DAYS=30"
          seen_keep = 1
          next
        }
        print
      }
      END {
        if (conflict) { exit 2 }
        if (!seen_trash) { print "LINUX_CLEANER_TRASH=1" }
        if (!seen_keep) { print "LINUX_CLEANER_TRASH_KEEP_DAYS=30" }
      }
    ' "$tmp" > "$tmp_trash" || rc=$?
    if [[ "$rc" -ne 0 ]] || ! mv -f -- "$tmp_trash" "$tmp"; then
      rm -f -- "$tmp" "$tmp_trash" || true
      if [[ "$rc" -eq 2 ]]; then
        echo -e "${RED}Error: Timer environment template '$src' has conflicting LINUX_CLEANER_TRASH or LINUX_CLEANER_TRASH_KEEP_DAYS settings.${NC}" >&2
      else
        echo -e "${RED}Error: Failed to enable quarantine settings in '$tmp'.${NC}" >&2
      fi
      return 1
    fi
    if ! LC_ALL=C grep -qxE '^[[:blank:]]*LINUX_CLEANER_TRASH=(1|true|TRUE|yes|YES)[[:blank:]]*$' "$tmp" \
       || ! LC_ALL=C grep -qxE '^[[:blank:]]*LINUX_CLEANER_TRASH_KEEP_DAYS=[0123456789]+[[:blank:]]*$' "$tmp"; then
      rm -f -- "$tmp" || true
      echo -e "${RED}Error: Staged timer environment file failed quarantine verification.${NC}" >&2
      return 1
    fi
  fi

  _publish_staged_user_file "$tmp" "$dest" "Timer env file" || return 1

  if [[ "$TRASH_CLI" == true ]]; then
    echo "Created $dest from $src with quarantine enabled (LINUX_CLEANER_TRASH=1, LINUX_CLEANER_TRASH_KEEP_DAYS=30); check with: cleaner --doctor"
  else
    echo "Created $dest from $src; edit it (for example set LINUX_CLEANER_TRASH=1 and LINUX_CLEANER_TRASH_KEEP_DAYS=30), then check with: cleaner --doctor"
  fi
  return 0
}

if [[ "$INIT_ENV" == true ]]; then
  init_timer_env
  exit $?
fi

CHECK_CONFIG_PRE_STATUS=""
CHECK_CONFIG_PRE_ERROR=""
CHECK_CONFIG_SEARCHED=()
# Check if config file exists (only if not restoring, purging, or listing sessions)
if [[ -z "${RESTORE_TARGET:-}" && -z "${PURGE_TARGET:-}" && -z "$HOLD_TARGET" && -z "$RELEASE_TARGET" && "$LIST_SESSIONS" != true && "$REPORT" != true && "$DOCTOR" != true && "$INIT_ENV" != true ]]; then
  # Resolve the default config by search order when -c/--config was not given.
  CONFIG_CANDIDATES=()
  [[ -n "$CONFIG_FILE" ]] && CONFIG_EXPLICIT=true
  if [[ -z "$CONFIG_FILE" ]]; then
    set_default_config_candidates || exit 1
    for candidate in "${CONFIG_CANDIDATES[@]}"; do
      CHECK_CONFIG_SEARCHED+=("$candidate")
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
    if [[ "$CHECK_CONFIG" == true && "$JSON_OUTPUT" == true ]]; then
      CHECK_CONFIG_PRE_STATUS="not_found"
      CHECK_CONFIG_PRE_ERROR="Configuration file not found at '$CONFIG_FILE'"
    else
      echo -e "${RED}Error: Configuration file not found at '$CONFIG_FILE'${NC}" >&2
      if [[ ${#CONFIG_CANDIDATES[@]} -gt 0 ]]; then
        printf '  searched: %s\n' "${CONFIG_CANDIDATES[@]}" >&2
        echo "Run 'cleaner --doctor' to check the environment." >&2
      fi
      exit 1
    fi
  elif [[ ! -r "$CONFIG_FILE" ]]; then
    if [[ "$CHECK_CONFIG" == true && "$JSON_OUTPUT" == true ]]; then
      CHECK_CONFIG_PRE_STATUS="not_readable"
      CHECK_CONFIG_PRE_ERROR="Configuration file '$CONFIG_FILE' is not readable"
    else
      echo -e "${RED}Error: Configuration file '$CONFIG_FILE' is not readable${NC}" >&2
      exit 1
    fi
  fi
fi

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
    trim_to pat "${rest%%,*}"
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
action_filter_kept=false
SELECTED_TARGET_PATH=""

target_name_included() {
  local name="$1"
  if [[ -n "$ONLY_TARGET" ]]; then
    name_matches_any "$name" "${ONLY_TARGET_PATTERNS[@]}" || return 1
  elif [[ -n "$ONLY_TARGET_EXACT" ]]; then
    [[ "$name" == "$ONLY_TARGET_EXACT" ]] || return 1
  fi
  return 0
}

target_name_excluded() {
  local name="$1"
  if [[ -n "$EXCLUDE_TARGET" ]] && name_matches_any "$name" "${EXCLUDE_TARGET_PATTERNS[@]}"; then
    return 0
  fi
  if [[ -n "$EXCLUDE_TARGET_EXACT" && "$name" == "$EXCLUDE_TARGET_EXACT" ]]; then
    return 0
  fi
  return 1
}

select_target_name() {
  local name="$1"
  if [[ -n "$ONLY_TARGET" || -n "$ONLY_TARGET_EXACT" ]]; then
    target_name_included "$name" || return 1
    only_target_matched=true
  fi
  if target_name_excluded "$name"; then
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

select_target_action() {
  if [[ "$SKIP_ACTIONS" == true ]]; then
    [[ "$1" == action:* ]] && return 1
    action_filter_kept=true
  fi
  return 0
}

check_target_selection() {
  if [[ -n "$ONLY_TARGET" && "$only_target_matched" != true ]]; then
    echo -e "${RED}Error: No config target NAME matches '--only-target ${ONLY_TARGET}'.${NC}" >&2
    return 1
  fi
  if [[ -n "$ONLY_TARGET_EXACT" && "$only_target_matched" != true ]]; then
    echo -e "${RED}Error: No config target NAME matches '--only-target-exact ${ONLY_TARGET_EXACT}'.${NC}" >&2
    return 1
  fi
  if [[ -n "$EXCLUDE_TARGET" && "$name_filter_kept" != true ]]; then
    echo -e "${RED}Error: --exclude-target ${EXCLUDE_TARGET} left no config targets to process.${NC}" >&2
    return 1
  fi
  if [[ -n "$EXCLUDE_TARGET_EXACT" && "$name_filter_kept" != true ]]; then
    echo -e "${RED}Error: --exclude-target-exact ${EXCLUDE_TARGET_EXACT} left no config targets to process.${NC}" >&2
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
  if [[ "$SKIP_ACTIONS" == true && "$action_filter_kept" != true ]]; then
    echo "Error: --skip-actions left no config targets to process." >&2
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
  if [[ "$s" == *[\\\"[:cntrl:]]* ]]; then
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\b'/\\b}
    s=${s//$'\f'/\\f}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}

    if [[ "$s" == *[[:cntrl:]]* ]]; then
      # Bash strings cannot contain NUL; encode every other representable C0 byte.
      for ((code = 1; code < 32; code++)); do
        case "$code" in 8|9|10|12|13) continue ;; esac
        printf -v octal '%03o' "$code"
        printf -v control '%b' "\\$octal"
        printf -v escaped '\\u%04x' "$code"
        s=${s//"$control"/"$escaped"}
      done
    fi
  fi
  if [[ "$#" -gt 1 ]]; then
    printf -v "$2" '%s' "$s"
  else
    printf '%s' "$s"
  fi
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

  if [[ "${_CFG_VALIDATED:-false}" == true && "${_CFG_VALIDATED_CONFIG:-}" == "$CONFIG_FILE" && "${_CFG_HAS_EXPANDABLE:-false}" != true ]]; then
    for i in "${!CFG_TGT_NAMES[@]}"; do
      name="${CFG_TGT_NAMES[$i]}"
      select_target_name "$name" || continue
      raw_path="${CFG_TGT_PATHS[$i]}"
      custom_clean_cmd="${CFG_TGT_ACTIONS[$i]}"
      select_target_path "$raw_path" "$custom_clean_cmd" || continue
      select_target_action "$custom_clean_cmd" || continue
      lt_names+=("$name")
      lt_risks+=("${CFG_TGT_RISKS[$i]}")
      lt_paths+=("$raw_path")
      lt_descs+=("${CFG_TGT_DESCS[$i]}")
      lt_min_ages+=("${CFG_TGT_MIN_AGES[$i]}")
      lt_procs+=("${CFG_TGT_PROCS[$i]}")
      lt_actions+=("$custom_clean_cmd")
    done
  else
    if [[ "${_CFG_REC_LOADED:-false}" != true || "${_CFG_REC_LOADED_CONFIG:-}" != "$CONFIG_FILE" ]]; then
      load_config_lines || return 1
    fi
    while IFS= read -r -d '' _ && IFS= read -r -d '' _ && IFS= read -r -d '' config_line; do
      # validate_config_file already rejected malformed records before this runs.
      IFS='|' read -r risk name raw_path desc min_age check_procs custom_clean_cmd <<< "$config_line"
      trim_to risk "$risk"
      [[ -z "$risk" || "$risk" =~ ^# ]] && continue
      trim_to name "$name"
      select_target_name "$name" || continue
      trim_to raw_path "$raw_path"
      trim_to desc "$desc"
      trim_to min_age "$min_age"
      trim_to check_procs "${check_procs:-}"
      trim_to custom_clean_cmd "${custom_clean_cmd:-}"
      select_target_path "$raw_path" "$custom_clean_cmd" || continue
      select_target_action "$custom_clean_cmd" || continue
      lt_names+=("$name")
      lt_risks+=("$risk")
      lt_paths+=("$raw_path")
      lt_descs+=("$desc")
      lt_min_ages+=("$min_age")
      lt_procs+=("$check_procs")
      lt_actions+=("$custom_clean_cmd")
    done < <(expand_config_globs)
  fi

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
    json_escape "${lt_names[$i]}" name
    json_escape "${lt_risks[$i]}" risk
    json_escape "${lt_paths[$i]}" raw_path
    json_escape "${lt_descs[$i]}" desc
    json_escape "${lt_min_ages[$i]}" min_age
    json_escape "${lt_procs[$i]}" check_procs
    json_escape "${lt_actions[$i]}" custom_clean_cmd
    printf '{"name":"%s","risk":"%s","path":"%s","description":"%s","min_age_days":"%s","check_processes":"%s","custom_action":"%s"}' \
      "$name" "$risk" "$raw_path" "$desc" "$min_age" "$check_procs" "$custom_clean_cmd"
  done
  printf ']}'
  printf '\n'
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
  local rel_cand="$1" rel_pat="$2" _gcm_rest
  local -a cand_parts=() pat_parts=()
  # Split on '/' without read -a so paths containing newlines are not truncated.
  _gcm_rest="$rel_cand"
  while [[ "$_gcm_rest" == */* ]]; do
    cand_parts+=("${_gcm_rest%%/*}")
    _gcm_rest="${_gcm_rest#*/}"
  done
  [[ -n "$_gcm_rest" ]] && cand_parts+=("$_gcm_rest")
  _gcm_rest="$rel_pat"
  while [[ "$_gcm_rest" == */* ]]; do
    pat_parts+=("${_gcm_rest%%/*}")
    _gcm_rest="${_gcm_rest#*/}"
  done
  [[ -n "$_gcm_rest" ]] && pat_parts+=("$_gcm_rest")
  _glob_parts_match 0 0
}

# Split normalized wildcard path into literal prefix, relative pattern tail, min/max depth,
# globstar presence, and trailing leaf name into caller locals in expand_config_globs.
_expand_glob_parse_pattern() {
  local raw="$1" head slashes
  while [[ "$raw" == *//* ]]; do
    raw="${raw//\/\//\/}"
  done
  if [[ "$raw" =~ ^/+$ ]]; then
    raw="/"
  else
    while [[ "$raw" == */ ]]; do
      raw="${raw%/}"
    done
  fi
  head="${raw%%[*?]*}"
  prefix="${head%/*}"
  tail_part="${raw#"$prefix"/}"
  slashes="${tail_part//[^\/]/}"
  depth=$(( ${#slashes} + 1 ))
  max_depth="$depth"
  has_globstar=false
  if [[ "/$tail_part/" == *"/**/"* || "$tail_part" == "**" ]]; then
    has_globstar=true
    max_depth="$GLOB_RECURSION_MAX_DEPTH"
    [[ "$depth" -gt "$max_depth" ]] && max_depth="$depth"
  fi
  leaf="${raw##*/}"
  norm_raw_path="$raw"
}

# Filter and emit one candidate directory for the current config row in expand_config_globs.
_expand_glob_accept_match() {
  local cand="$1" from_cache="$2" c_trimmed c_expanded c_rel c_slashes c_depth c_anc
  [[ -z "$cand" ]] && return 0
  if [[ "$from_cache" == true ]]; then
    # When reusing a shared prefix walk, filter leaf and depth before safety warnings.
    # shellcheck disable=SC2053
    [[ "${cand##*/}" == $leaf ]] || return 0
    c_rel="${cand#"$prefix"/}"
    c_slashes="${c_rel//[^\/]/}"
    c_depth=$(( ${#c_slashes} + 1 ))
    (( c_depth >= depth && c_depth <= max_depth )) || return 0
  fi
  glob_components_match "${cand#"$prefix"/}" "$tail_part" || return 0
  trim_to c_trimmed "$cand"
  # Config records are line/pipe-delimited and consumers trim and expand the
  # path again. Refuse a match whose identity would change in that transport.
  if ! expand_path_safe "$cand" c_expanded \
     || [[ "$cand" == *'|'* || "$cand" == *[[:cntrl:]]* || "$cand" == *\\* || "$cand" != "$c_trimmed" || "$cand" != "$c_expanded" ]]; then
    printf 'Warning: %s:%s: skipping wildcard match that cannot be represented safely: %q\n' \
      "$src_file" "$lineno" "$cand" >&2
    return 0
  fi
  if [[ "${#prune_args[@]}" -eq 0 ]]; then
    c_anc="${cand%/*}"
    while [[ "$c_anc" == "$prefix"/* ]]; do
      [[ -n "${accepted_matches[$c_anc]:-}" ]] && return 0
      c_anc="${c_anc%/*}"
    done
  fi
  if [[ "$target_filter" == "filter:cxx_build" ]]; then
    is_cxx_build_dir "$cand" || return 0
  fi
  [[ "${#prune_args[@]}" -eq 0 ]] && accepted_matches["$cand"]=1
  printf '%s\0%s\0%s|%s|%s|%s\0' "$src_file" "$lineno" "$f1" "$f2" "$cand" "$frest"
}

CONFIG_INCLUDE_MAX_DEPTH=8
CFG_REC_FILES=()
CFG_REC_LINENOS=()
CFG_REC_LINES=()
_CFG_INCLUDE_STACK=()
_CFG_WALKED_FILES=()
_CFG_WALKED_CANON=()
_CFG_SUPPRESS_STDERR=false
_CFG_LAST_ERROR=""
_CFG_LAST_ERROR_FILE=""
_CFG_LAST_ERROR_LINE=""
_CFG_LAST_TARGET_COUNT=0
_CFG_LAST_PROTECT_COUNT=0
_CFG_REC_LOADED=false
_CFG_REC_LOADED_CONFIG=""
_CFG_VALIDATED=false
_CFG_VALIDATED_CONFIG=""
_CFG_HAS_EXPANDABLE=false
CFG_TGT_RISKS=()
CFG_TGT_NAMES=()
CFG_TGT_PATHS=()
CFG_TGT_DESCS=()
CFG_TGT_MIN_AGES=()
CFG_TGT_PROCS=()
CFG_TGT_ACTIONS=()

_cfg_report_error() {
  local err_file="$1" err_line="$2" use_red="$3" err_msg="$4"
  _CFG_LAST_ERROR_FILE="$err_file"
  _CFG_LAST_ERROR_LINE="$err_line"
  _CFG_LAST_ERROR="${err_msg//$'\n'/ }"
  if [[ "$_CFG_SUPPRESS_STDERR" != true ]]; then
    if [[ "$use_red" == true ]]; then
      printf '%b%s%b\n' "$RED" "$err_msg" "$NC" >&2
    else
      printf '%s\n' "$err_msg" >&2
    fi
  fi
}

# Resolve an existing config file physically while preserving valid internal or
# trailing newlines in discovered XDG_CONFIG_HOME paths; emit with trailing '.' so
# callers can strip only the capture sentinel.
_config_file_identity() {
  local resolved
  resolved=$(realpath -e -- "$1" 2>/dev/null && printf '.') || return 1
  resolved="${resolved%.}"
  resolved="${resolved%$'\n'}"
  [[ -n "$resolved" ]] || return 1
  printf '%s.' "$resolved"
}

_collect_config_lines_walk() {
  local src_file="$1" depth="$2"
  local canon_cur line lineno=0 pipes field_count risk inc_raw inc_exp inc_canon stack_item
  local seen_canon walked_seen=false
  local -a walk_lines=()
  if (( depth > CONFIG_INCLUDE_MAX_DEPTH )); then
    _cfg_report_error "$src_file" "" true "Error: ${src_file}: include depth exceeds limit (${CONFIG_INCLUDE_MAX_DEPTH})"
    return 1
  fi
  if [[ ! -f "$src_file" || ! -r "$src_file" ]]; then
    _cfg_report_error "$src_file" "" true "Error: Configuration file '${src_file}' is not readable"
    return 1
  fi
  if ! canon_cur=$(_config_file_identity "$src_file"); then
    _cfg_report_error "$src_file" "" true "Error: Could not resolve configuration file '${src_file}'"
    return 1
  fi
  canon_cur="${canon_cur%.}"
  for stack_item in "${_CFG_INCLUDE_STACK[@]}"; do
    if [[ "$stack_item" == "$canon_cur" ]]; then
      _cfg_report_error "$src_file" "" true "Error: circular include detected for '${src_file}'"
      return 1
    fi
  done
  for seen_canon in "${_CFG_WALKED_CANON[@]}"; do
    if [[ "$seen_canon" == "$canon_cur" ]]; then
      walked_seen=true
      break
    fi
  done
  if [[ "$walked_seen" != true ]]; then
    _CFG_WALKED_CANON+=("$canon_cur")
    _CFG_WALKED_FILES+=("$src_file")
  fi
  _CFG_INCLUDE_STACK+=("$canon_cur")
  mapfile -t walk_lines < "$src_file"
  for line in "${walk_lines[@]}"; do
    lineno=$((lineno + 1))
    pipes="${line//[^|]/}"
    field_count=$(( ${#pipes} + 1 ))
    IFS='|' read -r risk inc_raw _ <<< "$line"
    trim_to risk "$risk"
    if [[ "$risk" == "include" ]]; then
      if [[ "$field_count" -ne 2 ]]; then
        _cfg_report_error "$src_file" "$lineno" true "Error: ${src_file}:${lineno}: include line requires 2 fields (include|PATH), found ${field_count}"
        unset '_CFG_INCLUDE_STACK[${#_CFG_INCLUDE_STACK[@]}-1]'
        return 1
      fi
      trim_to inc_raw "$inc_raw"
      if [[ -z "$inc_raw" ]]; then
        _cfg_report_error "$src_file" "$lineno" true "Error: ${src_file}:${lineno}: include PATH is empty"
        unset '_CFG_INCLUDE_STACK[${#_CFG_INCLUDE_STACK[@]}-1]'
        return 1
      fi
      if [[ "$inc_raw" == *$'\r'* ]] || ! expand_path_safe "$inc_raw" inc_exp || [[ "$inc_exp" == *$'\r'* ]]; then
        _cfg_report_error "$src_file" "$lineno" false "Error: ${src_file}:${lineno}: include PATH has unsafe path expansion"
        unset '_CFG_INCLUDE_STACK[${#_CFG_INCLUDE_STACK[@]}-1]'
        return 1
      fi
      if [[ "$inc_exp" != /* ]]; then
        _cfg_report_error "$src_file" "$lineno" true "Error: ${src_file}:${lineno}: include PATH '${inc_exp}' must be absolute"
        unset '_CFG_INCLUDE_STACK[${#_CFG_INCLUDE_STACK[@]}-1]'
        return 1
      fi
      if [[ "$inc_exp" == *[*?\[]* ]]; then
        _cfg_report_error "$src_file" "$lineno" true "Error: ${src_file}:${lineno}: include PATH '${inc_exp}' cannot contain glob characters"
        unset '_CFG_INCLUDE_STACK[${#_CFG_INCLUDE_STACK[@]}-1]'
        return 1
      fi
      if [[ -d "$inc_exp" || ! -e "$inc_exp" || ! -f "$inc_exp" ]]; then
        _cfg_report_error "$src_file" "$lineno" true "Error: ${src_file}:${lineno}: included configuration file '${inc_exp}' does not exist or is not a regular file"
        unset '_CFG_INCLUDE_STACK[${#_CFG_INCLUDE_STACK[@]}-1]'
        return 1
      fi
      if [[ ! -r "$inc_exp" ]]; then
        _cfg_report_error "$src_file" "$lineno" true "Error: ${src_file}:${lineno}: included configuration file '${inc_exp}' is not readable"
        unset '_CFG_INCLUDE_STACK[${#_CFG_INCLUDE_STACK[@]}-1]'
        return 1
      fi
      if ! inc_canon=$(_config_file_identity "$inc_exp"); then
        _cfg_report_error "$src_file" "$lineno" true "Error: ${src_file}:${lineno}: could not resolve included configuration file '${inc_exp}'"
        unset '_CFG_INCLUDE_STACK[${#_CFG_INCLUDE_STACK[@]}-1]'
        return 1
      fi
      inc_canon="${inc_canon%.}"
      for stack_item in "${_CFG_INCLUDE_STACK[@]}"; do
        if [[ "$stack_item" == "$inc_canon" ]]; then
          _cfg_report_error "$src_file" "$lineno" true "Error: ${src_file}:${lineno}: circular include '${inc_exp}'"
          unset '_CFG_INCLUDE_STACK[${#_CFG_INCLUDE_STACK[@]}-1]'
          return 1
        fi
      done
      if (( depth + 1 > CONFIG_INCLUDE_MAX_DEPTH )); then
        _cfg_report_error "$src_file" "$lineno" true "Error: ${src_file}:${lineno}: include depth exceeds limit (${CONFIG_INCLUDE_MAX_DEPTH})"
        unset '_CFG_INCLUDE_STACK[${#_CFG_INCLUDE_STACK[@]}-1]'
        return 1
      fi
      _collect_config_lines_walk "$inc_exp" $((depth + 1)) || {
        unset '_CFG_INCLUDE_STACK[${#_CFG_INCLUDE_STACK[@]}-1]'
        return 1
      }
      continue
    fi
    CFG_REC_FILES+=("$src_file")
    CFG_REC_LINENOS+=("$lineno")
    CFG_REC_LINES+=("$line")
  done
  unset '_CFG_INCLUDE_STACK[${#_CFG_INCLUDE_STACK[@]}-1]'
}

load_config_lines() {
  _CFG_REC_LOADED=false
  _CFG_REC_LOADED_CONFIG=""
  _CFG_VALIDATED=false
  _CFG_VALIDATED_CONFIG=""
  _CFG_HAS_EXPANDABLE=false
  CFG_TGT_RISKS=()
  CFG_TGT_NAMES=()
  CFG_TGT_PATHS=()
  CFG_TGT_DESCS=()
  CFG_TGT_MIN_AGES=()
  CFG_TGT_PROCS=()
  CFG_TGT_ACTIONS=()
  CFG_REC_FILES=()
  CFG_REC_LINENOS=()
  CFG_REC_LINES=()
  _CFG_INCLUDE_STACK=()
  _CFG_WALKED_FILES=()
  _CFG_WALKED_CANON=()
  _CFG_LAST_ERROR=""
  _CFG_LAST_ERROR_FILE=""
  _CFG_LAST_ERROR_LINE=""
  _collect_config_lines_walk "$CONFIG_FILE" 0 || return 1
  _CFG_REC_LOADED=true
  _CFG_REC_LOADED_CONFIG="$CONFIG_FILE"
}

# Stream the configuration file with wildcard PATH_EXPRESSION lines expanded into
# one record per matching directory. Expansion runs through find, never a shell glob
# and never eval, so the documented no-wildcard-eval contract still holds: only the
# $HOME / ~ / $USER placeholders are substituted, and every expanded match re-enters
# the same safety pipeline (check_path_safety, canonicalize_physical) as a literal
# target. Each emitted NUL-delimited triple carries its physical source file, 1-based
# line number, and record line so warnings and errors report against the real file:line.
expand_config_globs() {
  local line src_file="" lineno=0 risk name raw_path f1 f2 f3 frest pipes fields expanded_glob_path norm_raw_path
  local prefix depth max_depth tail_part leaf match target_filter has_globstar
  local p_min p_max cache_start cache_len cache_end cache_idx rec_idx
  local -a prune_args globstar_dirs=()
  local -A accepted_matches globstar_prefix_counts=() globstar_prefix_min=() globstar_prefix_max=() globstar_cache_start=() globstar_cache_len=()

  if [[ "${_CFG_REC_LOADED:-false}" != true || "${_CFG_REC_LOADED_CONFIG:-}" != "$CONFIG_FILE" ]]; then
    load_config_lines || return 1
  fi

  # Pre-scan shared "**" prefixes so rows sharing one literal root reuse one find traversal.
  for line in "${CFG_REC_LINES[@]}"; do
    pipes="${line//[^|]/}"
    fields=$(( ${#pipes} + 1 ))
    IFS='|' read -r f1 f2 f3 frest <<< "$line"
    trim_to risk "$f1"
    [[ "$risk" == "protect" || -z "$risk" || "$risk" =~ ^# || "$fields" -lt 5 || "$fields" -gt 7 ]] && continue
    trim_to raw_path "$f3"
    [[ "$raw_path" == *[*?]* ]] || continue
    trim_to name "$f2"
    if ! target_name_included "$name" || target_name_excluded "$name"; then
      continue
    fi
    expand_path_safe "$raw_path" expanded_glob_path || continue
    [[ "$expanded_glob_path" == *'['* || "$expanded_glob_path" == *']'* ]] && continue
    _expand_glob_parse_pattern "$expanded_glob_path"
    [[ -n "$prefix" && "$has_globstar" == true ]] || continue
    globstar_prefix_counts["$prefix"]=$(( ${globstar_prefix_counts[$prefix]:-0} + 1 ))
    if [[ -z "${globstar_prefix_min[$prefix]+set}" || "$depth" -lt "${globstar_prefix_min[$prefix]}" ]]; then
      globstar_prefix_min["$prefix"]="$depth"
    fi
    if [[ -z "${globstar_prefix_max[$prefix]+set}" || "$max_depth" -gt "${globstar_prefix_max[$prefix]}" ]]; then
      globstar_prefix_max["$prefix"]="$max_depth"
    fi
  done

  for rec_idx in "${!CFG_REC_LINES[@]}"; do
    src_file="${CFG_REC_FILES[$rec_idx]}"
    lineno="${CFG_REC_LINENOS[$rec_idx]}"
    line="${CFG_REC_LINES[$rec_idx]}"
    pipes="${line//[^|]/}"
    fields=$(( ${#pipes} + 1 ))
    IFS='|' read -r f1 f2 f3 frest <<< "$line"
    trim_to risk "$f1"
    [[ "$risk" == "protect" ]] && continue
    trim_to raw_path "$f3"
    # Leave malformed lines intact for the field-count validator.
    if [[ -z "$risk" || "$risk" =~ ^# || "$fields" -lt 5 || "$fields" -gt 7 ]]; then
      printf '%s\0%s\0%s\0' "$src_file" "$lineno" "$line"
      continue
    fi

    target_filter=""
    [[ "$fields" -eq 7 ]] && trim_to target_filter "${frest##*|}"
    if [[ "$raw_path" != *[*?]* ]]; then
      if [[ "$target_filter" == "filter:cxx_build" ]]; then
        if ! expand_path_safe "$raw_path" expanded_glob_path; then
          printf 'Warning: %s:%s: skipping target with unsafe path expansion\n' "$src_file" "$lineno" >&2
          continue
        fi
        is_cxx_build_dir "$expanded_glob_path" || continue
      fi
      printf '%s\0%s\0%s\0' "$src_file" "$lineno" "$line"
      continue
    fi

    trim_to name "$f2"
    if ! target_name_included "$name" || target_name_excluded "$name"; then
      printf '%s\0%s\0%s\0' "$src_file" "$lineno" "$line"
      continue
    fi

    if ! expand_path_safe "$raw_path" expanded_glob_path; then
      printf 'Warning: %s:%s: skipping wildcard with unsafe path expansion\n' "$src_file" "$lineno" >&2
      continue
    fi
    if [[ "$expanded_glob_path" == *'['* || "$expanded_glob_path" == *']'* ]]; then
      printf 'Warning: %s:%s: skipping wildcard with bracket characters in expanded path\n' "$src_file" "$lineno" >&2
      continue
    fi
    _expand_glob_parse_pattern "$expanded_glob_path"

    # Refuse to expand it and pass the line through untouched: the literal pattern
    # then fails the ordinary existence and HOME-boundary checks, so nothing is
    # scanned and nothing is deleted. This runs inside a process substitution, so
    # it warns and degrades rather than trying to abort the run from a subshell.
    if [[ -z "$prefix" ]]; then
      printf '%bWarning: %s:%s: wildcard must follow a literal directory, not the filesystem root; leaving '\''%s'\'' unexpanded%b\n' "$YELLOW" "$src_file" "$lineno" "$norm_raw_path" "$NC" >&2
      printf '%s\0%s\0%s\0' "$src_file" "$lineno" "$line"
      continue
    fi

    # Stop at unfiltered matches. When "**" widens the search depth or a filter is
    # active, find must walk through rejected parents so a candidate rejected by
    # glob_components_match or the filter cannot prune a valid deeper match;
    # descendants of accepted matches are suppressed in bash below.
    prune_args=(-prune)
    [[ "$target_filter" == "filter:cxx_build" || "$has_globstar" == true ]] && prune_args=()
    accepted_matches=()
    if [[ "$has_globstar" == true && "${globstar_prefix_counts[$prefix]:-0}" -gt 1 ]]; then
      if [[ -z "${globstar_cache_start[$prefix]+set}" ]]; then
        p_min="${globstar_prefix_min[$prefix]}"
        p_max="${globstar_prefix_max[$prefix]}"
        cache_start="${#globstar_dirs[@]}"
        while IFS= read -r -d '' match; do
          [[ -z "$match" ]] && continue
          globstar_dirs+=("$match")
        done < <(find "$prefix" -mindepth "$p_min" -maxdepth "$p_max" -type d -print0 2>/dev/null | sort -z)
        globstar_cache_start["$prefix"]="$cache_start"
        globstar_cache_len["$prefix"]=$(( ${#globstar_dirs[@]} - cache_start ))
      fi
      cache_start="${globstar_cache_start[$prefix]}"
      cache_len="${globstar_cache_len[$prefix]}"
      cache_end=$(( cache_start + cache_len ))
      for (( cache_idx = cache_start; cache_idx < cache_end; cache_idx++ )); do
        _expand_glob_accept_match "${globstar_dirs[$cache_idx]}" true
      done
    else
      while IFS= read -r -d '' match; do
        _expand_glob_accept_match "$match" false
      done < <(find "$prefix" -mindepth "$depth" -maxdepth "$max_depth" \
                    -type d -name "$leaf" -path "$norm_raw_path" "${prune_args[@]}" -print0 2>/dev/null | sort -z)
    fi
  done
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
    printf '%s\n' "/"
    return 0
  fi
  while [[ "$p" == */ ]]; do
    p="${p%/}"
  done
  printf '%s\n' "$p"
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
load_exclude_from_file() {
  EXCLUDE_FROM_PATTERNS=()
  local raw_path="${EXCLUDE_FROM:-}" line excl_trimmed line_no=0
  [[ -n "$raw_path" ]] || return 0
  if [[ "$raw_path" == *$'\n'* ]]; then
    echo -e "${RED}Error: --exclude-from path cannot contain line feeds.${NC}" >&2
    return 1
  fi
  if [[ -d "$raw_path" ]]; then
    echo -e "${RED}Error: --exclude-from path '$raw_path' is a directory, expected a regular file.${NC}" >&2
    return 1
  fi
  if [[ ! -e "$raw_path" ]]; then
    echo -e "${RED}Error: --exclude-from file '$raw_path' does not exist.${NC}" >&2
    return 1
  fi
  if [[ ! -f "$raw_path" ]]; then
    echo -e "${RED}Error: --exclude-from path '$raw_path' must be a regular file.${NC}" >&2
    return 1
  fi
  if [[ ! -r "$raw_path" ]]; then
    echo -e "${RED}Error: --exclude-from file '$raw_path' is not readable.${NC}" >&2
    return 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_no=$((line_no + 1))
    if [[ "$line" == *$'\r'* ]]; then
      echo -e "${RED}Error: --exclude-from file '$raw_path' line $line_no contains a carriage return (CR).${NC}" >&2
      return 1
    fi
    trim_to excl_trimmed "$line"
    if [[ -z "$excl_trimmed" || "$excl_trimmed" == \#* ]]; then
      continue
    fi
    EXCLUDE_FROM_PATTERNS+=("$excl_trimmed")
  done < "$raw_path"
  return 0
}

build_exclude_find_args() {
  local patterns="${1-${EXCLUDE_PATTERNS:-}}"
  EXCLUDE_FIND_ARGS=()
  TARGET_EXCLUDE_ACTIVE=false
  if [[ -n "$patterns" || ${#EXCLUDE_FROM_PATTERNS[@]} -gt 0 ]]; then
    TARGET_EXCLUDE_ACTIVE=true
  else
    return 0
  fi

  local -a pats=()
  if [[ -n "$patterns" ]]; then
    local rest="$patterns"
    while [[ "$rest" == *,* ]]; do
      pats+=("${rest%%,*}")
      rest="${rest#*,}"
    done
    pats+=("$rest")
  fi
  if [[ ${#EXCLUDE_FROM_PATTERNS[@]} -gt 0 ]]; then
    pats+=("${EXCLUDE_FROM_PATTERNS[@]}")
  fi

  if [[ ${#pats[@]} -eq 0 ]]; then
    return 0
  fi
  
  local -a clauses=()
  local pat
  for pat in "${pats[@]}"; do
    trim_to pat "$pat"
    if [[ -z "$pat" ]]; then
      continue
    fi
    # Normalize directory-style trailing slashes (e.g. sub/, a/b/, sub///)
    # while keeping root "/" intact and refusing to widen "*/" into bare "*".
    if [[ "$pat" == */ && ! "$pat" =~ ^/+$ ]]; then
      local stripped_pat="$pat"
      while [[ "$stripped_pat" == */ ]]; do
        stripped_pat="${stripped_pat%/}"
      done
      if [[ -n "$stripped_pat" && "$stripped_pat" != "*" && "$stripped_pat" != "**" ]]; then
        pat="$stripped_pat"
      fi
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
    echo -e "  [${YELLOW:-}LOG${NC:-}] Refusing to write log outside \$HOME ('$target'); logging disabled." >&2
    LOG_ENABLED=false
    return 0
  fi
  # Guard against standalone extracted unit tests (set -u without LOG_MAX_SIZE_BYTES).
  local max_bytes="${LOG_MAX_SIZE_BYTES:-0}"
  if [[ "$max_bytes" =~ ^[[:digit:]]+$ ]] && (( max_bytes > 0 )); then
    local log_bytes=0 rotated="${target}.1" resolved_rotated=""
    if [[ -L "$target" ]]; then
      echo -e "  [${YELLOW:-}LOG${NC:-}] Warning: refusing to rotate symlinked log '$target'." >&2
    elif [[ -f "$target" ]]; then
      log_bytes=$({ wc -c < "$target"; } 2>/dev/null || printf 0)
      log_bytes=${log_bytes//[[:space:]]/}
      if [[ "$log_bytes" =~ ^[[:digit:]]+$ ]] && (( log_bytes > 0 && log_bytes >= max_bytes )); then
        if [[ -L "$rotated" || -d "$rotated" ]]; then
          echo -e "  [${YELLOW:-}LOG${NC:-}] Warning: refusing to rotate log to unsafe backup path '$rotated'." >&2
        elif ! resolved_rotated=$(canonicalize_physical "$rotated") || \
             { [[ "$resolved_rotated" != "$resolved_home" && "$resolved_rotated" != "$resolved_home"/* ]]; }; then
          echo -e "  [${YELLOW:-}LOG${NC:-}] Warning: refusing to rotate log outside \$HOME ('$rotated')." >&2
        elif ! mv -f -- "$target" "$rotated" 2>/dev/null; then
          echo -e "  [${YELLOW:-}LOG${NC:-}] Warning: could not rotate log '$target' to '$rotated'." >&2
        fi
      fi
    fi
  fi
  if ! { mkdir -p "$literal_dir" && printf '%s\n' "$message" >> "$target"; } 2>/dev/null; then
    echo -e "  [${YELLOW:-}LOG${NC:-}] Warning: could not write to log '$target'." >&2
  fi
}

# Print configured cleanup targets (strictly read-only): NAME, risk, path, and
# description for every active config line. No disk analysis or mutation.
list_config_targets() {
  local config_line
  local risk name raw_path desc min_age check_procs custom_clean_cmd
  local i

  if [[ "$JSON_OUTPUT" == true ]]; then
    emit_list_targets_json
    return $?
  fi

  echo -e "${BOLD}${BLUE}=== Configured Targets ===${NC}"
  echo -e "Config file: ${YELLOW}$CONFIG_FILE${NC}"
  echo

  if [[ "${_CFG_VALIDATED:-false}" == true && "${_CFG_VALIDATED_CONFIG:-}" == "$CONFIG_FILE" && "${_CFG_HAS_EXPANDABLE:-false}" != true ]]; then
    for i in "${!CFG_TGT_NAMES[@]}"; do
      name="${CFG_TGT_NAMES[$i]}"
      select_target_name "$name" || continue
      raw_path="${CFG_TGT_PATHS[$i]}"
      custom_clean_cmd="${CFG_TGT_ACTIONS[$i]}"
      select_target_path "$raw_path" "$custom_clean_cmd" || continue
      select_target_action "$custom_clean_cmd" || continue
      printf '%s\t%s\t%s\t%s\n' "$name" "${CFG_TGT_RISKS[$i]}" "$raw_path" "${CFG_TGT_DESCS[$i]}"
    done
  else
    if [[ "${_CFG_REC_LOADED:-false}" != true || "${_CFG_REC_LOADED_CONFIG:-}" != "$CONFIG_FILE" ]]; then
      load_config_lines || return 1
    fi
    while IFS= read -r -d '' _ && IFS= read -r -d '' _ && IFS= read -r -d '' config_line; do
      # validate_config_file already rejected malformed records before this runs.
      IFS='|' read -r risk name raw_path desc min_age check_procs custom_clean_cmd <<< "$config_line"
      trim_to risk "$risk"
      [[ -z "$risk" || "$risk" =~ ^# ]] && continue
      trim_to name "$name"
      select_target_name "$name" || continue
      trim_to raw_path "$raw_path"
      trim_to custom_clean_cmd "${custom_clean_cmd:-}"
      select_target_path "$raw_path" "$custom_clean_cmd" || continue
      select_target_action "$custom_clean_cmd" || continue
      trim_to desc "$desc"
      printf '%s\t%s\t%s\t%s\n' "$name" "$risk" "$raw_path" "$desc"
    done < <(expand_config_globs)
  fi
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
  local config_line config_src config_lineno=0 config_pipes field_count
  local risk name raw_path desc min_age check_procs custom_clean_cmd
  local target_count=0 protect_count=0 exclusion_patterns rec_idx
  local risk_err="" risk_err_plain=""

  _CFG_LAST_TARGET_COUNT=0
  _CFG_LAST_PROTECT_COUNT=0
  load_config_lines || return 1
  for rec_idx in "${!CFG_REC_LINES[@]}"; do
    config_src="${CFG_REC_FILES[$rec_idx]}"
    config_lineno="${CFG_REC_LINENOS[$rec_idx]}"
    config_line="${CFG_REC_LINES[$rec_idx]}"
    config_pipes="${config_line//[^|]/}"
    field_count=$(( ${#config_pipes} + 1 ))
    IFS='|' read -r risk name raw_path desc min_age check_procs custom_clean_cmd <<< "$config_line"
    trim_to risk "$risk"
    [[ -z "$risk" || "$risk" =~ ^# ]] && continue
    if [[ "$risk" == "protect" ]]; then
      if [[ "$field_count" -ne 2 ]]; then
        _cfg_report_error "$config_src" "$config_lineno" true "Error: ${config_src}:${config_lineno}: protect line requires 2 fields (protect|PATH), found ${field_count}"
        return 1
      fi
      trim_to name "$name"
      if [[ -z "$name" ]]; then
        _cfg_report_error "$config_src" "$config_lineno" true "Error: ${config_src}:${config_lineno}: protect PATH is empty"
        return 1
      fi
      if ! expand_path_safe "$name" name; then
        _cfg_report_error "$config_src" "$config_lineno" false "Error: ${config_src}:${config_lineno}: protect PATH has unsafe path expansion"
        return 1
      fi
      if [[ "$name" != /* ]]; then
        _cfg_report_error "$config_src" "$config_lineno" true "Error: ${config_src}:${config_lineno}: protect PATH '${name}' must be absolute"
        return 1
      fi
      if [[ "$name" == *[*?\[]* ]]; then
        _cfg_report_error "$config_src" "$config_lineno" true "Error: ${config_src}:${config_lineno}: protect PATH '${name}' cannot contain glob characters"
        return 1
      fi
      protect_count=$((protect_count + 1))
      continue
    fi
    if [[ "$field_count" -lt 5 || "$field_count" -gt 7 ]]; then
      _cfg_report_error "$config_src" "$config_lineno" true "Error: ${config_src}:${config_lineno}: expected 5-7 fields, found ${field_count}"
      return 1
    fi
    trim_to name "$name"
    trim_to raw_path "$raw_path"
    trim_to desc "$desc"
    trim_to min_age "$min_age"
    if [[ -n "${check_procs:-}" ]]; then trim_to check_procs "$check_procs"; else check_procs=""; fi
    if [[ -n "${custom_clean_cmd:-}" ]]; then trim_to custom_clean_cmd "$custom_clean_cmd"; else custom_clean_cmd=""; fi
    if [[ -z "$name" ]]; then
      _cfg_report_error "$config_src" "$config_lineno" true "Error: ${config_src}:${config_lineno}: NAME (field 2) is empty"
      return 1
    fi
    if [[ -z "$raw_path" ]]; then
      _cfg_report_error "$config_src" "$config_lineno" true "Error: ${config_src}:${config_lineno}: PATH (field 3) is empty"
      return 1
    fi
    if [[ ( "$raw_path" == *'*'* || "$raw_path" == *'?'* ) &&
          ( "$raw_path" == *'['* || "$raw_path" == *']'* ) ]]; then
      _cfg_report_error "$config_src" "$config_lineno" true "Error: ${config_src}:${config_lineno}: PATH cannot contain '[' or ']' in a wildcard path"
      return 1
    fi
    if [[ -n "$check_procs" && "$check_procs" =~ (^|,)[[:space:]]*(,|$) ]]; then
      _cfg_report_error "$config_src" "$config_lineno" true "Error: ${config_src}:${config_lineno}: malformed CHECK_PROCESSES '${check_procs}' (empty or stray comma-separated token)"
      return 1
    fi
    # A cmdline: token with nothing after the prefix would match every process.
    if [[ "$check_procs" =~ (^|,)[[:space:]]*cmdline:[[:space:]]*(,|$) ]]; then
      _cfg_report_error "$config_src" "$config_lineno" true "Error: ${config_src}:${config_lineno}: malformed CHECK_PROCESSES '${check_procs}' (empty pattern after 'cmdline:')"
      return 1
    fi
    if [[ -n "$custom_clean_cmd" ]]; then
      case "$custom_clean_cmd" in
        exclude:*)
          exclusion_patterns="${custom_clean_cmd#exclude:}"
          if [[ -z "$exclusion_patterns" || "$exclusion_patterns" =~ (^|,)[[:space:]]*(,|$) \
                || "$exclusion_patterns" == *'|'* || "$exclusion_patterns" == *$'\n'* \
                || "$exclusion_patterns" == *$'\r'* ]]; then
            _cfg_report_error "$config_src" "$config_lineno" true "Error: ${config_src}:${config_lineno}: malformed CUSTOM_ACTION '${custom_clean_cmd}' (unsafe or empty exclusion pattern)"
            return 1
          fi
          ;;
        action:paccache_keep1|action:paccache_keep2|action:paccache_keep3|action:pacman_clean|action:apt_clean|action:dnf_clean|action:zypper_clean|action:apk_clean|action:uv_cache_prune|action:pnpm_store_prune|action:hf_cache_prune|action:nix_store_gc|action:flatpak_unused|filter:cxx_build)
          ;;
        *)
          _cfg_report_error "$config_src" "$config_lineno" true "${config_src}:${config_lineno}: Error: Unknown action '${custom_clean_cmd}' in target '${name}'."
          return 1
          ;;
      esac
    fi
    if ! _risk_to_int_to "" "$risk"; then
      risk_err=$(risk_to_int "$risk" "${config_src}:${config_lineno}: " 2>&1 >/dev/null) || true
      risk_err_plain=$(printf '%s' "$risk_err" | sed $'s/\033\\[[0-9;]*m//g')
      _CFG_LAST_ERROR_FILE="$config_src"
      _CFG_LAST_ERROR_LINE="$config_lineno"
      _CFG_LAST_ERROR="${risk_err_plain//$'\n'/ }"
      [[ "$_CFG_SUPPRESS_STDERR" == true ]] || printf '%s\n' "$risk_err" >&2
      return 1
    fi
    if [[ -z "$min_age" ]]; then
      :
    elif [[ ! "$min_age" =~ ^[[:digit:]]+$ ]]; then
      _cfg_report_error "$config_src" "$config_lineno" true "Error: ${config_src}:${config_lineno}: invalid MIN_AGE_DAYS '${min_age}'"
      return 1
    elif [[ "$custom_clean_cmd" == action:* ]] && has_positive_age "$min_age"; then
      # The action runs its own command over the whole cache; an age would only narrow the plan's estimate.
      _cfg_report_error "$config_src" "$config_lineno" true "Error: ${config_src}:${config_lineno}: MIN_AGE_DAYS must be 0 for ${custom_clean_cmd} (the action ignores file age)"
      return 1
    fi
    if [[ "$raw_path" == *[*?]* || "$custom_clean_cmd" == "filter:cxx_build" ]]; then
      _CFG_HAS_EXPANDABLE=true
    elif [[ "$_CFG_HAS_EXPANDABLE" != true ]]; then
      CFG_TGT_RISKS+=("$risk")
      CFG_TGT_NAMES+=("$name")
      CFG_TGT_PATHS+=("$raw_path")
      CFG_TGT_DESCS+=("$desc")
      CFG_TGT_MIN_AGES+=("$min_age")
      CFG_TGT_PROCS+=("$check_procs")
      CFG_TGT_ACTIONS+=("$custom_clean_cmd")
    fi
    target_count=$((target_count + 1))
  done

  if [[ "$_CFG_HAS_EXPANDABLE" != true ]]; then
    _CFG_VALIDATED=true
    _CFG_VALIDATED_CONFIG="$CONFIG_FILE"
  else
    CFG_TGT_RISKS=()
    CFG_TGT_NAMES=()
    CFG_TGT_PATHS=()
    CFG_TGT_DESCS=()
    CFG_TGT_MIN_AGES=()
    CFG_TGT_PROCS=()
    CFG_TGT_ACTIONS=()
  fi
  _CFG_LAST_TARGET_COUNT="$target_count"
  _CFG_LAST_PROTECT_COUNT="$protect_count"
  printf 'OK: %s targets in %s\n' "$target_count" "$CONFIG_FILE"
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
  local session="$1" meta="$1/quarantine.meta" records="" entry mtype rel top_rel count=0
  local -A ref_seen=()
  if [[ -f "$meta" ]]; then
    if ! records=$(cat -- "$meta" && printf '.'); then
      echo "Error: Failed to read quarantine metadata '$meta'." >&2
      return 1
    fi
    records=${records%.}
  fi
  while IFS='|' read -r mtype rel _ || [[ -n "$mtype" ]]; do
    trim_to mtype "$mtype"
    [[ -z "$mtype" || "$mtype" == \#* ]] && continue
    trim_to rel "$rel"
    top_rel="${rel%%/*}"
    [[ -n "$top_rel" ]] && ref_seen["$top_rel"]=1
  done <<< "$records"
  local stream_rc=""
  while IFS= read -r -d '' entry; do
    if [[ -z "$entry" ]]; then
      IFS= read -r -d '' stream_rc
      break
    fi
    [[ -n "${ref_seen[$entry]+set}" ]] || count=$((count + 1))
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
    trim_to mtype "$mtype"
    [[ "$mtype" == aged-restored ]] && mtype=aged
    [[ -z "$mtype" || "$mtype" =~ ^# ]] && continue
    trim_to morig "${morig:-}"
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

_emit_session_targets_json() {
  local meta="$1" mtype morig jmtype jmorig tgt_first=true
  [[ -f "$meta" ]] || return 0
  while IFS='|' read -r mtype _ morig _ || [[ -n "$mtype" ]]; do
    trim_to mtype "$mtype"
    [[ "$mtype" == aged-restored ]] && mtype=aged
    [[ -z "$mtype" || "$mtype" =~ ^# ]] && continue
    trim_to morig "${morig:-}"
    json_escape "$mtype" jmtype
    json_escape "$morig" jmorig
    if [[ "$tgt_first" == true ]]; then
      tgt_first=false
    else
      printf ','
    fi
    printf '{"type":"%s","path":"%s"}' "$jmtype" "$jmorig"
  done < "$meta"
}

_emit_purge_preview_json() {
  local selector="$1" target_cnt="$2"
  shift 2
  local -a sessions=() held_list=() sess_sizes=() sess_unrec=()
  local i=0 s ts sb sh ur total_bytes=0 total_human="" first=true esc=""
  while (( i < target_cnt )); do
    sessions+=("$1")
    shift
    i=$((i + 1))
  done
  held_list=("$@")

  for s in "${sessions[@]}"; do
    sb=$(quarantine_size_bytes "$s") || return 1
    sess_sizes+=("$sb")
    total_bytes=$((total_bytes + sb))
    ur=$(quarantine_unrecorded_entry_count "$s") || return 1
    sess_unrec+=("$ur")
  done
  total_human=$(format_bytes "$total_bytes")

  printf '{"selector":"%s","sessions":[' "$(json_escape "$selector")"
  for i in "${!sessions[@]}"; do
    s="${sessions[$i]}"
    ts=$(basename "$s")
    sb="${sess_sizes[$i]}"
    sh=$(format_bytes "$sb")
    [[ "$i" -eq 0 ]] || printf ','
    printf '{"timestamp":"%s","size_bytes":%s,"size_human":"%s","unrecorded_entry_count":%s,"targets":[' \
      "$(json_escape "$ts")" "$sb" "$(json_escape "$sh")" "${sess_unrec[$i]}"
    _emit_session_targets_json "$s/quarantine.meta"
    printf ']}'
  done
  printf '],"held_skipped":['
  first=true
  for s in "${held_list[@]}"; do
    [[ "$first" == true ]] || printf ','
    first=false
    json_escape "$s" esc
    printf '"%s"' "$esc"
  done
  printf '],"purge_count":%d,"held_skipped_count":%d,"total_reclaimable_bytes":%s,"total_reclaimable_human":"%s"}\n' \
    "${#sessions[@]}" "${#held_list[@]}" "$total_bytes" "$(json_escape "$total_human")"
}

# List quarantine sessions (strictly read-only): print each session's
# timestamp (directory name), size, and modification date, plus the targets it
# holds. Never moves, deletes, or modifies any session or its metadata.
# With --json, emit a machine-readable inventory instead of human banners.
emit_list_sessions_json() {
  local quarantine_base="$HOME/.cache/linux-cleaner/quarantine"
  local -a sessions=() session_sizes=() session_unrecorded=()
  local s session idx ts size_bytes size_human mdate unrecorded held
  local sess_first=true

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
    _emit_session_targets_json "$session/quarantine.meta"
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

  local json_preview=false
  [[ "$DRY_RUN_EXPLICIT" == true && "$JSON_OUTPUT" == true ]] && json_preview=true

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
      if [[ "$json_preview" == true ]]; then
        _emit_purge_preview_json "$target" 0
      else
        echo -e "${YELLOW}No quarantine sessions older than ${days} day(s).${NC}"
      fi
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
      if [[ "$json_preview" == true ]]; then
        _emit_purge_preview_json "$target" 0
      else
        echo -e "${YELLOW}No quarantine sessions beyond the max-size:${max_size_spec} budget.${NC}"
      fi
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
      if [[ "$json_preview" == true ]]; then
        _emit_purge_preview_json "$target" 0
      else
        echo -e "${YELLOW}No quarantine sessions beyond the newest ${keep_count}.${NC}"
      fi
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
      if [[ "$json_preview" == true ]]; then
        _emit_purge_preview_json "$target" 0
      else
        echo -e "${YELLOW}No quarantine sessions found.${NC}"
      fi
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
      if [[ "$json_preview" == true ]]; then
        _emit_purge_preview_json "$target" 0
      else
        echo -e "${YELLOW}No quarantine sessions older than ${days} day(s).${NC}"
      fi
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
      if [[ "$json_preview" == true ]]; then
        _emit_purge_preview_json "$target" 0
      else
        echo -e "${YELLOW}No quarantine sessions beyond the max-size:${max_size_spec} budget.${NC}"
      fi
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
      if [[ "$json_preview" == true ]]; then
        _emit_purge_preview_json "$target" 0
      else
        echo -e "${YELLOW}No quarantine sessions beyond the newest ${keep_count}.${NC}"
      fi
      return 0
    fi
    for (( idx=${#over_count[@]}-1; idx>=0; idx-- )); do
      targets+=("${over_count[idx]}")
    done
  else
    # A named session must be an immediate child of the base.
    validate_quarantine_session_name "$target"
    local dir="$quarantine_base/$target"
    if [[ -L "$dir" || ! -d "$dir" ]]; then
      echo -e "${RED}Error: Quarantine session directory '$dir' does not exist.${NC}" >&2
      exit 1
    fi
    targets+=("$dir")
  fi

  if [[ "$DRY_RUN_EXPLICIT" == true && "$json_preview" != true ]]; then
    echo -e "${BOLD}${BLUE}=== Would purge Quarantine Sessions ===${NC}"
  fi

  # A hold only ever shrinks the purge set, even under --force: bulk selectors and
  # inline retention skip held sessions (they still count toward max-size and
  # keep-latest), and a held latest or named session is refused, never replaced.
  local d
  local -a unheld=() held_skipped=()
  for d in "${targets[@]}"; do
    if ! session_is_held "$d"; then
      unheld+=("$d")
      continue
    fi
    case "$target" in
      all|older-than:*|max-size:*|keep-latest:*)
        held_skipped+=("$(basename "$d")")
        if [[ "$json_preview" != true ]]; then
          echo -e "${YELLOW}Skipping held session $(basename "$d") (release it with --release-session $(basename "$d")).${NC}"
        fi
        ;;
      *)
        echo -e "${RED}Error: Quarantine session '$(basename "$d")' is held; run --release-session $(basename "$d") before purging it.${NC}" >&2
        exit 1
        ;;
    esac
  done
  if [[ ${#unheld[@]} -eq 0 ]]; then
    if [[ "$json_preview" == true ]]; then
      _emit_purge_preview_json "$target" 0 "${held_skipped[@]}" || return 1
    else
      echo -e "${YELLOW}No quarantine sessions to purge; every selected session is held.${NC}"
    fi
    return 0
  fi
  targets=("${unheld[@]}")

  if [[ "$json_preview" == true ]]; then
    _emit_purge_preview_json "$target" "${#targets[@]}" "${targets[@]}" "${held_skipped[@]}" || return 1
    return 0
  fi

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

# --trash-keep-days and --trash-max-size: retire old or over-budget quarantine
# sessions at the end of every cleanup run, including one that had nothing to clean,
# so a skipped day still purges. Age runs first so expired sessions leave before
# budget sizing counts remaining sessions. A failed purge sets OPERATION_FAILED.
apply_trash_retention() {
  if [[ -n "$TRASH_KEEP_DAYS" || -n "$TRASH_MAX_SIZE" ]]; then
    local failed=false
    if [[ -n "$TRASH_KEEP_DAYS" ]]; then
      if ! purge_quarantine_sessions "older-than:$TRASH_KEEP_DAYS"; then
        failed=true
        OPERATION_FAILED=true
        RETENTION_FAILED=true
      fi
    fi
    if [[ -n "$TRASH_MAX_SIZE" ]]; then
      if ! purge_quarantine_sessions "max-size:$TRASH_MAX_SIZE"; then
        failed=true
        OPERATION_FAILED=true
        RETENTION_FAILED=true
      fi
    fi
    RESULT_REPORT_TEXT+=$'\n'"Retention failed: $failed"
    printf 'Retention failed: %s\n' "$failed"
    save_last_cleanup_report
  fi
}

# Run CMD directly, or through sudo when USE_SUDO (arg 1) is true. Every
# privileged operation goes through here so it is written once, not twice.
# Close cleaner.lock fd 9 so spawned external/privileged helpers cannot keep the lock held.
with_sudo() {
  local use_sudo="$1"
  shift
  if [[ "$use_sudo" = true ]]; then
    sudo "$@" 9>&-
  else
    "$@" 9>&-
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

# True when the closest existing ancestor directory of PATH lacks search (+x)
# permission, blocking unprivileged stat/lstat lookup of PATH.
path_lookup_blocked() {
  local cur="$1" parent
  while [[ "$cur" != "/" && -n "$cur" ]]; do
    parent=$(dirname -- "$cur") || return 1
    [[ "$parent" != "$cur" ]] || break
    cur="$parent"
    if [[ -e "$cur" || -L "$cur" ]]; then
      [[ -d "$cur" && ! -x "$cur" ]]
      return
    fi
  done
  return 1
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
      with_sudo true chown -R "$(id -u):$(id -g)" "$dest" || ok=false
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
# the private .hold marker that purge, --trash-keep-days, and --trash-max-size
# retention honor. The session's mtime is put back, so a hold never changes its age.
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
    echo -e "${GREEN}Held session $name; purges, --trash-keep-days, and --trash-max-size retention skip it until --release-session $name.${NC}"
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

# Atomically move a colliding non-symlink restore destination aside to a unique
# sibling backup path (<dest>.pre-restore-<session>[.N]). Returns 0 with
# RESTORE_BACKUP_PATH set, 2 on symlink refusal (never followed or moved), or 1
# on invalid path or move error.
_backup_restore_conflict() {
  local use_sudo="$1" dest="$2" session_name="$3"
  local clean_dest base cand suffix=0
  RESTORE_BACKUP_PATH=""
  clean_dest=$(strip_trailing_slashes "$dest")
  if [[ -z "$clean_dest" || "$clean_dest" == "/" ]]; then
    echo -e "${RED}Error: Refusing to back up unsafe restore destination '$dest'.${NC}" >&2
    return 1
  fi
  if with_sudo "$use_sudo" test -L "$clean_dest"; then
    echo -e "${RED}Error: Restore destination '$clean_dest' is a symlink. Conflict detected, skipping.${NC}" >&2
    return 2
  fi
  base="${clean_dest}.pre-restore-${session_name}"
  cand="$base"
  while path_present "$use_sudo" "$cand"; do
    suffix=$((suffix + 1))
    if [[ "$suffix" -gt 999 ]]; then
      echo -e "${RED}Error: Too many existing pre-restore backups beside '$clean_dest'.${NC}" >&2
      return 1
    fi
    cand="${base}.${suffix}"
  done
  if ! with_sudo "$use_sudo" mv -T -- "$clean_dest" "$cand"; then
    echo -e "${RED}Error: Failed to back up existing restore conflict '$clean_dest' to '$cand'.${NC}" >&2
    return 1
  fi
  RESTORE_BACKUP_PATH="$cand"
  echo "Backed up existing restore conflict '$clean_dest' to '$cand'."
  return 0
}

# Roll back leaf and newly created empty intermediate directory backups on a
# failed aged file restore, preserving any directory already holding restored files.
_rollback_aged_backups() {
  local use_sudo="$1" clean_root="$2" dest_parent="$3" dest_file="$4" leaf_backup="$5" dir_target="$6" dir_backup="$7"
  if [[ -n "$leaf_backup" ]] && ! path_present "$use_sudo" "$dest_file"; then
    if with_sudo "$use_sudo" mv -T -- "$leaf_backup" "$dest_file" 2>/dev/null; then
      echo "Rolled back pre-restore backup '$leaf_backup' to '$dest_file'." >&2
    else
      echo -e "${RED}Error: Failed to roll back pre-restore backup '$leaf_backup' to '$dest_file'.${NC}" >&2
    fi
  fi
  if [[ -n "$dir_backup" && -n "$dir_target" ]]; then
    local trim_dir="$dest_parent"
    while [[ -n "$trim_dir" && "$trim_dir" != "$clean_root" && "$trim_dir" != "/" ]]; do
      with_sudo "$use_sudo" rmdir -- "$trim_dir" 2>/dev/null || break
      [[ "$trim_dir" == "$dir_target" ]] && break
      trim_dir="${trim_dir%/*}"
    done
    if ! path_present "$use_sudo" "$dir_target"; then
      if with_sudo "$use_sudo" mv -T -- "$dir_backup" "$dir_target" 2>/dev/null; then
        echo "Rolled back pre-restore backup '$dir_backup' to '$dir_target'." >&2
      else
        echo -e "${RED}Error: Failed to roll back pre-restore backup '$dir_backup' to '$dir_target'.${NC}" >&2
      fi
    fi
  fi
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
    if ! latest=$(find "$quarantine_base" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n 1); then
      echo "Error: Failed to enumerate quarantine sessions." >&2
      exit 1
    fi
    if [[ -z "$latest" ]]; then
      echo -e "${RED}Error: No quarantined sessions found in '$quarantine_base'.${NC}" >&2
      exit 1
    fi
    restore_dir="$latest"
  else
    # Named session must be an immediate child of the base (same rule as purge).
    validate_quarantine_session_name "$target"
    restore_dir="$quarantine_base/$target"
    if [[ -L "$restore_dir" || ! -d "$restore_dir" ]]; then
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
  
  local session_name
  session_name=$(basename "$restore_dir")
  if [[ "$DRY_RUN_EXPLICIT" != true || "$JSON_OUTPUT" != true ]]; then
    echo -e "${BOLD}${BLUE}=== Restoring from Quarantine Session: ${session_name} ===${NC}"
  fi
  
  # Read metadata line by line
  # Format: TYPE|RELATIVE_PATH|ORIGINAL_PATH|USE_SUDO|UID|GID
  local type rel_path original_path use_sudo uid gid meta_line RESTORE_RECORD_ERROR=""
  local overall_success=true
  local matched_any=false
  local cnt_would_restore=0 cnt_already_restored=0 cnt_missing=0
  local cnt_unknown_type=0 cnt_conflict=0 cnt_invalid_record=0
  local cnt_would_backup_and_restore=0
  local -a json_rec_types=() json_rec_origs=() json_rec_rels=() json_rec_sudos=() json_rec_statuses=()
  # rel_paths actually moved back out of quarantine. Under --only, the metadata is
  # rewritten from this so every remaining record still points at a file that is
  # present in quarantine -- the same invariant the failed-move fix established.
  local -a restored_rels=()
  # Checkpoints atomically replace the pathname; this loop keeps its old inode.
  # shellcheck disable=SC2094
  while IFS= read -r meta_line || [[ -n "$meta_line" ]]; do
    IFS='|' read -r type rel_path original_path use_sudo uid gid _ <<< "$meta_line"
    trim_to type "$type"
    [[ -z "$type" || "$type" =~ ^# ]] && continue

    trim_to original_path "$original_path"
    # Leave every non-matching target quarantined, untouched.
    if [[ -n "${RESTORE_ONLY:-}" ]]; then
      if [[ "$RESTORE_ONLY_MODE" == --only-exact ]]; then
        [[ "$original_path" == "$RESTORE_ONLY" ]] || continue
      else
        [[ "$original_path" == *"$RESTORE_ONLY"* ]] || continue
      fi
    fi
    matched_any=true

    trim_to rel_path "$rel_path"
    trim_to use_sudo "$use_sudo"
    trim_to uid "${uid:-}"
    trim_to gid "${gid:-}"

    if ! validate_restore_record "$rel_path" "$original_path" "$use_sudo" "$uid" "$gid"; then
      if [[ "$DRY_RUN_EXPLICIT" == true ]]; then
        if [[ "$JSON_OUTPUT" == true ]]; then
          local rec_sudo="null"
          [[ "$use_sudo" == "true" || "$use_sudo" == "false" ]] && rec_sudo="$use_sudo"
          cnt_invalid_record=$((cnt_invalid_record + 1))
          json_rec_types+=("$type")
          json_rec_origs+=("$original_path")
          json_rec_rels+=("$rel_path")
          json_rec_sudos+=("$rec_sudo")
          json_rec_statuses+=("invalid_record")
        else
          printf 'invalid record  %s\n' "$original_path"
        fi
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
      local clean_prev_orig
      clean_prev_orig=$(strip_trailing_slashes "$original_path")
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
          if [[ "$BACKUP_CONFLICTS" == true && ! -L "$clean_prev_orig" && -n "$clean_prev_orig" && "$clean_prev_orig" != "/" ]]; then
            preview_status="would backup and restore"
          else
            preview_status="conflict"
          fi
        fi
      elif [[ "$type" == aged ]]; then
        local preview_hard_conflict=false preview_backup_conflict=false
        if [[ -L "$clean_prev_orig" ]]; then
          preview_hard_conflict=true
        elif [[ -e "$clean_prev_orig" && ! -d "$clean_prev_orig" ]]; then
          if [[ "$BACKUP_CONFLICTS" == true && -n "$clean_prev_orig" && "$clean_prev_orig" != "/" ]]; then
            preview_backup_conflict=true
          else
            preview_hard_conflict=true
          fi
        fi
        if [[ "$preview_hard_conflict" == true ]]; then
          preview_status="conflict"
        else
          stream_rc=""
          while IFS= read -r -d '' preview_file; do
            if [[ -z "$preview_file" ]]; then
              IFS= read -r -d '' stream_rc
              break
            fi
            preview_dest="$clean_prev_orig/${preview_file#"$src_path"/}"
            if [[ -L "$preview_dest" ]]; then
              preview_hard_conflict=true
            elif path_present false "$preview_dest"; then
              if [[ "$BACKUP_CONFLICTS" == true ]]; then
                preview_backup_conflict=true
              else
                preview_hard_conflict=true
              fi
            fi
            preview_parent="${preview_dest%/*}"
            while [[ "$preview_parent" != "$clean_prev_orig" && "$preview_parent" != / ]]; do
              if [[ -L "$preview_parent" ]]; then
                preview_hard_conflict=true
              elif [[ -e "$preview_parent" && ! -d "$preview_parent" ]]; then
                if [[ "$BACKUP_CONFLICTS" == true ]]; then
                  preview_backup_conflict=true
                else
                  preview_hard_conflict=true
                fi
              fi
              preview_parent="${preview_parent%/*}"
            done
          done < <(print0_with_status find "$src_path" -mindepth 1 \( -type f -o -type l \) -print0)
          if [[ "$stream_rc" != 0 ]]; then
            preview_status="missing"
          elif [[ "$preview_hard_conflict" == true ]]; then
            preview_status="conflict"
          elif [[ "$preview_backup_conflict" == true ]]; then
            preview_status="would backup and restore"
          fi
        fi
      fi
      if [[ "$JSON_OUTPUT" == true ]]; then
        local json_status="would_restore"
        case "$preview_status" in
          "would restore")
            json_status="would_restore"
            cnt_would_restore=$((cnt_would_restore + 1))
            ;;
          "would backup and restore")
            json_status="would_backup_and_restore"
            cnt_would_backup_and_restore=$((cnt_would_backup_and_restore + 1))
            ;;
          "already restored")
            json_status="already_restored"
            cnt_already_restored=$((cnt_already_restored + 1))
            ;;
          "missing")
            json_status="missing"
            cnt_missing=$((cnt_missing + 1))
            ;;
          "unknown type")
            json_status="unknown_type"
            cnt_unknown_type=$((cnt_unknown_type + 1))
            ;;
          "conflict")
            json_status="conflict"
            cnt_conflict=$((cnt_conflict + 1))
            ;;
        esac
        json_rec_types+=("$type")
        json_rec_origs+=("$original_path")
        json_rec_rels+=("$rel_path")
        json_rec_sudos+=("$use_sudo")
        json_rec_statuses+=("$json_status")
      else
        printf '%s  %s\n' "$preview_status" "$original_path"
      fi
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
      if [[ "$type" == "full" ]]; then
        local already_restored=false
        if path_present false "$original_path"; then
          already_restored=true
        elif [[ "$use_sudo" = true ]]; then
          if ! ensure_sudo; then
            echo -e "${RED}Error: sudo authentication failed; '$original_path' was not restored.${NC}" >&2
            overall_success=false
            log_restore_outcome "$restore_dir" "$original_path" failed
            continue
          fi
          if path_present true "$original_path"; then
            already_restored=true
          fi
        fi
        if [[ "$already_restored" == true ]]; then
          echo -e "Note: '$original_path' is already restored; dropping its stale record."
          restored_rels+=("$rel_path")
          log_restore_outcome "$restore_dir" "$original_path" success
          continue
        fi
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
      local full_backup="" RESTORE_BACKUP_PATH="" clean_full_orig=""
      clean_full_orig=$(strip_trailing_slashes "$original_path")
      if path_present "$use_sudo" "$original_path"; then
        if [[ "$BACKUP_CONFLICTS" != true ]]; then
          echo -e "${RED}Error: Restore destination '$original_path' already exists. Conflict detected, skipping.${NC}" >&2
          overall_success=false
          log_restore_outcome "$restore_dir" "$original_path" conflict
          continue
        fi
        if with_sudo "$use_sudo" test -L "$clean_full_orig"; then
          echo -e "${RED}Error: Restore destination '$original_path' is a symlink. Conflict detected, skipping.${NC}" >&2
          overall_success=false
          log_restore_outcome "$restore_dir" "$original_path" conflict
          continue
        fi
        if ! move_has_room "$src_path" "$use_sudo" "$(dirname "$clean_full_orig")" "$use_sudo" ""; then
          echo -e "${RED}Error: Not enough free space to restore '$original_path' (needs $(format_bytes "$MOVE_NEED_BYTES"), $(format_bytes "$MOVE_AVAIL_BYTES") free); kept in quarantine.${NC}" >&2
          overall_success=false
          log_restore_outcome "$restore_dir" "$original_path" failed
          continue
        fi
        local backup_rc=0
        _backup_restore_conflict "$use_sudo" "$clean_full_orig" "$session_name" || backup_rc=$?
        if [[ "$backup_rc" -ne 0 ]]; then
          overall_success=false
          if [[ "$backup_rc" -eq 2 ]]; then
            log_restore_outcome "$restore_dir" "$original_path" conflict
          else
            log_restore_outcome "$restore_dir" "$original_path" failed
          fi
          continue
        fi
        full_backup="$RESTORE_BACKUP_PATH"
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
      if [[ "$success" == false && -n "$full_backup" ]] && ! path_present "$use_sudo" "$clean_full_orig"; then
        if with_sudo "$use_sudo" mv -T -- "$full_backup" "$clean_full_orig" 2>/dev/null; then
          echo "Rolled back pre-restore backup '$full_backup' to '$clean_full_orig'." >&2
        else
          echo -e "${RED}Error: Failed to roll back pre-restore backup '$full_backup' to '$clean_full_orig'.${NC}" >&2
        fi
      fi
    elif [[ "$type" == "aged" ]]; then
      local clean_aged_orig="" aged_root_backup="" RESTORE_BACKUP_PATH=""
      clean_aged_orig=$(strip_trailing_slashes "$original_path")
      if with_sudo "$use_sudo" test -L "$clean_aged_orig"; then
        echo -e "${RED}Error: Restore destination '$original_path' is a symlink. Conflict detected, skipping.${NC}" >&2
        overall_success=false
        log_restore_outcome "$restore_dir" "$original_path" conflict
        continue
      elif with_sudo "$use_sudo" test -e "$clean_aged_orig" && ! with_sudo "$use_sudo" test -d "$clean_aged_orig"; then
        if [[ "$BACKUP_CONFLICTS" != true ]]; then
          echo -e "${RED}Error: Restore destination '$original_path' exists and is not a directory. Conflict detected, skipping.${NC}" >&2
          overall_success=false
          log_restore_outcome "$restore_dir" "$original_path" conflict
          continue
        fi
        if ! move_has_room "$src_path" "$use_sudo" "$(dirname "$clean_aged_orig")" "$use_sudo" ""; then
          echo -e "${RED}Error: Not enough free space to restore '$original_path' (needs $(format_bytes "$MOVE_NEED_BYTES"), $(format_bytes "$MOVE_AVAIL_BYTES") free); kept in quarantine.${NC}" >&2
          overall_success=false
          log_restore_outcome "$restore_dir" "$original_path" failed
          continue
        fi
        local root_backup_rc=0
        _backup_restore_conflict "$use_sudo" "$clean_aged_orig" "$session_name" || root_backup_rc=$?
        if [[ "$root_backup_rc" -ne 0 ]]; then
          overall_success=false
          if [[ "$root_backup_rc" -eq 2 ]]; then
            log_restore_outcome "$restore_dir" "$original_path" conflict
          else
            log_restore_outcome "$restore_dir" "$original_path" failed
          fi
          continue
        fi
        aged_root_backup="$RESTORE_BACKUP_PATH"
      fi
      # shellcheck disable=SC2016
      if ! with_sudo "$use_sudo" bash -c 'umask 077; mkdir -p -- "$1"' _ "$clean_aged_orig"; then
        success=false
        if [[ -n "$aged_root_backup" ]] && ! path_present "$use_sudo" "$clean_aged_orig"; then
          if with_sudo "$use_sudo" mv -T -- "$aged_root_backup" "$clean_aged_orig" 2>/dev/null; then
            echo "Rolled back pre-restore backup '$aged_root_backup' to '$clean_aged_orig'." >&2
          else
            echo -e "${RED}Error: Failed to roll back pre-restore backup '$aged_root_backup' to '$clean_aged_orig'.${NC}" >&2
          fi
        fi
      else
        if ! move_has_room "$src_path" "$use_sudo" "$clean_aged_orig" "$use_sudo" ""; then
          echo -e "${RED}Error: Not enough free space to restore '$original_path' (needs $(format_bytes "$MOVE_NEED_BYTES"), $(format_bytes "$MOVE_AVAIL_BYTES") free); kept in quarantine.${NC}" >&2
          success=false
          if [[ -n "$aged_root_backup" ]] \
             && with_sudo "$use_sudo" rmdir -- "$clean_aged_orig" 2>/dev/null \
             && with_sudo "$use_sudo" mv -T -- "$aged_root_backup" "$clean_aged_orig" 2>/dev/null; then
            echo "Rolled back pre-restore backup '$aged_root_backup' to '$clean_aged_orig'." >&2
          fi
        else
          stream_rc=""
          while IFS= read -r -d '' file; do
            if [[ -z "$file" ]]; then
              IFS= read -r -d '' stream_rc
              break
            fi
            local file_rel="${file#"$src_path"/}"
            local dest_file="$clean_aged_orig/$file_rel"
            local dest_parent check_dir="$clean_aged_orig" rel_dir part path_conflict=false
            local leaf_backup="" dir_backup="" dir_backup_target="" dir_backup_rc=0 leaf_backup_rc=0
            dest_parent=$(dirname "$dest_file")
            if [[ "$dest_parent" != "$clean_aged_orig" ]]; then
              rel_dir="${file_rel%/*}"
              while [[ -n "$rel_dir" ]]; do
                part="${rel_dir%%/*}"
                check_dir="$check_dir/$part"
                if with_sudo "$use_sudo" test -L "$check_dir"; then
                  echo -e "${RED}Error: Restore destination path '$check_dir' is a symlink. Conflict detected, skipping '$dest_file'.${NC}" >&2
                  path_conflict=true
                  break
                elif with_sudo "$use_sudo" test -e "$check_dir" && ! with_sudo "$use_sudo" test -d "$check_dir"; then
                  if [[ "$BACKUP_CONFLICTS" == true ]]; then
                    dir_backup_rc=0
                    _backup_restore_conflict "$use_sudo" "$check_dir" "$session_name" || dir_backup_rc=$?
                    if [[ "$dir_backup_rc" -ne 0 ]]; then
                      path_conflict=true
                      break
                    fi
                    dir_backup="$RESTORE_BACKUP_PATH"
                    dir_backup_target="$check_dir"
                    # shellcheck disable=SC2016
                    if ! with_sudo "$use_sudo" bash -c 'umask 077; mkdir -p -- "$1"' _ "$check_dir"; then
                      with_sudo "$use_sudo" mv -T -- "$dir_backup" "$check_dir" 2>/dev/null || true
                      dir_backup=""
                      dir_backup_target=""
                      path_conflict=true
                      break
                    fi
                  else
                    echo -e "${RED}Error: Restore destination path '$check_dir' exists and is not a directory. Conflict detected, skipping '$dest_file'.${NC}" >&2
                    path_conflict=true
                    break
                  fi
                fi
                [[ "$rel_dir" == "$part" ]] && break
                rel_dir="${rel_dir#*/}"
              done
            fi
            if [[ "$path_conflict" = true ]]; then
              success=false
              had_conflict=true
              _rollback_aged_backups "$use_sudo" "$clean_aged_orig" "$check_dir" "$dest_file" "" "$dir_backup_target" "$dir_backup"
              continue
            fi
            # shellcheck disable=SC2016
            if ! with_sudo "$use_sudo" bash -c 'umask 077; mkdir -p -- "$1"' _ "$dest_parent"; then
              success=false
              _rollback_aged_backups "$use_sudo" "$clean_aged_orig" "$dest_parent" "$dest_file" "" "$dir_backup_target" "$dir_backup"
              continue
            fi
            if path_present "$use_sudo" "$dest_file"; then
              if [[ "$BACKUP_CONFLICTS" != true ]]; then
                echo -e "${RED}Error: Restore destination file '$dest_file' already exists. Conflict detected, skipping.${NC}" >&2
                success=false
                had_conflict=true
                _rollback_aged_backups "$use_sudo" "$clean_aged_orig" "$dest_parent" "$dest_file" "" "$dir_backup_target" "$dir_backup"
                continue
              fi
              if with_sudo "$use_sudo" test -L "$dest_file"; then
                echo -e "${RED}Error: Restore destination file '$dest_file' is a symlink. Conflict detected, skipping.${NC}" >&2
                success=false
                had_conflict=true
                _rollback_aged_backups "$use_sudo" "$clean_aged_orig" "$dest_parent" "$dest_file" "" "$dir_backup_target" "$dir_backup"
                continue
              fi
              leaf_backup_rc=0
              _backup_restore_conflict "$use_sudo" "$dest_file" "$session_name" || leaf_backup_rc=$?
              if [[ "$leaf_backup_rc" -ne 0 ]]; then
                success=false
                [[ "$leaf_backup_rc" -eq 2 ]] && had_conflict=true
                _rollback_aged_backups "$use_sudo" "$clean_aged_orig" "$dest_parent" "$dest_file" "" "$dir_backup_target" "$dir_backup"
                continue
              fi
              leaf_backup="$RESTORE_BACKUP_PATH"
            fi
            if with_sudo "$use_sudo" mv "$file" "$dest_file"; then
              with_sudo "$use_sudo" chown -h "$uid:$gid" "$dest_file" 2>/dev/null || true
            else
              success=false
              _rollback_aged_backups "$use_sudo" "$clean_aged_orig" "$dest_parent" "$dest_file" "$leaf_backup" "$dir_backup_target" "$dir_backup"
            fi
          done < <(print0_with_status find "$src_path" -mindepth 1 \( -type f -o -type l \) -print0)
          [[ "$stream_rc" == 0 ]] || success=false
          if [[ "$success" == false && -n "$aged_root_backup" ]]; then
            with_sudo "$use_sudo" find "$clean_aged_orig" -mindepth 1 -depth -type d -empty -delete 2>/dev/null || true
            if with_sudo "$use_sudo" rmdir -- "$clean_aged_orig" 2>/dev/null; then
              if with_sudo "$use_sudo" mv -T -- "$aged_root_backup" "$clean_aged_orig" 2>/dev/null; then
                echo "Rolled back pre-restore backup '$aged_root_backup' to '$clean_aged_orig'." >&2
              else
                echo -e "${RED}Error: Failed to roll back pre-restore backup '$aged_root_backup' to '$clean_aged_orig'.${NC}" >&2
              fi
            fi
          fi
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
        trim_to checkpoint_rel "$checkpoint_rel"
        if [[ "$checkpoint_rel" == "$rel_path" ]]; then
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
    if [[ "$JSON_OUTPUT" == true ]]; then
      local held_json="false" mtime_json="null" has_sel=false sel_mode_val="" rec_idx=0
      session_is_held "$restore_dir" && held_json="true"
      [[ "$session_mtime" =~ ^[[:digit:]]+$ ]] && mtime_json="$session_mtime"
      if [[ -n "${RESTORE_ONLY:-}" ]]; then
        has_sel=true
        sel_mode_val="$RESTORE_ONLY_MODE"
      fi
      printf '{"session":"%s","session_mtime":%s,"held":%s,"selector":%s,"selector_mode":%s' \
        "$(json_escape "$session_name")" \
        "$mtime_json" \
        "$held_json" \
        "$(_json_str_or_null "$has_sel" "${RESTORE_ONLY:-}")" \
        "$(_json_str_or_null "$has_sel" "$sel_mode_val")"
      if [[ "$BACKUP_CONFLICTS" == true ]]; then
        printf ',"backup_conflicts":true'
      fi
      printf ',"records":['
      for rec_idx in "${!json_rec_statuses[@]}"; do
        [[ "$rec_idx" -eq 0 ]] || printf ','
        printf '{"type":"%s","original_path":"%s","relative_path":"%s","use_sudo":%s,"status":"%s"}' \
          "$(json_escape "${json_rec_types[$rec_idx]}")" \
          "$(json_escape "${json_rec_origs[$rec_idx]}")" \
          "$(json_escape "${json_rec_rels[$rec_idx]}")" \
          "${json_rec_sudos[$rec_idx]}" \
          "${json_rec_statuses[$rec_idx]}"
      done
      printf '],"counts":{"would_restore":%d,"already_restored":%d,"missing":%d,"unknown_type":%d,"conflict":%d,"invalid_record":%d' \
        "$cnt_would_restore" "$cnt_already_restored" "$cnt_missing" "$cnt_unknown_type" "$cnt_conflict" "$cnt_invalid_record"
      if [[ "$BACKUP_CONFLICTS" == true ]]; then
        printf ',"would_backup_and_restore":%d' "$cnt_would_backup_and_restore"
      fi
      printf '}}\n'
    else
      echo "Dry-run: nothing restored."
    fi
    return 0
  fi

  # Keep metadata aligned with the files still in quarantine. This is required
  # after a partial failure as well as --only: successful sibling restores have
  # already moved out and must not poison a later retry as missing sources.
  local -a retained=()
  if [[ ( "$overall_success" != true || -n "${RESTORE_ONLY:-}" ) && ${#restored_rels[@]} -gt 0 ]]; then
    local -A restored_seen=()
    local restored_empty=false line rp r
    for r in "${restored_rels[@]}"; do
      if [[ -z "$r" ]]; then
        restored_empty=true
      else
        restored_seen["$r"]=1
      fi
    done
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" ]] && continue
      IFS='|' read -r _ rp _ <<< "$line"
      trim_to rp "$rp"
      if [[ ( -z "$rp" && "$restored_empty" == true ) || ( -n "$rp" && -n "${restored_seen[$rp]+set}" ) ]]; then
        continue
      fi
      retained+=("$line")
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
  if [[ "${NO_SUDO:-false}" == true ]]; then
    SUDO_AUTH_FAILED=true
    return 1
  fi
  if [[ "$SUDO_AUTH_FAILED" == true ]]; then
    return 1
  fi
  if sudo -n true 2>/dev/null 9>&-; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    SUDO_AUTH_FAILED=true
    return 1
  fi
  echo -e "${YELLOW}Target(s) require root privileges. Please authenticate for sudo:${NC}"
  if ! sudo -v 9>&-; then
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
  if [[ "$TARGET_EXCLUDE_ACTIVE" == true ]]; then
    if [[ -z $(with_sudo "$use_sudo" find "$target_path" "${EXCLUDE_FIND_ARGS[@]}" -print -quit 2>/dev/null) ]]; then
      return 1
    fi
  fi

  local -a mtime_args=()
  if has_positive_age "$age_days"; then
    mtime_args=(-mtime "+$age_days")
  fi

  if path_is_real_dir "$use_sudo" "$target_path" && { has_positive_age "$age_days" || [[ "$TARGET_EXCLUDE_ACTIVE" == true ]]; }; then
    # Exclusions switch MIN_AGE_DAYS=0 directories to file-by-file cleanup, so only
    # eligible files or symlinks inside make the target cleanable.
    [[ -n $(with_sudo "$use_sudo" find "$target_path" -mindepth 1 "${EXCLUDE_FIND_ARGS[@]}" \( -type f -o -type l \) "${mtime_args[@]}" -print -quit 2>/dev/null) ]] && return 0
    return 1
  elif has_positive_age "$age_days"; then
    # Single file or symlink
    [[ -n $(with_sudo "$use_sudo" find "$target_path" -mtime +"$age_days" -print -quit 2>/dev/null) ]] && return 0
    return 1
  fi

  path_present "$use_sudo" "$target_path"
}

# List the same eligible files/symlinks as has_matching_files; whole targets stay compact.
print_matching_paths() {
  local target_path="$1" age_days="$2" use_sudo="$3" match_path
  local -a mtime_args=()
  if has_positive_age "$age_days"; then
    mtime_args=(-mtime "+$age_days")
  fi
  {
    if path_is_real_dir "$use_sudo" "$target_path" && { has_positive_age "$age_days" || [[ "$TARGET_EXCLUDE_ACTIVE" == true ]]; }; then
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
  if [[ "$TARGET_EXCLUDE_ACTIVE" == true ]]; then
    if [[ -z $(with_sudo "$use_sudo" find "$target_path" "${EXCLUDE_FIND_ARGS[@]}" -print -quit 2>/dev/null) ]]; then
      echo 0
      return
    fi
  fi

  if path_is_real_dir "$use_sudo" "$target_path"; then
    # Sum size of files/symlinks older than age_days within the directory
    # Exclusions require file-by-file handling even when age_days is 0.
    if [[ "$TARGET_EXCLUDE_ACTIVE" == true ]]; then
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
# actions, missing paths, and idle-recent trees. Exclusions are active when TARGET_EXCLUDE_ACTIVE is true.
measure_eligible_size() {
  local target_path="$1" age_days="$2" use_sudo="$3" size_bytes should_clean=false
  size_bytes=$(get_size_bytes "$target_path" "$age_days" "$use_sudo")
  if has_positive_age "$age_days" || [[ "$TARGET_EXCLUDE_ACTIVE" == true ]]; then
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

# Format bytes to human readable format using pure-bash arithmetic (no awk forks;
# extracted standalone by tests via awk '/^format_bytes\(\)/,/^\}/').
format_bytes() {
  local bytes="${1:-}"
  if [[ -z "$bytes" || "$bytes" -eq 0 ]]; then
    echo "0 B"
    return
  fi

  local -a units=("B" "KB" "MB" "GB" "TB")
  local unit_idx=0 whole=$bytes frac=0 q r num rem

  while (( whole >= 1024 && unit_idx < 4 )); do
    q=$((whole / 1024))
    r=$((whole % 1024))
    num=$((r * 100 + frac))
    frac=$((num / 1024))
    rem=$((num % 1024))
    if (( rem > 512 || (rem == 512 && (frac % 2) == 1) )); then
      frac=$((frac + 1))
      if (( frac >= 100 )); then
        frac=$((frac - 100))
        q=$((q + 1))
      fi
    fi
    whole=$q
    unit_idx=$((unit_idx + 1))
  done

  if (( unit_idx == 0 || frac == 0 )); then
    printf '%s %s\n' "$whole" "${units[$unit_idx]}"
  elif (( frac < 10 )); then
    printf '%s.0%s %s\n' "$whole" "$frac" "${units[$unit_idx]}"
  else
    printf '%s.%s %s\n' "$whole" "$frac" "${units[$unit_idx]}"
  fi
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
      local _sum_risk=0
      _risk_to_int_to _sum_risk "${parsed_risks[$i]}" || _sum_risk=0
      case "$_sum_risk" in
        1) safe_b=$((safe_b + bytes)) ;;
        2) med_b=$((med_b + bytes)) ;;
        3) dang_b=$((dang_b + bytes)) ;;
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
      if action_is_user_level "${parsed_cmds[$i]:-}"; then
        size_label="(size at run time)"
      elif [[ "${parsed_cmds[$i]:-}" == action:* ]]; then
        age_note+=" (cache size; the action may keep part)"
      fi
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
  _send_desktop_notification "${notify_args[@]}" "linux-cleaner" "$msg"
}

# Print one user unit's is-enabled state (first line, trimmed); empty without systemctl.
user_unit_state() {
  command -v systemctl >/dev/null 2>&1 || return 0
  local state
  if command -v timeout >/dev/null 2>&1; then
    state=$(timeout 5 systemctl --user is-enabled "$1" 2>/dev/null || true)
  else
    state=$(systemctl --user is-enabled "$1" 2>/dev/null || true)
  fi
  trim "${state%%$'\n'*}"
}

# Parse a systemd EnvironmentFile value: trim outer whitespace and strip at most
# one matching outer '...' or "..." pair while preserving embedded quotes.
unquote_env_value() {
  local _uenv_out="$1" _uenv_val
  trim_to _uenv_val "$2"
  if [[ ${#_uenv_val} -ge 2 ]]; then
    if [[ ( "${_uenv_val:0:1}" == '"' && "${_uenv_val: -1}" == '"' ) \
       || ( "${_uenv_val:0:1}" == "'" && "${_uenv_val: -1}" == "'" ) ]]; then
      _uenv_val="${_uenv_val:1:${#_uenv_val}-2}"
      trim_to _uenv_val "$_uenv_val"
    fi
  fi
  printf -v "$_uenv_out" '%s' "$_uenv_val"
}

# Read requested LINUX_CLEANER_* entries from a systemd EnvironmentFile (last wins).
read_systemd_env_file() {
  local _rs_file="$1" _rs_line _rs_key _rs_val
  local -n _rs_out="$2"
  while IFS= read -r _rs_line || [[ -n "$_rs_line" ]]; do
    trim_to _rs_line "$_rs_line"
    [[ "$_rs_line" == *=* ]] || continue
    _rs_key="${_rs_line%%=*}"
    [[ "$_rs_key" =~ ^LINUX_CLEANER_[ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_]+$ ]] || continue
    [[ -n "${_rs_out[$_rs_key]+set}" ]] || continue
    unquote_env_value _rs_val "${_rs_line#*=}"
    _rs_out["$_rs_key"]="$_rs_val"
  done < "$_rs_file"
}

# A manual run ignores the env file the daily timer reads, so its risk can differ
# from the timer's; name the timer's state and risk. Units stay silent: systemd sets
# JOURNAL_STREAM to the device:inode of a journal-bound stderr. Terminals inherit the
# variable too (INVOCATION_ID as well), so only a matching stderr counts.
print_timer_note() {
  [[ "$QUIET" != true ]] || return 0
  if [[ -n "${JOURNAL_STREAM:-}" ]] \
     && [[ "$(stat -L -c '%d:%i' "/proc/$$/fd/2" 2>/dev/null || true)" == "$JOURNAL_STREAM" ]]; then
    return 0
  fi
  local state env_file="$HOME/.config/linux-cleaner/env" risk=safe env_label
  local -A timer_note_vars=([LINUX_CLEANER_RISK]="")
  state=$(user_unit_state linux-cleaner-clean.timer)
  [[ -z "$state" || "$state" == not-found ]] && return 0
  if [[ ! -e "$env_file" ]]; then
    env_label=none
  elif [[ ! -f "$env_file" || ! -r "$env_file" ]]; then
    risk=unknown
    env_label="$env_file (not readable)"
  else
    env_label="$env_file"
    # Like systemd's EnvironmentFile, the last assignment wins.
    read_systemd_env_file "$env_file" timer_note_vars
    risk="${timer_note_vars[LINUX_CLEANER_RISK]}"
    [[ -z "$risk" ]] && risk=safe
  fi
  printf '%s\n\n' "Daily timer: ${state} risk=${risk} env=${env_label}"
}

# Point a confirmed manual cleanup at the installed-but-disabled daily timer.
suggest_daily_timer() {
  [[ "${FORCE:-false}" == false && "${QUIET:-false}" == false && "${JSON_OUTPUT:-false}" == false && "${OPERATION_FAILED:-false}" == false ]] || return 0
  [[ "${result_cleaned:-0}" -eq 0 ]] && return 0
  local state
  state=$(user_unit_state linux-cleaner-clean.timer)
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
  local quarantine_base="$HOME/.cache/linux-cleaner/quarantine" quarantine_bytes=0 q_sessions=0 q_held=0
  local -a quarantine_metrics=() q_session_metrics=()
  if [[ -e "$quarantine_base" || -L "$quarantine_base" ]]; then
    if [[ -L "$quarantine_base" || ! -d "$quarantine_base" ]]; then
      echo "Warning: could not measure quarantine size at '$quarantine_base'; omitting linux_cleaner_quarantine_bytes." >&2
      quarantine_bytes=""
      q_sessions=""
      q_held=""
    else
      if ! quarantine_bytes=$(quarantine_size_bytes "$quarantine_base" 2>/dev/null); then
        echo "Warning: could not measure quarantine size at '$quarantine_base'; omitting linux_cleaner_quarantine_bytes." >&2
        quarantine_bytes=""
      fi
      local q_session="" q_stream_rc="" q_sessions_cnt=0 q_held_cnt=0
      while IFS= read -r -d '' q_session; do
        if [[ -z "$q_session" ]]; then
          IFS= read -r -d '' q_stream_rc
          break
        fi
        q_sessions_cnt=$((q_sessions_cnt + 1))
        session_is_held "$q_session" && q_held_cnt=$((q_held_cnt + 1))
      done < <(print0_with_status find "$quarantine_base" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
      if [[ "$q_stream_rc" != 0 ]]; then
        echo "Warning: could not enumerate quarantine sessions at '$quarantine_base'; omitting linux_cleaner_quarantine_sessions and linux_cleaner_quarantine_held_sessions." >&2
        q_sessions=""
        q_held=""
      else
        q_sessions="$q_sessions_cnt"
        q_held="$q_held_cnt"
      fi
    fi
  fi
  if [[ -n "$quarantine_bytes" ]]; then
    quarantine_metrics=(
      "# HELP linux_cleaner_quarantine_bytes Current quarantine size in bytes."
      "# TYPE linux_cleaner_quarantine_bytes gauge"
      "linux_cleaner_quarantine_bytes ${quarantine_bytes}"
    )
  fi
  if [[ -n "$q_sessions" && -n "$q_held" ]]; then
    q_session_metrics=(
      "# HELP linux_cleaner_quarantine_sessions Current number of quarantine sessions."
      "# TYPE linux_cleaner_quarantine_sessions gauge"
      "linux_cleaner_quarantine_sessions ${q_sessions}"
      "# HELP linux_cleaner_quarantine_held_sessions Current number of held quarantine sessions."
      "# TYPE linux_cleaner_quarantine_held_sessions gauge"
      "linux_cleaner_quarantine_held_sessions ${q_held}"
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
    "${quarantine_metrics[@]}" \
    "${q_session_metrics[@]}"; then
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
  local proc cmdline_pat pid query_status
  local -a proc_list
  IFS=',' read -r -a proc_list <<< "$procs"
  for proc in "${proc_list[@]}"; do
    trim_to proc "$proc"
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
      trim_to cmdline_pat "${proc#cmdline:}"
      pid=$(_cmdline_match "$cmdline_pat") || query_status=$?
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

# Map ASCII risk level (safe, medium, danger, dangerous) to 1..3 in-process
# (tr_TR.UTF-8 safe: explicit ASCII brackets avoid dotted/dotless-I collation).
# Pass an empty destination variable name to validate without assigning.
_risk_to_int_to() {
  case "$2" in
    [sS][aA][fF][eE]) [[ -z "$1" ]] || printf -v "$1" '%s' 1 ;;
    [mM][eE][dD][iI][uU][mM]) [[ -z "$1" ]] || printf -v "$1" '%s' 2 ;;
    [dD][aA][nN][gG][eE][rR]|[dD][aA][nN][gG][eE][rR][oO][uU][sS]) [[ -z "$1" ]] || printf -v "$1" '%s' 3 ;;
    *) return 1 ;;
  esac
}

risk_to_int() {
  local _rti_val=""
  if _risk_to_int_to _rti_val "$1"; then
    printf '%s\n' "$_rti_val"
    return 0
  fi
  echo -e "${RED}${2:-}Error: Unknown risk level '$1'. Valid levels are: safe, medium, danger.${NC}" >&2
  exit 1
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
    flatpak_unused) echo "flatpak" ;;
    *) echo "" ;;
  esac
}

# True when a predefined action runs as the invoking user without sudo and
# measures reclaimed bytes from filesystem free-space delta at run time.
action_is_user_level() {
  case "${1:-}" in
    action:uv_cache_prune|action:pnpm_store_prune|action:hf_cache_prune|action:nix_store_gc|action:flatpak_unused) return 0 ;;
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
    "$@" 9>&-
    return
  fi
  local rc=0 started elapsed_us elapsed_s
  started=$(now_us)
  local -a timeout_mode=()
  # On a terminal, stay in its process group so Ctrl-C still reaches the action.
  [[ -t 0 ]] && timeout_mode=(--foreground)
  timeout "${timeout_mode[@]}" --kill-after=10 "$ACTION_TIMEOUT" "$@" 9>&- || rc=$?
  # 124/137 also come from an action's own status or an unrelated SIGKILL (OOM).
  # Microseconds: whole SECONDS ticks would call a 0.6 s exit a 1 s timeout.
  # Compare whole elapsed seconds as decimal text so large ACTION_TIMEOUT values
  # never overflow ACTION_TIMEOUT * 1000000 in 64-bit shell arithmetic.
  elapsed_us=$(( $(now_us) - started ))
  (( elapsed_us < 0 )) && elapsed_us=0
  elapsed_s=$(( elapsed_us / 1000000 ))
  # shellcheck disable=SC2071
  if [[ ( "$rc" -eq 124 || "$rc" -eq 137 ) ]] && \
     [[ ${#elapsed_s} -gt ${#ACTION_TIMEOUT} || \
        ( ${#elapsed_s} -eq ${#ACTION_TIMEOUT} && ( "$elapsed_s" > "$ACTION_TIMEOUT" || "$elapsed_s" == "$ACTION_TIMEOUT" ) ) ]]; then
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
    action:flatpak_unused) echo "flatpak uninstall --user --unused --assumeyes --noninteractive" ;;
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

_json_str_or_null() {
  local present="$1" val="$2" esc=""
  if [[ "$present" != true ]]; then
    printf 'null'
  else
    json_escape "$val" esc
    printf '"%s"' "$esc"
  fi
}

# Resolve config origin label ("XDG", "/etc", "checkout", or "explicit") for a
# config path using CONFIG_CANDIDATES ordering without clobbering callers.
resolve_config_source() {
  local cfg_path="$1" out_var="$2"
  local -a saved_candidates=("${CONFIG_CANDIDATES[@]}") cfg_labels=(XDG /etc checkout)
  local i resolved_src="explicit"
  set_default_config_candidates || { CONFIG_CANDIDATES=("${saved_candidates[@]}"); return 1; }
  for i in 0 1 2; do
    if [[ "$cfg_path" == "${CONFIG_CANDIDATES[i]}" ]]; then
      resolved_src="${cfg_labels[i]}"
      break
    fi
  done
  CONFIG_CANDIDATES=("${saved_candidates[@]}")
  printf -v "$out_var" '%s' "$resolved_src"
}

run_check_config() {
  if [[ "$JSON_OUTPUT" != true ]]; then
    validate_config_file
    return $?
  fi

  local cfg_source="explicit" valid_json="false" status_str="ok"
  local targets_cnt=0 protect_cnt=0 rc=0
  local has_err=false err_msg="" err_file="" err_line="" has_err_file=false has_err_line=false
  local -a include_list=() searched_list=("${CHECK_CONFIG_SEARCHED[@]}")
  local item first=true esc="" err_line_json="null"

  resolve_config_source "$CONFIG_FILE" cfg_source || return 1

  if [[ "$CHECK_CONFIG_PRE_STATUS" == "not_found" || "$CHECK_CONFIG_PRE_STATUS" == "not_readable" ]]; then
    status_str="$CHECK_CONFIG_PRE_STATUS"
    has_err=true
    err_msg="$CHECK_CONFIG_PRE_ERROR"
    has_err_file=true
    err_file="$CONFIG_FILE"
    rc=1
  else
    _CFG_SUPPRESS_STDERR=true
    if validate_config_file >/dev/null; then
      valid_json="true"
      status_str="ok"
      targets_cnt="${_CFG_LAST_TARGET_COUNT:-0}"
      protect_cnt="${_CFG_LAST_PROTECT_COUNT:-0}"
    else
      status_str="invalid"
      has_err=true
      err_msg="$_CFG_LAST_ERROR"
      err_file="${_CFG_LAST_ERROR_FILE:-$CONFIG_FILE}"
      has_err_file=true
      if [[ -n "$_CFG_LAST_ERROR_LINE" && "$_CFG_LAST_ERROR_LINE" =~ ^[0-9]+$ ]]; then
        has_err_line=true
        err_line="$_CFG_LAST_ERROR_LINE"
      fi
      rc=1
    fi
    _CFG_SUPPRESS_STDERR=false
    include_list=("${_CFG_WALKED_FILES[@]}")
  fi

  [[ "$has_err_line" == true ]] && err_line_json="$err_line"
  printf '{"valid":%s,"status":"%s","config_file":"%s","source":"%s","targets_count":%d,"protect_count":%d,"include_files":[' \
    "$valid_json" "$status_str" "$(json_escape "$CONFIG_FILE")" "$(json_escape "$cfg_source")" "$targets_cnt" "$protect_cnt"
  first=true
  for item in "${include_list[@]}"; do
    [[ "$first" == true ]] || printf ','
    first=false
    json_escape "$item" esc
    printf '"%s"' "$esc"
  done
  printf '],"searched":['
  first=true
  for item in "${searched_list[@]}"; do
    [[ "$first" == true ]] || printf ','
    first=false
    json_escape "$item" esc
    printf '"%s"' "$esc"
  done
  printf '],"error":%s,"error_file":%s,"error_line":%s}\n' \
    "$(_json_str_or_null "$has_err" "$err_msg")" \
    "$(_json_str_or_null "$has_err_file" "$err_file")" \
    "$err_line_json"
  return "$rc"
}

# Collect startup-fatal scheduler configuration problems from an associative array
# of LINUX_CLEANER_* variables (already trimmed/unquoted by read_systemd_env_file)
# into _out_problems. Shared by daily_timer_plan and monitor.env in run_doctor.
_collect_scheduler_env_problems() {
  local -n _sched_vars="$1"
  local _cfg_base="$2"
  local -n _out_problems="$3"

  local _risk="${_sched_vars[LINUX_CLEANER_RISK]:-}"
  local _cfg="${_sched_vars[LINUX_CLEANER_CONFIG]:-}"
  local _only="${_sched_vars[LINUX_CLEANER_ONLY_PATH]:-}"
  local _keep="${_sched_vars[LINUX_CLEANER_TRASH_KEEP_DAYS]:-}"
  local _max_size="${_sched_vars[LINUX_CLEANER_TRASH_MAX_SIZE]:-}"
  local _log="${_sched_vars[LINUX_CLEANER_LOG]:-}"
  local _log_max_size="${_sched_vars[LINUX_CLEANER_LOG_MAX_SIZE]:-}"
  local _min_reclaim="${_sched_vars[LINUX_CLEANER_MIN_RECLAIM]:-}"
  local _min_free="${_sched_vars[LINUX_CLEANER_MIN_FREE]:-}"
  local _min_free_path="${_sched_vars[LINUX_CLEANER_MIN_FREE_PATH]:-}"
  local _min_age="${_sched_vars[LINUX_CLEANER_MIN_AGE]:-}"
  local _action_timeout="${_sched_vars[LINUX_CLEANER_ACTION_TIMEOUT]:-}"
  local _lock_wait="${_sched_vars[LINUX_CLEANER_LOCK_WAIT]:-}"

  if [[ -n "$_risk" ]] && ! _risk_to_int_to "" "$_risk"; then
    _out_problems+=("invalid risk")
  fi
  # The clean run refuses --only-path together with --trash-keep-days or --trash-max-size.
  if [[ -n "$_only" && -n "$_keep" ]]; then
    _out_problems+=("only-path with keep-days")
  fi
  if [[ -n "$_keep" && ! "$_keep" =~ ^[0123456789]+$ ]]; then
    _out_problems+=("invalid keep-days")
  fi
  if [[ -n "$_max_size" ]]; then
    if [[ -n "$_only" ]]; then
      _out_problems+=("only-path with trash-max-size")
    fi
    if ! parse_size_bytes "$_max_size" >/dev/null 2>&1; then
      _out_problems+=("invalid trash-max-size")
    fi
  fi
  if [[ -n "$_cfg" ]]; then
    # The user service starts in HOME, so a relative path resolves there.
    local _cfg_path="$_cfg"
    [[ "$_cfg_path" == /* ]] || _cfg_path="$_cfg_base/$_cfg_path"
    if [[ ! -f "$_cfg_path" || ! -r "$_cfg_path" ]]; then
      _out_problems+=("config not readable")
    elif ! (CONFIG_FILE="$_cfg_path" validate_config_file >/dev/null 2>&1); then
      _out_problems+=("config invalid")
    fi
  fi
  if [[ -n "$_min_reclaim" ]] && ! parse_size_bytes "$_min_reclaim" >/dev/null 2>&1; then
    _out_problems+=("invalid min-reclaim")
  fi
  if [[ -n "$_min_free" ]] && ! parse_size_bytes "$_min_free" >/dev/null 2>&1; then
    _out_problems+=("invalid min-free")
  fi
  if [[ -n "$_min_free_path" ]]; then
    if [[ -z "$_min_free" ]]; then
      _out_problems+=("min-free-path without min-free")
    fi
    if [[ "$_min_free_path" != /* || "$_min_free_path" == *$'\n'* ]]; then
      _out_problems+=("invalid min-free-path")
    fi
  fi
  if [[ -n "$_min_age" && ! "$_min_age" =~ ^[0123456789]+$ ]]; then
    _out_problems+=("invalid min-age")
  fi
  if [[ -n "$_action_timeout" && ! "$_action_timeout" =~ ^[0123456789]+$ ]]; then
    _out_problems+=("invalid action-timeout")
  fi
  if [[ -n "$_lock_wait" ]] && ! is_valid_lock_wait "$_lock_wait"; then
    _out_problems+=("invalid lock-wait")
  fi
  if [[ -n "$_log_max_size" ]]; then
    if [[ -z "$_log" ]]; then
      _out_problems+=("log-max-size without log")
    fi
    if ! parse_size_bytes "$_log_max_size" >/dev/null 2>&1; then
      _out_problems+=("invalid log-max-size")
    fi
  fi
}

# Read-only environment checklist: explain config resolution, GNU userland,
# optional helper binaries, user timer states, last cleanup, and quarantine count.
# Exits 0 when cleanup can run, or 1 when the config is missing, unreadable,
# or invalid, or GNU userland is missing.
run_doctor() {
  local doctor_rc=0 cfg_path="$CONFIG_FILE" cfg_source="explicit" bin_path i cfg_err="" cfg_rc=0
  local -a doc_warnings=()
  local cfg_status="ok" cfg_has_err=false
  local gnu_ok=true gnu_detail="GNU userland available (du -sb, stat -c, find -print0/-quit, realpath)"
  local pgrep_avail=false pgrep_path="" flock_avail=false flock_path=""
  local git_avail=false git_path="" notify_avail=false notify_path=""
  local sudo_avail=false

  set_default_config_candidates || return 1
  if [[ -z "$cfg_path" ]]; then
    # Same fallback as discovery: the checkout path when no candidate exists.
    cfg_path="${CONFIG_CANDIDATES[2]}"
    for i in 0 1 2; do
      if [[ -f "${CONFIG_CANDIDATES[i]}" ]]; then
        cfg_path="${CONFIG_CANDIDATES[i]}"
        break
      fi
    done
  fi
  resolve_config_source "$cfg_path" cfg_source || return 1
  if [[ ! -f "$cfg_path" ]]; then
    cfg_status="not_found"
    cfg_has_err=true
    cfg_err="not found"
    doc_warnings+=("config: $cfg_path ($cfg_source, not found)")
    [[ "$JSON_OUTPUT" == true ]] || printf 'WARN: config: %s (%s, not found)\n' "$cfg_path" "$cfg_source"
    doctor_rc=1
  elif [[ ! -r "$cfg_path" ]]; then
    cfg_status="not_readable"
    cfg_has_err=true
    cfg_err="not readable"
    doc_warnings+=("config: $cfg_path ($cfg_source, not readable)")
    [[ "$JSON_OUTPUT" == true ]] || printf 'WARN: config: %s (%s, not readable)\n' "$cfg_path" "$cfg_source"
    doctor_rc=1
  else
    # Subshell: validate_config_file exits 1, and the checklist must continue.
    # The CONFIG_FILE prefix applies only there, so the caller's value stays put.
    cfg_err=$(CONFIG_FILE="$cfg_path" validate_config_file 2>&1 >/dev/null) || cfg_rc=$?
    if [[ "$cfg_rc" -ne 0 ]]; then
      cfg_err=$(printf '%s' "$cfg_err" | sed $'s/\033\\[[0-9;]*m//g')
      cfg_err="${cfg_err//$'\n'/ }"
      trim_to cfg_err "$cfg_err"
      cfg_status="invalid"
      cfg_has_err=true
      doc_warnings+=("config: $cfg_path ($cfg_source, $cfg_err)")
      [[ "$JSON_OUTPUT" == true ]] || printf 'WARN: config: %s (%s, %s)\n' "$cfg_path" "$cfg_source" "$cfg_err"
      doctor_rc=1
    else
      [[ "$JSON_OUTPUT" == true ]] || printf 'OK: config: %s (%s)\n' "$cfg_path" "$cfg_source"
    fi
  fi

  if check_gnu_userland; then
    [[ "$JSON_OUTPUT" == true ]] || printf 'OK: check_gnu_userland: %s\n' "$gnu_detail"
  else
    gnu_ok=false
    gnu_detail="missing required GNU userland support (du -sb, stat -c, find -print0/-quit, realpath)"
    doc_warnings+=("check_gnu_userland: $gnu_detail")
    [[ "$JSON_OUTPUT" == true ]] || printf 'WARN: check_gnu_userland: %s\n' "$gnu_detail"
    doctor_rc=1
  fi

  if bin_path=$(command -v pgrep 2>/dev/null); then
    pgrep_avail=true
    pgrep_path="$bin_path"
    [[ "$JSON_OUTPUT" == true ]] || printf 'OK: pgrep: %s\n' "$bin_path"
  else
    doc_warnings+=("pgrep: not found (CHECK_PROCESSES rows will fail process check and be skipped)")
    [[ "$JSON_OUTPUT" == true ]] || printf 'WARN: pgrep: not found (CHECK_PROCESSES rows will fail process check and be skipped)\n'
  fi

  if bin_path=$(command -v flock 2>/dev/null); then
    flock_avail=true
    flock_path="$bin_path"
    [[ "$JSON_OUTPUT" == true ]] || printf 'OK: flock: %s\n' "$bin_path"
  else
    doc_warnings+=("flock: not found (mutating runs will not be serialized)")
    [[ "$JSON_OUTPUT" == true ]] || printf 'WARN: flock: not found (mutating runs will not be serialized)\n'
  fi

  if bin_path=$(command -v git 2>/dev/null); then
    git_avail=true
    git_path="$bin_path"
    [[ "$JSON_OUTPUT" == true ]] || printf 'OK: git: %s\n' "$bin_path"
  else
    doc_warnings+=("git: not found (git-tracked file guard disabled)")
    [[ "$JSON_OUTPUT" == true ]] || printf 'WARN: git: not found (git-tracked file guard disabled)\n'
  fi

  if command -v sudo >/dev/null 2>&1 && sudo -n true </dev/null >/dev/null 2>&1; then
    sudo_avail=true
    [[ "$JSON_OUTPUT" == true ]] || printf 'OK: sudo -n: non-interactive sudo available\n'
  else
    [[ "$JSON_OUTPUT" == true ]] || printf 'INFO: sudo -n: non-interactive sudo unavailable (root targets will prompt or be skipped)\n'
  fi

  if bin_path=$(command -v notify-send 2>/dev/null); then
    notify_avail=true
    notify_path="$bin_path"
    [[ "$JSON_OUTPUT" == true ]] || printf 'OK: notify-send: %s\n' "$bin_path"
  else
    [[ "$JSON_OUTPUT" == true ]] || printf 'INFO: notify-send: not found (--notify unavailable)\n'
  fi

  local clean_timer="unavailable" retention_timer="unavailable" monitor_timer="unavailable" t_unit t_state
  if command -v systemctl >/dev/null 2>&1; then
    for t_unit in linux-cleaner-clean.timer linux-cleaner-retention.timer linux-cleaner-monitor.timer; do
      t_state=$(user_unit_state "$t_unit")
      [[ -z "$t_state" ]] && t_state="not-found"
      case "$t_unit" in
        linux-cleaner-clean.timer) clean_timer="$t_state" ;;
        linux-cleaner-retention.timer) retention_timer="$t_state" ;;
        linux-cleaner-monitor.timer) monitor_timer="$t_state" ;;
      esac
    done
  fi
  [[ "$JSON_OUTPUT" == true ]] || printf 'INFO: timers (systemctl --user is-enabled): clean=%s retention=%s monitor=%s\n' "$clean_timer" "$retention_timer" "$monitor_timer"

  local state_dir report_file report_line saved="" result="" last_level=INFO report_mtime now retention_note=""
  local last_status="none_recorded" last_has_fields=false last_interrupted=false last_retention_failed=false last_stale=false
  state_dir=$(_xdg_dir XDG_STATE_HOME "$HOME/.local/state" && printf '.') || return 1
  state_dir="${state_dir%.}/linux-cleaner"
  report_file="${state_dir}/last-report.txt"
  if [[ -L "$state_dir" || -L "$report_file" || ! -f "$report_file" ]]; then
    [[ "$JSON_OUTPUT" == true ]] || printf 'INFO: last cleanup: none recorded\n'
  elif [[ ! -r "$report_file" ]]; then
    last_status="unreadable"
    doc_warnings+=("last cleanup: report not readable")
    [[ "$JSON_OUTPUT" == true ]] || printf 'WARN: last cleanup: report not readable\n'
  else
    last_has_fields=true
    last_status="ok"
    while IFS= read -r report_line || [[ -n "$report_line" ]]; do
      case "$report_line" in
        "Saved: "*) saved="${report_line#Saved: }" ;;
        "Result: "*) result="${report_line#Result: }" ;;
        Interrupted:*) last_level=WARN; last_interrupted=true ;;
        "Retention failed: true") last_level=WARN; last_retention_failed=true; retention_note="; retention failed" ;;
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
      last_stale=true
    fi
    if [[ "$last_level" == WARN ]]; then
      last_status="warn"
      doc_warnings+=("last cleanup: ${saved} ${result}${retention_note}")
    fi
    [[ "$JSON_OUTPUT" == true ]] || printf '%s: last cleanup: %s %s%s\n' "$last_level" "$saved" "$result" "$retention_note"
  fi

  # The clean unit reads this env file; trash mode there needs a retention bound.
  # The monitor unit reads monitor.env beside it, under $HOME even when XDG_CONFIG_HOME differs.
  local timer_env="$HOME/.config/linux-cleaner/env" monitor_env="$HOME/.config/linux-cleaner/monitor.env" env_risk="" env_config="" env_trash="" env_keep="" env_max_size=""
  local timer_env_source="no env file" timer_deletion=permanent
  local ret_warn=false mon_present=false mon_readable=false mon_status="absent" mon_prob=""
  local plan_status="ok" plan_has_env=false plan_env_readable=true env_keep_valid=false env_max_size_valid=false
  local -a plan_problem_list=() mon_problems=()
  local -A doc_timer_vars=(
    [LINUX_CLEANER_RISK]=""
    [LINUX_CLEANER_CONFIG]=""
    [LINUX_CLEANER_ONLY_PATH]=""
    [LINUX_CLEANER_TRASH]=""
    [LINUX_CLEANER_TRASH_KEEP_DAYS]=""
    [LINUX_CLEANER_TRASH_MAX_SIZE]=""
    [LINUX_CLEANER_LOG]=""
    [LINUX_CLEANER_LOG_MAX_SIZE]=""
    [LINUX_CLEANER_MIN_RECLAIM]=""
    [LINUX_CLEANER_MIN_FREE]=""
    [LINUX_CLEANER_MIN_FREE_PATH]=""
    [LINUX_CLEANER_MIN_AGE]=""
    [LINUX_CLEANER_ACTION_TIMEOUT]=""
    [LINUX_CLEANER_LOCK_WAIT]=""
  )
  # Populated and read by name via read_systemd_env_file and _collect_scheduler_env_problems.
  # shellcheck disable=SC2034
  local -A doc_mon_vars=(
    [LINUX_CLEANER_RISK]=""
    [LINUX_CLEANER_CONFIG]=""
    [LINUX_CLEANER_ONLY_PATH]=""
    [LINUX_CLEANER_TRASH]=""
    [LINUX_CLEANER_TRASH_KEEP_DAYS]=""
    [LINUX_CLEANER_TRASH_MAX_SIZE]=""
    [LINUX_CLEANER_LOG]=""
    [LINUX_CLEANER_LOG_MAX_SIZE]=""
    [LINUX_CLEANER_MIN_RECLAIM]=""
    [LINUX_CLEANER_MIN_FREE]=""
    [LINUX_CLEANER_MIN_FREE_PATH]=""
    [LINUX_CLEANER_MIN_AGE]=""
    [LINUX_CLEANER_ACTION_TIMEOUT]=""
    [LINUX_CLEANER_LOCK_WAIT]=""
  )
  if [[ "$clean_timer" == enabled && -f "$timer_env" && -r "$timer_env" ]]; then
    timer_env_source="$timer_env"
    plan_has_env=true
    read_systemd_env_file "$timer_env" doc_timer_vars
    env_risk="${doc_timer_vars[LINUX_CLEANER_RISK]}"
    env_config="${doc_timer_vars[LINUX_CLEANER_CONFIG]}"
    env_trash="${doc_timer_vars[LINUX_CLEANER_TRASH]}"
    env_keep="${doc_timer_vars[LINUX_CLEANER_TRASH_KEEP_DAYS]}"
    env_max_size="${doc_timer_vars[LINUX_CLEANER_TRASH_MAX_SIZE]}"
    if [[ -n "$env_keep" && "$env_keep" =~ ^[0123456789]+$ ]]; then
      env_keep_valid=true
    fi
    if [[ -n "$env_max_size" ]] && parse_size_bytes "$env_max_size" >/dev/null 2>&1; then
      env_max_size_valid=true
    fi
    case "$env_trash" in
      1|true|TRUE|yes|YES)
        timer_deletion=quarantine
        if [[ "$env_keep_valid" != true && "$env_max_size_valid" != true && "$retention_timer" != enabled ]]; then
          ret_warn=true
          doc_warnings+=("quarantine retention: $timer_env enables LINUX_CLEANER_TRASH for the daily timer but neither LINUX_CLEANER_TRASH_KEEP_DAYS nor linux-cleaner-retention.timer bounds the quarantine")
          [[ "$JSON_OUTPUT" == true ]] || printf 'WARN: quarantine retention: %s enables LINUX_CLEANER_TRASH for the daily timer but neither LINUX_CLEANER_TRASH_KEEP_DAYS nor linux-cleaner-retention.timer bounds the quarantine\n' "$timer_env"
        fi
        ;;
    esac
  fi
  if [[ "$clean_timer" == enabled && -e "$timer_env" && "$timer_env_source" == "no env file" ]]; then
    # systemd's EnvironmentFile=- skips only a missing file, so every timer run fails.
    plan_status="warn"
    plan_has_env=true
    plan_env_readable=false
    plan_problem_list+=("env file not readable")
    doc_warnings+=("daily timer plan: env file not readable ($timer_env)")
    [[ "$JSON_OUTPUT" == true ]] || printf 'WARN: daily timer plan: env file not readable (%s)\n' "$timer_env"
  elif [[ "$clean_timer" == enabled ]]; then
    local plan_level=INFO plan_config="" plan_max_size="" plan_problems="" plan_prob=""
    [[ -n "$env_max_size" ]] && plan_max_size=" max-size=$env_max_size"
    [[ -n "$env_config" ]] && plan_config=" config=$env_config"
    _collect_scheduler_env_problems doc_timer_vars "$HOME" plan_problem_list
    for plan_prob in "${plan_problem_list[@]}"; do
      plan_level=WARN
      plan_problems+="; $plan_prob"
    done
    if [[ "$plan_level" == WARN ]]; then
      plan_status="warn"
      doc_warnings+=("daily timer plan: risk=${env_risk:-safe} deletion=${timer_deletion} keep-days=${env_keep:-none}${plan_max_size}${plan_config} (${timer_env_source})${plan_problems}")
    fi
    [[ "$JSON_OUTPUT" == true ]] || printf '%s: daily timer plan: risk=%s deletion=%s keep-days=%s%s%s (%s)%s\n' "$plan_level" "${env_risk:-safe}" "$timer_deletion" "${env_keep:-none}" "$plan_max_size" "$plan_config" "$timer_env_source" "$plan_problems"
  fi
  if [[ -f "$monitor_env" && -r "$monitor_env" ]]; then
    mon_present=true
    mon_readable=true
    mon_status="ok"
    read_systemd_env_file "$monitor_env" doc_mon_vars
    _collect_scheduler_env_problems doc_mon_vars "$HOME" mon_problems
    local mon_other_problems=""
    for mon_prob in "${mon_problems[@]}"; do
      case "$mon_prob" in
        "only-path with keep-days")
          mon_status="conflict"
          doc_warnings+=("monitor env: $monitor_env combines LINUX_CLEANER_ONLY_PATH with LINUX_CLEANER_TRASH_KEEP_DAYS")
          [[ "$JSON_OUTPUT" == true ]] || printf 'WARN: monitor env: %s combines LINUX_CLEANER_ONLY_PATH with LINUX_CLEANER_TRASH_KEEP_DAYS\n' "$monitor_env"
          ;;
        "only-path with trash-max-size")
          mon_status="conflict"
          doc_warnings+=("monitor env: $monitor_env combines LINUX_CLEANER_ONLY_PATH with LINUX_CLEANER_TRASH_MAX_SIZE")
          [[ "$JSON_OUTPUT" == true ]] || printf 'WARN: monitor env: %s combines LINUX_CLEANER_ONLY_PATH with LINUX_CLEANER_TRASH_MAX_SIZE\n' "$monitor_env"
          ;;
        *)
          mon_other_problems+="; $mon_prob"
          ;;
      esac
    done
    if [[ -n "$mon_other_problems" ]]; then
      [[ "$mon_status" == conflict ]] || mon_status="warn"
      mon_other_problems="${mon_other_problems#; }"
      doc_warnings+=("monitor env: $monitor_env ($mon_other_problems)")
      [[ "$JSON_OUTPUT" == true ]] || printf 'WARN: monitor env: %s (%s)\n' "$monitor_env" "$mon_other_problems"
    fi
  elif [[ -e "$monitor_env" ]]; then
    mon_present=true
    mon_readable=false
    mon_status="unreadable"
    doc_warnings+=("monitor env: $monitor_env (not readable)")
    [[ "$JSON_OUTPUT" == true ]] || printf 'WARN: monitor env: %s (not readable)\n' "$monitor_env"
  fi

  local quarantine_base="$HOME/.cache/linux-cleaner/quarantine" session_dots="" q_status="ok" q_has_count=true
  if [[ -L "$quarantine_base" ]]; then
    q_status="symlinked"
    q_has_count=false
    doc_warnings+=("quarantine: symlinked quarantine directory refused ($quarantine_base)")
    [[ "$JSON_OUTPUT" == true ]] || printf 'WARN: quarantine: symlinked quarantine directory refused (%s)\n' "$quarantine_base"
  elif [[ -d "$quarantine_base" && ! -L "$quarantine_base" ]] && \
     ! session_dots=$(find "$quarantine_base" -mindepth 1 -maxdepth 1 -type d -printf '.' 2>/dev/null); then
    q_status="unreadable"
    q_has_count=false
    doc_warnings+=("quarantine: cannot enumerate sessions ($quarantine_base)")
    [[ "$JSON_OUTPUT" == true ]] || printf 'WARN: quarantine: cannot enumerate sessions (%s)\n' "$quarantine_base"
  else
    [[ "$JSON_OUTPUT" == true ]] || printf 'INFO: quarantine: %d session(s) (%s)\n' "${#session_dots}" "$quarantine_base"
  fi

  if [[ "$DOCTOR_STRICT" == true && ${#doc_warnings[@]} -gt 0 ]]; then
    doctor_rc=1
  fi

  if [[ "$JSON_OUTPUT" == true ]]; then
    local ready_json="true" esc="" first=true p=""
    [[ "$doctor_rc" -eq 0 ]] || ready_json="false"
    printf '{"ready":%s,"exit_code":%d,' "$ready_json" "$doctor_rc"
    printf '"config":{"path":"%s","source":"%s","status":"%s","error":%s},' \
      "$(json_escape "$cfg_path")" "$(json_escape "$cfg_source")" "$cfg_status" \
      "$(_json_str_or_null "$cfg_has_err" "$cfg_err")"
    printf '"gnu_userland":{"ok":%s,"detail":"%s"},' \
      "$gnu_ok" "$(json_escape "$gnu_detail")"
    printf '"tools":{"pgrep":{"available":%s,"path":%s},"flock":{"available":%s,"path":%s},"git":{"available":%s,"path":%s},"notify_send":{"available":%s,"path":%s}},' \
      "$pgrep_avail" "$(_json_str_or_null "$pgrep_avail" "$pgrep_path")" \
      "$flock_avail" "$(_json_str_or_null "$flock_avail" "$flock_path")" \
      "$git_avail" "$(_json_str_or_null "$git_avail" "$git_path")" \
      "$notify_avail" "$(_json_str_or_null "$notify_avail" "$notify_path")"
    printf '"sudo_non_interactive":{"available":%s},' "$sudo_avail"
    printf '"timers":{"clean":"%s","retention":"%s","monitor":"%s"},' \
      "$(json_escape "$clean_timer")" "$(json_escape "$retention_timer")" "$(json_escape "$monitor_timer")"
    printf '"last_cleanup":{"status":"%s","saved":%s,"result":%s,"interrupted":%s,"retention_failed":%s,"stale":%s},' \
      "$last_status" \
      "$(_json_str_or_null "$last_has_fields" "$saved")" \
      "$(_json_str_or_null "$last_has_fields" "$result")" \
      "$last_interrupted" "$last_retention_failed" "$last_stale"
    if [[ "$clean_timer" != enabled ]]; then
      printf '"daily_timer_plan":null,'
    else
      local plan_read_json="null" plan_has_risk=false plan_has_del=false plan_has_keep=false plan_has_max_size=false plan_has_cfg=false
      if [[ "$plan_env_readable" == true ]]; then
        [[ "$plan_has_env" == true ]] && plan_read_json="true"
        plan_has_risk=true
        plan_has_del=true
        [[ -n "$env_keep" ]] && plan_has_keep=true
        [[ -n "$env_max_size" ]] && plan_has_max_size=true
        [[ -n "$env_config" ]] && plan_has_cfg=true
      else
        plan_read_json="false"
      fi
      printf '"daily_timer_plan":{"status":"%s","env_file":%s,"readable":%s,"risk":%s,"deletion":%s,"keep_days":%s,"max_size":%s,"config":%s,"problems":[' \
        "$plan_status" \
        "$(_json_str_or_null "$plan_has_env" "$timer_env")" \
        "$plan_read_json" \
        "$(_json_str_or_null "$plan_has_risk" "${env_risk:-safe}")" \
        "$(_json_str_or_null "$plan_has_del" "$timer_deletion")" \
        "$(_json_str_or_null "$plan_has_keep" "$env_keep")" \
        "$(_json_str_or_null "$plan_has_max_size" "$env_max_size")" \
        "$(_json_str_or_null "$plan_has_cfg" "$env_config")"
      first=true
      for p in "${plan_problem_list[@]}"; do
        [[ "$first" == true ]] || printf ','
        first=false
        json_escape "$p" esc
        printf '"%s"' "$esc"
      done
      printf ']},'
    fi
    printf '"quarantine_retention":{"warn":%s,"env_file":%s},' \
      "$ret_warn" "$(_json_str_or_null "$ret_warn" "$timer_env")"
    local mon_read_json="null" mon_probs_json="" mon_prob_esc="" mon_first=true
    [[ "$mon_present" == true ]] && mon_read_json="$mon_readable"
    for mon_prob in "${mon_problems[@]}"; do
      [[ "$mon_first" == true ]] || mon_probs_json+=","
      mon_first=false
      json_escape "$mon_prob" mon_prob_esc
      mon_probs_json+="\"$mon_prob_esc\""
    done
    printf '"monitor_env":{"present":%s,"path":"%s","readable":%s,"status":"%s","problems":[%s]},' \
      "$mon_present" "$(json_escape "$monitor_env")" "$mon_read_json" "$mon_status" "$mon_probs_json"
    local q_cnt_json="null"
    [[ "$q_has_count" == true ]] && q_cnt_json="${#session_dots}"
    printf '"quarantine":{"path":"%s","status":"%s","session_count":%s},' \
      "$(json_escape "$quarantine_base")" "$q_status" "$q_cnt_json"
    printf '"warnings":['
    first=true
    for p in "${doc_warnings[@]}"; do
      [[ "$first" == true ]] || printf ','
      first=false
      json_escape "$p" esc
      printf '"%s"' "$esc"
    done
    printf ']}\n'
  fi
  return "$doctor_rc"
}

MAX_RISK_INT=0
if ! _risk_to_int_to MAX_RISK_INT "$MAX_RISK"; then
  risk_to_int "$MAX_RISK" || exit 1
fi

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
  validate_config_file >/dev/null || exit 1
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
  run_check_config
  exit $?
fi

# Load cleanup-only pattern file pre-lock (non-cleanup modes have exited or skip cleanup).
if [[ -z "${RESTORE_TARGET:-}" && -z "${PURGE_TARGET:-}" && -z "$HOLD_TARGET" && -z "$RELEASE_TARGET" ]]; then
  load_exclude_from_file || exit 1
  build_exclude_find_args
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

# Arm failure-metrics export only after pre-lock validation, non-cleanup dispatch,
# and mutation lock acquisition succeed on the cleanup path.
if [[ "$DRY_RUN" == false ]]; then
  CLEANUP_METRICS_ARMED=true
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
  if [[ "${_CFG_REC_LOADED:-false}" != true || "${_CFG_REC_LOADED_CONFIG:-}" != "$CONFIG_FILE" ]]; then
    load_config_lines || return 1
  fi
  for line in "${CFG_REC_LINES[@]}"; do
    IFS='|' read -r f1 f2 _ <<< "$line"
    trim_to f1 "$f1"
    [[ "$f1" == "protect" ]] || continue
    trim_to f2 "$f2"
    if ! expand_path_safe "$f2" expanded; then
      echo "Error: protect PATH has unsafe path expansion" >&2
      return 1
    fi
    stripped=$(strip_trailing_slashes "$expanded")
    if ! canonical=$(canonicalize_physical "$stripped"); then
      echo "Error: could not resolve protect PATH" >&2
      return 1
    fi
    PROTECTED_PATHS+=("$canonical")
  done
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
config_src_file="$CONFIG_FILE"
config_lineno=0
while IFS= read -r -d '' config_src_file && IFS= read -r -d '' config_lineno && IFS= read -r -d '' config_line; do
  # validate_config_file already rejected malformed records (field count, empty
  # NAME/PATH, CHECK_PROCESSES, CUSTOM_ACTION, risk, MIN_AGE_DAYS) before this runs.
  IFS='|' read -r risk name raw_path desc min_age check_procs custom_clean_cmd <<< "$config_line"
  trim_to risk "$risk"
  [[ -z "$risk" || "$risk" =~ ^# ]] && continue

  trim_to name "$name"
  trim_to raw_path "$raw_path"
  trim_to desc "$desc"
  trim_to min_age "$min_age"
  trim_to check_procs "${check_procs:-}"
  trim_to custom_clean_cmd "${custom_clean_cmd:-}"
  set_target_exclusions "$custom_clean_cmd"

  select_target_name "$name" || continue
  select_target_path "$raw_path" "$custom_clean_cmd" || continue
  select_target_action "$custom_clean_cmd" || continue

  # Map risk levels
  target_risk_int=0
  if ! _risk_to_int_to target_risk_int "$risk"; then
    risk_to_int "$risk" "${config_src_file}:${config_lineno}: " || exit 1
  fi
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
    printf 'Error: %s:%s: target PATH has unsafe path expansion\n' "$config_src_file" "$config_lineno" >&2
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
      printf 'Error: %s:%s: could not resolve target PATH\n' "$config_src_file" "$config_lineno" >&2
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
           [[ -e "$path" && ( ! -r "$path" || ( -d "$path" && ! -x "$path" ) ) ]] || \
           { [[ "$custom_clean_cmd" != action:* ]] && path_lookup_blocked "$path"; } || \
           { [[ "$custom_clean_cmd" != action:* && "$safety_status" -eq 2 ]] && path_present false "$path" && \
             { { { [[ ! -d "$path" ]] || { ! has_positive_age "$effective_age" && [[ "$TARGET_EXCLUDE_ACTIVE" != true ]]; }; } && \
                 [[ ! -w "$(dirname "$path" 2>/dev/null || echo /)" ]]; } || \
               { [[ -d "$path" && ! -w "$path" ]] && \
                 { has_positive_age "$effective_age" || [[ "$TARGET_EXCLUDE_ACTIVE" == true ]]; }; }; }; }; then
          requires_sudo=true
          # A readable filter:cxx_build tree with a recent non-excluded file is active
          # regardless of root visibility, so skip root elevation and [ROOT] reporting.
          if has_positive_age "$idle_age" \
             && [[ "$custom_clean_cmd" != action:* ]] \
             && ! path_lookup_blocked "$path" \
             && [[ -e "$path" && -r "$path" && ( ! -d "$path" || -x "$path" ) ]] \
             && [[ -n $(with_sudo false find "$path" "${EXCLUDE_FIND_ARGS[@]}" -mtime -"$idle_age" -print -quit 2>/dev/null) ]]; then
            requires_sudo=false
          fi
          if [[ "$requires_sudo" == true ]]; then
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
            elif [[ "${NO_SUDO:-false}" != true ]] && sudo -n true 2>/dev/null; then
              use_sudo=true
            else
              use_sudo=false
            fi
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
  print_timer_note
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
    [[ -n "$EXCLUDE_FROM" ]] && next_args+=(--exclude-from "$EXCLUDE_FROM")
    [[ -n "$ONLY_TARGET" ]] && next_args+=(--only-target "$ONLY_TARGET")
    [[ -n "$ONLY_TARGET_EXACT" ]] && next_args+=(--only-target-exact "$ONLY_TARGET_EXACT")
    [[ -n "$EXCLUDE_TARGET" ]] && next_args+=(--exclude-target "$EXCLUDE_TARGET")
    [[ -n "$EXCLUDE_TARGET_EXACT" ]] && next_args+=(--exclude-target-exact "$EXCLUDE_TARGET_EXACT")
    [[ -n "$ONLY_PATH" ]] && next_args+=(--only-path "$ONLY_PATH")
    [[ -n "$EXCLUDE_PATH" ]] && next_args+=(--exclude-path "$EXCLUDE_PATH")
    [[ -n "$MIN_RECLAIM" ]] && next_args+=(--min-reclaim "$MIN_RECLAIM")
    [[ -n "$MIN_FREE" ]] && next_args+=(--min-free "$MIN_FREE")
    [[ -n "$MIN_FREE_PATH" ]] && next_args+=(--min-free-path "$MIN_FREE_PATH")
    [[ -n "$MIN_AGE_OVERRIDE" ]] && next_args+=(--min-age "$MIN_AGE_OVERRIDE")
    [[ -n "$TRASH_KEEP_DAYS" ]] && next_args+=(--trash-keep-days "$TRASH_KEEP_DAYS")
    [[ -n "$TRASH_MAX_SIZE" ]] && next_args+=(--trash-max-size "$TRASH_MAX_SIZE")
    [[ "$FAIL_FAST" == true ]] && next_args+=(--fail-fast)
    [[ "$SKIP_ACTIONS" == true ]] && next_args+=(--skip-actions)
    [[ "$NO_SUDO" == true ]] && next_args+=(--no-sudo)
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
  apply_trash_retention
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
  _danger_risk=0
  _risk_to_int_to _danger_risk "$risk_level" || _danger_risk=0
  if [[ "$_danger_risk" -eq 3 && "$YES_DANGER" != true ]]; then
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
      action:flatpak_unused)
        if run_action flatpak uninstall --user --unused --assumeyes --noninteractive; then
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
      else
        # A package-cache action keeps part of the cache (paccache -rk1 keeps the newest
        # version of every package), so credit only what left the planned directory.
        size_after=$(get_size_bytes "$path" "$age" "$use_sudo")
        credited_bytes=$((size - size_after))
        if [[ "$credited_bytes" -lt 0 ]]; then
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

    if has_positive_age "$age" || [[ "$TARGET_EXCLUDE_ACTIVE" == true ]]; then
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
          with_sudo true chown -R "$(id -u):$(id -g)" "$q_target" || success=false
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
    if has_positive_age "$age" || [[ "$TARGET_EXCLUDE_ACTIVE" == true ]]; then
      if path_is_real_dir "$use_sudo" "$path"; then
        find_mtime_args=()
        if has_positive_age "$age"; then
          find_mtime_args+=("-mtime" "+$age")
        fi
        via=""
        [[ "$use_sudo" = true ]] && via=" with sudo"

        status_echo "  Cleaning filtered files in ${YELLOW}$name${NC}${via}..."
        if with_sudo "$use_sudo" find "$path" -mindepth 1 "${EXCLUDE_FIND_ARGS[@]}" \( -type f -o -type l \) "${find_mtime_args[@]}" -delete; then
          with_sudo "$use_sudo" find "$path" -mindepth 1 "${EXCLUDE_FIND_ARGS[@]}" -type d -empty -delete 2>/dev/null || true
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
