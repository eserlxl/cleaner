#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

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
export TEST_ENV_DIR="${TEST_ENV_DIR:-$SCRIPT_DIR/test_env}"
MOCK_HOME="$TEST_ENV_DIR/mock_home"
# Last-report state stays inside the disposable test env.
export XDG_STATE_HOME="$TEST_ENV_DIR/xdg-state"
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
# -x matches the whole process name as a regular expression, like the real pgrep.
# The mocked binary is "mock_running_proc", but the kernel stores only its first 15
# characters, and real pgrep refuses a plain -x pattern longer than that.
if [[ "$1" == "-x" && ${#2} -gt 15 && "$2" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "pgrep: pattern that searches for process name longer than 15 characters will result in zero matches" >&2
  exit 1
fi
if [[ "$1" == "-x" && "mock_running_pr" =~ ^($2)$ ]]; then
  exit 0
fi
# -f matches the full command line. Answer with the PID of a real process the suite
# started, so the caller's liveness and ancestry checks see a genuine sibling rather
# than a fabricated number.
if [[ "$1" == "-f" ]]; then
  shift
  [[ "$1" == "--" ]] && shift
  if [[ "$1" == *mock_cmdline_proc* && -r "${TEST_ENV_DIR:-}/mock_cmdline_pid" ]]; then
    cat "${TEST_ENV_DIR}/mock_cmdline_pid"
    exit 0
  fi
  exit 1
fi
exit 1
EOF
  chmod +x "$TEST_ENV_DIR/bin/pgrep"
  export TEST_ENV_DIR

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

# Test-only privilege shim: make an unreadable target accessible when the
# cleaner reaches it through its sudo branch.
if [[ -n "${MOCK_SUDO_UNLOCK_PATH:-}" && "${1:-}" == "find" ]]; then
  chmod u+rwx "$MOCK_SUDO_UNLOCK_PATH"
fi

# Optional call log, so a test can prove a command was routed through sudo.
if [[ -n "${MOCK_SUDO_LOG:-}" ]]; then
  printf '%s\n' "$*" >> "$MOCK_SUDO_LOG"
fi

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

  # Cross-distro package-manager mocks (apt/apt-get/dnf/zypper/apk), same template as above.
  local _mgr
  for _mgr in apt apt-get dnf zypper apk; do
    cat > "$TEST_ENV_DIR/bin/$_mgr" << EOF
#!/usr/bin/env bash
# Mock $_mgr command
echo "Mock $_mgr called with: \$@"
exit 0
EOF
    chmod +x "$TEST_ENV_DIR/bin/$_mgr"
  done

  # User-level prune action mocks (uv, pnpm, hf)
  local _uact
  for _uact in uv pnpm hf; do
    cat > "$TEST_ENV_DIR/bin/$_uact" << EOF
#!/usr/bin/env bash
# Mock $_uact command
if [[ -n "\${MOCK_USER_ACTION_LOG:-}" ]]; then
  printf '%s %s\n' "$_uact" "\$*" >> "\$MOCK_USER_ACTION_LOG"
fi
echo "Mock $_uact called with: \$@"
exit 0
EOF
    chmod +x "$TEST_ENV_DIR/bin/$_uact"
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

# Tracked files protect the entire target, including untracked build output.
for git_target in "\$HOME/proj/build" "\$HOME/proj/build*"; do
  setup_mock_env
  mkdir -p "$MOCK_HOME/proj/build" "$MOCK_HOME/proj/build2" "$MOCK_HOME/plain-build"
  printf 'cache\n' > "$MOCK_HOME/proj/build/CMakeCache.txt"
  printf 'old output\n' > "$MOCK_HOME/proj/build/old.bin"
  touch -d '30 days ago' "$MOCK_HOME/proj/build/old.bin"
  printf 'source\n' > "$MOCK_HOME/proj/build/tracked.c"
  git_newline_file="$MOCK_HOME/proj/build/"$'tracked\nsource.c'
  printf 'source\n' > "$git_newline_file"
  printf 'cache\n' > "$MOCK_HOME/proj/build2/CMakeCache.txt"
  printf 'ignored output\n' > "$MOCK_HOME/proj/build2/output.bin"
  printf 'output\n' > "$MOCK_HOME/plain-build/output.bin"
  printf 'build2/\n' > "$MOCK_HOME/proj/.gitignore"
  (
    export HOME="$MOCK_HOME"
    git init -q "$MOCK_HOME/proj"
    git -C "$MOCK_HOME/proj" config user.name 'Cleaner Test'
    git -C "$MOCK_HOME/proj" config user.email 'cleaner-test@example.invalid'
    git -C "$MOCK_HOME/proj" add -- build/tracked.c "$git_newline_file"
    git -C "$MOCK_HOME/proj" -c commit.gpgsign=false -c core.hooksPath=/dev/null \
      commit -qm 'Track source in build tree'
    # An untrusted repository config must never run a command during the scan.
    git -C "$MOCK_HOME/proj" config core.fsmonitor "touch '$TEST_ENV_DIR/fsmonitor_ran'; false"
  )
  rm -f "$TEST_ENV_DIR/fsmonitor_ran"
  cat > "$TEST_ENV_DIR/git_guard.conf" <<GIT_GUARD
safe|Tracked Build|$git_target|Build tree with source|0||filter:cxx_build
safe|Tracked File|\$HOME/proj/build/tracked.c|Single source file|0||
safe|Plain Build|\$HOME/plain-build|Outside any repository|0||
GIT_GUARD
  if [[ "$git_target" != *'*' ]]; then
    printf '%s\n' "safe|Ignored Build|\$HOME/proj/build2|Ignored output|0||filter:cxx_build" \
      >> "$TEST_ENV_DIR/git_guard.conf"
  fi
  if ! run_test_case "Git-Tracked Target Guard JSON ($git_target)" 0 "git_guard_json.log" \
       --config "$TEST_ENV_DIR/git_guard.conf" --json --dry-run \
     || ! python3 - "$TEST_ENV_DIR/git_guard_json.log" "$MOCK_HOME" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
home = sys.argv[2]
targets = {target["path"]: target for target in data["targets"]}
for path in (home + "/proj/build", home + "/proj/build/tracked.c"):
    assert targets[path]["status"] == "skipped", targets[path]
    assert targets[path]["bytes"] == 0, targets[path]
for path in (home + "/proj/build2", home + "/plain-build"):
    assert targets[path]["status"] == "found", targets[path]
assert data["total_reclaimable_bytes"] == sum(target["bytes"] for target in targets.values())
PY
  then
    echo -e "${RED}FAIL: Git-tracked targets were not skipped with zero reclaimable bytes.${NC}"
    cat "$TEST_ENV_DIR/git_guard_json.log"
    exit 1
  fi
  if ! run_test_case "Git-Tracked Target Guard ($git_target)" 0 "git_guard.log" \
       --config "$TEST_ENV_DIR/git_guard.conf" --force \
     || ! grep -qF "[SKIP] Tracked Build: skipped: contains 2 git-tracked file(s) under '$MOCK_HOME/proj/build'." \
       "$TEST_ENV_DIR/git_guard.log" \
     || ! grep -qF "[SKIP] Tracked File: skipped: contains 1 git-tracked file(s)" "$TEST_ENV_DIR/git_guard.log" \
     || [[ ! -f "$MOCK_HOME/proj/build/tracked.c" || ! -f "$git_newline_file" \
        || ! -f "$MOCK_HOME/proj/build/CMakeCache.txt" || ! -f "$MOCK_HOME/proj/build/old.bin" \
        || -e "$MOCK_HOME/proj/build2" || -e "$MOCK_HOME/plain-build" \
        || -e "$TEST_ENV_DIR/fsmonitor_ran" ]]; then
    echo -e "${RED}FAIL: Git-tracked content or its untracked siblings were cleaned, or output controls were preserved.${NC}"
    cat "$TEST_ENV_DIR/git_guard.log"
    exit 1
  fi
  echo -e "${GREEN}PASS: Git-tracked targets and all contents survive --force; ignored and non-repo output is cleaned.${NC}"
done

# Old transcripts and durable memory share a tree and cannot be separated by age.
assert_row_exclusion() {
  local age="$1" mode="$2" global_source="${3:-none}"
  local target second test_name
  local -a mode_args=() global_args=()
  setup_mock_env
  target="$MOCK_HOME/projects"
  second="$MOCK_HOME/other-projects"
  test_name="Row Exclusion Age $age ($mode, $global_source)"
  mkdir -p "$target/p1/memory/empty" "$target/p1/uuid" "$second/p2/memory"
  printf 'old transcript\n' > "$target/p1/old.jsonl"
  printf 'nested transcript\n' > "$target/p1/uuid/old.jsonl"
  printf 'new transcript\n' > "$target/p1/new.jsonl"
  printf 'durable memory\n' > "$target/p1/memory/MEMORY.md"
  printf 'durable note\n' > "$target/p1/memory/note.md"
  printf 'disposable memory\n' > "$second/p2/memory/old.md"
  touch -d '30 days ago' "$target/p1/old.jsonl" "$target/p1/uuid/old.jsonl" \
    "$target/p1/memory/MEMORY.md" "$target/p1/memory/note.md" "$second/p2/memory/old.md"
  cat > "$TEST_ENV_DIR/row_exclusion.conf" <<'ROW_EXCLUSION'
medium|T|$HOME/projects|session transcripts|AGE||exclude:memory
medium|Next|$HOME/other-projects|no row exclusion|7||
ROW_EXCLUSION
  sed -i "s/|AGE|/|$age|/" "$TEST_ENV_DIR/row_exclusion.conf"
  [[ "$mode" == trash ]] && mode_args=(--trash)
  case "$global_source" in
    cli) global_args=(--exclude '*.keep') ;;
    env) export LINUX_CLEANER_EXCLUDE='*.keep' ;;
  esac
  if [[ "$global_source" != none ]]; then
    printf 'global exclusion\n' > "$target/p1/global.keep"
    printf 'global exclusion\n' > "$second/p2/global.keep"
    touch -d '30 days ago' "$target/p1/global.keep" "$second/p2/global.keep"
  fi
  if ! run_test_case "$test_name" 0 "row_exclusion.log" --config "$TEST_ENV_DIR/row_exclusion.conf" \
       --risk medium --force "${mode_args[@]}" "${global_args[@]}" \
     || [[ ! -d "$target" || ! -d "$target/p1/memory/empty" \
           || -e "$target/p1/old.jsonl" || -e "$target/p1/uuid/old.jsonl" \
           || -e "$second/p2/memory/old.md" ]] \
     || ! cmp -s "$target/p1/memory/MEMORY.md" <(printf 'durable memory\n') \
     || ! cmp -s "$target/p1/memory/note.md" <(printf 'durable note\n') \
     || { [[ "$age" == 7 ]] && [[ ! -f "$target/p1/new.jsonl" ]]; } \
     || { [[ "$age" == 0 ]] && [[ -e "$target/p1/new.jsonl" ]]; } \
     || { [[ "$global_source" != none ]] && \
          [[ ! -f "$target/p1/global.keep" || ! -f "$second/p2/global.keep" ]]; } \
     || grep -qE 'Executing action|Requires sudo|predefined action' "$TEST_ENV_DIR/row_exclusion.log"; then
    echo -e "${RED}FAIL: $test_name lost protected data, kept transcripts, or leaked exclusions.${NC}"
    cat "$TEST_ENV_DIR/row_exclusion.log"
    return 1
  fi
  unset LINUX_CLEANER_EXCLUDE
  echo -e "${GREEN}PASS: $test_name preserves memory and prunes the next target independently.${NC}"
}

assert_row_exclusion 7 permanent || exit 1
assert_row_exclusion 0 permanent || exit 1
assert_row_exclusion 7 trash || exit 1
assert_row_exclusion 0 trash || exit 1
assert_row_exclusion 7 permanent cli || exit 1
assert_row_exclusion 0 trash env || exit 1

setup_mock_env
mkdir -p "$MOCK_HOME/projects/p1/memory"
printf 'old jsonl\n' > "$MOCK_HOME/projects/p1/old.jsonl"
printf 'new jsonl\n' > "$MOCK_HOME/projects/p1/new.jsonl"
printf 'large durable memory that must not count\n' > "$MOCK_HOME/projects/p1/memory/MEMORY.md"
touch -d '30 days ago' "$MOCK_HOME/projects/p1/old.jsonl" "$MOCK_HOME/projects/p1/memory/MEMORY.md"
for row_age in 7 0; do
  printf "medium|T|\$HOME/projects|size test|%s||exclude:memory\n" "$row_age" > "$TEST_ENV_DIR/row_size.conf"
  expected_bytes=$(stat -c %s "$MOCK_HOME/projects/p1/old.jsonl")
  if [[ "$row_age" == 0 ]]; then
    expected_bytes=$((expected_bytes + $(stat -c %s "$MOCK_HOME/projects/p1/new.jsonl")))
  fi
  if ! run_test_case "Row Exclusion Dry Run Size (age $row_age)" 0 "row_size.log" \
       --config "$TEST_ENV_DIR/row_size.conf" --risk medium --dry-run --json \
     || ! python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["total_reclaimable_bytes"] == int(sys.argv[2])' \
       "$TEST_ENV_DIR/row_size.log" "$expected_bytes"; then
    echo -e "${RED}FAIL: row exclusion size included memory or ignored age.${NC}"
    exit 1
  fi
  echo -e "${GREEN}PASS: row exclusion dry-run size counts only eligible jsonl bytes.${NC}"
done

# Wildcard inventory must retain the token and ordinary ancestor pruning.
mkdir -p "$MOCK_HOME/projects/p1/nested"
printf "medium|T|\$HOME/projects/**|inventory|7||exclude:memory\n" > "$TEST_ENV_DIR/row_inventory.conf"
for row_output in text json; do
  row_output_args=()
  [[ "$row_output" == json ]] && row_output_args=(--json)
  if ! run_test_case "Row Exclusion Wildcard Inventory ($row_output)" 0 "row_inventory.log" \
       --config "$TEST_ENV_DIR/row_inventory.conf" --list-targets "${row_output_args[@]}" \
     || { [[ "$row_output" == json ]] && ! grep -q 'exclude:memory' "$TEST_ENV_DIR/row_inventory.log"; } \
     || grep -q '/p1/nested' "$TEST_ENV_DIR/row_inventory.log"; then
    echo -e "${RED}FAIL: row exclusion changed wildcard pruning or inventory token.${NC}"
    exit 1
  fi
  echo -e "${GREEN}PASS: row exclusion inventory retains its token and wildcard pruning.${NC}"
done

for row_token in 'exclude:' 'exclude:a,,b' 'exclude:a,' 'exclude: ,b' 'exclude:a, ,b' \
                 'exclude:a|b' $'exclude:a\nb' 'exclude:memory' 'exclude:memory,cache'; do
  row_expected_exit=1
  case "$row_token" in
    exclude:memory|exclude:memory,cache) row_expected_exit=0 ;;
  esac
  printf "medium|T|\$HOME/projects|validation|7||%s\n" "$row_token" > "$TEST_ENV_DIR/row_validation.conf"
  if ! run_test_case "Row Exclusion Validation ($row_token)" "$row_expected_exit" "row_validation.log" \
       --config "$TEST_ENV_DIR/row_validation.conf" --check-config \
     || { [[ "$row_expected_exit" == 1 ]] && \
          ! grep -qE 'row_validation.conf:[12]:' "$TEST_ENV_DIR/row_validation.log"; }; then
    echo -e "${RED}FAIL: row exclusion validation returned the wrong result or omitted its source line.${NC}"
    exit 1
  fi
  echo -e "${GREEN}PASS: row exclusion validation reports the expected result.${NC}"
done

setup_mock_env

# 1. Test Case: Dry Run Mode (Default without flags)
  if run_test_case "Dry Run Mode (Default)" 0 "dry_run.log" --debug --config "$TEST_ENV_DIR/test_cleaner.conf"; then
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
  
  # C. Outside HOME is FOUND without a special flag
  if grep -q "FOUND.*Outside HOME Target.*(outside HOME)$" "$TEST_ENV_DIR/dry_run.log"; then
    echo -e "${GREEN}PASS: Target outside HOME was listed as FOUND.${NC}"
  else
    echo -e "${RED}FAIL: Outside HOME target was not listed as FOUND.${NC}"
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
if run_test_case "Dry Run with Risk Medium" 0 "dry_run_medium.log" --debug --config "$TEST_ENV_DIR/test_cleaner.conf" --risk medium --dry-run; then
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
  # The path was $HOME/tilde~test. Check if it was resolved correctly (not as $HOME/tilde<expanded-HOME>test)
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

# 4. Test Case: deprecated --allow-outside-home is a no-op warning; outside HOME stays FOUND.
if run_test_case "Outside HOME with --allow-outside-home" 0 "outside_home.log" --debug --config "$TEST_ENV_DIR/test_cleaner.conf" --allow-outside-home --dry-run; then
  if grep -q "FOUND.*Outside HOME Target.*(outside HOME)$" "$TEST_ENV_DIR/outside_home.log" \
     && grep -qF "Warning: --allow-outside-home is deprecated and has no effect; targets outside HOME are always allowed." "$TEST_ENV_DIR/outside_home.log" \
     && ! grep -q "WARNING.*Outside HOME Target" "$TEST_ENV_DIR/outside_home.log"; then
    echo -e "${GREEN}PASS: --allow-outside-home warns once and outside HOME stays FOUND.${NC}"
  else
    echo -e "${RED}FAIL: --allow-outside-home did not warn, or the outside HOME target was not FOUND.${NC}"
    cat "$TEST_ENV_DIR/outside_home.log"
    exit 1
  fi
else
  exit 1
fi

# Deprecated env mirror: one warning, the run still succeeds, outside HOME stays FOUND.
setup_mock_env
echo -e "\n${BOLD}Test Case: LINUX_CLEANER_ALLOW_OUTSIDE_HOME Env${NC}"
LINUX_CLEANER_ALLOW_OUTSIDE_HOME=1 PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
  "$CLEANER_SH" --debug --config "$TEST_ENV_DIR/test_cleaner.conf" --dry-run \
  > "$TEST_ENV_DIR/allow_outside_env.log" 2>&1 || allow_env_ec=$?
if [[ ${allow_env_ec:-0} -eq 0 ]] \
   && grep -q "FOUND.*Outside HOME Target.*(outside HOME)$" "$TEST_ENV_DIR/allow_outside_env.log" \
   && grep -qF "Warning: LINUX_CLEANER_ALLOW_OUTSIDE_HOME is deprecated and has no effect; targets outside HOME are always allowed." "$TEST_ENV_DIR/allow_outside_env.log" \
   && ! grep -q "WARNING.*Outside HOME Target" "$TEST_ENV_DIR/allow_outside_env.log"; then
  echo -e "${GREEN}PASS: LINUX_CLEANER_ALLOW_OUTSIDE_HOME warns once and the run still succeeds.${NC}"
else
  echo -e "${RED}FAIL: LINUX_CLEANER_ALLOW_OUTSIDE_HOME did not warn or the run failed (ec=${allow_env_ec:-0}).${NC}"
  cat "$TEST_ENV_DIR/allow_outside_env.log"
  exit 1
fi

# Flag and env together still warn at most once.
setup_mock_env
echo -e "\n${BOLD}Test Case: Allow Outside HOME Deprecation Once${NC}"
both_ec=0
LINUX_CLEANER_ALLOW_OUTSIDE_HOME=1 PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
  "$CLEANER_SH" --allow-outside-home --debug --config "$TEST_ENV_DIR/test_cleaner.conf" --dry-run \
  > "$TEST_ENV_DIR/allow_outside_both.log" 2>&1 || both_ec=$?
both_warns=$(grep -c 'deprecated and has no effect' "$TEST_ENV_DIR/allow_outside_both.log" || true)
if [[ "$both_ec" -eq 0 && "$both_warns" -eq 1 ]]; then
  echo -e "${GREEN}PASS: flag and env together print one deprecation warning.${NC}"
else
  echo -e "${RED}FAIL: expected one deprecation warning and exit 0 (ec=$both_ec warns=$both_warns).${NC}"
  cat "$TEST_ENV_DIR/allow_outside_both.log"
  exit 1
fi

# Default cleanup asks one question; outside-HOME targets get no extra prompt.
setup_mock_env
mkdir -p "$OUTSIDE_DIR/first" "$OUTSIDE_DIR/second"
printf 'outside one\n' > "$OUTSIDE_DIR/first/cache.txt"
printf 'outside two\n' > "$OUTSIDE_DIR/second/cache.txt"
cat > "$TEST_ENV_DIR/outside_confirmation.conf" <<EOF
safe|Outside One|$OUTSIDE_DIR/first|first outside cache|0||
safe|Outside Two|$OUTSIDE_DIR/second|second outside cache|0||
safe|Inside|$MOCK_HOME/.cache/yarn|inside cache|0||
EOF
echo -e "\n${BOLD}Test Case: Outside HOME Single Confirmation${NC}"
outside_ec=0
PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
  "$CLEANER_SH" --config "$TEST_ENV_DIR/outside_confirmation.conf" --clean \
  < <(printf 'y\n') > "$TEST_ENV_DIR/outside_confirmation.log" 2>&1 || outside_ec=$?
prompt_count=$(grep -oF '[y/N]:' "$TEST_ENV_DIR/outside_confirmation.log" | wc -l) || prompt_count=0
if [[ "$outside_ec" -eq 0 && "$prompt_count" -eq 1 \
      && ! -f "$OUTSIDE_DIR/first/cache.txt" && ! -f "$OUTSIDE_DIR/second/cache.txt" \
      && ! -f "$MOCK_HOME/.cache/yarn/yarn-cache.json" ]] \
   && ! grep -q 'outside HOME. Clean them too' "$TEST_ENV_DIR/outside_confirmation.log"; then
  echo -e "${GREEN}PASS: one confirmation cleans inside and outside-HOME targets.${NC}"
else
  echo -e "${RED}FAIL: expected one prompt and every target cleaned (ec=$outside_ec prompts=$prompt_count).${NC}"
  cat "$TEST_ENV_DIR/outside_confirmation.log"
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

# Digit-only ages are decimal configuration values, not Bash arithmetic literals.
assert_zero_padded_age_filter() {
  local mode="$1" label="$2"
  local target old_file recent_file quarantined_old=""
  local -a mode_args=()

  setup_mock_env
  target="$MOCK_HOME/.cache/zero_padded_age"
  old_file="$target/old.txt"
  recent_file="$target/recent.txt"
  mkdir -p "$target"
  echo old > "$old_file"
  echo recent > "$recent_file"
  touch -d "10 days ago" "$old_file"
  touch -d "2 days ago" "$recent_file"
  printf 'safe|Zero Padded Age|%s|Decimal age filter|08||\n' "$target" > "$TEST_ENV_DIR/zero_padded_age.conf"
  [[ "$mode" == trash ]] && mode_args+=(--trash)

  if run_test_case "$label" 0 "zero_padded_${mode}.log" \
       --config "$TEST_ENV_DIR/zero_padded_age.conf" --force "${mode_args[@]}"; then
    if [[ "$mode" == trash ]]; then
      quarantined_old=$(find "$MOCK_HOME/.cache/linux-cleaner/quarantine" -name old.txt -print -quit)
    fi
    if [[ ! -e "$old_file" && -f "$recent_file" ]] \
       && [[ "$mode" != trash || -n "$quarantined_old" ]] \
       && ! grep -q "value too great for base" "$TEST_ENV_DIR/zero_padded_${mode}.log"; then
      echo -e "${GREEN}PASS: $label treated 08 as an eight-day filter.${NC}"
      return 0
    fi
  fi

  echo -e "${RED}FAIL: $label did not preserve only the recent file.${NC}"
  cat "$TEST_ENV_DIR/zero_padded_${mode}.log"
  return 1
}

assert_zero_padded_age_filter permanent "Zero-Padded Age Permanent" || exit 1
assert_zero_padded_age_filter trash "Zero-Padded Age Trash" || exit 1

setup_mock_env
zero_age_target="$MOCK_HOME/.cache/all_zero_age"
mkdir -p "$zero_age_target"
echo payload > "$zero_age_target/payload"
printf 'safe|All Zero Age|%s|Whole target|000||\n' "$zero_age_target" > "$TEST_ENV_DIR/all_zero_age.conf"
if run_test_case "All-Zero Age Whole Target" 0 "all_zero_age.log" \
     --config "$TEST_ENV_DIR/all_zero_age.conf" --force \
   && [[ ! -e "$zero_age_target" ]]; then
  echo -e "${GREEN}PASS: an all-zero minimum age retained whole-target semantics.${NC}"
else
  echo -e "${RED}FAIL: an all-zero minimum age no longer selected the whole target.${NC}"
  cat "$TEST_ENV_DIR/all_zero_age.log"
  exit 1
fi

setup_mock_env
huge_age_target="$MOCK_HOME/.cache/huge_age"
mkdir -p "$huge_age_target"
echo recent > "$huge_age_target/recent.txt"
printf 'safe|Huge Age|%s|Overflow guard|999999999999999999999999999999999999||\n' \
  "$huge_age_target" > "$TEST_ENV_DIR/huge_age.conf"
huge_age_ec=0
PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" "$CLEANER_SH" \
  --config "$TEST_ENV_DIR/huge_age.conf" --force < /dev/null \
  > "$TEST_ENV_DIR/huge_age.log" 2>&1 || huge_age_ec=$?
if [[ -f "$huge_age_target/recent.txt" ]] \
   && ! grep -Eq "value too great for base|invalid arithmetic" "$TEST_ENV_DIR/huge_age.log"; then
  echo -e "${GREEN}PASS: an oversized nonzero age did not overflow into whole-target cleanup (exit $huge_age_ec).${NC}"
else
  echo -e "${RED}FAIL: an oversized age triggered arithmetic fallback or removed the target.${NC}"
  cat "$TEST_ENV_DIR/huge_age.log"
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

# 6b. Test Case: same-second trash runs allocate distinct, chronologically sortable sessions
setup_mock_env
cat << 'EOF' > "$TEST_ENV_DIR/bin/date"
#!/usr/bin/env bash
printf '%s\n' '2026-09-05_12-00-00'
EOF
chmod +x "$TEST_ENV_DIR/bin/date"
cat << EOF > "$TEST_ENV_DIR/session_collision.conf"
safe|Collision Cache|\$HOME/.cache/session_collision|Fixed-date collision target|0||
EOF
mkdir -p "$MOCK_HOME/.cache/session_collision"
echo first > "$MOCK_HOME/.cache/session_collision/payload"
if ! run_test_case "Quarantine Session Collision First Run" 0 "session_collision_first.log" \
     --config "$TEST_ENV_DIR/session_collision.conf" --trash --force; then
  exit 1
fi

collision_base="$MOCK_HOME/.cache/linux-cleaner/quarantine/2026-09-05_12-00-00"
for collision_n in {1..10}; do
  printf -v collision_suffix '%06d' "$collision_n"
  mkdir -p "${collision_base}_${collision_suffix}"
  echo sentinel > "${collision_base}_${collision_suffix}/sentinel"
done

mkdir -p "$MOCK_HOME/.cache/session_collision"
echo second > "$MOCK_HOME/.cache/session_collision/payload"
if ! run_test_case "Quarantine Session Collision Second Run" 0 "session_collision_second.log" \
     --config "$TEST_ENV_DIR/session_collision.conf" --trash --force; then
  exit 1
fi

collision_latest="${collision_base}_000011"
collision_session_count=$(find "$(dirname "$collision_base")" -mindepth 1 -maxdepth 1 -type d | wc -l)
if [[ "$collision_session_count" -ne 12 ]] \
   || ! grep -qx first "$collision_base/0_Collision_Cache/payload" \
   || ! grep -qx second "$collision_latest/0_Collision_Cache/payload"; then
  echo -e "${RED}FAIL: same-second trash runs reused a session or produced the wrong payload layout.${NC}"
  find "$(dirname "$collision_base")" -mindepth 1 -printf '%P %y\n' | sort
  exit 1
fi

if run_test_case "Restore Latest Collision-Suffixed Session" 0 "session_collision_restore.log" --restore latest \
   && grep -qx second "$MOCK_HOME/.cache/session_collision/payload" \
   && [[ -f "$collision_base/0_Collision_Cache/payload" ]] \
   && [[ ! -d "$collision_latest" ]]; then
  echo -e "${GREEN}PASS: same-second trash runs use distinct padded sessions and latest restores the newest.${NC}"
else
  echo -e "${RED}FAIL: padded collision sessions did not preserve latest restore ordering.${NC}"
  cat "$TEST_ENV_DIR/session_collision_restore.log"
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

if run_test_case "Predefined Action" 0 "sudo_custom.log" --config "$TEST_ENV_DIR/sudo_custom_config.conf" --clean --force --risk medium; then
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

# Excluded empty directories must survive the follow-up directory sweep. Cover
# permanent/quarantine and plain/mock-sudo branches; ordinary empty directories
# should still be removed.
assert_excluded_empty_directory() {
  local test_name="$1" mode="$2" via_sudo="$3"
  local target="$MOCK_HOME/.cache/excluded-empty"
  local -a mode_args=()

  setup_mock_env
  mkdir -p "$target/keep-empty" "$target/drop-empty"
  echo "delete me" > "$target/delete.txt"
  cat << EOF > "$TEST_ENV_DIR/excluded_empty.conf"
safe|Excluded Empty|\$HOME/.cache/excluded-empty|empty directory exclusion|0||
EOF
  if [[ "$mode" == trash ]]; then
    mode_args+=(--trash)
  fi
  if [[ "$via_sudo" == true ]]; then
    chmod 000 "$target"
    export MOCK_SUDO_UNLOCK_PATH="$target"
  else
    unset MOCK_SUDO_UNLOCK_PATH || true
  fi

  if run_test_case "$test_name" 0 "${test_name// /_}.log" \
       --config "$TEST_ENV_DIR/excluded_empty.conf" --exclude keep-empty --force "${mode_args[@]}"; then
    unset MOCK_SUDO_UNLOCK_PATH || true
    if [[ -d "$target/keep-empty" && ! -d "$target/drop-empty" && ! -e "$target/delete.txt" ]]; then
      echo -e "${GREEN}PASS: $test_name preserved the excluded empty directory and removed ordinary empty content.${NC}"
      return 0
    fi
  fi

  unset MOCK_SUDO_UNLOCK_PATH || true
  chmod u+rwx "$target" 2>/dev/null || true
  echo -e "${RED}FAIL: $test_name did not preserve only the excluded empty directory.${NC}"
  return 1
}

assert_excluded_empty_directory "Excluded Empty Permanent Plain" permanent false || exit 1
assert_excluded_empty_directory "Excluded Empty Trash Plain" trash false || exit 1
assert_excluded_empty_directory "Excluded Empty Permanent Sudo" permanent true || exit 1
assert_excluded_empty_directory "Excluded Empty Trash Sudo" trash true || exit 1

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

# 11b. Test Case: Purge quarantine sessions to reclaim space
setup_mock_env

# Missing quarantine base must exit 1 before any selector work.
rm -rf "$MOCK_HOME/.cache/linux-cleaner/quarantine"
if run_test_case "Purge Missing Base" 1 "purge_missing_base.log" --purge-sessions latest --force; then
  if grep -q "No quarantine directory exists" "$TEST_ENV_DIR/purge_missing_base.log"; then
    echo -e "${GREEN}PASS: Purging with no quarantine base exits non-zero.${NC}"
  else
    echo -e "${RED}FAIL: Purge Missing Base exited 1 without the expected message.${NC}"
    cat "$TEST_ENV_DIR/purge_missing_base.log"
    exit 1
  fi
else
  exit 1
fi

if run_test_case "Quarantine for Purge" 0 "quarantine_purge_setup.log" --config "$TEST_ENV_DIR/test_cleaner.conf" --trash --force; then
  quarantine_base="$MOCK_HOME/.cache/linux-cleaner/quarantine"
  if [[ ! -d "$quarantine_base" ]] || [[ -z "$(find "$quarantine_base" -mindepth 1 -maxdepth 1 -type d)" ]]; then
    echo -e "${RED}FAIL: Quarantine session not created for purge test.${NC}"
    exit 1
  fi
else
  exit 1
fi

# Purging a non-existent named session must fail (base exists, session does not).
if run_test_case "Purge Missing Session" 1 "purge_missing.log" --purge-sessions 19700101-000000 --force; then
  echo -e "${GREEN}PASS: Purging a missing session exits non-zero.${NC}"
else
  exit 1
fi

# Path-escaping SESSION names must be rejected before any restore/purge work.
for bad_session in '../x' '.' '..'; do
  if run_test_case "Restore Invalid Session ${bad_session}" 1 "restore_invalid_${bad_session//\//_}.log" --restore "$bad_session"; then
    if grep -q "Invalid session name" "$TEST_ENV_DIR/restore_invalid_${bad_session//\//_}.log"; then
      echo -e "${GREEN}PASS: --restore '${bad_session}' rejected as Invalid session name.${NC}"
    else
      echo -e "${RED}FAIL: --restore '${bad_session}' exited 1 without Invalid session name.${NC}"
      cat "$TEST_ENV_DIR/restore_invalid_${bad_session//\//_}.log"
      exit 1
    fi
  else
    exit 1
  fi
  if run_test_case "Purge Invalid Session ${bad_session}" 1 "purge_invalid_${bad_session//\//_}.log" --purge-sessions "$bad_session" --force; then
    if grep -q "Invalid session name" "$TEST_ENV_DIR/purge_invalid_${bad_session//\//_}.log"; then
      echo -e "${GREEN}PASS: --purge-sessions '${bad_session}' rejected as Invalid session name.${NC}"
    else
      echo -e "${RED}FAIL: --purge-sessions '${bad_session}' exited 1 without Invalid session name.${NC}"
      cat "$TEST_ENV_DIR/purge_invalid_${bad_session//\//_}.log"
      exit 1
    fi
  else
    exit 1
  fi
done

# --force skips the confirmation prompt (stdin is /dev/null in the harness).
if run_test_case "Purge All Sessions" 0 "purge_all.log" --purge-sessions all --force; then
  if [[ -d "$quarantine_base" ]]; then
    echo -e "${RED}FAIL: Quarantine base still exists after purging all sessions.${NC}"
    find "$quarantine_base"
    exit 1
  else
    echo -e "${GREEN}PASS: All quarantine sessions purged and empty base removed.${NC}"
  fi
else
  exit 1
fi

# 11c. Test Case: Purge selectivity (latest) and confirmation abort
setup_mock_env
purge_qb="$MOCK_HOME/.cache/linux-cleaner/quarantine"
mkdir -p "$purge_qb/20200101-000000" "$purge_qb/20991231-235959"

# Decline at the confirmation prompt (stdin is /dev/null -> empty reply -> abort)
# must keep every session.
if run_test_case "Purge Declined Keeps Sessions" 0 "purge_decline.log" --purge-sessions all; then
  if [[ -d "$purge_qb/20200101-000000" && -d "$purge_qb/20991231-235959" ]]; then
    echo -e "${GREEN}PASS: declined purge kept all sessions.${NC}"
  else
    echo -e "${RED}FAIL: declined purge deleted sessions.${NC}"
    exit 1
  fi
else
  exit 1
fi

# --purge-sessions latest removes only the newest session, keeping older ones.
if run_test_case "Purge Latest Selectivity" 0 "purge_latest.log" --purge-sessions latest --force; then
  if [[ -d "$purge_qb/20200101-000000" && ! -d "$purge_qb/20991231-235959" ]]; then
    echo -e "${GREEN}PASS: purge latest removed only the newest session.${NC}"
  else
    echo -e "${RED}FAIL: purge latest did not select the newest session correctly.${NC}"
    exit 1
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

  conflict_meta="$latest_session/quarantine.meta"
  if [[ "$(grep -c '^[^#[:space:]]' "$conflict_meta")" -eq 1 ]] \
     && grep -qF "|$MOCK_HOME/.npm/_cacache|" "$conflict_meta"; then
    echo -e "${GREEN}PASS: partial restore metadata retained only the conflicted target.${NC}"
  else
    echo -e "${RED}FAIL: partial restore metadata retained stale records for targets already restored.${NC}"
    cat "$conflict_meta"
    exit 1
  fi

  rm -rf "$MOCK_HOME/.npm/_cacache"
  if run_test_case "Restore Retry After Conflict" 0 "restore_conflict_retry.log" --restore latest; then
    if [[ -f "$MOCK_HOME/.npm/_cacache/cache1.txt" && ! -d "$latest_session" ]]; then
      echo -e "${GREEN}PASS: restore retry succeeded after the destination conflict was cleared.${NC}"
    else
      echo -e "${RED}FAIL: restore retry did not restore the remaining target or retire the session.${NC}"
      cat "$TEST_ENV_DIR/restore_conflict_retry.log"
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
if run_test_case "Invalid Exclusions Dry Run" 0 "exclusions_invalid.log" --debug --config "$TEST_ENV_DIR/test_cleaner.conf" --exclude ",," --dry-run; then
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

# 16. Test Case: Canonicalization ..-traversal escape is FOUND at the canonical outside path
setup_mock_env
dotdot_canon="$(realpath -m "$MOCK_HOME/../dotdot_escape_probe")"
mkdir -p "$dotdot_canon"
echo probe > "$dotdot_canon/probe.txt"
cat << EOF > "$TEST_ENV_DIR/dotdot_escape.conf"
safe|Dotdot Escape Probe|\$HOME/../dotdot_escape_probe|Path climbing above HOME via ..|0||
EOF
if run_test_case "Canonicalization Dotdot Escape" 0 "dotdot_escape.log" --debug --config "$TEST_ENV_DIR/dotdot_escape.conf" --dry-run; then
  if grep -q "FOUND.*Dotdot Escape Probe.*(outside HOME)" "$TEST_ENV_DIR/dotdot_escape.log" \
     && grep -qF "$dotdot_canon" "$TEST_ENV_DIR/dotdot_escape.log" \
     && ! grep -qF "$MOCK_HOME/../dotdot_escape_probe" "$TEST_ENV_DIR/dotdot_escape.log"; then
    echo -e "${GREEN}PASS: '..'-traversal path was FOUND under its canonical outside path.${NC}"
  else
    echo -e "${RED}FAIL: '..'-traversal escape was not FOUND at the canonical path.${NC}"
    cat "$TEST_ENV_DIR/dotdot_escape.log"
    exit 1
  fi
else
  exit 1
fi

# 17. Test Case: Symlinked-parent escape resolves to the canonical outside path and is FOUND
setup_mock_env
mkdir -p "$OUTSIDE_DIR/sub"
echo kept > "$OUTSIDE_DIR/sub/kept.txt"
ln -s "$OUTSIDE_DIR" "$MOCK_HOME/escape_link"
symlink_canon="$(realpath "$OUTSIDE_DIR/sub")"
cat << EOF > "$TEST_ENV_DIR/symlink_parent.conf"
safe|Symlinked Parent Escape|\$HOME/escape_link/sub|Target under a symlinked parent that escapes HOME|0||
EOF
if run_test_case "Symlinked Parent Escape" 0 "symlink_parent.log" --debug --config "$TEST_ENV_DIR/symlink_parent.conf" --dry-run; then
  if grep -q "FOUND.*Symlinked Parent Escape.*(outside HOME)" "$TEST_ENV_DIR/symlink_parent.log" \
     && grep -qF "$symlink_canon" "$TEST_ENV_DIR/symlink_parent.log" \
     && ! grep -qF "$MOCK_HOME/escape_link/sub" "$TEST_ENV_DIR/symlink_parent.log" \
     && [[ -f "$OUTSIDE_DIR/sub/kept.txt" ]]; then
    echo -e "${GREEN}PASS: Symlinked parent was FOUND at its canonical outside path; real outside dir untouched.${NC}"
  else
    echo -e "${RED}FAIL: Symlinked-parent escape was not FOUND at the canonical path.${NC}"
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

# Test Case: HOME itself, including aliases, is protected even with bypass flags.
setup_mock_env
home_sentinel="$MOCK_HOME/home-sentinel.txt"
echo "must survive" > "$home_sentinel"
cat << EOF > "$TEST_ENV_DIR/home_root.conf"
safe|HOME Root|\$HOME|Mock HOME root|0||
safe|HOME Slash|\$HOME/|Mock HOME trailing slash|0||
safe|HOME Dotdot|\$HOME/.cache/..|Mock HOME dot-dot alias|0||
safe|NPM Descendant|\$HOME/.npm/_cacache|Allowed HOME descendant|0||
EOF
if run_test_case "HOME Root Protected from Bypass Flags" 0 "home_root.log" --debug --force --allow-outside-home --dry-run --config "$TEST_ENV_DIR/home_root.conf"; then
  if grep -q "UNSAFE.*HOME Root" "$TEST_ENV_DIR/home_root.log" && \
     grep -q "UNSAFE.*HOME Slash" "$TEST_ENV_DIR/home_root.log" && \
     grep -q "UNSAFE.*HOME Dotdot" "$TEST_ENV_DIR/home_root.log" && \
     grep -q "FOUND.*NPM Descendant" "$TEST_ENV_DIR/home_root.log" && \
     [[ -f "$home_sentinel" ]]; then
    echo -e "${GREEN}PASS: HOME root aliases stay protected while descendants remain allowed, even with bypass flags.${NC}"
  else
    echo -e "${RED}FAIL: HOME root protection, alias handling, or descendant allowance regressed.${NC}"
    cat "$TEST_ENV_DIR/home_root.log"
    exit 1
  fi
else
  exit 1
fi

# 20. Test Case: --force cleans an outside-HOME target with no extra flag
setup_mock_env
if run_test_case "Actual Outside HOME Clean" 0 "outside_clean.log" --config "$TEST_ENV_DIR/test_cleaner.conf" --force; then
  if [[ ! -f "$OUTSIDE_DIR/outside.txt" ]]; then
    echo -e "${GREEN}PASS: Outside-HOME target was deleted under --force.${NC}"
  else
    echo -e "${RED}FAIL: Outside-HOME target survived a destructive --force run.${NC}"
    cat "$TEST_ENV_DIR/outside_clean.log"
    exit 1
  fi
else
  exit 1
fi

# 21. Test Case: a root-requiring target is skipped when sudo cannot authenticate
setup_mock_env
root_target="$MOCK_HOME/.cache/needs-root"
plain_target="$MOCK_HOME/.cache/plain-sibling"
mkdir -p "$root_target" "$plain_target"
echo secret > "$root_target/secret.txt"
echo plain > "$plain_target/plain.txt"
root_canon="$(realpath "$root_target")"
chmod 000 "$root_target"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TEST_ENV_DIR/bin/sudo"
chmod +x "$TEST_ENV_DIR/bin/sudo"
cat > "$TEST_ENV_DIR/root_skip.conf" <<EOF
safe|Needs Root|$root_target|unreadable cache|0||
safe|Plain Sibling|$plain_target|writable cache|0||
EOF
root_log="$MOCK_HOME/root-skip.log"
if run_test_case "Root Skip Without Privileges" 0 "root_skip_run.log" \
     --config "$TEST_ENV_DIR/root_skip.conf" --clean --force --log "$root_log"; then
  chmod u+rwx "$root_target" 2>/dev/null || true
  if grep -qF "Warning: skipping 'Needs Root' ($root_canon): requires root privileges that are not available." "$TEST_ENV_DIR/root_skip_run.log" \
     && grep -qF "outcome=skipped reason=requires-root" "$root_log" \
     && grep -qF "Skipped (requires root): Needs Root" "$TEST_ENV_DIR/root_skip_run.log" \
     && grep -qF "Skipped (requires root): Needs Root" "$XDG_STATE_HOME/linux-cleaner/last-report.txt" \
     && grep -q '^Targets: found=1 .* skipped=1 ' "$XDG_STATE_HOME/linux-cleaner/last-report.txt" \
     && grep -q '^Result: cleaned=1 skipped=1 failed=0 ' "$XDG_STATE_HOME/linux-cleaner/last-report.txt" \
     && [[ ! -e "$plain_target" ]] \
     && [[ -f "$root_target/secret.txt" ]]; then
    echo -e "${GREEN}PASS: root target was skipped with a warning and log record, counted once in plan and result; the sibling was cleaned.${NC}"
  else
    echo -e "${RED}FAIL: root skip did not warn, log, list the plan skip, and clean the sibling.${NC}"
    cat "$TEST_ENV_DIR/root_skip_run.log" "$root_log" "$XDG_STATE_HOME/linux-cleaner/last-report.txt" 2>/dev/null
    exit 1
  fi
else
  chmod u+rwx "$root_target" 2>/dev/null || true
  exit 1
fi

# 22. Test Case: format_bytes GB scaling (unit_idx reaching 3)
setup_mock_env
mkdir -p "$MOCK_HOME/.cache/gb_probe"
truncate -s 2G "$MOCK_HOME/.cache/gb_probe/big.sparse"
cat << EOF > "$TEST_ENV_DIR/gb_size.conf"
safe|GB Size Probe|\$HOME/.cache/gb_probe|Sparse 2G file to exercise GB scaling|0||
EOF
if run_test_case "format_bytes GB Scaling" 0 "gb_size.log" --debug --config "$TEST_ENV_DIR/gb_size.conf" --dry-run; then
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
if run_test_case "format_bytes TB Scaling" 0 "tb_size.log" --debug --config "$TEST_ENV_DIR/tb_size.conf" --dry-run; then
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

# --list-sessions --json: empty inventory is {"sessions":[]} with no human banners.
if run_test_case "List Sessions JSON Empty" 0 "list_sessions_json_empty.log" --list-sessions --json; then
  if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d=={"sessions":[]}' \
       "$TEST_ENV_DIR/list_sessions_json_empty.log" 2>/dev/null \
     && ! grep -q "Quarantine Sessions" "$TEST_ENV_DIR/list_sessions_json_empty.log"; then
    echo -e "${GREEN}PASS: --list-sessions --json emits an empty sessions array.${NC}"
  else
    echo -e "${RED}FAIL: --list-sessions --json empty inventory was not valid JSON.${NC}"
    cat "$TEST_ENV_DIR/list_sessions_json_empty.log"
    exit 1
  fi
else
  exit 1
fi

# Populated --list-sessions --json after a trash run.
setup_mock_env
if run_test_case "Quarantine for List Sessions JSON" 0 "list_sessions_json_setup.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --trash --force; then
  if run_test_case "List Sessions JSON" 0 "list_sessions_json.log" --list-sessions --json; then
    if python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
assert "sessions" in d and len(d["sessions"])>=1
s=d["sessions"][0]
assert "timestamp" in s and "size_bytes" in s and isinstance(s["size_bytes"], int)
assert "size_human" in s and isinstance(s["size_human"], str) and len(s["size_human"])>0
assert "date" in s and isinstance(s["date"], str) and len(s["date"])>0
assert any(t.get("type")=="full" and "/.npm/_cacache" in t.get("path","") for t in s.get("targets",[]))
' "$TEST_ENV_DIR/list_sessions_json.log" 2>/dev/null \
       && ! grep -q "Quarantine Sessions" "$TEST_ENV_DIR/list_sessions_json.log"; then
      echo -e "${GREEN}PASS: --list-sessions --json emits session timestamps and target paths.${NC}"
    else
      echo -e "${RED}FAIL: --list-sessions --json populated inventory was incomplete.${NC}"
      cat "$TEST_ENV_DIR/list_sessions_json.log"
      exit 1
    fi
  else
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

# (b) LINUX_CLEANER_LOG env enables logging without --log
setup_mock_env
env_log_path="$MOCK_HOME/.cache/linux-cleaner/env-ops.log"
env_ec=0
LINUX_CLEANER_LOG="$env_log_path" PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
  "$CLEANER_SH" --config "$TEST_ENV_DIR/test_cleaner.conf" --force < /dev/null \
  > "$TEST_ENV_DIR/log_env.log" 2>&1 || env_ec=$?
if [[ $env_ec -ne 0 ]]; then
  echo -e "${RED}FAIL: LINUX_CLEANER_LOG activation run exited $env_ec.${NC}"
  cat "$TEST_ENV_DIR/log_env.log"
  exit 1
fi
if [[ -f "$env_log_path" ]] && grep -q "target='NPM Cache'" "$env_log_path"; then
  echo -e "${GREEN}PASS: LINUX_CLEANER_LOG enabled logging without --log.${NC}"
else
  echo -e "${RED}FAIL: LINUX_CLEANER_LOG did not write the expected log entry.${NC}"
  cat "$env_log_path" 2>/dev/null
  exit 1
fi

# (c) LINUX_CLEANER_LOG tilde expansion resolves under mock HOME
setup_mock_env
tilde_log_path="$MOCK_HOME/.cache/linux-cleaner/tilde-log-test.log"
tilde_ec=0
# shellcheck disable=SC2088  # literal ~ is intentional; cleaner expands it at runtime
LINUX_CLEANER_LOG='~/.cache/linux-cleaner/tilde-log-test.log' PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
  "$CLEANER_SH" --config "$TEST_ENV_DIR/test_cleaner.conf" --force < /dev/null \
  > "$TEST_ENV_DIR/log_tilde.log" 2>&1 || tilde_ec=$?
if [[ $tilde_ec -ne 0 ]]; then
  echo -e "${RED}FAIL: LINUX_CLEANER_LOG tilde expansion run exited $tilde_ec.${NC}"
  cat "$TEST_ENV_DIR/log_tilde.log"
  exit 1
fi
if [[ -f "$tilde_log_path" ]] && grep -q "target='NPM Cache'" "$tilde_log_path"; then
  echo -e "${GREEN}PASS: LINUX_CLEANER_LOG tilde path expanded and logged under mock HOME.${NC}"
else
  echo -e "${RED}FAIL: tilde log path was not created at '$tilde_log_path'.${NC}"
  cat "$TEST_ENV_DIR/log_tilde.log"
  exit 1
fi

# LINUX_CLEANER_QUIET env mirrors --quiet for cron wrappers.
echo -e "\n${BOLD}Test Case: LINUX_CLEANER_QUIET Env${NC}"
setup_mock_env
LINUX_CLEANER_QUIET=1 PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
  "$CLEANER_SH" --config "$TEST_ENV_DIR/test_cleaner.conf" --dry-run \
  < /dev/null > "$TEST_ENV_DIR/env_quiet.log" 2>&1 || true
if grep -q "Total potential space savings" "$TEST_ENV_DIR/env_quiet.log" \
   && ! grep -q '\[FOUND\]' "$TEST_ENV_DIR/env_quiet.log"; then
  echo -e "${GREEN}PASS: LINUX_CLEANER_QUIET enables quiet dry-run output.${NC}"
else
  echo -e "${RED}FAIL: LINUX_CLEANER_QUIET did not suppress status lines.${NC}"
  cat "$TEST_ENV_DIR/env_quiet.log"
  exit 1
fi

# LINUX_CLEANER_JSON env mirrors --json (dry-run only).
echo -e "\n${BOLD}Test Case: LINUX_CLEANER_JSON Env${NC}"
setup_mock_env
LINUX_CLEANER_JSON=1 PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
  "$CLEANER_SH" --config "$TEST_ENV_DIR/test_cleaner.conf" --dry-run \
  < /dev/null > "$TEST_ENV_DIR/env_json.log" 2>&1 || true
if python3 -m json.tool < "$TEST_ENV_DIR/env_json.log" > "$TEST_ENV_DIR/env_json_parsed.out" 2>"$TEST_ENV_DIR/env_json_parse.err"; then
  echo -e "${GREEN}PASS: LINUX_CLEANER_JSON enables JSON dry-run output.${NC}"
else
  echo -e "${RED}FAIL: LINUX_CLEANER_JSON did not emit valid JSON.${NC}"
  cat "$TEST_ENV_DIR/env_json_parse.err"
  cat "$TEST_ENV_DIR/env_json.log"
  exit 1
fi

# LINUX_CLEANER_ONLY_TARGET env mirrors --only-target for cron wrappers.
echo -e "\n${BOLD}Test Case: LINUX_CLEANER_ONLY_TARGET Env${NC}"
setup_mock_env
LINUX_CLEANER_ONLY_TARGET=NPM PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
  "$CLEANER_SH" --debug --config "$TEST_ENV_DIR/test_cleaner.conf" --dry-run \
  < /dev/null > "$TEST_ENV_DIR/env_only_target.log" 2>&1 || true
if grep -q "NPM Cache" "$TEST_ENV_DIR/env_only_target.log" \
   && ! grep -q "Gemini Temp" "$TEST_ENV_DIR/env_only_target.log"; then
  echo -e "${GREEN}PASS: LINUX_CLEANER_ONLY_TARGET filters to NPM Cache only.${NC}"
else
  echo -e "${RED}FAIL: LINUX_CLEANER_ONLY_TARGET did not filter targets.${NC}"
  cat "$TEST_ENV_DIR/env_only_target.log"
  exit 1
fi
# CLI --only-target overrides env when both are set.
LINUX_CLEANER_ONLY_TARGET=NPM PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
  "$CLEANER_SH" --debug --config "$TEST_ENV_DIR/test_cleaner.conf" --only-target Gemini --dry-run \
  < /dev/null > "$TEST_ENV_DIR/env_only_target_cli.log" 2>&1 || true
if grep -q "Gemini Temp" "$TEST_ENV_DIR/env_only_target_cli.log" \
   && ! grep -q "NPM Cache" "$TEST_ENV_DIR/env_only_target_cli.log"; then
  echo -e "${GREEN}PASS: --only-target overrides LINUX_CLEANER_ONLY_TARGET.${NC}"
else
  echo -e "${RED}FAIL: CLI --only-target did not override LINUX_CLEANER_ONLY_TARGET.${NC}"
  cat "$TEST_ENV_DIR/env_only_target_cli.log"
  exit 1
fi

# LINUX_CLEANER_RISK env mirrors --risk for cron wrappers.
echo -e "\n${BOLD}Test Case: LINUX_CLEANER_RISK Env${NC}"
setup_mock_env
LINUX_CLEANER_RISK=medium PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
  "$CLEANER_SH" --debug --config "$TEST_ENV_DIR/test_cleaner.conf" --dry-run \
  < /dev/null > "$TEST_ENV_DIR/env_risk.log" 2>&1 || true
if grep -q "Medium Risk Target" "$TEST_ENV_DIR/env_risk.log" \
   && ! grep -q "Danger Risk Target" "$TEST_ENV_DIR/env_risk.log"; then
  echo -e "${GREEN}PASS: LINUX_CLEANER_RISK=medium includes medium targets only.${NC}"
else
  echo -e "${RED}FAIL: LINUX_CLEANER_RISK did not set the risk ceiling.${NC}"
  cat "$TEST_ENV_DIR/env_risk.log"
  exit 1
fi
LINUX_CLEANER_RISK=medium PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
  "$CLEANER_SH" --debug --config "$TEST_ENV_DIR/test_cleaner.conf" --risk safe --dry-run \
  < /dev/null > "$TEST_ENV_DIR/env_risk_cli.log" 2>&1 || true
if grep -q "NPM Cache" "$TEST_ENV_DIR/env_risk_cli.log" \
   && ! grep -q "Medium Risk Target" "$TEST_ENV_DIR/env_risk_cli.log"; then
  echo -e "${GREEN}PASS: --risk overrides LINUX_CLEANER_RISK.${NC}"
else
  echo -e "${RED}FAIL: CLI --risk did not override LINUX_CLEANER_RISK.${NC}"
  cat "$TEST_ENV_DIR/env_risk_cli.log"
  exit 1
fi

# LINUX_CLEANER_TRASH env mirrors --trash for cron wrappers.
echo -e "\n${BOLD}Test Case: LINUX_CLEANER_TRASH Env${NC}"
setup_mock_env
LINUX_CLEANER_TRASH=1 PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
  "$CLEANER_SH" --config "$TEST_ENV_DIR/test_cleaner.conf" --dry-run \
  < /dev/null > "$TEST_ENV_DIR/env_trash.log" 2>&1 || true
if grep -q "Trash mode:.*ON" "$TEST_ENV_DIR/env_trash.log"; then
  echo -e "${GREEN}PASS: LINUX_CLEANER_TRASH enables trash/quarantine mode.${NC}"
else
  echo -e "${RED}FAIL: LINUX_CLEANER_TRASH did not enable trash mode.${NC}"
  cat "$TEST_ENV_DIR/env_trash.log"
  exit 1
fi

# NO_COLOR disables ANSI escapes for log-friendly cron output.
echo -e "\n${BOLD}Test Case: NO_COLOR Disables ANSI${NC}"
setup_mock_env
script -q -c "NO_COLOR=1 PATH=\"$TEST_ENV_DIR/bin:$PATH\" HOME=\"$MOCK_HOME\" \"$CLEANER_SH\" --config \"$TEST_ENV_DIR/test_cleaner.conf\" --dry-run" /dev/null \
  > "$TEST_ENV_DIR/no_color.log" 2>&1 || true
if grep -q $'\033' "$TEST_ENV_DIR/no_color.log"; then
  echo -e "${RED}FAIL: NO_COLOR=1 still emitted ANSI escape sequences.${NC}"
  cat "$TEST_ENV_DIR/no_color.log"
  exit 1
else
  echo -e "${GREEN}PASS: NO_COLOR suppresses ANSI color codes.${NC}"
fi

# LINUX_CLEANER_EXCLUDE env mirrors --exclude for cron wrappers.
echo -e "\n${BOLD}Test Case: LINUX_CLEANER_EXCLUDE Env${NC}"
setup_mock_env
echo "exclude this log" > "$MOCK_HOME/.npm/_cacache/excl1.log"
LINUX_CLEANER_EXCLUDE='*.log' PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
  "$CLEANER_SH" --config "$TEST_ENV_DIR/test_cleaner.conf" --force \
  < /dev/null > "$TEST_ENV_DIR/env_exclude.log" 2>&1 || true
if [[ ! -f "$MOCK_HOME/.npm/_cacache/cache1.txt" ]] \
   && [[ -f "$MOCK_HOME/.npm/_cacache/excl1.log" ]]; then
  echo -e "${GREEN}PASS: LINUX_CLEANER_EXCLUDE preserves matching files during clean.${NC}"
else
  echo -e "${RED}FAIL: LINUX_CLEANER_EXCLUDE did not apply exclusion patterns.${NC}"
  exit 1
fi

# LINUX_CLEANER_FORCE env mirrors --force for cron wrappers.
echo -e "\n${BOLD}Test Case: LINUX_CLEANER_FORCE Env${NC}"
setup_mock_env
LINUX_CLEANER_FORCE=1 PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
  "$CLEANER_SH" --config "$TEST_ENV_DIR/test_cleaner.conf" --only-target NPM \
  < /dev/null > "$TEST_ENV_DIR/env_force.log" 2>&1 || true
if [[ ! -f "$MOCK_HOME/.npm/_cacache/cache1.txt" ]]; then
  echo -e "${GREEN}PASS: LINUX_CLEANER_FORCE enables non-interactive clean.${NC}"
else
  echo -e "${RED}FAIL: LINUX_CLEANER_FORCE did not perform a real clean.${NC}"
  cat "$TEST_ENV_DIR/env_force.log"
  exit 1
fi

# LINUX_CLEANER_YES_DANGER env mirrors --yes-danger for unattended danger-tier cron.
echo -e "\n${BOLD}Test Case: LINUX_CLEANER_YES_DANGER Env${NC}"
setup_mock_env
LINUX_CLEANER_YES_DANGER=1 LINUX_CLEANER_FORCE=1 LINUX_CLEANER_RISK=danger PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
  "$CLEANER_SH" --config "$TEST_ENV_DIR/test_cleaner.conf" --only-target "Danger Risk" \
  < /dev/null > "$TEST_ENV_DIR/env_yes_danger.log" 2>&1 || true
if [[ ! -d "$MOCK_HOME/.cache/danger_test" ]]; then
  echo -e "${GREEN}PASS: LINUX_CLEANER_YES_DANGER enables danger-tier unattended clean.${NC}"
else
  echo -e "${RED}FAIL: LINUX_CLEANER_YES_DANGER did not clean danger target.${NC}"
  cat "$TEST_ENV_DIR/env_yes_danger.log"
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

# LINUX_CLEANER_CONFIG env selects config without -c; CLI -c still wins.
echo -e "\n${BOLD}Test Case: LINUX_CLEANER_CONFIG Env${NC}"
setup_mock_env
mkdir -p "$MOCK_HOME/.config/linux-cleaner"
# shellcheck disable=SC2016
printf 'safe|Env Config Target|$HOME/.cache/aurman|d|0||\n' > "$MOCK_HOME/.config/linux-cleaner/cleaner.conf"
LINUX_CLEANER_CONFIG="$TEST_ENV_DIR/test_cleaner.conf" \
  env -u XDG_CONFIG_HOME HOME="$MOCK_HOME" PATH="$TEST_ENV_DIR/bin:$PATH" \
  "$CLEANER_SH" --debug --dry-run < /dev/null > "$TEST_ENV_DIR/env_config.log" 2>&1 || true
if grep -q "Config file: $TEST_ENV_DIR/test_cleaner.conf" "$TEST_ENV_DIR/env_config.log" \
   && grep -q "NPM Cache" "$TEST_ENV_DIR/env_config.log" \
   && ! grep -q "Env Config Target" "$TEST_ENV_DIR/env_config.log"; then
  echo -e "${GREEN}PASS: LINUX_CLEANER_CONFIG selects the env config path without -c.${NC}"
else
  echo -e "${RED}FAIL: LINUX_CLEANER_CONFIG did not select the env config.${NC}"
  cat "$TEST_ENV_DIR/env_config.log"
  exit 1
fi
LINUX_CLEANER_CONFIG="$MOCK_HOME/.config/linux-cleaner/cleaner.conf" \
  env -u XDG_CONFIG_HOME HOME="$MOCK_HOME" PATH="$TEST_ENV_DIR/bin:$PATH" \
  "$CLEANER_SH" --debug --config "$TEST_ENV_DIR/test_cleaner.conf" --dry-run \
  < /dev/null > "$TEST_ENV_DIR/env_config_cli.log" 2>&1 || true
if grep -q "Config file: $TEST_ENV_DIR/test_cleaner.conf" "$TEST_ENV_DIR/env_config_cli.log" \
   && ! grep -q "Env Config Target" "$TEST_ENV_DIR/env_config_cli.log"; then
  echo -e "${GREEN}PASS: --config overrides LINUX_CLEANER_CONFIG.${NC}"
else
  echo -e "${RED}FAIL: --config did not override LINUX_CLEANER_CONFIG.${NC}"
  cat "$TEST_ENV_DIR/env_config_cli.log"
  exit 1
fi

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

# Man page documents every LINUX_CLEANER_* env var named in README.
echo -e "\n${BOLD}Test Case: Man Page Env Var Parity${NC}"
missing_env_vars=""
while IFS= read -r env_name; do
  [[ -z "$env_name" ]] && continue
  if ! grep -q "\\.B $env_name" "$SCRIPT_DIR/cleaner.1"; then
    missing_env_vars+=" $env_name"
  fi
done < <(grep -oE 'LINUX_CLEANER_[A-Z_]+' "$SCRIPT_DIR/README.md" | sort -u)
if [[ -z "$missing_env_vars" ]]; then
  echo -e "${GREEN}PASS: cleaner.1 documents every README LINUX_CLEANER_* env var.${NC}"
else
  echo -e "${RED}FAIL: README env vars missing from cleaner.1:$missing_env_vars${NC}"
  exit 1
fi

# 34. Test Case: CHANGELOG top released version matches --version, and so do the
# packaging manifests -- a partial bump would otherwise ship an AUR package whose
# pkgver disagrees with the installed script (RELEASING.md pre-release gate).
setup_mock_env
changelog_version=$(grep -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' "$SCRIPT_DIR/CHANGELOG.md" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
tool_version=$(HOME="$MOCK_HOME" PATH="$TEST_ENV_DIR/bin:$PATH" "$CLEANER_SH" --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
pkgbuild_version=$(awk -F= '/^pkgver=/ {print $2; exit}' "$SCRIPT_DIR/PKGBUILD")
srcinfo_version=$(awk -F' = ' '/^[[:space:]]*pkgver = / {print $2; exit}' "$SCRIPT_DIR/.SRCINFO")
echo -e "\n${BOLD}Test Case: Changelog/Version Consistency${NC}"
if [[ -n "$changelog_version" && "$changelog_version" == "$tool_version" ]]; then
  echo -e "${GREEN}PASS: CHANGELOG top version ($changelog_version) matches --version ($tool_version).${NC}"
else
  echo -e "${RED}FAIL: CHANGELOG version '$changelog_version' != --version '$tool_version'.${NC}"
  exit 1
fi
if [[ "$pkgbuild_version" == "$tool_version" && "$srcinfo_version" == "$tool_version" ]]; then
  echo -e "${GREEN}PASS: PKGBUILD and .SRCINFO pkgver both match --version ($tool_version).${NC}"
else
  echo -e "${RED}FAIL: packaging version mismatch — PKGBUILD='$pkgbuild_version' .SRCINFO='$srcinfo_version' --version='$tool_version'.${NC}"
  exit 1
fi
man_th_version=$(sed -n '1s/.*"linux-cleaner \([^"]*\)".*/\1/p' "$SCRIPT_DIR/cleaner.1")
if [[ "$man_th_version" == "$tool_version" ]]; then
  echo -e "${GREEN}PASS: cleaner.1 .TH version ($man_th_version) matches --version ($tool_version).${NC}"
else
  echo -e "${RED}FAIL: cleaner.1 .TH version '$man_th_version' != --version '$tool_version'.${NC}"
  exit 1
fi

# Count the '- ' entries stranded under CHANGELOG's [Unreleased] heading. A release cut
# while this is non-zero silently drops them: release.yml builds its notes by extracting
# only the tagged version's section, so anything still under [Unreleased] never ships.
unreleased_entry_count() {
  awk '/^## \[Unreleased\]/{f=1;next} f&&/^## \[/{exit} f&&/^- /{c++} END{print c+0}' "$1"
}

# 35. Test Case: version/tag/changelog three-way consistency + the release-notes guard
setup_mock_env
echo -e "\n${BOLD}Test Case: Version/Tag/Changelog Consistency${NC}"
git_tag=$(git -C "$SCRIPT_DIR" describe --tags --exact-match --match 'v[0-9]*' 2>/dev/null || true)
if [[ -z "$git_tag" ]]; then
  echo -e "${GREEN}PASS (not applicable): HEAD is not a v* release tag; the three-way check applies only on a tagged release.${NC}"
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
  # A tagged release must not leave entries stranded under [Unreleased] — they would
  # be silently dropped from the published notes, irreversibly.
  stranded=$(unreleased_entry_count "$SCRIPT_DIR/CHANGELOG.md")
  if [[ "$stranded" -eq 0 ]]; then
    echo -e "${GREEN}PASS: no entries stranded under [Unreleased] at tag $git_tag.${NC}"
  else
    echo -e "${RED}FAIL: tagging $git_tag would silently drop $stranded [Unreleased] entry(ies) from the release notes. Roll them into the ${tag_version} section first.${NC}"
    exit 1
  fi
fi

# The guard above only runs on a tagged HEAD — which is never, on an ordinary commit.
# So prove its assertion actually works on EVERY run, against fixtures. A check that
# has never executed is not a gate. (Fixtures only: no git repo is created, no tag is
# ever made, so this can never touch the real repository.)
echo -e "\n${BOLD}Test Case: Stranded [Unreleased] Entries Are Detected${NC}"
cat << 'EOF' > "$TEST_ENV_DIR/cl_stranded.md"
## [Unreleased]

### Added
- an entry that would be dropped
- and another

## [1.0.0] - 2020-01-01

### Added
- already shipped
EOF
cat << 'EOF' > "$TEST_ENV_DIR/cl_rolled.md"
## [Unreleased]

## [1.0.0] - 2020-01-01

### Added
- already shipped
EOF
stranded_n=$(unreleased_entry_count "$TEST_ENV_DIR/cl_stranded.md")
rolled_n=$(unreleased_entry_count "$TEST_ENV_DIR/cl_rolled.md")
if [[ "$stranded_n" -eq 2 && "$rolled_n" -eq 0 ]]; then
  echo -e "${GREEN}PASS: the release guard detects stranded [Unreleased] entries (2) and a rolled changelog (0).${NC}"
else
  echo -e "${RED}FAIL: the release guard miscounts (stranded=$stranded_n expected 2, rolled=$rolled_n expected 0).${NC}"
  exit 1
fi
# Belt and braces: this suite must never create a tag in the real repository.
if [[ -n "$(git -C "$SCRIPT_DIR" tag -l 'v9.9.*' 2>/dev/null)" ]]; then
  echo -e "${RED}FAIL: a test fixture leaked a v9.9.* tag into the real repository.${NC}"
  exit 1
fi

# 37. Test Case: apt/dnf/zypper actions invoke their exact commands (and no other manager)
setup_mock_env
cat << EOF > "$TEST_ENV_DIR/aptdnf_config.conf"
medium|APT Clean|$OUTSIDE_DIR|Mock APT cache|0||action:apt_clean
medium|DNF Clean|$OUTSIDE_DIR|Mock DNF cache|0||action:dnf_clean
medium|Zypper Clean|$OUTSIDE_DIR|Mock Zypper cache|0||action:zypper_clean
medium|APK Clean|$OUTSIDE_DIR|Mock APK cache|0||action:apk_clean
EOF
if run_test_case "Cross-Distro Actions" 0 "aptdnf.log" --config "$TEST_ENV_DIR/aptdnf_config.conf" --clean --force --risk medium; then
  if grep -q "Mock apt-get called with: clean" "$TEST_ENV_DIR/aptdnf.log" && \
     grep -q "Mock dnf called with: clean all" "$TEST_ENV_DIR/aptdnf.log" && \
     grep -q "Mock zypper called with: clean -a" "$TEST_ENV_DIR/aptdnf.log" && \
     grep -q "Mock apk called with: cache clean" "$TEST_ENV_DIR/aptdnf.log" && \
     ! grep -q "Mock pacman called" "$TEST_ENV_DIR/aptdnf.log" && \
     ! grep -q "Mock paccache called" "$TEST_ENV_DIR/aptdnf.log"; then
    echo -e "${GREEN}PASS: apt/dnf/zypper/apk actions ran their exact commands; no other manager was called.${NC}"
  else
    echo -e "${RED}FAIL: apt/dnf/zypper/apk actions did not invoke their exact commands.${NC}"
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
  if run_test_case "Cross-Distro Degradation" 0 "degrade.log" --config "$TEST_ENV_DIR/degrade_config.conf" --clean --force --risk medium; then
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

# Parallel absent-zypper degradation for action:zypper_clean.
setup_mock_env
rm -f "$TEST_ENV_DIR/bin/zypper"
echo -e "\n${BOLD}Test Case: Zypper Safe Degradation${NC}"
if command -v zypper >/dev/null 2>&1; then
  echo -e "${GREEN}PASS (skipped): a real zypper is installed on this host; cannot simulate its absence.${NC}"
else
  cat << EOF > "$TEST_ENV_DIR/zypper_degrade.conf"
medium|Zypper Clean|$OUTSIDE_DIR|Mock Zypper cache|0||action:zypper_clean
EOF
  if run_test_case "Zypper Degradation" 0 "zypper_degrade.log" --config "$TEST_ENV_DIR/zypper_degrade.conf" --clean --force --risk medium; then
    if grep -qi "not available on this platform" "$TEST_ENV_DIR/zypper_degrade.log" && \
       ! grep -q "command not found" "$TEST_ENV_DIR/zypper_degrade.log" && \
       ! grep -q "Mock zypper called" "$TEST_ENV_DIR/zypper_degrade.log"; then
      echo -e "${GREEN}PASS: zypper action skipped cleanly when zypper is absent (non-fatal, no command-not-found).${NC}"
    else
      echo -e "${RED}FAIL: zypper action did not degrade safely when zypper is absent.${NC}"
      cat "$TEST_ENV_DIR/zypper_degrade.log"
      exit 1
    fi
  else
    exit 1
  fi
fi

# Parallel absent-apk degradation for action:apk_clean.
setup_mock_env
rm -f "$TEST_ENV_DIR/bin/apk"
echo -e "\n${BOLD}Test Case: Apk Safe Degradation${NC}"
if command -v apk >/dev/null 2>&1; then
  echo -e "${GREEN}PASS (skipped): a real apk is installed on this host; cannot simulate its absence.${NC}"
else
  cat << EOF > "$TEST_ENV_DIR/apk_degrade.conf"
medium|APK Clean|$OUTSIDE_DIR|Mock APK cache|0||action:apk_clean
EOF
  if run_test_case "Apk Degradation" 0 "apk_degrade.log" --config "$TEST_ENV_DIR/apk_degrade.conf" --clean --force --risk medium; then
    if grep -qi "not available on this platform" "$TEST_ENV_DIR/apk_degrade.log" && \
       ! grep -q "command not found" "$TEST_ENV_DIR/apk_degrade.log" && \
       ! grep -q "Mock apk called" "$TEST_ENV_DIR/apk_degrade.log"; then
      echo -e "${GREEN}PASS: apk action skipped cleanly when apk is absent (non-fatal, no command-not-found).${NC}"
    else
      echo -e "${RED}FAIL: apk action did not degrade safely when apk is absent.${NC}"
      cat "$TEST_ENV_DIR/apk_degrade.log"
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
if run_test_case "Pacman Clean Action" 0 "pacman_clean.log" --config "$TEST_ENV_DIR/pacman_clean_config.conf" --clean --force --risk medium; then
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
trash_action_qbase="$MOCK_HOME/.cache/linux-cleaner/quarantine"
trash_action_prior="$trash_action_qbase/2020-01-01_00-00-00"
trash_action_restore="$MOCK_HOME/.cache/restored_action_prior"
mkdir -p "$trash_action_prior/0_Action_Prior"
echo "prior payload" > "$trash_action_prior/0_Action_Prior/payload"
printf 'full|0_Action_Prior|%s|false|%s|%s\n' \
  "$trash_action_restore" "$(id -u)" "$(id -g)" > "$trash_action_prior/quarantine.meta"
cat << EOF > "$TEST_ENV_DIR/trash_action_config.conf"
medium|Paccache Trash|$OUTSIDE_DIR|Mock paccache under trash|0||action:paccache_keep1
EOF
if run_test_case "Trash Action Warning" 0 "trash_action.log" --config "$TEST_ENV_DIR/trash_action_config.conf" --trash --force --risk medium; then
  trash_action_session_count=$(find "$trash_action_qbase" -mindepth 1 -maxdepth 1 -type d | wc -l)
  if grep -q "bypass quarantine and run directly (irreversible deletion)" "$TEST_ENV_DIR/trash_action.log" \
     && grep -q "Mock paccache called with: -rk1" "$TEST_ENV_DIR/trash_action.log" \
     && grep -q "Total space quarantined: 0 B; permanently reclaimed by actions:" "$TEST_ENV_DIR/trash_action.log" \
     && ! grep -q "permanently reclaimed by actions: 0 B" "$TEST_ENV_DIR/trash_action.log" \
     && [[ "$trash_action_session_count" -eq 1 ]] \
     && [[ -d "$trash_action_prior" ]]; then
    echo -e "${GREEN}PASS: trash-mode predefined action used the mock, warned, reported irreversible bytes, and created no empty session.${NC}"
  else
    echo -e "${RED}FAIL: trash-mode action did not use the mock, warn, or preserve the sole prior session.${NC}"
    cat "$TEST_ENV_DIR/trash_action.log"
    exit 1
  fi
else
  exit 1
fi

if run_test_case "Restore Prior Session After Trash Action" 0 "trash_action_restore.log" --restore latest \
   && grep -qx "prior payload" "$trash_action_restore/payload" \
   && [[ ! -d "$trash_action_prior" ]]; then
  echo -e "${GREEN}PASS: action-only trash run left the prior latest session restorable.${NC}"
else
  echo -e "${RED}FAIL: action-only trash run hid the prior restorable session.${NC}"
  cat "$TEST_ENV_DIR/trash_action_restore.log"
  exit 1
fi

setup_mock_env
mixed_trash_target="$MOCK_HOME/.cache/mixed_trash_target"
mkdir -p "$mixed_trash_target"
echo quarantined > "$mixed_trash_target/payload"
cat << EOF > "$TEST_ENV_DIR/mixed_trash_action.conf"
medium|Paccache Mixed|$OUTSIDE_DIR|Mock paccache under trash|0||action:paccache_keep1
safe|Mixed Quarantine|$mixed_trash_target|Mock path quarantine|0||
EOF
if run_test_case "Mixed Trash and Action Summary" 0 "mixed_trash_action.log" \
     --config "$TEST_ENV_DIR/mixed_trash_action.conf" --trash --force --risk medium; then
  mixed_quarantined=$(find "$MOCK_HOME/.cache/linux-cleaner/quarantine" -name payload -print -quit)
  if [[ ! -e "$mixed_trash_target" && -n "$mixed_quarantined" ]] \
     && grep -q "Total space quarantined:" "$TEST_ENV_DIR/mixed_trash_action.log" \
     && grep -q "; permanently reclaimed by actions:" "$TEST_ENV_DIR/mixed_trash_action.log" \
     && ! grep -q "Total space quarantined: 0 B" "$TEST_ENV_DIR/mixed_trash_action.log" \
     && ! grep -q "permanently reclaimed by actions: 0 B" "$TEST_ENV_DIR/mixed_trash_action.log"; then
    echo -e "${GREEN}PASS: mixed trash/action summary reports both nonzero amounts separately.${NC}"
  else
    echo -e "${RED}FAIL: mixed trash/action summary combined or omitted one amount.${NC}"
    cat "$TEST_ENV_DIR/mixed_trash_action.log"
    exit 1
  fi
else
  exit 1
fi

# 41. Test Case: GNU-userland guard (transparent on GNU, refuses on non-GNU)
setup_mock_env
# (a) On this GNU host, a normal --force clean succeeds with no refusal
if run_test_case "GNU Guard Transparent" 0 "gnu_transparent.log" --config "$TEST_ENV_DIR/test_cleaner.conf" --force; then
  if ! grep -q "GNU coreutils are required" "$TEST_ENV_DIR/gnu_transparent.log"; then
    echo -e "${GREEN}PASS: GNU-userland guard is transparent on a GNU host.${NC}"
  else
    echo -e "${RED}FAIL: GNU guard refused on a GNU host.${NC}"
    cat "$TEST_ENV_DIR/gnu_transparent.log"
    exit 1
  fi
else
  exit 1
fi
# (b) Shadow stat with a -c-rejecting stub -> --force must refuse and delete nothing
setup_mock_env
# shellcheck disable=SC2016  # literal $1/$@ are the stub's own positionals
printf '#!/bin/sh\ncase "$1" in -c) exit 1;; esac; exec /usr/bin/stat "$@"\n' > "$TEST_ENV_DIR/bin/stat"
chmod +x "$TEST_ENV_DIR/bin/stat"
if run_test_case "GNU Guard Refuses" 1 "gnu_refuse.log" --config "$TEST_ENV_DIR/test_cleaner.conf" --force; then
  if grep -q "GNU coreutils are required" "$TEST_ENV_DIR/gnu_refuse.log" && \
     [[ -f "$MOCK_HOME/.npm/_cacache/cache1.txt" ]]; then
    echo -e "${GREEN}PASS: GNU guard refused --force on a non-GNU userland; nothing was deleted.${NC}"
  else
    echo -e "${RED}FAIL: GNU guard did not refuse or deleted files on a non-GNU userland.${NC}"
    cat "$TEST_ENV_DIR/gnu_refuse.log"
    exit 1
  fi
else
  echo -e "${RED}FAIL: non-GNU --force did not exit 1.${NC}"
  exit 1
fi

# 42. Test Case: action_required_binary maps each action to the binary its arm invokes
setup_mock_env
arb_fn=$(awk '/^action_required_binary\(\) \{/,/^\}/' "$CLEANER_SH")
arb_script="$TEST_ENV_DIR/arb_probe.sh"
# shellcheck disable=SC2016  # literal $1 is intentional: the probe script's own positional
{ echo "$arb_fn"; echo 'action_required_binary "$1"'; } > "$arb_script"
arb() { bash "$arb_script" "$1"; }
echo -e "\n${BOLD}Test Case: Action Required Binary Mapping${NC}"
arb_ok=true
[[ "$(arb action:paccache_keep1)" == "paccache" ]] || arb_ok=false
[[ "$(arb action:paccache_keep3)" == "paccache" ]] || arb_ok=false
[[ "$(arb action:pacman_clean)" == "pacman" ]] || arb_ok=false
[[ "$(arb action:apt_clean)" == "apt-get" ]] || arb_ok=false
[[ "$(arb action:dnf_clean)" == "dnf" ]] || arb_ok=false
[[ "$(arb action:zypper_clean)" == "zypper" ]] || arb_ok=false
[[ "$(arb action:apk_clean)" == "apk" ]] || arb_ok=false
[[ "$(arb action:uv_cache_prune)" == "uv" ]] || arb_ok=false
[[ "$(arb action:pnpm_store_prune)" == "pnpm" ]] || arb_ok=false
[[ "$(arb action:hf_cache_prune)" == "hf" ]] || arb_ok=false
[[ -z "$(arb action:bogus)" ]] || arb_ok=false
if [[ "$arb_ok" == true ]]; then
  echo -e "${GREEN}PASS: paccache actions require 'paccache' (not 'pacman'); apt/dnf/zypper/apk map to their real binaries.${NC}"
else
  echo -e "${RED}FAIL: action_required_binary returned an unexpected binary.${NC}"
  exit 1
fi

# 43. Test Case: opt-in log refuses a symlinked leaf that escapes $HOME
setup_mock_env
ext_target="$OUTSIDE_DIR/exfil.log"
ln -s "$ext_target" "$MOCK_HOME/planted.log"   # the log leaf is a symlink pointing outside HOME
cat << EOF > "$TEST_ENV_DIR/log_symlink_config.conf"
safe|NPM Cache|\$HOME/.npm/_cacache|Mock NPM cache|0||
EOF
if run_test_case "Log Symlink Leaf Refused" 0 "log_symlink.log" --config "$TEST_ENV_DIR/log_symlink_config.conf" --force --log "$MOCK_HOME/planted.log"; then
  if grep -qi "Refusing to write log outside" "$TEST_ENV_DIR/log_symlink.log" && [[ ! -f "$ext_target" ]]; then
    echo -e "${GREEN}PASS: opt-in log refused a symlinked leaf escaping HOME; nothing written outside HOME.${NC}"
  else
    echo -e "${RED}FAIL: opt-in log followed a symlinked leaf outside HOME.${NC}"
    cat "$TEST_ENV_DIR/log_symlink.log"
    exit 1
  fi
else
  exit 1
fi

# 44. Test Case: $HOME/$USER expand only as whole tokens (no substring over-expansion)
setup_mock_env
cat << EOF > "$TEST_ENV_DIR/token_expand.conf"
safe|Prefixed HOME Token|\$HOMEDATA/x|Must stay literal, not \$HOME-expanded|0||
safe|Real HOME Target|\$HOME/.cache/aurman|Real target that must still expand|0||
EOF
if run_test_case "Whole-Token HOME/USER Expansion" 0 "token_expand.log" --debug --config "$TEST_ENV_DIR/token_expand.conf" --dry-run; then
  # The prefixed token must be left literal ('$HOMEDATA' present verbatim) and
  # must NOT be over-expanded to <mock_home>DATA.
  # shellcheck disable=SC2016  # literal $HOMEDATA is intentional; it must NOT expand
  if grep -qF '$HOMEDATA' "$TEST_ENV_DIR/token_expand.log" \
     && ! grep -qF "${MOCK_HOME}DATA" "$TEST_ENV_DIR/token_expand.log"; then
    echo -e "${GREEN}PASS: \$HOMEDATA left literal; only whole \$HOME/\$USER tokens expand.${NC}"
  else
    echo -e "${RED}FAIL: \$HOME substring was over-expanded inside \$HOMEDATA.${NC}"
    cat "$TEST_ENV_DIR/token_expand.log"
    exit 1
  fi
else
  exit 1
fi

# 45. Test Case: --interactive per-target confirmation (y cleans, n skips)
setup_mock_env
cat << EOF > "$TEST_ENV_DIR/interactive.conf"
safe|Interactive Clean|\$HOME/.npm/_cacache|First target: answer yes|0||
safe|Interactive Skip|\$HOME/.cache/aurman|Second target: answer no|0||
EOF
echo -e "\n${BOLD}Test Case: Interactive Per-Target Confirmation${NC}"
inter_log="$TEST_ENV_DIR/interactive.log"
inter_ec=0
# Feed 'y' to the first per-target prompt and 'n' to the second (stdin, not /dev/null).
printf 'y\nn\n' | PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" "$CLEANER_SH" \
  --config "$TEST_ENV_DIR/interactive.conf" --interactive > "$inter_log" 2>&1 || inter_ec=$?
if [[ $inter_ec -eq 0 ]] \
   && [[ ! -e "$MOCK_HOME/.npm/_cacache" ]] \
   && [[ -f "$MOCK_HOME/.cache/aurman/pkg1.tar.zst" ]] \
   && grep -qi "Skipping" "$inter_log" \
   && grep -q '^Result: cleaned=1 skipped=1 failed=0 ' "$inter_log"; then
  echo -e "${GREEN}PASS: --interactive cleaned the y-confirmed target and counted the n-declined one once as skipped.${NC}"
else
  echo -e "${RED}FAIL: --interactive per-target confirmation did not behave as expected (ec=$inter_ec).${NC}"
  cat "$inter_log"
  exit 1
fi

# 46. Test Case: restore tolerates a failing sudo chown (does not abort mid-loop)
setup_mock_env
qroot="$MOCK_HOME/.cache/linux-cleaner/quarantine"
qsession="$qroot/2020-01-01_00-00-00"
mkdir -p "$qsession"
echo "restored payload" > "$qsession/0_RootOwned"
# Record a full item as sudo-owned uid/gid 0; under the mock sudo, 'chown 0:0'
# fails with EPERM (running as a normal user), exercising the chown-failure path.
printf 'full|0_RootOwned|%s/.cache/restored_root|true|0|0\n' "$MOCK_HOME" > "$qsession/quarantine.meta"
if run_test_case "Restore Tolerates Chown Failure" 0 "restore_chown.log" --restore 2020-01-01_00-00-00; then
  if [[ -f "$MOCK_HOME/.cache/restored_root" ]]; then
    echo -e "${GREEN}PASS: restore completed despite a failing sudo chown; file was restored.${NC}"
  else
    echo -e "${RED}FAIL: restore did not place the file (chown-failure path aborted the restore).${NC}"
    cat "$TEST_ENV_DIR/restore_chown.log"
    exit 1
  fi
else
  exit 1
fi

# 47. Test Case: an unset USER/HOME cannot collapse a target path to CWD
setup_mock_env
echo -e "\n${BOLD}Test Case: Unset USER/HOME Robustness${NC}"
robust_conf="$TEST_ENV_DIR/robust.conf"
# A non-existent target so the resolved path is printed verbatim ("...does not
# exist."), letting us assert it stayed under HOME instead of collapsing to CWD.
# shellcheck disable=SC2016  # literal $HOME is intentional: the cleaner expands it, not the shell
printf 'safe|Robust Probe|$HOME/.cache/robust_probe_xyz|USER-unset resolution guard|0||\n' > "$robust_conf"
# (a) USER unset: expand_path_safe must not abort on an unbound $USER deref and
#     silently return "" (which canonicalize_physical would turn into $PWD).
robust_log="$TEST_ENV_DIR/robust_user.log"
robust_ec=0
env -u USER HOME="$MOCK_HOME" XDG_CONFIG_HOME="$TEST_ENV_DIR/nope" PATH="$TEST_ENV_DIR/bin:$PATH" \
  "$CLEANER_SH" --config "$robust_conf" --debug --dry-run < /dev/null > "$robust_log" 2>&1 || robust_ec=$?
if [[ $robust_ec -eq 0 ]] \
   && ! grep -qi "unbound variable" "$robust_log" \
   && grep -q "$MOCK_HOME/.cache/robust_probe_xyz" "$robust_log"; then
  echo -e "${GREEN}PASS: unset USER kept the target under HOME (no CWD collapse).${NC}"
else
  echo -e "${RED}FAIL: unset USER broke path resolution (ec=$robust_ec).${NC}"
  cat "$robust_log"
  exit 1
fi
# (b) HOME unset: HOME is the safety boundary, so the tool must refuse to run with
#     a clear error and a non-zero exit rather than crash cryptically.
home_log="$TEST_ENV_DIR/robust_home.log"
home_ec=0
env -u HOME PATH="$TEST_ENV_DIR/bin:$PATH" \
  "$CLEANER_SH" --config "$robust_conf" --dry-run < /dev/null > "$home_log" 2>&1 || home_ec=$?
if [[ $home_ec -ne 0 ]] && grep -qi "HOME is not set" "$home_log"; then
  echo -e "${GREEN}PASS: unset HOME is refused with a clear error and non-zero exit.${NC}"
else
  echo -e "${RED}FAIL: unset HOME was not refused cleanly (ec=$home_ec).${NC}"
  cat "$home_log"
  exit 1
fi

# 48. Test Case: a failed quarantine move must not be recorded in quarantine.meta
# (a record for a file that never moved made every later --restore of that
# session exit 1 on a missing source, and kept the session forever).
setup_mock_env
mkdir -p "$MOCK_HOME/.cache/qfail_test" "$MOCK_HOME/.cache/qfail_aged/sub" "$MOCK_HOME/.cache/qok_test"
echo "unmovable" > "$MOCK_HOME/.cache/qfail_test/data.txt"
echo "unmovable aged" > "$MOCK_HOME/.cache/qfail_aged/sub/data.txt"
touch -d "10 days ago" "$MOCK_HOME/.cache/qfail_aged/sub/data.txt"
echo "movable" > "$MOCK_HOME/.cache/qok_test/data.txt"
cat << 'EOF' > "$TEST_ENV_DIR/qfail.conf"
safe|Qfail Target|$HOME/.cache/qfail_test|Target whose quarantine move fails|0||
safe|Qfail Aged|$HOME/.cache/qfail_aged|Aged target whose quarantine move fails|5||
safe|Qok Target|$HOME/.cache/qok_test|Target that quarantines cleanly|0||
EOF
# Stub mv so only the qfail_test and qfail_aged moves fail; every other mv passes through.
cat << 'EOF' > "$TEST_ENV_DIR/bin/mv"
#!/usr/bin/env bash
case "$1" in
  *qfail_test*|*qfail_aged*) exit 1 ;;
esac
real_mv=$(PATH="${PATH#"$TEST_ENV_DIR/bin:"}" command -v mv)
exec "$real_mv" "$@"
EOF
chmod +x "$TEST_ENV_DIR/bin/mv"
# Exit 1: a failed move is a failed operation (cleaner.1 EXIT STATUS contract).
if run_test_case "Failed Quarantine Move Not Recorded" 1 "qfail.log" \
     --config "$TEST_ENV_DIR/qfail.conf" --trash --force; then
  rm -f "$TEST_ENV_DIR/bin/mv"
  qmeta=$(find "$MOCK_HOME/.cache/linux-cleaner/quarantine" -name quarantine.meta -print -quit 2>/dev/null)
  if [[ -f "$qmeta" ]] \
     && ! grep -q "qfail_test" "$qmeta" \
     && ! grep -q "qfail_aged" "$qmeta" \
     && grep -q "qok_test" "$qmeta" \
     && [[ -f "$MOCK_HOME/.cache/qfail_test/data.txt" ]] \
     && [[ -f "$MOCK_HOME/.cache/qfail_aged/sub/data.txt" ]]; then
    echo -e "${GREEN}PASS: the failed full and aged moves left no quarantine.meta records and the files stayed in place.${NC}"
  else
    echo -e "${RED}FAIL: a failed quarantine move was still recorded in quarantine.meta.${NC}"
    cat "$qmeta" 2>/dev/null
    cat "$TEST_ENV_DIR/qfail.log"
    exit 1
  fi
  if run_test_case "Restore After a Failed Quarantine Move" 0 "qfail_restore.log" --restore latest; then
    if [[ -f "$MOCK_HOME/.cache/qok_test/data.txt" ]]; then
      echo -e "${GREEN}PASS: restore succeeded, retired the session, and returned the file that did reach quarantine.${NC}"
    else
      echo -e "${RED}FAIL: restore did not return the quarantined file.${NC}"
      cat "$TEST_ENV_DIR/qfail_restore.log"
      exit 1
    fi
  else
    exit 1
  fi
else
  rm -f "$TEST_ENV_DIR/bin/mv"
  exit 1
fi

# A move can succeed immediately before its quarantine.meta append fails. The
# cleanup must report that failure, and restoring a recorded sibling must not
# retire the session around the resulting unrecorded payload.
setup_mock_env
qmeta_recorded="$MOCK_HOME/.cache/qmeta_recorded"
qmeta_unrecorded="$MOCK_HOME/.cache/qmeta_unrecorded"
mkdir -p "$qmeta_recorded" "$qmeta_unrecorded"
echo "recorded payload" > "$qmeta_recorded/data.txt"
echo "unrecorded payload" > "$qmeta_unrecorded/data.txt"
cat << 'EOF' > "$TEST_ENV_DIR/qmeta_fail.conf"
safe|Recorded Sibling|$HOME/.cache/qmeta_recorded|Target recorded before metadata failure|0||
safe|Unrecorded Empty|$HOME/.cache/qmeta_unrecorded|Empty target whose metadata append fails|0||
EOF
# Pass both moves through, but make metadata unwritable only after the second
# target has moved. Permissions are restored before the restore probe.
cat << 'EOF' > "$TEST_ENV_DIR/bin/mv"
#!/usr/bin/env bash
real_mv=$(PATH="${PATH#"$TEST_ENV_DIR/bin:"}" command -v mv)
if ! "$real_mv" "$@"; then
  exit 1
fi
case "${1:-}" in
  *qmeta_unrecorded*) chmod u-w "$(dirname "$2")/quarantine.meta" ;;
esac
EOF
chmod +x "$TEST_ENV_DIR/bin/mv"

qmeta_failure_reported=true
if ! run_test_case "Quarantine Metadata Write Failure" 1 "qmeta_fail.log" \
     --config "$TEST_ENV_DIR/qmeta_fail.conf" --trash --force; then
  qmeta_failure_reported=false
fi
rm -f "$TEST_ENV_DIR/bin/mv"
qmeta_file=$(find "$MOCK_HOME/.cache/linux-cleaner/quarantine" -name quarantine.meta -print -quit 2>/dev/null)
qmeta_session=$(dirname "$qmeta_file")
chmod u+w "$qmeta_file"
cp "$qmeta_file" "$TEST_ENV_DIR/qmeta.before"

qmeta_failure_state=true
if [[ ! -f "$qmeta_file" ]] \
   || ! grep -qF "|$qmeta_recorded|" "$qmeta_file" \
   || grep -qF "|$qmeta_unrecorded|" "$qmeta_file" \
   || [[ ! -f "$qmeta_session/1_Unrecorded_Empty/data.txt" ]] \
   || [[ -e "$qmeta_unrecorded" ]] \
   || ! grep -q "Failed to move some files" "$TEST_ENV_DIR/qmeta_fail.log"; then
  qmeta_failure_state=false
fi

# Exercise both shell-glob blind spots explicitly: an empty unrecorded target
# from the failed append and a hidden unrecorded entry in the same session.
mv "$qmeta_session/1_Unrecorded_Empty/data.txt" "$qmeta_session/.hidden-unrecorded"
qmeta_restore_refused=true
if ! run_test_case "Restore Preserves Unrecorded Quarantine Payload" 1 "qmeta_restore.log" \
     --restore latest; then
  qmeta_restore_refused=false
fi

if [[ "$qmeta_failure_reported" == true && "$qmeta_failure_state" == true \
      && "$qmeta_restore_refused" == true ]] \
   && [[ -f "$qmeta_recorded/data.txt" ]] \
   && grep -qx "recorded payload" "$qmeta_recorded/data.txt" \
   && [[ -d "$qmeta_session/1_Unrecorded_Empty" ]] \
   && [[ -f "$qmeta_session/.hidden-unrecorded" ]] \
   && grep -qx "unrecorded payload" "$qmeta_session/.hidden-unrecorded" \
   && cmp -s "$TEST_ENV_DIR/qmeta.before" "$qmeta_file" \
   && grep -qi "unrecorded quarantine payload" "$TEST_ENV_DIR/qmeta_restore.log" \
   && ! grep -q "Restoration complete" "$TEST_ENV_DIR/qmeta_restore.log"; then
  echo -e "${GREEN}PASS: metadata write failure was reported and unrecorded payload blocked session retirement.${NC}"
else
  echo -e "${RED}FAIL: metadata failure or restore retirement lost its quarantine recovery invariant.${NC}"
  cat "$TEST_ENV_DIR/qmeta_fail.log"
  cat "$TEST_ENV_DIR/qmeta_restore.log"
  exit 1
fi

# 49. Test Case: both installers ship the same tree under DESTDIR, and uninstall
# removes what it shipped while preserving the system config. install.sh and the
# Makefile duplicate the layout independently, so nothing else catches them drifting.
setup_mock_env
echo -e "\n${BOLD}Test Case: Installer DESTDIR Smoke Test${NC}"
destroot="$TEST_ENV_DIR/destroot"
if ! DESTDIR="$destroot" PREFIX=/usr sh "$SCRIPT_DIR/install.sh" install \
     > "$TEST_ENV_DIR/install_sh.log" 2>&1; then
  echo -e "${RED}FAIL: install.sh install exited non-zero.${NC}"
  cat "$TEST_ENV_DIR/install_sh.log"
  exit 1
fi
install_ok=true
for asset in "usr/bin/cleaner" \
             "etc/linux-cleaner/cleaner.conf" \
             "usr/share/man/man1/cleaner.1" \
             "usr/share/licenses/linux-cleaner/LICENSE"; do
  if [[ ! -f "$destroot/$asset" ]]; then
    echo -e "${RED}FAIL: install.sh did not ship '$asset'.${NC}"
    install_ok=false
  fi
done
if [[ "$(stat -c '%a' "$destroot/usr/bin/cleaner" 2>/dev/null)" != "755" ]]; then
  echo -e "${RED}FAIL: the installed cleaner binary is not mode 0755.${NC}"
  install_ok=false
fi
if [[ "$install_ok" != true ]]; then
  exit 1
fi
echo -e "${GREEN}PASS: install.sh shipped all four assets under DESTDIR with a 0755 binary.${NC}"

# Re-installing over an existing config must preserve it and ship .example instead.
DESTDIR="$destroot" PREFIX=/usr sh "$SCRIPT_DIR/install.sh" install \
  > "$TEST_ENV_DIR/install_sh2.log" 2>&1
if [[ -f "$destroot/etc/linux-cleaner/cleaner.conf.example" ]]; then
  echo -e "${GREEN}PASS: re-install preserved the existing config and shipped cleaner.conf.example.${NC}"
else
  echo -e "${RED}FAIL: re-install did not take the existing-config branch.${NC}"
  cat "$TEST_ENV_DIR/install_sh2.log"
  exit 1
fi

DESTDIR="$destroot" PREFIX=/usr sh "$SCRIPT_DIR/install.sh" uninstall \
  > "$TEST_ENV_DIR/uninstall_sh.log" 2>&1
if [[ ! -e "$destroot/usr/bin/cleaner" ]] \
   && [[ ! -e "$destroot/usr/share/man/man1/cleaner.1" ]] \
   && [[ ! -e "$destroot/usr/share/licenses/linux-cleaner/LICENSE" ]] \
   && [[ -f "$destroot/etc/linux-cleaner/cleaner.conf" ]]; then
  echo -e "${GREEN}PASS: uninstall removed the binary, man page, and license but kept the config.${NC}"
else
  echo -e "${RED}FAIL: uninstall did not clean up correctly (or removed the system config).${NC}"
  cat "$TEST_ENV_DIR/uninstall_sh.log"
  exit 1
fi

if grep -q -- '--trash' "$SCRIPT_DIR/examples/systemd/linux-cleaner-clean.service"; then
  echo -e "${RED}FAIL: examples/systemd/linux-cleaner-clean.service passes --trash.${NC}"
  exit 1
fi
echo -e "${GREEN}PASS: examples/systemd/linux-cleaner-clean.service does not pass --trash.${NC}"

if command -v make > /dev/null 2>&1; then
  freshroot="$TEST_ENV_DIR/freshroot"
  makeroot="$TEST_ENV_DIR/makeroot"
  DESTDIR="$freshroot" PREFIX=/usr sh "$SCRIPT_DIR/install.sh" install > /dev/null 2>&1
  make -C "$SCRIPT_DIR" install DESTDIR="$makeroot" PREFIX=/usr \
    > "$TEST_ENV_DIR/make_install.log" 2>&1
  if diff <(cd "$freshroot" && find . -type f | sort) \
          <(cd "$makeroot" && find . -type f | sort) > "$TEST_ENV_DIR/drift.log" 2>&1; then
    echo -e "${GREEN}PASS: make install and install.sh ship an identical file tree.${NC}"
  else
    echo -e "${RED}FAIL: install.sh and the Makefile install target have drifted.${NC}"
    cat "$TEST_ENV_DIR/drift.log"
    exit 1
  fi
  units_ok=true
  for unit in linux-cleaner-clean.service linux-cleaner-clean.timer \
              linux-cleaner-retention.service linux-cleaner-retention.timer \
              linux-cleaner-monitor.service linux-cleaner-monitor.timer; do
    unit_path="$makeroot/usr/lib/systemd/user/$unit"
    if [[ ! -f "$unit_path" ]] || [[ "$(stat -c '%a' "$unit_path" 2>/dev/null)" != "644" ]]; then
      echo -e "${RED}FAIL: make install did not ship '$unit' mode 644.${NC}"
      units_ok=false
    fi
  done
  if [[ "$units_ok" != true ]]; then
    exit 1
  fi
  echo -e "${GREEN}PASS: make install shipped six systemd user units mode 644.${NC}"
  unmakeroot="$TEST_ENV_DIR/unmakeroot"
  make -C "$SCRIPT_DIR" install DESTDIR="$unmakeroot" PREFIX=/usr \
    > "$TEST_ENV_DIR/make_install_for_uninstall.log" 2>&1
  make -C "$SCRIPT_DIR" uninstall DESTDIR="$unmakeroot" PREFIX=/usr \
    > "$TEST_ENV_DIR/make_uninstall.log" 2>&1
  units_removed=true
  for unit in linux-cleaner-clean.service linux-cleaner-clean.timer \
              linux-cleaner-retention.service linux-cleaner-retention.timer \
              linux-cleaner-monitor.service linux-cleaner-monitor.timer; do
    if [[ -e "$unmakeroot/usr/lib/systemd/user/$unit" ]]; then
      units_removed=false
    fi
  done
  if [[ ! -e "$unmakeroot/usr/bin/cleaner" ]] \
     && [[ ! -e "$unmakeroot/usr/share/man/man1/cleaner.1" ]] \
     && [[ ! -e "$unmakeroot/usr/share/licenses/linux-cleaner/LICENSE" ]] \
     && [[ -f "$unmakeroot/etc/linux-cleaner/cleaner.conf" ]] \
     && [[ "$units_removed" == true ]]; then
    echo -e "${GREEN}PASS: make uninstall removed the binary, man page, license, and systemd user units but kept the config.${NC}"
  else
    echo -e "${RED}FAIL: make uninstall did not clean up correctly (or removed the system config).${NC}"
    cat "$TEST_ENV_DIR/make_uninstall.log"
    exit 1
  fi
else
  echo -e "${GREEN}PASS (skipped): make is not installed; cannot cross-check the Makefile tree.${NC}"
fi

# install.sh --help must print usage and exit cleanly (cold-frontier CLI path).
echo -e "\n${BOLD}Test Case: install.sh --help${NC}"
install_help_ec=0
sh "$SCRIPT_DIR/install.sh" --help > "$TEST_ENV_DIR/install_help.log" 2>&1 || install_help_ec=$?
if [[ $install_help_ec -eq 0 ]] \
   && grep -q "Usage:" "$TEST_ENV_DIR/install_help.log" \
   && grep -qE 'install\|uninstall' "$TEST_ENV_DIR/install_help.log"; then
  echo -e "${GREEN}PASS: install.sh --help prints usage and exits 0.${NC}"
else
  echo -e "${RED}FAIL: install.sh --help did not print expected usage (ec=$install_help_ec).${NC}"
  cat "$TEST_ENV_DIR/install_help.log"
  exit 1
fi

# Unknown subcommands must fail after printing usage.
echo -e "\n${BOLD}Test Case: install.sh unknown subcommand${NC}"
install_bad_ec=0
sh "$SCRIPT_DIR/install.sh" not-a-command > "$TEST_ENV_DIR/install_bad.log" 2>&1 || install_bad_ec=$?
if [[ $install_bad_ec -ne 0 ]] && grep -q "Usage:" "$TEST_ENV_DIR/install_bad.log"; then
  echo -e "${GREEN}PASS: install.sh rejects unknown subcommands with usage and exit 1.${NC}"
else
  echo -e "${RED}FAIL: install.sh accepted or silently ignored an unknown subcommand (ec=$install_bad_ec).${NC}"
  cat "$TEST_ENV_DIR/install_bad.log"
  exit 1
fi

# 50. Test Case: a failed permanent delete must exit non-zero (cleaner.1 EXIT
# STATUS: "non-zero on ... a failed operation"), while a clean run still exits 0,
# so an unattended cron run can detect a cleanup that did not happen.
setup_mock_env
mkdir -p "$MOCK_HOME/.cache/rmfail_test"
echo "undeletable" > "$MOCK_HOME/.cache/rmfail_test/data.txt"
cat << 'EOF' > "$TEST_ENV_DIR/rmfail.conf"
safe|Rmfail Target|$HOME/.cache/rmfail_test|Target whose delete fails|0||
EOF
cat << 'EOF' > "$TEST_ENV_DIR/bin/rm"
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    *rmfail_test*) exit 1 ;;
  esac
done
real_rm=$(PATH="${PATH#"$TEST_ENV_DIR/bin:"}" command -v rm)
exec "$real_rm" "$@"
EOF
chmod +x "$TEST_ENV_DIR/bin/rm"
if run_test_case "Failed Delete Exits Non-Zero" 1 "rmfail.log" \
     --config "$TEST_ENV_DIR/rmfail.conf" --clean --force; then
  rm -f "$TEST_ENV_DIR/bin/rm"
  if grep -q "Failed to delete" "$TEST_ENV_DIR/rmfail.log" \
     && grep -q "One or more targets failed to clean" "$TEST_ENV_DIR/rmfail.log" \
     && [[ -f "$MOCK_HOME/.cache/rmfail_test/data.txt" ]]; then
    echo -e "${GREEN}PASS: a failed delete exited 1 and said so; the file is still there.${NC}"
  else
    echo -e "${RED}FAIL: a failed delete did not report the failure properly.${NC}"
    cat "$TEST_ENV_DIR/rmfail.log"
    exit 1
  fi
else
  rm -f "$TEST_ENV_DIR/bin/rm"
  echo -e "${RED}FAIL: a failed delete did not exit 1 (silent failure).${NC}"
  exit 1
fi

# Control: the same config with a working rm must still exit 0.
setup_mock_env
mkdir -p "$MOCK_HOME/.cache/rmfail_test"
echo "deletable" > "$MOCK_HOME/.cache/rmfail_test/data.txt"
cat << 'EOF' > "$TEST_ENV_DIR/rmfail.conf"
safe|Rmfail Target|$HOME/.cache/rmfail_test|Target whose delete now succeeds|0||
EOF
if run_test_case "Successful Delete Still Exits Zero" 0 "rmok.log" \
     --config "$TEST_ENV_DIR/rmfail.conf" --clean --force; then
  if [[ ! -e "$MOCK_HOME/.cache/rmfail_test" ]]; then
    echo -e "${GREEN}PASS: a successful cleanup still exits 0 and removed the target.${NC}"
  else
    echo -e "${RED}FAIL: the control run did not delete the target.${NC}"
    cat "$TEST_ENV_DIR/rmok.log"
    exit 1
  fi
else
  exit 1
fi

# 51. Test Case: --list-sessions shows what each session actually holds, so an
# irreversible purge (or a restore) can be decided on sight.
setup_mock_env
if run_test_case "Quarantine for Content Listing" 0 "list_content_setup.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --trash --force --yes-danger; then
  if run_test_case "List Sessions Shows Contents" 0 "list_content.log" --list-sessions; then
    if grep -qE '^\s+(full|aged)\s+.*/\.npm/_cacache' "$TEST_ENV_DIR/list_content.log"; then
      echo -e "${GREEN}PASS: --list-sessions listed a quarantined target's type and original path.${NC}"
    else
      echo -e "${RED}FAIL: --list-sessions did not show the session's contents.${NC}"
      cat "$TEST_ENV_DIR/list_content.log"
      exit 1
    fi
  else
    exit 1
  fi
else
  exit 1
fi

# 52. Test Case: the irreversible purge confirmation names the targets it would
# destroy, not just a session size -- and declining still purges nothing.
setup_mock_env
if run_test_case "Quarantine for Purge Preview" 0 "purge_preview_setup.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --trash --force --yes-danger; then
  # stdin is /dev/null, so the [y/N] prompt is declined.
  if run_test_case "Purge Preview Names Targets" 0 "purge_preview.log" --purge-sessions all; then
    if grep -qE '^\s+(full|aged)\s+.*/\.npm/_cacache' "$TEST_ENV_DIR/purge_preview.log" \
       && grep -q "This cannot be undone" "$TEST_ENV_DIR/purge_preview.log" \
       && grep -q "No sessions were purged" "$TEST_ENV_DIR/purge_preview.log" \
       && [[ -d "$MOCK_HOME/.cache/linux-cleaner/quarantine" ]]; then
      echo -e "${GREEN}PASS: the purge confirmation named the targets it would destroy; declining purged nothing.${NC}"
    else
      echo -e "${RED}FAIL: the purge confirmation did not name its targets.${NC}"
      cat "$TEST_ENV_DIR/purge_preview.log"
      exit 1
    fi
  else
    exit 1
  fi
else
  exit 1
fi

# 53. Test Case: the shipped man page must render without roff diagnostics. The
# option-coverage test only greps cleaner.1 for flag tokens, so a broken macro or
# an unterminated font escape would ship a garbled page with nothing failing.
echo -e "\n${BOLD}Test Case: Man Page Renders Cleanly${NC}"
man_err="$TEST_ENV_DIR/man_render.err"
man_out="$TEST_ENV_DIR/man_render.out"
man_ec=0
# groff first: it renders and warns without a pager or locale noise on stderr,
# so an empty stderr is a trustworthy signal. man -l is the fallback.
if command -v groff > /dev/null 2>&1; then
  groff -man -ww -Tutf8 "$SCRIPT_DIR/cleaner.1" > "$man_out" 2> "$man_err" || man_ec=$?
elif command -v mandoc > /dev/null 2>&1; then
  mandoc -T ascii "$SCRIPT_DIR/cleaner.1" > "$man_out" 2> "$man_err" || man_ec=$?
elif command -v man > /dev/null 2>&1; then
  man --warnings -E UTF-8 -l "$SCRIPT_DIR/cleaner.1" > "$man_out" 2> "$man_err" || man_ec=$?
else
  man_ec=-1
fi
if [[ $man_ec -eq -1 ]]; then
  echo -e "${GREEN}PASS (skipped): no roff formatter (man/groff/mandoc) on PATH.${NC}"
elif [[ $man_ec -eq 0 ]] && [[ ! -s "$man_err" ]] && [[ -s "$man_out" ]] \
     && grep -q "NAME" "$man_out"; then
  echo -e "${GREEN}PASS: cleaner.1 renders with no roff diagnostics.${NC}"
else
  echo -e "${RED}FAIL: cleaner.1 did not render cleanly (ec=$man_ec).${NC}"
  cat "$man_err"
  exit 1
fi

# 54. Test Case: the shipped default config must target caches and temp files only.
# $HOME/.config is configuration and persistent state (e.g. a browser's per-site
# IndexedDB storage) -- a target there is data loss, not reclamation, and the README
# rates that class "danger". The default every install receives must not carry one.
#
# Rejection is the default. A leaf name is exempted only when what it names is
# regenerated by the application on demand -- a cache tree, or an artifact rebuilt
# from a pristine copy that sits beside it -- and never when it stores anything the
# user would miss. rootfs.img is the second kind: the local-agent VM image rebuilds
# from the rootfs.img.zst next to it, losing no project or session data.
# Electron editors keep genuine throwaway caches under $HOME/.config (per-build V8
# compiled-code and WASM caches, rotated log directories), so the name, not the
# parent directory, decides. Adding a name here widens what every install may
# delete: justify it by what the directory holds, not by how large it is.
# Deliberately NOT exempt: User/History, whose entries.json records a resource path
# and edit history per file -- an editor recovery feature, i.e. exactly the state
# class this guard exists to protect.
config_cache_names="|CachedData|logs|Cache|Code Cache|component_crx_cache|GPUPersistentCache|rootfs.img|"
config_offenders=""
while IFS='|' read -r c_risk _ c_path _; do
  c_risk="${c_risk#"${c_risk%%[![:space:]]*}"}"
  [[ -z "$c_risk" || "$c_risk" == \#* ]] && continue
  case "$c_path" in
    */.config/*)
      # Exempt only an allowlisted leaf name; every other .config path still fails.
      c_leaf="${c_path##*/}"
      case "$config_cache_names" in
        *"|$c_leaf|"*) ;;
        *) config_offenders+=" $c_path" ;;
      esac
      ;;
  esac
done < "$SCRIPT_DIR/cleaner.conf"
if [[ -z "$config_offenders" ]]; then
  echo -e "${GREEN}PASS: the shipped config targets no \$HOME/.config state path (allowlisted caches only).${NC}"
else
  echo -e "${RED}FAIL: the shipped config targets configuration/state, not cache:$config_offenders${NC}"
  exit 1
fi

# The allowlist must stay narrow: prove it still rejects a state path under
# $HOME/.config rather than having been widened into a blanket exemption.
guard_probe_offenders=""
for guard_probe in "\$HOME/.config/Cursor/User/History" \
                   "\$HOME/.config/Cursor/User/globalStorage" \
                   "\$HOME/.config/Cursor/CachedData"; do
  probe_leaf="${guard_probe##*/}"
  case "$config_cache_names" in
    *"|$probe_leaf|"*) ;;
    *) guard_probe_offenders+=" $guard_probe" ;;
  esac
done
if [[ "$guard_probe_offenders" == " \$HOME/.config/Cursor/User/History \$HOME/.config/Cursor/User/globalStorage" ]]; then
  echo -e "${GREEN}PASS: the .config allowlist exempts cache leaves only and still rejects state paths.${NC}"
else
  echo -e "${RED}FAIL: the .config allowlist no longer rejects state paths (rejected:$guard_probe_offenders).${NC}"
  exit 1
fi

# 55. Test Case: age-based quarantine retention (--purge-sessions older-than:DAYS).
# This is what makes trash mode viable unattended: a cron '--trash --force' would
# otherwise accumulate one session per run forever.
setup_mock_env
ret_qb="$MOCK_HOME/.cache/linux-cleaner/quarantine"
mkdir -p "$ret_qb/2020-01-01_00-00-00" "$ret_qb/2099-12-31_23-59-59"
echo old > "$ret_qb/2020-01-01_00-00-00/payload"
echo new > "$ret_qb/2099-12-31_23-59-59/payload"
# Age only the first session; the second keeps its fresh mtime.
touch -d '60 days ago' "$ret_qb/2020-01-01_00-00-00"
if run_test_case "Purge Older-Than Retention" 0 "purge_older.log" \
     --purge-sessions older-than:30 --force; then
  if [[ ! -d "$ret_qb/2020-01-01_00-00-00" && -d "$ret_qb/2099-12-31_23-59-59" ]]; then
    echo -e "${GREEN}PASS: older-than:30 purged the aged session and kept the fresh one.${NC}"
  else
    echo -e "${RED}FAIL: older-than:30 did not purge selectively.${NC}"
    cat "$TEST_ENV_DIR/purge_older.log"
    exit 1
  fi
else
  exit 1
fi

# A retention run that matches nothing is a success for a cron wrapper, not an error.
if run_test_case "Purge Older-Than No Match" 0 "purge_older_none.log" \
     --purge-sessions older-than:30 --force; then
  if grep -q "No quarantine sessions older than 30 day" "$TEST_ENV_DIR/purge_older_none.log" \
     && [[ -d "$ret_qb/2099-12-31_23-59-59" ]]; then
    echo -e "${GREEN}PASS: a retention run matching nothing exits 0 and purges nothing.${NC}"
  else
    echo -e "${RED}FAIL: a no-match retention run did not behave as expected.${NC}"
    cat "$TEST_ENV_DIR/purge_older_none.log"
    exit 1
  fi
else
  exit 1
fi

# A malformed day count is a hard error, not a silently-ignored selector.
if run_test_case "Purge Older-Than Invalid Days" 1 "purge_older_bad.log" \
     --purge-sessions older-than:abc --force; then
  if grep -q "Invalid day count" "$TEST_ENV_DIR/purge_older_bad.log" \
     && [[ -d "$ret_qb/2099-12-31_23-59-59" ]]; then
    echo -e "${GREEN}PASS: a malformed day count exits 1 and purges nothing.${NC}"
  else
    echo -e "${RED}FAIL: a malformed day count was not rejected cleanly.${NC}"
    cat "$TEST_ENV_DIR/purge_older_bad.log"
    exit 1
  fi
else
  exit 1
fi

# 56. Test Case: --restore --only PATTERN returns a single target and leaves the
# rest quarantined with a consistent quarantine.meta -- so a later full restore of
# the same session still succeeds (the invariant the failed-move fix established).
setup_mock_env
cat << 'EOF' > "$TEST_ENV_DIR/only.conf"
safe|Yarn Cache|$HOME/.cache/yarn|yarn cache|0||
safe|NPM Cache|$HOME/.npm/_cacache|npm cache|0||
EOF
if run_test_case "Quarantine for Selective Restore" 0 "only_setup.log" \
     --config "$TEST_ENV_DIR/only.conf" --trash --force; then
  if run_test_case "Restore Only One Target" 0 "only_restore.log" \
       --restore latest --only "/.cache/yarn"; then
    only_meta=$(find "$MOCK_HOME/.cache/linux-cleaner/quarantine" -name quarantine.meta -print -quit 2>/dev/null)
    if [[ -f "$MOCK_HOME/.cache/yarn/yarn-cache.json" ]] \
       && [[ ! -e "$MOCK_HOME/.npm/_cacache" ]] \
       && [[ -f "$only_meta" ]] \
       && ! grep -q "/.cache/yarn" "$only_meta" \
       && grep -q "_cacache" "$only_meta"; then
      echo -e "${GREEN}PASS: --only restored just the matching target; the rest stayed quarantined and the meta is consistent.${NC}"
    else
      echo -e "${RED}FAIL: --only did not restore selectively or left inconsistent metadata.${NC}"
      cat "$TEST_ENV_DIR/only_restore.log"
      cat "$only_meta" 2>/dev/null
      exit 1
    fi
    # The session must still be fully restorable afterwards.
    if run_test_case "Full Restore After Selective Restore" 0 "only_rest2.log" --restore latest; then
      if [[ -e "$MOCK_HOME/.npm/_cacache" ]]; then
        echo -e "${GREEN}PASS: a later full restore of the same session succeeded and returned the remaining target.${NC}"
      else
        echo -e "${RED}FAIL: the remaining target was not restored by the follow-up full restore.${NC}"
        cat "$TEST_ENV_DIR/only_rest2.log"
        exit 1
      fi
    else
      echo -e "${RED}FAIL: a full restore after a selective restore did not exit 0 (session left inconsistent).${NC}"
      cat "$TEST_ENV_DIR/only_rest2.log"
      exit 1
    fi
  else
    exit 1
  fi
else
  exit 1
fi

# A pattern matching nothing must fail loudly rather than "succeed" having done nothing.
setup_mock_env
cat << 'EOF' > "$TEST_ENV_DIR/only.conf"
safe|Yarn Cache|$HOME/.cache/yarn|yarn cache|0||
safe|NPM Cache|$HOME/.npm/_cacache|npm cache|0||
EOF
if run_test_case "Quarantine for No-Match Only" 0 "only_nomatch_setup.log" \
     --config "$TEST_ENV_DIR/only.conf" --trash --force; then
  if run_test_case "Restore Only No Match" 1 "only_nomatch.log" \
       --restore latest --only "no_such_target_xyz"; then
    if grep -q "matches '--only no_such_target_xyz'" "$TEST_ENV_DIR/only_nomatch.log"; then
      echo -e "${GREEN}PASS: an --only pattern matching nothing exits 1 and restores nothing.${NC}"
    else
      echo -e "${RED}FAIL: a no-match --only did not report the empty match.${NC}"
      cat "$TEST_ENV_DIR/only_nomatch.log"
      exit 1
    fi
  else
    exit 1
  fi
else
  exit 1
fi

# --only without --restore is a usage error, not a silently ignored flag.
if run_test_case "Only Without Restore Rejected" 1 "only_norestore.log" \
     --config "$TEST_ENV_DIR/only.conf" --only yarn --dry-run; then
  if grep -q "only requires --restore" "$TEST_ENV_DIR/only_norestore.log"; then
    echo -e "${GREEN}PASS: --only without --restore is rejected with a clear error.${NC}"
  else
    echo -e "${RED}FAIL: --only without --restore was not rejected.${NC}"
    cat "$TEST_ENV_DIR/only_norestore.log"
    exit 1
  fi
else
  exit 1
fi

echo -e "\n${BOLD}Test Case: LINUX_CLEANER_JSON Requires Dry Run${NC}"
LINUX_CLEANER_JSON=1 PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
  "$CLEANER_SH" --config "$TEST_ENV_DIR/test_cleaner.conf" --force --clean \
  > "$TEST_ENV_DIR/json_env_nodry.log" 2>&1 || json_env_ec=$?
if [[ ${json_env_ec:-0} -ne 0 ]] \
   && grep -q "json is valid only with --dry-run" "$TEST_ENV_DIR/json_env_nodry.log"; then
  echo -e "${GREEN}PASS: LINUX_CLEANER_JSON without dry-run is rejected.${NC}"
else
  echo -e "${RED}FAIL: LINUX_CLEANER_JSON enabled JSON on a non-dry-run run (ec=${json_env_ec:-0}).${NC}"
  cat "$TEST_ENV_DIR/json_env_nodry.log"
  exit 1
fi

# --only-target: scoped cleanup by config target NAME (invent tier).
echo -e "\n${BOLD}Test Case: Only Target Dry Run Filter${NC}"
setup_mock_env
if run_test_case "Only Target Dry Run" 0 "only_target_dry.log" \
     --debug --config "$TEST_ENV_DIR/test_cleaner.conf" --only-target NPM --dry-run; then
  if grep -q "NPM Cache" "$TEST_ENV_DIR/only_target_dry.log" \
     && ! grep -q "Yarn Cache" "$TEST_ENV_DIR/only_target_dry.log"; then
    echo -e "${GREEN}PASS: --only-target NPM shows NPM Cache only.${NC}"
  else
    echo -e "${RED}FAIL: --only-target did not filter to NPM Cache only.${NC}"
    cat "$TEST_ENV_DIR/only_target_dry.log"
    exit 1
  fi
else
  exit 1
fi

echo -e "\n${BOLD}Test Case: Only Target No Match${NC}"
if run_test_case "Only Target No Match" 1 "only_target_nomatch.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --only-target no_such_target_xyz --dry-run; then
  if grep -q "matches '--only-target no_such_target_xyz'" "$TEST_ENV_DIR/only_target_nomatch.log"; then
    echo -e "${GREEN}PASS: --only-target with no matching NAME exits 1.${NC}"
  else
    echo -e "${RED}FAIL: --only-target no-match did not report the empty match.${NC}"
    cat "$TEST_ENV_DIR/only_target_nomatch.log"
    exit 1
  fi
else
  exit 1
fi

echo -e "\n${BOLD}Test Case: Only Target With Restore Rejected${NC}"
if run_test_case "Only Target With Restore Rejected" 1 "only_target_norestore.log" \
     --restore latest --only-target NPM; then
  if grep -q "only-target applies only to cleanup" "$TEST_ENV_DIR/only_target_norestore.log"; then
    echo -e "${GREEN}PASS: --only-target with --restore is rejected.${NC}"
  else
    echo -e "${RED}FAIL: --only-target with --restore was not rejected.${NC}"
    cat "$TEST_ENV_DIR/only_target_norestore.log"
    exit 1
  fi
else
  exit 1
fi

echo -e "\n${BOLD}Test Case: Only Target With List Targets Rejected${NC}"
if run_test_case "Only Target With List Targets Rejected" 1 "only_target_nolist.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --only-target NPM --list-targets; then
  if grep -q "only-target applies only to cleanup" "$TEST_ENV_DIR/only_target_nolist.log"; then
    echo -e "${GREEN}PASS: --only-target with --list-targets is rejected.${NC}"
  else
    echo -e "${RED}FAIL: --only-target with --list-targets was not rejected.${NC}"
    cat "$TEST_ENV_DIR/only_target_nolist.log"
    exit 1
  fi
else
  exit 1
fi

echo -e "\n${BOLD}Test Case: Only Target Missing Pattern Argument${NC}"
if run_test_case "Only Target Missing Pattern" 1 "only_target_noarg.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --only-target; then
  if grep -q "only-target requires a pattern argument" "$TEST_ENV_DIR/only_target_noarg.log"; then
    echo -e "${GREEN}PASS: bare --only-target is rejected with a clear error.${NC}"
  else
    echo -e "${RED}FAIL: missing --only-target pattern was not rejected cleanly.${NC}"
    cat "$TEST_ENV_DIR/only_target_noarg.log"
    exit 1
  fi
else
  exit 1
fi

echo -e "\n${BOLD}Test Case: Only Target With List Sessions Rejected${NC}"
if run_test_case "Only Target With List Sessions Rejected" 1 "only_target_nolistsess.log" \
     --list-sessions --only-target NPM; then
  if grep -q "only-target applies only to cleanup" "$TEST_ENV_DIR/only_target_nolistsess.log"; then
    echo -e "${GREEN}PASS: --only-target with --list-sessions is rejected.${NC}"
  else
    echo -e "${RED}FAIL: --only-target with --list-sessions was not rejected.${NC}"
    cat "$TEST_ENV_DIR/only_target_nolistsess.log"
    exit 1
  fi
else
  exit 1
fi

echo -e "\n${BOLD}Test Case: Only Target With Purge Sessions Rejected${NC}"
if run_test_case "Only Target With Purge Rejected" 1 "only_target_nopurge.log" \
     --purge-sessions all --only-target NPM; then
  if grep -q "only-target applies only to cleanup" "$TEST_ENV_DIR/only_target_nopurge.log"; then
    echo -e "${GREEN}PASS: --only-target with --purge-sessions is rejected.${NC}"
  else
    echo -e "${RED}FAIL: --only-target with --purge-sessions was not rejected.${NC}"
    cat "$TEST_ENV_DIR/only_target_nopurge.log"
    exit 1
  fi
else
  exit 1
fi

# --exclude-target: skip matching NAMEs (inverse of --only-target).
echo -e "\n${BOLD}Test Case: Exclude Target Dry Run Filter${NC}"
if run_test_case "Exclude Target Dry Run" 0 "exclude_target_dry.log" \
     --debug --config "$TEST_ENV_DIR/test_cleaner.conf" --exclude-target NPM --dry-run; then
  if ! grep -q "NPM Cache" "$TEST_ENV_DIR/exclude_target_dry.log" \
     && grep -q "Gemini Temp" "$TEST_ENV_DIR/exclude_target_dry.log"; then
    echo -e "${GREEN}PASS: --exclude-target NPM skips NPM Cache and keeps Gemini Temp.${NC}"
  else
    echo -e "${RED}FAIL: --exclude-target did not skip NPM Cache as expected.${NC}"
    cat "$TEST_ENV_DIR/exclude_target_dry.log"
    exit 1
  fi
else
  exit 1
fi

echo -e "\n${BOLD}Test Case: Exclude Target Leaves Nothing${NC}"
if run_test_case "Exclude Target Leaves Nothing" 1 "exclude_target_all.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --only-target NPM --exclude-target NPM --dry-run; then
  if grep -q "left no config targets to process" "$TEST_ENV_DIR/exclude_target_all.log"; then
    echo -e "${GREEN}PASS: --exclude-target with --only-target leaving nothing exits 1.${NC}"
  else
    echo -e "${RED}FAIL: combined only/exclude empty set did not error clearly.${NC}"
    cat "$TEST_ENV_DIR/exclude_target_all.log"
    exit 1
  fi
else
  exit 1
fi

echo -e "\n${BOLD}Test Case: Exclude Target With Restore Rejected${NC}"
if run_test_case "Exclude Target With Restore Rejected" 1 "exclude_target_norestore.log" \
     --restore latest --exclude-target NPM; then
  if grep -q "exclude-target applies only to cleanup" "$TEST_ENV_DIR/exclude_target_norestore.log"; then
    echo -e "${GREEN}PASS: --exclude-target with --restore is rejected.${NC}"
  else
    echo -e "${RED}FAIL: --exclude-target with --restore was not rejected.${NC}"
    cat "$TEST_ENV_DIR/exclude_target_norestore.log"
    exit 1
  fi
else
  exit 1
fi

echo -e "\n${BOLD}Test Case: Exclude Target With List Targets Rejected${NC}"
if run_test_case "Exclude Target With List Targets Rejected" 1 "exclude_target_nolist.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --exclude-target NPM --list-targets; then
  if grep -q "exclude-target applies only to cleanup" "$TEST_ENV_DIR/exclude_target_nolist.log"; then
    echo -e "${GREEN}PASS: --exclude-target with --list-targets is rejected.${NC}"
  else
    echo -e "${RED}FAIL: --exclude-target with --list-targets was not rejected.${NC}"
    cat "$TEST_ENV_DIR/exclude_target_nolist.log"
    exit 1
  fi
else
  exit 1
fi

echo -e "\n${BOLD}Test Case: LINUX_CLEANER_EXCLUDE_TARGET Env${NC}"
setup_mock_env
LINUX_CLEANER_EXCLUDE_TARGET=NPM PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
  "$CLEANER_SH" --debug --config "$TEST_ENV_DIR/test_cleaner.conf" --dry-run \
  < /dev/null > "$TEST_ENV_DIR/env_exclude_target.log" 2>&1 || true
if ! grep -q "NPM Cache" "$TEST_ENV_DIR/env_exclude_target.log" \
   && grep -q "Gemini Temp" "$TEST_ENV_DIR/env_exclude_target.log"; then
  echo -e "${GREEN}PASS: LINUX_CLEANER_EXCLUDE_TARGET skips NPM Cache.${NC}"
else
  echo -e "${RED}FAIL: LINUX_CLEANER_EXCLUDE_TARGET did not filter targets.${NC}"
  cat "$TEST_ENV_DIR/env_exclude_target.log"
  exit 1
fi

# --quiet: minimal output for unattended cron runs.
echo -e "\n${BOLD}Test Case: Quiet Dry Run Output${NC}"
if run_test_case "Quiet Dry Run" 0 "quiet_dry.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --quiet --dry-run; then
  if grep -q "Total potential space savings" "$TEST_ENV_DIR/quiet_dry.log" \
     && ! grep -q '\[FOUND\]' "$TEST_ENV_DIR/quiet_dry.log" \
     && ! grep -q '\[BLOCKED\]' "$TEST_ENV_DIR/quiet_dry.log" \
     && ! grep -q 'Linux Cache & Temp File Cleaner' "$TEST_ENV_DIR/quiet_dry.log"; then
    echo -e "${GREEN}PASS: --quiet keeps totals and hides per-target status and header.${NC}"
  else
    echo -e "${RED}FAIL: --quiet did not suppress status lines or lost the total.${NC}"
    cat "$TEST_ENV_DIR/quiet_dry.log"
    exit 1
  fi
else
  exit 1
fi

# --json: machine-readable dry-run summary for wrappers and dashboards.
echo -e "\n${BOLD}Test Case: JSON Dry Run Output${NC}"
if run_test_case "JSON Dry Run" 0 "json_dry.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --json --dry-run; then
  if python3 -m json.tool < "$TEST_ENV_DIR/json_dry.log" > "$TEST_ENV_DIR/json_parsed.out" 2>"$TEST_ENV_DIR/json_parse.err"; then
    if grep -q '"total_reclaimable_bytes"' "$TEST_ENV_DIR/json_parsed.out" \
       && grep -q '"total_reclaimable_human"' "$TEST_ENV_DIR/json_parsed.out" \
       && grep -q '"size_human"' "$TEST_ENV_DIR/json_parsed.out" \
       && grep -q '"description": "Mock NPM cache"' "$TEST_ENV_DIR/json_parsed.out" \
       && grep -q '"min_age_days": "0"' "$TEST_ENV_DIR/json_parsed.out" \
       && grep -q '"NPM Cache"' "$TEST_ENV_DIR/json_parsed.out" \
       && grep -q '"status": "found"' "$TEST_ENV_DIR/json_parsed.out" \
       && ! grep -q '\[FOUND\]' "$TEST_ENV_DIR/json_dry.log"; then
      echo -e "${GREEN}PASS: --json --dry-run emits valid JSON with target metadata.${NC}"
    else
      echo -e "${RED}FAIL: --json output missing expected fields or still has human status lines.${NC}"
      cat "$TEST_ENV_DIR/json_parsed.out"
      exit 1
    fi
  else
    echo -e "${RED}FAIL: --json output is not valid JSON.${NC}"
    cat "$TEST_ENV_DIR/json_parse.err"
    cat "$TEST_ENV_DIR/json_dry.log"
    exit 1
  fi
else
  exit 1
fi

# Target names with quotes, backslashes, and C0 controls must still produce valid JSON.
echo -e "\n${BOLD}Test Case: JSON Escaping Special Target Names${NC}"
printf '%s\n' $'safe|Türkçe Cache "quoted" \\\\name\b\f\v\001|$HOME/.cache/json_escape_test|Adversarial name chars|0||' \
  > "$TEST_ENV_DIR/json_escape.conf"
mkdir -p "$MOCK_HOME/.cache/json_escape_test"
echo "payload" > "$MOCK_HOME/.cache/json_escape_test/file.txt"
if run_test_case "JSON Escaping Special Target Names" 0 "json_escape.log" \
     --config "$TEST_ENV_DIR/json_escape.conf" --json --dry-run; then
  if python3 -m json.tool < "$TEST_ENV_DIR/json_escape.log" > "$TEST_ENV_DIR/json_escape_parsed.out" 2>"$TEST_ENV_DIR/json_escape_parse.err"; then
    if python3 - "$TEST_ENV_DIR/json_escape.conf" "$TEST_ENV_DIR/json_escape_parsed.out" << 'PY'
import json, sys
data = json.load(open(sys.argv[2]))
# Config NAME includes two literal backslashes and representative C0 controls.
expected = 'Türkçe Cache "quoted" \\\\name\b\f\v\x01'
if data["targets"][0]["name"] != expected:
    raise SystemExit(1)
PY
    then
      echo -e "${GREEN}PASS: --json --dry-run escapes special characters in target names.${NC}"
    else
      echo -e "${RED}FAIL: escaped target name missing from parsed JSON.${NC}"
      cat "$TEST_ENV_DIR/json_escape_parsed.out"
      exit 1
    fi
  else
    echo -e "${RED}FAIL: --json output with special target names is not valid JSON.${NC}"
    cat "$TEST_ENV_DIR/json_escape_parse.err"
    cat "$TEST_ENV_DIR/json_escape.log"
    exit 1
  fi
else
  exit 1
fi

if run_test_case "JSON Requires Dry Run" 1 "json_nodry.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --json --force; then
  if grep -q "json is valid only with --dry-run" "$TEST_ENV_DIR/json_nodry.log"; then
    echo -e "${GREEN}PASS: --json without --dry-run is rejected.${NC}"
  else
    echo -e "${RED}FAIL: --json without --dry-run was not rejected.${NC}"
    cat "$TEST_ENV_DIR/json_nodry.log"
    exit 1
  fi
else
  exit 1
fi

# Restore, purge, and check-config are not JSON output modes. They leave the
# default DRY_RUN flag true, so the partner guard must reject them explicitly
# before restore/purge can mutate quarantine state.
setup_mock_env
json_qsession="$MOCK_HOME/.cache/linux-cleaner/quarantine/2020-01-01_00-00-00"
json_restore_dest="$MOCK_HOME/.cache/json-restore-dest"
mkdir -p "$json_qsession"
echo "quarantined" > "$json_qsession/payload"
printf 'full|payload|%s|false|%s|%s\n' \
  "$json_restore_dest" "$(id -u)" "$(id -g)" > "$json_qsession/quarantine.meta"

if run_test_case "Dry Run With Restore Rejected" 1 "dry_run_restore.log" \
     --restore 2020-01-01_00-00-00 --dry-run; then
  if grep -q "dry-run cannot be combined" "$TEST_ENV_DIR/dry_run_restore.log" \
     && [[ -f "$json_qsession/payload" && ! -e "$json_restore_dest" ]]; then
    echo -e "${GREEN}PASS: explicit --dry-run blocked restore before moving quarantined data.${NC}"
  else
    echo -e "${RED}FAIL: explicit --dry-run with restore mutated data or returned the wrong error.${NC}"
    cat "$TEST_ENV_DIR/dry_run_restore.log"
    exit 1
  fi
else
  exit 1
fi

if run_test_case "Dry Run With Purge Rejected" 1 "dry_run_purge.log" \
     --purge-sessions 2020-01-01_00-00-00 --force --dry-run; then
  if grep -q "dry-run cannot be combined" "$TEST_ENV_DIR/dry_run_purge.log" \
     && [[ -d "$json_qsession" ]]; then
    echo -e "${GREEN}PASS: explicit --dry-run blocked purge before deleting the session.${NC}"
  else
    echo -e "${RED}FAIL: explicit --dry-run with purge mutated data or returned the wrong error.${NC}"
    cat "$TEST_ENV_DIR/dry_run_purge.log"
    exit 1
  fi
else
  exit 1
fi

if run_test_case "Dry Run Before Restore Rejected" 1 "dry_run_before_restore.log" \
     --dry-run --restore 2020-01-01_00-00-00 \
   && run_test_case "Dry Run Before Purge Rejected" 1 "dry_run_before_purge.log" \
     --force --dry-run --purge-sessions 2020-01-01_00-00-00; then
  if [[ -f "$json_qsession/payload" && ! -e "$json_restore_dest" ]]; then
    echo -e "${GREEN}PASS: explicit --dry-run blocked restore and purge in either mode-argument position.${NC}"
  else
    echo -e "${RED}FAIL: reverse-position --dry-run restore/purge mutated quarantined data.${NC}"
    exit 1
  fi
else
  exit 1
fi

if run_test_case "JSON With Restore Rejected" 1 "json_restore.log" \
     --restore 2020-01-01_00-00-00 --json; then
  if grep -q "json is valid only" "$TEST_ENV_DIR/json_restore.log" \
     && [[ -f "$json_qsession/payload" && ! -e "$json_restore_dest" ]]; then
    echo -e "${GREEN}PASS: --restore with --json was rejected before moving quarantined data.${NC}"
  else
    echo -e "${RED}FAIL: --restore with --json mutated data or returned the wrong error.${NC}"
    cat "$TEST_ENV_DIR/json_restore.log"
    exit 1
  fi
else
  exit 1
fi

if LINUX_CLEANER_JSON=1 run_test_case "JSON Env With Purge Rejected" 1 "json_purge.log" \
     --purge-sessions 2020-01-01_00-00-00 --force; then
  if grep -q "json is valid only" "$TEST_ENV_DIR/json_purge.log" \
     && [[ -d "$json_qsession" ]]; then
    echo -e "${GREEN}PASS: LINUX_CLEANER_JSON blocked purge before deleting the session.${NC}"
  else
    echo -e "${RED}FAIL: LINUX_CLEANER_JSON did not block purge before mutation.${NC}"
    cat "$TEST_ENV_DIR/json_purge.log"
    exit 1
  fi
else
  exit 1
fi

if run_test_case "JSON With Check Config Rejected" 1 "json_check_config.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --check-config --json; then
  if grep -q "json is valid only" "$TEST_ENV_DIR/json_check_config.log"; then
    echo -e "${GREEN}PASS: --check-config with --json was rejected instead of printing non-JSON output.${NC}"
  else
    echo -e "${RED}FAIL: --check-config with --json returned the wrong output.${NC}"
    cat "$TEST_ENV_DIR/json_check_config.log"
    exit 1
  fi
else
  exit 1
fi

if run_test_case "Force Overrides Earlier Dry Run for Purge" 0 "dry_run_force_purge.log" \
     --dry-run --purge-sessions 2020-01-01_00-00-00 --force; then
  if [[ ! -d "$json_qsession" ]]; then
    echo -e "${GREEN}PASS: a later --force preserves cleanup-flag precedence for purge.${NC}"
  else
    echo -e "${RED}FAIL: a later --force did not override the earlier --dry-run for purge.${NC}"
    cat "$TEST_ENV_DIR/dry_run_force_purge.log"
    exit 1
  fi
else
  exit 1
fi

echo -e "\n${BOLD}Test Case: Check Config Valid${NC}"
if run_test_case "Check Config Valid" 0 "check_config_ok.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --check-config; then
  if grep -qE '^OK: [0-9]+ targets in ' "$TEST_ENV_DIR/check_config_ok.log" \
     && ! grep -q 'Analyzing targets' "$TEST_ENV_DIR/check_config_ok.log" \
     && ! grep -q 'Total potential space savings' "$TEST_ENV_DIR/check_config_ok.log"; then
    echo -e "${GREEN}PASS: --check-config validates without disk analysis.${NC}"
  else
    echo -e "${RED}FAIL: --check-config did not print OK or ran analysis.${NC}"
    cat "$TEST_ENV_DIR/check_config_ok.log"
    exit 1
  fi
else
  exit 1
fi

echo -e "\n${BOLD}Test Case: Check Config Invalid${NC}"
cat > "$TEST_ENV_DIR/bad_check.conf" << 'EOF'
safe|Broken|path only|
EOF
if run_test_case "Check Config Invalid" 1 "check_config_bad.log" \
     --config "$TEST_ENV_DIR/bad_check.conf" --check-config; then
  if grep -q "expected 5-7 fields" "$TEST_ENV_DIR/check_config_bad.log"; then
    echo -e "${GREEN}PASS: --check-config rejects a malformed config line.${NC}"
  else
    echo -e "${RED}FAIL: --check-config did not report the field-count error.${NC}"
    cat "$TEST_ENV_DIR/check_config_bad.log"
    exit 1
  fi
else
  exit 1
fi

echo -e "\n${BOLD}Test Case: Check Config With List Targets Rejected${NC}"
if run_test_case "Check Config With List Targets Rejected" 1 "check_config_nolist.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --check-config --list-targets; then
  if grep -q "check-config cannot be combined" "$TEST_ENV_DIR/check_config_nolist.log"; then
    echo -e "${GREEN}PASS: --check-config with --list-targets is rejected.${NC}"
  else
    echo -e "${RED}FAIL: --check-config with --list-targets was not rejected.${NC}"
    cat "$TEST_ENV_DIR/check_config_nolist.log"
    exit 1
  fi
else
  exit 1
fi

echo -e "\n${BOLD}Test Case: List Targets Read-Only${NC}"
if run_test_case "List Targets" 0 "list_targets.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --list-targets; then
  if grep -q $'NPM Cache\tsafe\t' "$TEST_ENV_DIR/list_targets.log" \
     && grep -q $'Mock NPM cache' "$TEST_ENV_DIR/list_targets.log" \
     && ! grep -q 'Total potential space savings' "$TEST_ENV_DIR/list_targets.log" \
     && ! grep -q 'Analyzing targets' "$TEST_ENV_DIR/list_targets.log"; then
    echo -e "${GREEN}PASS: --list-targets prints configured targets without dry-run analysis.${NC}"
  else
    echo -e "${RED}FAIL: --list-targets output missing targets/description or ran analysis.${NC}"
    cat "$TEST_ENV_DIR/list_targets.log"
    exit 1
  fi
else
  exit 1
fi

echo -e "\n${BOLD}Test Case: List Targets JSON Output${NC}"
setup_mock_env
if run_test_case "List Targets JSON" 0 "list_targets_json.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --list-targets --json; then
  if python3 -m json.tool < "$TEST_ENV_DIR/list_targets_json.log" > "$TEST_ENV_DIR/list_targets_json_parsed.out" 2>"$TEST_ENV_DIR/list_targets_json_parse.err"; then
    if python3 - "$TEST_ENV_DIR/list_targets_json_parsed.out" << 'PY'
import json, sys
data = json.load(open(sys.argv[1]))
targets = data.get("targets", [])
names = [t.get("name") for t in targets]
assert "NPM Cache" in names
assert all("risk" in t and "path" in t for t in targets)
assert all("description" in t and "min_age_days" in t for t in targets)
assert all("check_processes" in t and "custom_action" in t for t in targets)
npm = next(t for t in targets if t.get("name") == "NPM Cache")
assert isinstance(npm.get("description"), str) and len(npm["description"]) > 0
assert isinstance(npm.get("min_age_days"), str)
assert npm.get("check_processes") == "node,npm"
assert npm.get("custom_action") == ""
PY
    then
      echo -e "${GREEN}PASS: --list-targets --json emits valid JSON inventory.${NC}"
    else
      echo -e "${RED}FAIL: --list-targets JSON missing expected target fields.${NC}"
      cat "$TEST_ENV_DIR/list_targets_json_parsed.out"
      exit 1
    fi
  else
    echo -e "${RED}FAIL: --list-targets --json is not valid JSON.${NC}"
    cat "$TEST_ENV_DIR/list_targets_json_parse.err"
    cat "$TEST_ENV_DIR/list_targets_json.log"
    exit 1
  fi
else
  exit 1
fi

if run_test_case "List Targets With Restore Rejected" 1 "list_targets_bad.log" \
     --restore latest --list-targets; then
  if grep -q "list-targets cannot be combined" "$TEST_ENV_DIR/list_targets_bad.log"; then
    echo -e "${GREEN}PASS: --list-targets with --restore is rejected.${NC}"
  else
    echo -e "${RED}FAIL: --list-targets with --restore was not rejected.${NC}"
    cat "$TEST_ENV_DIR/list_targets_bad.log"
    exit 1
  fi
else
  exit 1
fi

if run_test_case "List Targets With Purge Rejected" 1 "list_targets_nopurge.log" \
     --purge-sessions all --list-targets; then
  if grep -q "list-targets cannot be combined" "$TEST_ENV_DIR/list_targets_nopurge.log"; then
    echo -e "${GREEN}PASS: --list-targets with --purge-sessions is rejected.${NC}"
  else
    echo -e "${RED}FAIL: --list-targets with --purge-sessions was not rejected.${NC}"
    cat "$TEST_ENV_DIR/list_targets_nopurge.log"
    exit 1
  fi
else
  exit 1
fi

if run_test_case "List Targets With List Sessions Rejected" 1 "list_targets_nolistsess.log" \
     --list-sessions --list-targets; then
  if grep -q "list-targets cannot be combined" "$TEST_ENV_DIR/list_targets_nolistsess.log"; then
    echo -e "${GREEN}PASS: --list-targets with --list-sessions is rejected.${NC}"
  else
    echo -e "${RED}FAIL: --list-targets with --list-sessions was not rejected.${NC}"
    cat "$TEST_ENV_DIR/list_targets_nolistsess.log"
    exit 1
  fi
else
  exit 1
fi

# 57. Test Case: release-notes extraction. This decides what a published release SAYS,
# and a published release cannot be cleanly un-published — so it must be tested, not
# left as inline awk inside a workflow where nothing covers it.
echo -e "\n${BOLD}Test Case: Release Notes Extraction${NC}"
rn_sh="$SCRIPT_DIR/release-notes.sh"
rn_ver=$("$CLEANER_SH" --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
rn_out="$TEST_ENV_DIR/notes.md"
rn_ec=0
"$rn_sh" extract "$rn_ver" > "$rn_out" 2>&1 || rn_ec=$?
if [[ $rn_ec -eq 0 ]] && [[ -s "$rn_out" ]] \
   && ! grep -q '^## \[' "$rn_out" \
   && ! grep -qE '^\[[^]]+\]: https?://' "$rn_out"; then
  echo -e "${GREEN}PASS: extracted the $rn_ver section without the [Unreleased] heading above it or the link footer below it.${NC}"
else
  echo -e "${RED}FAIL: release-notes extraction returned the wrong block (ec=$rn_ec).${NC}"
  cat "$rn_out"
  exit 1
fi

# A version with no changelog section must FAIL, never publish an empty-bodied release.
rn_ec=0
"$rn_sh" extract 9.9.9 > "$TEST_ENV_DIR/notes_missing.md" 2>&1 || rn_ec=$?
if [[ $rn_ec -ne 0 ]] && grep -q "no changelog section found" "$TEST_ENV_DIR/notes_missing.md"; then
  echo -e "${GREEN}PASS: a missing changelog section exits non-zero instead of publishing empty notes.${NC}"
else
  echo -e "${RED}FAIL: a missing changelog section did not fail (ec=$rn_ec).${NC}"
  cat "$TEST_ENV_DIR/notes_missing.md"
  exit 1
fi

# The release workflow must actually call the tested script, not carry its own copy.
if grep -q "release-notes.sh extract" "$SCRIPT_DIR/.github/workflows/release.yml" \
   && ! grep -q "printf 'Release %s" "$SCRIPT_DIR/.github/workflows/release.yml"; then
  echo -e "${GREEN}PASS: release.yml calls release-notes.sh and carries no empty-notes fallback.${NC}"
else
  echo -e "${RED}FAIL: release.yml does not use release-notes.sh, or still has the empty-notes fallback.${NC}"
  exit 1
fi

# CHANGELOG env override must read an alternate file, not only the default beside the script.
rn_alt="$TEST_ENV_DIR/alt-changelog.md"
cp "$SCRIPT_DIR/CHANGELOG.md" "$rn_alt"
rn_alt_ec=0
CHANGELOG="$rn_alt" "$rn_sh" extract "$rn_ver" > "$TEST_ENV_DIR/notes_alt.md" 2>&1 || rn_alt_ec=$?
if [[ $rn_alt_ec -eq 0 ]] && cmp -s "$rn_out" "$TEST_ENV_DIR/notes_alt.md"; then
  echo -e "${GREEN}PASS: release-notes.sh honors the CHANGELOG env override.${NC}"
else
  echo -e "${RED}FAIL: CHANGELOG env override did not extract the same block (ec=$rn_alt_ec).${NC}"
  cat "$TEST_ENV_DIR/notes_alt.md"
  exit 1
fi

# extract without a version argument must fail with a clear error.
rn_noarg_ec=0
"$rn_sh" extract > "$TEST_ENV_DIR/notes_noarg.md" 2>&1 || rn_noarg_ec=$?
if [[ $rn_noarg_ec -ne 0 ]] && grep -q "requires a version argument" "$TEST_ENV_DIR/notes_noarg.md"; then
  echo -e "${GREEN}PASS: release-notes.sh extract rejects a missing version argument.${NC}"
else
  echo -e "${RED}FAIL: missing extract argument was not rejected cleanly (ec=$rn_noarg_ec).${NC}"
  cat "$TEST_ENV_DIR/notes_noarg.md"
  exit 1
fi

rn_help_ec=0
"$rn_sh" --help > "$TEST_ENV_DIR/rn_help.log" 2>&1 || rn_help_ec=$?
if [[ $rn_help_ec -eq 0 ]] \
   && grep -q "Usage:" "$TEST_ENV_DIR/rn_help.log" \
   && grep -q "extract" "$TEST_ENV_DIR/rn_help.log"; then
  echo -e "${GREEN}PASS: release-notes.sh --help prints usage and exits 0.${NC}"
else
  echo -e "${RED}FAIL: release-notes.sh --help did not print expected usage (ec=$rn_help_ec).${NC}"
  cat "$TEST_ENV_DIR/rn_help.log"
  exit 1
fi

rn_bad_ec=0
"$rn_sh" not-a-command > "$TEST_ENV_DIR/rn_bad.log" 2>&1 || rn_bad_ec=$?
if [[ $rn_bad_ec -ne 0 ]] && grep -q "Usage:" "$TEST_ENV_DIR/rn_bad.log"; then
  echo -e "${GREEN}PASS: release-notes.sh rejects unknown subcommands with usage and exit 1.${NC}"
else
  echo -e "${RED}FAIL: release-notes.sh accepted or silently ignored an unknown subcommand (ec=$rn_bad_ec).${NC}"
  cat "$TEST_ENV_DIR/rn_bad.log"
  exit 1
fi

rn_nofile_ec=0
CHANGELOG="$TEST_ENV_DIR/no-such-changelog.md" "$rn_sh" extract 1.0.0 \
  > "$TEST_ENV_DIR/rn_nofile.log" 2>&1 || rn_nofile_ec=$?
if [[ $rn_nofile_ec -ne 0 ]] && grep -q "changelog not found" "$TEST_ENV_DIR/rn_nofile.log"; then
  echo -e "${GREEN}PASS: release-notes.sh rejects a missing CHANGELOG file.${NC}"
else
  echo -e "${RED}FAIL: missing CHANGELOG file was not rejected cleanly (ec=$rn_nofile_ec).${NC}"
  cat "$TEST_ENV_DIR/rn_nofile.log"
  exit 1
fi

# 58. Test Case: every documented lint command names the same files as CI does. This
# drifted once already, silently — README.md and CONTRIBUTING.md told contributors to
# lint two files while CI linted three, so a contributor could run the documented
# command, see green, and still fail the build.
echo -e "\n${BOLD}Test Case: ShellCheck Invocation Parity${NC}"
# CI is the source of truth: extract the file list from its shellcheck step.
ci_files=$(grep -m1 -oE 'shellcheck( [a-zA-Z0-9_.-]+\.sh)+' "$SCRIPT_DIR/.github/workflows/ci.yml" \
  | sed 's/^shellcheck //' | tr ' ' '\n' | sort | tr '\n' ' ')
sc_drift=""
for f in ".github/workflows/release.yml" "README.md" "RELEASING.md" "CONTRIBUTING.md" "Makefile"; do
  site_files=$(grep -m1 -oE 'shellcheck( [a-zA-Z0-9_.-]+\.sh)+' "$SCRIPT_DIR/$f" \
    | sed 's/^shellcheck //' | tr ' ' '\n' | sort | tr '\n' ' ')
  if [[ "$site_files" != "$ci_files" ]]; then
    sc_drift+=" $f(=$site_files)"
  fi
done
# Prove the Makefile site is really read: a recipe that drops one file must differ.
sed 's/ release-notes\.sh//' "$SCRIPT_DIR/Makefile" > "$TEST_ENV_DIR/Makefile.drift"
drift_files=$(grep -m1 -oE 'shellcheck( [a-zA-Z0-9_.-]+\.sh)+' "$TEST_ENV_DIR/Makefile.drift" \
  | sed 's/^shellcheck //' | tr ' ' '\n' | sort | tr '\n' ' ')
if [[ "$drift_files" == "$ci_files" ]]; then
  sc_drift+=" Makefile-fixture(drift not detected)"
fi
if [[ -z "$sc_drift" && -n "$ci_files" ]]; then
  echo -e "${GREEN}PASS: all six shellcheck invocations lint the same files (${ci_files% }).${NC}"
else
  echo -e "${RED}FAIL: shellcheck invocation drift — CI lints '${ci_files% }' but:$sc_drift${NC}"
  exit 1
fi

# 59. Test Case: a wildcard PATH_EXPRESSION expands into one independently analyzed
# target per matching directory, through find rather than a shell glob or eval, and
# every match still passes the ordinary safety pipeline.
echo -e "\n${BOLD}Test Case: Wildcard Path Expansion${NC}"
mkdir -p "$MOCK_HOME/projects/alpha/build" \
         "$MOCK_HOME/projects/beta/build-asan" \
         "$MOCK_HOME/projects/gamma/src"
echo "artifact" > "$MOCK_HOME/projects/alpha/build/out.o"
echo "artifact" > "$MOCK_HOME/projects/beta/build-asan/out.o"
echo "source" > "$MOCK_HOME/projects/gamma/src/main.c"
cat > "$TEST_ENV_DIR/glob.conf" <<'GLOBCONF'
safe|Project Builds|$HOME/projects/*/build*|Per-project build output|0||
GLOBCONF

if run_test_case "Wildcard Expansion Listing" 0 "glob_list.log" \
     --list-targets --config "$TEST_ENV_DIR/glob.conf"; then
  glob_hits=$(grep -c "projects/.*/build" "$TEST_ENV_DIR/glob_list.log" || true)
  if [[ "$glob_hits" -eq 2 ]] \
     && grep -q "projects/alpha/build" "$TEST_ENV_DIR/glob_list.log" \
     && grep -q "projects/beta/build-asan" "$TEST_ENV_DIR/glob_list.log" \
     && ! grep -q "projects/gamma/src" "$TEST_ENV_DIR/glob_list.log" \
     && ! grep -q '\*' "$TEST_ENV_DIR/glob_list.log"; then
    echo -e "${GREEN}PASS: wildcard expanded to exactly the two matching build directories.${NC}"
  else
    echo -e "${RED}FAIL: wildcard expansion listed '$glob_hits' match(es); expected alpha/build and beta/build-asan only.${NC}"
    cat "$TEST_ENV_DIR/glob_list.log"
    exit 1
  fi
else
  exit 1
fi

# The same expansion must reach the analyzer, so each match is sized on its own.
if run_test_case "Wildcard Expansion Dry Run" 0 "glob_dry.log" --debug \
     --config "$TEST_ENV_DIR/glob.conf"; then
  if grep -q "FOUND.*Project Builds" "$TEST_ENV_DIR/glob_dry.log" \
     && [[ "$(grep -c 'FOUND.*Project Builds' "$TEST_ENV_DIR/glob_dry.log")" -eq 2 ]]; then
    echo -e "${GREEN}PASS: both expanded targets were analyzed separately in dry-run.${NC}"
  else
    echo -e "${RED}FAIL: dry-run did not analyze each expanded match as its own target.${NC}"
    cat "$TEST_ENV_DIR/glob_dry.log"
    exit 1
  fi
else
  exit 1
fi

# A wildcard matching nothing is not an error — it simply contributes no target.
cat > "$TEST_ENV_DIR/glob_empty.conf" <<'GLOBEMPTY'
safe|Absent Builds|$HOME/projects/*/nosuchdir*|Nothing matches this|0||
GLOBEMPTY
if run_test_case "Wildcard No Match" 0 "glob_empty.log" \
     --config "$TEST_ENV_DIR/glob_empty.conf"; then
  echo -e "${GREEN}PASS: a wildcard matching nothing exits 0 without a target.${NC}"
else
  exit 1
fi

# A wildcard in the first component would make find walk the whole filesystem.
cat > "$TEST_ENV_DIR/glob_root.conf" <<'GLOBROOT'
safe|Root Wildcard|/*/build|Wildcard at the filesystem root|0||
GLOBROOT
if run_test_case "Wildcard Root Refusal" 0 "glob_root.log" \
     --list-targets --config "$TEST_ENV_DIR/glob_root.conf"; then
  if grep -q "wildcard must follow a literal directory" "$TEST_ENV_DIR/glob_root.log" \
     && grep -q '/\*/build' "$TEST_ENV_DIR/glob_root.log"; then
    echo -e "${GREEN}PASS: a root-level wildcard warns and stays unexpanded instead of scanning the filesystem.${NC}"
  else
    echo -e "${RED}FAIL: root-level wildcard was not refused with the documented message.${NC}"
    cat "$TEST_ENV_DIR/glob_root.log"
    exit 1
  fi
else
  exit 1
fi

# A "**" component spans several nesting levels, so one line covers a build
# directory class that occurs at more than one depth.
mkdir -p "$MOCK_HOME/deep/one/build" \
         "$MOCK_HOME/deep/one/two/build" \
         "$MOCK_HOME/deep/one/two/three/build-asan"
cat > "$TEST_ENV_DIR/glob_rec.conf" <<'GLOBREC'
safe|Nested Builds|$HOME/deep/**/build*|Build output at any nesting level|0||
GLOBREC
if run_test_case "Wildcard Recursive Expansion" 0 "glob_rec.log" \
     --list-targets --config "$TEST_ENV_DIR/glob_rec.conf"; then
  if grep -q "deep/one/build" "$TEST_ENV_DIR/glob_rec.log" \
     && grep -q "deep/one/two/build" "$TEST_ENV_DIR/glob_rec.log" \
     && grep -q "deep/one/two/three/build-asan" "$TEST_ENV_DIR/glob_rec.log"; then
    echo -e "${GREEN}PASS: one '**' pattern matched build directories at three different depths.${NC}"
  else
    echo -e "${RED}FAIL: '**' did not span nesting levels.${NC}"
    cat "$TEST_ENV_DIR/glob_rec.log"
    exit 1
  fi
else
  exit 1
fi

# A trailing wildcard must name the directory itself, not swallow the paths below
# it, and a build directory nested inside an already matched one must not become a
# second target -- cleaning the parent would delete what the child still refers to.
mkdir -p "$MOCK_HOME/deep/one/build/CMakeFiles/sub" \
         "$MOCK_HOME/deep/one/build/nested/build"
if run_test_case "Wildcard Recursive No Overlap" 0 "glob_overlap.log" \
     --list-targets --config "$TEST_ENV_DIR/glob_rec.conf"; then
  if ! grep -q "build/CMakeFiles" "$TEST_ENV_DIR/glob_overlap.log" \
     && ! grep -q "build/nested/build" "$TEST_ENV_DIR/glob_overlap.log" \
     && grep -q "deep/one/build" "$TEST_ENV_DIR/glob_overlap.log"; then
    echo -e "${GREEN}PASS: recursion matched the directory itself and pruned nested matches.${NC}"
  else
    echo -e "${RED}FAIL: recursive expansion emitted paths below an already matched directory.${NC}"
    cat "$TEST_ENV_DIR/glob_overlap.log"
    exit 1
  fi
else
  exit 1
fi

# Without "**" the fixed-depth rule must still hold, so the two forms stay distinct.
cat > "$TEST_ENV_DIR/glob_fixed.conf" <<'GLOBFIXED'
safe|Shallow Builds|$HOME/deep/*/build*|Build output one level down|0||
GLOBFIXED
if run_test_case "Wildcard Fixed Depth Unchanged" 0 "glob_fixed.log" \
     --list-targets --config "$TEST_ENV_DIR/glob_fixed.conf"; then
  if grep -q "deep/one/build" "$TEST_ENV_DIR/glob_fixed.log" \
     && ! grep -q "deep/one/two/build" "$TEST_ENV_DIR/glob_fixed.log"; then
    echo -e "${GREEN}PASS: a pattern without '**' still matches exactly one depth.${NC}"
  else
    echo -e "${RED}FAIL: a non-recursive pattern crossed nesting levels.${NC}"
    cat "$TEST_ENV_DIR/glob_fixed.log"
    exit 1
  fi
else
  exit 1
fi

# The recursion ceiling must actually bound the search: a directory below the
# documented limit is not matched, so a mistyped pattern cannot walk a deep tree.
glob_ceiling=$(grep -m1 '^GLOB_RECURSION_MAX_DEPTH=' "$CLEANER_SH" | cut -d= -f2)
if [[ ! "$glob_ceiling" =~ ^[0-9]+$ ]]; then
  echo -e "${RED}FAIL: could not read GLOB_RECURSION_MAX_DEPTH from cleaner.sh.${NC}"
  exit 1
fi
glob_too_deep="$MOCK_HOME/ceiling"
for _ in $(seq 1 "$((glob_ceiling + 1))"); do
  glob_too_deep="$glob_too_deep/d"
done
mkdir -p "$glob_too_deep/build" "$MOCK_HOME/ceiling/d/build"
cat > "$TEST_ENV_DIR/glob_ceiling.conf" <<'GLOBCEIL'
safe|Ceiling Builds|$HOME/ceiling/**/build|Build output under the recursion ceiling|0||
GLOBCEIL
if run_test_case "Wildcard Recursion Ceiling" 0 "glob_ceiling.log" \
     --list-targets --config "$TEST_ENV_DIR/glob_ceiling.conf"; then
  if grep -q "ceiling/d/build" "$TEST_ENV_DIR/glob_ceiling.log" \
     && ! grep -q "$glob_too_deep/build" "$TEST_ENV_DIR/glob_ceiling.log"; then
    echo -e "${GREEN}PASS: recursion stops at the documented ceiling of $glob_ceiling levels.${NC}"
  else
    echo -e "${RED}FAIL: recursion was not bounded by GLOB_RECURSION_MAX_DEPTH=$glob_ceiling.${NC}"
    cat "$TEST_ENV_DIR/glob_ceiling.log"
    exit 1
  fi
else
  exit 1
fi

# filter:cxx_build selects expanded matches by contents rather than by name, so a
# source directory whose name merely starts with "build" is excluded while a real
# build tree -- including a qmake layout whose marker sits one level down -- is kept.
mkdir -p "$MOCK_HOME/src/cmakeproj/build" \
         "$MOCK_HOME/src/qmakeproj/build/Desktop-Debug" \
         "$MOCK_HOME/src/libproj/builder"
# Non-empty on purpose: a target whose total size is 0 B is reported already clean
# and never deleted, so empty markers would not exercise the cleanup path below.
echo "CMAKE_CACHE_MAJOR_VERSION:INTERNAL=3" > "$MOCK_HOME/src/cmakeproj/build/CMakeCache.txt"
echo "QMAKE_STASH" > "$MOCK_HOME/src/qmakeproj/build/Desktop-Debug/.qmake.stash"
echo "module.exports = {}" > "$MOCK_HOME/src/libproj/builder/index.js"
cat > "$TEST_ENV_DIR/glob_filter.conf" <<'GLOBFILT'
safe|Filtered Builds|$HOME/src/**/build*|Real build trees only|0||filter:cxx_build
GLOBFILT
cat > "$TEST_ENV_DIR/glob_nofilter.conf" <<'GLOBNOFILT'
safe|Unfiltered Builds|$HOME/src/**/build*|Name matches only|0||
GLOBNOFILT
if run_test_case "Wildcard Build Marker Filter" 0 "glob_filter.log" \
     --list-targets --config "$TEST_ENV_DIR/glob_filter.conf"; then
  if grep -q "cmakeproj/build" "$TEST_ENV_DIR/glob_filter.log" \
     && grep -q "qmakeproj/build" "$TEST_ENV_DIR/glob_filter.log" \
     && ! grep -q "libproj/builder" "$TEST_ENV_DIR/glob_filter.log"; then
    echo -e "${GREEN}PASS: filter:cxx_build kept both build trees and excluded the source directory.${NC}"
  else
    echo -e "${RED}FAIL: filter:cxx_build selected the wrong directories.${NC}"
    cat "$TEST_ENV_DIR/glob_filter.log"
    exit 1
  fi
else
  exit 1
fi

# Without the token the behaviour must be unchanged, so the filter is opt-in only.
if run_test_case "Wildcard Filter Is Opt In" 0 "glob_nofilter.log" \
     --list-targets --config "$TEST_ENV_DIR/glob_nofilter.conf"; then
  if grep -q "libproj/builder" "$TEST_ENV_DIR/glob_nofilter.log"; then
    echo -e "${GREEN}PASS: the same pattern without the token still matches by name alone.${NC}"
  else
    echo -e "${RED}FAIL: name-only expansion changed when the filter token was absent.${NC}"
    cat "$TEST_ENV_DIR/glob_nofilter.log"
    exit 1
  fi
else
  exit 1
fi

# An unknown filter: token must be rejected exactly like an unknown action:.
cat > "$TEST_ENV_DIR/glob_badfilter.conf" <<'GLOBBAD'
safe|Bad Filter|$HOME/src/**/build*|Unknown filter token|0||filter:nosuchfilter
GLOBBAD
if run_test_case "Unknown Filter Token Rejected" 1 "glob_badfilter.log" \
     --check-config --config "$TEST_ENV_DIR/glob_badfilter.conf"; then
  if grep -q "Unknown action 'filter:nosuchfilter'" "$TEST_ENV_DIR/glob_badfilter.log"; then
    echo -e "${GREEN}PASS: an unknown filter token is rejected with a line-numbered error.${NC}"
  else
    echo -e "${RED}FAIL: an unknown filter token was not rejected.${NC}"
    cat "$TEST_ENV_DIR/glob_badfilter.log"
    exit 1
  fi
else
  exit 1
fi

# A filter token must never be executed as an action during a real cleanup.
if run_test_case "Filter Token Is Not An Action" 0 "glob_filter_clean.log" \
     --clean --force --config "$TEST_ENV_DIR/glob_filter.conf"; then
  if ! grep -q "Executing action" "$TEST_ENV_DIR/glob_filter_clean.log" \
     && ! grep -q "Unknown action" "$TEST_ENV_DIR/glob_filter_clean.log" \
     && [[ ! -f "$MOCK_HOME/src/cmakeproj/build/CMakeCache.txt" ]] \
     && [[ -f "$MOCK_HOME/src/libproj/builder/index.js" ]]; then
    echo -e "${GREEN}PASS: the filter token cleaned the build trees and never ran as an action.${NC}"
  else
    echo -e "${RED}FAIL: the filter token was treated as an action or cleaned the wrong directory.${NC}"
    cat "$TEST_ENV_DIR/glob_filter_clean.log"
    exit 1
  fi
else
  exit 1
fi

# Line numbers must survive expansion: an error after a wildcard line still cites
# its real physical line, not a position shifted by the expanded matches.
cat > "$TEST_ENV_DIR/glob_lineno.conf" <<'GLOBLINENO'
safe|Project Builds|$HOME/projects/*/build*|Per-project build output|0||
safe|Broken|$HOME/x|too few fields
GLOBLINENO
if run_test_case "Wildcard Line Number Fidelity" 1 "glob_lineno.log" \
     --check-config --config "$TEST_ENV_DIR/glob_lineno.conf"; then
  if grep -q ":2: expected 5-7 fields" "$TEST_ENV_DIR/glob_lineno.log"; then
    echo -e "${GREEN}PASS: config errors still cite the real source line after expansion.${NC}"
  else
    echo -e "${RED}FAIL: expansion shifted the reported config line number.${NC}"
    cat "$TEST_ENV_DIR/glob_lineno.log"
    exit 1
  fi
else
  exit 1
fi

# 60. Test Case: cmdline: guards a tool whose process name is not its own. A tool
# launched through a shared runtime runs as "electron" or "node", so exact-comm
# matching silently never fires and its data would be deleted while it is open.
echo -e "\n${BOLD}Test Case: Cmdline Process Guard${NC}"
mkdir -p "$MOCK_HOME/guarded"
echo "payload" > "$MOCK_HOME/guarded/data.txt"
cat > "$TEST_ENV_DIR/cmdline_guard.conf" <<'CMDGUARD'
safe|Cmdline Guarded|$HOME/guarded|Blocked while the runtime process lives|0|cmdline:mock_cmdline_proc|
CMDGUARD

# A real sibling process: not our ancestor, not our descendant, and genuinely alive.
sleep 60 &
mock_cmdline_pid=$!
echo "$mock_cmdline_pid" > "$TEST_ENV_DIR/mock_cmdline_pid"

if run_test_case "Cmdline Guard Blocks" 0 "cmdline_block.log" \
     --config "$TEST_ENV_DIR/cmdline_guard.conf"; then
  if grep -q "BLOCKED.*Cmdline Guarded.*cmdline:mock_cmdline_proc" "$TEST_ENV_DIR/cmdline_block.log"; then
    echo -e "${GREEN}PASS: a cmdline: token blocked the target and named itself in the status line.${NC}"
  else
    echo -e "${RED}FAIL: the cmdline: token did not block the target.${NC}"
    cat "$TEST_ENV_DIR/cmdline_block.log"
    kill "$mock_cmdline_pid" 2>/dev/null || true
    exit 1
  fi
else
  kill "$mock_cmdline_pid" 2>/dev/null || true
  exit 1
fi

# Once the process is gone the target must become cleanable again: a dead PID in the
# match set is not an application still running.
# wait reports 143 for a signalled job; tolerate it so set -e does not abort here.
kill "$mock_cmdline_pid" 2>/dev/null || true
wait "$mock_cmdline_pid" 2>/dev/null || true
echo "$mock_cmdline_pid" > "$TEST_ENV_DIR/mock_cmdline_pid"
if run_test_case "Cmdline Guard Releases" 0 "cmdline_release.log" --debug \
     --config "$TEST_ENV_DIR/cmdline_guard.conf"; then
  if grep -q "FOUND.*Cmdline Guarded" "$TEST_ENV_DIR/cmdline_release.log"; then
    echo -e "${GREEN}PASS: a dead PID in the match set does not block the target.${NC}"
  else
    echo -e "${RED}FAIL: the target stayed blocked after the process exited.${NC}"
    cat "$TEST_ENV_DIR/cmdline_release.log"
    exit 1
  fi
else
  exit 1
fi

# The pattern appearing in our own invocation must never block: that would make the
# guard fire forever against nothing, which is how pgrep -f guards usually break.
cat > "$TEST_ENV_DIR/cmdline_self.conf" <<'CMDSELF'
safe|mock_cmdline_proc|$HOME/guarded|Pattern appears in our own argv|0|cmdline:mock_cmdline_proc|
CMDSELF
rm -f "$TEST_ENV_DIR/mock_cmdline_pid"
if run_test_case "Cmdline Guard Ignores Self" 0 "cmdline_self.log" --debug \
     --config "$TEST_ENV_DIR/cmdline_self.conf" --only-target mock_cmdline_proc; then
  if grep -q "FOUND.*mock_cmdline_proc" "$TEST_ENV_DIR/cmdline_self.log"; then
    echo -e "${GREEN}PASS: a pattern present only in our own command line does not block.${NC}"
  else
    echo -e "${RED}FAIL: the guard matched the cleaner's own invocation.${NC}"
    cat "$TEST_ENV_DIR/cmdline_self.log"
    exit 1
  fi
else
  exit 1
fi

# A bare token must keep matching comm exactly, so the two forms stay distinct.
cat > "$TEST_ENV_DIR/cmdline_bare.conf" <<'CMDBARE'
safe|Bare Token|$HOME/guarded|Exact comm match only|0|mock_running_proc|
CMDBARE
if run_test_case "Bare Token Still Matches Comm" 0 "cmdline_bare.log" \
     --config "$TEST_ENV_DIR/cmdline_bare.conf"; then
  if grep -q "BLOCKED.*Bare Token.*'mock_running_proc'" "$TEST_ENV_DIR/cmdline_bare.log"; then
    echo -e "${GREEN}PASS: a bare token still matches the process name exactly.${NC}"
  else
    echo -e "${RED}FAIL: bare-token behaviour changed.${NC}"
    cat "$TEST_ENV_DIR/cmdline_bare.log"
    exit 1
  fi
else
  exit 1
fi

# An empty pattern after the prefix would match every process, so it is rejected.
cat > "$TEST_ENV_DIR/cmdline_empty.conf" <<'CMDEMPTY'
safe|Empty Pattern|$HOME/guarded|No pattern after the prefix|0|cmdline:|
CMDEMPTY
if run_test_case "Empty Cmdline Pattern Rejected" 1 "cmdline_empty.log" \
     --check-config --config "$TEST_ENV_DIR/cmdline_empty.conf"; then
  if grep -q "empty pattern after 'cmdline:'" "$TEST_ENV_DIR/cmdline_empty.log"; then
    echo -e "${GREEN}PASS: an empty cmdline: pattern is rejected with a line-numbered error.${NC}"
  else
    echo -e "${RED}FAIL: an empty cmdline: pattern was accepted.${NC}"
    cat "$TEST_ENV_DIR/cmdline_empty.log"
    exit 1
  fi
else
  exit 1
fi

# Excluding a whole single-file target must prevent the move/delete, even when
# another eligible target makes the total nonzero and enables the execution pass.
for exclusion_mode in delete trash; do
  setup_mock_env
  printf 'preserve exactly\n' > "$MOCK_HOME/keep.log"
  printf 'discard\n' > "$MOCK_HOME/discard.tmp"
  cat > "$TEST_ENV_DIR/excluded_file.conf" <<'EXCLUDEFILE'
safe|Excluded File|$HOME/keep.log|Must remain untouched|0||
safe|Eligible File|$HOME/discard.tmp|Sibling enables cleanup|0||
EXCLUDEFILE
  exclusion_args=()
  [[ "$exclusion_mode" == trash ]] && exclusion_args+=(--trash)
  if run_test_case "Excluded Single File ($exclusion_mode)" 0 "excluded_file.log" \
       --config "$TEST_ENV_DIR/excluded_file.conf" --force --exclude '*.log' "${exclusion_args[@]}" \
     && grep -qx 'preserve exactly' "$MOCK_HOME/keep.log" \
     && [[ ! -e "$MOCK_HOME/discard.tmp" ]]; then
    if [[ "$exclusion_mode" == trash ]]; then
      quarantine_meta=$(find "$MOCK_HOME/.cache/linux-cleaner/quarantine" -name quarantine.meta)
      if grep -qF '/keep.log|' "$quarantine_meta" \
         || ! grep -qF '/discard.tmp|' "$quarantine_meta"; then
        echo -e "${RED}FAIL: quarantine did not preserve the single-file exclusion.${NC}"
        exit 1
      fi
    fi
    echo -e "${GREEN}PASS: excluded single file stays intact during $exclusion_mode while its sibling is cleaned.${NC}"
  else
    echo -e "${RED}FAIL: excluded single file was moved or deleted during $exclusion_mode.${NC}"
    cat "$TEST_ENV_DIR/excluded_file.log"
    exit 1
  fi
done

# Whitespace is valid around config fields, and a literal path must obey its
# filter just as a wildcard does. Exercise the shared inventory/cleanup stream.
for filter_form in wildcard literal; do
  setup_mock_env
  mkdir -p "$MOCK_HOME/filter/build-source" "$MOCK_HOME/filter/build-real"
  printf 'source\n' > "$MOCK_HOME/filter/build-source/keep.c"
  printf 'generated\n' > "$MOCK_HOME/filter/build-real/CMakeCache.txt"
  if [[ "$filter_form" == wildcard ]]; then
    filter_paths=("\$HOME/filter/build-*")
  else
    filter_paths=("\$HOME/filter/build-source" "\$HOME/filter/build-real")
  fi
  printf 'safe|Filtered Build|%s|Only generated output|0|| filter:cxx_build \n' \
    "${filter_paths[@]}" > "$TEST_ENV_DIR/padded_filter.conf"
  for filter_output in human json; do
    filter_args=()
    [[ "$filter_output" == json ]] && filter_args+=(--json)
    if ! run_test_case "Build Filter Inventory ($filter_form $filter_output)" 0 "padded_filter.log" \
         --config "$TEST_ENV_DIR/padded_filter.conf" --list-targets "${filter_args[@]}" \
       || grep -q 'build-source' "$TEST_ENV_DIR/padded_filter.log" \
       || ! grep -q 'build-real' "$TEST_ENV_DIR/padded_filter.log"; then
      echo -e "${RED}FAIL: $filter_form inventory bypassed a padded build filter.${NC}"
      cat "$TEST_ENV_DIR/padded_filter.log"
      exit 1
    fi
  done
  if run_test_case "Build Filter Cleanup ($filter_form)" 0 "padded_filter_clean.log" \
       --config "$TEST_ENV_DIR/padded_filter.conf" --force \
     && grep -qx source "$MOCK_HOME/filter/build-source/keep.c" \
     && [[ ! -e "$MOCK_HOME/filter/build-real" ]]; then
    echo -e "${GREEN}PASS: $filter_form build filter preserves source and cleans generated output.${NC}"
  else
    echo -e "${RED}FAIL: $filter_form cleanup bypassed a padded build filter.${NC}"
    cat "$TEST_ENV_DIR/padded_filter_clean.log"
    exit 1
  fi
done

# Invalid wildcard records must be rejected even if they currently match nothing,
# before a valid sibling can be cleaned. All config consumers share this gate.
setup_mock_env
printf 'preserve\n' > "$MOCK_HOME/config-sentinel"
for invalid_record in \
  "safe|Absent|\$HOME/missing/*|Invalid age|nope||" \
  "safe|Absent|\$HOME/missing/*|Invalid action|0||filter:unknown" \
  "safe|Absent|\$HOME/missing/*|Extra field|0|||extra" \
  "safe|Absent|\$HOME/missing/*|Empty command pattern|0|cmdline:|"; do
  printf '%s\n' \
    "safe|Sentinel|\$HOME/config-sentinel|Must not be touched|0||" \
    '# Keep physical line numbering' "$invalid_record" > "$TEST_ENV_DIR/unmatched_invalid.conf"
  for validation_mode in check inventory json clean; do
    case "$validation_mode" in
      check) validation_args=(--check-config) ;;
      inventory) validation_args=(--list-targets) ;;
      json) validation_args=(--list-targets --json) ;;
      clean) validation_args=(--force) ;;
    esac
    if ! run_test_case "Unmatched Wildcard Validation ($validation_mode)" 1 "unmatched_invalid.log" \
         --config "$TEST_ENV_DIR/unmatched_invalid.conf" "${validation_args[@]}" \
       || ! grep -qF 'unmatched_invalid.conf:3:' "$TEST_ENV_DIR/unmatched_invalid.log" \
       || ! grep -qx preserve "$MOCK_HOME/config-sentinel"; then
      echo -e "${RED}FAIL: $validation_mode hid a malformed unmatched wildcard record.${NC}"
      cat "$TEST_ENV_DIR/unmatched_invalid.log"
      exit 1
    fi
  done
done
echo -e "${GREEN}PASS: all config consumers reject malformed unmatched wildcard records before mutation.${NC}"

# --check-config validates definitions, never their current expansion or contents.
mkdir -p "$MOCK_HOME/count/a" "$MOCK_HOME/count/b"
printf '%s\n' \
  "safe|Existing Pattern|\$HOME/count/*|Two matches but one definition|0||" \
  "safe|Absent Pattern|\$HOME/absent/*|No matches but one definition|0||filter:cxx_build" \
  > "$TEST_ENV_DIR/raw_count.conf"
cat > "$TEST_ENV_DIR/bin/find" <<'NOFIND'
#!/usr/bin/env bash
printf 'called\n' >> "$TEST_ENV_DIR/check_config_find_called"
exit 99
NOFIND
chmod +x "$TEST_ENV_DIR/bin/find"
if run_test_case "Check Config Counts Definitions Without Traversal" 0 "raw_count.log" \
     --config "$TEST_ENV_DIR/raw_count.conf" --check-config \
   && grep -q '^OK: 2 targets in ' "$TEST_ENV_DIR/raw_count.log" \
   && [[ ! -e "$TEST_ENV_DIR/check_config_find_called" ]]; then
  echo -e "${GREEN}PASS: --check-config counts raw definitions and never invokes find.${NC}"
else
  echo -e "${RED}FAIL: --check-config traversed target paths or counted filesystem matches.${NC}"
  cat "$TEST_ENV_DIR/raw_count.log"
  exit 1
fi

# A discovered filename must not turn into a different config target. In
# particular, build?* must never emit the unmatched sibling named just build.
for transport_mode in delete trash; do
  setup_mock_env
  transport_names=($'build\nunrelated' 'build|field' 'build ' "build\$USER")
  mkdir -p "$MOCK_HOME/transport/build" "$MOCK_HOME/transport/build-normal output"
  printf 'preserve\n' > "$MOCK_HOME/transport/build/keep"
  printf 'generated\n' > "$MOCK_HOME/transport/build-normal output/discard"
  for transport_name in "${transport_names[@]}"; do
    mkdir -p "$MOCK_HOME/transport/$transport_name"
    printf 'preserve\n' > "$MOCK_HOME/transport/$transport_name/keep"
  done
  cat > "$TEST_ENV_DIR/transport.conf" <<'TRANSPORT'
safe|Transport Target|$HOME/transport/build?*|Preserve directory identity|0||
TRANSPORT
  if ! run_test_case "Wildcard Path Identity Inventory ($transport_mode)" 0 "transport_list.log" \
       --config "$TEST_ENV_DIR/transport.conf" --list-targets \
     || [[ "$(grep -c '^Transport Target[[:space:]]' "$TEST_ENV_DIR/transport_list.log")" -ne 1 ]] \
     || ! grep -q 'build-normal output' "$TEST_ENV_DIR/transport_list.log" \
     || ! grep -q 'skipping wildcard match that cannot be represented safely' "$TEST_ENV_DIR/transport_list.log"; then
    echo -e "${RED}FAIL: wildcard inventory changed a discovered directory name.${NC}"
    cat "$TEST_ENV_DIR/transport_list.log"
    exit 1
  fi
  transport_args=()
  [[ "$transport_mode" == trash ]] && transport_args+=(--trash)
  if ! run_test_case "Wildcard Path Identity Cleanup ($transport_mode)" 0 "transport_clean.log" \
       --config "$TEST_ENV_DIR/transport.conf" --force "${transport_args[@]}" \
     || ! grep -qx preserve "$MOCK_HOME/transport/build/keep" \
     || [[ -e "$MOCK_HOME/transport/build-normal output" ]]; then
    echo -e "${RED}FAIL: wildcard cleanup acted on the wrong directory.${NC}"
    cat "$TEST_ENV_DIR/transport_clean.log"
    exit 1
  fi
  for transport_name in "${transport_names[@]}"; do
    if ! grep -qx preserve "$MOCK_HOME/transport/$transport_name/keep"; then
      echo -e "${RED}FAIL: an unrepresentable wildcard match was cleaned.${NC}"
      exit 1
    fi
  done
  echo -e "${GREEN}PASS: wildcard $transport_mode preserves unmatched and unrepresentable paths; ordinary spaces still work.${NC}"
done

# An absent package manager must not ask for sudo or block an ordinary sibling.
# A restricted PATH makes absence deterministic even when the host has dnf.
setup_mock_env
missing_action_bin="$TEST_ENV_DIR/missing_action_bin"
mkdir -p "$missing_action_bin"
for tool in bash basename cat dirname realpath sed du awk tr id sort find stat date rm mktemp; do
  ln -s "$(command -v "$tool")" "$missing_action_bin/$tool"
done
rm "$TEST_ENV_DIR/bin/dnf"
cat > "$TEST_ENV_DIR/bin/sudo" <<'NOAUTH'
#!/usr/bin/env bash
printf 'called\n' >> "$TEST_ENV_DIR/unexpected_sudo"
exit 1
NOAUTH
chmod +x "$TEST_ENV_DIR/bin/sudo"
cat > "$TEST_ENV_DIR/missing_action.conf" <<'MISSING_ACTION'
safe|Absent Manager|$HOME/.cache/aurman|Unavailable manager|0||action:dnf_clean
safe|Ordinary Cache|$HOME/.npm/_cacache|No privileges needed|0||
MISSING_ACTION
if ! PATH="$missing_action_bin" run_test_case "Absent Action JSON Without Sudo" 0 "missing_action_json.log" \
     --config "$TEST_ENV_DIR/missing_action.conf" --dry-run --json \
   || ! grep -q '"bytes":0,"size_human":"0 B","status":"skipped"' "$TEST_ENV_DIR/missing_action_json.log" \
   || ! PATH="$missing_action_bin" run_test_case "Absent Action Cleanup Without Sudo" 0 "missing_action.log" \
     --config "$TEST_ENV_DIR/missing_action.conf" --force \
   || [[ -e "$TEST_ENV_DIR/unexpected_sudo" || -e "$MOCK_HOME/.npm/_cacache" ]] \
   || [[ ! -f "$MOCK_HOME/.cache/aurman/pkg1.tar.zst" ]] \
   || ! grep -q "'dnf' not available" "$TEST_ENV_DIR/missing_action.log"; then
  echo -e "${RED}FAIL: an absent action requested sudo, broke preview, or blocked ordinary cleanup.${NC}"
  cat "$TEST_ENV_DIR"/missing_action*.log
  exit 1
fi
echo -e "${GREEN}PASS: absent actions skip before sudo and ordinary sibling cleanup succeeds.${NC}"

# Process-substitution discovery must propagate a partial find failure. Exercise
# both ownership branches without using real sudo or host permission assumptions.
for traversal_sudo in false true; do
  setup_mock_env
  cat > "$TEST_ENV_DIR/bin/find" <<'PARTIAL_FIND'
#!/usr/bin/env bash
if [[ "$1" == "${MOCK_FIND_FAIL_ROOT:-}" && " $* " == *' -print0 '* ]]; then
  printf '%s\0' "$1/first"
  exit 1
fi
real_find=$(PATH="${PATH#"$TEST_ENV_DIR/bin:"}" command -v find)
exec "$real_find" "$@"
PARTIAL_FIND
  chmod +x "$TEST_ENV_DIR/bin/find"
  traversal_target="$MOCK_HOME/.cache/traversal"
  mkdir -p "$traversal_target"
  printf 'first\n' > "$traversal_target/first"
  printf 'second\n' > "$traversal_target/second"
  touch -d '10 days ago' "$traversal_target/first" "$traversal_target/second"
  printf 'safe|Traversal|%s|Partial traversal|7||\n' "$traversal_target" > "$TEST_ENV_DIR/traversal.conf"
  [[ "$traversal_sudo" == true ]] && chmod u-r "$traversal_target"
  if ! MOCK_SUDO_UNLOCK_PATH="$traversal_target" MOCK_FIND_FAIL_ROOT="$traversal_target" \
       run_test_case "Trash Traversal Failure ($traversal_sudo)" 1 "traversal_trash.log" \
       --config "$TEST_ENV_DIR/traversal.conf" --trash --force; then
    chmod u+r "$traversal_target"
    exit 1
  fi
  chmod u+r "$traversal_target"
  traversal_meta=$(find "$MOCK_HOME/.cache/linux-cleaner/quarantine" -name quarantine.meta -print -quit)
  traversal_session=$(dirname "$traversal_meta")
  [[ -f "$traversal_session/0_Traversal/first" && -f "$traversal_target/second" ]] \
    && grep -q "Failed to move some files" "$TEST_ENV_DIR/traversal_trash.log" || exit 1

  # Simulate a complete aged payload and an unmatched sibling for selective retry.
  mv "$traversal_target/second" "$traversal_session/0_Traversal/second"
  printf 'sibling\n' > "$traversal_session/1_Sibling"
  printf 'full|1_Sibling|%s|false|%s|%s\n' \
    "$MOCK_HOME/.cache/unmatched_sibling" "$(id -u)" "$(id -g)" >> "$traversal_meta"
  cp "$traversal_meta" "$TEST_ENV_DIR/traversal.meta.before"
  if ! MOCK_FIND_FAIL_ROOT="$traversal_session/0_Traversal" run_test_case "Selective Restore Traversal Failure ($traversal_sudo)" 1 "traversal_restore.log" \
       --restore latest --only /.cache/traversal \
     || ! cmp -s "$traversal_meta" "$TEST_ENV_DIR/traversal.meta.before" \
     || [[ ! -f "$traversal_session/0_Traversal/second" || ! -f "$traversal_target/first" ]]; then
    echo -e "${RED}FAIL: failed traversal discarded payload or recovery metadata.${NC}"
    exit 1
  fi
  if ! run_test_case "Restore Traversal Failure Retry ($traversal_sudo)" 0 "traversal_retry.log" --restore latest \
     || [[ ! -f "$traversal_target/second" || -d "$traversal_session" ]]; then
    echo -e "${RED}FAIL: retry after a traversal failure did not recover the session.${NC}"
    exit 1
  fi
  echo -e "${GREEN}PASS: partial trash/restore traversal fails and preserves retryable state ($traversal_sudo).${NC}"
done

setup_mock_env
purge_failure_base="$MOCK_HOME/.cache/linux-cleaner/quarantine"
mkdir -p "$purge_failure_base/2000-01-01_00-00-00"
printf 'preserve\n' > "$purge_failure_base/2000-01-01_00-00-00/payload"
cat > "$TEST_ENV_DIR/bin/find" <<'PURGE_FIND'
#!/usr/bin/env bash
printf '%s/2000-01-01_00-00-00\n' "$1"
exit 1
PURGE_FIND
chmod +x "$TEST_ENV_DIR/bin/find"
for purge_selector in all latest older-than:30; do
  if ! run_test_case "Purge Enumeration Failure ($purge_selector)" 1 "purge_find_failure.log" \
       --purge-sessions "$purge_selector" --force \
     || ! grep -q 'Failed to enumerate' "$TEST_ENV_DIR/purge_find_failure.log" \
     || ! grep -qx preserve "$purge_failure_base/2000-01-01_00-00-00/payload"; then
    echo -e "${RED}FAIL: purge deleted a partial enumeration or reported success.${NC}"
    exit 1
  fi
done
echo -e "${GREEN}PASS: all purge selectors refuse failed session enumeration without deletion.${NC}"

# A rejected build* source parent must not hide a valid nested build directory;
# accepted parents must still suppress descendant targets, even across siblings.
for filtered_mode in delete trash; do
  setup_mock_env
  filtered_root="$MOCK_HOME/filtered-projects"
  mkdir -p "$filtered_root/app/builder/source/build" \
    "$filtered_root/lib/build/build-inner" "$filtered_root/lib/build-other"
  printf 'source\n' > "$filtered_root/app/builder/source/keep.cpp"
  for build_dir in app/builder/source/build lib/build lib/build/build-inner lib/build-other; do
    printf 'generated\n' > "$filtered_root/$build_dir/CMakeCache.txt"
  done
  cat > "$TEST_ENV_DIR/filtered_nested.conf" <<'FILTERED_NESTED'
safe|Filtered Nested Build|$HOME/filtered-projects/**/build*|Generated build trees only|0||filter:cxx_build
FILTERED_NESTED
  if ! run_test_case "Filtered Nested Build Inventory ($filtered_mode)" 0 "filtered_nested_list.log" \
       --config "$TEST_ENV_DIR/filtered_nested.conf" --list-targets \
     || [[ "$(grep -c '^Filtered Nested Build[[:space:]]' "$TEST_ENV_DIR/filtered_nested_list.log")" -ne 3 ]] \
     || ! grep -qF "$filtered_root/app/builder/source/build" "$TEST_ENV_DIR/filtered_nested_list.log" \
     || grep -qF 'build-inner' "$TEST_ENV_DIR/filtered_nested_list.log"; then
    echo -e "${RED}FAIL: filtered discovery hid a nested build or emitted overlapping targets.${NC}"
    cat "$TEST_ENV_DIR/filtered_nested_list.log"
    exit 1
  fi
  filtered_args=()
  [[ "$filtered_mode" == trash ]] && filtered_args+=(--trash)
  if ! run_test_case "Filtered Nested Build Cleanup ($filtered_mode)" 0 "filtered_nested_clean.log" \
       --config "$TEST_ENV_DIR/filtered_nested.conf" --force "${filtered_args[@]}" \
     || ! grep -qx source "$filtered_root/app/builder/source/keep.cpp" \
     || [[ -e "$filtered_root/app/builder/source/build" || -e "$filtered_root/lib/build" \
           || -e "$filtered_root/lib/build-other" ]]; then
    echo -e "${RED}FAIL: filtered cleanup missed generated output or removed source files.${NC}"
    cat "$TEST_ENV_DIR/filtered_nested_clean.log"
    exit 1
  fi
  echo -e "${GREEN}PASS: filtered recursive $filtered_mode discovers nested builds without overlap or source loss.${NC}"
done

# A readable target holding an unreadable subdirectory must still be measured as
# one integer (du/find exit non-zero there under pipefail), and session listing
# must survive the same layout inside quarantine.
setup_mock_env
unreadable_root="$MOCK_HOME/.cache/partly-unreadable"
unreadable_session="$MOCK_HOME/.cache/linux-cleaner/quarantine/2026-01-01_00-00-00"
mkdir -p "$unreadable_root/locked" "$unreadable_session/0_x/locked"
printf 'readable\n' > "$unreadable_root/readable.txt"
printf 'hidden\n' > "$unreadable_root/locked/hidden.txt"
touch -d '10 days ago' "$unreadable_root/readable.txt"
printf 'full|0_x|%s/gone|false|%s|%s\n' "$MOCK_HOME" "$(id -u)" "$(id -g)" > "$unreadable_session/quarantine.meta"
chmod 000 "$unreadable_root/locked" "$unreadable_session/0_x/locked"
cat > "$TEST_ENV_DIR/unreadable.conf" <<'UNREADABLE'
safe|Partly Unreadable|$HOME/.cache/partly-unreadable|partly unreadable cache|0||
UNREADABLE
cat > "$TEST_ENV_DIR/unreadable_aged.conf" <<'UNREADABLE'
safe|Partly Unreadable Aged|$HOME/.cache/partly-unreadable|partly unreadable cache|5||
UNREADABLE
unreadable_ok=true
if ! run_test_case "Partly Unreadable Dry Run" 0 "unreadable_dry.log" --debug --config "$TEST_ENV_DIR/unreadable.conf" \
   || grep -q 'syntax error' "$TEST_ENV_DIR/unreadable_dry.log" \
   || ! grep -q 'FOUND.*Partly Unreadable ([1-9]' "$TEST_ENV_DIR/unreadable_dry.log"; then
  unreadable_ok=false
fi
if ! run_test_case "Partly Unreadable JSON" 0 "unreadable_json.log" --config "$TEST_ENV_DIR/unreadable.conf" --dry-run --json \
   || ! python3 -m json.tool "$TEST_ENV_DIR/unreadable_json.log" > /dev/null 2>&1; then
  unreadable_ok=false
fi
if ! run_test_case "Partly Unreadable Aged Dry Run" 0 "unreadable_aged.log" --debug --config "$TEST_ENV_DIR/unreadable_aged.conf" \
   || ! grep -q 'FOUND.*Partly Unreadable Aged' "$TEST_ENV_DIR/unreadable_aged.log"; then
  unreadable_ok=false
fi
if ! run_test_case "Partly Unreadable Session List" 0 "unreadable_sessions.log" --list-sessions \
   || ! grep -q '2026-01-01_00-00-00' "$TEST_ENV_DIR/unreadable_sessions.log" \
   || ! run_test_case "Partly Unreadable Session JSON" 0 "unreadable_sessions_json.log" --list-sessions --json \
   || ! python3 -m json.tool "$TEST_ENV_DIR/unreadable_sessions_json.log" > /dev/null 2>&1; then
  unreadable_ok=false
fi
chmod u+rwx "$unreadable_root/locked" "$unreadable_session/0_x/locked"
if [[ "$unreadable_ok" != true ]]; then
  echo -e "${RED}FAIL: a partly unreadable target or session broke size reporting.${NC}"
  cat "$TEST_ENV_DIR"/unreadable_*.log
  exit 1
fi
echo -e "${GREEN}PASS: partly unreadable targets and sessions are measured without aborting.${NC}"

# A CHECK_PROCESSES token carrying glob characters must reach pgrep verbatim,
# whatever files exist in the directory the cleaner is started from.
setup_mock_env
mkdir -p "$MOCK_HOME/.cache/glob-guarded" "$TEST_ENV_DIR/glob-cwd"
printf 'data\n' > "$MOCK_HOME/.cache/glob-guarded/cache.bin"
: > "$TEST_ENV_DIR/glob-cwd/mock_running_p.decoy"
cat > "$TEST_ENV_DIR/glob_guard.conf" <<'GLOB_GUARD'
safe|Glob Guarded|$HOME/.cache/glob-guarded|glob-bearing process token|0|mock_running_p.*|
GLOB_GUARD
if ! (cd "$TEST_ENV_DIR/glob-cwd" && run_test_case "Glob Process Token" 0 "glob_guard.log" \
        --config "$TEST_ENV_DIR/glob_guard.conf") \
   || ! grep -qF "BLOCKED" "$TEST_ENV_DIR/glob_guard.log" \
   || ! grep -qF "'mock_running_p.*'" "$TEST_ENV_DIR/glob_guard.log"; then
  echo -e "${RED}FAIL: a glob-bearing CHECK_PROCESSES token was expanded against the working directory.${NC}"
  cat "$TEST_ENV_DIR/glob_guard.log"
  exit 1
fi
echo -e "${GREEN}PASS: process guard token is not glob-expanded against the working directory.${NC}"

# The runbook validator must not depend on ripgrep, and must fail (not pass
# vacuously) when an example names a flag that --help does not document.
setup_mock_env
validator_bin="$TEST_ENV_DIR/validator-bin"
validator_copy="$TEST_ENV_DIR/validator-copy"
mkdir -p "$validator_bin" "$validator_copy/scripts"
for tool in bash dirname basename cat grep sort; do
  ln -s "$(type -P "$tool")" "$validator_bin/$tool"
done
cp -r "$SCRIPT_DIR/cleaner.sh" "$SCRIPT_DIR/cleaner.1" "$SCRIPT_DIR/RUNBOOK.md" "$SCRIPT_DIR/examples" "$validator_copy/"
cp "$SCRIPT_DIR/scripts/validate-runbook-examples.sh" "$validator_copy/scripts/"
validator_rc=0
env -i HOME="$MOCK_HOME" PATH="$validator_bin" bash "$SCRIPT_DIR/scripts/validate-runbook-examples.sh" \
  > "$TEST_ENV_DIR/validator_ok.log" 2>&1 || validator_rc=$?
printf '\n    cleaner --no-such-flag\n' >> "$validator_copy/RUNBOOK.md"
validator_bad_rc=0
env -i HOME="$MOCK_HOME" PATH="$validator_bin" bash "$validator_copy/scripts/validate-runbook-examples.sh" \
  > "$TEST_ENV_DIR/validator_bad.log" 2>&1 || validator_bad_rc=$?
if [[ "$validator_rc" -ne 0 || "$validator_bad_rc" -eq 0 ]] \
   || ! grep -qF 'missing in help: --no-such-flag' "$TEST_ENV_DIR/validator_bad.log"; then
  echo -e "${RED}FAIL: runbook validator needs ripgrep or passed an undocumented flag.${NC}"
  cat "$TEST_ENV_DIR/validator_ok.log" "$TEST_ENV_DIR/validator_bad.log"
  exit 1
fi
echo -e "${GREEN}PASS: runbook validator runs without ripgrep and rejects an undocumented flag.${NC}"

# Top-level system directories outside the original list stay UNSAFE even with
# --allow-outside-home. Dry-run only: a regression here must never delete a real
# system directory.
setup_mock_env
cat > "$TEST_ENV_DIR/system_dirs.conf" <<'SYSTEM_DIRS'
safe|Top Opt|/opt|top-level system directory|0||
safe|Top Tmp|/tmp/|top-level system directory|0||
safe|Top Mnt|$HOME/../../../../../../../../mnt|dot-dot alias of a system directory|0||
SYSTEM_DIRS
if ! run_test_case "Top-Level System Directories" 0 "system_dirs.log" \
       --config "$TEST_ENV_DIR/system_dirs.conf" --dry-run --allow-outside-home \
   || [[ "$(grep -c 'UNSAFE' "$TEST_ENV_DIR/system_dirs.log")" -ne 3 ]]; then
  echo -e "${RED}FAIL: a top-level system directory was not blocked.${NC}"
  cat "$TEST_ENV_DIR/system_dirs.log"
  exit 1
fi
echo -e "${GREEN}PASS: top-level system directories are UNSAFE even with --allow-outside-home.${NC}"

# Restore and purge outcomes reach the opt-in operation log; without --log no
# log file is created.
setup_mock_env
mkdir -p "$MOCK_HOME/.cache/logged-target"
printf 'cached\n' > "$MOCK_HOME/.cache/logged-target/item.bin"
cat > "$TEST_ENV_DIR/logged.conf" <<'LOGGED'
safe|Logged Target|$HOME/.cache/logged-target|log coverage target|0||
LOGGED
ops_log="$MOCK_HOME/.cache/linux-cleaner/operations.log"
rm -f "$ops_log"
log_ok=true
if ! run_test_case "Log Trash For Restore" 0 "log_trash1.log" --config "$TEST_ENV_DIR/logged.conf" --clean --trash --force \
   || ! run_test_case "Log Restore" 0 "log_restore.log" --restore latest --log \
   || [[ ! -f "$MOCK_HOME/.cache/logged-target/item.bin" ]] \
   || ! run_test_case "Log Trash For Purge" 0 "log_trash2.log" --config "$TEST_ENV_DIR/logged.conf" --clean --trash --force \
   || ! run_test_case "Log Purge" 0 "log_purge.log" --purge-sessions latest --force --log; then
  log_ok=false
fi
if [[ "$log_ok" != true ]] \
   || [[ "$(grep -c "mode=restore .*path='$MOCK_HOME/.cache/logged-target' outcome=success" "$ops_log" 2>/dev/null)" -ne 1 ]] \
   || [[ "$(grep -c "mode=purge session='.*' outcome=success" "$ops_log" 2>/dev/null)" -ne 1 ]] \
   || [[ "$(wc -l < "$ops_log")" -ne 2 ]]; then
  echo -e "${RED}FAIL: purge/restore outcomes were not logged exactly once each.${NC}"
  cat "$ops_log" "$TEST_ENV_DIR"/log_*.log 2>/dev/null
  exit 1
fi
rm -f "$ops_log"
mkdir -p "$MOCK_HOME/.cache/logged-target"
printf 'cached\n' > "$MOCK_HOME/.cache/logged-target/item.bin"
if ! run_test_case "Unlogged Trash" 0 "log_trash3.log" --config "$TEST_ENV_DIR/logged.conf" --clean --trash --force \
   || ! run_test_case "Unlogged Purge" 0 "log_purge2.log" --purge-sessions latest --force \
   || [[ -e "$ops_log" ]]; then
  echo -e "${RED}FAIL: a purge without --log wrote an operation log.${NC}"
  exit 1
fi
echo -e "${GREEN}PASS: purge and restore outcomes are logged only when logging is enabled.${NC}"

# A sudo-owned aged record restores file by file through sudo, restores what it
# can, and leaves a conflicting file (and its record) in quarantine.
setup_mock_env
aged_session="$MOCK_HOME/.cache/linux-cleaner/quarantine/2020-02-02_00-00-00"
aged_dest="$MOCK_HOME/.cache/aged-root-dest"
mkdir -p "$aged_session/0_Aged/sub" "$aged_dest"
printf 'new\n' > "$aged_session/0_Aged/sub/new.txt"
printf 'quarantined\n' > "$aged_session/0_Aged/clash.txt"
printf 'existing\n' > "$aged_dest/clash.txt"
printf 'aged|0_Aged|%s|true|%s|%s\n' "$aged_dest" "$(id -u)" "$(id -g)" > "$aged_session/quarantine.meta"
export MOCK_SUDO_LOG="$TEST_ENV_DIR/sudo_calls.log"
: > "$MOCK_SUDO_LOG"
aged_restore_ok=true
run_test_case "Sudo Aged Restore" 1 "sudo_aged_restore.log" --restore 2020-02-02_00-00-00 || aged_restore_ok=false
unset MOCK_SUDO_LOG
if [[ "$aged_restore_ok" != true ]] \
   || ! grep -qx 'new' "$aged_dest/sub/new.txt" \
   || ! grep -qx 'existing' "$aged_dest/clash.txt" \
   || ! grep -qx 'quarantined' "$aged_session/0_Aged/clash.txt" \
   || ! grep -q '^aged|0_Aged|' "$aged_session/quarantine.meta" \
   || ! grep -q '^mv .*new\.txt' "$TEST_ENV_DIR/sudo_calls.log" \
   || ! grep -q 'Conflict detected' "$TEST_ENV_DIR/sudo_aged_restore.log"; then
  echo -e "${RED}FAIL: sudo-owned aged restore did not route through sudo or mishandled a conflict.${NC}"
  cat "$TEST_ENV_DIR/sudo_aged_restore.log" "$TEST_ENV_DIR/sudo_calls.log"
  exit 1
fi
echo -e "${GREEN}PASS: sudo-owned aged restore moves files through sudo and keeps conflicts quarantined.${NC}"

# A restore whose second record cannot create its destination parent must report
# the failure, keep that record, and drop the record it already restored.
setup_mock_env
mkdir_session="$MOCK_HOME/.cache/linux-cleaner/quarantine/2020-03-03_00-00-00"
mkdir -p "$mkdir_session/0_first" "$mkdir_session/1_second"
printf 'first\n' > "$mkdir_session/0_first/f"
printf 'second\n' > "$mkdir_session/1_second/f"
: > "$MOCK_HOME/.cache/blocker"
printf 'full|0_first|%s/.cache/restored_first|false|%s|%s\nfull|1_second|%s/.cache/blocker/restored_second|false|%s|%s\n' \
  "$MOCK_HOME" "$(id -u)" "$(id -g)" "$MOCK_HOME" "$(id -u)" "$(id -g)" > "$mkdir_session/quarantine.meta"
if ! run_test_case "Restore Mkdir Failure" 1 "restore_mkdir.log" --restore 2020-03-03_00-00-00 \
   || ! grep -qx first "$MOCK_HOME/.cache/restored_first/f" \
   || grep -q '0_first' "$mkdir_session/quarantine.meta" \
   || ! grep -q '1_second' "$mkdir_session/quarantine.meta" \
   || ! grep -q 'Restoration completed with some errors' "$TEST_ENV_DIR/restore_mkdir.log"; then
  echo -e "${RED}FAIL: a restore mkdir failure aborted before metadata reconciliation.${NC}"
  cat "$TEST_ENV_DIR/restore_mkdir.log" "$mkdir_session/quarantine.meta"
  exit 1
fi
echo -e "${GREEN}PASS: restore mkdir failure keeps metadata aligned and reports the error.${NC}"

# A failed sudo authentication for the second record must fail that record only:
# the first record was already restored, so it has to leave the metadata too.
setup_mock_env
auth_session="$MOCK_HOME/.cache/linux-cleaner/quarantine/2020-04-04_00-00-00"
mkdir -p "$auth_session/0_first" "$auth_session/1_second"
printf 'first\n' > "$auth_session/0_first/f"
printf 'second\n' > "$auth_session/1_second/f"
printf 'full|0_first|%s/.cache/auth_first|false|%s|%s\nfull|1_second|%s/.cache/auth_second|true|%s|%s\n' \
  "$MOCK_HOME" "$(id -u)" "$(id -g)" "$MOCK_HOME" "$(id -u)" "$(id -g)" > "$auth_session/quarantine.meta"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TEST_ENV_DIR/bin/sudo"
chmod +x "$TEST_ENV_DIR/bin/sudo"
if ! run_test_case "Restore Sudo Auth Failure" 1 "restore_auth.log" --restore 2020-04-04_00-00-00 \
   || ! grep -qx first "$MOCK_HOME/.cache/auth_first/f" \
   || grep -q '0_first' "$auth_session/quarantine.meta" \
   || ! grep -q '1_second' "$auth_session/quarantine.meta" \
   || [[ ! -f "$auth_session/1_second/f" ]] \
   || ! grep -q 'Restoration completed with some errors' "$TEST_ENV_DIR/restore_auth.log"; then
  echo -e "${RED}FAIL: a failed sudo authentication aborted restore before metadata reconciliation.${NC}"
  cat "$TEST_ENV_DIR/restore_auth.log" "$auth_session/quarantine.meta"
  exit 1
fi
echo -e "${GREEN}PASS: a failed sudo authentication fails only its record and keeps metadata aligned.${NC}"

# A failing chown after a privileged aged quarantine is recorded for that target,
# and the run still processes the next target.
setup_mock_env
chown_target="$MOCK_HOME/.cache/aged-root"
mkdir -p "$chown_target/sub" "$MOCK_HOME/.cache/after-chown"
printf 'old\n' > "$chown_target/sub/old.bin"
touch -d '10 days ago' "$chown_target/sub/old.bin"
printf 'next\n' > "$MOCK_HOME/.cache/after-chown/next.bin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TEST_ENV_DIR/bin/chown"
chmod +x "$TEST_ENV_DIR/bin/chown"
chmod 000 "$chown_target"
export MOCK_SUDO_UNLOCK_PATH="$chown_target"
cat > "$TEST_ENV_DIR/chown_fail.conf" <<'CHOWN_FAIL'
safe|Aged Root|$HOME/.cache/aged-root|privileged aged target|5||
safe|After Chown|$HOME/.cache/after-chown|next target|0||
CHOWN_FAIL
chown_ok=true
run_test_case "Aged Quarantine Chown Failure" 1 "chown_fail.log" \
  --config "$TEST_ENV_DIR/chown_fail.conf" --clean --trash --force || chown_ok=false
unset MOCK_SUDO_UNLOCK_PATH
chmod u+rwx "$chown_target" 2>/dev/null || true
if [[ "$chown_ok" != true ]] \
   || ! grep -q "Failed to move some files for 'Aged Root'" "$TEST_ENV_DIR/chown_fail.log" \
   || [[ -e "$MOCK_HOME/.cache/after-chown" ]]; then
  echo -e "${RED}FAIL: a failing chown aborted the run or went unreported.${NC}"
  cat "$TEST_ENV_DIR/chown_fail.log"
  exit 1
fi
echo -e "${GREEN}PASS: aged quarantine chown failure is recorded and later targets still run.${NC}"

# check-aur-ready must block a PKGBUILD whose checksum is still SKIP, pass a
# pinned one, and stay a no-op without AUR_PREP.
setup_mock_env
for aur_case in skip pinned; do
  mkdir -p "$TEST_ENV_DIR/aur-$aur_case"
  cp "$SCRIPT_DIR/Makefile" "$TEST_ENV_DIR/aur-$aur_case/"
done
sed "s/^sha256sums=.*/sha256sums=('SKIP')/" "$SCRIPT_DIR/PKGBUILD" > "$TEST_ENV_DIR/aur-skip/PKGBUILD"
sed "s/^sha256sums=.*/sha256sums=('$(printf '%064d' 0)')/" "$SCRIPT_DIR/PKGBUILD" > "$TEST_ENV_DIR/aur-pinned/PKGBUILD"
aur_skip_rc=0; AUR_PREP=1 make -s -C "$TEST_ENV_DIR/aur-skip" check-aur-ready >/dev/null 2>&1 || aur_skip_rc=$?
aur_pinned_rc=0; AUR_PREP=1 make -s -C "$TEST_ENV_DIR/aur-pinned" check-aur-ready >/dev/null 2>&1 || aur_pinned_rc=$?
aur_noprep_rc=0; make -s -C "$TEST_ENV_DIR/aur-skip" check-aur-ready >/dev/null 2>&1 || aur_noprep_rc=$?
if [[ "$aur_skip_rc" -eq 0 || "$aur_pinned_rc" -ne 0 || "$aur_noprep_rc" -ne 0 ]]; then
  echo -e "${RED}FAIL: check-aur-ready skip=$aur_skip_rc pinned=$aur_pinned_rc noprep=$aur_noprep_rc (want nonzero/0/0).${NC}"
  exit 1
fi
echo -e "${GREEN}PASS: check-aur-ready rejects a SKIP checksum and accepts a pinned one.${NC}"

# The pacman install scriptlet only prints an opt-in hint: it must never call
# systemctl, and upgrades stay quiet (no post_upgrade).
echo -e "\n${BOLD}Test Case: Package Install Scriptlet Is Hint Only${NC}"
setup_mock_env
install_file=$(awk -F= '/^install=/ {print $2; exit}' "$SCRIPT_DIR/PKGBUILD")
mkdir -p "$TEST_ENV_DIR/scriptlet-bin"
printf '#!/usr/bin/env bash\necho "$*" >> "%s"\n' "$TEST_ENV_DIR/scriptlet-systemctl.calls" > "$TEST_ENV_DIR/scriptlet-bin/systemctl"
chmod +x "$TEST_ENV_DIR/scriptlet-bin/systemctl"
scriptlet_rc=0
scriptlet_out=$(PATH="$TEST_ENV_DIR/scriptlet-bin:$PATH" bash -c '
  set -eu
  . "$1"
  declare -F post_install >/dev/null
  if declare -F post_upgrade >/dev/null; then exit 3; fi
  post_install
' _ "$SCRIPT_DIR/$install_file" 2>&1) || scriptlet_rc=$?
if [[ -n "$install_file" && -f "$SCRIPT_DIR/$install_file" ]] \
   && bash -n "$SCRIPT_DIR/$install_file" \
   && [[ "$scriptlet_rc" -eq 0 ]] \
   && [[ ! -e "$TEST_ENV_DIR/scriptlet-systemctl.calls" ]] \
   && grep -qF "nothing was enabled" <<<"$scriptlet_out" \
   && grep -qF "cleaner --dry-run" <<<"$scriptlet_out" \
   && grep -qF "systemctl --user enable --now linux-cleaner-clean.timer" <<<"$scriptlet_out" \
   && grep -qF "LINUX_CLEANER_TRASH=1" <<<"$scriptlet_out" \
   && grep -qE "^[[:space:]]*install = ${install_file}$" "$SCRIPT_DIR/.SRCINFO"; then
  echo -e "${GREEN}PASS: the install scriptlet prints the opt-in hint, calls no systemctl, and has no post_upgrade.${NC}"
else
  echo -e "${RED}FAIL: install scriptlet '$install_file' rc=$scriptlet_rc is missing, calls systemctl, defines post_upgrade, or lacks the hint.${NC}"
  printf '%s\n' "$scriptlet_out"
  cat "$TEST_ENV_DIR/scriptlet-systemctl.calls" 2>/dev/null
  exit 1
fi

# Debug output: --debug and LINUX_CLEANER_DEBUG expose [FOUND] and [CLEAN] lines; hidden by default and --quiet.
echo -e "\n${BOLD}Test Case: Debug Dry Run Output${NC}"
setup_mock_env
mkdir -p "$MOCK_HOME/debug_clean_target"
echo "recent content" > "$MOCK_HOME/debug_clean_target/recent.txt"
mkdir -p "$MOCK_HOME/debug_found_target" "$TEST_ENV_DIR/debug_outside_target"
echo "found content" > "$MOCK_HOME/debug_found_target/found.txt"
echo "outside content" > "$TEST_ENV_DIR/debug_outside_target/outside.txt"
cat << 'EOF' > "$TEST_ENV_DIR/debug_test.conf"
safe|Clean Age Target|$HOME/debug_clean_target|Clean age target|7||
safe|Missing Target|$HOME/debug_missing_target|Missing target|0||
safe|Debug Found Target|$HOME/debug_found_target|Found target|0||
EOF
echo "safe|Debug Outside Target|$TEST_ENV_DIR/debug_outside_target|Outside HOME target|0||" >> "$TEST_ENV_DIR/debug_test.conf"

PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
  "$CLEANER_SH" --config "$TEST_ENV_DIR/debug_test.conf" --dry-run \
  < /dev/null > "$TEST_ENV_DIR/debug_default.log" 2>&1 || true

PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
  "$CLEANER_SH" --config "$TEST_ENV_DIR/debug_test.conf" --debug --dry-run \
  < /dev/null > "$TEST_ENV_DIR/debug_flag.log" 2>&1 || true

LINUX_CLEANER_DEBUG=1 PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
  "$CLEANER_SH" --config "$TEST_ENV_DIR/debug_test.conf" --dry-run \
  < /dev/null > "$TEST_ENV_DIR/debug_env.log" 2>&1 || true

PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
  "$CLEANER_SH" --config "$TEST_ENV_DIR/debug_test.conf" --debug --quiet --dry-run \
  < /dev/null > "$TEST_ENV_DIR/debug_quiet.log" 2>&1 || true

if grep -qE '(CLEAN|FOUND|REJECTED)\]' "$TEST_ENV_DIR/debug_default.log"; then
  echo -e "${RED}FAIL: default run without --debug printed CLEAN, FOUND or REJECTED lines.${NC}"
  cat "$TEST_ENV_DIR/debug_default.log"
  exit 1
fi

if ! grep -q 'No files older than' "$TEST_ENV_DIR/debug_flag.log" \
   || ! grep -q 'does not exist' "$TEST_ENV_DIR/debug_flag.log" \
   || ! grep -q 'FOUND.*Debug Found Target' "$TEST_ENV_DIR/debug_flag.log" \
   || ! grep -q 'FOUND.*Debug Outside Target.*(outside HOME)' "$TEST_ENV_DIR/debug_flag.log"; then
  echo -e "${RED}FAIL: --debug did not print clean, missing, and FOUND status lines.${NC}"
  cat "$TEST_ENV_DIR/debug_flag.log"
  exit 1
fi

if ! grep -q 'No files older than' "$TEST_ENV_DIR/debug_env.log" \
   || ! grep -q 'does not exist' "$TEST_ENV_DIR/debug_env.log" \
   || ! grep -q 'FOUND.*Debug Found Target' "$TEST_ENV_DIR/debug_env.log" \
   || ! grep -q 'FOUND.*Debug Outside Target.*(outside HOME)' "$TEST_ENV_DIR/debug_env.log"; then
  echo -e "${RED}FAIL: LINUX_CLEANER_DEBUG=1 did not print clean, missing, and FOUND status lines.${NC}"
  cat "$TEST_ENV_DIR/debug_env.log"
  exit 1
fi

if grep -qE '(CLEAN|FOUND|REJECTED)\]' "$TEST_ENV_DIR/debug_quiet.log"; then
  echo -e "${RED}FAIL: --debug --quiet did not suppress CLEAN, FOUND or REJECTED status lines.${NC}"
  cat "$TEST_ENV_DIR/debug_quiet.log"
  exit 1
fi

echo -e "${GREEN}PASS: --debug and LINUX_CLEANER_DEBUG show FOUND and CLEAN lines; default and --quiet suppress them.${NC}"

# Plan report (after the totals line, without --debug) and result report (after cleanup).
setup_mock_env
mkdir -p "$MOCK_HOME/report_found" "$MOCK_HOME/report_old"
echo 'found-bytes' > "$MOCK_HOME/report_found/cache.txt"
echo 'old-bytes' > "$MOCK_HOME/report_old/cache.txt"
touch -d '30 days ago' "$MOCK_HOME/report_old/cache.txt"
cat > "$TEST_ENV_DIR/plan_report.conf" <<'EOF'
safe|Report Found|$HOME/report_found|found cache|0||
safe|Report Old|$HOME/report_old|old cache|3||
EOF

if run_test_case "Plan Report Dry Run" 0 "plan_report.log" \
     --config "$TEST_ENV_DIR/plan_report.conf" --dry-run; then
  plan_totals=$(grep -n 'Total potential space savings' "$TEST_ENV_DIR/plan_report.log" | head -1 | cut -d: -f1)
  plan_header=$(grep -n '^Plan: mode=dry-run risk=safe config=' "$TEST_ENV_DIR/plan_report.log" | head -1 | cut -d: -f1)
  if [[ -n "$plan_totals" && -n "$plan_header" && "$plan_header" -gt "$plan_totals" ]] \
     && awk '
          /^Largest targets:/ { in_largest=1 }
          in_largest && /Report Found/ { found=1 }
          in_largest && /Report Old/ && /files > 3 days/ { aged=1 }
          END { exit !(found && aged) }
        ' "$TEST_ENV_DIR/plan_report.log" \
     && ! grep -q '\[FOUND\]' "$TEST_ENV_DIR/plan_report.log"; then
    echo -e "${GREEN}PASS: dry-run plan report follows the totals and lists found targets without --debug.${NC}"
  else
    echo -e "${RED}FAIL: dry-run plan report missing header, largest targets, or age filter.${NC}"
    cat "$TEST_ENV_DIR/plan_report.log"
    exit 1
  fi
else
  exit 1
fi

if run_test_case "Plan Report Quiet" 0 "plan_report_quiet.log" \
     --config "$TEST_ENV_DIR/plan_report.conf" --quiet --dry-run; then
  if grep -q 'Total potential space savings' "$TEST_ENV_DIR/plan_report_quiet.log" \
     && ! grep -q '^Plan:' "$TEST_ENV_DIR/plan_report_quiet.log" \
     && ! grep -q 'Largest targets:' "$TEST_ENV_DIR/plan_report_quiet.log"; then
    echo -e "${GREEN}PASS: --quiet keeps the savings total and suppresses the plan report.${NC}"
  else
    echo -e "${RED}FAIL: --quiet did not suppress the plan report.${NC}"
    cat "$TEST_ENV_DIR/plan_report_quiet.log"
    exit 1
  fi
else
  exit 1
fi

if run_test_case "Plan Report JSON" 0 "plan_report_json.log" \
     --config "$TEST_ENV_DIR/plan_report.conf" --json --dry-run; then
  if python3 -m json.tool < "$TEST_ENV_DIR/plan_report_json.log" >/dev/null \
     && ! grep -q '^Plan:' "$TEST_ENV_DIR/plan_report_json.log" \
     && ! grep -q 'Largest targets:' "$TEST_ENV_DIR/plan_report_json.log" \
     && ! grep -q '^Result:' "$TEST_ENV_DIR/plan_report_json.log" \
     && ! grep -q 'Reclaimed:' "$TEST_ENV_DIR/plan_report_json.log"; then
    echo -e "${GREEN}PASS: --json output contains no plan or result report text.${NC}"
  else
    echo -e "${RED}FAIL: --json output included report text or was not JSON.${NC}"
    cat "$TEST_ENV_DIR/plan_report_json.log"
    exit 1
  fi
else
  exit 1
fi

if run_test_case "Result Report Clean" 0 "plan_report_clean.log" \
     --config "$TEST_ENV_DIR/plan_report.conf" --clean --force; then
  clean_plan=$(grep -n '^Plan: mode=clean ' "$TEST_ENV_DIR/plan_report_clean.log" | head -1 | cut -d: -f1)
  clean_start=$(grep -n 'Starting cleanup' "$TEST_ENV_DIR/plan_report_clean.log" | head -1 | cut -d: -f1)
  clean_result=$(grep -n '^Result: cleaned=2 skipped=0 failed=0 elapsed=' "$TEST_ENV_DIR/plan_report_clean.log" | head -1 | cut -d: -f1)
  clean_done=$(grep -n 'Cleanup finished!' "$TEST_ENV_DIR/plan_report_clean.log" | head -1 | cut -d: -f1)
  if [[ -n "$clean_plan" && -n "$clean_start" && -n "$clean_result" && -n "$clean_done" \
        && "$clean_plan" -lt "$clean_start" && "$clean_start" -lt "$clean_result" \
        && "$clean_result" -lt "$clean_done" ]] \
     && grep -q 'Reclaimed: quarantined=0 B permanent=' "$TEST_ENV_DIR/plan_report_clean.log" \
     && ! grep -q 'Quarantine session:' "$TEST_ENV_DIR/plan_report_clean.log" \
     && [[ ! -f "$MOCK_HOME/report_found/cache.txt" && ! -f "$MOCK_HOME/report_old/cache.txt" ]]; then
    echo -e "${GREEN}PASS: --clean prints the plan report before cleanup and the result report after it.${NC}"
  else
    echo -e "${RED}FAIL: result report missing cleaned count or printed out of order.${NC}"
    cat "$TEST_ENV_DIR/plan_report_clean.log"
    exit 1
  fi
else
  exit 1
fi

# Last cleanup report: written only after a real cleanup, printed by --report.
setup_mock_env
mkdir -p "$MOCK_HOME/last_report_target"
printf 'bytes\n' > "$MOCK_HOME/last_report_target/cache.txt"
cat > "$TEST_ENV_DIR/last_report.conf" <<'EOF'
safe|Last Report Target|$HOME/last_report_target|last report cache|0||
EOF
report_state_dir="$XDG_STATE_HOME/linux-cleaner"
report_file="$report_state_dir/last-report.txt"

if run_test_case "Last Report Dry Run" 0 "last_report_dry.log" \
     --config "$TEST_ENV_DIR/last_report.conf" --dry-run; then
  if [[ ! -e "$XDG_STATE_HOME" && ! -e "$report_file" ]]; then
    echo -e "${GREEN}PASS: --dry-run does not create the last cleanup report.${NC}"
  else
    echo -e "${RED}FAIL: --dry-run created last-report state.${NC}"
    exit 1
  fi
else
  exit 1
fi

if run_test_case "Last Report Missing" 1 "last_report_missing.log" --report; then
  if grep -q 'No cleanup report yet.' "$TEST_ENV_DIR/last_report_missing.log"; then
    echo -e "${GREEN}PASS: --report exits 1 when no cleanup report has been saved.${NC}"
  else
    echo -e "${RED}FAIL: --report missing-file message was not printed.${NC}"
    cat "$TEST_ENV_DIR/last_report_missing.log"
    exit 1
  fi
else
  exit 1
fi

if run_test_case "Last Report Saved" 0 "last_report_saved.log" \
     --config "$TEST_ENV_DIR/last_report.conf" --clean --force; then
  report_mode=""
  if [[ -d "$report_state_dir" && ! -L "$report_state_dir" ]]; then
    report_mode=$(stat -c '%a' "$report_state_dir")
  fi
  if [[ -f "$report_file" && ! -L "$report_file" && "$report_mode" == 700 ]] \
     && grep -q '^Plan: mode=clean ' "$report_file" \
     && grep -q '^Result: cleaned=' "$report_file" \
     && ! grep -q $'\033' "$report_file"; then
    echo -e "${GREEN}PASS: --clean --force wrote the plan and result into a mode 0700 state dir.${NC}"
  else
    echo -e "${RED}FAIL: last cleanup report missing, colored, or not in a mode 0700 directory (mode='$report_mode').${NC}"
    cat "$report_file" 2>/dev/null || true
    exit 1
  fi
else
  exit 1
fi

if run_test_case "Last Report Print" 0 "last_report_print.log" --report; then
  if diff -q "$report_file" "$TEST_ENV_DIR/last_report_print.log" >/dev/null; then
    echo -e "${GREEN}PASS: --report prints the saved cleanup report and exits 0.${NC}"
  else
    echo -e "${RED}FAIL: --report output did not match the saved report.${NC}"
    cat "$TEST_ENV_DIR/last_report_print.log"
    exit 1
  fi
else
  exit 1
fi

# A later run with nothing to clean replaces the report, so --report never shows a stale run.
if run_test_case "Last Report Nothing To Clean" 0 "last_report_empty.log" \
     --config "$TEST_ENV_DIR/last_report.conf" --clean --force; then
  if grep -q '^Result: nothing to clean' "$report_file" && grep -q '^Saved: ' "$report_file"; then
    echo -e "${GREEN}PASS: a nothing-to-clean run overwrote the saved report.${NC}"
  else
    echo -e "${RED}FAIL: nothing-to-clean run left a stale report.${NC}"
    cat "$report_file" 2>/dev/null || true
    exit 1
  fi
else
  exit 1
fi

mkdir -p "$MOCK_HOME/last_report_target"
printf 'bytes\n' > "$MOCK_HOME/last_report_target/cache.txt"
if run_test_case "Last Report Quiet" 0 "last_report_quiet.log" \
     --config "$TEST_ENV_DIR/last_report.conf" --clean --force --quiet; then
  if ! grep -q '^Plan:' "$TEST_ENV_DIR/last_report_quiet.log" \
     && grep -q '^Result: cleaned=' "$TEST_ENV_DIR/last_report_quiet.log" \
     && grep -q '^Plan: mode=clean ' "$report_file" \
     && grep -q '^Result: cleaned=' "$report_file"; then
    echo -e "${GREEN}PASS: --quiet hides the plan on screen and still saves it.${NC}"
  else
    echo -e "${RED}FAIL: quiet cleanup did not keep the plan in the saved report only.${NC}"
    cat "$TEST_ENV_DIR/last_report_quiet.log"
    cat "$report_file" 2>/dev/null || true
    exit 1
  fi
else
  exit 1
fi

mkdir -p "$MOCK_HOME/last_report_target"
printf 'bytes\n' > "$MOCK_HOME/last_report_target/cache.txt"
symlink_target="$TEST_ENV_DIR/symlink-report-target"
rm -rf "$XDG_STATE_HOME"
mkdir -p "$XDG_STATE_HOME" "$symlink_target"
printf 'untouched\n' > "$symlink_target/marker"
ln -s "$symlink_target" "$XDG_STATE_HOME/linux-cleaner"
if run_test_case "Last Report Symlink" 0 "last_report_symlink.log" \
     --config "$TEST_ENV_DIR/last_report.conf" --clean --force; then
  if grep -q 'state path is a symlink' "$TEST_ENV_DIR/last_report_symlink.log" \
     && [[ -L "$XDG_STATE_HOME/linux-cleaner" ]] \
     && [[ "$(cat "$symlink_target/marker")" == "untouched" ]] \
     && [[ -z "$(find "$symlink_target" -mindepth 1 ! -name marker -print)" ]] \
     && [[ ! -e "$MOCK_HOME/last_report_target/cache.txt" ]]; then
    echo -e "${GREEN}PASS: a symlinked state directory was refused and its target stayed untouched.${NC}"
  else
    echo -e "${RED}FAIL: symlinked state directory was followed or cleanup did not finish.${NC}"
    cat "$TEST_ENV_DIR/last_report_symlink.log"
    find "$symlink_target" -print
    exit 1
  fi
else
  exit 1
fi

if run_test_case "Report With List Sessions Rejected" 1 "last_report_mutex.log" \
     --report --list-sessions; then
  if grep -q 'report cannot be combined' "$TEST_ENV_DIR/last_report_mutex.log"; then
    echo -e "${GREEN}PASS: --report with --list-sessions is rejected.${NC}"
  else
    echo -e "${RED}FAIL: --report with --list-sessions was not rejected.${NC}"
    cat "$TEST_ENV_DIR/last_report_mutex.log"
    exit 1
  fi
else
  exit 1
fi

# User-defined protected paths via protect|PATH config lines: equal, under,
# contains, and wildcard matches are skipped; whole-component sibling is cleaned;
# --debug, --dry-run --json, --list-targets, and --check-config validation work.
setup_mock_env
mkdir -p "$MOCK_HOME/keep/sub" "$MOCK_HOME/parent/keep" "$MOCK_HOME/parent/other" \
         "$MOCK_HOME/keepsake" "$MOCK_HOME/wild/keep_dir" "$MOCK_HOME/wild/clean_dir"
printf 'keep-root\n' > "$MOCK_HOME/keep/file.txt"
printf 'keep-sub\n' > "$MOCK_HOME/keep/sub/file.txt"
printf 'parent-keep\n' > "$MOCK_HOME/parent/keep/file.txt"
printf 'parent-other\n' > "$MOCK_HOME/parent/other/file.txt"
printf 'sibling\n' > "$MOCK_HOME/keepsake/file.txt"
printf 'wild-keep\n' > "$MOCK_HOME/wild/keep_dir/file.txt"
printf 'wild-clean\n' > "$MOCK_HOME/wild/clean_dir/file.txt"

cat > "$TEST_ENV_DIR/protect.conf" <<'EOF'
protect|$HOME/keep
protect|$HOME/parent/keep
protect|$HOME/wild/keep_dir
protect|$HOME/nonexistent_protected
safe|Equal Protected|$HOME/keep|equal protected target|0||
safe|Under Protected|$HOME/keep/sub|under protected target|0||
safe|Contains Protected|$HOME/parent|contains protected target|0||
safe|Wildcard Target|$HOME/wild/*_dir|wildcard target|0||
safe|Sibling Keepsake|$HOME/keepsake|unrelated sibling target|0||
EOF

if ! run_test_case "Protect Check Config Valid" 0 "protect_check.log" \
       --config "$TEST_ENV_DIR/protect.conf" --check-config \
   || ! grep -q '^OK: 5 targets in ' "$TEST_ENV_DIR/protect_check.log"; then
  echo -e "${RED}FAIL: --check-config did not accept valid protect lines or miscounted targets.${NC}"
  cat "$TEST_ENV_DIR/protect_check.log"
  exit 1
fi

if ! run_test_case "Protect List Targets" 0 "protect_lt.log" \
       --config "$TEST_ENV_DIR/protect.conf" --list-targets \
   || grep -q 'protect|' "$TEST_ENV_DIR/protect_lt.log" \
   || grep -q 'nonexistent_protected' "$TEST_ENV_DIR/protect_lt.log" \
   || ! run_test_case "Protect List Targets JSON" 0 "protect_lt_json.log" \
       --config "$TEST_ENV_DIR/protect.conf" --list-targets --json \
   || ! python3 -m json.tool < "$TEST_ENV_DIR/protect_lt_json.log" >/dev/null \
   || grep -q '"risk":"protect"' "$TEST_ENV_DIR/protect_lt_json.log"; then
  echo -e "${RED}FAIL: --list-targets included protect lines or produced invalid JSON.${NC}"
  cat "$TEST_ENV_DIR/protect_lt.log" "$TEST_ENV_DIR/protect_lt_json.log"
  exit 1
fi

if ! run_test_case "Protect Debug Dry Run" 0 "protect_debug.log" \
       --config "$TEST_ENV_DIR/protect.conf" --debug --dry-run \
   || ! grep -qF "  [PROTECTED] Equal Protected: '$MOCK_HOME/keep' is protected by the config. Skipping." "$TEST_ENV_DIR/protect_debug.log" \
   || ! grep -qF "  [PROTECTED] Under Protected: '$MOCK_HOME/keep/sub' is protected by the config. Skipping." "$TEST_ENV_DIR/protect_debug.log" \
   || ! grep -qF "  [PROTECTED] Contains Protected: '$MOCK_HOME/parent' is protected by the config. Skipping." "$TEST_ENV_DIR/protect_debug.log" \
   || ! grep -qF "  [PROTECTED] Wildcard Target: '$MOCK_HOME/wild/keep_dir' is protected by the config. Skipping." "$TEST_ENV_DIR/protect_debug.log" \
   || ! grep -q '^Protected (by config): Equal Protected, Under Protected, Contains Protected, Wildcard Target$' "$TEST_ENV_DIR/protect_debug.log" \
   || ! grep -q 'protected=4' "$TEST_ENV_DIR/protect_debug.log"; then
  echo -e "${RED}FAIL: --debug dry-run did not show [PROTECTED] lines or plan report summary.${NC}"
  cat "$TEST_ENV_DIR/protect_debug.log"
  exit 1
fi

if ! run_test_case "Protect Dry Run JSON" 0 "protect_json.log" \
       --config "$TEST_ENV_DIR/protect.conf" --dry-run --json \
   || ! python3 -m json.tool < "$TEST_ENV_DIR/protect_json.log" >/dev/null \
   || [[ "$(grep -o '"status":"protected"' "$TEST_ENV_DIR/protect_json.log" | wc -l)" -ne 4 ]]; then
  echo -e "${RED}FAIL: --dry-run --json did not emit 4 protected statuses or valid JSON.${NC}"
  cat "$TEST_ENV_DIR/protect_json.log"
  exit 1
fi

if ! run_test_case "Protect Clean Force" 0 "protect_clean.log" \
       --config "$TEST_ENV_DIR/protect.conf" --clean --force \
   || [[ ! -f "$MOCK_HOME/keep/file.txt" ]] \
   || [[ ! -f "$MOCK_HOME/keep/sub/file.txt" ]] \
   || [[ ! -f "$MOCK_HOME/parent/keep/file.txt" ]] \
   || [[ ! -f "$MOCK_HOME/parent/other/file.txt" ]] \
   || [[ ! -f "$MOCK_HOME/wild/keep_dir/file.txt" ]] \
   || [[ -e "$MOCK_HOME/wild/clean_dir" ]] \
   || [[ -e "$MOCK_HOME/keepsake" ]]; then
  echo -e "${RED}FAIL: --clean --force did not preserve protected targets or failed to clean unprotected ones.${NC}"
  cat "$TEST_ENV_DIR/protect_clean.log"
  exit 1
fi
echo -e "${GREEN}PASS: protect|PATH skips equal, under, contains, and wildcard matches while cleaning sibling targets.${NC}"

for bad_case in \
    "empty:protect|" \
    "relative:protect|relative/path" \
    "glob_star:protect|\$HOME/*" \
    "glob_qmark:protect|\$HOME/keep?" \
    "glob_bracket:protect|\$HOME/keep[0-9]" \
    "extra:protect|\$HOME/a|extra"; do
  bad_label="${bad_case%%:*}"
  bad_line="${bad_case#*:}"
  printf "# header\n%s\nsafe|Valid|\$HOME/keepsake|valid|0||\n" "$bad_line" > "$TEST_ENV_DIR/protect_bad_${bad_label}.conf"
  if ! run_test_case "Protect Invalid ($bad_label)" 1 "protect_bad_${bad_label}.log" \
         --config "$TEST_ENV_DIR/protect_bad_${bad_label}.conf" --check-config \
     || ! grep -qF "$TEST_ENV_DIR/protect_bad_${bad_label}.conf:2:" "$TEST_ENV_DIR/protect_bad_${bad_label}.log"; then
    echo -e "${RED}FAIL: --check-config did not reject invalid protect line '$bad_line' with config:line.${NC}"
    cat "$TEST_ENV_DIR/protect_bad_${bad_label}.log"
    exit 1
  fi
done
echo -e "${GREEN}PASS: --check-config rejects malformed protect| lines with file:line errors.${NC}"

# filter:cxx_build with MIN_AGE_DAYS > 0 cleans C++ build directories only when
# idle as a whole; active build trees survive untouched, and non-cxx_build aged
# rows keep per-file age deletion.
setup_mock_env
active_build="$MOCK_HOME/proj/active/build"
idle_build="$MOCK_HOME/proj/idle/build"
aged_plain="$MOCK_HOME/proj/aged_plain"
mkdir -p "$active_build/CMakeFiles" "$idle_build/CMakeFiles" "$aged_plain"
printf 'CMAKE_CACHE_MAJOR_VERSION:INTERNAL=3\n' > "$active_build/CMakeCache.txt"
printf 'old-obj\n' > "$active_build/CMakeFiles/old.o"
printf 'fresh-obj\n' > "$active_build/CMakeFiles/fresh.o"
touch -d '30 days ago' "$active_build/CMakeCache.txt" "$active_build/CMakeFiles/old.o" \
  "$active_build/CMakeFiles" "$active_build"
touch "$active_build/CMakeFiles/fresh.o"

printf 'CMAKE_CACHE_MAJOR_VERSION:INTERNAL=3\n' > "$idle_build/CMakeCache.txt"
printf 'idle-obj\n' > "$idle_build/CMakeFiles/idle.o"
touch -d '30 days ago' "$idle_build/CMakeCache.txt" "$idle_build/CMakeFiles/idle.o" \
  "$idle_build/CMakeFiles" "$idle_build"

printf 'old-cache\n' > "$aged_plain/old.txt"
printf 'new-cache\n' > "$aged_plain/new.txt"
touch -d '30 days ago' "$aged_plain/old.txt"

cat > "$TEST_ENV_DIR/idle_builds.conf" <<'EOF'
safe|Idle Builds|$HOME/proj/**/build*|Per-project build output|14||filter:cxx_build
safe|Aged Plain|$HOME/proj/aged_plain|Per-file aged cache|14||
EOF

if ! run_test_case "Idle Builds Debug Dry Run" 0 "idle_builds_dry.log" \
       --config "$TEST_ENV_DIR/idle_builds.conf" --debug --dry-run \
   || ! grep -q '\[CLEAN\] Idle Builds: active within 14 days\.' "$TEST_ENV_DIR/idle_builds_dry.log" \
   || ! grep -q '\[FOUND\] Idle Builds ' "$TEST_ENV_DIR/idle_builds_dry.log" \
   || ! awk '
        /^Largest targets:/ { in_largest=1 }
        in_largest && /Idle Builds/ && /\(idle > 14 days\)/ { idle_ok=1 }
        in_largest && /Aged Plain/ && /\(files > 14 days\)/ { files_ok=1 }
        END { exit !(idle_ok && files_ok) }
      ' "$TEST_ENV_DIR/idle_builds_dry.log"; then
  echo -e "${RED}FAIL: --debug --dry-run did not report active build as CLEAN, idle build as FOUND, or (idle > 14 days) in plan report.${NC}"
  cat "$TEST_ENV_DIR/idle_builds_dry.log"
  exit 1
fi

if ! run_test_case "Idle Builds Clean Force" 0 "idle_builds_clean.log" \
       --config "$TEST_ENV_DIR/idle_builds.conf" --clean --force \
   || [[ ! -f "$active_build/CMakeCache.txt" ]] \
   || [[ ! -f "$active_build/CMakeFiles/old.o" ]] \
   || [[ ! -f "$active_build/CMakeFiles/fresh.o" ]] \
   || [[ -e "$idle_build" ]] \
   || [[ -e "$aged_plain/old.txt" ]] \
   || [[ ! -f "$aged_plain/new.txt" ]]; then
  echo -e "${RED}FAIL: --clean --force did not preserve active build whole, remove idle build whole, or keep per-file age semantics on plain row.${NC}"
  cat "$TEST_ENV_DIR/idle_builds_clean.log"
  exit 1
fi
echo -e "${GREEN}PASS: filter:cxx_build idle threshold preserves active build trees whole, removes idle build trees whole, and keeps per-file age deletion on other rows.${NC}"

# Symlink target with trailing slashes: strip_trailing_slashes removes all
# trailing slashes so a symlink target is refused as [SYMLINK] and its referent
# outside HOME survives --clean --force and --clean --force --trash.
echo -e "\n${BOLD}Test Case: Symlink Target Trailing Slashes${NC}"
for link_spelling in 'link' 'link/' 'link//' 'link////'; do
  setup_mock_env
  printf 'x\n' > "$OUTSIDE_DIR/referent.txt"
  ln -s "$OUTSIDE_DIR" "$MOCK_HOME/link"
  printf "safe|T|\$HOME/%s|d|0||\n" "$link_spelling" > "$TEST_ENV_DIR/symlink_slashes.conf"
  if ! run_test_case "Symlink Trailing Slashes Dry Run ($link_spelling)" 0 "symlink_slashes_dry.log" \
         --config "$TEST_ENV_DIR/symlink_slashes.conf" --dry-run --debug \
     || ! grep -q '\[SYMLINK\] T: Refusing to delete symlink target' "$TEST_ENV_DIR/symlink_slashes_dry.log" \
     || grep -q '\[FOUND\]' "$TEST_ENV_DIR/symlink_slashes_dry.log" \
     || ! run_test_case "Symlink Trailing Slashes Clean ($link_spelling)" 0 "symlink_slashes_clean.log" \
         --config "$TEST_ENV_DIR/symlink_slashes.conf" --clean --force \
     || [[ ! -L "$MOCK_HOME/link" || ! -f "$OUTSIDE_DIR/referent.txt" ]] \
     || ! run_test_case "Symlink Trailing Slashes Trash ($link_spelling)" 0 "symlink_slashes_trash.log" \
         --config "$TEST_ENV_DIR/symlink_slashes.conf" --clean --force --trash \
     || [[ ! -L "$MOCK_HOME/link" || ! -f "$OUTSIDE_DIR/referent.txt" ]]; then
    echo -e "${RED}FAIL: symlink target '$link_spelling' bypassed [SYMLINK] guard or deleted referent.${NC}"
    cat "$TEST_ENV_DIR"/symlink_slashes_*.log 2>/dev/null || true
    exit 1
  fi
done
echo -e "${GREEN}PASS: symlink targets with one or more trailing slashes are refused as [SYMLINK] and leave referent and link intact.${NC}"

# Quarantine session and base directories are created mode 0700 even under
# umask 022 and a 0755 HOME/.cache, for both aged and full targets.
echo -e "\n${BOLD}Test Case: Quarantine Session And Base Mode 0700${NC}"
setup_mock_env
chmod 755 "$MOCK_HOME" "$MOCK_HOME/.cache"
mkdir -p "$MOCK_HOME/aged_target/priv"
chmod 700 "$MOCK_HOME/aged_target/priv"
printf 'secret\n' > "$MOCK_HOME/aged_target/priv/old.txt"
chmod 644 "$MOCK_HOME/aged_target/priv/old.txt"
touch -d '10 days ago' "$MOCK_HOME/aged_target/priv/old.txt"
cat > "$TEST_ENV_DIR/umask_aged.conf" <<'EOF'
safe|Aged Private|$HOME/aged_target|aged target with private subdir|7||
EOF
aged_umask_ec=0
(
  umask 022
  PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" "$CLEANER_SH" \
    --config "$TEST_ENV_DIR/umask_aged.conf" --clean --force --trash \
    < /dev/null > "$TEST_ENV_DIR/umask_aged.log" 2>&1
) || aged_umask_ec=$?
q_base="$MOCK_HOME/.cache/linux-cleaner/quarantine"
aged_sess=$(find "$q_base" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n 1)
if [[ "$aged_umask_ec" -ne 0 || -z "$aged_sess" ]] \
   || [[ "$(stat -c %a "$MOCK_HOME/.cache/linux-cleaner")" != "700" ]] \
   || [[ "$(stat -c %a "$q_base")" != "700" ]] \
   || [[ "$(stat -c %a "$aged_sess")" != "700" ]] \
   || [[ ! -f "$aged_sess/0_Aged_Private/priv/old.txt" ]]; then
  echo -e "${RED}FAIL: aged quarantine under umask 022 did not create 0700 base and session directories.${NC}"
  cat "$TEST_ENV_DIR/umask_aged.log" 2>/dev/null || true
  exit 1
fi

setup_mock_env
chmod 755 "$MOCK_HOME" "$MOCK_HOME/.cache"
mkdir -p "$MOCK_HOME/full_target"
printf 'full-secret\n' > "$MOCK_HOME/full_target/item.txt"
chmod 644 "$MOCK_HOME/full_target/item.txt"
cat > "$TEST_ENV_DIR/umask_full.conf" <<'EOF'
safe|Full Target|$HOME/full_target|full target|0||
EOF
full_umask_ec=0
(
  umask 022
  PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" "$CLEANER_SH" \
    --config "$TEST_ENV_DIR/umask_full.conf" --clean --force --trash \
    < /dev/null > "$TEST_ENV_DIR/umask_full.log" 2>&1
) || full_umask_ec=$?
full_sess=$(find "$q_base" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n 1)
if [[ "$full_umask_ec" -ne 0 || -z "$full_sess" ]] \
   || [[ "$(stat -c %a "$q_base")" != "700" ]] \
   || [[ "$(stat -c %a "$full_sess")" != "700" ]] \
   || [[ ! -f "$full_sess/0_Full_Target/item.txt" ]]; then
  echo -e "${RED}FAIL: full quarantine under umask 022 did not create 0700 base and session directories.${NC}"
  cat "$TEST_ENV_DIR/umask_full.log" 2>/dev/null || true
  exit 1
fi
echo -e "${GREEN}PASS: quarantine base and session directories are mode 0700 under umask 022 for aged and full targets.${NC}"

# Restore refuses symlink conflicts at the original path (full and aged) or any
# intermediate directory component between an aged record's original path and
# the destination file's parent, leaving quarantined files intact, logging
# outcome=conflict, and succeeding after the symlink is removed.
echo -e "\n${BOLD}Test Case: Restore Symlink Conflicts${NC}"
# (a) Aged record whose emptied sub directory is replaced by a symlink before restore.
setup_mock_env
mkdir -p "$MOCK_HOME/aged_sym_sub/sub/nested" "$MOCK_HOME/other_mock_dir"
printf 'aged-sub-payload\n' > "$MOCK_HOME/aged_sym_sub/sub/nested/old.txt"
touch -d '10 days ago' "$MOCK_HOME/aged_sym_sub/sub/nested/old.txt"
cat > "$TEST_ENV_DIR/aged_sym_sub.conf" <<'EOF'
safe|Aged Sym Sub|$HOME/aged_sym_sub|aged target with subdir|7||
EOF
ops_log="$MOCK_HOME/.cache/linux-cleaner/operations.log"
rm -f "$ops_log"
if ! run_test_case "Quarantine Aged Sub Symlink" 0 "q_aged_sym_sub.log" \
       --config "$TEST_ENV_DIR/aged_sym_sub.conf" --clean --force --trash; then
  exit 1
fi
q_base="$MOCK_HOME/.cache/linux-cleaner/quarantine"
aged_sub_sess=$(find "$q_base" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1)
ln -s "$MOCK_HOME/other_mock_dir" "$MOCK_HOME/aged_sym_sub/sub"
if ! run_test_case "Restore Aged Subdir Symlink Conflict" 1 "r_aged_sym_sub_conflict.log" \
       --restore latest --log \
   || ! grep -q "Conflict detected" "$TEST_ENV_DIR/r_aged_sym_sub_conflict.log" \
   || [[ -n "$(find "$MOCK_HOME/other_mock_dir" -mindepth 1 -print -quit)" ]] \
   || [[ ! -f "$aged_sub_sess/0_Aged_Sym_Sub/sub/nested/old.txt" ]] \
   || [[ ! -d "$aged_sub_sess" ]] \
   || ! grep -qF "|$MOCK_HOME/aged_sym_sub|" "$aged_sub_sess/quarantine.meta" \
   || ! grep -q "mode=restore .*path='$MOCK_HOME/aged_sym_sub' outcome=conflict" "$ops_log"; then
  echo -e "${RED}FAIL: aged restore followed a symlinked subdir or failed to preserve session/log conflict.${NC}"
  cat "$TEST_ENV_DIR/r_aged_sym_sub_conflict.log" "$ops_log" 2>/dev/null || true
  exit 1
fi
rm -f "$MOCK_HOME/aged_sym_sub/sub"
if ! run_test_case "Restore Aged Subdir Symlink Retry" 0 "r_aged_sym_sub_retry.log" \
       --restore latest \
   || [[ ! -f "$MOCK_HOME/aged_sym_sub/sub/nested/old.txt" ]] \
   || ! grep -qx "aged-sub-payload" "$MOCK_HOME/aged_sym_sub/sub/nested/old.txt" \
   || [[ -d "$aged_sub_sess" ]]; then
  echo -e "${RED}FAIL: second restore after removing subdir symlink did not restore file or retire session.${NC}"
  cat "$TEST_ENV_DIR/r_aged_sym_sub_retry.log" 2>/dev/null || true
  exit 1
fi

# (b) Aged record whose original path itself is replaced by a symlink before restore.
setup_mock_env
mkdir -p "$MOCK_HOME/aged_sym_orig/sub" "$MOCK_HOME/other_orig_dir"
printf 'aged-orig-payload\n' > "$MOCK_HOME/aged_sym_orig/sub/old.txt"
touch -d '10 days ago' "$MOCK_HOME/aged_sym_orig/sub/old.txt"
cat > "$TEST_ENV_DIR/aged_sym_orig.conf" <<'EOF'
safe|Aged Sym Orig|$HOME/aged_sym_orig|aged target whose root becomes symlink|7||
EOF
ops_log="$MOCK_HOME/.cache/linux-cleaner/operations.log"
rm -f "$ops_log"
if ! run_test_case "Quarantine Aged Orig Symlink" 0 "q_aged_sym_orig.log" \
       --config "$TEST_ENV_DIR/aged_sym_orig.conf" --clean --force --trash; then
  exit 1
fi
aged_orig_sess=$(find "$q_base" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1)
rmdir "$MOCK_HOME/aged_sym_orig"
ln -s "$MOCK_HOME/other_orig_dir" "$MOCK_HOME/aged_sym_orig"
if ! run_test_case "Restore Aged Original Path Symlink Conflict" 1 "r_aged_sym_orig_conflict.log" \
       --restore latest --log \
   || ! grep -q "Conflict detected" "$TEST_ENV_DIR/r_aged_sym_orig_conflict.log" \
   || [[ -n "$(find "$MOCK_HOME/other_orig_dir" -mindepth 1 -print -quit)" ]] \
   || [[ ! -f "$aged_orig_sess/0_Aged_Sym_Orig/sub/old.txt" ]] \
   || [[ ! -d "$aged_orig_sess" ]] \
   || ! grep -qF "|$MOCK_HOME/aged_sym_orig|" "$aged_orig_sess/quarantine.meta" \
   || ! grep -q "mode=restore .*path='$MOCK_HOME/aged_sym_orig' outcome=conflict" "$ops_log"; then
  echo -e "${RED}FAIL: aged restore followed a symlinked original path or failed to preserve session/log conflict.${NC}"
  cat "$TEST_ENV_DIR/r_aged_sym_orig_conflict.log" "$ops_log" 2>/dev/null || true
  exit 1
fi
rm -f "$MOCK_HOME/aged_sym_orig"
if ! run_test_case "Restore Aged Original Path Symlink Retry" 0 "r_aged_sym_orig_retry.log" \
       --restore latest \
   || [[ ! -f "$MOCK_HOME/aged_sym_orig/sub/old.txt" ]] \
   || ! grep -qx "aged-orig-payload" "$MOCK_HOME/aged_sym_orig/sub/old.txt" \
   || [[ -d "$aged_orig_sess" ]]; then
  echo -e "${RED}FAIL: second restore after removing original-path symlink did not restore file or retire session.${NC}"
  cat "$TEST_ENV_DIR/r_aged_sym_orig_retry.log" 2>/dev/null || true
  exit 1
fi

# (c) Full record whose original path became a symlink before restore.
setup_mock_env
mkdir -p "$MOCK_HOME/full_sym_orig" "$MOCK_HOME/other_full_dir"
printf 'full-orig-payload\n' > "$MOCK_HOME/full_sym_orig/item.txt"
cat > "$TEST_ENV_DIR/full_sym_orig.conf" <<'EOF'
safe|Full Sym Orig|$HOME/full_sym_orig|full target whose root becomes symlink|0||
EOF
ops_log="$MOCK_HOME/.cache/linux-cleaner/operations.log"
rm -f "$ops_log"
if ! run_test_case "Quarantine Full Orig Symlink" 0 "q_full_sym_orig.log" \
       --config "$TEST_ENV_DIR/full_sym_orig.conf" --clean --force --trash; then
  exit 1
fi
full_orig_sess=$(find "$q_base" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1)
ln -s "$MOCK_HOME/other_full_dir" "$MOCK_HOME/full_sym_orig"
if ! run_test_case "Restore Full Original Path Symlink Conflict" 1 "r_full_sym_orig_conflict.log" \
       --restore latest --log \
   || ! grep -q "Conflict detected" "$TEST_ENV_DIR/r_full_sym_orig_conflict.log" \
   || [[ -n "$(find "$MOCK_HOME/other_full_dir" -mindepth 1 -print -quit)" ]] \
   || [[ ! -f "$full_orig_sess/0_Full_Sym_Orig/item.txt" ]] \
   || [[ ! -d "$full_orig_sess" ]] \
   || ! grep -qF "|$MOCK_HOME/full_sym_orig|" "$full_orig_sess/quarantine.meta" \
   || ! grep -q "mode=restore .*path='$MOCK_HOME/full_sym_orig' outcome=conflict" "$ops_log"; then
  echo -e "${RED}FAIL: full restore followed a symlinked original path or failed to preserve session/log conflict.${NC}"
  cat "$TEST_ENV_DIR/r_full_sym_orig_conflict.log" "$ops_log" 2>/dev/null || true
  exit 1
fi
echo -e "${GREEN}PASS: restore rejects symlink conflicts on full and aged original paths and aged intermediate directories.${NC}"

# In a pattern containing "**", only a "**" component may span multiple
# directory levels; "*" and "?" must match within a single component only,
# and a rejected parent candidate must not prune a valid deeper match.
echo -e "\n${BOLD}Test Case: Wildcard Component Matching With Globstar${NC}"
setup_mock_env
for rel_dir in \
    "glob/p/app/one/build" \
    "glob/p/q/app/one/build" \
    "glob/p/app/one/extra/build" \
    "glob/p/app/one/extra/app/two/build" \
    "glob2/a/x/m/build" \
    "glob2/a/b/x/m/build"; do
  mkdir -p "$MOCK_HOME/$rel_dir"
  printf 'payload\n' > "$MOCK_HOME/$rel_dir/out.o"
done
cat > "$TEST_ENV_DIR/glob_comp.conf" <<'EOF'
safe|Glob App Build|$HOME/glob/**/app/*/build|globstar before single-component star|0||
safe|Glob2 Build|$HOME/glob2/*/x/**/b?ild|single-component star before globstar and qmark|0||
EOF

if ! run_test_case "Wildcard Component Matching Dry Run" 0 "glob_comp_dry.log" \
       --config "$TEST_ENV_DIR/glob_comp.conf" --dry-run --debug \
   || [[ "$(grep -c '\[FOUND\] Glob App Build ' "$TEST_ENV_DIR/glob_comp_dry.log")" -ne 3 ]] \
   || [[ "$(grep -c '\[FOUND\] Glob2 Build ' "$TEST_ENV_DIR/glob_comp_dry.log")" -ne 1 ]] \
   || ! grep -qF "Glob App Build $MOCK_HOME/glob/p/app/one/build" "$TEST_ENV_DIR/glob_comp_dry.log" \
   || ! grep -qF "Glob App Build $MOCK_HOME/glob/p/q/app/one/build" "$TEST_ENV_DIR/glob_comp_dry.log" \
   || ! grep -qF "Glob App Build $MOCK_HOME/glob/p/app/one/extra/app/two/build" "$TEST_ENV_DIR/glob_comp_dry.log" \
   || grep -qE "Glob App Build $MOCK_HOME/glob/p/app/one/extra/build$" "$TEST_ENV_DIR/glob_comp_dry.log" \
   || ! grep -qF "Glob2 Build $MOCK_HOME/glob2/a/x/m/build" "$TEST_ENV_DIR/glob_comp_dry.log" \
   || grep -qF "$MOCK_HOME/glob2/a/b/x/m/build" "$TEST_ENV_DIR/glob_comp_dry.log" \
   || [[ "$(grep -c '\[FOUND\]' "$TEST_ENV_DIR/glob_comp_dry.log")" -ne 4 ]]; then
  echo -e "${RED}FAIL: wildcard component matching with '**' selected multi-component '*' matches or pruned a valid deeper match.${NC}"
  cat "$TEST_ENV_DIR/glob_comp_dry.log"
  exit 1
fi
echo -e "${GREEN}PASS: '**' spans multiple directory levels while '*' and '?' match single components only.${NC}"

# User-level prune actions (uv, pnpm, hf): run directly as the user without sudo,
# skip when the binary is absent, block when the process is running, never run in
# dry-run, credit df free-space delta instead of planned du, and keep system
# actions routed through sudo.
echo -e "\n${BOLD}Test Case: User-Level Prune Actions${NC}"

# 1. --clean --force runs each user action with exact argv, zero sudo calls, no "requires root".
setup_mock_env
mkdir -p "$MOCK_HOME/.cache/uv" "$MOCK_HOME/.local/share/pnpm/store" "$MOCK_HOME/.cache/huggingface/hub"
printf 'uv-entry\n' > "$MOCK_HOME/.cache/uv/entry.bin"
printf 'pnpm-entry\n' > "$MOCK_HOME/.local/share/pnpm/store/entry.bin"
printf 'hf-entry\n' > "$MOCK_HOME/.cache/huggingface/hub/entry.bin"
cat > "$TEST_ENV_DIR/bin/sudo" <<'FAIL_SUDO'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_ENV_DIR/sudo_unexpected.calls"
exit 1
FAIL_SUDO
chmod +x "$TEST_ENV_DIR/bin/sudo"
cat > "$TEST_ENV_DIR/user_actions.conf" <<'EOF'
safe|UV Cache|$HOME/.cache/uv|uv package manager cache (uv cache prune: unreachable entries only)|0|uv|action:uv_cache_prune
safe|PNPM Store|$HOME/.local/share/pnpm/store|pnpm content-addressable store (pnpm store prune: unreferenced packages only)|0|pnpm|action:pnpm_store_prune
safe|Hugging Face Cache|$HOME/.cache/huggingface/hub|Hugging Face hub cache (hf cache prune: detached revisions and incomplete downloads only)|0|hf|action:hf_cache_prune
EOF
export MOCK_USER_ACTION_LOG="$TEST_ENV_DIR/user_action.calls"
: > "$MOCK_USER_ACTION_LOG"
rm -f "$TEST_ENV_DIR/sudo_unexpected.calls"
if ! run_test_case "User Actions Clean Force Without Sudo" 0 "user_actions_clean.log" \
       --config "$TEST_ENV_DIR/user_actions.conf" --clean --force \
   || [[ -e "$TEST_ENV_DIR/sudo_unexpected.calls" ]] \
   || grep -qi "requires root" "$TEST_ENV_DIR/user_actions_clean.log" \
   || grep -qF "[FOUND] UV Cache" "$TEST_ENV_DIR/user_actions_clean.log" \
   || ! cmp -s "$MOCK_USER_ACTION_LOG" <(printf 'uv cache prune --cache-dir %s\npnpm store prune --store-dir %s\nhf cache prune --yes --cache-dir %s\n' \
          "$(realpath "$MOCK_HOME/.cache/uv")" \
          "$(realpath "$MOCK_HOME/.local/share/pnpm/store")" \
          "$(realpath "$MOCK_HOME/.cache/huggingface/hub")") \
   || ! grep -q '^Result: cleaned=3 skipped=0 failed=0 ' "$TEST_ENV_DIR/user_actions_clean.log"; then
  echo -e "${RED}FAIL: user actions did not run with exact argv, invoked sudo, or reported requires root.${NC}"
  cat "$TEST_ENV_DIR/user_actions_clean.log" "$MOCK_USER_ACTION_LOG" "$TEST_ENV_DIR/sudo_unexpected.calls" 2>/dev/null || true
  exit 1
fi
unset MOCK_USER_ACTION_LOG
echo -e "${GREEN}PASS: user-level prune actions run with exact argv, zero sudo calls, and no 'requires root'.${NC}"

# 2. Missing binary skips its row cleanly (no failure, exits 0, no sudo calls).
setup_mock_env
mkdir -p "$MOCK_HOME/.cache/uv" "$MOCK_HOME/.local/share/pnpm/store" "$MOCK_HOME/.cache/huggingface/hub"
user_missing_bin="$TEST_ENV_DIR/user_missing_bin"
mkdir -p "$user_missing_bin"
for tool in bash basename cat dirname realpath sed du df awk tr id sort find stat date rm mktemp pgrep; do
  ln -s "$(command -v "$tool")" "$user_missing_bin/$tool"
done
ln -s "$TEST_ENV_DIR/bin/uv" "$user_missing_bin/uv"
ln -s "$TEST_ENV_DIR/bin/hf" "$user_missing_bin/hf"
# pnpm intentionally omitted from user_missing_bin
cat > "$user_missing_bin/sudo" <<'FAIL_SUDO2'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_ENV_DIR/sudo_missing_unexpected.calls"
exit 1
FAIL_SUDO2
chmod +x "$user_missing_bin/sudo"
cat > "$TEST_ENV_DIR/user_actions.conf" <<'EOF'
safe|UV Cache|$HOME/.cache/uv|uv package manager cache (uv cache prune: unreachable entries only)|0|uv|action:uv_cache_prune
safe|PNPM Store|$HOME/.local/share/pnpm/store|pnpm content-addressable store (pnpm store prune: unreferenced packages only)|0|pnpm|action:pnpm_store_prune
safe|Hugging Face Cache|$HOME/.cache/huggingface/hub|Hugging Face hub cache (hf cache prune: detached revisions and incomplete downloads only)|0|hf|action:hf_cache_prune
EOF
export MOCK_USER_ACTION_LOG="$TEST_ENV_DIR/user_missing.calls"
: > "$MOCK_USER_ACTION_LOG"
echo -e "\n${BOLD}Test Case: User Actions Missing Binary Skips Cleanly${NC}"
missing_ec=0
PATH="$user_missing_bin" HOME="$MOCK_HOME" "$CLEANER_SH" \
  --config "$TEST_ENV_DIR/user_actions.conf" --clean --force \
  < /dev/null > "$TEST_ENV_DIR/user_actions_missing.log" 2>&1 || missing_ec=$?
unset MOCK_USER_ACTION_LOG
if [[ "$missing_ec" -ne 0 ]] \
   || [[ -e "$TEST_ENV_DIR/sudo_missing_unexpected.calls" ]] \
   || ! grep -q "PNPM Store: skipped: 'pnpm' not available on this platform." "$TEST_ENV_DIR/user_actions_missing.log" \
   || ! cmp -s "$TEST_ENV_DIR/user_missing.calls" <(printf 'uv cache prune --cache-dir %s\nhf cache prune --yes --cache-dir %s\n' \
          "$(realpath "$MOCK_HOME/.cache/uv")" \
          "$(realpath "$MOCK_HOME/.cache/huggingface/hub")") \
   || ! grep -q '^Result: cleaned=2 skipped=1 failed=0 ' "$TEST_ENV_DIR/user_actions_missing.log"; then
  echo -e "${RED}FAIL: missing user-action binary did not skip cleanly (ec=$missing_ec).${NC}"
  cat "$TEST_ENV_DIR/user_actions_missing.log" "$TEST_ENV_DIR/user_missing.calls" 2>/dev/null || true
  exit 1
fi
echo -e "${GREEN}PASS: a missing user-action binary skips its row cleanly and exits 0.${NC}"

# 3. A running process of that name blocks the row via CHECK_PROCESSES.
setup_mock_env
mkdir -p "$MOCK_HOME/.cache/uv" "$MOCK_HOME/.local/share/pnpm/store" "$MOCK_HOME/.cache/huggingface/hub"
cat > "$TEST_ENV_DIR/bin/pgrep" <<'PGREP_UV'
#!/usr/bin/env bash
if [[ "$1" == "-x" && "$2" == "uv" ]]; then
  exit 0
fi
exit 1
PGREP_UV
chmod +x "$TEST_ENV_DIR/bin/pgrep"
cat > "$TEST_ENV_DIR/user_actions.conf" <<'EOF'
safe|UV Cache|$HOME/.cache/uv|uv package manager cache (uv cache prune: unreachable entries only)|0|uv|action:uv_cache_prune
safe|PNPM Store|$HOME/.local/share/pnpm/store|pnpm content-addressable store (pnpm store prune: unreferenced packages only)|0|pnpm|action:pnpm_store_prune
safe|Hugging Face Cache|$HOME/.cache/huggingface/hub|Hugging Face hub cache (hf cache prune: detached revisions and incomplete downloads only)|0|hf|action:hf_cache_prune
EOF
export MOCK_USER_ACTION_LOG="$TEST_ENV_DIR/user_blocked.calls"
: > "$MOCK_USER_ACTION_LOG"
if ! run_test_case "User Actions Blocked By Running Process" 0 "user_actions_blocked.log" \
       --config "$TEST_ENV_DIR/user_actions.conf" --clean --force \
   || ! grep -q "BLOCKED.*UV Cache: Skip cleanup because process 'uv' is active." "$TEST_ENV_DIR/user_actions_blocked.log" \
   || ! cmp -s "$MOCK_USER_ACTION_LOG" <(printf 'pnpm store prune --store-dir %s\nhf cache prune --yes --cache-dir %s\n' \
          "$(realpath "$MOCK_HOME/.local/share/pnpm/store")" \
          "$(realpath "$MOCK_HOME/.cache/huggingface/hub")") \
   || ! grep -q '^Targets: found=2 .* blocked=1 ' "$TEST_ENV_DIR/user_actions_blocked.log"; then
  echo -e "${RED}FAIL: running 'uv' process did not block UV Cache row.${NC}"
  cat "$TEST_ENV_DIR/user_actions_blocked.log" "$MOCK_USER_ACTION_LOG" 2>/dev/null || true
  exit 1
fi
unset MOCK_USER_ACTION_LOG
echo -e "${GREEN}PASS: running process blocks its user-action row while siblings still run.${NC}"

# 4. --dry-run invokes none of the mocks and reports 0 B reclaimable with run-time size message.
setup_mock_env
mkdir -p "$MOCK_HOME/.cache/uv" "$MOCK_HOME/.local/share/pnpm/store" "$MOCK_HOME/.cache/huggingface/hub"
truncate -s 3M "$MOCK_HOME/.cache/uv/large.bin"
cat > "$TEST_ENV_DIR/user_actions.conf" <<'EOF'
safe|UV Cache|$HOME/.cache/uv|uv package manager cache (uv cache prune: unreachable entries only)|0|uv|action:uv_cache_prune
safe|PNPM Store|$HOME/.local/share/pnpm/store|pnpm content-addressable store (pnpm store prune: unreferenced packages only)|0|pnpm|action:pnpm_store_prune
safe|Hugging Face Cache|$HOME/.cache/huggingface/hub|Hugging Face hub cache (hf cache prune: detached revisions and incomplete downloads only)|0|hf|action:hf_cache_prune
EOF
export MOCK_USER_ACTION_LOG="$TEST_ENV_DIR/user_dry.calls"
: > "$MOCK_USER_ACTION_LOG"
if ! run_test_case "User Actions Dry Run Invokes No Mocks" 0 "user_actions_dry.log" \
       --config "$TEST_ENV_DIR/user_actions.conf" --dry-run --debug \
   || [[ -s "$MOCK_USER_ACTION_LOG" ]] \
   || ! grep -qF "[FOUND] UV Cache: size measured at run time (uv cache prune)" "$TEST_ENV_DIR/user_actions_dry.log" \
   || ! grep -qF "[FOUND] PNPM Store: size measured at run time (pnpm store prune)" "$TEST_ENV_DIR/user_actions_dry.log" \
   || ! grep -qF "[FOUND] Hugging Face Cache: size measured at run time (hf cache prune --yes)" "$TEST_ENV_DIR/user_actions_dry.log" \
   || ! grep -q "Total potential space savings: .*0 B" "$TEST_ENV_DIR/user_actions_dry.log" \
   || ! grep -q "^Reclaimable by risk: safe=0 B medium=0 B danger=0 B$" "$TEST_ENV_DIR/user_actions_dry.log" \
   || ! grep -q "^  (size at run time) safe UV Cache " "$TEST_ENV_DIR/user_actions_dry.log" \
   || grep -q "^  0 B safe UV Cache " "$TEST_ENV_DIR/user_actions_dry.log"; then
  echo -e "${RED}FAIL: --dry-run invoked user-action mocks or credited directory du to potential space savings.${NC}"
  cat "$TEST_ENV_DIR/user_actions_dry.log" "$MOCK_USER_ACTION_LOG" 2>/dev/null || true
  exit 1
fi
unset MOCK_USER_ACTION_LOG
echo -e "${GREEN}PASS: --dry-run invokes none of the user-action mocks and contributes 0 B to planned savings.${NC}"

# 5. Result does not credit planned du; credits df free-space delta (clamped at 0) and warns under --trash.
setup_mock_env
mkdir -p "$MOCK_HOME/.cache/uv" "$MOCK_HOME/.local/share/pnpm/store" "$MOCK_HOME/.cache/huggingface/hub"
# Create a real 4 MB file that the mock does NOT delete; planned du would be >= 4 MB.
dd if=/dev/zero of="$MOCK_HOME/.cache/uv/hardlinked_blob.bin" bs=1M count=4 status=none
# Mock df with deterministic before/after available bytes so the test is immune to background FS noise:
# First call (before uv) -> 10000000, second call (after uv) -> 10000000 (0 B freed, despite 4 MB du).
# Third call (before pnpm) -> 20000000, fourth call (after pnpm) -> 21048576 (1 MB = 1048576 B freed).
# Fifth call (before hf) -> 30000000, sixth call (after hf) -> 29000000 (negative delta -> clamped to 0 B).
cat > "$TEST_ENV_DIR/bin/df" <<'MOCK_DF'
#!/usr/bin/env bash
count_file="$TEST_ENV_DIR/df_call_count"
n=0
[[ -f "$count_file" ]] && n=$(cat "$count_file")
n=$((n + 1))
echo "$n" > "$count_file"
case "$n" in
  1) avail=10000000 ;;
  2) avail=10000000 ;;
  3) avail=20000000 ;;
  4) avail=21048576 ;;
  5) avail=30000000 ;;
  *) avail=29000000 ;;
esac
printf 'Avail\n%s\n' "$avail"
MOCK_DF
chmod +x "$TEST_ENV_DIR/bin/df"
cat > "$TEST_ENV_DIR/user_actions_size.conf" <<'EOF'
safe|UV Cache|$HOME/.cache/uv|uv package manager cache (uv cache prune: unreachable entries only)|0|uv|action:uv_cache_prune
safe|PNPM Store|$HOME/.local/share/pnpm/store|pnpm content-addressable store (pnpm store prune: unreferenced packages only)|0|pnpm|action:pnpm_store_prune
safe|Hugging Face Cache|$HOME/.cache/huggingface/hub|Hugging Face hub cache (hf cache prune: detached revisions and incomplete downloads only)|0|hf|action:hf_cache_prune
EOF
if ! run_test_case "User Actions Credit DF Delta Not Planned DU" 0 "user_actions_size.log" \
       --config "$TEST_ENV_DIR/user_actions_size.conf" --clean --force --trash \
   || [[ ! -f "$MOCK_HOME/.cache/uv/hardlinked_blob.bin" ]] \
   || ! grep -q "bypass quarantine and run directly (irreversible deletion)" "$TEST_ENV_DIR/user_actions_size.log" \
   || ! grep -q '^Reclaimed: quarantined=0 B permanent=1 MB$' "$TEST_ENV_DIR/user_actions_size.log" \
   || grep -q '4 MB' "$TEST_ENV_DIR/user_actions_size.log"; then
  echo -e "${RED}FAIL: user action credited planned du instead of df delta, failed negative clamping, or missed trash warning.${NC}"
  cat "$TEST_ENV_DIR/user_actions_size.log"
  exit 1
fi
echo -e "${GREEN}PASS: user actions credit df free-space delta (clamped at 0), never planned du, and warn under --trash.${NC}"

# 6. A system action (paccache) still goes through sudo and credits planned du alongside a user action.
setup_mock_env
mkdir -p "$MOCK_HOME/.cache/uv" "$OUTSIDE_DIR/paccache_pkg"
dd if=/dev/zero of="$OUTSIDE_DIR/paccache_pkg/pkg.tar.zst" bs=1M count=2 status=none
export MOCK_SUDO_LOG="$TEST_ENV_DIR/sudo_system.calls"
export MOCK_USER_ACTION_LOG="$TEST_ENV_DIR/user_system.calls"
: > "$MOCK_SUDO_LOG"
: > "$MOCK_USER_ACTION_LOG"
cat > "$TEST_ENV_DIR/mixed_actions.conf" <<EOF
safe|UV Cache|\$HOME/.cache/uv|uv cache|0|uv|action:uv_cache_prune
medium|Pacman Cache (Keep 1)|$OUTSIDE_DIR/paccache_pkg|pacman cache|0||action:paccache_keep1
EOF
if ! run_test_case "System Action Still Uses Sudo Alongside User Action" 0 "mixed_actions.log" \
       --config "$TEST_ENV_DIR/mixed_actions.conf" --clean --force --risk medium \
   || ! grep -qx "paccache -rk1" "$MOCK_SUDO_LOG" \
   || grep -q "uv" "$MOCK_SUDO_LOG" \
   || ! grep -qx "uv cache prune --cache-dir $(realpath "$MOCK_HOME/.cache/uv")" "$MOCK_USER_ACTION_LOG" \
   || ! grep -q '^Result: cleaned=2 skipped=0 failed=0 ' "$TEST_ENV_DIR/mixed_actions.log"; then
  echo -e "${RED}FAIL: system action did not route through sudo or user action leaked into sudo.${NC}"
  cat "$TEST_ENV_DIR/mixed_actions.log" "$MOCK_SUDO_LOG" "$MOCK_USER_ACTION_LOG" 2>/dev/null || true
  exit 1
fi
unset MOCK_SUDO_LOG MOCK_USER_ACTION_LOG
echo -e "${GREEN}PASS: system action still routes through sudo while user action runs directly as the user.${NC}"

# 7. --interactive shows "size at run time" rather than 0 B for user-level prune actions.
setup_mock_env
mkdir -p "$MOCK_HOME/.cache/uv"
printf 'uv-entry\n' > "$MOCK_HOME/.cache/uv/entry.bin"
cat > "$TEST_ENV_DIR/user_action_interactive.conf" <<'EOF'
safe|UV Cache|$HOME/.cache/uv|uv package manager cache (uv cache prune: unreachable entries only)|0|uv|action:uv_cache_prune
EOF
echo -e "\n${BOLD}Test Case: User Action Interactive Shows Run-Time Size${NC}"
inter_log="$TEST_ENV_DIR/user_action_interactive.log"
inter_ec=0
printf 'y\n' | PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" "$CLEANER_SH" \
  --config "$TEST_ENV_DIR/user_action_interactive.conf" --interactive > "$inter_log" 2>&1 || inter_ec=$?
if [[ $inter_ec -eq 0 ]] \
   && grep -q "Clean target 'UV Cache' (size at run time) at" "$inter_log" \
   && ! grep -q "Clean target 'UV Cache' (0 B)" "$inter_log"; then
  echo -e "${GREEN}PASS: --interactive shows 'size at run time' for user-level prune actions.${NC}"
else
  echo -e "${RED}FAIL: --interactive did not show 'size at run time' for user-level prune action (ec=$inter_ec).${NC}"
  cat "$inter_log"
  exit 1
fi

echo -e "\n${BOLD}${GREEN}All refactored tests passed successfully!${NC}"
exit 0
