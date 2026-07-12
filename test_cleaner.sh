#!/usr/bin/env bash

# Automated test suite for refactored cleaner.sh

set -euo pipefail

# Find absolute path of the cleaner.sh directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEANER_SH="$SCRIPT_DIR/cleaner.sh"

# Colors for test output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Setup test environment directories
export TEST_ENV_DIR="$SCRIPT_DIR/test_env"
MOCK_HOME="$TEST_ENV_DIR/mock_home"
OUTSIDE_DIR="$TEST_ENV_DIR/outside_dir"

echo -e "${BOLD}${BLUE}=== Running Refactored Cleaner Test Suite ===${NC}"

# Cleanup function to run on exit
cleanup() {
  echo -e "${BLUE}Cleaning up test environment...${NC}"
  rm -rf "$TEST_ENV_DIR"
}
trap cleanup EXIT

# Setup mock directory structure and populate test files
setup_mock_env() {
  cleanup &>/dev/null || true
  
  echo -e "${BLUE}Setting up mock directory structure...${NC}"
  mkdir -p "$MOCK_HOME/.npm/_cacache"
  mkdir -p "$MOCK_HOME/.gemini/tmp"
  mkdir -p "$MOCK_HOME/.cache/aurman"
  mkdir -p "$MOCK_HOME/.cache/yarn"
  mkdir -p "$MOCK_HOME/.cache/medium_test"
  mkdir -p "$MOCK_HOME/.cache/danger_test"
  mkdir -p "$MOCK_HOME/tilde~test"
  mkdir -p "$OUTSIDE_DIR"
  
  # Create a mock bin directory for stubs (like pgrep)
  mkdir -p "$TEST_ENV_DIR/bin"
  cat << 'EOF' > "$TEST_ENV_DIR/bin/pgrep"
#!/usr/bin/env bash
# Mock pgrep command
if [[ "$1" == "-x" && "$2" == "mock_running_proc" ]]; then
  exit 0
else
  exit 1
fi
EOF
  chmod +x "$TEST_ENV_DIR/bin/pgrep"

  cat << 'EOF' > "$TEST_ENV_DIR/bin/sudo"
#!/usr/bin/env bash
# Mock sudo command

# Handle flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|-v)
      exit 0
      ;;
    *)
      break
      ;;
  esac
done

exec "$@"
EOF
  chmod +x "$TEST_ENV_DIR/bin/sudo"
 
  cat << 'EOF' > "$TEST_ENV_DIR/bin/paccache"
#!/usr/bin/env bash
# Mock paccache command
echo "Mock paccache called with: $@"
exit 0
EOF
  chmod +x "$TEST_ENV_DIR/bin/paccache"

  cat << 'EOF' > "$TEST_ENV_DIR/bin/pacman"
#!/usr/bin/env bash
# Mock pacman command
echo "Mock pacman called with: $@"
exit 0
EOF
  chmod +x "$TEST_ENV_DIR/bin/pacman"

  # Create dummy files
  echo "dummy npm cache" > "$MOCK_HOME/.npm/_cacache/cache1.txt"
  truncate -s 2M "$MOCK_HOME/.npm/_cacache/cache1.txt"
  echo "dummy aurman pkg" > "$MOCK_HOME/.cache/aurman/pkg1.tar.zst"
  echo "dummy yarn cache" > "$MOCK_HOME/.cache/yarn/yarn-cache.json"
  echo "dummy medium" > "$MOCK_HOME/.cache/medium_test/medium.txt"
  echo "dummy danger" > "$MOCK_HOME/.cache/danger_test/danger.txt"
  echo "dummy file outside home" > "$OUTSIDE_DIR/outside.txt"
  echo "should not be affected by tilde expansion" > "$MOCK_HOME/tilde~test/backup.txt"
  
  # Create files with specific modification times for age filter tests
  # Note: touch -d requires date/GNU format. On Linux:
  touch -d "10 days ago" "$MOCK_HOME/.gemini/tmp/old_file.tmp"
  touch -d "2 days ago" "$MOCK_HOME/.gemini/tmp/new_file.tmp"
  
  # Create nested symlinks with specific times to test age filter on symlinks
  ln -s "$MOCK_HOME/.npm/_cacache/cache1.txt" "$MOCK_HOME/.gemini/tmp/old_link.tmp"
  touch -h -d "10 days ago" "$MOCK_HOME/.gemini/tmp/old_link.tmp"
  
  ln -s "$MOCK_HOME/.npm/_cacache/cache1.txt" "$MOCK_HOME/.gemini/tmp/new_link.tmp"
  touch -h -d "2 days ago" "$MOCK_HOME/.gemini/tmp/new_link.tmp"

  # Setup a bad symlink (Symlink Guard test)
  # bad_symlink itself points to OUTSIDE_DIR
  ln -s "$OUTSIDE_DIR" "$MOCK_HOME/bad_symlink"

  # Create test configuration file (pipe-delimited)
  cat << EOF > "$TEST_ENV_DIR/test_cleaner.conf"
# RISK|NAME|PATH|DESCRIPTION|MIN_AGE_DAYS|CHECK_PROCESSES|ACTION
safe|NPM Cache|\$HOME/.npm/_cacache|Mock NPM cache|0|node,npm|
safe|Gemini Temp|\$HOME/.gemini/tmp|Mock Gemini temporary files|7|gemini|
safe|Aurman Cache|\$HOME/.cache/aurman|Mock Aurman package cache|0|aurman|
safe|Yarn Cache|\$HOME/.cache/yarn|Mock Yarn package cache|0|mock_running_proc|
safe|Tilde Tilde Test|\$HOME/tilde~test|Tilde character in name test|0||
safe|Symlink Danger|\$HOME/bad_symlink|Symlink pointing to outside dir|0||
safe|Outside HOME Target|$OUTSIDE_DIR|Target outside HOME boundary|0||
medium|Medium Risk Target|\$HOME/.cache/medium_test|Mock medium risk|0||
danger|Danger Risk Target|\$HOME/.cache/danger_test|Mock danger risk|0||
EOF
}

# Run a test and output result
run_test_case() {
  local test_name="$1"
  local expected_exit="$2"
  local log_filename="$3"
  shift 3
  
  echo -e "\n${BOLD}Test Case: $test_name${NC}"
  
  # Export mock HOME and prepend mock bin to PATH so cleaner uses the mocked pgrep
  local exit_code=0
  PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" "$CLEANER_SH" "$@" < /dev/null > "$TEST_ENV_DIR/$log_filename" 2>&1 || exit_code=$?
  
  if [[ $exit_code -ne $expected_exit ]]; then
    echo -e "${RED}FAIL: Expected exit code $expected_exit, got $exit_code${NC}"
    echo "--- Log Output ---"
    cat "$TEST_ENV_DIR/$log_filename"
    return 1
  fi
  
  return 0
}

# --- Executing Test Cases ---

setup_mock_env

# 1. Test Case: Dry Run Mode (Default without flags)
  if run_test_case "Dry Run Mode (Default)" 0 "dry_run.log" --config "$TEST_ENV_DIR/test_cleaner.conf"; then
  # Verify that no files were deleted
  if [[ -f "$MOCK_HOME/.npm/_cacache/cache1.txt" ]] && \
     [[ -f "$MOCK_HOME/.gemini/tmp/old_file.tmp" ]] && \
     [[ -f "$OUTSIDE_DIR/outside.txt" ]]; then
    echo -e "${GREEN}PASS: Dry run (default mode) completed and no files were deleted.${NC}"
  else
    echo -e "${RED}FAIL: Dry run default mode deleted files!${NC}"
    exit 1
  fi
  
  # Assertions on dry_run.log outputs
  # A. Symlink danger check
  if grep -q "SYMLINK.*Symlink Danger: Refusing to delete symlink target" "$TEST_ENV_DIR/dry_run.log"; then
    echo -e "${GREEN}PASS: Symlink danger guard block detected and logged.${NC}"
  else
    echo -e "${RED}FAIL: Symlink was not recognized or blocked.${NC}"
    cat "$TEST_ENV_DIR/dry_run.log"
    exit 1
  fi
  
  # B. Running process check
  if grep -q "BLOCKED.*Yarn Cache: Skip cleanup because process 'mock_running_proc' is active." "$TEST_ENV_DIR/dry_run.log"; then
    echo -e "${GREEN}PASS: Running process 'mock_running_proc' blocked Yarn Cache cleanup.${NC}"
  else
    echo -e "${RED}FAIL: Process check did not block cleanup.${NC}"
    cat "$TEST_ENV_DIR/dry_run.log"
    exit 1
  fi
  
  # C. Outside HOME rejection without --allow-outside-home
  if grep -q "REJECTED.*Outside HOME Target" "$TEST_ENV_DIR/dry_run.log"; then
    echo -e "${GREEN}PASS: Target outside HOME was rejected without --allow-outside-home.${NC}"
  else
    echo -e "${RED}FAIL: Outside HOME target was not rejected.${NC}"
    cat "$TEST_ENV_DIR/dry_run.log"
    exit 1
  fi

  # D. Size formatting check (2 MB)
  if grep -q "NPM Cache (2 MB)" "$TEST_ENV_DIR/dry_run.log"; then
    echo -e "${GREEN}PASS: Size formatting verified (2 MB).${NC}"
  else
    echo -e "${RED}FAIL: Size formatting assertion failed (could not find 'NPM Cache (2 MB)').${NC}"
    cat "$TEST_ENV_DIR/dry_run.log"
    exit 1
  fi
else
  exit 1
fi

# 2. Test Case: Risk Levels Filter
# Default --risk safe: Medium Risk Target should NOT be in dry_run.log as FOUND or WARNING
if grep -q "Medium Risk Target" "$TEST_ENV_DIR/dry_run.log"; then
  echo -e "${RED}FAIL: Medium Risk Target was included in default risk run.${NC}"
  exit 1
else
  echo -e "${GREEN}PASS: Medium risk targets successfully filtered out in default safe mode.${NC}"
fi

# Dry run with --risk medium
if run_test_case "Dry Run with Risk Medium" 0 "dry_run_medium.log" --config "$TEST_ENV_DIR/test_cleaner.conf" --risk medium --dry-run; then
  if grep -q "Medium Risk Target" "$TEST_ENV_DIR/dry_run_medium.log" && ! grep -q "Danger Risk Target" "$TEST_ENV_DIR/dry_run_medium.log"; then
    echo -e "${GREEN}PASS: Medium risk target was included, danger risk target was excluded.${NC}"
  else
    echo -e "${RED}FAIL: Risk level filtering logic failed for medium/danger.${NC}"
    cat "$TEST_ENV_DIR/dry_run_medium.log"
    exit 1
  fi
else
  exit 1
fi

# 3. Test Case: Tilde Expansion safety
# Verify tilde~test folder backup.txt size is detected (meaning it resolved the path literally and did not map ~ to HOME in the middle of the string)
if grep -q "Tilde Tilde Test" "$TEST_ENV_DIR/dry_run.log"; then
  # The path was $HOME/tilde~test. Check if it was resolved correctly (not as $HOME/tilde/home/eserlxltest)
  if [[ -f "$MOCK_HOME/tilde~test/backup.txt" ]]; then
    echo -e "${GREEN}PASS: Path containing internal ~ did not undergo unsafe expansion.${NC}"
  else
    echo -e "${RED}FAIL: Unsafe tilde expansion affected literal tilde files.${NC}"
    exit 1
  fi
else
  echo -e "${RED}FAIL: Tilde Tilde Test target was skipped or errored.${NC}"
  exit 1
fi

# 4. Test Case: Outside HOME with --allow-outside-home
if run_test_case "Outside HOME with --allow-outside-home" 0 "outside_home.log" --config "$TEST_ENV_DIR/test_cleaner.conf" --allow-outside-home --dry-run; then
  if grep -q "WARNING.*Outside HOME Target" "$TEST_ENV_DIR/outside_home.log"; then
    echo -e "${GREEN}PASS: Outside HOME target is allowed with warning when --allow-outside-home is active.${NC}"
  else
    echo -e "${RED}FAIL: Outside HOME target was still blocked with --allow-outside-home active.${NC}"
    cat "$TEST_ENV_DIR/outside_home.log"
    exit 1
  fi
else
  exit 1
fi

# 5. Test Case: Age Filter execution (Force Clean)
setup_mock_env
if run_test_case "Age Filter Execution" 0 "age_clean.log" --config "$TEST_ENV_DIR/test_cleaner.conf" --force; then
  # Check that old files/symlinks are deleted, but new files/symlinks are kept
  if [[ ! -f "$MOCK_HOME/.gemini/tmp/old_file.tmp" ]] && \
     [[ ! -L "$MOCK_HOME/.gemini/tmp/old_link.tmp" ]] && \
     [[ -f "$MOCK_HOME/.gemini/tmp/new_file.tmp" ]] && \
     [[ -L "$MOCK_HOME/.gemini/tmp/new_link.tmp" ]]; then
    echo -e "${GREEN}PASS: Age filter deleted old files/symlinks and preserved new files/symlinks.${NC}"
  else
    echo -e "${RED}FAIL: Age filter did not execute correctly for files or symlinks.${NC}"
    echo "Exists old file: $([[ -f "$MOCK_HOME/.gemini/tmp/old_file.tmp" ]] && echo "yes" || echo "no")"
    echo "Exists old symlink: $([[ -L "$MOCK_HOME/.gemini/tmp/old_link.tmp" ]] && echo "yes" || echo "no")"
    echo "Exists new file: $([[ -f "$MOCK_HOME/.gemini/tmp/new_file.tmp" ]] && echo "yes" || echo "no")"
    echo "Exists new symlink: $([[ -L "$MOCK_HOME/.gemini/tmp/new_link.tmp" ]] && echo "yes" || echo "no")"
    exit 1
  fi
else
  exit 1
fi

# 6. Test Case: Trash Mode (Quarantine)
setup_mock_env
if run_test_case "Trash Quarantine Mode" 0 "trash_clean.log" --config "$TEST_ENV_DIR/test_cleaner.conf" --trash --force; then
  # Verify files are moved to quarantine folder inside mock HOME
  # Target NPM Cache should be quarantined under 0_NPM_Cache
  quarantine_base="$MOCK_HOME/.cache/linux-cleaner/quarantine"
  if [[ -d "$quarantine_base" ]]; then
    # Find quarantined file
    quarantined_npm_file=$(find "$quarantine_base" -path "*/0_NPM_Cache/cache1.txt")
    if [[ -f "$quarantined_npm_file" ]]; then
      echo -e "${GREEN}PASS: NPM Cache file successfully quarantined to '$quarantined_npm_file' with sanitized index prefix.${NC}"
    else
      echo -e "${RED}FAIL: NPM Cache file not found in quarantine.${NC}"
      find "$quarantine_base"
      exit 1
    fi
  else
    echo -e "${RED}FAIL: Quarantine folder not created.${NC}"
    exit 1
  fi
  
  # Verify that original path NPM Cache is removed from mock HOME
  if [[ ! -d "$MOCK_HOME/.npm/_cacache" ]]; then
    echo -e "${GREEN}PASS: Original cache folder removed from mock HOME.${NC}"
  else
    echo -e "${RED}FAIL: Original cache folder still exists in mock HOME.${NC}"
    exit 1
  fi
else
  exit 1
fi

# 7. Test Case: Unknown Risk Levels error handling
setup_mock_env
# A. CLI option risk level typo
if run_test_case "CLI Unknown Risk Level" 1 "cli_bad_risk.log" --config "$TEST_ENV_DIR/test_cleaner.conf" --risk typo_risk; then
  if grep -q "Error: Unknown risk level 'typo_risk'" "$TEST_ENV_DIR/cli_bad_risk.log"; then
    echo -e "${GREEN}PASS: Script correctly errored and exited on unknown CLI risk level.${NC}"
  else
    echo -e "${RED}FAIL: Script errored but error message was unexpected.${NC}"
    cat "$TEST_ENV_DIR/cli_bad_risk.log"
    exit 1
  fi
else
  echo -e "${RED}FAIL: Script did not exit with expected code 1 on unknown CLI risk level.${NC}"
  exit 1
fi

# B. Configuration risk level typo
cat << EOF > "$TEST_ENV_DIR/bad_config.conf"
typo_risk|Bad target|\$HOME/.cache/yarn|Mock bad config target|0|
EOF
if run_test_case "Config Unknown Risk Level" 1 "config_bad_risk.log" --config "$TEST_ENV_DIR/bad_config.conf"; then
  if grep -q "Error: Unknown risk level 'typo_risk'" "$TEST_ENV_DIR/config_bad_risk.log"; then
    echo -e "${GREEN}PASS: Script correctly errored and exited on unknown risk level in config.${NC}"
  else
    echo -e "${RED}FAIL: Script errored but error message was unexpected.${NC}"
    cat "$TEST_ENV_DIR/config_bad_risk.log"
    exit 1
  fi
else
  echo -e "${RED}FAIL: Script did not exit with expected code 1 on unknown risk level in config.${NC}"
  exit 1
fi

# 8. Test Case: Danger Target confirmation guard
setup_mock_env
# A. Under --force without --yes-danger, the danger target should be skipped
if run_test_case "Danger Target Force Skip" 0 "danger_force_skip.log" --config "$TEST_ENV_DIR/test_cleaner.conf" --risk danger --force; then
  if grep -q "Danger target 'Danger Risk Target'" "$TEST_ENV_DIR/danger_force_skip.log" && \
     grep -q "Skipping Danger Risk Target" "$TEST_ENV_DIR/danger_force_skip.log"; then
    echo -e "${GREEN}PASS: Danger target was skipped under --force without --yes-danger.${NC}"
  else
    echo -e "${RED}FAIL: Danger target confirmation guard was bypassed or did not log correctly.${NC}"
    cat "$TEST_ENV_DIR/danger_force_skip.log"
    exit 1
  fi
  
  # Ensure the target directory itself was NOT deleted
  if [[ -d "$MOCK_HOME/.cache/danger_test" ]]; then
    echo -e "${GREEN}PASS: Danger target directory was preserved.${NC}"
  else
    echo -e "${RED}FAIL: Danger target directory was deleted despite lack of --yes-danger flag.${NC}"
    exit 1
  fi
else
  exit 1
fi

# B. Under --force with --yes-danger, the danger target should be deleted
setup_mock_env
if run_test_case "Danger Target Cleaned with Bypass" 0 "danger_bypass.log" --config "$TEST_ENV_DIR/test_cleaner.conf" --risk danger --force --yes-danger; then
  if grep -q "Cleaning Danger Risk Target" "$TEST_ENV_DIR/danger_bypass.log"; then
    echo -e "${GREEN}PASS: Danger target was processed successfully.${NC}"
  else
    echo -e "${RED}FAIL: Danger target clean statement not found in log.${NC}"
    cat "$TEST_ENV_DIR/danger_bypass.log"
    exit 1
  fi
  
  # Ensure the target directory itself WAS deleted
  if [[ ! -d "$MOCK_HOME/.cache/danger_test" ]]; then
    echo -e "${GREEN}PASS: Danger target directory was successfully deleted.${NC}"
  else
    echo -e "${RED}FAIL: Danger target directory was not deleted despite --yes-danger flag.${NC}"
    exit 1
  fi
else
  exit 1
fi

# 9. Test Case: Predefined Action Support
setup_mock_env
cat << EOF > "$TEST_ENV_DIR/sudo_custom_config.conf"
medium|Pacman Cache (Keep 3)|$OUTSIDE_DIR|Mock Pacman Cache|0||action:paccache_keep3
medium|Pacman Cache (Keep 2)|$OUTSIDE_DIR|Mock Pacman Cache 2|0||action:paccache_keep2
medium|Pacman Cache (Keep 1)|$OUTSIDE_DIR|Mock Pacman Cache 1|0||action:paccache_keep1
EOF

if run_test_case "Predefined Action" 0 "sudo_custom.log" --config "$TEST_ENV_DIR/sudo_custom_config.conf" --clean --force --allow-outside-home --risk medium; then
  # Check if mock paccache was executed with correct arguments
  if grep -q "Mock paccache called with: -rk3" "$TEST_ENV_DIR/sudo_custom.log" && \
     grep -q "Mock paccache called with: -rk2" "$TEST_ENV_DIR/sudo_custom.log" && \
     grep -q "Mock paccache called with: -rk1" "$TEST_ENV_DIR/sudo_custom.log"; then
    echo -e "${GREEN}PASS: Predefined actions (keep3, keep2, and keep1) executed successfully.${NC}"
  else
    echo -e "${RED}FAIL: Predefined actions were not executed or logged correctly.${NC}"
    cat "$TEST_ENV_DIR/sudo_custom.log"
    exit 1
  fi
else
  exit 1
fi

# 10. Test Case: Exclusion Patterns Support
setup_mock_env
mkdir -p "$MOCK_HOME/.npm/_cacache/.git"
echo "git file content" > "$MOCK_HOME/.npm/_cacache/.git/git_file.txt"
echo "exclude this log" > "$MOCK_HOME/.npm/_cacache/excl1.log"
echo "keep this txt" > "$MOCK_HOME/.npm/_cacache/keep.txt"

# Run dry run with exclusions: --exclude ".git,*.log"
if run_test_case "Exclusions Dry Run" 0 "exclusions_dry_run.log" --config "$TEST_ENV_DIR/test_cleaner.conf" --exclude ".git,*.log" --dry-run; then
  echo -e "${GREEN}PASS: Exclusions dry run executed successfully.${NC}"
else
  exit 1
fi

# Run clean with exclusions: --exclude ".git,*.log"
if run_test_case "Exclusions Clean" 0 "exclusions_clean.log" --config "$TEST_ENV_DIR/test_cleaner.conf" --exclude ".git,*.log" --force; then
  if [[ ! -f "$MOCK_HOME/.npm/_cacache/cache1.txt" ]] && \
     [[ ! -f "$MOCK_HOME/.npm/_cacache/keep.txt" ]] && \
     [[ -f "$MOCK_HOME/.npm/_cacache/excl1.log" ]] && \
     [[ -f "$MOCK_HOME/.npm/_cacache/.git/git_file.txt" ]]; then
    echo -e "${GREEN}PASS: Exclusions cleaned successfully. Excluded files/folders were preserved.${NC}"
  else
    echo -e "${RED}FAIL: Exclusions cleanup failed. Excluded files were deleted or kept files were not cleaned.${NC}"
    echo "Exists cache1.txt: $([[ -f "$MOCK_HOME/.npm/_cacache/cache1.txt" ]] && echo "yes" || echo "no")"
    echo "Exists keep.txt: $([[ -f "$MOCK_HOME/.npm/_cacache/keep.txt" ]] && echo "yes" || echo "no")"
    echo "Exists excl1.log: $([[ -f "$MOCK_HOME/.npm/_cacache/excl1.log" ]] && echo "yes" || echo "no")"
    echo "Exists .git/git_file.txt: $([[ -f "$MOCK_HOME/.npm/_cacache/.git/git_file.txt" ]] && echo "yes" || echo "no")"
    exit 1
  fi
else
  exit 1
fi

# 11. Test Case: Quarantine and Restoration Support
setup_mock_env
if run_test_case "Quarantine for Restore" 0 "quarantine_restore_setup.log" --config "$TEST_ENV_DIR/test_cleaner.conf" --trash --force; then
  quarantine_base="$MOCK_HOME/.cache/linux-cleaner/quarantine"
  if [[ -d "$quarantine_base" ]]; then
    latest_session=$(find "$quarantine_base" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1)
    if [[ -n "$latest_session" && -f "$latest_session/quarantine.meta" ]]; then
      echo -e "${GREEN}PASS: Quarantine session created with metadata file.${NC}"
    else
      echo -e "${RED}FAIL: Quarantine metadata file not found.${NC}"
      exit 1
    fi
  else
    echo -e "${RED}FAIL: Quarantine directory not created.${NC}"
    exit 1
  fi
else
  exit 1
fi

if [[ -f "$MOCK_HOME/.cache/aurman/pkg1.tar.zst" ]]; then
  echo -e "${RED}FAIL: Aurman Cache file was not removed from original location.${NC}"
  exit 1
fi

if run_test_case "Restore Latest Session" 0 "restore_latest.log" --restore latest; then
  if [[ -f "$MOCK_HOME/.cache/aurman/pkg1.tar.zst" ]]; then
    echo -e "${GREEN}PASS: File successfully restored from quarantine.${NC}"
  else
    echo -e "${RED}FAIL: Restored file not found at original location.${NC}"
    exit 1
  fi
  
  if [[ -d "$latest_session" ]]; then
    echo -e "${RED}FAIL: Quarantine session directory was not removed after restore.${NC}"
    exit 1
  else
    echo -e "${GREEN}PASS: Quarantine session directory cleaned up after restore.${NC}"
  fi
else
  exit 1
fi

# 12. Test Case: Ownership Metadata and Preservation
setup_mock_env
current_uid=$(id -u)
current_gid=$(id -g)

if run_test_case "Quarantine for Ownership Test" 0 "quarantine_ownership.log" --config "$TEST_ENV_DIR/test_cleaner.conf" --trash --force; then
  quarantine_base="$MOCK_HOME/.cache/linux-cleaner/quarantine"
  latest_session=$(find "$quarantine_base" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1)
  meta_file="$latest_session/quarantine.meta"
  
  if [[ -f "$meta_file" ]]; then
    meta_line=$(head -n 1 "$meta_file")
    echo "Inspecting metadata line: $meta_line"
    
    if [[ "$meta_line" == *"$current_uid|$current_gid" ]]; then
      echo -e "${GREEN}PASS: Original ownership UID ($current_uid) and GID ($current_gid) correctly recorded in quarantine.meta.${NC}"
    else
      echo -e "${RED}FAIL: Incorrect ownership metadata in quarantine.meta: '$meta_line'. Expected suffix: '|$current_uid|$current_gid'${NC}"
      exit 1
    fi
  else
    echo -e "${RED}FAIL: quarantine.meta not found for ownership test.${NC}"
    exit 1
  fi
else
  exit 1
fi

# Stub chown command to log arguments
cat << 'EOF' > "$TEST_ENV_DIR/bin/chown"
#!/usr/bin/env bash
echo "chown called with: $@" >> "$TEST_ENV_DIR/chown_calls.log"
exit 0
EOF
chmod +x "$TEST_ENV_DIR/bin/chown"
rm -f "$TEST_ENV_DIR/chown_calls.log"

# Modify quarantine.meta to use a dummy owner UID/GID to verify chown gets called with these values
sed -i "s/|$current_uid|$current_gid$/|9999|8888/" "$meta_file"

if run_test_case "Restore with Ownership Preservation" 0 "restore_ownership.log" --restore latest; then
  if [[ -f "$TEST_ENV_DIR/chown_calls.log" ]]; then
    chown_log=$(cat "$TEST_ENV_DIR/chown_calls.log")
    echo "Chown calls log:"
    cat "$TEST_ENV_DIR/chown_calls.log"
    if grep -q "9999:8888" "$TEST_ENV_DIR/chown_calls.log"; then
      echo -e "${GREEN}PASS: chown command was executed with the preserved UID:GID (9999:8888).${NC}"
    else
      echo -e "${RED}FAIL: chown was not called with preserved UID:GID. Log content: $chown_log${NC}"
      echo "--- restore_ownership.log Content ---"
      cat "$TEST_ENV_DIR/restore_ownership.log"
      exit 1
    fi
  else
    echo -e "${RED}FAIL: Mock chown was not called during restore.${NC}"
    echo "--- restore_ownership.log Content ---"
    cat "$TEST_ENV_DIR/restore_ownership.log"
    exit 1
  fi
else
  exit 1
fi

# 13. Test Case: Partial Restoration Failure Safety
setup_mock_env
if run_test_case "Quarantine for Failure Safety Test" 0 "quarantine_failure.log" --config "$TEST_ENV_DIR/test_cleaner.conf" --trash --force; then
  quarantine_base="$MOCK_HOME/.cache/linux-cleaner/quarantine"
  latest_session=$(find "$quarantine_base" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1)
  meta_file="$latest_session/quarantine.meta"
  
  # Inject a nonexistent target into metadata to cause restore failure
  echo "full|nonexistent_target|/nonexistent/original/path|false|0|0" >> "$meta_file"
  
  # Remove mock chown stub for clean restore run
  rm -f "$TEST_ENV_DIR/bin/chown"
  
  if run_test_case "Restore with Partial Failure" 1 "restore_failure.log" --restore latest; then
    if [[ -d "$latest_session" ]]; then
      echo -e "${GREEN}PASS: Quarantine session directory was preserved after a partial restore failure.${NC}"
    else
      echo -e "${RED}FAIL: Quarantine session directory was deleted despite restore failure!${NC}"
      exit 1
    fi
    
    if [[ -f "$MOCK_HOME/.cache/aurman/pkg1.tar.zst" ]]; then
      echo -e "${GREEN}PASS: Successfully processed items were restored despite overall failure.${NC}"
    else
      echo -e "${RED}FAIL: Successfully restored files are missing.${NC}"
      exit 1
    fi
  else
    exit 1
  fi
else
  exit 1
fi

# 14. Test Case: Restore Conflict Check
setup_mock_env
if run_test_case "Quarantine for Conflict Test" 0 "quarantine_conflict.log" --config "$TEST_ENV_DIR/test_cleaner.conf" --trash --force; then
  quarantine_base="$MOCK_HOME/.cache/linux-cleaner/quarantine"
  latest_session=$(find "$quarantine_base" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1)
  
  # Re-create original directory/file to trigger a conflict
  mkdir -p "$MOCK_HOME/.npm/_cacache"
  echo "conflicting file" > "$MOCK_HOME/.npm/_cacache/cache1.txt"
  
  if run_test_case "Restore with Conflict" 1 "restore_conflict.log" --restore latest; then
    if grep -q "Conflict detected" "$TEST_ENV_DIR/restore_conflict.log"; then
      echo -e "${GREEN}PASS: Restore conflict was detected and logged.${NC}"
    else
      echo -e "${RED}FAIL: Conflict error message not found in log.${NC}"
      cat "$TEST_ENV_DIR/restore_conflict.log"
      exit 1
    fi
    
    if [[ -d "$latest_session" ]]; then
      echo -e "${GREEN}PASS: Quarantine session directory was preserved after conflict check failure.${NC}"
    else
      echo -e "${RED}FAIL: Quarantine session directory was deleted despite conflict!${NC}"
      exit 1
    fi
  else
    exit 1
  fi
else
  exit 1
fi

# 15. Test Case: Invalid/Empty Exclusion Patterns
setup_mock_env
if run_test_case "Invalid Exclusions Dry Run" 0 "exclusions_invalid.log" --config "$TEST_ENV_DIR/test_cleaner.conf" --exclude ",," --dry-run; then
  if grep -q "NPM Cache" "$TEST_ENV_DIR/exclusions_invalid.log"; then
    echo -e "${GREEN}PASS: Invalid/empty exclusion patterns did not cause find to crash and dry-run completed successfully.${NC}"
  else
    echo -e "${RED}FAIL: Target not found in log, find may have failed.${NC}"
    cat "$TEST_ENV_DIR/exclusions_invalid.log"
    exit 1
  fi
else
  exit 1
fi

# 16. Test Case: Canonicalization ..-traversal escape (REJECTED, not classified in-HOME safe)
setup_mock_env
cat << EOF > "$TEST_ENV_DIR/dotdot_escape.conf"
safe|Dotdot Escape Probe|\$HOME/../dotdot_escape_probe|Path climbing above HOME via ..|0||
EOF
if run_test_case "Canonicalization Dotdot Escape" 0 "dotdot_escape.log" --config "$TEST_ENV_DIR/dotdot_escape.conf" --dry-run; then
  if grep -q "REJECTED.*Dotdot Escape Probe" "$TEST_ENV_DIR/dotdot_escape.log"; then
    echo -e "${GREEN}PASS: '..'-traversal path escaping HOME was resolved and REJECTED, not classified as in-HOME safe.${NC}"
  else
    echo -e "${RED}FAIL: '..'-traversal escape was not rejected (canonicalization may not resolve '..').${NC}"
    cat "$TEST_ENV_DIR/dotdot_escape.log"
    exit 1
  fi
else
  exit 1
fi

# 17. Test Case: Symlinked-parent escape (parent symlink resolves outside HOME -> REJECTED)
setup_mock_env
ln -s "$OUTSIDE_DIR" "$MOCK_HOME/escape_link"
cat << EOF > "$TEST_ENV_DIR/symlink_parent.conf"
safe|Symlinked Parent Escape|\$HOME/escape_link/sub|Target under a symlinked parent that escapes HOME|0||
EOF
if run_test_case "Symlinked Parent Escape" 0 "symlink_parent.log" --config "$TEST_ENV_DIR/symlink_parent.conf" --dry-run; then
  if grep -q "REJECTED.*Symlinked Parent Escape" "$TEST_ENV_DIR/symlink_parent.log" && \
     [[ -f "$OUTSIDE_DIR/outside.txt" ]]; then
    echo -e "${GREEN}PASS: Symlinked parent resolved outside HOME and was REJECTED; real outside dir untouched.${NC}"
  else
    echo -e "${RED}FAIL: Symlinked-parent escape was not rejected or the outside dir was affected.${NC}"
    cat "$TEST_ENV_DIR/symlink_parent.log"
    exit 1
  fi
else
  exit 1
fi

# 18. Test Case: Protected system directory classified UNSAFE
setup_mock_env
cat << 'EOF' > "$TEST_ENV_DIR/system_dir.conf"
safe|System Usr Probe|/usr|Hardcoded blocked system directory|0||
EOF
if run_test_case "Protected System Dir UNSAFE" 0 "system_dir.log" --config "$TEST_ENV_DIR/system_dir.conf" --dry-run; then
  if grep -q "UNSAFE.*System Usr Probe.*protected system directory" "$TEST_ENV_DIR/system_dir.log" && [[ -d /usr ]]; then
    echo -e "${GREEN}PASS: Protected system directory '/usr' was classified UNSAFE and left intact.${NC}"
  else
    echo -e "${RED}FAIL: '/usr' was not classified UNSAFE (or was somehow affected).${NC}"
    cat "$TEST_ENV_DIR/system_dir.log"
    exit 1
  fi
else
  exit 1
fi

# 19. Test Case: ..-traversal that canonicalizes onto a system directory -> UNSAFE
setup_mock_env
cat << EOF > "$TEST_ENV_DIR/dotdot_system.conf"
safe|Dotdot System Escape|\$HOME/.cache/../../../../../../../../../../../../../../../../../../../../../../../../etc|.. path that resolves onto /etc|0||
EOF
if run_test_case "Dotdot Onto System Dir" 0 "dotdot_system.log" --config "$TEST_ENV_DIR/dotdot_system.conf" --dry-run; then
  if grep -q "UNSAFE.*Dotdot System Escape.*protected system directory" "$TEST_ENV_DIR/dotdot_system.log" && [[ -d /etc ]]; then
    echo -e "${GREEN}PASS: '..'-traversal resolving onto /etc was classified UNSAFE; canonicalizer and block-list cooperate.${NC}"
  else
    echo -e "${RED}FAIL: '..'-onto-system-dir was not classified UNSAFE.${NC}"
    cat "$TEST_ENV_DIR/dotdot_system.log"
    exit 1
  fi
else
  exit 1
fi

echo -e "\n${BOLD}${GREEN}All refactored tests passed successfully!${NC}"
exit 0

