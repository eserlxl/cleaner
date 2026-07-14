#!/usr/bin/env bash

# Linux Cache and Temp File Cleaner
# A script to safely clean unnecessary files and folders.

set -euo pipefail

# Determine script directory to find the default configuration file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Config resolution: an explicit -c/--config wins; otherwise the default is
# resolved by search order (XDG user > /etc > dev checkout) after arg parsing.
CONFIG_FILE=""

# Single source of truth for the tool version (semantic version).
readonly VERSION="1.2.0"

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
  --list-targets             List configured cleanup targets (read-only) and exit.
  --restore SESSION          Restore files from quarantine session (latest or timestamp).
  --only PATTERN             With --restore: restore only targets whose original path contains PATTERN; the rest stay quarantined.
  --only-target PATTERN      With cleanup: process only config targets whose NAME contains PATTERN (substring match).
  --purge-sessions SESSION   Permanently delete quarantine session(s) to reclaim space (latest, all, older-than:DAYS, or timestamp). Irreversible.
  --allow-outside-home       Explicitly allow cleaning targets outside user's HOME directory.
  --log [FILE]               Append an operation log (opt-in, off by default; kept under your HOME).
  -q, --quiet                Suppress per-target status lines; keep errors, totals, and final summary.
  --json                     Emit machine-readable JSON (--dry-run summary or --list-targets inventory).
  -h, --help                 Display this help message and exit.
  -V, --version              Print the tool version and exit.
EOF
}

# Default flags
DRY_RUN=true
INTERACTIVE=false
FORCE=false
YES_DANGER=false
QUIET=false
JSON_OUTPUT=false
TRASH_MODE=false
MAX_RISK="safe"
ALLOW_OUTSIDE_HOME=false
EXCLUDE_PATTERNS=""
RESTORE_TARGET=""
RESTORE_ONLY=""
ONLY_TARGET=""
PURGE_TARGET=""
LIST_SESSIONS=false
LIST_TARGETS=false

# Set by any operation that was attempted and failed (a delete, a quarantine move,
# a predefined action, a purge). The tool exits non-zero when it is set, per the
# contract in cleaner.1 ("non-zero on ... a failed operation") -- an unattended run
# must be able to detect a failure it only printed to stderr. Deliberate skips (a
# declined danger target, a blocked process, an unsafe path, an action whose binary
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
case "${LINUX_CLEANER_QUIET:-}" in
  1|true|TRUE|yes|YES) QUIET=true ;;
esac
case "${LINUX_CLEANER_JSON:-}" in
  1|true|TRUE|yes|YES) JSON_OUTPUT=true ;;
esac
if [[ -n "${LINUX_CLEANER_ONLY_TARGET:-}" ]]; then
  ONLY_TARGET="$LINUX_CLEANER_ONLY_TARGET"
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
      shift
      ;;
    --clean)
      DRY_RUN=false
      shift
      ;;
    -i|--interactive)
      INTERACTIVE=true
      DRY_RUN=false
      shift
      ;;
    -f|--force)
      FORCE=true
      DRY_RUN=false
      shift
      ;;
    -q|--quiet)
      QUIET=true
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
    --purge-sessions)
      if [[ -z "${2:-}" ]]; then
        echo -e "${RED}Error: --purge-sessions requires a session argument (latest, all, older-than:DAYS, or timestamp).${NC}" >&2
        exit 1
      fi
      PURGE_TARGET="$2"
      shift 2
      ;;
    --allow-outside-home)
      ALLOW_OUTSIDE_HOME=true
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
    --list-targets)
      LIST_TARGETS=true
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

# --only only means anything as a filter on --restore; silently ignoring it would
# let a user believe a cleanup or purge was narrowed when it was not.
if [[ -n "$RESTORE_ONLY" && -z "$RESTORE_TARGET" ]]; then
  echo -e "${RED}Error: --only requires --restore (it filters which quarantined targets are restored).${NC}" >&2
  exit 1
fi

if [[ -n "$ONLY_TARGET" && ( -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" || "$LIST_SESSIONS" == true || "$LIST_TARGETS" == true ) ]]; then
  echo -e "${RED}Error: --only-target applies only to cleanup runs (not --restore, --purge-sessions, --list-sessions, or --list-targets).${NC}" >&2
  exit 1
fi

if [[ "$LIST_TARGETS" == true && ( -n "${RESTORE_TARGET:-}" || -n "${PURGE_TARGET:-}" || "$LIST_SESSIONS" == true ) ]]; then
  echo -e "${RED}Error: --list-targets cannot be combined with --restore, --purge-sessions, or --list-sessions.${NC}" >&2
  exit 1
fi

if [[ "$JSON_OUTPUT" == true && "$DRY_RUN" != true && "$LIST_TARGETS" != true ]]; then
  echo -e "${RED}Error: --json is valid only with --dry-run (machine-readable preview) or --list-targets.${NC}" >&2
  exit 1
fi

if [[ "$JSON_OUTPUT" == true ]]; then
  QUIET=true
fi

# Check if config file exists (only if not restoring, purging, or listing sessions)
if [[ -z "${RESTORE_TARGET:-}" && -z "${PURGE_TARGET:-}" && "$LIST_SESSIONS" != true ]]; then
  # Resolve the default config by search order when -c/--config was not given:
  # XDG user config > system config > dev-checkout config beside the script.
  if [[ -z "$CONFIG_FILE" ]]; then
    for candidate in \
        "${XDG_CONFIG_HOME:-$HOME/.config}/linux-cleaner/cleaner.conf" \
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

# User-facing status lines (per-target progress, headers). Suppressed by --quiet;
# errors and final summaries still print via echo/stderr.
status_echo() {
  if [[ "$QUIET" == true ]]; then
    return 0
  fi
  echo -e "$@"
}

json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

emit_dry_run_json() {
  local i first=true
  printf '{'
  printf '"config":"%s",' "$(json_escape "$CONFIG_FILE")"
  printf '"total_reclaimable_bytes":%s,' "$total_reclaimable_bytes"
  printf '"targets":['
  for i in "${!json_names[@]}"; do
    if [[ "$first" == true ]]; then
      first=false
    else
      printf ','
    fi
    printf '{"name":"%s","path":"%s","risk":"%s","bytes":%s,"status":"%s"}' \
      "$(json_escape "${json_names[$i]}")" \
      "$(json_escape "${json_paths[$i]}")" \
      "$(json_escape "${json_risks[$i]}")" \
      "${json_bytes[$i]}" \
      "$(json_escape "${json_statuses[$i]}")"
  done
  printf ']}'
  printf '\n'
}

emit_list_targets_json() {
  local -a lt_names=() lt_risks=() lt_paths=()
  local config_line config_lineno=0 config_pipes field_count
  local risk name raw_path desc min_age check_procs custom_clean_cmd
  local i first=true

  while IFS= read -r config_line || [[ -n "$config_line" ]]; do
    config_lineno=$((config_lineno + 1))
    config_pipes="${config_line//[^|]/}"
    field_count=$(( ${#config_pipes} + 1 ))
    IFS='|' read -r risk name raw_path desc min_age check_procs custom_clean_cmd <<< "$config_line"
    risk=$(trim "$risk")
    [[ -z "$risk" || "$risk" =~ ^# ]] && continue
    if [[ "$field_count" -lt 5 || "$field_count" -gt 7 ]]; then
      echo -e "${RED}Error: ${CONFIG_FILE}:${config_lineno}: expected 5-7 fields, found ${field_count}${NC}" >&2
      exit 1
    fi
    name=$(trim "$name")
    raw_path=$(trim "$raw_path")
    if [[ -z "$name" ]]; then
      echo -e "${RED}Error: ${CONFIG_FILE}:${config_lineno}: NAME (field 2) is empty${NC}" >&2
      exit 1
    fi
    if [[ -z "$raw_path" ]]; then
      echo -e "${RED}Error: ${CONFIG_FILE}:${config_lineno}: PATH (field 3) is empty${NC}" >&2
      exit 1
    fi
    lt_names+=("$name")
    lt_risks+=("$risk")
    lt_paths+=("$raw_path")
  done < "$CONFIG_FILE"

  printf '{'
  printf '"config":"%s",' "$(json_escape "$CONFIG_FILE")"
  printf '"targets":['
  for i in "${!lt_names[@]}"; do
    if [[ "$first" == true ]]; then
      first=false
    else
      printf ','
    fi
    printf '{"name":"%s","risk":"%s","path":"%s"}' \
      "$(json_escape "${lt_names[$i]}")" \
      "$(json_escape "${lt_risks[$i]}")" \
      "$(json_escape "${lt_paths[$i]}")"
  done
  printf ']}'
  printf '\n'
}

# Replace every whole-token occurrence of $NAME (arg 2) with VALUE (arg 3) in
# STRING (arg 1). "Whole token" means the $NAME is not immediately followed by
# an identifier character, so $HOMEDATA / $USERNAME are left literal -- only the
# explicit $HOME / $USER placeholders are resolved (no eval, no substring creep).
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

# Expand standard environment variables in a safe way (avoiding eval)
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

  # Replace $HOME and $USER only as whole tokens (so $HOMEDATA / $USERNAME stay
  # literal, matching the documented "explicit placeholders only" contract).
  expanded=$(_expand_var_token "$expanded" "HOME" "$HOME")
  expanded=$(_expand_var_token "$expanded" "USER" "$USER")

  echo "$expanded"
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
  else
    echo "${p%/}"
  fi
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

# Build the global array EXCLUDE_FIND_ARGS for use in find commands based on EXCLUDE_PATTERNS
EXCLUDE_FIND_ARGS=()
build_exclude_find_args() {
  if [[ -z "${EXCLUDE_PATTERNS:-}" ]]; then
    return
  fi
  
  local IFS=','
  local -a pats
  read -r -a pats <<< "$EXCLUDE_PATTERNS"
  
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

# Print configured cleanup targets (strictly read-only): NAME, risk, and path
# for every active config line. No disk analysis or mutation.
list_config_targets() {
  local config_line config_lineno=0 config_pipes field_count
  local risk name raw_path desc min_age check_procs custom_clean_cmd

  if [[ "$JSON_OUTPUT" == true ]]; then
    emit_list_targets_json
    return 0
  fi

  echo -e "${BOLD}${BLUE}=== Configured Targets ===${NC}"
  echo -e "Config file: ${YELLOW}$CONFIG_FILE${NC}"
  echo

  while IFS= read -r config_line || [[ -n "$config_line" ]]; do
    config_lineno=$((config_lineno + 1))
    config_pipes="${config_line//[^|]/}"
    field_count=$(( ${#config_pipes} + 1 ))
    IFS='|' read -r risk name raw_path desc min_age check_procs custom_clean_cmd <<< "$config_line"
    risk=$(trim "$risk")
    [[ -z "$risk" || "$risk" =~ ^# ]] && continue
    if [[ "$field_count" -lt 5 || "$field_count" -gt 7 ]]; then
      echo -e "${RED}Error: ${CONFIG_FILE}:${config_lineno}: expected 5-7 fields, found ${field_count}${NC}" >&2
      exit 1
    fi
    name=$(trim "$name")
    raw_path=$(trim "$raw_path")
    if [[ -z "$name" ]]; then
      echo -e "${RED}Error: ${CONFIG_FILE}:${config_lineno}: NAME (field 2) is empty${NC}" >&2
      exit 1
    fi
    if [[ -z "$raw_path" ]]; then
      echo -e "${RED}Error: ${CONFIG_FILE}:${config_lineno}: PATH (field 3) is empty${NC}" >&2
      exit 1
    fi
    printf '%s\t%s\t%s\n' "$name" "$risk" "$raw_path"
  done < "$CONFIG_FILE"
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
list_quarantine_sessions() {
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
    size=$(du -sh "$session" 2>/dev/null | awk '{print $1}')
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
    if [[ ${#targets[@]} -eq 0 ]]; then
      echo -e "${YELLOW}No quarantine sessions found.${NC}"
      return 0
    fi
  elif [[ "$target" == "latest" ]]; then
    local latest
    latest=$(find "$quarantine_base" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n 1)
    if [[ -z "$latest" ]]; then
      echo -e "${RED}Error: No quarantined sessions found in '$quarantine_base'.${NC}" >&2
      exit 1
    fi
    targets+=("$latest")
  elif [[ "$target" == older-than:* ]]; then
    # Age-based retention: what makes trash mode viable unattended. Without it a
    # cron '--trash --force' accumulates one session per run forever, so the tool
    # would hold the very space it claims to reclaim.
    local days="${target#older-than:}"
    if [[ ! "$days" =~ ^[0-9]+$ ]]; then
      echo -e "${RED}Error: Invalid day count in '$target'. Use older-than:<days>, e.g. older-than:30.${NC}" >&2
      exit 1
    fi
    local s
    while IFS= read -r s; do
      [[ -n "$s" ]] && targets+=("$s")
    done < <(find "$quarantine_base" -mindepth 1 -maxdepth 1 -type d -mtime +"$days" 2>/dev/null | sort)
    # Nothing old enough is a success for a cron wrapper, not an error.
    if [[ ${#targets[@]} -eq 0 ]]; then
      echo -e "${YELLOW}No quarantine sessions older than ${days} day(s).${NC}"
      return 0
    fi
  else
    # A named session must be an immediate child of the base: reject any path
    # separator or dot-traversal so the purge can never escape the quarantine dir.
    if [[ "$target" == */* || "$target" == "." || "$target" == ".." ]]; then
      echo -e "${RED}Error: Invalid session name '$target'.${NC}" >&2
      exit 1
    fi
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
    size=$(du -sh "$d" 2>/dev/null | awk '{print $1}')
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
    else
      echo -e "${RED}Error: Failed to purge '$d'.${NC}" >&2
      OPERATION_FAILED=true
    fi
  done

  # Remove the base directory if it is now empty (mirrors restore cleanup).
  rmdir "$quarantine_base" 2>/dev/null || true

  echo -e "${BOLD}Purged ${purged} session(s).${NC}"
}

# Move a whole target into quarantine and record it in quarantine.meta. The
# record is written ONLY after the move actually succeeded: a record for a file
# that never moved makes every later --restore of the session fail on a missing
# source (and keep the session forever), even though nothing was lost.
# Returns non-zero if the move (or the sudo chown that follows it) failed.
quarantine_move_full() {
  local src="$1" dest="$2" rel="$3" use_sudo="$4" owner_info="$5"
  local moved=false ok=true

  if [[ "$use_sudo" = true ]]; then
    if sudo mv "$src" "$dest"; then
      moved=true
      sudo chown -R "$(id -u):$(id -g)" "$dest" || ok=false
    else
      ok=false
    fi
  else
    if mv "$src" "$dest"; then
      moved=true
    else
      ok=false
    fi
  fi

  if [[ "$moved" = true ]]; then
    echo "full|$rel|$src|$use_sudo|$owner_info" >> "$QUARANTINE_DIR/quarantine.meta"
  fi
  [[ "$ok" = true ]]
}

# Permanently delete a whole target and account for it. Sets OPERATION_FAILED on a
# failed delete so an unattended run exits non-zero, per cleaner.1's EXIT STATUS
# contract. Adds the target's size to the running total only when the delete worked.
delete_path_full() {
  local target="$1" label="$2" use_sudo="$3" bytes="$4"

  if [[ "$use_sudo" = true ]]; then
    echo -e "  Cleaning ${YELLOW}$label${NC} at '$target' with sudo..."
    if sudo rm -rf "$target"; then
      total_deleted_bytes=$((total_deleted_bytes + bytes))
      return 0
    fi
    echo -e "  ${RED}Error: Failed to delete '$target' with sudo${NC}" >&2
  else
    echo -e "  Cleaning ${YELLOW}$label${NC} at '$target'..."
    if rm -rf "$target"; then
      total_deleted_bytes=$((total_deleted_bytes + bytes))
      return 0
    fi
    echo -e "  ${RED}Error: Failed to delete '$target'${NC}" >&2
  fi
  OPERATION_FAILED=true
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
      continue
    fi
    
    echo -e "Restoring ${YELLOW}$original_path${NC}..."
    
    local success=true
    if [[ "$type" == "full" ]]; then
      local conflict=false
      if [[ "$use_sudo" = true ]]; then
        if sudo test -e "$original_path" || sudo test -L "$original_path"; then
          conflict=true
        fi
      else
        if [[ -e "$original_path" || -L "$original_path" ]]; then
          conflict=true
        fi
      fi

      if [[ "$conflict" = true ]]; then
        echo -e "${RED}Error: Restore destination '$original_path' already exists. Conflict detected, skipping.${NC}" >&2
        overall_success=false
        continue
      fi

      if [[ "$use_sudo" = true ]]; then
        ensure_sudo
        sudo mkdir -p "$(dirname "$original_path")"
        if sudo mv "$src_path" "$original_path"; then
          sudo chown -hR "$uid:$gid" "$original_path" 2>/dev/null || true
        else
          success=false
        fi
      else
        mkdir -p "$(dirname "$original_path")"
        if mv "$src_path" "$original_path"; then
          chown -hR "$uid:$gid" "$original_path" 2>/dev/null || true
        else
          success=false
        fi
      fi
    elif [[ "$type" == "aged" ]]; then
      if [[ "$use_sudo" = true ]]; then
        ensure_sudo
        sudo mkdir -p "$original_path"
        while IFS= read -r -d '' file; do
          local file_rel="${file#"$src_path"/}"
          local dest_file="$original_path/$file_rel"
          local file_conflict=false
          if sudo test -e "$dest_file" || sudo test -L "$dest_file"; then
            file_conflict=true
          fi
          if [[ "$file_conflict" = true ]]; then
            echo -e "${RED}Error: Restore destination file '$dest_file' already exists. Conflict detected, skipping.${NC}" >&2
            success=false
            continue
          fi
          sudo mkdir -p "$(dirname "$dest_file")"
          if sudo mv "$file" "$dest_file"; then
            sudo chown -h "$uid:$gid" "$dest_file" 2>/dev/null || true
          else
            success=false
          fi
        done < <(find "$src_path" -mindepth 1 \( -type f -o -type l \) -print0)
      else
        mkdir -p "$original_path"
        while IFS= read -r -d '' file; do
          local file_rel="${file#"$src_path"/}"
          local dest_file="$original_path/$file_rel"
          local file_conflict=false
          if [[ -e "$dest_file" || -L "$dest_file" ]]; then
            file_conflict=true
          fi
          if [[ "$file_conflict" = true ]]; then
            echo -e "${RED}Error: Restore destination file '$dest_file' already exists. Conflict detected, skipping.${NC}" >&2
            success=false
            continue
          fi
          mkdir -p "$(dirname "$dest_file")"
          if mv "$file" "$dest_file"; then
            chown -h "$uid:$gid" "$dest_file" 2>/dev/null || true
          else
            success=false
          fi
        done < <(find "$src_path" -mindepth 1 \( -type f -o -type l \) -print0)
      fi
    else
      echo -e "${RED}Error: Unknown restore type '$type' for '$original_path'. Skipping.${NC}" >&2
      overall_success=false
      continue
    fi
    
    if [[ "$success" = false ]]; then
      echo -e "${RED}Error: Failed to restore '$original_path'.${NC}" >&2
      overall_success=false
    else
      restored_rels+=("$rel_path")
    fi
  done < "$meta_file"

  # A --only pattern that matched nothing restored nothing: say so, don't succeed silently.
  if [[ -n "${RESTORE_ONLY:-}" && "$matched_any" != true ]]; then
    echo -e "${RED}Error: No quarantined target in this session matches '--only ${RESTORE_ONLY}'.${NC}" >&2
    exit 1
  fi

  if [[ "$overall_success" != true ]]; then
    echo -e "${RED}Error: Restoration completed with some errors. The quarantine session has been kept at '$restore_dir' for recovery.${NC}" >&2
    exit 1
  fi

  echo -e "${BOLD}${GREEN}Restoration complete!${NC}"

  if [[ -z "${RESTORE_ONLY:-}" ]]; then
    rm -rf "$restore_dir"
    rmdir "$quarantine_base" 2>/dev/null || true
    return 0
  fi

  # Filtered restore: keep every record we did NOT move back, so the session stays
  # consistent and a later full --restore of it still succeeds.
  local -a retained=()
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
    rm -rf "$restore_dir"
    rmdir "$quarantine_base" 2>/dev/null || true
  else
    printf '%s\n' "${retained[@]}" > "$meta_file"
    echo -e "Session ${YELLOW}$(basename "$restore_dir")${NC} kept: ${#retained[@]} target(s) still quarantined."
  fi
}



# Ensure sudo is authenticated
ensure_sudo() {
  if ! sudo -n true 2>/dev/null; then
    echo -e "${YELLOW}Target(s) require root privileges. Please authenticate for sudo:${NC}"
    sudo -v || exit 1
  fi
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
  
  local normalized
  normalized=$(canonicalize_physical "$target_path")
  
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
     [[ "$normalized" =~ ^/lib ]]; then
    return 1
  fi
  
  # Warn/error if outside HOME directory
  if [[ "$normalized" != "$HOME" && "$normalized" != "$HOME"/* ]]; then
    return 2
  fi
  
  return 0
}

# Check if there are files that match the age filter criteria
has_matching_files() {
  local target_path="$1"
  local age_days="$2"
  local use_sudo="${3:-false}"
  
  local cmd_prefix=""
  if [[ "$use_sudo" = true ]]; then
    cmd_prefix="sudo "
  fi

  # Check if the target itself is excluded
  if [[ -n "${EXCLUDE_PATTERNS:-}" ]]; then
    if [[ -z $($cmd_prefix find "$target_path" "${EXCLUDE_FIND_ARGS[@]}" -print 2>/dev/null) ]]; then
      return 1
    fi
  fi

  if [[ "$age_days" -le 0 ]]; then
    if [[ "$use_sudo" = true ]]; then
      if sudo test -e "$target_path" || sudo test -L "$target_path"; then
        return 0
      fi
    else
      if [[ -e "$target_path" || -L "$target_path" ]]; then
        return 0
      fi
    fi
    return 1
  fi
  
  if [[ -d "$target_path" && ! -L "$target_path" ]]; then
    # Check if there is any file or symlink inside older than age_days
    # find -print -quit exits 0 if a match is found
    [[ -n $($cmd_prefix find "$target_path" -mindepth 1 "${EXCLUDE_FIND_ARGS[@]}" \( -type f -o -type l \) -mtime +"$age_days" -print -quit 2>/dev/null) ]] && return 0
  else
    # Single file or symlink
    [[ -n $($cmd_prefix find "$target_path" -mtime +"$age_days" -print -quit 2>/dev/null) ]] && return 0
  fi
  return 1
}

# Calculate size in bytes using du (takes into account min_age and exclusions if set)
get_size_bytes() {
  local target_path="$1"
  local age_days="${2:-0}"
  local use_sudo="${3:-false}"
  
  local cmd_prefix=""
  if [[ "$use_sudo" = true ]]; then
    cmd_prefix="sudo "
  fi

  # Check existence. If sudo is required, check via sudo test
  local exists=false
  if [[ "$use_sudo" = true ]]; then
    if sudo test -e "$target_path" || sudo test -L "$target_path"; then
      exists=true
    fi
  else
    if [[ -e "$target_path" || -L "$target_path" ]]; then
      exists=true
    fi
  fi

  if [[ "$exists" = false ]]; then
    echo 0
    return
  fi
  
  # Check if the target itself is excluded
  if [[ -n "${EXCLUDE_PATTERNS:-}" ]]; then
    if [[ -z $($cmd_prefix find "$target_path" "${EXCLUDE_FIND_ARGS[@]}" -print 2>/dev/null) ]]; then
      echo 0
      return
    fi
  fi
  
  # Check if directory and if symlink
  local is_dir=false
  local is_link=false
  if [[ "$use_sudo" = true ]]; then
    if sudo test -d "$target_path" && ! sudo test -L "$target_path"; then is_dir=true; fi
    if sudo test -L "$target_path"; then is_link=true; fi
  else
    if [[ -d "$target_path" && ! -L "$target_path" ]]; then is_dir=true; fi
    if [[ -L "$target_path" ]]; then is_link=true; fi
  fi

  if [[ "$is_dir" = true && "$is_link" = false ]]; then
    # Sum size of files/symlinks older than age_days within the directory
    # If EXCLUDE_PATTERNS is set, we must use find even if age_days is 0!
    if [[ -n "${EXCLUDE_PATTERNS:-}" ]]; then
      local find_mtime_args=()
      if [[ "$age_days" -gt 0 ]]; then
        find_mtime_args+=("-mtime" "+$age_days")
      fi
      $cmd_prefix find "$target_path" -mindepth 1 "${EXCLUDE_FIND_ARGS[@]}" \( -type f -o -type l \) "${find_mtime_args[@]}" -exec du -sb {} + 2>/dev/null | awk '{sum+=$1} END {print sum+0}'
    else
      if [[ "$age_days" -gt 0 ]]; then
        $cmd_prefix find "$target_path" -mindepth 1 \( -type f -o -type l \) -mtime +"$age_days" -exec du -sb {} + 2>/dev/null | awk '{sum+=$1} END {print sum+0}'
      else
        $cmd_prefix du -sb "$target_path" 2>/dev/null | awk '{print $1}' || echo 0
      fi
    fi
  else
    # If target is a file or symlink, check if it's older than age_days
    if [[ "$age_days" -gt 0 ]]; then
      if [[ -n $($cmd_prefix find "$target_path" -mtime +"$age_days" -print -quit 2>/dev/null) ]]; then
        $cmd_prefix du -sb "$target_path" 2>/dev/null | awk '{print $1}' || echo 0
      else
        echo 0
      fi
    else
      $cmd_prefix du -sb "$target_path" 2>/dev/null | awk '{print $1}' || echo 0
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

# Check if any specified process is running
is_process_running() {
  local procs="$1"
  if [[ -z "$procs" ]]; then
    return 1
  fi
  
  # Disable IFS split warning by splitting explicitly
  local proc
  local saved_ifs="$IFS"
  IFS=','
  for proc in $procs; do
    IFS="$saved_ifs"
    proc=$(trim "$proc")
    if pgrep -x "$proc" >/dev/null; then
      echo "$proc"
      return 0
    fi
    IFS=','
  done
  IFS="$saved_ifs"
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
    *) echo "" ;;
  esac
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

# Read-only: list quarantine sessions and exit
if [[ "$LIST_SESSIONS" == true ]]; then
  list_quarantine_sessions
  exit 0
fi

if [[ "$LIST_TARGETS" == true ]]; then
  list_config_targets
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
parsed_exists=()
parsed_safety=()
parsed_ages=()
parsed_risks=()
parsed_cmds=()
parsed_sudos=()

json_names=()
json_paths=()
json_risks=()
json_bytes=()
json_statuses=()

total_reclaimable_bytes=0
only_target_matched=false

# First pass: Parse config line-by-line safely and analyze targets
status_echo "${BOLD}Analyzing targets...${NC}"

# Read configuration file line by line
config_lineno=0
while IFS= read -r config_line || [[ -n "$config_line" ]]; do
  # Track the physical (1-based) line number for every line (comments and
  # blanks included) so error messages can cite the real line.
  config_lineno=$((config_lineno + 1))
  # Expose the true (nominal) field count: fields are pipe-delimited, so the
  # count is the number of '|' delimiters plus one. Counting delimiters stays
  # correct even when trailing optional fields are empty (unlike an array length).
  config_pipes="${config_line//[^|]/}"
  field_count=$(( ${#config_pipes} + 1 ))
  # Split into the named fields (fields beyond the 7th collapse into the last).
  IFS='|' read -r risk name raw_path desc min_age check_procs custom_clean_cmd <<< "$config_line"
  # Trim and check empty/comment
  risk=$(trim "$risk")
  [[ -z "$risk" || "$risk" =~ ^# ]] && continue
  
  # Enforce the field-count contract (5-7 fields): RISK, NAME, PATH, DESCRIPTION,
  # and MIN_AGE_DAYS are required; CHECK_PROCESSES and CUSTOM_ACTION are optional.
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
  
  # Reject empty required fields (a strong field-shift signal) before use.
  if [[ -z "$name" ]]; then
    echo -e "${RED}Error: ${CONFIG_FILE}:${config_lineno}: NAME (field 2) is empty${NC}" >&2
    exit 1
  fi
  if [[ -z "$raw_path" ]]; then
    echo -e "${RED}Error: ${CONFIG_FILE}:${config_lineno}: PATH (field 3) is empty${NC}" >&2
    exit 1
  fi

  if [[ -n "$ONLY_TARGET" ]]; then
    if [[ "$name" != *"$ONLY_TARGET"* ]]; then
      continue
    fi
    only_target_matched=true
  fi

  # Minimal CHECK_PROCESSES shape check: reject empty/whitespace-only tokens or
  # stray commas (a field-shift signal); normal comma-separated names are fine.
  if [[ -n "$check_procs" && "$check_procs" =~ (^|,)[[:space:]]*(,|$) ]]; then
    echo -e "${RED}Error: ${CONFIG_FILE}:${config_lineno}: malformed CHECK_PROCESSES '${check_procs}' (empty or stray comma-separated token)${NC}" >&2
    exit 1
  fi

  # Validate custom clean action if provided
  if [[ -n "$custom_clean_cmd" ]]; then
    case "$custom_clean_cmd" in
      action:paccache_keep1|action:paccache_keep2|action:paccache_keep3|action:pacman_clean|action:apt_clean|action:dnf_clean)
        ;;
      *)
        echo -e "${RED}${CONFIG_FILE}:${config_lineno}: Error: Unknown action '$custom_clean_cmd' in target '$name'.${NC}" >&2
        exit 1
        ;;
    esac
  fi
  
  # Map risk levels
  target_risk_int=$(risk_to_int "$risk" "${CONFIG_FILE}:${config_lineno}: ") || exit 1
  if [[ $target_risk_int -gt $MAX_RISK_INT ]]; then
    # Skip target quietly or verbosely
    continue
  fi
  
  # Validate age number: empty stays effective 0 (documented whole-directory
  # case); a non-empty non-numeric value is a hard error (likely a field shift).
  if [[ -z "$min_age" ]]; then
    min_age=0
  elif [[ ! "$min_age" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}Error: ${CONFIG_FILE}:${config_lineno}: invalid MIN_AGE_DAYS '${min_age}'${NC}" >&2
    exit 1
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
  use_sudo=false
  target_status=""
  
  if [[ $safety_status -eq 1 ]]; then
    target_status=unsafe
    status_echo "  [${RED}UNSAFE${NC}] $name: Path '$path' is a protected system directory! Skipping."
  elif [[ $safety_status -eq 3 ]]; then
    target_status=symlink
    status_echo "  [${RED}SYMLINK${NC}] $name: Refusing to delete symlink target '$path'. Skipping."
    safety_status=1 # Treat as completely unsafe to skip deletion later
  else
    # Enforce outside HOME restriction unless flag is set
    if [[ $safety_status -eq 2 && "$ALLOW_OUTSIDE_HOME" != true ]]; then
      target_status=rejected
      status_echo "  [${RED}REJECTED${NC}] $name: Path '$path' is outside HOME and --allow-outside-home is not set. Skipping."
      safety_status=1 # Skipped
    else
      # Check if running processes block this target
      running_proc=$(is_process_running "$check_procs" || true)
      if [[ -n "$running_proc" ]]; then
        target_status=blocked
        status_echo "  [${YELLOW}BLOCKED${NC}] $name: Skip cleanup because process '$running_proc' is active."
      else
        # Determine if sudo is needed
        requires_sudo=false
        if [[ "$custom_clean_cmd" == action:* ]] || \
           [[ -e "$path" && ! -r "$path" ]] || \
           { [[ ! -e "$path" ]] && [[ "$safety_status" -eq 2 ]] && [[ ! -w "$(dirname "$path" 2>/dev/null || echo /)" ]]; }; then
          requires_sudo=true
          use_sudo=true
          if [[ "$DRY_RUN" = false ]]; then
            ensure_sudo
          else
            if ! sudo -n true 2>/dev/null; then
              use_sudo=false
            fi
          fi
        fi

        if [[ "$DRY_RUN" = true ]] && [[ "$requires_sudo" = true ]] && [[ "$use_sudo" = false ]]; then
          # Try to get size without sudo. If it's readable, we show it, but warn that sudo is required for cleanup
          size_bytes=$(get_size_bytes "$path" "$min_age" false)
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
          path_exists=false
          if [[ "$use_sudo" = true ]]; then
            if sudo test -e "$path" || sudo test -L "$path"; then
              path_exists=true
            fi
          else
            if [[ -e "$path" || -L "$path" ]]; then
              path_exists=true
            fi
          fi

          if [[ "$path_exists" = true ]]; then
            size_bytes=$(get_size_bytes "$path" "$min_age" "$use_sudo")
            readable_size=$(format_bytes "$size_bytes")
            
            should_clean=false
            if [[ "$min_age" -gt 0 ]]; then
              if has_matching_files "$path" "$min_age" "$use_sudo"; then
                should_clean=true
              fi
            else
              if [[ "$use_sudo" = true ]]; then
                is_dir=false
                if sudo test -d "$path" && ! sudo test -L "$path"; then is_dir=true; fi
                if [[ "$is_dir" = false ]] || [[ "$size_bytes" -gt 0 ]]; then
                  should_clean=true
                fi
              else
                if [[ ! -d "$path" ]] || [[ "$size_bytes" -gt 0 ]]; then
                  should_clean=true
                fi
              fi
            fi
            
            if [[ "$should_clean" = true ]]; then
              exists=true
              total_reclaimable_bytes=$((total_reclaimable_bytes + size_bytes))
              
              if [[ $safety_status -eq 2 ]]; then
                target_status=found
                status_echo "  [${YELLOW}WARNING${NC}] $name ($readable_size): Path '$path' is outside HOME (Risk: $risk)."
              else
                target_status=found
                if [[ "$min_age" -gt 0 ]]; then
                  status_echo "  [${GREEN}FOUND${NC}] $name ($readable_size): $desc (Files > $min_age days)"
                else
                  status_echo "  [${GREEN}FOUND${NC}] $name ($readable_size): $desc"
                fi
              fi
            else
              target_status=clean
              if [[ "$min_age" -gt 0 ]]; then
                status_echo "  [${BLUE}CLEAN${NC}] $name: No files older than $min_age days."
              else
                status_echo "  [${BLUE}CLEAN${NC}] $name: Target size is 0 B."
              fi
            fi
          else
            target_status=missing
            status_echo "  [${BLUE}CLEAN${NC}] $name: Path '$path' does not exist."
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
    json_statuses+=("${target_status:-skipped}")
  fi

  # Keep track of valid targets for execution
  parsed_names+=("$name")
  parsed_paths+=("$path")
  parsed_descs+=("$desc")
  parsed_sizes+=("$size_bytes")
  parsed_exists+=("$exists")
  parsed_safety+=("$safety_status")
  parsed_ages+=("$min_age")
  parsed_risks+=("$risk")
  parsed_cmds+=("$custom_clean_cmd")
  parsed_sudos+=("$use_sudo")
  
done < "$CONFIG_FILE"

if [[ -n "$ONLY_TARGET" && "$only_target_matched" != true ]]; then
  echo -e "${RED}Error: No config target NAME matches '--only-target ${ONLY_TARGET}'.${NC}" >&2
  exit 1
fi

if [[ "$JSON_OUTPUT" == true ]]; then
  emit_dry_run_json
  exit 0
fi

echo
echo -e "${BOLD}Total potential space savings: ${GREEN}$(format_bytes "$total_reclaimable_bytes")${NC}"
echo

# If dry-run is specified, we stop here
if [[ "$DRY_RUN" = true ]]; then
  status_echo "${YELLOW}Dry-run mode active. No files were modified.${NC}"
  exit 0
fi

# Check if there is anything to clean
if [[ "$total_reclaimable_bytes" -eq 0 ]]; then
  echo -e "${GREEN}No files need cleaning. Everything is already clean!${NC}"
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

# Create a quarantine timestamp directory if in trash mode
QUARANTINE_DIR=""
if [[ "$TRASH_MODE" = true && "$total_reclaimable_bytes" -gt 0 ]]; then
  time_stamp=$(date +%Y-%m-%d_%H-%M-%S)
  QUARANTINE_DIR="$HOME/.cache/linux-cleaner/quarantine/$time_stamp"
  mkdir -p "$QUARANTINE_DIR"
  status_echo "Quarantine directory: ${YELLOW}$QUARANTINE_DIR${NC}"
fi

for i in "${!parsed_names[@]}"; do
  name="${parsed_names[$i]}"
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
  
  # Dangerous Confirmation Guard
  danger_prompted=false
  if [[ "${risk_level,,}" =~ ^danger(ous)?$ && "$YES_DANGER" != true ]]; then
    echo -n -e "${RED}Danger target '$name' ($path) requires explicit confirmation. Clean anyway? [y/N]: ${NC}"
    read -r reply || true
    if [[ ! "$reply" =~ ^[yY](es)?$ ]]; then
      status_echo "  Skipping $name..."
      continue
    fi
    danger_prompted=true
  fi
  
  # If outside home and not forced, extra warning
  if [[ "$safety" -eq 2 && "$FORCE" != true && "$proceed_all" = true && "$danger_prompted" != true ]]; then
    echo -n -e "${YELLOW}Warning: Target '$name' points outside HOME ('$path'). Clean anyway? [y/N]: ${NC}"
    read -r reply || true
    if [[ ! "$reply" =~ ^[yY](es)?$ ]]; then
      status_echo "  Skipping $name..."
      continue
    fi
  fi
  
  # Interactive mode confirmation (ask for each target)
  if [[ "$INTERACTIVE" = true && "$proceed_all" = false && "$danger_prompted" != true ]]; then
    readable_size=$(format_bytes "$size")
    if [[ "$age" -gt 0 ]]; then
      echo -n -e "Clean old files (> $age days) in '$name' ($readable_size) at '$path'? [y/N]: "
    else
      echo -n -e "Clean target '$name' ($readable_size) at '$path'? [y/N]: "
    fi
    read -r reply || true
    if [[ ! "$reply" =~ ^[yY](es)?$ ]]; then
      status_echo "  Skipping $name..."
      continue
    fi
  fi
  
  # Handle Cleanup
  custom_clean_cmd="${parsed_cmds[$i]:-}"
  use_sudo="${parsed_sudos[$i]:-false}"
  cleanup_bytes_before=$total_deleted_bytes

  if [[ -n "$custom_clean_cmd" ]]; then
    # Safe degradation: skip an action whose actual binary is absent, before any
    # sudo call (e.g. paccache when pacman-contrib is not installed, or apt/dnf on
    # the wrong distro), so it is a clean skip rather than a failed sudo call.
    required_bin=$(action_required_binary "$custom_clean_cmd")
    if [[ -n "$required_bin" ]] && ! command -v "$required_bin" >/dev/null 2>&1; then
      status_echo "  [${YELLOW}SKIP${NC}] $name: skipped: '$required_bin' not available on this platform."
      continue
    fi
    if [[ "$TRASH_MODE" = true ]]; then
      status_echo "  ${YELLOW}WARNING:${NC} Target '$name' uses a predefined action. This action will bypass quarantine and run directly (irreversible deletion)!"
    else
      status_echo "  Executing action for ${YELLOW}$name${NC}..."
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
    esac
    if [[ "$action_success" = true ]]; then
      total_deleted_bytes=$((total_deleted_bytes + size))
      log_operation "$(date '+%Y-%m-%dT%H:%M:%S') mode=action risk=${risk_level} target='${name}' path='${path}' action=${custom_clean_cmd} outcome=success"
    else
      echo -e "  ${RED}Error: Action '$custom_clean_cmd' for '$name' failed.${NC}" >&2
      OPERATION_FAILED=true
      log_operation "$(date '+%Y-%m-%dT%H:%M:%S') mode=action risk=${risk_level} target='${name}' path='${path}' action=${custom_clean_cmd} outcome=failed"
    fi
    continue
  fi

  if [[ "$TRASH_MODE" = true ]]; then
    status_echo "  Moving ${YELLOW}$name${NC} to quarantine..."
    
    safe_name=$(printf '%s' "$name" | tr '/[:space:]' '__')
    q_target="$QUARANTINE_DIR/${i}_${safe_name}"
    
    if [[ "$use_sudo" = true ]]; then
      sudo mkdir -p "$(dirname "$q_target")"
    else
      mkdir -p "$(dirname "$q_target")"
    fi
    
    # Determine if target is a directory and if symlink
    is_dir=false
    is_link=false
    if [[ "$use_sudo" = true ]]; then
      if sudo test -d "$path" && ! sudo test -L "$path"; then is_dir=true; fi
      if sudo test -L "$path"; then is_link=true; fi
    else
      if [[ -d "$path" && ! -L "$path" ]]; then is_dir=true; fi
      if [[ -L "$path" ]]; then is_link=true; fi
    fi

    success=true
    owner_info=""
    if [[ "$use_sudo" = true ]]; then
      owner_info=$(sudo stat -c '%u|%g' "$path" 2>/dev/null || echo "0|0")
    else
      owner_info=$(stat -c '%u|%g' "$path" 2>/dev/null || echo "$(id -u)|$(id -g)")
    fi

    if [[ "$age" -gt 0 || -n "${EXCLUDE_PATTERNS:-}" ]]; then
      # File-by-file quarantine
      if [[ "$is_dir" = true && "$is_link" = false ]]; then
        # Record aged quarantine metadata
        echo "aged|${i}_${safe_name}|$path|$use_sudo|$owner_info" >> "$QUARANTINE_DIR/quarantine.meta"
        
        find_mtime_args=()
        if [[ "$age" -gt 0 ]]; then
          find_mtime_args+=("-mtime" "+$age")
        fi
        
        if [[ "$use_sudo" = true ]]; then
          sudo mkdir -p "$q_target"
          while IFS= read -r -d '' file; do
            rel_path="${file#"$path"/}"
            dest_file="$q_target/$rel_path"
            sudo mkdir -p "$(dirname "$dest_file")"
            if ! sudo mv "$file" "$dest_file"; then
              success=false
            fi
          done < <(sudo find "$path" -mindepth 1 "${EXCLUDE_FIND_ARGS[@]}" \( -type f -o -type l \) "${find_mtime_args[@]}" -print0)
          sudo chown -R "$(id -u):$(id -g)" "$q_target"
          sudo find "$path" -mindepth 1 -type d -empty -delete 2>/dev/null || true
        else
          mkdir -p "$q_target"
          while IFS= read -r -d '' file; do
            rel_path="${file#"$path"/}"
            dest_file="$q_target/$rel_path"
            mkdir -p "$(dirname "$dest_file")"
            if ! mv "$file" "$dest_file"; then
              success=false
            fi
          done < <(find "$path" -mindepth 1 "${EXCLUDE_FIND_ARGS[@]}" \( -type f -o -type l \) "${find_mtime_args[@]}" -print0)
          find "$path" -mindepth 1 -type d -empty -delete 2>/dev/null || true
        fi
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
    fi
    
  else
    # Permanent Deletion Mode
    # Determine if target is a directory and if symlink
    is_dir=false
    is_link=false
    if [[ "$use_sudo" = true ]]; then
      if sudo test -d "$path" && ! sudo test -L "$path"; then is_dir=true; fi
      if sudo test -L "$path"; then is_link=true; fi
    else
      if [[ -d "$path" && ! -L "$path" ]]; then is_dir=true; fi
      if [[ -L "$path" ]]; then is_link=true; fi
    fi

    if [[ "$age" -gt 0 || -n "${EXCLUDE_PATTERNS:-}" ]]; then
      if [[ "$is_dir" = true && "$is_link" = false ]]; then
        find_mtime_args=()
        if [[ "$age" -gt 0 ]]; then
          find_mtime_args+=("-mtime" "+$age")
        fi
        
        if [[ "$use_sudo" = true ]]; then
          status_echo "  Cleaning filtered files in ${YELLOW}$name${NC} with sudo..."
          if sudo find "$path" -mindepth 1 "${EXCLUDE_FIND_ARGS[@]}" \( -type f -o -type l \) "${find_mtime_args[@]}" -delete && \
             sudo find "$path" -mindepth 1 -type d -empty -delete 2>/dev/null; then
            total_deleted_bytes=$((total_deleted_bytes + size))
          else
            echo -e "  ${RED}Error: Failed to completely clean aged/filtered files in '$path' with sudo${NC}" >&2
            OPERATION_FAILED=true
          fi
        else
          status_echo "  Cleaning filtered files in ${YELLOW}$name${NC}..."
          if find "$path" -mindepth 1 "${EXCLUDE_FIND_ARGS[@]}" \( -type f -o -type l \) "${find_mtime_args[@]}" -delete && \
             find "$path" -mindepth 1 -type d -empty -delete 2>/dev/null; then
            total_deleted_bytes=$((total_deleted_bytes + size))
          else
            echo -e "  ${RED}Error: Failed to completely clean aged/filtered files in '$path'${NC}" >&2
            OPERATION_FAILED=true
          fi
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
    if [[ "$total_deleted_bytes" -gt "$cleanup_bytes_before" ]]; then
      op_outcome=success
    else
      op_outcome=attempted
    fi
    if [[ "$TRASH_MODE" = true ]]; then
      log_operation "$(date '+%Y-%m-%dT%H:%M:%S') mode=quarantine risk=${risk_level} target='${name}' path='${path}' outcome=${op_outcome}"
    else
      log_operation "$(date '+%Y-%m-%dT%H:%M:%S') mode=delete risk=${risk_level} target='${name}' path='${path}' outcome=${op_outcome}"
    fi
  fi
done

echo
if [[ "$TRASH_MODE" = true ]]; then
  echo -e "${BOLD}${GREEN}Cleanup finished! Total space quarantined: $(format_bytes "$total_deleted_bytes")${NC}"
else
  echo -e "${BOLD}${GREEN}Cleanup finished! Total space permanently reclaimed: $(format_bytes "$total_deleted_bytes")${NC}"
fi

# Report a non-zero status when any target failed, so an unattended run (cron,
# systemd) can detect a failure that was otherwise only printed to stderr.
if [[ "$OPERATION_FAILED" = true ]]; then
  echo -e "${RED}One or more targets failed to clean; see the errors above.${NC}" >&2
  exit 1
fi
