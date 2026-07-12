#!/usr/bin/env bash

# Linux Cache and Temp File Cleaner
# A script to safely clean unnecessary files and folders.

set -euo pipefail

# Determine script directory to find the default configuration file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG="$SCRIPT_DIR/cleaner.conf"
CONFIG_FILE="$DEFAULT_CONFIG"

# Single source of truth for the tool version (semantic version).
readonly VERSION="1.0.0"

# Colors for terminal output
if [[ -t 1 ]]; then
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
  -c, --config FILE          Path to custom configuration file (default: ./cleaner.conf)
  -d, --dry-run              Calculate and display potential space savings without deleting anything (default).
  --clean                    Perform cleanup with a summary confirmation prompt.
  -i, --interactive          Prompt for confirmation before cleaning each target.
  -f, --force                Perform cleaning immediately without any confirmation prompts (except danger level).
  --yes-danger               Bypass manual confirmation prompt for danger risk targets.
  -t, --trash                Move files to quarantine instead of permanent deletion.
  -r, --risk LEVEL           Max risk level to clean: safe, medium, danger (default: safe).
  -e, --exclude PATTERNS     Comma-separated glob patterns to exclude (Warning: Incorrect patterns can affect deletion semantics or exclude everything).
  --list-sessions            List quarantine sessions (read-only) and exit.
  --restore SESSION          Restore files from quarantine session (latest or timestamp).
  --allow-outside-home       Explicitly allow cleaning targets outside user's HOME directory.
  -h, --help                 Display this help message and exit.
  -V, --version              Print the tool version and exit.
EOF
}

# Default flags
DRY_RUN=true
INTERACTIVE=false
FORCE=false
YES_DANGER=false
TRASH_MODE=false
MAX_RISK="safe"
ALLOW_OUTSIDE_HOME=false
EXCLUDE_PATTERNS=""
RESTORE_TARGET=""
LIST_SESSIONS=false

# Operation log (opt-in, OFF by default). Enable via --log or by setting the
# LINUX_CLEANER_LOG environment variable. The log lives under $HOME (see the
# writer). When disabled, no log file is created or written.
LOG_ENABLED=false
LOG_FILE=""
if [[ -n "${LINUX_CLEANER_LOG:-}" ]]; then
  LOG_ENABLED=true
  LOG_FILE="$LINUX_CLEANER_LOG"
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
    --allow-outside-home)
      ALLOW_OUTSIDE_HOME=true
      shift
      ;;
    -V|--version)
      echo "$(basename "$0") $VERSION"
      exit 0
      ;;
    --list-sessions)
      LIST_SESSIONS=true
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

# Check if config file exists (only if not restoring or listing sessions)
if [[ -z "${RESTORE_TARGET:-}" && "$LIST_SESSIONS" != true ]]; then
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

# Expand standard environment variables in a safe way (avoiding eval)
expand_path_safe() {
  local raw_path="$1"
  local expanded="$raw_path"
  
  # Safe leading ~ expansion
  # shellcheck disable=SC2088
  case "$expanded" in
    "~") expanded="$HOME" ;;
    "~/"*) expanded="$HOME/${expanded#~/}" ;;
  esac
  
  # Replace $HOME and $USER anywhere they appear
  expanded="${expanded//\$HOME/$HOME}"
  expanded="${expanded//\$USER/$USER}"
  
  echo "$expanded"
}

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
  local literal_dir resolved_dir
  literal_dir=$(dirname "$target")
  resolved_dir=$(canonicalize_physical "$literal_dir")
  if [[ "$resolved_dir" != "$HOME" && "$resolved_dir" != "$HOME"/* ]]; then
    echo -e "  [${YELLOW}LOG${NC}] Refusing to write log outside \$HOME ('$target'); logging disabled." >&2
    LOG_ENABLED=false
    return 0
  fi
  if ! { mkdir -p "$literal_dir" && printf '%s\n' "$message" >> "$target"; } 2>/dev/null; then
    echo -e "  [${YELLOW}LOG${NC}] Warning: could not write to log '$target'." >&2
  fi
}

# List quarantine sessions (strictly read-only): print each session's
# timestamp (directory name), size, and modification date. Never moves,
# deletes, or modifies any session or its metadata.
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
  done
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
  local type rel_path original_path use_sudo uid gid
  local overall_success=true
  while IFS='|' read -r type rel_path original_path use_sudo uid gid _ || [[ -n "$type" ]]; do
    type=$(trim "$type")
    [[ -z "$type" || "$type" =~ ^# ]] && continue
    
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
          sudo chown -hR "$uid:$gid" "$original_path"
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
            sudo chown -h "$uid:$gid" "$dest_file"
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
    fi
  done < "$meta_file"
  
  if [[ "$overall_success" = true ]]; then
    echo -e "${BOLD}${GREEN}Restoration complete!${NC}"
    rm -rf "$restore_dir"
    rmdir "$quarantine_base" 2>/dev/null || true
  else
    echo -e "${RED}Error: Restoration completed with some errors. The quarantine session has been kept at '$restore_dir' for recovery.${NC}" >&2
    exit 1
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

# Parse custom max risk
MAX_RISK_INT=$(risk_to_int "$MAX_RISK") || exit 1

# Build exclude arguments for find
build_exclude_find_args

# Read-only: list quarantine sessions and exit
if [[ "$LIST_SESSIONS" == true ]]; then
  list_quarantine_sessions
  exit 0
fi

# Check if restore mode is active
if [[ -n "${RESTORE_TARGET:-}" ]]; then
  restore_quarantine "$RESTORE_TARGET"
  exit 0
fi

# Header output
echo -e "${BOLD}${BLUE}=== Linux Cache & Temp File Cleaner ===${NC}"
echo -e "Config file: ${YELLOW}$CONFIG_FILE${NC}"
echo -e "Max Risk Level: ${YELLOW}$MAX_RISK${NC}"
if [[ "$TRASH_MODE" = true ]]; then
  echo -e "Trash mode: ${GREEN}ON (Quarantine)${NC}"
else
  echo -e "Trash mode: ${RED}OFF (Permanent deletion)${NC}"
fi
echo

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

total_reclaimable_bytes=0

# First pass: Parse config line-by-line safely and analyze targets
echo -e "${BOLD}Analyzing targets...${NC}"

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

  # Minimal CHECK_PROCESSES shape check: reject empty/whitespace-only tokens or
  # stray commas (a field-shift signal); normal comma-separated names are fine.
  if [[ -n "$check_procs" && "$check_procs" =~ (^|,)[[:space:]]*(,|$) ]]; then
    echo -e "${RED}Error: ${CONFIG_FILE}:${config_lineno}: malformed CHECK_PROCESSES '${check_procs}' (empty or stray comma-separated token)${NC}" >&2
    exit 1
  fi

  # Validate custom clean action if provided
  if [[ -n "$custom_clean_cmd" ]]; then
    case "$custom_clean_cmd" in
      action:paccache_keep1|action:paccache_keep2|action:paccache_keep3|action:pacman_clean)
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
  
  if [[ $safety_status -eq 1 ]]; then
    echo -e "  [${RED}UNSAFE${NC}] $name: Path '$path' is a protected system directory! Skipping."
  elif [[ $safety_status -eq 3 ]]; then
    echo -e "  [${RED}SYMLINK${NC}] $name: Refusing to delete symlink target '$path'. Skipping."
    safety_status=1 # Treat as completely unsafe to skip deletion later
  else
    # Enforce outside HOME restriction unless flag is set
    if [[ $safety_status -eq 2 && "$ALLOW_OUTSIDE_HOME" != true ]]; then
      echo -e "  [${RED}REJECTED${NC}] $name: Path '$path' is outside HOME and --allow-outside-home is not set. Skipping."
      safety_status=1 # Skipped
    else
      # Check if running processes block this target
      running_proc=$(is_process_running "$check_procs" || true)
      if [[ -n "$running_proc" ]]; then
        echo -e "  [${YELLOW}BLOCKED${NC}] $name: Skip cleanup because process '$running_proc' is active."
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
            echo -e "  [${YELLOW}ROOT${NC}] $name ($readable_size): Requires sudo; size may be inaccurate and sudo is required for cleanup."
            total_reclaimable_bytes=$((total_reclaimable_bytes + size_bytes))
          else
            echo -e "  [${YELLOW}ROOT${NC}] $name: Requires sudo; size is unavailable in dry-run."
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
                echo -e "  [${YELLOW}WARNING${NC}] $name ($readable_size): Path '$path' is outside HOME (Risk: $risk)."
              else
                if [[ "$min_age" -gt 0 ]]; then
                  echo -e "  [${GREEN}FOUND${NC}] $name ($readable_size): $desc (Files > $min_age days)"
                else
                  echo -e "  [${GREEN}FOUND${NC}] $name ($readable_size): $desc"
                fi
              fi
            else
              if [[ "$min_age" -gt 0 ]]; then
                echo -e "  [${BLUE}CLEAN${NC}] $name: No files older than $min_age days."
              else
                echo -e "  [${BLUE}CLEAN${NC}] $name: Target size is 0 B."
              fi
            fi
          else
            echo -e "  [${BLUE}CLEAN${NC}] $name: Path '$path' does not exist."
          fi
        fi
      fi
    fi
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

echo
echo -e "${BOLD}Total potential space savings: ${GREEN}$(format_bytes "$total_reclaimable_bytes")${NC}"
echo

# If dry-run is specified, we stop here
if [[ "$DRY_RUN" = true ]]; then
  echo -e "${YELLOW}Dry-run mode active. No files were modified.${NC}"
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

# Second pass: Perform deletion or move to quarantine
echo -e "${BOLD}Starting cleanup...${NC}"
total_deleted_bytes=0

# Create a quarantine timestamp directory if in trash mode
QUARANTINE_DIR=""
if [[ "$TRASH_MODE" = true && "$total_reclaimable_bytes" -gt 0 ]]; then
  time_stamp=$(date +%Y-%m-%d_%H-%M-%S)
  QUARANTINE_DIR="$HOME/.cache/linux-cleaner/quarantine/$time_stamp"
  mkdir -p "$QUARANTINE_DIR"
  echo -e "Quarantine directory: ${YELLOW}$QUARANTINE_DIR${NC}"
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
      echo -e "  Skipping $name..."
      continue
    fi
    danger_prompted=true
  fi
  
  # If outside home and not forced, extra warning
  if [[ "$safety" -eq 2 && "$FORCE" != true && "$proceed_all" = true && "$danger_prompted" != true ]]; then
    echo -n -e "${YELLOW}Warning: Target '$name' points outside HOME ('$path'). Clean anyway? [y/N]: ${NC}"
    read -r reply || true
    if [[ ! "$reply" =~ ^[yY](es)?$ ]]; then
      echo -e "  Skipping $name..."
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
      echo -e "  Skipping $name..."
      continue
    fi
  fi
  
  # Handle Cleanup
  custom_clean_cmd="${parsed_cmds[$i]:-}"
  use_sudo="${parsed_sudos[$i]:-false}"
  cleanup_bytes_before=$total_deleted_bytes

  if [[ -n "$custom_clean_cmd" ]]; then
    if [[ "$TRASH_MODE" = true ]]; then
      echo -e "  ${YELLOW}WARNING:${NC} Target '$name' uses a predefined action. This action will bypass quarantine and run directly (irreversible deletion)!"
    else
      echo -e "  Executing action for ${YELLOW}$name${NC}..."
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
    esac
    if [[ "$action_success" = true ]]; then
      total_deleted_bytes=$((total_deleted_bytes + size))
      log_operation "$(date '+%Y-%m-%dT%H:%M:%S') mode=action risk=${risk_level} target='${name}' path='${path}' action=${custom_clean_cmd} outcome=success"
    else
      echo -e "  ${RED}Error: Action '$custom_clean_cmd' for '$name' failed.${NC}" >&2
      log_operation "$(date '+%Y-%m-%dT%H:%M:%S') mode=action risk=${risk_level} target='${name}' path='${path}' action=${custom_clean_cmd} outcome=failed"
    fi
    continue
  fi

  if [[ "$TRASH_MODE" = true ]]; then
    echo -e "  Moving ${YELLOW}$name${NC} to quarantine..."
    
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
        echo "full|${i}_${safe_name}|$path|$use_sudo|$owner_info" >> "$QUARANTINE_DIR/quarantine.meta"
        if [[ "$use_sudo" = true ]]; then
          if sudo mv "$path" "$q_target" && sudo chown -R "$(id -u):$(id -g)" "$q_target"; then
            success=true
          else
            success=false
          fi
        else
          if ! mv "$path" "$q_target"; then
            success=false
          fi
        fi
      fi
    else
      # Full folder/file quarantine (no age limit, no exclusions)
      echo "full|${i}_${safe_name}|$path|$use_sudo|$owner_info" >> "$QUARANTINE_DIR/quarantine.meta"
      if [[ "$use_sudo" = true ]]; then
        if sudo mv "$path" "$q_target" && sudo chown -R "$(id -u):$(id -g)" "$q_target"; then
          success=true
        else
          success=false
        fi
      else
        if ! mv "$path" "$q_target"; then
          success=false
        fi
      fi
    fi
    
    if [[ "$success" = true ]]; then
      total_deleted_bytes=$((total_deleted_bytes + size))
    else
      echo -e "  ${RED}Error: Failed to move some files for '$name' to quarantine.${NC}" >&2
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
          echo -e "  Cleaning filtered files in ${YELLOW}$name${NC} with sudo..."
          if sudo find "$path" -mindepth 1 "${EXCLUDE_FIND_ARGS[@]}" \( -type f -o -type l \) "${find_mtime_args[@]}" -delete && \
             sudo find "$path" -mindepth 1 -type d -empty -delete 2>/dev/null; then
            total_deleted_bytes=$((total_deleted_bytes + size))
          else
            echo -e "  ${RED}Error: Failed to completely clean aged/filtered files in '$path' with sudo${NC}" >&2
          fi
        else
          echo -e "  Cleaning filtered files in ${YELLOW}$name${NC}..."
          if find "$path" -mindepth 1 "${EXCLUDE_FIND_ARGS[@]}" \( -type f -o -type l \) "${find_mtime_args[@]}" -delete && \
             find "$path" -mindepth 1 -type d -empty -delete 2>/dev/null; then
            total_deleted_bytes=$((total_deleted_bytes + size))
          else
            echo -e "  ${RED}Error: Failed to completely clean aged/filtered files in '$path'${NC}" >&2
          fi
        fi
      else
        # Single file or symlink deletion
        if [[ "$use_sudo" = true ]]; then
          echo -e "  Cleaning ${YELLOW}$name${NC} at '$path' with sudo..."
          if sudo rm -rf "$path"; then
            total_deleted_bytes=$((total_deleted_bytes + size))
          else
            echo -e "  ${RED}Error: Failed to delete '$path' with sudo${NC}" >&2
          fi
        else
          echo -e "  Cleaning ${YELLOW}$name${NC} at '$path'..."
          if rm -rf "$path"; then
            total_deleted_bytes=$((total_deleted_bytes + size))
          else
            echo -e "  ${RED}Error: Failed to delete '$path'${NC}" >&2
          fi
        fi
      fi
    else
      # Full folder/file deletion
      if [[ "$use_sudo" = true ]]; then
        echo -e "  Cleaning ${YELLOW}$name${NC} at '$path' with sudo..."
        if sudo rm -rf "$path"; then
          total_deleted_bytes=$((total_deleted_bytes + size))
        else
          echo -e "  ${RED}Error: Failed to delete '$path' with sudo${NC}" >&2
        fi
      else
        echo -e "  Cleaning ${YELLOW}$name${NC} at '$path'..."
        if rm -rf "$path"; then
          total_deleted_bytes=$((total_deleted_bytes + size))
        else
          echo -e "  ${RED}Error: Failed to delete '$path'${NC}" >&2
        fi
      fi
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
