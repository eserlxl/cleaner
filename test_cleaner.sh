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

  # Cross-distro package-manager mocks (apt/apt-get/dnf), same template as above.
  local _mgr
  for _mgr in apt apt-get dnf; do
    cat > "$TEST_ENV_DIR/bin/$_mgr" << EOF
#!/usr/bin/env bash
# Mock $_mgr command
echo "Mock $_mgr called with: \$@"
exit 0
EOF
    chmod +x "$TEST_ENV_DIR/bin/$_mgr"
  done

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

# 20. Test Case: Actual outside-HOME deletion with --allow-outside-home --force
setup_mock_env
if run_test_case "Actual Outside HOME Clean" 0 "outside_clean.log" --config "$TEST_ENV_DIR/test_cleaner.conf" --allow-outside-home --force; then
  if [[ ! -f "$OUTSIDE_DIR/outside.txt" ]]; then
    echo -e "${GREEN}PASS: Outside-HOME target was actually deleted under --allow-outside-home --force.${NC}"
  else
    echo -e "${RED}FAIL: Outside-HOME target survived a destructive --allow-outside-home run.${NC}"
    cat "$TEST_ENV_DIR/outside_clean.log"
    exit 1
  fi
else
  exit 1
fi

# 21. Test Case: Destructive run WITHOUT --allow-outside-home leaves outside target intact
setup_mock_env
if run_test_case "Destructive Without Escape Flag" 0 "outside_gated.log" --config "$TEST_ENV_DIR/test_cleaner.conf" --force; then
  if [[ -f "$OUTSIDE_DIR/outside.txt" ]]; then
    echo -e "${GREEN}PASS: Outside-HOME target survived a real --force run because --allow-outside-home was absent.${NC}"
  else
    echo -e "${RED}FAIL: Outside-HOME target was deleted under --force without --allow-outside-home.${NC}"
    cat "$TEST_ENV_DIR/outside_gated.log"
    exit 1
  fi
else
  exit 1
fi

# 22. Test Case: format_bytes GB scaling (unit_idx reaching 3)
setup_mock_env
mkdir -p "$MOCK_HOME/.cache/gb_probe"
truncate -s 2G "$MOCK_HOME/.cache/gb_probe/big.sparse"
cat << EOF > "$TEST_ENV_DIR/gb_size.conf"
safe|GB Size Probe|\$HOME/.cache/gb_probe|Sparse 2G file to exercise GB scaling|0||
EOF
if run_test_case "format_bytes GB Scaling" 0 "gb_size.log" --config "$TEST_ENV_DIR/gb_size.conf" --dry-run; then
  if grep -q "GB Size Probe (2 GB)" "$TEST_ENV_DIR/gb_size.log"; then
    echo -e "${GREEN}PASS: format_bytes rendered a GB-magnitude target as '2 GB'.${NC}"
  else
    echo -e "${RED}FAIL: GB-magnitude size was not rendered as '2 GB'.${NC}"
    cat "$TEST_ENV_DIR/gb_size.log"
    exit 1
  fi
else
  exit 1
fi

# 23. Test Case: format_bytes TB scaling and the unit_idx < 4 cap
setup_mock_env
mkdir -p "$MOCK_HOME/.cache/tb_probe"
truncate -s 2T "$MOCK_HOME/.cache/tb_probe/big.sparse"
cat << EOF > "$TEST_ENV_DIR/tb_size.conf"
safe|TB Size Probe|\$HOME/.cache/tb_probe|Sparse 2T file to exercise TB scaling and the cap|0||
EOF
if run_test_case "format_bytes TB Scaling" 0 "tb_size.log" --config "$TEST_ENV_DIR/tb_size.conf" --dry-run; then
  if grep -q "TB Size Probe (2 TB)" "$TEST_ENV_DIR/tb_size.log"; then
    echo -e "${GREEN}PASS: format_bytes scaled to '2 TB' and capped at the TB unit.${NC}"
  else
    echo -e "${RED}FAIL: TB-magnitude size was not rendered as '2 TB'.${NC}"
    cat "$TEST_ENV_DIR/tb_size.log"
    exit 1
  fi
else
  exit 1
fi

# 24. Test Case: format_bytes direct-invocation fallback (deterministic, FS-independent GB/TB)
# Extract only the format_bytes function from cleaner.sh and run it on exact byte
# inputs, so GB/TB coverage holds even where sparse-file fixtures are not viable.
fb_gb=$( { awk '/^format_bytes\(\) \{/,/^\}/' "$CLEANER_SH"; echo 'format_bytes 2147483648'; } | bash )
fb_tb=$( { awk '/^format_bytes\(\) \{/,/^\}/' "$CLEANER_SH"; echo 'format_bytes 2199023255552'; } | bash )
echo -e "\n${BOLD}Test Case: format_bytes Direct GB/TB${NC}"
if [[ "$fb_gb" == "2 GB" && "$fb_tb" == "2 TB" ]]; then
  echo -e "${GREEN}PASS: format_bytes(2147483648)='2 GB' and format_bytes(2199023255552)='2 TB' via direct invocation.${NC}"
else
  echo -e "${RED}FAIL: direct format_bytes gave GB='$fb_gb' TB='$fb_tb' (expected '2 GB' / '2 TB').${NC}"
  exit 1
fi

# 25. Test Case: Malformed structure (field-count contract, line-numbered errors)
setup_mock_env
# A. Too few fields (4 < 5) on a known line number (row 2)
cat << EOF > "$TEST_ENV_DIR/too_few.conf"
# header comment
safe|Too Few Fields|\$HOME/.cache/aurman|Missing min_age and beyond
EOF
if run_test_case "Malformed Too Few Fields" 1 "too_few.log" --config "$TEST_ENV_DIR/too_few.conf" --dry-run; then
  if grep -q ":2: expected 5-7 fields, found 4" "$TEST_ENV_DIR/too_few.log"; then
    echo -e "${GREEN}PASS: Too-few-fields line rejected with the correct line number.${NC}"
  else
    echo -e "${RED}FAIL: Too-few-fields error/line-number not found.${NC}"
    cat "$TEST_ENV_DIR/too_few.log"
    exit 1
  fi
else
  echo -e "${RED}FAIL: Too-few-fields config did not exit non-zero.${NC}"
  exit 1
fi

# B. Too many fields (8 > 7) on a known line number (row 2)
cat << EOF > "$TEST_ENV_DIR/too_many.conf"
# header comment
safe|Too Many Fields|\$HOME/.cache/aurman|desc|0|proc|action:pacman_clean|stray
EOF
if run_test_case "Malformed Too Many Fields" 1 "too_many.log" --config "$TEST_ENV_DIR/too_many.conf" --dry-run; then
  if grep -q ":2: expected 5-7 fields, found 8" "$TEST_ENV_DIR/too_many.log"; then
    echo -e "${GREEN}PASS: Too-many-fields line rejected with the correct line number.${NC}"
  else
    echo -e "${RED}FAIL: Too-many-fields error/line-number not found.${NC}"
    cat "$TEST_ENV_DIR/too_many.log"
    exit 1
  fi
else
  echo -e "${RED}FAIL: Too-many-fields config did not exit non-zero.${NC}"
  exit 1
fi

# 26b. Test Case: Malformed CHECK_PROCESSES token shape (and a valid control)
setup_mock_env
printf '# header\nsafe|N|/p|desc|0|node,,npm\n' > "$TEST_ENV_DIR/cp_bad.conf"
if run_test_case "CheckProcs Malformed" 1 "cp_bad.log" --config "$TEST_ENV_DIR/cp_bad.conf" --dry-run; then
  if grep -q ":2: malformed CHECK_PROCESSES 'node,,npm'" "$TEST_ENV_DIR/cp_bad.log"; then
    echo -e "${GREEN}PASS: Malformed CHECK_PROCESSES 'node,,npm' rejected with a line-numbered error.${NC}"
  else
    echo -e "${RED}FAIL: Malformed CHECK_PROCESSES error not found.${NC}"
    cat "$TEST_ENV_DIR/cp_bad.log"
    exit 1
  fi
else
  echo -e "${RED}FAIL: Malformed CHECK_PROCESSES did not exit non-zero.${NC}"
  exit 1
fi
# Control: a normal comma-separated process list must still load
# shellcheck disable=SC2016  # literal $HOME is intentional; the tool expands it at runtime
printf 'safe|N|$HOME/.cache/aurman|desc|0|node,npm\n' > "$TEST_ENV_DIR/cp_ok.conf"
if run_test_case "CheckProcs Valid Control" 0 "cp_ok.log" --config "$TEST_ENV_DIR/cp_ok.conf" --dry-run; then
  echo -e "${GREEN}PASS: Normal comma-separated CHECK_PROCESSES 'node,npm' still loads.${NC}"
else
  echo -e "${RED}FAIL: Valid CHECK_PROCESSES 'node,npm' was rejected.${NC}"
  cat "$TEST_ENV_DIR/cp_ok.log"
  exit 1
fi

# 26. Test Case: Value violations (line-numbered errors, malformed line on row 2)
setup_mock_env
assert_value_error() {
  local case_name="$1" conf="$2" pattern="$3"
  if run_test_case "$case_name" 1 "${case_name// /_}.log" --config "$conf" --dry-run; then
    if grep -q "$pattern" "$TEST_ENV_DIR/${case_name// /_}.log"; then
      echo -e "${GREEN}PASS: $case_name rejected with line-numbered error.${NC}"
    else
      echo -e "${RED}FAIL: $case_name did not produce the expected '$pattern'.${NC}"
      cat "$TEST_ENV_DIR/${case_name// /_}.log"
      exit 1
    fi
  else
    echo -e "${RED}FAIL: $case_name did not exit non-zero.${NC}"
    exit 1
  fi
}

printf '# header\nsafe|N|/p|desc|notanumber\n' > "$TEST_ENV_DIR/vv_age.conf"
assert_value_error "Value Nonnumeric Age" "$TEST_ENV_DIR/vv_age.conf" ":2: invalid MIN_AGE_DAYS 'notanumber'"

printf '# header\nsafe||/p|desc|0\n' > "$TEST_ENV_DIR/vv_name.conf"
assert_value_error "Value Empty Name" "$TEST_ENV_DIR/vv_name.conf" ":2: NAME (field 2) is empty"

printf '# header\nsafe|N||desc|0\n' > "$TEST_ENV_DIR/vv_path.conf"
assert_value_error "Value Empty Path" "$TEST_ENV_DIR/vv_path.conf" ":2: PATH (field 3) is empty"

printf '# header\nbadrisk|N|/p|desc|0\n' > "$TEST_ENV_DIR/vv_risk.conf"
assert_value_error "Value Risk LineNumber" "$TEST_ENV_DIR/vv_risk.conf" ":2: Error: Unknown risk level 'badrisk'"

# 27. Test Case: Positive control — a valid config with trailing-empty optionals parses clean
setup_mock_env
cat << EOF > "$TEST_ENV_DIR/positive_control.conf"
# a valid target with trailing-empty optional fields (like cleaner.conf's |0||)
safe|Positive Control|\$HOME/.cache/aurman|Valid target with trailing empties|0||
EOF
if run_test_case "Positive Control Valid Config" 0 "positive_control.log" --config "$TEST_ENV_DIR/positive_control.conf" --dry-run; then
  if ! grep -q "expected 5-7 fields\|invalid MIN_AGE_DAYS\|is empty\|malformed CHECK_PROCESSES\|Unknown risk level\|Unknown action" "$TEST_ENV_DIR/positive_control.log"; then
    echo -e "${GREEN}PASS: Valid config with trailing-empty optional fields parsed and ran clean.${NC}"
  else
    echo -e "${RED}FAIL: A valid config triggered a validation error.${NC}"
    cat "$TEST_ENV_DIR/positive_control.log"
    exit 1
  fi
else
  echo -e "${RED}FAIL: Valid config did not exit 0.${NC}"
  exit 1
fi

# 28. Test Case: Self-consistency — the shipped cleaner.conf passes the validator
setup_mock_env
if run_test_case "Shipped Config Self-Validates" 0 "shipped_config.log" --config "$SCRIPT_DIR/cleaner.conf" --dry-run; then
  if ! grep -q "expected 5-7 fields\|invalid MIN_AGE_DAYS\|is empty\|malformed CHECK_PROCESSES\|Unknown risk level\|Unknown action" "$TEST_ENV_DIR/shipped_config.log"; then
    echo -e "${GREEN}PASS: The shipped cleaner.conf passes the field/value validator.${NC}"
  else
    echo -e "${RED}FAIL: The shipped cleaner.conf triggered a validation error.${NC}"
    cat "$TEST_ENV_DIR/shipped_config.log"
    exit 1
  fi
else
  echo -e "${RED}FAIL: Dry-run against the shipped cleaner.conf did not exit 0.${NC}"
  cat "$TEST_ENV_DIR/shipped_config.log"
  exit 1
fi

# 29. Test Case: --version prints a version token and exits 0
setup_mock_env
if run_test_case "Version Flag" 0 "version.log" --version; then
  if grep -qE '[0-9]+\.[0-9]+' "$TEST_ENV_DIR/version.log"; then
    echo -e "${GREEN}PASS: --version printed a version token and exited 0.${NC}"
  else
    echo -e "${RED}FAIL: --version output had no version token.${NC}"
    cat "$TEST_ENV_DIR/version.log"
    exit 1
  fi
else
  echo -e "${RED}FAIL: --version did not exit 0.${NC}"
  exit 1
fi

# 30. Test Case: --list-sessions lists a session (read-only) and reports empty state
setup_mock_env
if run_test_case "Quarantine for Listing" 0 "list_setup.log" --config "$TEST_ENV_DIR/test_cleaner.conf" --trash --force; then
  quarantine_base="$MOCK_HOME/.cache/linux-cleaner/quarantine"
  latest_session=$(find "$quarantine_base" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1)
  session_ts=$(basename "$latest_session")
  if run_test_case "List Sessions" 0 "list_sessions.log" --list-sessions; then
    if grep -q "$session_ts" "$TEST_ENV_DIR/list_sessions.log" && [[ -d "$latest_session" ]]; then
      echo -e "${GREEN}PASS: --list-sessions listed the session and left it intact.${NC}"
    else
      echo -e "${RED}FAIL: --list-sessions did not list the session or it was modified.${NC}"
      cat "$TEST_ENV_DIR/list_sessions.log"
      exit 1
    fi
  else
    exit 1
  fi
else
  exit 1
fi
# Empty-quarantine state: fresh mock HOME with no quarantine
setup_mock_env
if run_test_case "List Sessions Empty" 0 "list_empty.log" --list-sessions; then
  if grep -qi "No quarantine sessions found" "$TEST_ENV_DIR/list_empty.log"; then
    echo -e "${GREEN}PASS: --list-sessions reports the empty state cleanly.${NC}"
  else
    echo -e "${RED}FAIL: --list-sessions empty-state message not found.${NC}"
    cat "$TEST_ENV_DIR/list_empty.log"
    exit 1
  fi
else
  exit 1
fi

# 31. Test Case: Opt-in operation logging (default-off, opt-in-on, no-leak, $HOME-confined)
setup_mock_env
log_path="$MOCK_HOME/.cache/linux-cleaner/operations.log"

# (a) Default run writes no log file
if run_test_case "Log Default Off" 0 "log_default.log" --config "$TEST_ENV_DIR/test_cleaner.conf" --dry-run; then
  if [[ ! -f "$log_path" ]]; then
    echo -e "${GREEN}PASS: Default run wrote no operation log.${NC}"
  else
    echo -e "${RED}FAIL: An operation log was created without opt-in.${NC}"
    exit 1
  fi
else
  exit 1
fi

# (b)+(c) Opted-in clean run writes a log entry and leaks no file contents
setup_mock_env
if run_test_case "Log Opt-In Write" 0 "log_optin.log" --config "$TEST_ENV_DIR/test_cleaner.conf" --force --log; then
  if [[ -f "$log_path" ]] && grep -q "target='NPM Cache'" "$log_path"; then
    echo -e "${GREEN}PASS: Opted-in run logged a cleaned target.${NC}"
  else
    echo -e "${RED}FAIL: Opted-in run did not log the expected target.${NC}"
    cat "$log_path" 2>/dev/null
    exit 1
  fi
  if ! grep -qE "dummy npm cache|dummy aurman pkg|dummy yarn cache" "$log_path"; then
    echo -e "${GREEN}PASS: Operation log leaked no mock file contents.${NC}"
  else
    echo -e "${RED}FAIL: Operation log leaked file contents.${NC}"
    cat "$log_path"
    exit 1
  fi
else
  exit 1
fi

# (d) Out-of-$HOME log path is refused (no file created outside HOME)
setup_mock_env
outside_log="$OUTSIDE_DIR/should_not_exist.log"
if run_test_case "Log Outside HOME Rejected" 0 "log_outside.log" --config "$TEST_ENV_DIR/test_cleaner.conf" --force --log "$outside_log"; then
  if [[ ! -f "$outside_log" ]] && grep -qi "Refusing to write log outside" "$TEST_ENV_DIR/log_outside.log"; then
    echo -e "${GREEN}PASS: Out-of-HOME log path was refused; no file created.${NC}"
  else
    echo -e "${RED}FAIL: Out-of-HOME log path was not properly refused.${NC}"
    cat "$TEST_ENV_DIR/log_outside.log"
    exit 1
  fi
else
  exit 1
fi

# 32. Test Case: Config resolution order (explicit -c, XDG user config, dev fallback)
setup_mock_env
mkdir -p "$MOCK_HOME/.config/linux-cleaner"
# shellcheck disable=SC2016  # literal $HOME is intentional; the tool expands it at runtime
printf 'safe|XDG Only Target|$HOME/.cache/aurman|d|0||\n' > "$MOCK_HOME/.config/linux-cleaner/cleaner.conf"
run_cleaner_env() {  # run the cleaner with controlled HOME + unset XDG, capture output
  local log="$1"; shift
  env -u XDG_CONFIG_HOME HOME="$MOCK_HOME" PATH="$TEST_ENV_DIR/bin:$PATH" "$CLEANER_SH" "$@" < /dev/null > "$TEST_ENV_DIR/$log" 2>&1
}
# (a) Explicit -c wins over any resolved default
run_cleaner_env "cfg_c.log" --config "$TEST_ENV_DIR/test_cleaner.conf" --dry-run
if grep -q "Config file: $TEST_ENV_DIR/test_cleaner.conf" "$TEST_ENV_DIR/cfg_c.log" && ! grep -q "XDG Only Target" "$TEST_ENV_DIR/cfg_c.log"; then
  echo -e "${GREEN}PASS: Explicit -c overrides the resolved default config.${NC}"
else
  echo -e "${RED}FAIL: Explicit -c did not win.${NC}"; cat "$TEST_ENV_DIR/cfg_c.log"; exit 1
fi
# (b) XDG user config used when no -c (XDG_CONFIG_HOME unset -> $HOME/.config)
run_cleaner_env "cfg_xdg.log" --dry-run
if grep -q "Config file: $MOCK_HOME/.config/linux-cleaner/cleaner.conf" "$TEST_ENV_DIR/cfg_xdg.log"; then
  echo -e "${GREEN}PASS: XDG user config resolved when no -c is given.${NC}"
else
  echo -e "${RED}FAIL: XDG user config was not resolved.${NC}"; cat "$TEST_ENV_DIR/cfg_xdg.log"; exit 1
fi
# (c) Dev-checkout fallback when no XDG/system config exists
rm -rf "$MOCK_HOME/.config/linux-cleaner"
if [[ -f /etc/linux-cleaner/cleaner.conf ]]; then
  echo -e "${GREEN}PASS: Dev-fallback assertion skipped (a system config is installed at /etc/linux-cleaner).${NC}"
else
  run_cleaner_env "cfg_dev.log" --dry-run
  if grep -q "Config file: $SCRIPT_DIR/cleaner.conf" "$TEST_ENV_DIR/cfg_dev.log"; then
    echo -e "${GREEN}PASS: Dev-checkout config beside the script resolved as fallback.${NC}"
  else
    echo -e "${RED}FAIL: Dev-checkout fallback did not resolve.${NC}"; cat "$TEST_ENV_DIR/cfg_dev.log"; exit 1
  fi
fi
# Note: the /etc/linux-cleaner rung is not hermetically testable without touching a real system path.

# 33. Test Case: the man page documents every --help option (drift guard)
setup_mock_env
help_out="$TEST_ENV_DIR/help_flags.txt"
HOME="$MOCK_HOME" PATH="$TEST_ENV_DIR/bin:$PATH" "$CLEANER_SH" --help > "$help_out" 2>&1
man_stripped="$TEST_ENV_DIR/man_stripped.txt"
sed 's/\\//g' "$SCRIPT_DIR/cleaner.1" > "$man_stripped"   # drop roff backslash escapes
missing_flags=""
while IFS= read -r flag; do
  [[ -z "$flag" ]] && continue
  grep -q -- "$flag" "$man_stripped" || missing_flags="$missing_flags $flag"
done < <(grep -oE -- '--[a-z][a-z-]*' "$help_out" | sort -u)
echo -e "\n${BOLD}Test Case: Man Page Option Consistency${NC}"
if [[ -z "$missing_flags" ]]; then
  echo -e "${GREEN}PASS: The man page documents every --help long option.${NC}"
else
  echo -e "${RED}FAIL: Options in --help but missing from the man page:$missing_flags${NC}"
  exit 1
fi

# 34. Test Case: CHANGELOG top released version matches --version
setup_mock_env
changelog_version=$(grep -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' "$SCRIPT_DIR/CHANGELOG.md" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
tool_version=$(HOME="$MOCK_HOME" PATH="$TEST_ENV_DIR/bin:$PATH" "$CLEANER_SH" --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
echo -e "\n${BOLD}Test Case: Changelog/Version Consistency${NC}"
if [[ -n "$changelog_version" && "$changelog_version" == "$tool_version" ]]; then
  echo -e "${GREEN}PASS: CHANGELOG top version ($changelog_version) matches --version ($tool_version).${NC}"
else
  echo -e "${RED}FAIL: CHANGELOG version '$changelog_version' != --version '$tool_version'.${NC}"
  exit 1
fi

# 35. Test Case: version/tag/changelog three-way consistency (skipped without a release tag)
setup_mock_env
echo -e "\n${BOLD}Test Case: Version/Tag/Changelog Consistency${NC}"
git_tag=$(git -C "$SCRIPT_DIR" describe --tags --exact-match --match 'v[0-9]*' 2>/dev/null || true)
if [[ -z "$git_tag" ]]; then
  echo -e "${GREEN}PASS (skipped): HEAD is not a v* release tag; the three-way check applies only on a tagged release.${NC}"
else
  tag_version="${git_tag#v}"
  changelog_version=$(grep -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' "$SCRIPT_DIR/CHANGELOG.md" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
  tool_version=$(HOME="$MOCK_HOME" PATH="$TEST_ENV_DIR/bin:$PATH" "$CLEANER_SH" --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  if [[ "$tag_version" == "$changelog_version" && "$changelog_version" == "$tool_version" ]]; then
    echo -e "${GREEN}PASS: tag ($tag_version), CHANGELOG ($changelog_version), and --version ($tool_version) all agree.${NC}"
  else
    echo -e "${RED}FAIL: version mismatch — tag='$tag_version' changelog='$changelog_version' --version='$tool_version'.${NC}"
    exit 1
  fi
fi

# 36. Test Case: detect_package_manager returns the right token per stub
setup_mock_env
detect_fn=$(awk '/^detect_package_manager\(\) \{/,/^\}/' "$CLEANER_SH")
detect_script="$TEST_ENV_DIR/detect_probe.sh"
# shellcheck disable=SC2016  # literal $1 is intentional: it is the probe script's own positional
{ echo 'PATH="$1"'; echo "$detect_fn"; echo 'detect_package_manager'; } > "$detect_script"
detect_with() { bash "$detect_script" "$1"; }   # $1 = isolated bin dir
mk_stub_dir() {
  local d; d=$(mktemp -d "$TEST_ENV_DIR/detbin.XXXXXX")
  local t; for t in "$@"; do printf '#!/bin/sh\n' > "$d/$t"; chmod +x "$d/$t"; done
  printf '%s' "$d"
}
echo -e "\n${BOLD}Test Case: Package Manager Detection${NC}"
det_ok=true
[[ "$(detect_with "$(mk_stub_dir pacman)")" == "pacman" ]] || det_ok=false
[[ "$(detect_with "$(mk_stub_dir apt-get)")" == "apt" ]] || det_ok=false
[[ "$(detect_with "$(mk_stub_dir dnf)")" == "dnf" ]] || det_ok=false
[[ "$(detect_with "$(mk_stub_dir)")" == "none" ]] || det_ok=false
# mutation sanity: a renamed stub must fall through to none
[[ "$(detect_with "$(mk_stub_dir pacman-renamed)")" == "none" ]] || det_ok=false
if [[ "$det_ok" == true ]]; then
  echo -e "${GREEN}PASS: detect_package_manager returns pacman/apt/dnf/none for the matching stub (mutation-safe).${NC}"
else
  echo -e "${RED}FAIL: detection returned an unexpected token.${NC}"
  exit 1
fi

# 37. Test Case: apt/dnf actions invoke their exact commands (and no other manager)
setup_mock_env
cat << EOF > "$TEST_ENV_DIR/aptdnf_config.conf"
medium|APT Clean|$OUTSIDE_DIR|Mock APT cache|0||action:apt_clean
medium|DNF Clean|$OUTSIDE_DIR|Mock DNF cache|0||action:dnf_clean
EOF
if run_test_case "Cross-Distro Actions" 0 "aptdnf.log" --config "$TEST_ENV_DIR/aptdnf_config.conf" --clean --force --allow-outside-home --risk medium; then
  if grep -q "Mock apt-get called with: clean" "$TEST_ENV_DIR/aptdnf.log" && \
     grep -q "Mock dnf called with: clean all" "$TEST_ENV_DIR/aptdnf.log" && \
     ! grep -q "Mock pacman called" "$TEST_ENV_DIR/aptdnf.log" && \
     ! grep -q "Mock paccache called" "$TEST_ENV_DIR/aptdnf.log"; then
    echo -e "${GREEN}PASS: apt_clean ran 'apt-get clean' and dnf_clean ran 'dnf clean all'; no other manager was called.${NC}"
  else
    echo -e "${RED}FAIL: apt/dnf actions did not invoke their exact commands.${NC}"
    cat "$TEST_ENV_DIR/aptdnf.log"
    exit 1
  fi
else
  exit 1
fi

# 38. Test Case: a package-cache action safely degrades when its manager is absent
setup_mock_env
rm -f "$TEST_ENV_DIR/bin/dnf"   # simulate a host without dnf
echo -e "\n${BOLD}Test Case: Cross-Distro Safe Degradation${NC}"
if command -v dnf >/dev/null 2>&1; then
  echo -e "${GREEN}PASS (skipped): a real dnf is installed on this host; cannot simulate its absence.${NC}"
else
  cat << EOF > "$TEST_ENV_DIR/degrade_config.conf"
medium|DNF Clean|$OUTSIDE_DIR|Mock DNF cache|0||action:dnf_clean
EOF
  if run_test_case "Cross-Distro Degradation" 0 "degrade.log" --config "$TEST_ENV_DIR/degrade_config.conf" --clean --force --allow-outside-home --risk medium; then
    if grep -qi "not available on this platform" "$TEST_ENV_DIR/degrade.log" && \
       ! grep -q "command not found" "$TEST_ENV_DIR/degrade.log" && \
       ! grep -q "Mock dnf called" "$TEST_ENV_DIR/degrade.log"; then
      echo -e "${GREEN}PASS: dnf action skipped cleanly when dnf is absent (non-fatal, no command-not-found).${NC}"
    else
      echo -e "${RED}FAIL: dnf action did not degrade safely when dnf is absent.${NC}"
      cat "$TEST_ENV_DIR/degrade.log"
      exit 1
    fi
  else
    exit 1
  fi
fi

# 39. Test Case: action:pacman_clean invokes 'pacman -Sc --noconfirm'
setup_mock_env
cat << EOF > "$TEST_ENV_DIR/pacman_clean_config.conf"
medium|Pacman Purge|$OUTSIDE_DIR|Mock pacman purge|0||action:pacman_clean
EOF
if run_test_case "Pacman Clean Action" 0 "pacman_clean.log" --config "$TEST_ENV_DIR/pacman_clean_config.conf" --clean --force --allow-outside-home --risk medium; then
  if grep -q "Mock pacman called with: -Sc --noconfirm" "$TEST_ENV_DIR/pacman_clean.log"; then
    echo -e "${GREEN}PASS: action:pacman_clean invoked 'pacman -Sc --noconfirm'.${NC}"
  else
    echo -e "${RED}FAIL: pacman_clean did not invoke the expected command.${NC}"
    cat "$TEST_ENV_DIR/pacman_clean.log"
    exit 1
  fi
else
  exit 1
fi

# 40. Test Case: trash-mode predefined action shows the irreversibility warning
setup_mock_env
cat << EOF > "$TEST_ENV_DIR/trash_action_config.conf"
medium|Paccache Trash|$OUTSIDE_DIR|Mock paccache under trash|0||action:paccache_keep1
EOF
if run_test_case "Trash Action Warning" 0 "trash_action.log" --config "$TEST_ENV_DIR/trash_action_config.conf" --trash --force --allow-outside-home --risk medium; then
  if grep -q "bypass quarantine and run directly (irreversible deletion)" "$TEST_ENV_DIR/trash_action.log"; then
    echo -e "${GREEN}PASS: trash-mode predefined action logged the irreversibility warning.${NC}"
  else
    echo -e "${RED}FAIL: irreversibility warning not found for a trash-mode action.${NC}"
    cat "$TEST_ENV_DIR/trash_action.log"
    exit 1
  fi
else
  exit 1
fi

echo -e "\n${BOLD}${GREEN}All refactored tests passed successfully!${NC}"
exit 0

