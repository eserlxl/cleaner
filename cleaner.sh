#!/usr/bin/env bash

# Linux Cache and Temp File Cleaner
# A script to safely clean unnecessary files and folders.

set -euo pipefail

# Determine script directory to find the default configuration file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG="$SCRIPT_DIR/cleaner.conf"
CONFIG_FILE="$DEFAULT_CONFIG"

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
  -d, --dry-run              Calculate and display potential space savings without deleting anything.
  -i, --interactive          Prompt for confirmation before cleaning each target.
  -f, --force                Perform cleaning immediately without any confirmation prompts.
  -t, --trash                Move files to quarantine instead of permanent deletion.
  -r, --risk LEVEL           Max risk level to clean: safe, medium, danger (default: safe).
  --allow-outside-home       Explicitly allow cleaning targets outside user's HOME directory.
  -h, --help                 Display this help message and exit.
EOF
}

# Default flags
DRY_RUN=false
INTERACTIVE=false
FORCE=false
TRASH_MODE=false
MAX_RISK="safe"
ALLOW_OUTSIDE_HOME=false

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
    -i|--interactive)
      INTERACTIVE=true
      shift
      ;;
    -f|--force)
      FORCE=true
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
    --allow-outside-home)
      ALLOW_OUTSIDE_HOME=true
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

# Check if config file exists
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo -e "${RED}Error: Configuration file not found at '$CONFIG_FILE'${NC}" >&2
  exit 1
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
  normalized=$(realpath -m "$target_path")
  
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
  
  if [[ "$age_days" -le 0 ]]; then
    [[ -e "$target_path" ]] && return 0
    return 1
  fi
  
  if [[ -d "$target_path" ]]; then
    # Check if there is any file inside older than age_days
    # find -print -quit exits 0 if a match is found
    [[ -n $(find "$target_path" -mindepth 1 -type f -mtime +"$age_days" -print -quit) ]] && return 0
  else
    # Single file
    [[ -n $(find "$target_path" -mtime +"$age_days" -print -quit) ]] && return 0
  fi
  return 1
}

# Calculate size in bytes using du (takes into account min_age if set)
get_size_bytes() {
  local target_path="$1"
  local age_days="${2:-0}"
  
  if [[ ! -e "$target_path" ]]; then
    echo 0
    return
  fi
  
  if [[ "$age_days" -gt 0 ]]; then
    if [[ -d "$target_path" ]]; then
      # Sum size of files older than age_days within the directory
      find "$target_path" -mindepth 1 -type f -mtime +"$age_days" -exec du -sb {} + 2>/dev/null | awk '{sum+=$1} END {print sum+0}'
    else
      # If target is a file, check if it's older than age_days
      if [[ $(find "$target_path" -mtime +"$age_days") ]]; then
        du -sb "$target_path" 2>/dev/null | awk '{print $1}' || echo 0
      else
        echo 0
      fi
    fi
  else
    # Apparent size of entire target
    du -sb "$target_path" 2>/dev/null | awk '{print $1}' || echo 0
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
    *) echo 1 ;;
  esac
}

# Parse custom max risk
MAX_RISK_INT=$(risk_to_int "$MAX_RISK")

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

total_reclaimable_bytes=0

# First pass: Parse config line-by-line safely and analyze targets
echo -e "${BOLD}Analyzing targets...${NC}"

# Read configuration file line by line
while IFS='|' read -r risk name raw_path desc min_age check_procs || [[ -n "$risk" ]]; do
  # Trim and check empty/comment
  risk=$(trim "$risk")
  [[ -z "$risk" || "$risk" =~ ^# ]] && continue
  
  name=$(trim "$name")
  raw_path=$(trim "$raw_path")
  desc=$(trim "$desc")
  min_age=$(trim "$min_age")
  check_procs=$(trim "${check_procs:-}")
  
  # Map risk levels
  target_risk_int=$(risk_to_int "$risk")
  if [[ $target_risk_int -gt $MAX_RISK_INT ]]; then
    # Skip target quietly or verbosely
    continue
  fi
  
  # Validate age number
  if [[ ! "$min_age" =~ ^[0-9]+$ ]]; then
    min_age=0
  fi
  
  # Safe path expansions & cleanup trailing slashes
  expanded_path=$(expand_path_safe "$raw_path")
  stripped_path=$(strip_trailing_slashes "$expanded_path")
  
  # Resolve to canonical
  path=$(realpath -m "$stripped_path")
  
  # Run safety check
  safety_status=0
  if [[ -L "$stripped_path" ]]; then
    safety_status=3
  else
    check_path_safety "$path" || safety_status=$?
  fi
  
  exists=false
  size_bytes=0
  
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
        if [[ -e "$path" ]]; then
          size_bytes=$(get_size_bytes "$path" "$min_age")
          readable_size=$(format_bytes "$size_bytes")
          
          should_clean=false
          if [[ "$min_age" -gt 0 ]]; then
            if has_matching_files "$path" "$min_age"; then
              should_clean=true
            fi
          else
            if [[ ! -d "$path" ]] || [[ "$size_bytes" -gt 0 ]]; then
              should_clean=true
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
  
  # Keep track of valid targets for execution
  parsed_names+=("$name")
  parsed_paths+=("$path")
  parsed_descs+=("$desc")
  parsed_sizes+=("$size_bytes")
  parsed_exists+=("$exists")
  parsed_safety+=("$safety_status")
  parsed_ages+=("$min_age")
  
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
  read -r reply
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
  
  # Skip targets that don't exist, are unsafe, or had 0 B reclaimable size
  if [[ "$exists" != true || "$safety" -eq 1 ]]; then
    continue
  fi
  
  # If outside home and not forced, extra warning
  if [[ "$safety" -eq 2 && "$FORCE" != true && "$proceed_all" = true ]]; then
    echo -n -e "${YELLOW}Warning: Target '$name' points outside HOME ('$path'). Clean anyway? [y/N]: ${NC}"
    read -r reply
    if [[ ! "$reply" =~ ^[yY](es)?$ ]]; then
      echo -e "  Skipping $name..."
      continue
    fi
  fi
  
  # Interactive mode confirmation (ask for each target)
  if [[ "$INTERACTIVE" = true && "$proceed_all" = false ]]; then
    readable_size=$(format_bytes "$size")
    if [[ "$age" -gt 0 ]]; then
      echo -n -e "Clean old files (> $age days) in '$name' ($readable_size) at '$path'? [y/N]: "
    else
      echo -n -e "Clean target '$name' ($readable_size) at '$path'? [y/N]: "
    fi
    read -r reply
    if [[ ! "$reply" =~ ^[yY](es)?$ ]]; then
      echo -e "  Skipping $name..."
      continue
    fi
  fi
  
  # Handle Cleanup
  if [[ "$TRASH_MODE" = true ]]; then
    echo -e "  Moving ${YELLOW}$name${NC} to quarantine..."
    
    q_target="$QUARANTINE_DIR/$name"
    mkdir -p "$(dirname "$q_target")"
    
    success=true
    if [[ "$age" -gt 0 ]]; then
      # Age filtered quarantine: Move only matching files, recreate relative structure
      mkdir -p "$q_target"
      # Find and process
      while IFS= read -r -d '' file; do
        rel_path="${file#$path/}"
        dest_file="$q_target/$rel_path"
        mkdir -p "$(dirname "$dest_file")"
        if ! mv "$file" "$dest_file"; then
          success=false
        fi
      done < <(find "$path" -mindepth 1 -type f -mtime +"$age" -print0)
      
      # Prune empty subdirs
      find "$path" -mindepth 1 -type d -empty -delete 2>/dev/null || true
    else
      # Full folder quarantine
      if ! mv "$path" "$q_target"; then
        success=false
      fi
    fi
    
    if [[ "$success" = true ]]; then
      total_deleted_bytes=$((total_deleted_bytes + size))
    else
      echo -e "  ${RED}Error: Failed to move some files for '$name' to quarantine.${NC}" >&2
    fi
    
  else
    # Permanent Deletion Mode
    if [[ "$age" -gt 0 ]]; then
      echo -e "  Cleaning files older than $age days in ${YELLOW}$name${NC}..."
      if find "$path" -mindepth 1 -type f -mtime +"$age" -delete && \
         find "$path" -mindepth 1 -type d -empty -delete 2>/dev/null; then
        total_deleted_bytes=$((total_deleted_bytes + size))
      else
        echo -e "  ${RED}Error: Failed to completely clean aged files in '$path'${NC}" >&2
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
done

echo
if [[ "$TRASH_MODE" = true ]]; then
  echo -e "${BOLD}${GREEN}Cleanup finished! Total space quarantined: $(format_bytes "$total_deleted_bytes")${NC}"
else
  echo -e "${BOLD}${GREEN}Cleanup finished! Total space permanently reclaimed: $(format_bytes "$total_deleted_bytes")${NC}"
fi
