#!/usr/bin/env bash

# Automated test suite for cleaner.sh

set -euo pipefail

# Find absolute path of the cleaner.sh directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEANER_SH="$SCRIPT_DIR/cleaner.sh"

# Colors for test output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Setup test environment directories
TEST_ENV_DIR="$SCRIPT_DIR/test_env"
MOCK_HOME="$TEST_ENV_DIR/mock_home"
OUTSIDE_DIR="$TEST_ENV_DIR/outside_dir"

echo -e "${BOLD}${BLUE}=== Running Cleaner Test Suite ===${NC}"

# Cleanup function to run on exit
cleanup() {
  echo -e "${BLUE}Cleaning up test environment...${NC}"
  rm -rf "$TEST_ENV_DIR"
}
trap cleanup EXIT

# 1. Create mock directory structures
setup_mock_env() {
  cleanup &>/dev/null || true
  
  echo -e "${BLUE}Setting up mock directory structure...${NC}"
  mkdir -p "$MOCK_HOME/.npm/_cacache"
  mkdir -p "$MOCK_HOME/.gemini/tmp"
  mkdir -p "$MOCK_HOME/.cache/aurman"
  mkdir -p "$MOCK_HOME/.cache/yarn"
  mkdir -p "$OUTSIDE_DIR"
  
  # Create dummy files with specific sizes
  # dd or truncate works. Let's use echo/dd to populate
  echo "dummy npm cache" > "$MOCK_HOME/.npm/_cacache/cache1.txt"
  echo "dummy gemini temp file" > "$MOCK_HOME/.gemini/tmp/temp1.tmp"
  echo "dummy aurman pkg" > "$MOCK_HOME/.cache/aurman/pkg1.tar.zst"
  echo "dummy yarn cache" > "$MOCK_HOME/.cache/yarn/yarn-cache.json"
  echo "dummy file outside home" > "$OUTSIDE_DIR/outside.txt"
  
  # Create test configuration file
  cat << EOF > "$TEST_ENV_DIR/test_cleaner.conf"
TARGETS=(
  "NPM Cache;\$HOME/.npm/_cacache;Mock NPM cache"
  "Gemini Temp;\$HOME/.gemini/tmp;Mock Gemini temporary files"
  "Aurman Cache;\$HOME/.cache/aurman;Mock Aurman package cache"
  "Yarn Cache;\$HOME/.cache/yarn;Mock Yarn package cache"
  "Non-Existent Target;\$HOME/.cache/does_not_exist;Should be skipped gracefully"
  "Outside HOME;$OUTSIDE_DIR;Target outside HOME boundary"
  "System Directory;/usr;Unsafe system directory block test"
)
EOF
}

# Run a test and output result
run_test_case() {
  local test_name="$1"
  local expected_exit="$2"
  local log_filename="$3"
  shift 3
  
  echo -e "\n${BOLD}Test Case: $test_name${NC}"
  
  # Export mock HOME environment variable so cleaner.sh resolves $HOME inside our mock directory
  local exit_code=0
  HOME="$MOCK_HOME" "$CLEANER_SH" "$@" > "$TEST_ENV_DIR/$log_filename" 2>&1 || exit_code=$?
  
  if [[ $exit_code -ne $expected_exit ]]; then
    echo -e "${RED}FAIL: Expected exit code $expected_exit, got $exit_code${NC}"
    echo "--- Log Output ---"
    cat "$TEST_ENV_DIR/$log_filename"
    return 1
  fi
  
  return 0
}

# --- Test Case 1: Dry run test ---
setup_mock_env
if run_test_case "Dry Run Mode" 0 "dry_run.log" --config "$TEST_ENV_DIR/test_cleaner.conf" --dry-run; then
  # Verify that no files were deleted
  if [[ -f "$MOCK_HOME/.npm/_cacache/cache1.txt" ]] && \
     [[ -f "$MOCK_HOME/.gemini/tmp/temp1.tmp" ]] && \
     [[ -f "$OUTSIDE_DIR/outside.txt" ]]; then
    echo -e "${GREEN}PASS: Dry run completed and no files were deleted.${NC}"
  else
    echo -e "${RED}FAIL: Dry run deleted files!${NC}"
    exit 1
  fi
else
  exit 1
fi

# --- Test Case 2: Error handling on missing config ---
if run_test_case "Missing Config File" 1 "missing_config.log" --config "$TEST_ENV_DIR/non_existent.conf"; then
  # We expect error code 1
  if grep -q "Configuration file not found" "$TEST_ENV_DIR/missing_config.log"; then
    echo -e "${GREEN}PASS: Gracefully failed on missing config.${NC}"
  else
    echo -e "${RED}FAIL: Expected config file not found error message.${NC}"
    cat "$TEST_ENV_DIR/missing_config.log"
    exit 1
  fi
else
  exit 1
fi

# --- Test Case 3: Safe block of system directory ---
# Check if "/usr" is identified as UNSAFE in the dry run logs
if grep -q "UNSAFE.*System Directory" "$TEST_ENV_DIR/dry_run.log"; then
  echo -e "${GREEN}PASS: System directory '/usr' safety block detected and logged.${NC}"
else
  echo -e "${RED}FAIL: /usr was not blocked or logged as UNSAFE.${NC}"
  cat "$TEST_ENV_DIR/dry_run.log"
  exit 1
fi

# --- Test Case 4: Non-existent directory handling ---
# Check if non-existent target is logged as CLEAN in the dry run logs
if grep -q "CLEAN.*Non-Existent Target" "$TEST_ENV_DIR/dry_run.log"; then
  echo -e "${GREEN}PASS: Non-existent directory target handles cleanly.${NC}"
else
  echo -e "${RED}FAIL: Non-existent directory not flagged as CLEAN.${NC}"
  cat "$TEST_ENV_DIR/dry_run.log"
  exit 1
fi

# --- Test Case 5: Force Clean Mode ---
setup_mock_env
# We expect outside directory target warning prompt to be skipped or handled.
# In force mode:
# - System dir (/usr) should NOT be deleted (remains safe).
# - Targets in HOME should be deleted.
# - Target outside HOME ($OUTSIDE_DIR) should be deleted without prompts because of --force.
if run_test_case "Force Clean Mode" 0 "force_clean.log" --config "$TEST_ENV_DIR/test_cleaner.conf" --force; then
  # Check that mock home files are deleted
  if [[ ! -d "$MOCK_HOME/.npm/_cacache" ]] && \
     [[ ! -d "$MOCK_HOME/.gemini/tmp" ]] && \
     [[ ! -d "$MOCK_HOME/.cache/aurman" ]] && \
     [[ ! -d "$MOCK_HOME/.cache/yarn" ]]; then
    echo -e "${GREEN}PASS: Cache files inside home deleted.${NC}"
  else
    echo -e "${RED}FAIL: Files inside mock HOME were not deleted!${NC}"
    exit 1
  fi

  # Check that outside target was deleted under --force
  if [[ ! -d "$OUTSIDE_DIR" ]]; then
    echo -e "${GREEN}PASS: Target outside HOME deleted under force mode.${NC}"
  else
    echo -e "${RED}FAIL: Target outside HOME was not deleted in force mode!${NC}"
    exit 1
  fi
  
  # Ensure /usr was NOT touched
  if grep -q "Cleaning.*/usr" "$TEST_ENV_DIR/force_clean.log"; then
    echo -e "${RED}FAIL: Attempted to clean unsafe system directory /usr!${NC}"
    exit 1
  else
    echo -e "${GREEN}PASS: Unsafe system directory /usr was completely bypassed.${NC}"
  fi
else
  exit 1
fi

echo -e "\n${BOLD}${GREEN}All tests passed successfully!${NC}"
exit 0
