#!/usr/bin/env bash

# Linux Cache and Temp File Cleaner
# A script to safely clean unnecessary files and folders.

# Exit on error in setup, but we want to handle command failures gracefully during deletion.
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
  -c, --config FILE       Path to custom configuration file (default: ./cleaner.conf)
  -d, --dry-run           Calculate and display potential space savings without deleting anything.
  -i, --interactive       Prompt for confirmation before cleaning each target.
  -f, --force             Perform cleaning immediately without any confirmation prompts.
  -h, --help              Display this help message and exit.

By default, the script runs in "interactive summary" mode: it calculates potential
savings, previews what will be deleted, and asks for a single confirmation before proceeding.
EOF
}

# Default flags
DRY_RUN=false
INTERACTIVE=false
FORCE=false

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

# Source configuration file to get the TARGETS array
# Shellcheck disable=SC1090
source "$CONFIG_FILE"

if [[ -z "${TARGETS:-}" || ${#TARGETS[@]} -eq 0 ]]; then
  echo -e "${RED}Error: No cleaning targets found in configuration file '${CONFIG_FILE}'.${NC}" >&2
  exit 1
fi

# Expand standard environment variables in a safe way (avoiding eval)
expand_path_safe() {
  local raw_path="$1"
  local expanded="$raw_path"
  
  # Replace $HOME and ~
  expanded="${expanded//\$HOME/$HOME}"
  expanded="${expanded//\~/$HOME}"
  # Replace $USER
  expanded="${expanded//\$USER/$USER}"
  
  echo "$expanded"
}

# Check if the path is safe to delete
# Returns:
#   0 if safe
#   1 if it is a sensitive system directory
#   2 if it is outside the user's HOME directory (warning level)
check_path_safety() {
  local target_path="$1"
  
  if [[ -z "$target_path" ]]; then
    return 1
  fi
  
  # Normalize trailing slashes
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
  
  # Warning if outside HOME directory
  if [[ "$normalized" != "$HOME" && "$normalized" != "$HOME"/* ]]; then
    return 2
  fi
  
  return 0
}

# Calculate size in bytes using du
get_size_bytes() {
  local target_path="$1"
  if [[ ! -e "$target_path" ]]; then
    echo 0
    return
  fi
  # du -sb: -s (summary/total), -b (apparent size in bytes)
  du -sb "$target_path" 2>/dev/null | awk '{print $1}' || echo 0
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
  
  # Use awk to handle division with float precision
  while [[ $(echo "$size >= 1024" | bc -l) -eq 1 && $unit_idx -lt 4 ]]; do
    size=$(awk "BEGIN {printf \"%.2f\", $size / 1024}")
    ((unit_idx++))
  done
  
  # Strip unnecessary trailing .00
  size=${size%.00}
  echo "$size ${units[$unit_idx]}"
}

# Define targets parsing logic
# Each target in config is separated by semicolon: NAME;PATH;DESCRIPTION
parse_target() {
  local entry="$1"
  IFS=';' read -r name raw_path desc <<< "$entry"
  
  local expanded_path
  expanded_path=$(expand_path_safe "$raw_path")
  
  local canonical_path
  canonical_path=$(realpath -m "$expanded_path")
  
  echo "$name|$canonical_path|$desc"
}

# Header output
echo -e "${BOLD}${BLUE}=== Linux Cache & Temp File Cleaner ===${NC}"
echo -e "Config file: ${YELLOW}$CONFIG_FILE${NC}"
echo

# Arrays to store processed target info
parsed_names=()
parsed_paths=()
parsed_descs=()
parsed_sizes=()
parsed_exists=()
parsed_safety=()

total_reclaimable_bytes=0

# First pass: Analyze targets
echo -e "${BOLD}Analyzing targets...${NC}"
for entry in "${TARGETS[@]}"; do
  # Skip empty or commented lines
  [[ -z "${entry// }" || "$entry" =~ ^# ]] && continue
  
  # Parse the entry
  IFS='|' read -r name path desc <<< "$(parse_target "$entry")"
  
  # Run safety check
  safety_status=0
  check_path_safety "$path" || safety_status=$?
  
  exists=false
  size_bytes=0
  
  if [[ $safety_status -eq 1 ]]; then
    echo -e "  [${RED}UNSAFE${NC}] $name: Path '$path' is a protected system directory! Skipping."
  else
    if [[ -e "$path" ]]; then
      exists=true
      size_bytes=$(get_size_bytes "$path")
      total_reclaimable_bytes=$((total_reclaimable_bytes + size_bytes))
      readable_size=$(format_bytes "$size_bytes")
      
      if [[ $safety_status -eq 2 ]]; then
        echo -e "  [${YELLOW}WARNING${NC}] $name ($readable_size): Path '$path' exists but is outside HOME."
      else
        echo -e "  [${GREEN}FOUND${NC}] $name ($readable_size): $desc"
      fi
    else
      echo -e "  [${BLUE}CLEAN${NC}] $name: Path '$path' does not exist."
    fi
  fi
  
  # Keep track of targets for execution phase
  parsed_names+=("$name")
  parsed_paths+=("$path")
  parsed_descs+=("$desc")
  parsed_sizes+=("$size_bytes")
  parsed_exists+=("$exists")
  parsed_safety+=("$safety_status")
done

echo
echo -e "${BOLD}Total potential space savings: ${GREEN}$(format_bytes "$total_reclaimable_bytes")${NC}"
echo

# If dry-run is specified, we stop here
if [[ "$DRY_RUN" = true ]]; then
  echo -e "${YELLOW}Dry-run mode active. No files were deleted.${NC}"
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

# Second pass: Perform deletion
echo -e "${BOLD}Starting cleanup...${NC}"
total_deleted_bytes=0

for i in "${!parsed_names[@]}"; do
  name="${parsed_names[$i]}"
  path="${parsed_paths[$i]}"
  size="${parsed_sizes[$i]}"
  exists="${parsed_exists[$i]}"
  safety="${parsed_safety[$i]}"
  
  # Skip targets that don't exist or are unsafe
  if [[ "$exists" != true || "$safety" -eq 1 ]]; then
    continue
  fi
  
  # If outside home and not forced, extra warning
  if [[ "$safety" -eq 2 && "$FORCE" != true && "$proceed_all" = true ]]; then
    echo -n -e "${YELLOW}Warning: Target '$name' points outside HOME ('$path'). Delete anyway? [y/N]: ${NC}"
    read -r reply
    if [[ ! "$reply" =~ ^[yY](es)?$ ]]; then
      echo -e "  Skipping $name..."
      continue
    fi
  fi
  
  # Interactive mode confirmation (ask for each target)
  if [[ "$INTERACTIVE" = true && "$proceed_all" = false ]]; then
    readable_size=$(format_bytes "$size")
    echo -n -e "Clean target '$name' ($readable_size) at '$path'? [y/N]: "
    read -r reply
    if [[ ! "$reply" =~ ^[yY](es)?$ ]]; then
      echo -e "  Skipping $name..."
      continue
    fi
  fi
  
  # Delete target
  echo -e "  Cleaning ${YELLOW}$name${NC} at '$path'..."
  
  # Run rm -rf wrapped in error handling
  if rm -rf "$path"; then
    total_deleted_bytes=$((total_deleted_bytes + size))
  else
    echo -e "  ${RED}Error: Failed to delete '$path'${NC}" >&2
  fi
done

echo
echo -e "${BOLD}${GREEN}Cleanup finished! Total space reclaimed: $(format_bytes "$total_deleted_bytes")${NC}"
