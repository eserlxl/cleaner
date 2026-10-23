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
if [[ "$1" == "-x" && ${#2} -gt 15 && "$2" =~ ^[[:alnum:]._-]+$ ]]; then
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

  # User-level prune action mocks (uv, pnpm, hf, nix-store)
  local _uact
  for _uact in uv pnpm hf nix-store; do
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

  cat << 'EOF' > "$TEST_ENV_DIR/bin/systemctl"
#!/usr/bin/env bash
# Mock systemctl command
echo "not-found"
exit 4
EOF
  chmod +x "$TEST_ENV_DIR/bin/systemctl"

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

# A work tree whose index cannot be read fails closed and skips the target.
setup_mock_env
mkdir -p "$MOCK_HOME/proj/build" "$MOCK_HOME/plain-build"
printf 'cache\n' > "$MOCK_HOME/proj/build/CMakeCache.txt"
printf 'source\n' > "$MOCK_HOME/proj/build/tracked.c"
printf 'output\n' > "$MOCK_HOME/plain-build/output.bin"
HOME="$MOCK_HOME" git init -q "$MOCK_HOME/proj"
HOME="$MOCK_HOME" git -C "$MOCK_HOME/proj" config user.name 'Cleaner Test'
HOME="$MOCK_HOME" git -C "$MOCK_HOME/proj" config user.email 'cleaner-test@example.invalid'
HOME="$MOCK_HOME" git -C "$MOCK_HOME/proj" add -- build/tracked.c
HOME="$MOCK_HOME" git -C "$MOCK_HOME/proj" -c commit.gpgsign=false -c core.hooksPath=/dev/null \
  commit -qm 'Track source in build tree'
printf 'corrupt index\n' > "$MOCK_HOME/proj/.git/index"
cat > "$TEST_ENV_DIR/git_guard_corrupt.conf" <<'GIT_GUARD_CORRUPT'
safe|Corrupt Repo Build|$HOME/proj/build|Build tree in repo with corrupt index|0||filter:cxx_build
safe|Corrupt Repo File|$HOME/proj/build/tracked.c|Single file in repo with corrupt index|0||
safe|Plain Build|$HOME/plain-build|Outside any repository|0||
GIT_GUARD_CORRUPT
if ! run_test_case "Git-Tracked Target Guard Corrupt Index JSON" 0 "git_guard_corrupt_json.log" \
     --config "$TEST_ENV_DIR/git_guard_corrupt.conf" --json --dry-run \
   || ! python3 - "$TEST_ENV_DIR/git_guard_corrupt_json.log" "$MOCK_HOME" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
home = sys.argv[2]
targets = {target["path"]: target for target in data["targets"]}
for path in (home + "/proj/build", home + "/proj/build/tracked.c"):
    assert targets[path]["status"] == "skipped", targets[path]
    assert targets[path]["reason"] == "git-tracked check failed", targets[path]
    assert targets[path]["bytes"] == 0, targets[path]
assert targets[home + "/plain-build"]["status"] == "found", targets[home + "/plain-build"]
PY
then
  echo -e "${RED}FAIL: Corrupt git index targets were not skipped with 'git-tracked check failed' in JSON dry-run.${NC}"
  cat "$TEST_ENV_DIR/git_guard_corrupt_json.log"
  exit 1
fi
if ! run_test_case "Git-Tracked Target Guard Corrupt Index" 0 "git_guard_corrupt.log" \
     --config "$TEST_ENV_DIR/git_guard_corrupt.conf" --force \
   || ! grep -qF "[SKIP] Corrupt Repo Build: skipped: git-tracked check failed." "$TEST_ENV_DIR/git_guard_corrupt.log" \
   || ! grep -qF "[SKIP] Corrupt Repo File: skipped: git-tracked check failed." "$TEST_ENV_DIR/git_guard_corrupt.log" \
   || [[ ! -f "$MOCK_HOME/proj/build/tracked.c" || ! -f "$MOCK_HOME/proj/build/CMakeCache.txt" \
      || -e "$MOCK_HOME/plain-build" ]]; then
  echo -e "${RED}FAIL: Corrupt git index target was cleaned or plain target was preserved.${NC}"
  cat "$TEST_ENV_DIR/git_guard_corrupt.log"
  exit 1
fi
echo -e "${GREEN}PASS: Corrupt git index fails closed with [SKIP] and preserves work-tree targets.${NC}"

# A repository git refuses (dubious ownership) fails closed and skips the target.
setup_mock_env
mkdir -p "$MOCK_HOME/proj/build" "$MOCK_HOME/plain-build"
printf 'cache\n' > "$MOCK_HOME/proj/build/CMakeCache.txt"
printf 'source\n' > "$MOCK_HOME/proj/build/tracked.c"
printf 'output\n' > "$MOCK_HOME/plain-build/output.bin"
HOME="$MOCK_HOME" git init -q "$MOCK_HOME/proj"
HOME="$MOCK_HOME" git -C "$MOCK_HOME/proj" config user.name 'Cleaner Test'
HOME="$MOCK_HOME" git -C "$MOCK_HOME/proj" config user.email 'cleaner-test@example.invalid'
HOME="$MOCK_HOME" git -C "$MOCK_HOME/proj" add -- build/tracked.c
HOME="$MOCK_HOME" git -C "$MOCK_HOME/proj" -c commit.gpgsign=false -c core.hooksPath=/dev/null \
  commit -qm 'Track source in build tree'
cat > "$TEST_ENV_DIR/git_guard_dubious.conf" <<'GIT_GUARD_DUBIOUS'
safe|Dubious Repo Build|$HOME/proj/build|Build tree in repo git refuses|0||filter:cxx_build
safe|Dubious Repo File|$HOME/proj/build/tracked.c|Single file in repo git refuses|0||
safe|Plain Build|$HOME/plain-build|Outside any repository|0||
GIT_GUARD_DUBIOUS
# Stop repository discovery at the test directory: the suite may run inside a
# checkout, and the refused-owner switch would otherwise refuse that outer repo too.
export GIT_TEST_ASSUME_DIFFERENT_OWNER=1 GIT_CEILING_DIRECTORIES="$TEST_ENV_DIR"
if ! run_test_case "Git-Tracked Target Guard Dubious Ownership JSON" 0 "git_guard_dubious_json.log" \
     --config "$TEST_ENV_DIR/git_guard_dubious.conf" --json --dry-run \
   || ! python3 - "$TEST_ENV_DIR/git_guard_dubious_json.log" "$MOCK_HOME" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
home = sys.argv[2]
targets = {target["path"]: target for target in data["targets"]}
for path in (home + "/proj/build", home + "/proj/build/tracked.c"):
    assert targets[path]["status"] == "skipped", targets[path]
    assert targets[path]["reason"] == "git-tracked check failed", targets[path]
    assert targets[path]["bytes"] == 0, targets[path]
assert targets[home + "/plain-build"]["status"] == "found", targets[home + "/plain-build"]
PY
then
  unset GIT_TEST_ASSUME_DIFFERENT_OWNER GIT_CEILING_DIRECTORIES
  echo -e "${RED}FAIL: Dubious-ownership targets were not skipped with 'git-tracked check failed' in JSON dry-run.${NC}"
  cat "$TEST_ENV_DIR/git_guard_dubious_json.log"
  exit 1
fi
if ! run_test_case "Git-Tracked Target Guard Dubious Ownership" 0 "git_guard_dubious.log" \
     --config "$TEST_ENV_DIR/git_guard_dubious.conf" --dry-run \
   || ! grep -qF "[SKIP] Dubious Repo Build: skipped: git-tracked check failed." "$TEST_ENV_DIR/git_guard_dubious.log" \
   || ! grep -qF "[SKIP] Dubious Repo File: skipped: git-tracked check failed." "$TEST_ENV_DIR/git_guard_dubious.log" \
   || ! grep -qF "Targets: found=1 " "$TEST_ENV_DIR/git_guard_dubious.log" \
   || [[ ! -f "$MOCK_HOME/proj/build/tracked.c" || ! -f "$MOCK_HOME/proj/build/CMakeCache.txt" \
      || ! -e "$MOCK_HOME/plain-build" ]]; then
  unset GIT_TEST_ASSUME_DIFFERENT_OWNER GIT_CEILING_DIRECTORIES
  echo -e "${RED}FAIL: Dubious-ownership dry-run did not skip the refused repository or skipped the non-repo target.${NC}"
  cat "$TEST_ENV_DIR/git_guard_dubious.log"
  exit 1
fi
unset GIT_TEST_ASSUME_DIFFERENT_OWNER GIT_CEILING_DIRECTORIES
echo -e "${GREEN}PASS: Dubious ownership fails closed with [SKIP]; a non-repo target stays found.${NC}"

# A readable outside-HOME target under an unwritable parent still runs the unprivileged git-tracked guard.
setup_mock_env
mkdir -p "$OUTSIDE_DIR/proj/sub/build"
printf 'source\n' > "$OUTSIDE_DIR/proj/sub/build/tracked.c"
HOME="$MOCK_HOME" git init -q "$OUTSIDE_DIR/proj"
HOME="$MOCK_HOME" git -C "$OUTSIDE_DIR/proj" config user.name 'Cleaner Test'
HOME="$MOCK_HOME" git -C "$OUTSIDE_DIR/proj" config user.email 'cleaner-test@example.invalid'
HOME="$MOCK_HOME" git -C "$OUTSIDE_DIR/proj" add -- sub/build/tracked.c
HOME="$MOCK_HOME" git -C "$OUTSIDE_DIR/proj" -c commit.gpgsign=false -c core.hooksPath=/dev/null \
  commit -qm 'Track source under unwritable parent'
chmod 555 "$OUTSIDE_DIR/proj/sub"
cat > "$TEST_ENV_DIR/git_guard_sudo_readable.conf" <<GIT_GUARD_SUDO_READABLE
safe|Readable Sudo Repo Build|$OUTSIDE_DIR/proj/sub/build|Readable build under unwritable parent|0||
GIT_GUARD_SUDO_READABLE
if ! run_test_case "Git-Tracked Target Guard Readable Sudo Target" 0 "git_guard_sudo_readable.log" \
     --config "$TEST_ENV_DIR/git_guard_sudo_readable.conf" --force \
   || ! grep -qF "[SKIP] Readable Sudo Repo Build: skipped: contains 1 git-tracked file(s) under '$OUTSIDE_DIR/proj/sub/build'." \
     "$TEST_ENV_DIR/git_guard_sudo_readable.log" \
   || [[ ! -f "$OUTSIDE_DIR/proj/sub/build/tracked.c" ]]; then
  chmod 755 "$OUTSIDE_DIR/proj/sub" 2>/dev/null || true
  echo -e "${RED}FAIL: Readable sudo target with git-tracked file was not skipped or tracked file was removed.${NC}"
  cat "$TEST_ENV_DIR/git_guard_sudo_readable.log"
  exit 1
fi
chmod 755 "$OUTSIDE_DIR/proj/sub"
echo -e "${GREEN}PASS: Readable sudo target under an unwritable parent preserves git-tracked files.${NC}"

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

# Complete global lists must retain later patterns and appended row protection.
python3 - "$CLEANER_SH" <<'EXCLUSION_LIST_PY'
import hashlib, json, os, pathlib, stat, subprocess, sys, tempfile, time
cleaner = sys.argv[1]
with tempfile.TemporaryDirectory(prefix="cleaner-exclusion-list-", dir="/tmp") as directory:
    root = pathlib.Path(directory)
    home = root / "home"
    first, second = home / "first", home / "second"
    first.mkdir(parents=True)
    second.mkdir()
    for parent, files in ((first, {"keep-a": 19, "keep-b": 29, "row.keep": 41, "eligible": 7,
                                  "keep-a\nkeep-b": 13, "fresh": 5}),
                          (second, {"row.keep": 43, "eligible": 3})):
        for name, size in files.items():
            path = parent / name
            path.write_bytes(b"p" * size)
            if name != "fresh":
                os.utime(path, (time.time() - 30 * 86400,) * 2)
    state = home / "state/linux-cleaner"
    state.mkdir(parents=True)
    (state / "last-report.txt").write_text("keep report metadata\n")
    quarantine = home / ".cache/linux-cleaner/quarantine/2099-01-01_00-00-00"
    quarantine.mkdir(parents=True)
    (quarantine / "quarantine.meta").write_text("keep recovery metadata\n")
    (quarantine / "payload").write_text("keep recovery payload\n")
    config = root / "exclusion.conf"
    bindir = root / "bin"
    bindir.mkdir()
    trace = root / "forbidden-calls"
    for command in ("rm", "mv", "flock", "sudo", "uv", "pnpm", "hf", "pacman"):
        stub = bindir / command
        stub.write_text('#!/bin/sh\nprintf "%s\\n" "$0" >> "$EXCLUSION_TRACE"\nexit 99\n')
        stub.chmod(0o755)
    env = {k: v for k, v in os.environ.items() if not k.startswith(("LINUX_CLEANER_", "XDG_"))}
    env.update(HOME=str(home), XDG_STATE_HOME=str(home / "state"), NO_COLOR="1",
               PATH=str(bindir) + ":" + env["PATH"], EXCLUSION_TRACE=str(trace))
    def snapshot():
        return {str(p.relative_to(home)): (stat.S_IMODE(p.stat().st_mode), p.stat().st_mtime_ns,
                hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else None)
                for p in home.rglob("*")}
    before = snapshot()
    # Expected first-target sizes include the fresh 5 bytes only at age zero.
    cases = [
        ("CLI control", ["--exclude", "keep-a,keep-b"], {}, 20),
        ("CLI comma LF", ["--exclude", "keep-a,\nkeep-b"], {}, 20),
        ("environment comma LF", [], {"LINUX_CLEANER_EXCLUDE": "keep-a,\nkeep-b"}, 20),
        ("CLI internal LF literal", ["--exclude", "keep-a\nkeep-b"], {}, 55),
        ("environment internal LF literal", [], {"LINUX_CLEANER_EXCLUDE": "keep-a\nkeep-b"}, 55),
        ("later comma fields", ["--exclude", "absent,\nkeep-a,keep-b"], {}, 20),
        ("empty entries ignored", ["--exclude", ",keep-a,\n,,keep-b,,"], {}, 20),
        ("all empty entries ignored", ["--exclude", ",\n,,"], {}, 68),
        ("CLI overrides environment", ["--exclude", "keep-a,\nkeep-b"], {"LINUX_CLEANER_EXCLUDE": "keep-a\nkeep-b"}, 20),
    ]
    for age in (0, 7):
        config.write_text("safe|Row Protected|$HOME/first|row composition|" + str(age) + "||exclude:row.keep\n"
                          "safe|Next Target|$HOME/second|row reset|" + str(age) + "||\n")
        for label, args, overrides, old_bytes in cases:
            print("Test Case: Complete Exclusion List " + label + " age " + str(age), flush=True)
            result = subprocess.run([cleaner, "--config", str(config), "--dry-run", "--json"] + args,
                                    env=env | overrides, capture_output=True, text=True, timeout=20)
            assert result.returncode == 0, (label, age, result)
            data = json.loads(result.stdout)
            expected = old_bytes + (5 if age == 0 else 0)
            targets = data["targets"]
            assert [(t["name"], t["bytes"], t["status"]) for t in targets] == [
                ("Row Protected", expected, "found"), ("Next Target", 46, "found")], (label, age, targets)
            assert data["total_reclaimable_bytes"] == expected + 46, (label, age, data)
            assert snapshot() == before and not trace.exists(), "preview changed data/metadata or invoked mutation tools"
            print("PASS: Complete Exclusion List " + label + " age " + str(age), flush=True)
EXCLUSION_LIST_PY

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

# Targets above the risk ceiling are named without contributing reclaimable bytes.
mkdir -p "$MOCK_HOME/.cache"
truncate -s 32 "$MOCK_HOME/.cache/risk-safe.bin"
truncate -s 64 "$MOCK_HOME/.cache/risk-medium.bin"
truncate -s 128 "$MOCK_HOME/.cache/risk-danger.bin"
mkdir -p "$MOCK_HOME/.cache/risk-wild-a" "$MOCK_HOME/.cache/risk-wild-b"
cat > "$TEST_ENV_DIR/hidden_risk.conf" <<'EOF'
safe|Visible Cache|$HOME/.cache/risk-safe.bin|safe cache|0||
medium|Hidden Cache|$HOME/.cache/risk-medium.bin|medium cache|0||
medium|Wild Cache|$HOME/.cache/risk-wild-*|wildcard row named once|0||
medium|Browser, GPU|$HOME/.cache/risk-browser-gpu|name holding the separator|0||
medium|GPU|$HOME/.cache/risk-gpu|distinct name inside another|0||
danger|Danger Cache|$HOME/.cache/risk-danger.bin|danger cache|0||
EOF
# case#args#expected Above line#expected Hidden line (empty Above = neither line)
while IFS='#' read -r hidden_risk_case hidden_risk_arg hidden_risk_above hidden_risk_names; do
  hidden_risk_args=()
  case "$hidden_risk_arg" in
    risk-medium) hidden_risk_args=(--risk medium) ;;
    no-danger) hidden_risk_args=(--exclude-target 'Danger Cache') ;;
    only-safe) hidden_risk_args=(--only-target 'Visible Cache') ;;
    risk-danger) hidden_risk_args=(--risk danger) ;;
  esac
  if ! run_test_case "Hidden Risk ($hidden_risk_case)" 0 "hidden_risk.log" \
       --config "$TEST_ENV_DIR/hidden_risk.conf" --dry-run "${hidden_risk_args[@]}"; then
    echo -e "${RED}FAIL: hidden risk dry run ($hidden_risk_case) failed.${NC}"
    exit 1
  fi
  if [[ -n "$hidden_risk_above" ]]; then
    if ! grep -qFx "Above --risk $hidden_risk_above" "$TEST_ENV_DIR/hidden_risk.log" \
       || ! grep -qFx "Hidden by risk: $hidden_risk_names" "$TEST_ENV_DIR/hidden_risk.log" \
       || ! grep -q '^Reclaimable by risk: .* danger=0 B$' "$TEST_ENV_DIR/hidden_risk.log" \
       || { [[ "$hidden_risk_above" == safe* ]] && ! grep -q ' medium=0 B danger' "$TEST_ENV_DIR/hidden_risk.log"; }; then
      echo -e "${RED}FAIL: hidden risk lines wrong ($hidden_risk_case).${NC}"
      cat "$TEST_ENV_DIR/hidden_risk.log"
      exit 1
    fi
  elif grep -qE '^(Above --risk |Hidden by risk:)' "$TEST_ENV_DIR/hidden_risk.log"; then
    echo -e "${RED}FAIL: hidden risk lines appeared with nothing above the ceiling ($hidden_risk_case).${NC}"
    exit 1
  fi
done <<'HIDDEN_RISK_CASES'
default##safe (not analysed): medium=5 danger=1; preview with --risk danger#Hidden Cache, Wild Cache, Browser, GPU, GPU, Danger Cache
medium#risk-medium#medium (not analysed): medium=0 danger=1; preview with --risk danger#Danger Cache
no-danger#no-danger#safe (not analysed): medium=5 danger=0; preview with --risk medium#Hidden Cache, Wild Cache, Browser, GPU, GPU
only-safe#only-safe##
danger#risk-danger##
HIDDEN_RISK_CASES
echo -e "${GREEN}PASS: the plan names targets above the risk ceiling without sizing them.${NC}"

# Blocked targets report an in-use size without adding it to the savings total.
mkdir -p "$MOCK_HOME/.cache"
truncate -s 2M "$MOCK_HOME/.cache/in-use-held.bin"
cat > "$TEST_ENV_DIR/in_use_held.conf" <<'EOF'
safe|Held Cache|$HOME/.cache/in-use-held.bin|cache held by a running process|0|mock_running_proc|
EOF
if run_test_case "Blocked Target In-Use Size Dry Run" 0 "in_use_held.log" \
     --config "$TEST_ENV_DIR/in_use_held.conf" --dry-run; then
  if grep -qF "Skip cleanup because process 'mock_running_proc' is active; 2 MB would be reclaimable otherwise." "$TEST_ENV_DIR/in_use_held.log" \
     && grep -qF "Held by active processes: 2 MB (not counted above)" "$TEST_ENV_DIR/in_use_held.log" \
     && grep -qF "Blocked (process 'mock_running_proc' is active): Held Cache (2 MB)" "$TEST_ENV_DIR/in_use_held.log" \
     && grep -qF "In use: blocked=1 would_reclaim=2 MB" "$TEST_ENV_DIR/in_use_held.log" \
     && grep -qF "Total potential space savings: 0 B" "$TEST_ENV_DIR/in_use_held.log" \
     && awk '
          /Reclaimable by risk:/ { risk=NR }
          /In use: blocked=1 would_reclaim=2 MB/ && !seen { inuse=NR; seen=1 }
          END { exit !(risk && inuse && inuse > risk) }
        ' "$TEST_ENV_DIR/in_use_held.log"; then
    echo -e "${GREEN}PASS: blocked target shows its in-use size and leaves it out of the savings total.${NC}"
  else
    echo -e "${RED}FAIL: blocked in-use size missing from the status line, held line, or plan report.${NC}"
    cat "$TEST_ENV_DIR/in_use_held.log"
    exit 1
  fi
else
  exit 1
fi
if run_test_case "Blocked Target In-Use Size JSON Unchanged" 0 "in_use_held.json" \
     --config "$TEST_ENV_DIR/in_use_held.conf" --dry-run --json \
   && python3 - "$TEST_ENV_DIR/in_use_held.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert data["total_reclaimable_bytes"] == 0, data
target = data["targets"][0]
assert target["name"] == "Held Cache" and target["status"] == "blocked", target
assert target["bytes"] == 0, target
PY
then
  echo -e "${GREEN}PASS: blocked in-use size stays out of JSON bytes and total_reclaimable_bytes.${NC}"
else
  echo -e "${RED}FAIL: blocked in-use size changed the JSON bytes contract.${NC}"
  cat "$TEST_ENV_DIR/in_use_held.json"
  exit 1
fi

# A missing path and an action row are not measurable, so they add no in-use size.
mkdir -p "$MOCK_HOME/.cache/in-use-action"
truncate -s 2M "$MOCK_HOME/.cache/in-use-action/blob.bin"
cat > "$TEST_ENV_DIR/in_use_unmeasurable.conf" <<'EOF'
safe|Missing Blocked|$HOME/.cache/in-use-missing|path does not exist|0|mock_running_proc|
safe|Action Blocked|$HOME/.cache/in-use-action|user action|0|mock_running_proc|action:uv_cache_prune
EOF
if run_test_case "Blocked Target Unmeasurable In-Use Size" 0 "in_use_unmeasurable.log" \
     --config "$TEST_ENV_DIR/in_use_unmeasurable.conf" --dry-run; then
  if grep -qF "Missing Blocked: Skip cleanup because process 'mock_running_proc' is active." "$TEST_ENV_DIR/in_use_unmeasurable.log" \
     && grep -qF "Action Blocked: Skip cleanup because process 'mock_running_proc' is active." "$TEST_ENV_DIR/in_use_unmeasurable.log" \
     && grep -qF "Blocked (process 'mock_running_proc' is active): Missing Blocked, Action Blocked" "$TEST_ENV_DIR/in_use_unmeasurable.log" \
     && ! grep -q "would be reclaimable otherwise" "$TEST_ENV_DIR/in_use_unmeasurable.log" \
     && ! grep -qF "Held by active processes:" "$TEST_ENV_DIR/in_use_unmeasurable.log" \
     && ! grep -q '^In use:' "$TEST_ENV_DIR/in_use_unmeasurable.log"; then
    echo -e "${GREEN}PASS: missing and action blocked targets show no in-use size.${NC}"
  else
    echo -e "${RED}FAIL: unmeasurable blocked target showed an in-use size.${NC}"
    cat "$TEST_ENV_DIR/in_use_unmeasurable.log"
    exit 1
  fi
else
  exit 1
fi

# A real run records the plan-blocked in-use size in the result report and --report.
truncate -s 2M "$MOCK_HOME/.cache/in-use-held.bin"
printf 'sibling\n' > "$MOCK_HOME/.cache/in-use-sibling.bin"
cat > "$TEST_ENV_DIR/in_use_result.conf" <<'EOF'
safe|Held Cache|$HOME/.cache/in-use-held.bin|cache held by a running process|0|mock_running_proc|
safe|Sibling Cache|$HOME/.cache/in-use-sibling.bin|cleaned sibling|0||
EOF
cat > "$TEST_ENV_DIR/bin/notify-send" <<'NOTIFY_STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$TEST_ENV_DIR/in_use_notify.log"
exit 0
NOTIFY_STUB
chmod +x "$TEST_ENV_DIR/bin/notify-send"
export LINUX_CLEANER_METRICS_FILE="$TEST_ENV_DIR/in_use_blocked.prom"
if run_test_case "Blocked Target In-Use Result Report" 0 "in_use_result.log" \
     --config "$TEST_ENV_DIR/in_use_result.conf" --clean --force --notify; then
  in_use_result_ok=0
  if grep -qF "In use: blocked=1 would_reclaim=2 MB" "$TEST_ENV_DIR/in_use_result.log" \
     && awk '
          /^Reclaimed:/ { seen=1 }
          seen && /^In use: blocked=1 would_reclaim=2 MB$/ { found=1 }
          END { exit !found }
        ' "$TEST_ENV_DIR/in_use_result.log" \
     && [[ -f "$MOCK_HOME/.cache/in-use-held.bin" ]] \
     && [[ ! -f "$MOCK_HOME/.cache/in-use-sibling.bin" ]] \
     && grep -qF 'linux_cleaner_targets{result="cleaned"} 1' "$TEST_ENV_DIR/in_use_blocked.prom" \
     && ! grep -q 'In use:' "$TEST_ENV_DIR/in_use_notify.log" \
     && grep -q '^Reclaimed: ' "$TEST_ENV_DIR/in_use_notify.log"; then
    in_use_result_ok=1
  fi
else
  in_use_result_ok=0
fi
unset LINUX_CLEANER_METRICS_FILE
rm -f "$TEST_ENV_DIR/bin/notify-send"
if [[ "$in_use_result_ok" -ne 1 ]] \
   || ! run_test_case "Blocked Target In-Use Saved Report" 0 "in_use_report.log" --report \
   || ! awk '
        /^Reclaimed:/ { seen=1 }
        seen && /^In use: blocked=1 would_reclaim=2 MB$/ { found=1 }
        END { exit !found }
      ' "$TEST_ENV_DIR/in_use_report.log" \
   || ! run_test_case "Blocked Target In-Use Report JSON" 0 "in_use_report.json" --report --json \
   || ! python3 - "$TEST_ENV_DIR/in_use_report.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert data["result"] == "completed", data
assert data["cleaned"] == 1, data
assert "would_reclaim" not in data, data
PY
then
  echo -e "${RED}FAIL: plan-blocked in-use size missing from the result report or --report.${NC}"
  cat "$TEST_ENV_DIR/in_use_result.log" "$TEST_ENV_DIR/in_use_report.log" "$TEST_ENV_DIR/in_use_notify.log" "$TEST_ENV_DIR/in_use_blocked.prom" 2>/dev/null || true
  exit 1
fi
echo -e "${GREEN}PASS: plan-blocked in-use size is in the result report and saved --report, and parsers ignore it.${NC}"

# 2. Test Case: Risk Levels Filter
# Default --risk safe: Medium Risk Target should NOT be in dry_run.log as FOUND or WARNING
if grep -v '^Hidden by risk:' "$TEST_ENV_DIR/dry_run.log" | grep -q "Medium Risk Target"; then
  echo -e "${RED}FAIL: Medium Risk Target was included in default risk run.${NC}"
  exit 1
else
  echo -e "${GREEN}PASS: Medium risk targets successfully filtered out in default safe mode.${NC}"
fi

# Dry run with --risk medium
if run_test_case "Dry Run with Risk Medium" 0 "dry_run_medium.log" --debug --config "$TEST_ENV_DIR/test_cleaner.conf" --risk medium --dry-run; then
  if grep -q "Medium Risk Target" "$TEST_ENV_DIR/dry_run_medium.log" \
     && ! grep -v '^Hidden by risk:' "$TEST_ENV_DIR/dry_run_medium.log" | grep -q "Danger Risk Target"; then
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

# A symlinked quarantine base hides sessions from find, which does not descend
# its start point. Trash must move nothing; readers must not claim the base is empty.
setup_mock_env
symlink_q_real="$TEST_ENV_DIR/quarantine_elsewhere"
mkdir -p "$symlink_q_real/2026-01-01_00-00-00" "$MOCK_HOME/.cache/linux-cleaner"
echo hidden > "$symlink_q_real/2026-01-01_00-00-00/payload"
ln -s "$symlink_q_real" "$MOCK_HOME/.cache/linux-cleaner/quarantine"
symlink_q_base="$MOCK_HOME/.cache/linux-cleaner/quarantine"
symlink_q_msg="Error: Refusing symlinked quarantine directory '$symlink_q_base'."
symlink_q_npm="$MOCK_HOME/.npm/_cacache/cache1.txt"
symlink_q_before=$(find "$symlink_q_real" -printf '%p\n' | sort)
if ! run_test_case "Trash Refuses Symlinked Quarantine Directory" 1 "trash_symlink_q.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --trash --force \
   || ! grep -qF "$symlink_q_msg" "$TEST_ENV_DIR/trash_symlink_q.log" \
   || [[ ! -f "$symlink_q_npm" ]] \
   || [[ ! -L "$symlink_q_base" ]] \
   || [[ "$(find "$symlink_q_real" -printf '%p\n' | sort)" != "$symlink_q_before" ]]; then
  echo -e "${RED}FAIL: symlinked quarantine was not refused or trash wrote through the link.${NC}"
  cat "$TEST_ENV_DIR/trash_symlink_q.log" 2>/dev/null || true
  exit 1
fi
if ! run_test_case "List Sessions Refuses Symlinked Quarantine Directory" 1 "list_symlink_q.log" \
     --list-sessions \
   || ! grep -qF "$symlink_q_msg" "$TEST_ENV_DIR/list_symlink_q.log" \
   || grep -q "No quarantine sessions found" "$TEST_ENV_DIR/list_symlink_q.log" \
   || [[ "$(find "$symlink_q_real" -printf '%p\n' | sort)" != "$symlink_q_before" ]]; then
  echo -e "${RED}FAIL: --list-sessions did not refuse a symlinked quarantine directory.${NC}"
  cat "$TEST_ENV_DIR/list_symlink_q.log" 2>/dev/null || true
  exit 1
fi
if ! run_test_case "Restore Refuses Symlinked Quarantine Directory" 1 "restore_symlink_q.log" \
     --restore latest \
   || ! grep -qF "$symlink_q_msg" "$TEST_ENV_DIR/restore_symlink_q.log" \
   || grep -q "No quarantined sessions found" "$TEST_ENV_DIR/restore_symlink_q.log" \
   || [[ ! -f "$symlink_q_real/2026-01-01_00-00-00/payload" ]]; then
  echo -e "${RED}FAIL: --restore did not refuse a symlinked quarantine directory.${NC}"
  cat "$TEST_ENV_DIR/restore_symlink_q.log" 2>/dev/null || true
  exit 1
fi
if ! run_test_case "Purge Sessions Refuses Symlinked Quarantine Directory" 1 "purge_symlink_q.log" \
     --purge-sessions all --force \
   || ! grep -qF "$symlink_q_msg" "$TEST_ENV_DIR/purge_symlink_q.log" \
   || grep -q "No quarantine sessions found" "$TEST_ENV_DIR/purge_symlink_q.log" \
   || [[ ! -f "$symlink_q_real/2026-01-01_00-00-00/payload" ]]; then
  echo -e "${RED}FAIL: --purge-sessions did not refuse a symlinked quarantine directory.${NC}"
  cat "$TEST_ENV_DIR/purge_symlink_q.log" 2>/dev/null || true
  exit 1
fi
if ! run_test_case "Doctor Symlinked Quarantine Warning" 0 "doctor_symlink_q.log" \
     --doctor --config "$TEST_ENV_DIR/test_cleaner.conf" \
   || ! grep -qxF "WARN: quarantine: symlinked quarantine directory refused ($symlink_q_base)" "$TEST_ENV_DIR/doctor_symlink_q.log" \
   || grep -q "^INFO: quarantine:" "$TEST_ENV_DIR/doctor_symlink_q.log"; then
  echo -e "${RED}FAIL: --doctor did not warn about a symlinked quarantine directory.${NC}"
  cat "$TEST_ENV_DIR/doctor_symlink_q.log" 2>/dev/null || true
  exit 1
fi
echo -e "${GREEN}PASS: a symlinked quarantine directory is refused by trash, list, restore and purge, and --doctor warns.${NC}"

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

# 15b. Test Case: Value-taking options refuse an option name as their value
setup_mock_env
if run_test_case "Refuse Option Value (--force -e --dry-run)" 1 "opt_val_exclude.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --force -e --dry-run \
   && grep -qF "Error: -e requires a value, got option '--dry-run'." "$TEST_ENV_DIR/opt_val_exclude.log" \
   && [[ -f "$MOCK_HOME/.npm/_cacache/cache1.txt" ]]; then
  echo -e "${GREEN}PASS: --force -e --dry-run exited 1 with the expected message and left the target intact.${NC}"
else
  echo -e "${RED}FAIL: --force -e --dry-run did not exit 1 with the expected message or deleted the target.${NC}"
  cat "$TEST_ENV_DIR/opt_val_exclude.log" 2>/dev/null || true
  exit 1
fi

setup_mock_env
if run_test_case "Refuse Option Value (--force --exclude-target --dry-run)" 1 "opt_val_exclude_target.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --force --exclude-target --dry-run \
   && grep -qF "Error: --exclude-target requires a value, got option '--dry-run'." "$TEST_ENV_DIR/opt_val_exclude_target.log" \
   && [[ -f "$MOCK_HOME/.npm/_cacache/cache1.txt" ]]; then
  echo -e "${GREEN}PASS: --force --exclude-target --dry-run exited 1 with the expected message and left the target intact.${NC}"
else
  echo -e "${RED}FAIL: --force --exclude-target --dry-run did not exit 1 with the expected message or deleted the target.${NC}"
  cat "$TEST_ENV_DIR/opt_val_exclude_target.log" 2>/dev/null || true
  exit 1
fi

setup_mock_env
printf 'dash-glob-keep\n' > "$MOCK_HOME/.npm/_cacache/-xfile.txt"
if run_test_case "Accept Dash-Leading Glob Value (-e '-x*')" 0 "opt_val_dash_glob.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --force -e '-x*' \
   && [[ ! -f "$MOCK_HOME/.npm/_cacache/cache1.txt" ]] \
   && [[ -f "$MOCK_HOME/.npm/_cacache/-xfile.txt" ]]; then
  echo -e "${GREEN}PASS: -e '-x*' is accepted and preserves matching dash-leading files.${NC}"
else
  echo -e "${RED}FAIL: -e '-x*' was rejected or did not exclude matching files.${NC}"
  cat "$TEST_ENV_DIR/opt_val_dash_glob.log" 2>/dev/null || true
  exit 1
fi

setup_mock_env
if run_test_case "Refuse Dry-Run Short Flag Value (--force -e -d)" 1 "opt_val_exclude_short.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --force -e -d \
   && grep -qF "Error: -e requires a value, got option '-d'." "$TEST_ENV_DIR/opt_val_exclude_short.log" \
   && [[ -f "$MOCK_HOME/.npm/_cacache/cache1.txt" ]]; then
  echo -e "${GREEN}PASS: --force -e -d exited 1 with the expected message and left the target intact.${NC}"
else
  echo -e "${RED}FAIL: --force -e -d was not refused with the expected message or deleted the target.${NC}"
  cat "$TEST_ENV_DIR/opt_val_exclude_short.log" 2>/dev/null || true
  exit 1
fi

setup_mock_env
if run_test_case "Refuse Option Value (--force --only-path --dry-run)" 1 "opt_val_only_path.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --force --only-path --dry-run \
   && grep -qF "Error: --only-path requires a value, got option '--dry-run'." "$TEST_ENV_DIR/opt_val_only_path.log" \
   && [[ -f "$MOCK_HOME/.npm/_cacache/cache1.txt" ]]; then
  echo -e "${GREEN}PASS: --force --only-path --dry-run exited 1 with the expected message and left the target intact.${NC}"
else
  echo -e "${RED}FAIL: --force --only-path --dry-run did not exit 1 with the expected message or deleted the target.${NC}"
  cat "$TEST_ENV_DIR/opt_val_only_path.log" 2>/dev/null || true
  exit 1
fi

setup_mock_env
if run_test_case "Refuse Dry-Run Short Flag Value (--force --only-path -d)" 1 "opt_val_only_path_short.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --force --only-path -d \
   && grep -qF "Error: --only-path requires a value, got option '-d'." "$TEST_ENV_DIR/opt_val_only_path_short.log" \
   && [[ -f "$MOCK_HOME/.npm/_cacache/cache1.txt" ]]; then
  echo -e "${GREEN}PASS: --force --only-path -d exited 1 with the expected message and left the target intact.${NC}"
else
  echo -e "${RED}FAIL: --force --only-path -d was not refused with the expected message or deleted the target.${NC}"
  cat "$TEST_ENV_DIR/opt_val_only_path_short.log" 2>/dev/null || true
  exit 1
fi

setup_mock_env
if run_test_case "Refuse Option Value (--force --lock-wait --dry-run)" 1 "opt_val_lock_wait.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --force --lock-wait --dry-run \
   && grep -qF "Error: --lock-wait requires a value, got option '--dry-run'." "$TEST_ENV_DIR/opt_val_lock_wait.log" \
   && [[ -f "$MOCK_HOME/.npm/_cacache/cache1.txt" ]]; then
  echo -e "${GREEN}PASS: --force --lock-wait --dry-run exited 1 with the expected message and left the target intact.${NC}"
else
  echo -e "${RED}FAIL: --force --lock-wait --dry-run did not exit 1 with the expected message or deleted the target.${NC}"
  cat "$TEST_ENV_DIR/opt_val_lock_wait.log" 2>/dev/null || true
  exit 1
fi

setup_mock_env
if run_test_case "Refuse Dry-Run Short Flag Value (--force --lock-wait -d)" 1 "opt_val_lock_wait_short.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --force --lock-wait -d \
   && grep -qF "Error: --lock-wait requires a value, got option '-d'." "$TEST_ENV_DIR/opt_val_lock_wait_short.log" \
   && [[ -f "$MOCK_HOME/.npm/_cacache/cache1.txt" ]]; then
  echo -e "${GREEN}PASS: --force --lock-wait -d exited 1 with the expected message and left the target intact.${NC}"
else
  echo -e "${RED}FAIL: --force --lock-wait -d was not refused with the expected message or deleted the target.${NC}"
  cat "$TEST_ENV_DIR/opt_val_lock_wait_short.log" 2>/dev/null || true
  exit 1
fi

setup_mock_env
if run_test_case "Refuse Option Value (--force --min-reclaim --dry-run)" 1 "opt_val_min_reclaim.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --force --min-reclaim --dry-run \
   && grep -qF "Error: --min-reclaim requires a value, got option '--dry-run'." "$TEST_ENV_DIR/opt_val_min_reclaim.log" \
   && [[ -f "$MOCK_HOME/.npm/_cacache/cache1.txt" ]]; then
  echo -e "${GREEN}PASS: --force --min-reclaim --dry-run exited 1 with the expected message and left the target intact.${NC}"
else
  echo -e "${RED}FAIL: --force --min-reclaim --dry-run did not exit 1 with the expected message or deleted the target.${NC}"
  cat "$TEST_ENV_DIR/opt_val_min_reclaim.log" 2>/dev/null || true
  exit 1
fi

setup_mock_env
if run_test_case "Refuse Dry-Run Short Flag Value (--force --min-reclaim -d)" 1 "opt_val_min_reclaim_short.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --force --min-reclaim -d \
   && grep -qF "Error: --min-reclaim requires a value, got option '-d'." "$TEST_ENV_DIR/opt_val_min_reclaim_short.log" \
   && [[ -f "$MOCK_HOME/.npm/_cacache/cache1.txt" ]]; then
  echo -e "${GREEN}PASS: --force --min-reclaim -d exited 1 with the expected message and left the target intact.${NC}"
else
  echo -e "${RED}FAIL: --force --min-reclaim -d was not refused with the expected message or deleted the target.${NC}"
  cat "$TEST_ENV_DIR/opt_val_min_reclaim_short.log" 2>/dev/null || true
  exit 1
fi

setup_mock_env
if run_test_case "Refuse Option Value (--force --min-free --dry-run)" 1 "opt_val_min_free.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --force --min-free --dry-run \
   && grep -qF "Error: --min-free requires a value, got option '--dry-run'." "$TEST_ENV_DIR/opt_val_min_free.log" \
   && [[ -f "$MOCK_HOME/.npm/_cacache/cache1.txt" ]]; then
  echo -e "${GREEN}PASS: --force --min-free --dry-run exited 1 with the expected message and left the target intact.${NC}"
else
  echo -e "${RED}FAIL: --force --min-free --dry-run did not exit 1 with the expected message or deleted the target.${NC}"
  cat "$TEST_ENV_DIR/opt_val_min_free.log" 2>/dev/null || true
  exit 1
fi

setup_mock_env
if run_test_case "Refuse Dry-Run Short Flag Value (--force --min-free -d)" 1 "opt_val_min_free_short.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --force --min-free -d \
   && grep -qF "Error: --min-free requires a value, got option '-d'." "$TEST_ENV_DIR/opt_val_min_free_short.log" \
   && [[ -f "$MOCK_HOME/.npm/_cacache/cache1.txt" ]]; then
  echo -e "${GREEN}PASS: --force --min-free -d exited 1 with the expected message and left the target intact.${NC}"
else
  echo -e "${RED}FAIL: --force --min-free -d was not refused with the expected message or deleted the target.${NC}"
  cat "$TEST_ENV_DIR/opt_val_min_free_short.log" 2>/dev/null || true
  exit 1
fi

setup_mock_env
if run_test_case "Refuse Option Value (--force --min-age --dry-run)" 1 "opt_val_min_age.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --force --min-age --dry-run \
   && grep -qF "Error: --min-age requires a value, got option '--dry-run'." "$TEST_ENV_DIR/opt_val_min_age.log" \
   && [[ -f "$MOCK_HOME/.npm/_cacache/cache1.txt" ]]; then
  echo -e "${GREEN}PASS: --force --min-age --dry-run exited 1 with the expected message and left the target intact.${NC}"
else
  echo -e "${RED}FAIL: --force --min-age --dry-run did not exit 1 with the expected message or deleted the target.${NC}"
  cat "$TEST_ENV_DIR/opt_val_min_age.log" 2>/dev/null || true
  exit 1
fi

setup_mock_env
if run_test_case "Refuse Dry-Run Short Flag Value (--force --min-age -d)" 1 "opt_val_min_age_short.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --force --min-age -d \
   && grep -qF "Error: --min-age requires a value, got option '-d'." "$TEST_ENV_DIR/opt_val_min_age_short.log" \
   && [[ -f "$MOCK_HOME/.npm/_cacache/cache1.txt" ]]; then
  echo -e "${GREEN}PASS: --force --min-age -d exited 1 with the expected message and left the target intact.${NC}"
else
  echo -e "${RED}FAIL: --force --min-age -d was not refused with the expected message or deleted the target.${NC}"
  cat "$TEST_ENV_DIR/opt_val_min_age_short.log" 2>/dev/null || true
  exit 1
fi

setup_mock_env
if run_test_case "Refuse Option Value (--force --action-timeout --dry-run)" 1 "opt_val_action_timeout.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --force --action-timeout --dry-run \
   && grep -qF "Error: --action-timeout requires a value, got option '--dry-run'." "$TEST_ENV_DIR/opt_val_action_timeout.log" \
   && [[ -f "$MOCK_HOME/.npm/_cacache/cache1.txt" ]]; then
  echo -e "${GREEN}PASS: --force --action-timeout --dry-run exited 1 with the expected message and left the target intact.${NC}"
else
  echo -e "${RED}FAIL: --force --action-timeout --dry-run did not exit 1 with the expected message or deleted the target.${NC}"
  cat "$TEST_ENV_DIR/opt_val_action_timeout.log" 2>/dev/null || true
  exit 1
fi

setup_mock_env
if run_test_case "Refuse Dry-Run Short Flag Value (--force --action-timeout -d)" 1 "opt_val_action_timeout_short.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --force --action-timeout -d \
   && grep -qF "Error: --action-timeout requires a value, got option '-d'." "$TEST_ENV_DIR/opt_val_action_timeout_short.log" \
   && [[ -f "$MOCK_HOME/.npm/_cacache/cache1.txt" ]]; then
  echo -e "${GREEN}PASS: --force --action-timeout -d exited 1 with the expected message and left the target intact.${NC}"
else
  echo -e "${RED}FAIL: --force --action-timeout -d was not refused with the expected message or deleted the target.${NC}"
  cat "$TEST_ENV_DIR/opt_val_action_timeout_short.log" 2>/dev/null || true
  exit 1
fi

setup_mock_env
if run_test_case "Refuse Option Value (--force --trash-keep-days --dry-run)" 1 "opt_val_trash_keep_days.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --force --trash-keep-days --dry-run \
   && grep -qF "Error: --trash-keep-days requires a value, got option '--dry-run'." "$TEST_ENV_DIR/opt_val_trash_keep_days.log" \
   && [[ -f "$MOCK_HOME/.npm/_cacache/cache1.txt" ]]; then
  echo -e "${GREEN}PASS: --force --trash-keep-days --dry-run exited 1 with the expected message and left the target intact.${NC}"
else
  echo -e "${RED}FAIL: --force --trash-keep-days --dry-run did not exit 1 with the expected message or deleted the target.${NC}"
  cat "$TEST_ENV_DIR/opt_val_trash_keep_days.log" 2>/dev/null || true
  exit 1
fi

setup_mock_env
if run_test_case "Refuse Dry-Run Short Flag Value (--force --trash-keep-days -d)" 1 "opt_val_trash_keep_days_short.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --force --trash-keep-days -d \
   && grep -qF "Error: --trash-keep-days requires a value, got option '-d'." "$TEST_ENV_DIR/opt_val_trash_keep_days_short.log" \
   && [[ -f "$MOCK_HOME/.npm/_cacache/cache1.txt" ]]; then
  echo -e "${GREEN}PASS: --force --trash-keep-days -d exited 1 with the expected message and left the target intact.${NC}"
else
  echo -e "${RED}FAIL: --force --trash-keep-days -d was not refused with the expected message or deleted the target.${NC}"
  cat "$TEST_ENV_DIR/opt_val_trash_keep_days_short.log" 2>/dev/null || true
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

# A resolved '|' must never enter deletion or quarantine metadata (a resolved
# newline aborts the run instead; see the canonical-path cases).
setup_mock_env
python3 - "$CLEANER_SH" "$MOCK_HOME" "$TEST_ENV_DIR" <<'RESOLVED_DELIMITERS_PY'
import json, os, pathlib, subprocess, sys
cleaner, home, root = sys.argv[1], pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
env = {k: v for k, v in os.environ.items() if not k.startswith(("LINUX_CLEANER_", "XDG_"))}
env.update(HOME=str(home), XDG_STATE_HOME=str(root / "xdg-state"), NO_COLOR="1",
           PATH=str(root / "bin") + ":" + env["PATH"])
reason = "resolved path contains '|'"
config = root / "resolved-delimiters.conf"
config.write_text("safe|PipeTest|$HOME/link/cache|test|0||\n"
                  "safe|Ordinary|$HOME/ordinary|control|0||\n")
for delimiter in ("|",):
    physical = home / ("foo" + delimiter + "bar") / "cache"
    physical.mkdir(parents=True)
    payload = physical / "data.txt"
    payload.write_text("keep payload\n")
    link = home / "link"
    link.symlink_to(physical.parent, target_is_directory=True)
    cases = [("JSON", ["--dry-run", "--json"]), ("dry run", ["--dry-run"]),
             ("clean", ["--clean", "--force"]), ("trash", ["--clean", "--force", "--trash"])]
    if delimiter == "|":
        cases.append(("scoped JSON", ["--dry-run", "--json", "--only-path", str(home)]))
    for label, args in cases:
        ordinary = home / "ordinary"
        ordinary.mkdir(exist_ok=True)
        (ordinary / "data.txt").write_text("ordinary payload\n")
        result = subprocess.run([cleaner, "--config", str(config)] + args, env=env,
                                capture_output=True, text=True, timeout=20)
        assert result.returncode == 0, (delimiter, label, result)
        if "--json" in args:
            targets = {t["name"]: t for t in json.loads(result.stdout)["targets"]}
            assert targets["PipeTest"]["status"] == "skipped", targets
            assert targets["PipeTest"]["reason"] == reason, targets
            assert targets["PipeTest"]["bytes"] == 0, targets
            assert targets["Ordinary"]["status"] == "found", targets
        else:
            assert "[SKIP] PipeTest: skipped: " + reason in result.stdout, result
            assert "skipped=1" in result.stdout, result
        assert payload.read_text() == "keep payload\n", (delimiter, label)
        assert not (home / "foo").exists(), (delimiter, label)
        assert ordinary.exists() == ("--clean" not in args), (delimiter, label, result)
        for meta in (home / ".cache/linux-cleaner/quarantine").glob("*/quarantine.meta"):
            assert b"/foo" not in meta.read_bytes(), (delimiter, label, meta)
        print("PASS: Resolved delimiter " + repr(delimiter) + " " + label, flush=True)
    link.unlink()
RESOLVED_DELIMITERS_PY

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

# Test Case: Ancestor of HOME is classified UNSAFE and never deleted.
setup_mock_env
nested_parent="$TEST_ENV_DIR/home_ancestor"
nested_home="$nested_parent/svc/home"
mkdir -p "$nested_home/.cache"
echo "keep" > "$nested_home/.cache/keep.txt"
cat << 'EOF' > "$TEST_ENV_DIR/home_ancestor.conf"
safe|Parent Of Home|$HOME/..|ancestor of HOME|0||
EOF
echo -e "\n${BOLD}Test Case: Ancestor of HOME UNSAFE${NC}"
PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$nested_home" "$CLEANER_SH" \
  --config "$TEST_ENV_DIR/home_ancestor.conf" --dry-run --debug < /dev/null \
  > "$TEST_ENV_DIR/home_ancestor_dry.log" 2>&1
if grep -q "UNSAFE.*Parent Of Home" "$TEST_ENV_DIR/home_ancestor_dry.log" && \
   ! grep -q "FOUND.*Parent Of Home" "$TEST_ENV_DIR/home_ancestor_dry.log"; then
  echo -e "${GREEN}PASS: Ancestor of HOME was classified UNSAFE in dry-run.${NC}"
else
  echo -e "${RED}FAIL: Ancestor of HOME was not classified UNSAFE (or was FOUND) in dry-run.${NC}"
  cat "$TEST_ENV_DIR/home_ancestor_dry.log"
  exit 1
fi
PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$nested_home" "$CLEANER_SH" \
  --config "$TEST_ENV_DIR/home_ancestor.conf" --clean --force < /dev/null \
  > "$TEST_ENV_DIR/home_ancestor_clean.log" 2>&1
if [[ -f "$nested_home/.cache/keep.txt" ]]; then
  echo -e "${GREEN}PASS: Ancestor of HOME survived --clean --force.${NC}"
else
  echo -e "${RED}FAIL: Ancestor of HOME was deleted by --clean --force.${NC}"
  cat "$TEST_ENV_DIR/home_ancestor_clean.log"
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

# 21b. Test Case: an existing outside-HOME target under an unwritable parent requires root
setup_mock_env
outside_parent="$OUTSIDE_DIR/unwritable_parent"
outside_full="$outside_parent/full_target"
outside_aged="$outside_parent/aged_target"
outside_excluded="$outside_parent/excluded_target"
mkdir -p "$outside_full/sub" "$outside_aged" "$outside_excluded"
echo keep_full > "$outside_full/sub/f"
echo old_aged > "$outside_aged/old.txt"
touch -d "10 days ago" "$outside_aged/old.txt"
echo drop_exc > "$outside_excluded/drop.txt"
echo keep_exc > "$outside_excluded/keep.lock"
outside_full_canon="$(realpath "$outside_full")"
chmod 555 "$outside_parent"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TEST_ENV_DIR/bin/sudo"
chmod +x "$TEST_ENV_DIR/bin/sudo"
cat > "$TEST_ENV_DIR/outside_unwritable_parent.conf" <<EOF
safe|Outside Full Unwritable Parent|$outside_full|whole outside target under unwritable parent|0||
safe|Outside Aged Unwritable Parent|$outside_aged|aged outside target under unwritable parent|5||
safe|Outside Excluded Unwritable Parent|$outside_excluded|excluded outside target under unwritable parent|0||exclude:*.lock
EOF
outside_root_log="$MOCK_HOME/outside-unwritable-parent.log"
if run_test_case "Outside HOME Unwritable Parent Skip Without Privileges" 0 "outside_unwritable_parent_run.log" \
     --config "$TEST_ENV_DIR/outside_unwritable_parent.conf" --clean --force --log "$outside_root_log"; then
  chmod 755 "$outside_parent" 2>/dev/null || true
  if grep -qF "Warning: skipping 'Outside Full Unwritable Parent' ($outside_full_canon): requires root privileges that are not available." "$TEST_ENV_DIR/outside_unwritable_parent_run.log" \
     && grep -qF "outcome=skipped reason=requires-root" "$outside_root_log" \
     && grep -qF "Skipped (requires root): Outside Full Unwritable Parent" "$TEST_ENV_DIR/outside_unwritable_parent_run.log" \
     && [[ -f "$outside_full/sub/f" ]] \
     && [[ ! -e "$outside_aged/old.txt" && -d "$outside_aged" ]] \
     && [[ ! -e "$outside_excluded/drop.txt" && -f "$outside_excluded/keep.lock" ]]; then
    echo -e "${GREEN}PASS: existing outside-HOME target under unwritable parent was skipped as requiring root with contents intact, while aged and excluded siblings cleaned file-by-file without sudo.${NC}"
  else
    echo -e "${RED}FAIL: outside-HOME target under unwritable parent was not handled as expected.${NC}"
    cat "$TEST_ENV_DIR/outside_unwritable_parent_run.log" "$outside_root_log" 2>/dev/null
    exit 1
  fi
else
  chmod 755 "$outside_parent" 2>/dev/null || true
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

# Trash cleanup prints one runnable Undo command naming its own session; a
# delete run, a --quiet run and a trash run that quarantined nothing print none.
write_undo_configs() {
  cat > "$TEST_ENV_DIR/undo.conf" << 'EOF'
safe|Undo Target|$HOME/.cache/yarn|Undo target|0||
EOF
  cat > "$TEST_ENV_DIR/undo_aged.conf" << 'EOF'
safe|Undo Aged|$HOME/.gemini/tmp|Nothing old enough|30||
EOF
}
setup_mock_env
write_undo_configs
undo_file="$MOCK_HOME/.cache/yarn/yarn-cache.json"
if ! run_test_case "Trash Prints Undo Command" 0 "undo_trash.log" \
     --config "$TEST_ENV_DIR/undo.conf" --trash --force; then
  exit 1
fi
undo_lines=$(grep -c '^Undo: ' "$TEST_ENV_DIR/undo_trash.log" || true)
undo_line=$(grep '^Undo: ' "$TEST_ENV_DIR/undo_trash.log" || true)
read -ra undo_cmd <<< "${undo_line#Undo: }"
undo_session="${undo_cmd[2]:-}"
if [[ "$undo_lines" != 1 || "${undo_cmd[0]:-}" != cleaner || "${undo_cmd[1]:-}" != --restore \
      || ${#undo_cmd[@]} -ne 3 || -z "$undo_session" || -e "$undo_file" ]]; then
  echo -e "${RED}FAIL: trash cleanup did not print exactly one 'Undo: cleaner --restore SESSION' line.${NC}"
  cat "$TEST_ENV_DIR/undo_trash.log"
  exit 1
fi
if ! run_test_case "Undo Session Listed" 0 "undo_list.log" --list-sessions \
   || ! grep -qF "$undo_session" "$TEST_ENV_DIR/undo_list.log"; then
  echo -e "${RED}FAIL: --list-sessions did not show the Undo session '$undo_session'.${NC}"
  cat "$TEST_ENV_DIR/undo_list.log"
  exit 1
fi
# Run the printed command itself, with "cleaner" mapped to the script under test.
if ! run_test_case "Undo Command Restores" 0 "undo_restore.log" "${undo_cmd[@]:1}" \
   || [[ "$(cat "$undo_file" 2>/dev/null)" != "dummy yarn cache" ]]; then
  echo -e "${RED}FAIL: the printed Undo command did not restore '$undo_file'.${NC}"
  cat "$TEST_ENV_DIR/undo_restore.log"
  exit 1
fi
if ! run_test_case "Delete Run Prints No Undo" 0 "undo_delete.log" \
     --config "$TEST_ENV_DIR/undo.conf" --force \
   || [[ -e "$undo_file" ]] || grep -q '^Undo: ' "$TEST_ENV_DIR/undo_delete.log"; then
  echo -e "${RED}FAIL: a delete run did not clean the target or printed an Undo line.${NC}"
  cat "$TEST_ENV_DIR/undo_delete.log"
  exit 1
fi
setup_mock_env
write_undo_configs
if ! run_test_case "Quiet Trash Prints No Undo" 0 "undo_quiet.log" \
     --config "$TEST_ENV_DIR/undo.conf" --trash --force --quiet; then
  exit 1
fi
if ! run_test_case "Empty Trash Prints No Undo" 0 "undo_empty.log" \
     --config "$TEST_ENV_DIR/undo_aged.conf" --trash --force; then
  exit 1
fi
if [[ -e "$undo_file" || ! -e "$MOCK_HOME/.gemini/tmp/old_file.tmp" ]] \
   || grep -q '^Undo: ' "$TEST_ENV_DIR/undo_quiet.log" "$TEST_ENV_DIR/undo_empty.log"; then
  echo -e "${RED}FAIL: a --quiet or nothing-quarantined run printed an Undo line (or did not run as set up).${NC}"
  cat "$TEST_ENV_DIR/undo_quiet.log" "$TEST_ENV_DIR/undo_empty.log"
  exit 1
fi
# An aged target whose moves all fail leaves a session without metadata: nothing to undo.
setup_mock_env
cat > "$TEST_ENV_DIR/undo_aged_fail.conf" << 'EOF'
safe|Undo Aged Fail|$HOME/.gemini/tmp|Old files only|5||
EOF
cat > "$TEST_ENV_DIR/bin/mv" << 'UNDO_MV'
#!/usr/bin/env bash
[[ "$*" == *'/.gemini/tmp/'* ]] && exit 1
real_mv=$(PATH="${PATH#"$TEST_ENV_DIR/bin:"}" command -v mv)
exec "$real_mv" "$@"
UNDO_MV
chmod +x "$TEST_ENV_DIR/bin/mv"
undo_aged_fail_rc=0
run_test_case "Failed Aged Trash Prints No Undo" 1 "undo_aged_fail.log" \
  --config "$TEST_ENV_DIR/undo_aged_fail.conf" --trash --force || undo_aged_fail_rc=1
rm -f "$TEST_ENV_DIR/bin/mv"
[[ "$undo_aged_fail_rc" -eq 0 ]] || exit 1
if [[ ! -e "$MOCK_HOME/.gemini/tmp/old_file.tmp" ]] \
   || ! compgen -G "$MOCK_HOME/.cache/linux-cleaner/quarantine/*" > /dev/null \
   || grep -q '^Undo: ' "$TEST_ENV_DIR/undo_aged_fail.log"; then
  echo -e "${RED}FAIL: a trash run that quarantined nothing printed an Undo line (or no session was created).${NC}"
  cat "$TEST_ENV_DIR/undo_aged_fail.log"
  exit 1
fi
echo -e "${GREEN}PASS: trash cleanup prints one runnable Undo command; delete, --quiet and empty runs print none.${NC}"

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

# Recorded paths print literally: a backslash sequence such as \c must not act as an escape.
setup_mock_env
bs_session="$MOCK_HOME/.cache/linux-cleaner/quarantine/2026-01-03_00-00-00"
mkdir -p "$bs_session"
printf 'keep payload\n' > "$bs_session/payload"
printf 'full|payload|%s/foo\\cbar|false|%s|%s\n' "$MOCK_HOME" "$(id -u)" "$(id -g)" > "$bs_session/quarantine.meta"
for bs_args in "--list-sessions" "--purge-sessions 2026-01-03_00-00-00 --dry-run"; do
  read -ra bs_argv <<< "$bs_args"
  if ! HOME="$MOCK_HOME" "$CLEANER_SH" "${bs_argv[@]}" < /dev/null > "$TEST_ENV_DIR/bs.out" 2>&1 \
     || ! grep -qF "$MOCK_HOME/foo\\cbar" "$TEST_ENV_DIR/bs.out" \
     || [[ ! -f "$bs_session/payload" ]]; then
    echo -e "${RED}FAIL: $bs_args did not print a recorded backslash path literally.${NC}"
    cat "$TEST_ENV_DIR/bs.out"
    exit 1
  fi
done
echo -e "${GREEN}PASS: session inventory and purge preview print recorded backslash paths literally.${NC}"

# A failed inventory scan must not publish a successful empty or partial list.
for inventory_format in human json; do
  for inventory_failure in total partial; do
    echo -e "\n${BOLD}Test Case: List Sessions Enumeration Failure ($inventory_format $inventory_failure)${NC}"
    setup_mock_env
    inventory_base="$MOCK_HOME/.cache/linux-cleaner/quarantine"
    for inventory_session in 2026-01-01_00-00-00 2026-01-02_00-00-00; do
      mkdir -p "$inventory_base/$inventory_session"
      printf 'keep payload\n' > "$inventory_base/$inventory_session/payload"
      printf 'full|payload|%s/original|false|%s|%s\n' "$MOCK_HOME" "$(id -u)" "$(id -g)" \
        > "$inventory_base/$inventory_session/quarantine.meta"
    done
    sha256sum "$inventory_base/"*/payload "$inventory_base/"*/quarantine.meta > "$TEST_ENV_DIR/inventory.sha256"
    export MOCK_INVENTORY_BASE="$inventory_base" MOCK_INVENTORY_FAILURE="$inventory_failure"
    cat > "$TEST_ENV_DIR/bin/find" <<'INVENTORY_FIND'
#!/usr/bin/env bash
if [[ "${1:-}" == "$MOCK_INVENTORY_BASE" ]]; then
  [[ "$MOCK_INVENTORY_FAILURE" == partial ]] && printf '%s\n' "$MOCK_INVENTORY_BASE/2026-01-01_00-00-00"
  exit 23
fi
real_find=$(PATH="${PATH#"$TEST_ENV_DIR/bin:"}" command -v find)
exec "$real_find" "$@"
INVENTORY_FIND
    chmod +x "$TEST_ENV_DIR/bin/find"
    inventory_args=(--list-sessions)
    [[ "$inventory_format" == json ]] && inventory_args+=(--json)
    inventory_exit=0
    PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" "$CLEANER_SH" "${inventory_args[@]}" \
      < /dev/null > "$TEST_ENV_DIR/inventory.out" 2> "$TEST_ENV_DIR/inventory.err" || inventory_exit=$?
    if [[ "$inventory_exit" -ne 1 || -s "$TEST_ENV_DIR/inventory.out" ]] \
       || ! grep -qx 'Error: Failed to enumerate quarantine sessions.' "$TEST_ENV_DIR/inventory.err" \
       || ! sha256sum -c "$TEST_ENV_DIR/inventory.sha256" > "$TEST_ENV_DIR/inventory_check.log" 2>&1; then
      echo -e "${RED}FAIL: failed $inventory_format inventory emitted success, lost its error, or changed payload (exit=$inventory_exit).${NC}"
      cat "$TEST_ENV_DIR/inventory.out" "$TEST_ENV_DIR/inventory.err"
      exit 1
    fi
  done
done
unset MOCK_INVENTORY_BASE MOCK_INVENTORY_FAILURE
echo -e "${GREEN}PASS: total and partial inventory scans fail safely in human and JSON formats.${NC}"

# Immediate unrecorded entry accounting is read-only and fails closed before purge.
python3 - "$CLEANER_SH" <<'UNRECORDED_PY'
import hashlib, json, os, pathlib, shutil, stat, subprocess, sys, tempfile
with tempfile.TemporaryDirectory(prefix="cleaner-unrecorded-", dir="/tmp") as directory:
    root = pathlib.Path(directory)
    home, bindir = root / "home", root / "bin"
    base = home / ".cache/linux-cleaner/quarantine"
    mixed, missing, zero = [base / f"2025-01-0{i}_00-00-00" for i in (1, 2, 3)]
    for session in (mixed, missing, zero): session.mkdir(parents=True)
    for name in ("known", "known-prefix", "nested", "aged", ".hidden", "empty", "literal [*?] $,\\"):
        (mixed / name).mkdir()
    (mixed / "regular").write_text("keep regular\n")
    (mixed / "line\nbreak").write_text("keep newline name\n")
    os.mkfifo(mixed / "fifo")
    (mixed / "link").symlink_to(mixed / "known", target_is_directory=True)
    (mixed / "dangling").symlink_to(mixed / "absent")
    (mixed / "nested/deep").write_text("nested reference\n")
    (mixed / "quarantine.meta").write_text(
        "# ignored|known-prefix|/ignored\n\n full | known |/recorded\n"
        "aged|nested/deep|/nested\naged-restored|aged|/aged\n"
        "full|literal [*?] $,\\|/literal\nfull|./regular|/not-normalized\n")
    (missing / "payload").write_text("no metadata\n")
    (missing / "empty").mkdir()
    (zero / "recorded").mkdir()
    (zero / "recorded/unlisted-descendant").write_text("not inspected\n")
    (zero / "quarantine.meta").write_text("aged-restored|recorded|/zero\n")
    for session in (mixed, missing, zero): os.utime(session, (0, 0))
    config = root / "nothing.conf"
    config.write_text("safe|Missing|$HOME/missing|No cleanup payload|0||\n")
    bindir.mkdir()
    env = {k: v for k, v in os.environ.items() if not k.startswith(("LINUX_CLEANER_", "XDG_"))}
    env.update(HOME=str(home), XDG_STATE_HOME=str(home / "state"), NO_COLOR="1")
    def snapshot(path):
        return {str(p.relative_to(path)): (p.lstat().st_mode, os.readlink(p) if p.is_symlink()
                else hashlib.sha256(p.read_bytes()).hexdigest() if stat.S_ISREG(p.lstat().st_mode) else None)
                for p in path.rglob("*")}
    def run(label, args, current=env, reply=""):
        print("Test Case: Unrecorded Inventory " + label, flush=True)
        result = subprocess.run([sys.argv[1]] + args, env=current, input=reply,
                                capture_output=True, text=True, timeout=20)
        return result
    before = snapshot(home)
    result = run("mixed zero and missing metadata JSON", ["--list-sessions", "--json"])
    assert result.returncode == 0, result
    sessions = json.loads(result.stdout)["sessions"]
    assert [s["unrecorded_entry_count"] for s in sessions] == [8, 2, 0], sessions
    assert len(sessions[0]["targets"]) == 5 and sessions[2]["targets"] == [{"type": "aged", "path": "/zero"}]
    assert snapshot(home) == before
    print("PASS: mixed, literal, nested, all-type, missing-metadata and zero counts", flush=True)
    result = run("human warning", ["--list-sessions"])
    assert result.returncode == 0 and "Unrecorded entries: 8" in result.stdout and "inspect" in result.stdout
    assert snapshot(home) == before
    print("PASS: human warning and inventory leave state unchanged", flush=True)
    for producer in ("cat", "find"):
        real = shutil.which(producer)
        script = bindir / producer
        script.write_text('#!/usr/bin/env bash\n'
            'if [[ "$1" == "$FAIL_SESSION"' + ('/quarantine.meta' if producer == 'cat' else '') + ' ]]; then\n'
            '  [[ "$FAIL_STYLE" != total ]] && ' + ('"' + real + '" "$@"' if producer == 'cat'
                else 'printf "known\\0"') + '\n  exit 23\nfi\nexec "' + real + '" "$@"\n')
        # cat is invoked with -- before its metadata operand.
        if producer == "cat": script.write_text(script.read_text().replace('if [[ "$1"', '[[ "${1:-}" == -- ]] && shift\nif [[ "$1"'))
        script.chmod(0o755)
        for mode, style in (("json", "total"), ("json", "partial"), ("json", "late"),
                            ("human", "total"), ("human", "partial"), ("forced", "total"),
                            ("forced", "partial"), ("prompt", "partial"), ("retention", "partial")):
            current = env | {"PATH": str(bindir) + ":" + env["PATH"], "FAIL_STYLE": style,
                             "FAIL_SESSION": str(zero if style == "late" else mixed)}
            args = ["--list-sessions"] + (["--json"] if mode == "json" else [])
            if mode in ("forced", "prompt"): args = ["--purge-sessions", "all"] + (["--force"] if mode == "forced" else [])
            if mode == "retention": args = ["--config", str(config), "--clean", "--force", "--trash-keep-days", "0"]
            state = snapshot(base)
            result = run(f"{producer} {style} {mode}", args, current, "y\n")
            assert result.returncode == 1 and "Error: Failed to " in result.stderr, result
            assert snapshot(base) == state and "Permanently delete" not in result.stdout, result
            if mode == "json": assert not result.stdout, result
            if mode == "retention":
                assert "Retention failed: true" in result.stdout, result
                report = subprocess.run([sys.argv[1], "--report", "--json"], env=env, capture_output=True, text=True)
                assert report.returncode == 0 and json.loads(report.stdout)["retention_failed"] is True, report
            print("PASS: checked failure preserves every quarantine entry", flush=True)
        script.unlink()
    result = run("positive count permits declined purge", ["--purge-sessions", "all"], reply="n\n")
    assert result.returncode == 0 and "Unrecorded entries: 8" in result.stdout and "No sessions were purged" in result.stdout
    state = snapshot(base)
    result = run("positive count remains informational under force", ["--purge-sessions", mixed.name, "--force"])
    assert result.returncode == 0 and not mixed.exists() and missing.exists() and zero.exists(), result
    print("PASS: counts preserve existing confirmation and force policy", flush=True)
UNRECORDED_PY

# Exact size failures must precede JSON output and every budgeted deletion.
for size_mode in json budget; do
  for size_failure in first late partial malformed; do
    echo -e "\n${BOLD}Test Case: Quarantine Size Failure ($size_mode $size_failure)${NC}"
    setup_mock_env
    size_base="$MOCK_HOME/.cache/linux-cleaner/quarantine"
    for size_session in 2026-01-01_00-00-00 2026-01-02_00-00-00; do
      mkdir -p "$size_base/$size_session"
      printf 'keep payload\n' > "$size_base/$size_session/payload"
      printf 'full|payload|%s/original|false|%s|%s\n' "$MOCK_HOME" "$(id -u)" "$(id -g)" \
        > "$size_base/$size_session/quarantine.meta"
    done
    sha256sum "$size_base/"*/payload "$size_base/"*/quarantine.meta > "$TEST_ENV_DIR/size.sha256"
    size_failed_session=2026-01-02_00-00-00
    if [[ "$size_mode:$size_failure" == json:first || ( "$size_mode" == budget && "$size_failure" != first ) ]]; then
      size_failed_session=2026-01-01_00-00-00
    fi
    export MOCK_SIZE_BASE="$size_base" MOCK_SIZE_FAILURE="$size_failure"
    export MOCK_SIZE_FAILED_PATH="$size_base/$size_failed_session"
    cat > "$TEST_ENV_DIR/bin/du" <<'SIZE_DU'
#!/usr/bin/env bash
if [[ "${1:-}" == -sb && "${!#}" == "$MOCK_SIZE_FAILED_PATH" ]]; then
  case "$MOCK_SIZE_FAILURE" in
    partial) printf '12345\t%s\n' "$MOCK_SIZE_FAILED_PATH" ;;
    malformed) printf 'not-a-size\t%s\n' "$MOCK_SIZE_FAILED_PATH"; exit 0 ;;
  esac
  exit 23
fi
real_du=$(PATH="${PATH#"$TEST_ENV_DIR/bin:"}" command -v du)
exec "$real_du" "$@"
SIZE_DU
    cat > "$TEST_ENV_DIR/bin/rm" <<'SIZE_RM'
#!/usr/bin/env bash
# Refuse every removal so a regression can never destroy the fixture payload.
printf '%s\n' "$*" >> "$TEST_ENV_DIR/size_rm_attempts"
exit 23
SIZE_RM
    chmod +x "$TEST_ENV_DIR/bin/du" "$TEST_ENV_DIR/bin/rm"
    size_args=(--list-sessions --json)
    [[ "$size_mode" == budget ]] && size_args=(--purge-sessions max-size:1 --force)
    size_exit=0
    PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" "$CLEANER_SH" "${size_args[@]}" \
      < /dev/null > "$TEST_ENV_DIR/size.out" 2> "$TEST_ENV_DIR/size.err" || size_exit=$?
    if [[ "$size_exit" -ne 1 || -s "$TEST_ENV_DIR/size.out" || -s "$TEST_ENV_DIR/size_rm_attempts" ]] \
       || ! grep -Fxq "Error: Failed to measure quarantine session '$MOCK_SIZE_FAILED_PATH'." "$TEST_ENV_DIR/size.err" \
       || ! sha256sum -c "$TEST_ENV_DIR/size.sha256" > "$TEST_ENV_DIR/size_check.log" 2>&1; then
      echo -e "${RED}FAIL: $size_mode $size_failure size failure emitted success, attempted removal, or changed payload (exit=$size_exit).${NC}"
      cat "$TEST_ENV_DIR/size.out" "$TEST_ENV_DIR/size.err"
      exit 1
    fi
  done
done
unset MOCK_SIZE_BASE MOCK_SIZE_FAILURE MOCK_SIZE_FAILED_PATH
echo -e "${GREEN}PASS: unavailable or invalid session sizes stop inventory and budgeted purge safely.${NC}"

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
   && ! grep -v '^Hidden by risk:' "$TEST_ENV_DIR/env_risk.log" | grep -q "Danger Risk Target"; then
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
   && ! grep -v '^Hidden by risk:' "$TEST_ENV_DIR/env_risk_cli.log" | grep -q "Medium Risk Target"; then
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

# Man page documents every LINUX_CLEANER_* env var named in the README or the CLI reference.
echo -e "\n${BOLD}Test Case: Man Page Env Var Parity${NC}"
missing_env_vars=""
while IFS= read -r env_name; do
  [[ -z "$env_name" ]] && continue
  if ! grep -q "\\.B $env_name" "$SCRIPT_DIR/cleaner.1"; then
    missing_env_vars+=" $env_name"
  fi
done < <(grep -ohE 'LINUX_CLEANER_[A-Z_]+' "$SCRIPT_DIR/README.md" "$SCRIPT_DIR/docs/cli-reference.md" | sort -u)
if [[ -z "$missing_env_vars" ]]; then
  echo -e "${GREEN}PASS: cleaner.1 documents every LINUX_CLEANER_* env var in README.md and docs/cli-reference.md.${NC}"
else
  echo -e "${RED}FAIL: documented env vars missing from cleaner.1:$missing_env_vars${NC}"
  exit 1
fi

# Value-taking options named by require_non_option_value, cleaner.1, and docs/cli-reference.md.
echo -e "\n${BOLD}Test Case: Value-taking Options Doc Parity${NC}"
vt_expected=$(printf '%s\n' \
  --config --risk --exclude --restore --only --only-exact --only-target \
  --exclude-target --only-path --exclude-path --lock-wait --check-health --min-reclaim \
  --min-free --min-free-path --min-age --action-timeout --trash-keep-days --purge-sessions \
  --hold-session --release-session | sort)
vt_parser=$(awk '
  function emit(    n, i, p) {
    if (lab == "") return
    n = split(lab, p, "|")
    for (i = 1; i <= n; i++) if (p[i] ~ /^--/) print p[i]
  }
  /^[[:space:]]*(--?[A-Za-z0-9-]+(\|--?[A-Za-z0-9-]+)*)\)[[:space:]]*$/ {
    lab = $0
    sub(/^[[:space:]]+/, "", lab)
    sub(/\)[[:space:]]*$/, "", lab)
  }
  /require_non_option_value/ && !/require_non_option_value\(\)/ { hit = 1 }
  /^[[:space:]]*;;[[:space:]]*$/ {
    if (hit) emit()
    lab = ""
    hit = 0
  }
' "$SCRIPT_DIR/cleaner.sh" | sort -u)
vt_man=$(awk '
  $0 == "Value-taking options" { p = 1 }
  p && /^\.SH / { exit }
  p { print }
' "$SCRIPT_DIR/cleaner.1" | sed 's/\\-/-/g')
vt_man=${vt_man%%refuse*}
vt_man_flags=$(printf '%s\n' "$vt_man" | grep -oE -- '--[a-z][a-z0-9-]*' | sort -u || true)
vt_doc=$(grep -m1 '^Value-taking options' "$SCRIPT_DIR/docs/cli-reference.md" || true)
vt_doc=${vt_doc%%refuse*}
vt_doc_flags=$(printf '%s\n' "$vt_doc" | grep -oE -- '--[a-z][a-z0-9-]*' | sort -u || true)
vt_fail=""
if [[ "$vt_parser" != "$vt_expected" ]]; then
  vt_fail+=" require_non_option_value"
fi
if [[ "$vt_man_flags" != "$vt_expected" ]]; then
  vt_fail+=" cleaner.1"
fi
if [[ "$vt_doc_flags" != "$vt_expected" ]]; then
  vt_fail+=" cli-reference.md"
fi
if [[ -z "$vt_fail" ]]; then
  echo -e "${GREEN}PASS: require_non_option_value, cleaner.1, and docs/cli-reference.md name the same value-taking options.${NC}"
else
  echo -e "${RED}FAIL: value-taking options differ from the declared contract:$vt_fail${NC}"
  exit 1
fi

# 34. Test Case: CHANGELOG top released version matches --version, and so does
# the man page (RELEASING.md pre-release gate). AUR pkgver is not tracked;
# aurgen aur takes it from the v* tag.
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
mixed_quarantine_bytes=$(du -sb "$mixed_trash_target" | cut -f1)
mixed_action_bytes=$(du -sb "$OUTSIDE_DIR" | cut -f1)
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

if ! run_test_case "Report JSON Mixed Trash Action Bytes" 0 "mixed_report.json" --report --json \
   || ! python3 - "$TEST_ENV_DIR/mixed_report.json" "$mixed_quarantine_bytes" "$mixed_action_bytes" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert (d["quarantined_bytes"], d["permanent_bytes"]) == tuple(map(int, sys.argv[2:])), d
PY
then
  echo -e "${RED}FAIL: saved report lost the mixed quarantine/action byte split.${NC}"
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
[[ "$(arb action:nix_store_gc)" == "nix-store" ]] || arb_ok=false
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

# 44b. Test Case: XDG base-directory placeholders ($XDG_CACHE_HOME, $XDG_CONFIG_HOME,
# $XDG_DATA_HOME, $XDG_STATE_HOME) expand as whole tokens when absolute, fall back
# to spec defaults when unset or relative, and leave longer token names literal.
# The dry-run JSON reports each target's expanded, canonical path.
xdg_target_path() {
  python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
print([t["path"] for t in d["targets"] if t["name"] == sys.argv[2]][0])' "$1" "$2"
}
setup_mock_env
mkdir -p "$TEST_ENV_DIR/xdg_cache_dir/xdg_probe"
printf 'probe\n' > "$TEST_ENV_DIR/xdg_cache_dir/xdg_probe/f.txt"
cat << 'XDGCONF' > "$TEST_ENV_DIR/xdg_probe.conf"
safe|XDG Probe|$XDG_CACHE_HOME/xdg_probe|xdg placeholder|0||
safe|XDG Longer|$HOME/$XDG_CACHE_HOMEX/zz|longer token stays literal|0||
XDGCONF
xdg_def_expected="$(realpath -m "$MOCK_HOME/.cache/xdg_probe")"
for xdg_case in absolute unset relative; do
  echo -e "\n${BOLD}Test Case: XDG Cache Placeholder ($xdg_case)${NC}"
  xdg_log="$TEST_ENV_DIR/xdg_${xdg_case}.json"
  xdg_ec=0
  case "$xdg_case" in
    absolute)
      xdg_expected="$(realpath -m "$TEST_ENV_DIR/xdg_cache_dir/xdg_probe")"
      XDG_CACHE_HOME="$TEST_ENV_DIR/xdg_cache_dir" PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
        "$CLEANER_SH" --config "$TEST_ENV_DIR/xdg_probe.conf" --dry-run --json \
        < /dev/null > "$xdg_log" 2>&1 || xdg_ec=$?
      ;;
    unset)
      xdg_expected="$xdg_def_expected"
      env -u XDG_CACHE_HOME PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
        "$CLEANER_SH" --config "$TEST_ENV_DIR/xdg_probe.conf" --dry-run --json \
        < /dev/null > "$xdg_log" 2>&1 || xdg_ec=$?
      ;;
    relative)
      xdg_expected="$xdg_def_expected"
      XDG_CACHE_HOME=rel PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
        "$CLEANER_SH" --config "$TEST_ENV_DIR/xdg_probe.conf" --dry-run --json \
        < /dev/null > "$xdg_log" 2>&1 || xdg_ec=$?
      ;;
  esac
  # shellcheck disable=SC2016  # the literal $XDG_CACHE_HOMEX must not expand
  if [[ $xdg_ec -eq 0 ]] \
     && [[ "$(xdg_target_path "$xdg_log" "XDG Probe")" == "$xdg_expected" ]] \
     && [[ "$(xdg_target_path "$xdg_log" "XDG Longer")" == *'/$XDG_CACHE_HOMEX/zz' ]]; then
    echo -e "${GREEN}PASS: \$XDG_CACHE_HOME ($xdg_case) resolved to '$xdg_expected' and \$XDG_CACHE_HOMEX stayed literal.${NC}"
  else
    echo -e "${RED}FAIL: \$XDG_CACHE_HOME ($xdg_case) did not resolve to '$xdg_expected' (ec=$xdg_ec).${NC}"
    cat "$xdg_log"
    exit 1
  fi
done

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
if ! run_test_case "Unrecorded Inventory After Metadata Append Failure" 0 "qmeta_inventory.json" --list-sessions --json \
   || ! python3 - "$TEST_ENV_DIR/qmeta_inventory.json" <<'QMETA_INVENTORY'
import json, sys
sessions = json.load(open(sys.argv[1]))["sessions"]
assert len(sessions) == 1 and sessions[0]["unrecorded_entry_count"] == 2, sessions
assert len(sessions[0]["targets"]) == 1, sessions
QMETA_INVENTORY
then
  exit 1
fi
if ! run_test_case "Unrecorded Inventory Human After Metadata Append Failure" 0 "qmeta_inventory.log" --list-sessions \
   || ! grep -q 'Unrecorded entries: 2' "$TEST_ENV_DIR/qmeta_inventory.log" \
   || ! cmp -s "$TEST_ENV_DIR/qmeta.before" "$qmeta_file" \
   || [[ ! -d "$qmeta_session/1_Unrecorded_Empty" ]] \
   || ! grep -qx 'unrecorded payload' "$qmeta_session/.hidden-unrecorded"; then
  exit 1
fi
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
             "usr/share/linux-cleaner/linux-cleaner.env.example" \
             "usr/share/bash-completion/completions/cleaner" \
             "usr/share/zsh/site-functions/_cleaner" \
             "usr/share/fish/vendor_completions.d/cleaner.fish" \
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
if ! cmp -s "$SCRIPT_DIR/examples/linux-cleaner.env.example" "$destroot/usr/share/linux-cleaner/linux-cleaner.env.example" \
   || [[ "$(stat -c '%a' "$destroot/usr/share/linux-cleaner/linux-cleaner.env.example" 2>/dev/null)" != 644 ]]; then
  echo -e "${RED}FAIL: install.sh did not ship the environment template unchanged with mode 0644.${NC}"
  install_ok=false
fi
if ! cmp -s "$SCRIPT_DIR/completions/cleaner.bash" "$destroot/usr/share/bash-completion/completions/cleaner" \
   || [[ "$(stat -c '%a' "$destroot/usr/share/bash-completion/completions/cleaner" 2>/dev/null)" != 644 ]]; then
  echo -e "${RED}FAIL: install.sh did not ship the bash completion file unchanged with mode 0644.${NC}"
  install_ok=false
fi
if ! cmp -s "$SCRIPT_DIR/completions/_cleaner" "$destroot/usr/share/zsh/site-functions/_cleaner" \
   || [[ "$(stat -c '%a' "$destroot/usr/share/zsh/site-functions/_cleaner" 2>/dev/null)" != 644 ]]; then
  echo -e "${RED}FAIL: install.sh did not ship the zsh completion file unchanged with mode 0644.${NC}"
  install_ok=false
fi
if ! cmp -s "$SCRIPT_DIR/completions/cleaner.fish" "$destroot/usr/share/fish/vendor_completions.d/cleaner.fish" \
   || [[ "$(stat -c '%a' "$destroot/usr/share/fish/vendor_completions.d/cleaner.fish" 2>/dev/null)" != 644 ]]; then
  echo -e "${RED}FAIL: install.sh did not ship the fish completion file unchanged with mode 0644.${NC}"
  install_ok=false
fi
if [[ "$install_ok" != true ]]; then
  exit 1
fi
echo -e "${GREEN}PASS: install.sh shipped all eight assets under DESTDIR with a 0755 binary and 0644 environment template and shell completions.${NC}"

# A renamed command (BINNAME) gets completions registered under its own name by both installers.
rename_installers=(install.sh)
command -v make >/dev/null 2>&1 && rename_installers+=(make)
for rename_installer in "${rename_installers[@]}"; do
  rename_root="$TEST_ENV_DIR/rename_$rename_installer"
  rm -rf "$rename_root"
  # An administrator's own unit sharing the prefix must not be rewritten.
  mkdir -p "$rename_root/usr/lib/systemd/user"
  printf 'ExecStart=/usr/bin/env cleaner --clean --force\n' > "$rename_root/usr/lib/systemd/user/linux-cleaner-custom.service"
  if [[ "$rename_installer" == install.sh ]]; then
    DESTDIR="$rename_root" PREFIX=/usr BINNAME=cache-cleaner sh "$SCRIPT_DIR/install.sh" install > "$TEST_ENV_DIR/rename_install.log" 2>&1
  else
    make -s -C "$SCRIPT_DIR" install DESTDIR="$rename_root" PREFIX=/usr BINNAME=cache-cleaner > "$TEST_ENV_DIR/rename_install.log" 2>&1
  fi
  rename_share="$rename_root/usr/share"
  if [[ "$(bash -c 'source "$1" && complete -p cache-cleaner' _ "$rename_share/bash-completion/completions/cache-cleaner" 2>/dev/null)" != "complete -F _cleaner cache-cleaner" ]] \
     || [[ "$(head -n 1 "$rename_share/zsh/site-functions/_cache-cleaner")" != "#compdef cache-cleaner cleaner cleaner.sh" ]] \
     || ! grep -qxF 'complete -c cache-cleaner -w cleaner' "$rename_share/fish/vendor_completions.d/cache-cleaner.fish" \
     || ! grep -q '^ExecStart=/usr/bin/env cache-cleaner ' "$rename_root/usr/lib/systemd/user/linux-cleaner-clean.service" \
     || ! grep -q '^ExecStart=/usr/bin/env cache-cleaner ' "$rename_root/usr/lib/systemd/user/linux-cleaner-retention.service" \
     || ! grep -q '^ExecStart=/usr/bin/env cache-cleaner ' "$rename_root/usr/lib/systemd/user/linux-cleaner-monitor.service" \
     || grep -q '^ExecStart=/usr/bin/env cleaner ' "$rename_root/usr/lib/systemd/user"/linux-cleaner-{clean,retention,monitor}.service \
     || ! grep -qxF 'ExecStart=/usr/bin/env cleaner --clean --force' "$rename_root/usr/lib/systemd/user/linux-cleaner-custom.service"; then
    echo -e "${RED}FAIL: $rename_installer BINNAME=cache-cleaner did not register completions or point the services at the renamed command.${NC}"
    cat "$TEST_ENV_DIR/rename_install.log"
    exit 1
  fi
  rm -rf "$rename_root"
done
echo -e "${GREEN}PASS: both installers register completions for a renamed BINNAME.${NC}"
# A failing step in the Makefile's renamed-BINNAME recipe must fail make, not report success.
if command -v make >/dev/null 2>&1; then
  rename_fail_root="$TEST_ENV_DIR/rename_make_fail"
  rm -rf "$rename_fail_root"
  # A directory where the zsh completion file belongs makes its redirect fail.
  mkdir -p "$rename_fail_root/usr/share/zsh/site-functions/_cache-cleaner"
  if make -s -C "$SCRIPT_DIR" install DESTDIR="$rename_fail_root" PREFIX=/usr BINNAME=cache-cleaner > "$TEST_ENV_DIR/rename_make_fail.log" 2>&1; then
    echo -e "${RED}FAIL: make install reported success although the renamed zsh completion could not be written.${NC}"
    cat "$TEST_ENV_DIR/rename_make_fail.log"
    exit 1
  fi
  rm -rf "$rename_fail_root"
  echo -e "${GREEN}PASS: make install fails when a renamed-BINNAME step fails.${NC}"
fi

# An unsafe BINNAME (space, slash, dot path) is refused before anything is written.
for unsafe_binname in 'cache cleaner' '../../escape' '..'; do
  for rename_installer in "${rename_installers[@]}"; do
    unsafe_root="$TEST_ENV_DIR/unsafe_binname"
    rm -rf "$unsafe_root"
    unsafe_rc=0
    if [[ "$rename_installer" == install.sh ]]; then
      DESTDIR="$unsafe_root" PREFIX=/usr BINNAME="$unsafe_binname" sh "$SCRIPT_DIR/install.sh" install > "$TEST_ENV_DIR/unsafe_binname.log" 2>&1 || unsafe_rc=$?
    else
      make -s -C "$SCRIPT_DIR" install DESTDIR="$unsafe_root" PREFIX=/usr BINNAME="$unsafe_binname" > "$TEST_ENV_DIR/unsafe_binname.log" 2>&1 || unsafe_rc=$?
    fi
    if [[ "$unsafe_rc" -eq 0 ]] || [[ -e "$unsafe_root" ]] || ! grep -qF 'must be a plain name' "$TEST_ENV_DIR/unsafe_binname.log"; then
      echo -e "${RED}FAIL: $rename_installer accepted BINNAME='$unsafe_binname' or wrote before refusing it.${NC}"
      cat "$TEST_ENV_DIR/unsafe_binname.log"
      exit 1
    fi
  done
done
echo -e "${GREEN}PASS: both installers refuse an unsafe BINNAME before writing anything.${NC}"

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
   && [[ ! -e "$destroot/usr/share/linux-cleaner" ]] \
   && [[ ! -e "$destroot/usr/share/bash-completion/completions/cleaner" ]] \
   && [[ ! -e "$destroot/usr/share/bash-completion" ]] \
   && [[ ! -e "$destroot/usr/share/zsh/site-functions/_cleaner" ]] \
   && [[ ! -e "$destroot/usr/share/zsh" ]] \
   && [[ ! -e "$destroot/usr/share/fish/vendor_completions.d/cleaner.fish" ]] \
   && [[ ! -e "$destroot/usr/share/fish" ]] \
   && [[ ! -e "$destroot/etc/linux-cleaner/cleaner.conf.example" ]] \
   && [[ -f "$destroot/etc/linux-cleaner/cleaner.conf" ]]; then
  echo -e "${GREEN}PASS: uninstall removed the binary, man page, completions, license and shipped cleaner.conf.example but kept the config.${NC}"
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

# Every unit tags its journal output, so `journalctl --user -t linux-cleaner` finds all three.
for unit_file in "$SCRIPT_DIR"/examples/systemd/*.service; do
  if [[ "$(grep -c '^SyslogIdentifier=linux-cleaner$' "$unit_file")" -ne 1 ]]; then
    echo -e "${RED}FAIL: $(basename "$unit_file") lacks exactly one SyslogIdentifier=linux-cleaner line.${NC}"
    exit 1
  fi
  for priority_line in 'Nice=19' 'IOSchedulingClass=idle'; do
    if [[ "$(grep -cx "$priority_line" "$unit_file")" -ne 1 ]]; then
      echo -e "${RED}FAIL: $(basename "$unit_file") lacks exactly one $priority_line line.${NC}"
      exit 1
    fi
  done
  # Oneshot units default to an infinite start timeout; a hung run would stall the timer.
  if [[ "$(grep -c '^TimeoutStartSec=' "$unit_file")" -ne 1 ]] \
     || grep -qE '^TimeoutStartSec=(0+([a-z]+)?|infinity)?$' "$unit_file"; then
    echo -e "${RED}FAIL: $(basename "$unit_file") lacks exactly one finite TimeoutStartSec= line.${NC}"
    exit 1
  fi
done
echo -e "${GREEN}PASS: every systemd service tags its journal output as linux-cleaner, runs at idle priority, and bounds its run time.${NC}"

# Mutating runs share one lock, so the retention unit must queue behind a
# cleanup that Persistent=true catch-up starts at the same moment.
if [[ "$(grep -c '^After=linux-cleaner-clean.service$' "$SCRIPT_DIR/examples/systemd/linux-cleaner-retention.service")" -ne 1 ]]; then
  echo -e "${RED}FAIL: linux-cleaner-retention.service is not ordered after linux-cleaner-clean.service.${NC}"
  exit 1
fi
echo -e "${GREEN}PASS: the retention unit is ordered after the cleanup unit.${NC}"

# The retention unit reads no env profile, so its own command line must wait for a
# cleanup that still holds the lock, within its two-hour start timeout.
retention_wait=$(sed -n 's/^ExecStart=.* --lock-wait \([0-9][0-9]*\)\( .*\)\{0,1\}$/\1/p' "$SCRIPT_DIR/examples/systemd/linux-cleaner-retention.service")
if [[ -z "$retention_wait" ]] || (( 10#$retention_wait <= 0 || 10#$retention_wait >= 7200 )); then
  echo -e "${RED}FAIL: linux-cleaner-retention.service does not wait for the run lock within its start timeout (got '${retention_wait}').${NC}"
  exit 1
fi
echo -e "${GREEN}PASS: the retention unit waits up to ${retention_wait}s for the run lock.${NC}"

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
  if ! cmp -s "$SCRIPT_DIR/examples/linux-cleaner.env.example" "$makeroot/usr/share/linux-cleaner/linux-cleaner.env.example" \
     || [[ "$(stat -c '%a' "$makeroot/usr/share/linux-cleaner/linux-cleaner.env.example" 2>/dev/null)" != 644 ]]; then
    echo -e "${RED}FAIL: make install did not ship the environment template unchanged with mode 0644.${NC}"
    exit 1
  fi
  if ! cmp -s "$SCRIPT_DIR/completions/cleaner.bash" "$makeroot/usr/share/bash-completion/completions/cleaner" \
     || [[ "$(stat -c '%a' "$makeroot/usr/share/bash-completion/completions/cleaner" 2>/dev/null)" != 644 ]]; then
    echo -e "${RED}FAIL: make install did not ship the bash completion file unchanged with mode 0644.${NC}"
    exit 1
  fi
  if ! cmp -s "$SCRIPT_DIR/completions/_cleaner" "$makeroot/usr/share/zsh/site-functions/_cleaner" \
     || [[ "$(stat -c '%a' "$makeroot/usr/share/zsh/site-functions/_cleaner" 2>/dev/null)" != 644 ]]; then
    echo -e "${RED}FAIL: make install did not ship the zsh completion file unchanged with mode 0644.${NC}"
    exit 1
  fi
  if ! cmp -s "$SCRIPT_DIR/completions/cleaner.fish" "$makeroot/usr/share/fish/vendor_completions.d/cleaner.fish" \
     || [[ "$(stat -c '%a' "$makeroot/usr/share/fish/vendor_completions.d/cleaner.fish" 2>/dev/null)" != 644 ]]; then
    echo -e "${RED}FAIL: make install did not ship the fish completion file unchanged with mode 0644.${NC}"
    exit 1
  fi
  echo -e "${GREEN}PASS: make install shipped six systemd user units and shell completions mode 644.${NC}"
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
     && [[ ! -e "$unmakeroot/usr/share/linux-cleaner" ]] \
     && [[ ! -e "$unmakeroot/usr/share/bash-completion/completions/cleaner" ]] \
     && [[ ! -e "$unmakeroot/usr/share/bash-completion" ]] \
     && [[ ! -e "$unmakeroot/usr/share/zsh/site-functions/_cleaner" ]] \
     && [[ ! -e "$unmakeroot/usr/share/zsh" ]] \
     && [[ ! -e "$unmakeroot/usr/share/fish/vendor_completions.d/cleaner.fish" ]] \
     && [[ ! -e "$unmakeroot/usr/share/fish" ]] \
     && [[ -f "$unmakeroot/etc/linux-cleaner/cleaner.conf" ]] \
     && [[ "$units_removed" == true ]]; then
    echo -e "${GREEN}PASS: make uninstall removed the binary, man page, completions, license, and systemd user units but kept the config.${NC}"
  else
    echo -e "${RED}FAIL: make uninstall did not clean up correctly (or removed the system config).${NC}"
    cat "$TEST_ENV_DIR/make_uninstall.log"
    exit 1
  fi

  for template_installer in sh make; do
    echo -e "\n${BOLD}Test Case: Environment Template Custom Paths ($template_installer)${NC}"
    template_root="$TEST_ENV_DIR/template-$template_installer"
    template_data="$template_root/custom/share/custom-cleaner"
    template_config="$template_root/etc/custom-cleaner/cleaner.conf"
    template_user_env="$MOCK_HOME/.config/linux-cleaner/env"
    template_command=(sh "$SCRIPT_DIR/install.sh")
    [[ "$template_installer" == make ]] && template_command=(make -s -C "$SCRIPT_DIR")
    HOME="$MOCK_HOME" DESTDIR="$template_root" PREFIX=/usr DATADIR=/custom/share PKGNAME=custom-cleaner \
      "${template_command[@]}" install > "$TEST_ENV_DIR/template-$template_installer.log" 2>&1
    if ! cmp -s "$SCRIPT_DIR/examples/linux-cleaner.env.example" "$template_data/linux-cleaner.env.example" \
       || [[ "$(stat -c %a "$template_data/linux-cleaner.env.example" 2>/dev/null)" != 644 ]]; then
      echo -e "${RED}FAIL: $template_installer ignored the custom environment template path, bytes, or mode.${NC}"
      exit 1
    fi
    mkdir -p "$(dirname "$template_user_env")"
    cp "$SCRIPT_DIR/examples/linux-cleaner.env.example" "$template_user_env"
    printf 'user config\n' > "$template_config"
    printf 'keep\n' > "$template_data/keep"
    HOME="$MOCK_HOME" DESTDIR="$template_root" PREFIX=/usr DATADIR=/custom/share PKGNAME=custom-cleaner \
      "${template_command[@]}" uninstall >> "$TEST_ENV_DIR/template-$template_installer.log" 2>&1
    if [[ -e "$template_data/linux-cleaner.env.example" ]] \
       || ! grep -qx keep "$template_data/keep" || ! grep -qx 'user config' "$template_config" \
       || ! cmp -s "$SCRIPT_DIR/examples/linux-cleaner.env.example" "$template_user_env"; then
      echo -e "${RED}FAIL: $template_installer uninstall removed user files or kept the shipped environment template.${NC}"
      exit 1
    fi
    rm "$template_data/keep"
    HOME="$MOCK_HOME" DESTDIR="$template_root" PREFIX=/usr DATADIR=/custom/share PKGNAME=custom-cleaner \
      "${template_command[@]}" uninstall >> "$TEST_ENV_DIR/template-$template_installer.log" 2>&1
    if [[ -e "$template_data" ]]; then
      echo -e "${RED}FAIL: $template_installer uninstall kept the empty template directory.${NC}"
      exit 1
    fi
    echo -e "${GREEN}PASS: $template_installer honors custom template paths and preserves user files on uninstall.${NC}"
  done
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

setup_mock_env
mkdir -p "$MOCK_HOME/.cache/rmfail_test"
echo "undeletable" > "$MOCK_HOME/.cache/rmfail_test/data.txt"
: > "$MOCK_HOME/.cache/zero_byte.bin"
cat << 'EOF' > "$TEST_ENV_DIR/outcome.conf"
safe|Rmfail Target|$HOME/.cache/rmfail_test|Target whose delete fails|0||
safe|Zero Byte Target|$HOME/.cache/zero_byte.bin|Empty file target|0||
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
if run_test_case "Log Records Failed And Zero-Byte Outcomes" 1 "outcome_log.log" \
     --config "$TEST_ENV_DIR/outcome.conf" --clean --force \
     --log "$MOCK_HOME/.cache/linux-cleaner/outcome.log"; then
  rm -f "$TEST_ENV_DIR/bin/rm"
  outcome_log="$MOCK_HOME/.cache/linux-cleaner/outcome.log"
  if [[ -f "$outcome_log" ]] \
     && grep -q "mode=delete .*target='Rmfail Target'.* outcome=failed" "$outcome_log" \
     && grep -q "mode=delete .*target='Zero Byte Target'.* outcome=success" "$outcome_log" \
     && ! grep -q "outcome=attempted" "$outcome_log"; then
    echo -e "${GREEN}PASS: log records failed and zero-byte delete outcomes as failed/success.${NC}"
  else
    echo -e "${RED}FAIL: log did not record the expected failed and zero-byte delete outcomes.${NC}"
    cat "$TEST_ENV_DIR/outcome_log.log"
    cat "$outcome_log" 2>/dev/null
    exit 1
  fi
else
  rm -f "$TEST_ENV_DIR/bin/rm"
  echo -e "${RED}FAIL: log records failed and zero-byte outcomes run did not exit 1 (silent failure).${NC}"
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
# IndexedDB storage) -- a target there is data loss, not reclamation, and the example in
# docs/configuration.md rates that class "danger". The default every install receives must not carry one.
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

# Retention purge when no quarantine directory exists (initial clean state or delete mode).
setup_mock_env
rm -rf "$MOCK_HOME/.cache/linux-cleaner/quarantine"
if run_test_case "Retention Purge Without Quarantine Dir" 0 "purge_older_no_quarantine.log" \
     --purge-sessions older-than:30 --force; then
  if grep -q "No quarantine sessions older than 30 day(s)." "$TEST_ENV_DIR/purge_older_no_quarantine.log"; then
    echo -e "${GREEN}PASS: older-than retention succeeds when quarantine directory does not exist.${NC}"
  else
    echo -e "${RED}FAIL: older-than retention without quarantine dir did not report expected message.${NC}"
    cat "$TEST_ENV_DIR/purge_older_no_quarantine.log"
    exit 1
  fi
else
  exit 1
fi

if run_test_case "Invalid Retention Days Without Quarantine Dir" 1 "purge_older_no_quarantine_bad.log" \
     --purge-sessions older-than:abc --force; then
  if grep -q "Invalid day count" "$TEST_ENV_DIR/purge_older_no_quarantine_bad.log"; then
    echo -e "${GREEN}PASS: invalid retention days without quarantine dir exits 1 and rejects cleanly.${NC}"
  else
    echo -e "${RED}FAIL: invalid retention days without quarantine dir was not rejected cleanly.${NC}"
    cat "$TEST_ENV_DIR/purge_older_no_quarantine_bad.log"
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

# A partial restore must keep the session's original retention age so older-than
# still purges the remaining quarantined targets on schedule.
setup_mock_env
cat << 'EOF' > "$TEST_ENV_DIR/only_age.conf"
safe|Yarn Cache|$HOME/.cache/yarn|yarn cache|0||
safe|NPM Cache|$HOME/.npm/_cacache|npm cache|0||
EOF
if run_test_case "Quarantine for Partial Restore Retention Age" 0 "only_age_setup.log" \
     --config "$TEST_ENV_DIR/only_age.conf" --trash --force; then
  only_age_sess=$(find "$MOCK_HOME/.cache/linux-cleaner/quarantine" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1)
  touch -d '40 days ago' "$only_age_sess"
  only_age_mtime_before=$(stat -c %Y "$only_age_sess")
  if run_test_case "Partial Restore Keeps Session Retention Age" 0 "only_age_restore.log" \
       --restore latest --only "/.cache/yarn"; then
    only_age_mtime_after=$(stat -c %Y "$only_age_sess")
    if [[ "$only_age_mtime_after" == "$only_age_mtime_before" ]] \
       && [[ -f "$MOCK_HOME/.cache/yarn/yarn-cache.json" ]] \
       && [[ -d "$only_age_sess" ]]; then
      echo -e "${GREEN}PASS: partial restore kept the session's 40-day mtime.${NC}"
    else
      echo -e "${RED}FAIL: partial restore reset session mtime ($only_age_mtime_before -> $only_age_mtime_after).${NC}"
      cat "$TEST_ENV_DIR/only_age_restore.log"
      exit 1
    fi
    if run_test_case "Purge Older-Than After Partial Restore" 0 "only_age_purge.log" \
         --purge-sessions older-than:30 --force; then
      if [[ ! -d "$only_age_sess" ]]; then
        echo -e "${GREEN}PASS: older-than:30 purged the 40-day session after a partial restore.${NC}"
      else
        echo -e "${RED}FAIL: older-than:30 did not purge the 40-day session after a partial restore.${NC}"
        cat "$TEST_ENV_DIR/only_age_purge.log"
        exit 1
      fi
    else
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

python3 - "$CLEANER_SH" <<'RESTORE_EXACT_PY'
import hashlib, json, os, pathlib, subprocess, sys, tempfile
cleaner = sys.argv[1]
with tempfile.TemporaryDirectory(prefix="cleaner-restore-exact-", dir="/tmp") as directory:
    root = pathlib.Path(directory)
    home, bindir, guards = root / "home", root / "bin", root / "guards"
    short, sibling = home / "caches/cache", home / "caches/cache-copy"
    literal = home / "literal/space [*?], comma/cache"
    for path in (short, sibling, literal):
        path.mkdir(parents=True)
        (path / "payload").write_text(str(path) + "\n")
    config = root / "fixture.conf"
    config.write_text("safe|Short|$HOME/caches/cache|short|0||\n"
                      "safe|Sibling|$HOME/caches/cache-copy|sibling|0||\n"
                      "safe|Literal|$HOME/literal/*/cache|literal path|0||\n")
    bindir.mkdir()
    guards.mkdir()
    trace = root / "forbidden-calls"
    for name in ("sudo", "uv", "pnpm", "hf"):
        path = bindir / name
        path.write_text('#!/bin/sh\nprintf "%s\\n" "$0" >> "$RESTORE_TRACE"\nexit 99\n')
        path.chmod(0o755)
    (guards / "flock").write_text('#!/bin/sh\nprintf "flock\\n" >> "$RESTORE_TRACE"\nexit 99\n')
    (guards / "flock").chmod(0o755)
    env = {k: v for k, v in os.environ.items() if not k.startswith(("LINUX_CLEANER_", "XDG_"))}
    env.update(HOME=str(home), XDG_STATE_HOME=str(home / "state"), NO_COLOR="1",
               PATH=str(bindir) + ":" + env["PATH"], RESTORE_TRACE=str(trace))
    def snapshot():
        return {str(p.relative_to(home)): (p.lstat().st_mode, os.readlink(p) if p.is_symlink()
                else hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else None) for p in home.rglob("*")}
    def run(label, args, error=None, prelock=False):
        print("Test Case: Restore Exact " + label, flush=True)
        before = snapshot()
        current = env | ({"PATH": str(guards) + ":" + env["PATH"]} if prelock else {})
        result = subprocess.run([cleaner, "--config", str(config)] + args, env=current, cwd=home,
                                capture_output=True, text=True, timeout=20)
        assert result.returncode == (1 if error else 0), (label, result)
        if error:
            assert error in result.stderr and snapshot() == before, (label, result)
        assert not trace.exists(), (label, "privilege/action/early-lock call")
        print("PASS: Restore Exact " + label, flush=True)
        return result
    for label, args, error in [
        ("missing argument", ["--restore", "latest", "--only-exact"], "requires a path argument"),
        ("empty argument", ["--restore", "latest", "--only-exact", ""], "requires a path argument"),
        ("requires restore", ["--only-exact", str(short), "--clean", "--force"], "--only-exact requires --restore"),
        ("mixed substring first", ["--restore", "latest", "--only", "cache", "--only-exact", str(short)], "cannot be combined"),
        ("mixed exact first", ["--restore", "latest", "--only-exact", str(short), "--only", "cache"], "cannot be combined"),
    ]:
        run(label, args, error, prelock=True)
    run("quarantine prefix siblings", ["--clean", "--trash", "--force"])
    inventory = json.loads(run("inventory paths", ["--list-sessions", "--json"]).stdout)
    session = home / ".cache/linux-cleaner/quarantine" / inventory["sessions"][0]["timestamp"]
    assert {t["path"] for t in inventory["sessions"][0]["targets"]} == {str(short), str(sibling), str(literal)}
    for label, value in (("no match", str(home / "missing")), ("argument not trimmed", str(short) + " "),
                         ("no normalization", str(short) + "/"), ("no expansion", "$HOME/caches/cache"),
                         ("no wildcards", str(short) + "*"), ("no comma list", str(short) + "," + str(sibling))):
        run(label, ["--restore", "latest", "--only-exact", value], "matches '--only-exact ")
    run("shorter original path", ["--restore", "latest", "--only-exact", str(short)])
    assert (short / "payload").read_text() == str(short) + "\n" and not sibling.exists() and not literal.exists()
    meta = session / "quarantine.meta"
    pending = [line.split("|") for line in meta.read_text().splitlines()]
    assert {r[2] for r in pending} == {str(sibling), str(literal)}
    assert all((session / r[1] / "payload").read_text() == r[2] + "\n" for r in pending)
    run("full after shorter path", ["--restore", "latest"])
    assert not session.exists() and all((p / "payload").read_text() == str(p) + "\n" for p in (short, sibling, literal))
    run("quarantine literal path", ["--clean", "--trash", "--force"])
    run("literal and repeated exact last wins", ["--restore", "latest", "--only-exact", str(short), "--only-exact", str(literal)])
    assert (literal / "payload").is_file() and not short.exists() and not sibling.exists()
    run("full after literal path", ["--restore", "latest"])
    run("quarantine substring compatibility", ["--clean", "--trash", "--force"])
    run("substring and repeated last wins", ["--restore", "latest", "--only", "absent", "--only", str(short)])
    assert (short / "payload").is_file() and (sibling / "payload").is_file() and not literal.exists()
    run("full after substring", ["--restore", "latest"])
    relative_session = home / ".cache/linux-cleaner/quarantine/2099-01-01_00-00-00"
    relative_session.mkdir(parents=True)
    (relative_session / "payload").write_text("relative fixture\n")
    (relative_session / "quarantine.meta").write_text(f"full|payload|relative-cache|false|{os.getuid()}|{os.getgid()}\n")
    run("literal relative stored path", ["--restore", "latest", "--only-exact", "relative-cache"])
    assert (home / "relative-cache").read_text() == "relative fixture\n" and not relative_session.exists()
RESTORE_EXACT_PY

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

if run_test_case "Only Target Comma List Dry Run" 0 "only_target_comma_dry.log" \
     --debug --config "$TEST_ENV_DIR/test_cleaner.conf" --only-target "NPM,Yarn" --dry-run; then
  if grep -q "NPM Cache" "$TEST_ENV_DIR/only_target_comma_dry.log" \
     && grep -q "Yarn Cache" "$TEST_ENV_DIR/only_target_comma_dry.log" \
     && ! grep -q "Gemini Temp" "$TEST_ENV_DIR/only_target_comma_dry.log" \
     && ! grep -q "Aurman Cache" "$TEST_ENV_DIR/only_target_comma_dry.log"; then
    echo -e "${GREEN}PASS: --only-target NPM,Yarn shows NPM Cache and Yarn Cache only.${NC}"
  else
    echo -e "${RED}FAIL: --only-target NPM,Yarn did not filter to NPM Cache and Yarn Cache only.${NC}"
    cat "$TEST_ENV_DIR/only_target_comma_dry.log"
    exit 1
  fi
else
  exit 1
fi

echo -e "\n${BOLD}Test Case: Only Target Comma List Env${NC}"
setup_mock_env
LINUX_CLEANER_ONLY_TARGET="NPM,Yarn" PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
  "$CLEANER_SH" --debug --config "$TEST_ENV_DIR/test_cleaner.conf" --dry-run \
  < /dev/null > "$TEST_ENV_DIR/env_only_target_comma.log" 2>&1 || true
if grep -q "NPM Cache" "$TEST_ENV_DIR/env_only_target_comma.log" \
   && grep -q "Yarn Cache" "$TEST_ENV_DIR/env_only_target_comma.log" \
   && ! grep -q "Gemini Temp" "$TEST_ENV_DIR/env_only_target_comma.log" \
   && ! grep -q "Aurman Cache" "$TEST_ENV_DIR/env_only_target_comma.log"; then
  echo -e "${GREEN}PASS: LINUX_CLEANER_ONLY_TARGET=NPM,Yarn shows NPM Cache and Yarn Cache only.${NC}"
else
  echo -e "${RED}FAIL: LINUX_CLEANER_ONLY_TARGET=NPM,Yarn did not filter targets.${NC}"
  cat "$TEST_ENV_DIR/env_only_target_comma.log"
  exit 1
fi

if run_test_case "Only Target Empty Token Rejected" 1 "only_target_empty_token.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --only-target "NPM,," --dry-run; then
  if grep -q "empty pattern" "$TEST_ENV_DIR/only_target_empty_token.log"; then
    echo -e "${GREEN}PASS: --only-target with an empty token exits 1 and reports empty pattern.${NC}"
  else
    echo -e "${RED}FAIL: --only-target empty token did not report empty pattern.${NC}"
    cat "$TEST_ENV_DIR/only_target_empty_token.log"
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

if ! run_test_case "Only Target With List Targets" 0 "only_target_list.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --only-target NPM --list-targets \
   || ! grep -q $'NPM Cache\tsafe\t' "$TEST_ENV_DIR/only_target_list.log"; then
  echo -e "${RED}FAIL: --only-target did not filter configured inventory.${NC}"
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

if run_test_case "Exclude Target Comma List Dry Run" 0 "exclude_target_comma_dry.log" \
     --debug --config "$TEST_ENV_DIR/test_cleaner.conf" --exclude-target "NPM,Yarn" --dry-run; then
  if ! grep -q "NPM Cache" "$TEST_ENV_DIR/exclude_target_comma_dry.log" \
     && ! grep -q "Yarn Cache" "$TEST_ENV_DIR/exclude_target_comma_dry.log" \
     && grep -q "Gemini Temp" "$TEST_ENV_DIR/exclude_target_comma_dry.log"; then
    echo -e "${GREEN}PASS: --exclude-target NPM,Yarn skips NPM Cache and Yarn Cache and keeps Gemini Temp.${NC}"
  else
    echo -e "${RED}FAIL: --exclude-target NPM,Yarn did not skip both targets as expected.${NC}"
    cat "$TEST_ENV_DIR/exclude_target_comma_dry.log"
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

if ! run_test_case "Exclude Target With List Targets" 0 "exclude_target_list.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --exclude-target NPM --list-targets \
   || grep -q $'NPM Cache\tsafe\t' "$TEST_ENV_DIR/exclude_target_list.log"; then
  echo -e "${RED}FAIL: --exclude-target did not filter configured inventory.${NC}"
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

# --min-reclaim / LINUX_CLEANER_MIN_RECLAIM: skip cleanup when planned reclaim is below threshold.
setup_mock_env
if run_test_case "Min Reclaim Above Total Skips" 0 "min_reclaim_skip.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --clean --force --min-reclaim 1T; then
  if grep -q "is below --min-reclaim 1T; nothing was cleaned." "$TEST_ENV_DIR/min_reclaim_skip.log" \
     && [[ -f "$MOCK_HOME/.npm/_cacache/cache1.txt" ]]; then
    echo -e "${GREEN}PASS: --min-reclaim 1T skips cleanup and keeps files intact.${NC}"
  else
    echo -e "${RED}FAIL: --min-reclaim 1T did not skip cleanup or deleted files.${NC}"
    cat "$TEST_ENV_DIR/min_reclaim_skip.log"
    exit 1
  fi
else
  exit 1
fi

# A dry-run that found something names the command that applies the plan.
setup_mock_env
cat > "$TEST_ENV_DIR/next_hint_empty.conf" <<'NEXTHINT'
safe|Absent Target|$HOME/.cache/no_such_dir_for_hint|Missing target|0||
NEXTHINT
if run_test_case "Dry Run Next Step Hint" 0 "next_hint.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --dry-run \
   && grep -qF "Next: run 'cleaner --clean' to apply this plan" "$TEST_ENV_DIR/next_hint.log" \
   && run_test_case "Dry Run Next Step Hint Quiet" 0 "next_hint_quiet.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --dry-run --quiet \
   && ! grep -qF "Next: run" "$TEST_ENV_DIR/next_hint_quiet.log" \
   && run_test_case "Dry Run Next Step Hint Nothing To Clean" 0 "next_hint_empty.log" \
     --config "$TEST_ENV_DIR/next_hint_empty.conf" --dry-run \
   && ! grep -qF "Next: run" "$TEST_ENV_DIR/next_hint_empty.log"; then
  echo -e "${GREEN}PASS: a dry-run with something to clean names the apply command; --quiet and empty plans do not.${NC}"
else
  echo -e "${RED}FAIL: dry-run next-step hint did not match the plan or --quiet.${NC}"
  cat "$TEST_ENV_DIR/next_hint.log" "$TEST_ENV_DIR/next_hint_quiet.log" "$TEST_ENV_DIR/next_hint_empty.log" 2>/dev/null || true
  exit 1
fi

# The Next: command repeats the preview's config, risk, filters and age, so re-running it
# as a dry run plans exactly the previewed targets. Each option changes this plan when
# dropped. The spaced paths and the backslash in the exclude glob (still matching *.log)
# prove the printf %q quoting round-trips through the printed line.
setup_mock_env
mkdir -p "$MOCK_HOME/.cache/space dir" "$MOCK_HOME/.cache/skip dir"
printf 'spaced\n' > "$MOCK_HOME/.cache/space dir/old.txt"
printf 'log\n' > "$MOCK_HOME/.cache/space dir/old.log"
touch -d '10 days ago' "$MOCK_HOME/.cache/space dir/old.txt" "$MOCK_HOME/.cache/space dir/old.log"
printf 'skip\n' > "$MOCK_HOME/.cache/skip dir/file.txt"
cat > "$TEST_ENV_DIR/next carry.conf" <<'NEXTCARRY'
safe|NPM Cache|$HOME/.npm/_cacache|Outside --only-path|0||
safe|Aurman Cache|$HOME/.cache/aurman|Too new for --min-age|0||
safe|Skip Spaced|$HOME/.cache/skip dir|Under --exclude-path|0||
medium|Medium Risk Target|$HOME/.cache/medium_test|Dropped by --exclude-target|0||
medium|Spaced Medium|$HOME/.cache/space dir|Needs --risk medium|0||
NEXTCARRY
next_carry_ok=false
if run_test_case "Dry Run Next Carries Filters" 0 "next_carry.log" \
     --config "$TEST_ENV_DIR/next carry.conf" --risk medium --exclude-target 'Medium Risk Target' \
     --only-path "$MOCK_HOME/.cache" --exclude-path "$MOCK_HOME/.cache/skip dir" \
     --exclude '*.lo\g' --min-age 1 --dry-run \
   && grep -qF "Next: run 'cleaner --clean' to apply this plan, repeating this preview's options (add --trash to quarantine instead of deleting):" "$TEST_ENV_DIR/next_carry.log"; then
  next_carry_line=$(grep -A1 -F "Next: run" "$TEST_ENV_DIR/next_carry.log" | tail -n 1)
  next_carry_argv=()
  eval "next_carry_argv=($next_carry_line)"
  if [[ "${next_carry_argv[0]:-}" == cleaner && "${next_carry_argv[1]:-}" == --clean ]] \
     && printf '%s\n' "${next_carry_argv[@]}" | grep -qxF '*.lo\g' \
     && printf '%s\n' "${next_carry_argv[@]}" | grep -qxF "$TEST_ENV_DIR/next carry.conf" \
     && run_test_case "Dry Run Next Carries Filters Replay" 0 "next_carry_replay.log" \
       "${next_carry_argv[@]:1}" --dry-run \
     && sed -n '/^Plan: /,/^$/p' "$TEST_ENV_DIR/next_carry.log" > "$TEST_ENV_DIR/next_carry.plan" \
     && sed -n '/^Plan: /,/^$/p' "$TEST_ENV_DIR/next_carry_replay.log" > "$TEST_ENV_DIR/next_carry_replay.plan" \
     && grep -qF "Targets: found=1 clean/missing=1 " "$TEST_ENV_DIR/next_carry.plan" \
     && grep -qF "  7 B medium Spaced Medium $MOCK_HOME/.cache/space dir (files > 1 days)" "$TEST_ENV_DIR/next_carry.plan" \
     && cmp -s "$TEST_ENV_DIR/next_carry.plan" "$TEST_ENV_DIR/next_carry_replay.plan"; then
    next_carry_ok=true
  fi
fi
# A bare preview keeps the plain hint; an env-enabled --trash is repeated and drops the note.
mkdir -p "$TEST_ENV_DIR/next-xdg/linux-cleaner"
cp "$TEST_ENV_DIR/test_cleaner.conf" "$TEST_ENV_DIR/next-xdg/linux-cleaner/cleaner.conf"
if [[ "$next_carry_ok" == true ]] \
   && XDG_CONFIG_HOME="$TEST_ENV_DIR/next-xdg" run_test_case "Dry Run Next Bare" 0 "next_bare.log" --dry-run \
   && grep -qxF "Next: run 'cleaner --clean' to apply this plan, or 'cleaner --clean --trash' to quarantine instead of deleting." "$TEST_ENV_DIR/next_bare.log" \
   && ! grep -qF "repeating this preview's options" "$TEST_ENV_DIR/next_bare.log" \
   && LINUX_CLEANER_TRASH=1 XDG_CONFIG_HOME="$TEST_ENV_DIR/next-xdg" run_test_case "Dry Run Next Env Trash" 0 "next_env_trash.log" --dry-run \
   && grep -qxF "Next: run 'cleaner --clean' to apply this plan, repeating this preview's options:" "$TEST_ENV_DIR/next_env_trash.log" \
   && grep -qxF "  cleaner --clean --trash" "$TEST_ENV_DIR/next_env_trash.log" \
   && XDG_CONFIG_HOME="$TEST_ENV_DIR/next-xdg" run_test_case "Dry Run Next Keep Days" 0 "next_keep_days.log" --trash --trash-keep-days 14 --dry-run \
   && grep -qxF "  cleaner --clean --trash --trash-keep-days 14" "$TEST_ENV_DIR/next_keep_days.log" \
   && XDG_CONFIG_HOME="$TEST_ENV_DIR/next-xdg" run_test_case "Dry Run Next Action Timeout" 0 "next_action_timeout.log" --action-timeout 600 --dry-run \
   && grep -qxF "  cleaner --clean --action-timeout 600" "$TEST_ENV_DIR/next_action_timeout.log" \
   && LINUX_CLEANER_ACTION_TIMEOUT=30 XDG_CONFIG_HOME="$TEST_ENV_DIR/next-xdg" run_test_case "Dry Run Next Explicit Zero Timeout" 0 "next_zero_timeout.log" --action-timeout 0 --dry-run \
   && grep -qxF "  cleaner --clean --action-timeout 0" "$TEST_ENV_DIR/next_zero_timeout.log" \
   && LINUX_CLEANER_RISK=medium XDG_CONFIG_HOME="$TEST_ENV_DIR/next-xdg" run_test_case "Dry Run Next Explicit Safe Risk" 0 "next_safe_risk.log" --risk safe --dry-run \
   && grep -qxF "  cleaner --clean --risk safe" "$TEST_ENV_DIR/next_safe_risk.log" \
   && run_test_case "Dry Run Next Carries Filters JSON" 0 "next_carry_json.log" \
     --config "$TEST_ENV_DIR/next carry.conf" --risk medium --json --dry-run \
   && ! grep -qF "Next:" "$TEST_ENV_DIR/next_carry_json.log"; then
  echo -e "${GREEN}PASS: the dry-run Next: command repeats the preview's options and replays the same plan.${NC}"
else
  echo -e "${RED}FAIL: the dry-run Next: command did not reproduce the previewed plan.${NC}"
  cat "$TEST_ENV_DIR/next_carry.log" "$TEST_ENV_DIR/next_carry_replay.log" "$TEST_ENV_DIR/next_bare.log" \
    "$TEST_ENV_DIR/next_env_trash.log" "$TEST_ENV_DIR/next_carry_json.log" 2>/dev/null || true
  exit 1
fi

setup_mock_env
if run_test_case "Min Reclaim Dry Run Note" 0 "min_reclaim_dry.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --dry-run --min-reclaim 1T \
   && grep -qF "Below --min-reclaim 1T: a cleanup run would skip." "$TEST_ENV_DIR/min_reclaim_dry.log" \
   && ! grep -qF "Next: run" "$TEST_ENV_DIR/min_reclaim_dry.log" \
   && [[ -f "$MOCK_HOME/.npm/_cacache/cache1.txt" ]] \
   && run_test_case "Min Reclaim Dry Run No Note" 0 "min_reclaim_dry_low.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --dry-run --min-reclaim 1K \
   && ! grep -qF "Below --min-reclaim" "$TEST_ENV_DIR/min_reclaim_dry_low.log" \
   && grep -qF "Next: run" "$TEST_ENV_DIR/min_reclaim_dry_low.log"; then
  echo -e "${GREEN}PASS: --dry-run notes a --min-reclaim skip only when the plan is below the threshold.${NC}"
else
  echo -e "${RED}FAIL: --dry-run --min-reclaim note did not match the threshold.${NC}"
  cat "$TEST_ENV_DIR/min_reclaim_dry.log" "$TEST_ENV_DIR/min_reclaim_dry_low.log" 2>/dev/null || true
  exit 1
fi

setup_mock_env
if run_test_case "Min Reclaim Below Total Cleans" 0 "min_reclaim_clean.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --clean --force --min-reclaim 1K; then
  if [[ ! -f "$MOCK_HOME/.npm/_cacache/cache1.txt" ]]; then
    echo -e "${GREEN}PASS: --min-reclaim 1K proceeds with cleanup when threshold is met.${NC}"
  else
    echo -e "${RED}FAIL: --min-reclaim 1K did not clean files.${NC}"
    cat "$TEST_ENV_DIR/min_reclaim_clean.log"
    exit 1
  fi
else
  exit 1
fi

echo -e "\n${BOLD}Test Case: Min Reclaim Env${NC}"
setup_mock_env
min_reclaim_env_ec=0
LINUX_CLEANER_MIN_RECLAIM=1T PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
  "$CLEANER_SH" --config "$TEST_ENV_DIR/test_cleaner.conf" --clean --force \
  < /dev/null > "$TEST_ENV_DIR/env_min_reclaim.log" 2>&1 || min_reclaim_env_ec=$?
if [[ "$min_reclaim_env_ec" -eq 0 ]] \
   && grep -q "is below --min-reclaim 1T; nothing was cleaned." "$TEST_ENV_DIR/env_min_reclaim.log" \
   && [[ -f "$MOCK_HOME/.npm/_cacache/cache1.txt" ]]; then
  echo -e "${GREEN}PASS: LINUX_CLEANER_MIN_RECLAIM=1T skips cleanup and keeps files intact.${NC}"
else
  echo -e "${RED}FAIL: LINUX_CLEANER_MIN_RECLAIM=1T did not skip cleanup (ec=$min_reclaim_env_ec).${NC}"
  cat "$TEST_ENV_DIR/env_min_reclaim.log"
  exit 1
fi

if run_test_case "Min Reclaim Invalid Size" 1 "min_reclaim_invalid.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --min-reclaim 10X --dry-run; then
  if grep -q -- "--min-reclaim expects a size" "$TEST_ENV_DIR/min_reclaim_invalid.log"; then
    echo -e "${GREEN}PASS: --min-reclaim 10X is rejected with a clear error.${NC}"
  else
    echo -e "${RED}FAIL: --min-reclaim 10X did not report expected size error.${NC}"
    cat "$TEST_ENV_DIR/min_reclaim_invalid.log"
    exit 1
  fi
else
  exit 1
fi

if run_test_case "Min Reclaim Too Large" 1 "min_reclaim_too_large.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --min-reclaim 99999999999T --dry-run \
   && grep -q "is too large" "$TEST_ENV_DIR/min_reclaim_too_large.log" \
   && run_test_case "Min Reclaim Largest Fitting Size" 0 "min_reclaim_max.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --min-reclaim 8388607T --dry-run; then
  echo -e "${GREEN}PASS: --min-reclaim refuses a size that overflows 64-bit arithmetic and accepts the largest one that fits.${NC}"
else
  echo -e "${RED}FAIL: --min-reclaim overflow guard did not behave as expected.${NC}"
  cat "$TEST_ENV_DIR/min_reclaim_too_large.log" "$TEST_ENV_DIR/min_reclaim_max.log" 2>/dev/null || true
  exit 1
fi

if run_test_case "Min Reclaim With Restore Rejected" 1 "min_reclaim_norestore.log" \
     --min-reclaim 1G --restore latest; then
  if grep -q "min-reclaim applies only to cleanup" "$TEST_ENV_DIR/min_reclaim_norestore.log"; then
    echo -e "${GREEN}PASS: --min-reclaim with --restore is rejected.${NC}"
  else
    echo -e "${RED}FAIL: --min-reclaim with --restore was not rejected.${NC}"
    cat "$TEST_ENV_DIR/min_reclaim_norestore.log"
    exit 1
  fi
else
  exit 1
fi

# --min-free / LINUX_CLEANER_MIN_FREE: skip cleanup when home filesystem free space is at or above threshold.
write_min_free_df_stub() {
  cat > "$TEST_ENV_DIR/bin/df" <<MOCK_DF
#!/usr/bin/env bash
printf 'Avail\n%s\n' "$1"
MOCK_DF
  chmod +x "$TEST_ENV_DIR/bin/df"
}

setup_mock_env
write_min_free_df_stub 5368709120
if run_test_case "Min Free Above Threshold Skips" 0 "min_free_skip.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --clean --force --min-free 1G; then
  if grep -qF "is at or above --min-free 1G; nothing was cleaned." "$TEST_ENV_DIR/min_free_skip.log" \
     && [[ -f "$MOCK_HOME/.npm/_cacache/cache1.txt" ]] \
     && grep -qF "Result: skipped at or above --min-free 1G" "$XDG_STATE_HOME/linux-cleaner/last-report.txt" \
     && run_test_case "Min Free Report JSON" 0 "min_free_report.json" --report --json \
     && python3 - "$TEST_ENV_DIR/min_free_report.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["result"] == "skipped_at_or_above_min_free", d
PY
  then
    echo -e "${GREEN}PASS: --min-free 1G skips cleanup when 5G is free and records skipped report.${NC}"
  else
    echo -e "${RED}FAIL: --min-free 1G did not skip cleanup, deleted files, or missed saved report.${NC}"
    cat "$TEST_ENV_DIR/min_free_skip.log" "$XDG_STATE_HOME/linux-cleaner/last-report.txt" 2>/dev/null || true
    exit 1
  fi
else
  exit 1
fi

setup_mock_env
write_min_free_df_stub 104857600
if run_test_case "Min Free Below Threshold Cleans" 0 "min_free_clean.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --clean --force --min-free 1G; then
  if [[ ! -f "$MOCK_HOME/.npm/_cacache/cache1.txt" ]]; then
    echo -e "${GREEN}PASS: --min-free 1G proceeds with cleanup when free space is below threshold.${NC}"
  else
    echo -e "${RED}FAIL: --min-free 1G did not clean files when free space was below threshold.${NC}"
    cat "$TEST_ENV_DIR/min_free_clean.log"
    exit 1
  fi
else
  exit 1
fi

setup_mock_env
write_min_free_df_stub 5368709120
if run_test_case "Min Free Zero Disables" 0 "min_free_zero.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --clean --force --min-free 0; then
  if [[ ! -f "$MOCK_HOME/.npm/_cacache/cache1.txt" ]] && ! grep -qF -- "--min-free" "$TEST_ENV_DIR/min_free_zero.log"; then
    echo -e "${GREEN}PASS: --min-free 0 disables the free-space gate and cleans normally.${NC}"
  else
    echo -e "${RED}FAIL: --min-free 0 skipped the cleanup instead of disabling the gate.${NC}"
    cat "$TEST_ENV_DIR/min_free_zero.log"
    exit 1
  fi
else
  exit 1
fi

setup_mock_env
printf '#!/usr/bin/env bash\nexit 1\n' > "$TEST_ENV_DIR/bin/df"
chmod +x "$TEST_ENV_DIR/bin/df"
if run_test_case "Min Free Unreadable Df" 0 "min_free_nodf.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --clean --force --min-free 1G; then
  if [[ ! -f "$MOCK_HOME/.npm/_cacache/cache1.txt" ]] \
     && grep -qF -- "cannot read free space on the filesystem holding HOME; --min-free 1G is ignored this run." "$TEST_ENV_DIR/min_free_nodf.log"; then
    echo -e "${GREEN}PASS: --min-free warns and cleans when free space cannot be read.${NC}"
  else
    echo -e "${RED}FAIL: --min-free did not warn or did not clean when df failed.${NC}"
    cat "$TEST_ENV_DIR/min_free_nodf.log"
    exit 1
  fi
else
  exit 1
fi

if run_test_case "Min Free Invalid Size" 1 "min_free_invalid.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --min-free bogus --dry-run; then
  if grep -q -- "--min-free expects a size" "$TEST_ENV_DIR/min_free_invalid.log"; then
    echo -e "${GREEN}PASS: --min-free bogus is rejected with a clear error.${NC}"
  else
    echo -e "${RED}FAIL: --min-free bogus did not report expected size error.${NC}"
    cat "$TEST_ENV_DIR/min_free_invalid.log"
    exit 1
  fi
else
  exit 1
fi

if run_test_case "Min Free With List Sessions Rejected" 1 "min_free_nolist.log" \
     --min-free 1G --list-sessions; then
  if grep -q "min-free applies only to cleanup" "$TEST_ENV_DIR/min_free_nolist.log"; then
    echo -e "${GREEN}PASS: --min-free with --list-sessions is rejected.${NC}"
  else
    echo -e "${RED}FAIL: --min-free with --list-sessions was not rejected.${NC}"
    cat "$TEST_ENV_DIR/min_free_nolist.log"
    exit 1
  fi
else
  exit 1
fi

echo -e "\n${BOLD}Test Case: Min Free Env${NC}"
setup_mock_env
write_min_free_df_stub 5368709120
min_free_env_ec=0
LINUX_CLEANER_MIN_FREE=1G PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
  "$CLEANER_SH" --config "$TEST_ENV_DIR/test_cleaner.conf" --clean --force \
  < /dev/null > "$TEST_ENV_DIR/env_min_free.log" 2>&1 || min_free_env_ec=$?
if [[ "$min_free_env_ec" -eq 0 ]] \
   && grep -qF "is at or above --min-free 1G; nothing was cleaned." "$TEST_ENV_DIR/env_min_free.log" \
   && [[ -f "$MOCK_HOME/.npm/_cacache/cache1.txt" ]] \
   && grep -qF "Result: skipped at or above --min-free 1G" "$XDG_STATE_HOME/linux-cleaner/last-report.txt"; then
  echo -e "${GREEN}PASS: LINUX_CLEANER_MIN_FREE=1G skips cleanup and keeps files intact.${NC}"
else
  echo -e "${RED}FAIL: LINUX_CLEANER_MIN_FREE=1G did not skip cleanup (ec=$min_free_env_ec).${NC}"
  cat "$TEST_ENV_DIR/env_min_free.log"
  exit 1
fi

setup_mock_env
write_min_free_df_stub 5368709120
if run_test_case "Min Free Dry Run Note" 0 "min_free_dry.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --dry-run --min-free 1G \
   && grep -qF "Free space 5 GB is at or above --min-free 1G: a cleanup run would skip." "$TEST_ENV_DIR/min_free_dry.log" \
   && ! grep -qF "Next: run" "$TEST_ENV_DIR/min_free_dry.log" \
   && [[ -f "$MOCK_HOME/.npm/_cacache/cache1.txt" ]]; then
  echo -e "${GREEN}PASS: --dry-run notes a --min-free skip when free space is at or above the threshold.${NC}"
else
  echo -e "${RED}FAIL: --dry-run --min-free note did not match the threshold.${NC}"
  cat "$TEST_ENV_DIR/min_free_dry.log" 2>/dev/null || true
  exit 1
fi
rm -f "$TEST_ENV_DIR/bin/df"

# Opposite pressure on HOME and the selected filesystem pins the probe argument.
write_min_free_path_df_stub() {
  cat > "$TEST_ENV_DIR/bin/df" <<MOCK_DF
#!/usr/bin/env bash
case "\${@: -1}" in
  "\$HOME") printf 'Avail\n%s\n' "$2" ;;
  "\$TEST_ENV_DIR/min free path")
    [[ "$1" != unreadable ]] || exit 1
    printf 'Avail\n%s\n' "$1"
    ;;
  *) printf 'Avail\n5368709120\n' ;;
esac
MOCK_DF
  chmod +x "$TEST_ENV_DIR/bin/df"
}

for min_free_direction in selected_low selected_high; do
  setup_mock_env
  min_free_path="$TEST_ENV_DIR/min free path"
  mkdir -p "$min_free_path"
  min_free_expected_exit=2
  min_free_home_exit=0
  min_free_expected_skip=null
  min_free_home_skip=skipped_at_or_above_min_free
  if [[ "$min_free_direction" == selected_low ]]; then
    write_min_free_path_df_stub 104857600 5368709120
  else
    write_min_free_path_df_stub 5368709120 104857600
    min_free_expected_exit=0
    min_free_home_exit=2
    min_free_expected_skip=skipped_at_or_above_min_free
    min_free_home_skip=null
  fi
  if ! run_test_case "Min Free Path $min_free_direction JSON Exit" "$min_free_expected_exit" "min_free_path.json" \
       --config "$TEST_ENV_DIR/test_cleaner.conf" --min-free 1G --min-free-path "$min_free_path" --json --exit-code \
     || ! run_test_case "Min Free Default HOME $min_free_direction" "$min_free_home_exit" "min_free_home.json" \
       --config "$TEST_ENV_DIR/test_cleaner.conf" --min-free 1G --json --exit-code \
     || ! LINUX_CLEANER_MIN_FREE=1G LINUX_CLEANER_MIN_FREE_PATH="$min_free_path" \
       run_test_case "Min Free Path Env $min_free_direction" "$min_free_expected_exit" "min_free_path_env.json" \
       --config "$TEST_ENV_DIR/test_cleaner.conf" --json --exit-code \
     || ! LINUX_CLEANER_MIN_FREE=10G LINUX_CLEANER_MIN_FREE_PATH="$MOCK_HOME" \
       run_test_case "Min Free Path CLI Overrides Env $min_free_direction" "$min_free_expected_exit" "min_free_path_override.json" \
       --config "$TEST_ENV_DIR/test_cleaner.conf" --min-free 1G --min-free-path "$min_free_path" --json --exit-code \
     || ! python3 - "$TEST_ENV_DIR" "$min_free_expected_skip" "$min_free_home_skip" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
for name, expected in [("min_free_path.json", sys.argv[2]),
                       ("min_free_path_env.json", sys.argv[2]),
                       ("min_free_path_override.json", sys.argv[2]),
                       ("min_free_home.json", sys.argv[3])]:
    data = json.loads((root / name).read_text())
    assert data["would_skip"] == (None if expected == "null" else expected), data
PY
  then
    echo -e "${RED}FAIL: selected filesystem, HOME default, env override, JSON or exit code disagreed.${NC}"
    exit 1
  fi
  if ! run_test_case "Min Free Path Text $min_free_direction" "$min_free_expected_exit" "min_free_path_text.log" \
       --config "$TEST_ENV_DIR/test_cleaner.conf" --min-free 1G --min-free-path "$min_free_path" --exit-code; then
    exit 1
  fi
  if [[ "$min_free_direction" == selected_low ]]; then
    printf -v min_free_next '%q ' cleaner --clean --config "$TEST_ENV_DIR/test_cleaner.conf" --min-free 1G --min-free-path "$min_free_path"
    if ! grep -qxF "  ${min_free_next% }" "$TEST_ENV_DIR/min_free_path_text.log"; then
      echo -e "${RED}FAIL: Next: omitted or misquoted the selected filesystem or threshold.${NC}"
      exit 1
    fi
  elif ! grep -qF 'a cleanup run would skip.' "$TEST_ENV_DIR/min_free_path_text.log" \
       || grep -qF 'Next:' "$TEST_ENV_DIR/min_free_path_text.log"; then
    echo -e "${RED}FAIL: text preview did not skip on the selected filesystem.${NC}"
    exit 1
  fi
  if [[ ! -f "$MOCK_HOME/.npm/_cacache/cache1.txt" ]] \
     || ! run_test_case "Min Free Path Cleanup $min_free_direction" 0 "min_free_path_clean.log" \
       --config "$TEST_ENV_DIR/test_cleaner.conf" --min-free 1G --min-free-path "$min_free_path" --clean --force; then
    exit 1
  fi
  if [[ "$min_free_direction" == selected_low && -f "$MOCK_HOME/.npm/_cacache/cache1.txt" ]] \
     || [[ "$min_free_direction" == selected_high && ! -f "$MOCK_HOME/.npm/_cacache/cache1.txt" ]]; then
    echo -e "${RED}FAIL: cleanup followed HOME pressure instead of --min-free-path.${NC}"
    exit 1
  fi
done
echo -e "${GREEN}PASS: --min-free-path gates both directions, defaults to HOME, and agrees with env, JSON and --exit-code.${NC}"

setup_mock_env
min_free_path="$TEST_ENV_DIR/min free path"
mkdir -p "$min_free_path"
write_min_free_path_df_stub unreadable 5368709120
if ! run_test_case "Min Free Path Unreadable Preview" 2 "min_free_path_unreadable.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --min-free 1G --min-free-path "$min_free_path" --exit-code \
   || ! run_test_case "Min Free Path Unreadable Cleans" 0 "min_free_path_unreadable_clean.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --min-free 1G --min-free-path "$min_free_path" --clean --force \
   || ! grep -qF "cannot read free space on the filesystem holding $min_free_path; --min-free 1G is ignored this run." "$TEST_ENV_DIR/min_free_path_unreadable_clean.log" \
   || [[ -f "$MOCK_HOME/.npm/_cacache/cache1.txt" ]]; then
  echo -e "${RED}FAIL: an unreadable explicit filesystem did not warn and proceed.${NC}"
  exit 1
fi

setup_mock_env
min_free_path="$TEST_ENV_DIR/min free path"
mkdir -p "$min_free_path"
touch "$min_free_path/file"
write_min_free_path_df_stub 5368709120 5368709120
if ! run_test_case "Min Free Path File Zero Disables" 0 "min_free_path_zero.log" \
     --config "$TEST_ENV_DIR/test_cleaner.conf" --min-free 0 --min-free-path "$min_free_path/file" --clean --force \
   || [[ -f "$MOCK_HOME/.npm/_cacache/cache1.txt" ]]; then
  echo -e "${RED}FAIL: --min-free-path rejected an existing file or --min-free 0 failed to disable the gate.${NC}"
  exit 1
fi
for min_free_bad_path in relative/path "$TEST_ENV_DIR/missing"; do
  if ! run_test_case "Min Free Path Invalid $min_free_bad_path" 1 "min_free_path_bad.log" \
       --min-free 1G --min-free-path "$min_free_bad_path" \
     || ! grep -qF -- '--min-free-path requires an absolute existing path' "$TEST_ENV_DIR/min_free_path_bad.log" \
     || ! LINUX_CLEANER_MIN_FREE=1G LINUX_CLEANER_MIN_FREE_PATH="$min_free_bad_path" \
       run_test_case "Min Free Path Invalid Env $min_free_bad_path" 1 "min_free_path_bad_env.log" \
     || ! grep -qF -- '--min-free-path requires an absolute existing path' "$TEST_ENV_DIR/min_free_path_bad_env.log"; then
    echo -e "${RED}FAIL: CLI or env accepted an invalid min-free path.${NC}"
    exit 1
  fi
done
if ! run_test_case "Min Free Path Requires Threshold" 1 "min_free_path_requires.log" --min-free-path "$min_free_path" \
   || ! grep -qF -- '--min-free-path requires --min-free.' "$TEST_ENV_DIR/min_free_path_requires.log" \
   || ! LINUX_CLEANER_MIN_FREE_PATH="$min_free_path" \
     run_test_case "Min Free Path Env Requires Threshold" 1 "min_free_path_env_requires.log" \
   || ! grep -qF -- '--min-free-path requires --min-free.' "$TEST_ENV_DIR/min_free_path_env_requires.log" \
   || ! run_test_case "Min Free Path Missing Argument" 1 "min_free_path_missing.log" --min-free 1G --min-free-path \
   || ! grep -qF -- '--min-free-path requires a path argument.' "$TEST_ENV_DIR/min_free_path_missing.log"; then
  echo -e "${RED}FAIL: --min-free-path did not require a threshold and path argument.${NC}"
  exit 1
fi
for min_free_option_value in --dry-run -d; do
  if ! run_test_case "Min Free Path Refuses Option $min_free_option_value" 1 "min_free_path_option.log" \
       --force --min-free 1G --min-free-path "$min_free_option_value" \
     || ! grep -qF "Error: --min-free-path requires a value, got option '$min_free_option_value'." "$TEST_ENV_DIR/min_free_path_option.log"; then
    echo -e "${RED}FAIL: --min-free-path consumed a dry-run option as its path.${NC}"
    exit 1
  fi
done
rm -f "$TEST_ENV_DIR/bin/df"
# The cleanup cases above emptied the mock caches; later cases expect them populated.
setup_mock_env

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
       && grep -q '"size_at_run_time": false' "$TEST_ENV_DIR/json_parsed.out" \
       && grep -q '"reason": ""' "$TEST_ENV_DIR/json_parsed.out" \
       && grep -qF '"reason": "process '"'"'mock_running_proc'"'"' is active"' "$TEST_ENV_DIR/json_parsed.out" \
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

# JSON previews report cleanup gates in the same order as cleanup, including empty plans.
for json_gate_case in "Min Reclaim" "Min Free" "Nothing To Clean" "Proceed" \
                      "Empty Min Reclaim" "Empty Min Free" "Runtime Sized"; do
  setup_mock_env
  mkdir -p "$MOCK_HOME/.cache/json_gate"
  printf 'cache\n' > "$MOCK_HOME/.cache/json_gate/file.txt"
  printf '%s\n' "safe|JSON Gate|\$HOME/.cache/json_gate|Gate preview|0||" > "$TEST_ENV_DIR/json_gate.conf"
  write_min_free_df_stub 1073741824
  json_gate_args=(--min-reclaim 0 --min-free 0)
  json_gate_expected=null
  case "$json_gate_case" in
    "Min Reclaim"|"Empty Min Reclaim")
      json_gate_args=(--min-reclaim 1G --min-free 1G)
      json_gate_expected=skipped_below_min_reclaim
      ;;
    "Min Free"|"Empty Min Free")
      json_gate_args=(--min-reclaim 0 --min-free 1G)
      json_gate_expected=skipped_at_or_above_min_free
      ;;
    "Nothing To Clean") json_gate_expected=nothing_to_clean ;;
    "Proceed")
      write_min_free_df_stub 536870912
      json_gate_args=(--min-reclaim 0 --min-free 1G)
      ;;
    "Runtime Sized")
      printf '%s\n' "safe|JSON Gate|\$HOME/.cache/json_gate|Gate preview|0||action:uv_cache_prune" > "$TEST_ENV_DIR/json_gate.conf"
      ;;
  esac
  case "$json_gate_case" in
    "Nothing To Clean"|"Empty "*) rm -rf "$MOCK_HOME/.cache/json_gate" ;;
  esac
  if ! run_test_case "JSON Would Skip $json_gate_case" 0 "json_gate.log" \
       --config "$TEST_ENV_DIR/json_gate.conf" --dry-run --json "${json_gate_args[@]}" \
     || ! python3 - "$TEST_ENV_DIR/json_gate.log" "$json_gate_expected" "$json_gate_case" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
expected = None if sys.argv[2] == "null" else sys.argv[2]
assert d["would_skip"] == expected, d
if sys.argv[3] == "Runtime Sized":
    assert d["total_reclaimable_bytes"] == 0, d
    assert d["targets"][0]["size_at_run_time"] is True, d
PY
  then
    echo -e "${RED}FAIL: JSON would_skip did not match $json_gate_case.${NC}"
    cat "$TEST_ENV_DIR/json_gate.log"
    exit 1
  fi
  echo -e "${GREEN}PASS: JSON would_skip matches $json_gate_case.${NC}"
  for exit_format in text json; do
    for exit_modifier in false true; do
      exit_args=(--config "$TEST_ENV_DIR/json_gate.conf" "${json_gate_args[@]}")
      [[ "$exit_format" == json ]] && exit_args+=(--json --dry-run)
      [[ "$exit_modifier" == true ]] && exit_args+=(--exit-code)
      exit_expected=0
      if [[ "$exit_modifier" == true && "$json_gate_expected" == null ]]; then
        exit_expected=2
      fi
      if ! run_test_case "Preview Exit Code $json_gate_case $exit_format $exit_modifier" "$exit_expected" "exit_code.log" "${exit_args[@]}" \
         || grep -A1 '^Next:' "$TEST_ENV_DIR/exit_code.log" | grep -q -- '--exit-code'; then
        echo -e "${RED}FAIL: preview exit status or Next command differed for $json_gate_case.${NC}"
        exit 1
      fi
      if [[ "$exit_format" == json ]] && ! python3 - "$TEST_ENV_DIR/exit_code.log" "$json_gate_expected" <<'EXIT_CODE_PY'
import json, sys
expected = None if sys.argv[2] == "null" else sys.argv[2]
assert json.load(open(sys.argv[1]))["would_skip"] == expected
EXIT_CODE_PY
      then
        echo -e "${RED}FAIL: --exit-code changed the JSON preview verdict.${NC}"
        exit 1
      fi
      case "$json_gate_case" in
        "Nothing To Clean"|"Empty "*) ;;
        *)
          if [[ ! -f "$MOCK_HOME/.cache/json_gate/file.txt" ]]; then
            echo -e "${RED}FAIL: --exit-code preview removed the target.${NC}"
            exit 1
          fi
          ;;
      esac
    done
  done
done
rm -f "$TEST_ENV_DIR/bin/df"

printf 'invalid|Exit Code|%s/.cache/json_gate|Invalid risk|0||\n' "$MOCK_HOME" > "$TEST_ENV_DIR/exit_code_invalid.conf"
for exit_format in text json; do
  exit_args=(--exit-code --config "$TEST_ENV_DIR/exit_code_invalid.conf")
  [[ "$exit_format" == json ]] && exit_args+=(--json)
  if ! run_test_case "Preview Exit Code Invalid Config $exit_format" 1 "exit_code_invalid.log" "${exit_args[@]}"; then
    exit 1
  fi
done

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

if run_test_case "Dry Run With Restore Preview" 0 "dry_run_restore.log" \
     --restore 2020-01-01_00-00-00 --dry-run; then
  if grep -Fxq "would restore  $json_restore_dest" "$TEST_ENV_DIR/dry_run_restore.log" \
     && grep -Fxq "Dry-run: nothing restored." "$TEST_ENV_DIR/dry_run_restore.log" \
     && [[ -f "$json_qsession/payload" && ! -e "$json_restore_dest" ]]; then
    echo -e "${GREEN}PASS: explicit --dry-run previews restore without moving quarantined data.${NC}"
  else
    echo -e "${RED}FAIL: explicit --dry-run with restore mutated data or returned the wrong error.${NC}"
    cat "$TEST_ENV_DIR/dry_run_restore.log"
    exit 1
  fi
else
  exit 1
fi

if run_test_case "Dry Run With Purge Preview" 0 "dry_run_purge.log" \
     --purge-sessions 2020-01-01_00-00-00 --force --dry-run; then
  if grep -Fxq "=== Would purge Quarantine Sessions ===" "$TEST_ENV_DIR/dry_run_purge.log" \
     && grep -qE '^  2020-01-01_00-00-00  size=.' "$TEST_ENV_DIR/dry_run_purge.log" \
     && ! grep -q 'Permanently delete\|Purged ' "$TEST_ENV_DIR/dry_run_purge.log" \
     && [[ -f "$json_qsession/payload" ]]; then
    echo -e "${GREEN}PASS: explicit --dry-run previews purge without deleting the session.${NC}"
  else
    echo -e "${RED}FAIL: explicit --dry-run with purge mutated data or returned the wrong preview.${NC}"
    cat "$TEST_ENV_DIR/dry_run_purge.log"
    exit 1
  fi
else
  exit 1
fi

if run_test_case "Dry Run Before Restore Preview" 0 "dry_run_before_restore.log" \
     --dry-run --restore 2020-01-01_00-00-00 \
   && run_test_case "Dry Run Before Purge Preview" 0 "dry_run_before_purge.log" \
     --force --dry-run --purge-sessions 2020-01-01_00-00-00; then
  if grep -Fxq "would restore  $json_restore_dest" "$TEST_ENV_DIR/dry_run_before_restore.log" \
     && grep -Fxq "Dry-run: nothing restored." "$TEST_ENV_DIR/dry_run_before_restore.log" \
     && grep -Fxq "=== Would purge Quarantine Sessions ===" "$TEST_ENV_DIR/dry_run_before_purge.log" \
     && grep -qE '^  2020-01-01_00-00-00  size=.' "$TEST_ENV_DIR/dry_run_before_purge.log" \
     && ! grep -q 'Permanently delete\|Purged ' "$TEST_ENV_DIR/dry_run_before_purge.log" \
     && [[ -f "$json_qsession/payload" && ! -e "$json_restore_dest" ]]; then
    echo -e "${GREEN}PASS: explicit --dry-run previews restore and purge in either mode-argument position.${NC}"
  else
    echo -e "${RED}FAIL: reverse-position --dry-run restore/purge mutated quarantined data.${NC}"
    exit 1
  fi
else
  exit 1
fi

# Restore previews preserve payload, recovery metadata, retention age, and lock state.
python3 - "$CLEANER_SH" <<'RESTORE_PREVIEW_PY'
import hashlib, os, pathlib, subprocess, sys, tempfile

cleaner = sys.argv[1]
with tempfile.TemporaryDirectory(prefix="cleaner-restore-preview-", dir="/tmp") as directory:
    root = pathlib.Path(directory)
    home = root / "home"
    config = root / "cleaner.conf"
    names = ("conflict", "ready", "already", "missing")
    for name in names:
        target = home / name
        target.mkdir(parents=True)
        (target / "payload").write_text(name + "\n")
    config.write_text("".join(f"safe|{name}|$HOME/{name}|preview|0||\n" for name in names))
    env = {k: v for k, v in os.environ.items() if not k.startswith(("LINUX_CLEANER_", "XDG_"))}
    env.update(HOME=str(home), XDG_STATE_HOME=str(home / "state"), NO_COLOR="1")
    result = subprocess.run([cleaner, "--config", str(config), "--trash", "--force"],
                            env=env, capture_output=True, text=True, timeout=20)
    assert result.returncode == 0, result
    session, = (home / ".cache/linux-cleaner/quarantine").iterdir()
    meta = session / "quarantine.meta"
    records = [line.split("|") for line in meta.read_text().splitlines() if line and not line.startswith("#")]
    assert len(records) == len(names), records
    for record in records:
        if pathlib.Path(record[2]).name in ("already", "missing"):
            payload = session / record[1]
            (payload / "payload").unlink()
            payload.rmdir()
        record[3] = "true"  # Privileged records must never invoke sudo during preview.
    for name in ("conflict", "already"):
        (home / name).mkdir()
        (home / name / "new-data").write_text("keep destination\n")
    expected = {name: status for name, status in zip(names, ("conflict", "would restore", "already restored", "missing"))}
    for name, status in (("aged-ready", "would restore"), ("aged-conflict", "conflict"),
                         ("aged-symlink", "conflict"), ("aged-parent-symlink", "conflict"),
                         ("aged-file-root", "conflict"), ("aged-file-parent", "conflict"),
                         ("aged-complete", "already restored")):
        staging = session / name
        staging.mkdir()
        original = home / name
        if name != "aged-complete":
            (staging / "nested").mkdir()
            (staging / "nested/file").write_text("old data\n")
        if name == "aged-conflict":
            (original / "nested").mkdir(parents=True)
            (original / "nested/file").write_text("new data\n")
        elif name == "aged-symlink":
            original.symlink_to(home / "absent", target_is_directory=True)
        elif name == "aged-parent-symlink":
            original.mkdir()
            (original / "nested").symlink_to(home / "absent", target_is_directory=True)
        elif name == "aged-file-root":
            original.write_text("a file where the target directory was\n")
        elif name == "aged-file-parent":
            original.mkdir()
            (original / "nested").write_text("a file where a parent directory is needed\n")
        record_type = "aged-restored" if name == "aged-complete" else "aged"
        records.append([record_type, name, str(original), "true", str(os.getuid()), str(os.getgid())])
        expected[name] = status
    (home / "bogus").mkdir()
    (session / "bogus").mkdir()
    records.append(["bogus", "bogus", str(home / "bogus"), "true", str(os.getuid()), str(os.getgid())])
    expected["bogus"] = "unknown type"
    # A missing payload is reported before an unknown type, as the real restore does.
    records.append(["bogus", "bogus-gone", str(home / "bogus-gone"), "true", str(os.getuid()), str(os.getgid())])
    expected["bogus-gone"] = "missing"
    meta.write_text("\n".join("|".join(record) for record in records) + "\n")
    os.utime(session, (1577836800, 1577836800))
    lock = home / ".cache/linux-cleaner/cleaner.lock"
    lock.unlink(missing_ok=True)
    bindir = root / "bin"
    bindir.mkdir()
    trace = root / "forbidden-calls"
    for command in ("sudo", "mv", "cp", "rm", "mkdir", "rmdir", "chown", "touch", "mktemp", "flock"):
        stub = bindir / command
        stub.write_text('#!/bin/sh\nprintf "%s\\n" "$0" >> "$RESTORE_PREVIEW_TRACE"\nexit 99\n')
        stub.chmod(0o755)
    env.update(PATH=str(bindir) + ":" + env["PATH"], RESTORE_PREVIEW_TRACE=str(trace))

    def snapshot(path):
        listing = subprocess.check_output(["find", str(path), "-printf", "%P|%y|%m|%s|%T@|%l\n"])
        checksums = {str(p.relative_to(path)): hashlib.sha256(p.read_bytes()).hexdigest()
                     for p in path.rglob("*") if p.is_file() and not p.is_symlink()}
        return sorted(listing.splitlines()), checksums

    before = snapshot(home)
    meta_before, mtime_before = meta.read_bytes(), session.stat().st_mtime_ns
    cases = [
        ("all outcomes after trash", ["--restore", "latest", "--dry-run"], expected, 0),
        ("dry-run first", ["--dry-run", "--restore", session.name], expected, 0),
        ("substring selector", ["--restore", "latest", "--dry-run", "--only", "ready"],
         {name: status for name, status in expected.items() if "ready" in str(home / name)}, 0),
        ("exact selector", ["--restore", "latest", "--dry-run", "--only-exact", str(home / "ready")],
         {"ready": "would restore"}, 0),
        ("unmatched selector", ["--restore", "latest", "--dry-run", "--only-exact", str(home / "absent")], {}, 1),
    ]
    for label, args, selected, status in cases:
        result = subprocess.run([cleaner, "--log", str(home / "preview.log")] + args,
                                env=env, capture_output=True, text=True, timeout=20)
        assert result.returncode == status, (label, result)
        lines = result.stdout.splitlines()
        outcomes = [line for line in lines if line.startswith(("would restore  ", "conflict  ", "already restored  ", "missing  ", "unknown type  "))]
        assert sorted(outcomes) == sorted(f"{value}  {home / name}" for name, value in selected.items()), (label, result)
        if status == 0:
            assert lines[-1] == "Dry-run: nothing restored.", (label, result)
        else:
            assert "No quarantined target" in result.stderr, (label, result)
        assert snapshot(home) == before, (label, "tree listing or checksums changed")
        assert meta.read_bytes() == meta_before, (label, "metadata bytes changed")
        assert session.stat().st_mtime_ns == mtime_before, (label, "session mtime changed")
        assert not lock.exists() and not trace.exists(), (label, "lock or mutation call")
        print("PASS: Restore Preview " + label, flush=True)

    # A fresh HOME has no cleanup-created lock to reuse.
    fresh = root / "fresh-home"
    fresh_session = fresh / ".cache/linux-cleaner/quarantine" / session.name
    fresh_session.mkdir(parents=True)
    (fresh_session / "payload").write_text("keep quarantined\n")
    (fresh_session / "quarantine.meta").write_text(f"full|payload|{fresh}/destination|true|0|0\n")
    fresh_before = snapshot(fresh)
    result = subprocess.run([cleaner, "--restore", "latest", "--dry-run", "--lock-wait", "1"],
                            env=env | {"HOME": str(fresh)}, capture_output=True, text=True, timeout=20)
    assert result.returncode == 0 and f"would restore  {fresh}/destination" in result.stdout, result
    assert snapshot(fresh) == fresh_before and not trace.exists(), "fresh HOME changed or mutation tool called"
    assert not (fresh / ".cache/linux-cleaner/cleaner.lock").exists(), "preview created a lock"
    print("PASS: Restore Preview Fresh HOME Has No Lock", flush=True)
RESTORE_PREVIEW_PY

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

# Purge previews use the real selector/hold rules without opening the mutation path.
python3 - "$CLEANER_SH" "$TEST_ENV_DIR" <<'PURGE_PREVIEW_PY'
import fcntl, hashlib, os, pathlib, re, subprocess, sys, tempfile, time

cleaner = sys.argv[1]
with tempfile.TemporaryDirectory(prefix="purge-preview-", dir=sys.argv[2]) as directory:
    root = pathlib.Path(directory)
    bindir = root / "bin"
    bindir.mkdir()
    trace = root / "forbidden-calls"
    for command in ("sudo", "rm", "mkdir", "rmdir", "mv", "cp", "touch", "mktemp", "flock"):
        stub = bindir / command
        stub.write_text('#!/bin/sh\nprintf "%s\\n" "$0" >> "$PURGE_PREVIEW_TRACE"\nexit 99\n')
        stub.chmod(0o755)
    base_env = {k: v for k, v in os.environ.items() if not k.startswith(("LINUX_CLEANER_", "XDG_"))}
    names = [f"2020-01-0{i}_00-00-00" for i in range(1, 5)]
    cases = [("older-than:30", [0, 2], [1]), ("max-size:budget", [0], [1]),
             ("keep-latest:2", [0], [1]), ("latest", [3], []),
             ("all", [0, 2, 3], [1]), (names[2], [2], []),
             ("older-than:99999", [], []), ("max-size:1G", [], []),
             ("keep-latest:4", [], []), ("all-held", [], [0, 1, 2, 3])]

    def snapshot(home):
        result = {}
        for path in [home, *home.rglob("*")]:
            stat = path.lstat()
            result[str(path.relative_to(home))] = (
                stat.st_mode, stat.st_size, stat.st_mtime_ns, stat.st_ino,
                hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None)
        return result

    for index, (selector, selected, skipped) in enumerate(cases):
        home = root / str(index)
        quarantine = home / ".cache/linux-cleaner/quarantine"
        sessions = [quarantine / name for name in names]
        for i, session in enumerate(sessions):
            session.mkdir(parents=True)
            (session / "payload").write_bytes(b"x" * (64 * (i + 1)))
            (session / "quarantine.meta").write_text(f"full|payload|{home}/dest-{i}|false|0|0\n")
        (sessions[1] / ".hold").write_text("held\n")
        if selector == "all-held":
            selector = "all"
            for session in sessions:
                (session / ".hold").write_text("held\n")
        for session in sessions[:3]:
            os.utime(session, (time.time() - 40 * 86400,) * 2)
        if selector == "max-size:budget":
            budget = sum(int(subprocess.check_output(["du", "-sb", str(s)]).split()[0]) for s in sessions[2:])
            selector = f"max-size:{budget}"
        expected_rows = [f"  {names[i]}  size=" + subprocess.check_output(
            ["du", "-sh", str(sessions[i])], text=True).split()[0] for i in selected]
        log = home / "operations.log"
        log.write_text("existing log\n")
        report = home / "state/linux-cleaner/last-report.txt"
        report.parent.mkdir(parents=True)
        report.write_text("existing report\n")
        env = base_env | {"HOME": str(home), "XDG_STATE_HOME": str(home / "state"),
                          "XDG_CONFIG_HOME": str(home / "config"), "NO_COLOR": "1",
                          "LINUX_CLEANER_FORCE": "1", "LINUX_CLEANER_LOG": str(log),
                          "LINUX_CLEANER_PREVIEW_METRICS_FILE": str(home / "preview.prom"),
                          "LINUX_CLEANER_METRICS_FILE": str(home / "cleanup.prom")}
        preview_env = env | {"PATH": str(bindir) + ":" + env["PATH"], "PURGE_PREVIEW_TRACE": str(trace)}

        def preview(args, status=0):
            before = snapshot(home)
            result = subprocess.run([cleaner, *args], env=preview_env, stdin=subprocess.DEVNULL,
                                    capture_output=True, text=True, timeout=20)
            assert result.returncode == status, (selector, args, result)
            if status == 0:
                rows = [line for line in result.stdout.splitlines() if re.match(r"^  \S+  size=", line)]
                assert rows == expected_rows, (selector, rows, expected_rows, result)
                assert "Permanently delete" not in result.stdout and "Purged " not in result.stdout, result
                held = re.findall(r"^Skipping held session (\S+) ", result.stdout, re.M)
                assert held == [names[i] for i in skipped], (selector, held, skipped, result)
                if selected or skipped:
                    assert "=== Would purge Quarantine Sessions ===" in result.stdout, result
            assert snapshot(home) == before and not trace.exists(), (selector, "preview mutated state")
            return result

        args = ["--purge-sessions", selector, "--dry-run", "--log", str(home / "new.log")]
        preview(args)  # No lock exists yet, even with inherited FORCE and logging enabled.
        lock = home / ".cache/linux-cleaner/cleaner.lock"
        lock.write_text("keep lock contents\n")
        with lock.open("r+") as locked:
            fcntl.flock(locked, fcntl.LOCK_EX | fcntl.LOCK_NB)
            preview(["--dry-run", "--purge-sessions", selector, "--lock-wait", "1"])
            preview(["--force", *args])
            result = preview([*args, "--json"], 1)
            assert "json is valid only" in result.stderr, result
            if selector == "latest":
                (sessions[3] / ".hold").write_text("held latest\n")
                for held_selector in ("latest", names[3]):
                    result = preview(["--purge-sessions", held_selector, "--dry-run"], 1)
                    assert "is held" in result.stderr, result
                (sessions[3] / ".hold").unlink()
        result = subprocess.run([cleaner, "--purge-sessions", selector, "--force"], env=env,
                                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=20)
        assert result.returncode == 0, result
        deleted = [i for i, session in enumerate(sessions) if not session.exists()]
        assert deleted == selected, (selector, deleted, selected, result)
        assert re.findall(r"^Purged (\S+)$", result.stdout, re.M) == [names[i] for i in selected], result
        print("PASS: Purge Preview " + selector + " matches real purge without state changes", flush=True)
PURGE_PREVIEW_PY
setup_mock_env

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

setup_mock_env
rm -rf "$TEST_ENV_DIR/xdg_cfg"
if XDG_CONFIG_HOME="$TEST_ENV_DIR/xdg_cfg" run_test_case "Init Config Creates User Config" 0 "init_config_create.log" \
     --init-config -c "$TEST_ENV_DIR/test_cleaner.conf"; then
  if [[ -f "$TEST_ENV_DIR/xdg_cfg/linux-cleaner/cleaner.conf" ]] \
     && cmp -s "$TEST_ENV_DIR/test_cleaner.conf" "$TEST_ENV_DIR/xdg_cfg/linux-cleaner/cleaner.conf" \
     && [[ "$(stat -c %a "$TEST_ENV_DIR/xdg_cfg/linux-cleaner/cleaner.conf")" == "644" ]] \
     && grep -qF "Created " "$TEST_ENV_DIR/init_config_create.log"; then
    echo -e "${GREEN}PASS: --init-config created user config with mode 644 and matching content.${NC}"
  else
    echo -e "${RED}FAIL: --init-config did not create expected user config file or output.${NC}"
    cat "$TEST_ENV_DIR/init_config_create.log"
    exit 1
  fi
else
  exit 1
fi

if XDG_CONFIG_HOME="$TEST_ENV_DIR/xdg_cfg" run_test_case "Init Config Refuses Overwrite" 1 "init_config_overwrite.log" \
     --init-config -c "$TEST_ENV_DIR/test_cleaner.conf"; then
  if cmp -s "$TEST_ENV_DIR/test_cleaner.conf" "$TEST_ENV_DIR/xdg_cfg/linux-cleaner/cleaner.conf"; then
    echo -e "${GREEN}PASS: --init-config refuses to overwrite an existing user config.${NC}"
  else
    echo -e "${RED}FAIL: --init-config modified existing user config on second run.${NC}"
    cat "$TEST_ENV_DIR/init_config_overwrite.log"
    exit 1
  fi
else
  exit 1
fi

# Inject competing destinations only at the final publication command boundary.
python3 - "$CLEANER_SH" <<'INIT_PUBLICATION_PY'
import hashlib, os, pathlib, shutil, stat, subprocess, sys, tempfile
cleaner = sys.argv[1]
with tempfile.TemporaryDirectory(prefix="cleaner-init-publication-", dir="/tmp") as directory:
    root = pathlib.Path(directory)
    source = root / "source.conf"
    source.write_text("safe|Initializer Source|$HOME/cache|source fixture|0||\n")
    real_mv = shutil.which("mv")
    bindir = root / "bin"
    bindir.mkdir()
    wrapper = bindir / "mv"
    wrapper.write_text('''#!/usr/bin/env bash
set -euo pipefail
args=("$@")
[[ "${args[-1]}" == "$INIT_DEST" && "${args[-2]}" == "$INIT_DEST".tmp.* ]] || exit 97
[[ -f "${args[-2]}" && ! -e "$INIT_DEST" && ! -L "$INIT_DEST" ]] || exit 98
printf 'publication reached\\n' > "$INIT_TRACE"
case "$INIT_KIND" in
  regular) printf 'keep competitor\\n' > "$INIT_DEST" ;;
  directory) mkdir -- "$INIT_DEST"; printf 'keep competitor\\n' > "$INIT_DEST/keep" ;;
  symlink) ln -s -- "$INIT_REFERENT" "$INIT_DEST" ;;
  dangling) ln -s -- "$INIT_REFERENT.missing" "$INIT_DEST" ;;
  failure) exit 23 ;;
  success) ;;
  *) exit 99 ;;
esac
exec "$INIT_REAL_MV" "$@"
''')
    wrapper.chmod(0o755)
    base_env = {k: v for k, v in os.environ.items() if not k.startswith(("LINUX_CLEANER_", "XDG_"))}
    for kind in ("regular", "directory", "symlink", "dangling", "failure", "success"):
        print("Test Case: Init Config Publication " + kind, flush=True)
        case = root / kind
        home = case / "home"
        config_dir = home / ".config/linux-cleaner"
        config_dir.mkdir(parents=True)
        dest = config_dir / "cleaner.conf"
        referent = home / "referent"
        referent.write_text("keep referent\n")
        for name in ("cache/payload", "state/linux-cleaner/last-report.txt", ".cache/linux-cleaner/ops.log",
                     ".cache/linux-cleaner/quarantine/2099-01-01_00-00-00/quarantine.meta"):
            path = home / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("keep sentinel\n")
        def snapshot():
            return {str(p.relative_to(home)): (stat.S_IMODE(p.lstat().st_mode),
                    os.readlink(p) if p.is_symlink() else hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else None)
                    for p in home.rglob("*") if p != dest and dest not in p.parents}
        before = snapshot()
        trace = case / "publication.log"
        env = base_env | dict(HOME=str(home), XDG_CONFIG_HOME=str(home / ".config"), NO_COLOR="1",
                              PATH=str(bindir) + ":" + base_env["PATH"], INIT_DEST=str(dest), INIT_KIND=kind,
                              INIT_REFERENT=str(referent), INIT_TRACE=str(trace), INIT_REAL_MV=real_mv)
        result = subprocess.run([cleaner, "--init-config", "--config", str(source)], env=env,
                                capture_output=True, text=True, timeout=20)
        assert trace.is_file(), (kind, result)
        assert not list(config_dir.glob("cleaner.conf.tmp.*")), (kind, "temporary leak")
        if kind == "success":
            assert result.returncode == 0 and "Created " in result.stdout, result
            assert dest.read_bytes() == source.read_bytes() and stat.S_IMODE(dest.stat().st_mode) == 0o644
        else:
            assert result.returncode == 1 and "Created " not in result.stdout, (kind, result)
            assert ("Failed to move" if kind == "failure" else "refusing to overwrite") in result.stderr, result
            if kind == "regular":
                assert dest.is_file() and not dest.is_symlink() and dest.read_text() == "keep competitor\n"
            elif kind == "directory":
                assert dest.is_dir() and not dest.is_symlink() and (dest / "keep").read_text() == "keep competitor\n"
            elif kind in ("symlink", "dangling"):
                assert dest.is_symlink() and os.readlink(dest) == str(referent) + (".missing" if kind == "dangling" else "")
                assert not pathlib.Path(str(referent) + ".missing").exists()
            else:
                assert not dest.exists() and not dest.is_symlink()
        assert snapshot() == before, (kind, "unrelated state changed")
        assert source.read_text() == "safe|Initializer Source|$HOME/cache|source fixture|0||\n"
        print("PASS: Init Config Publication " + kind, flush=True)
INIT_PUBLICATION_PY

echo -e "\n${BOLD}Test Case: Init Config Used By Next Run${NC}"
init_next_ec=0
env -u LINUX_CLEANER_CONFIG XDG_CONFIG_HOME="$TEST_ENV_DIR/xdg_cfg" PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
  "$CLEANER_SH" --check-config < /dev/null > "$TEST_ENV_DIR/init_config_next.log" 2>&1 || init_next_ec=$?
if [[ $init_next_ec -eq 0 ]] \
   && grep -qE "^OK: [0-9]+ targets in $TEST_ENV_DIR/xdg_cfg/linux-cleaner/cleaner\\.conf$" "$TEST_ENV_DIR/init_config_next.log"; then
  echo -e "${GREEN}PASS: --check-config discovers the user config created by --init-config.${NC}"
else
  echo -e "${RED}FAIL: --check-config did not use the created user config (ec=$init_next_ec).${NC}"
  cat "$TEST_ENV_DIR/init_config_next.log"
  exit 1
fi

rm -rf "$TEST_ENV_DIR/xdg_cfg" "$TEST_ENV_DIR/xdg_sym_target"
mkdir -p "$TEST_ENV_DIR/xdg_cfg" "$TEST_ENV_DIR/xdg_sym_target"
ln -s "$TEST_ENV_DIR/xdg_sym_target" "$TEST_ENV_DIR/xdg_cfg/linux-cleaner"
if XDG_CONFIG_HOME="$TEST_ENV_DIR/xdg_cfg" run_test_case "Init Config Refuses Symlinked Directory" 1 "init_config_symlink.log" \
     --init-config -c "$TEST_ENV_DIR/test_cleaner.conf"; then
  if [[ -z "$(find "$TEST_ENV_DIR/xdg_sym_target" -mindepth 1 -print -quit)" ]]; then
    echo -e "${GREEN}PASS: --init-config refuses a symlinked linux-cleaner directory and writes nothing into the target.${NC}"
  else
    echo -e "${RED}FAIL: --init-config wrote into the symlink target directory.${NC}"
    cat "$TEST_ENV_DIR/init_config_symlink.log"
    exit 1
  fi
else
  exit 1
fi

if XDG_CONFIG_HOME="$TEST_ENV_DIR/xdg_cfg" run_test_case "Init Config With List Targets Rejected" 1 "init_config_nolist.log" \
     --init-config --list-targets; then
  if grep -q "cannot be combined" "$TEST_ENV_DIR/init_config_nolist.log"; then
    echo -e "${GREEN}PASS: --init-config with --list-targets is rejected.${NC}"
  else
    echo -e "${RED}FAIL: --init-config with --list-targets did not print mutual exclusion error.${NC}"
    cat "$TEST_ENV_DIR/init_config_nolist.log"
    exit 1
  fi
else
  exit 1
fi
rm -rf "$TEST_ENV_DIR/xdg_cfg" "$TEST_ENV_DIR/xdg_sym_target"

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

# Inventory NAME Selection: share cleanup matching without disk or process analysis.
setup_mock_env
python3 - "$CLEANER_SH" "$TEST_ENV_DIR" <<'INVENTORY_PY'
import hashlib, json, os, pathlib, stat, subprocess, sys
cleaner, test_dir = sys.argv[1:]
root = pathlib.Path(test_dir) / "name-inventory"
home = root / "home"
(home / "cache").mkdir(parents=True)
(home / "cache/payload").write_text("keep cache data\n")
for child in ("a", "b"):
    (home / "builds" / child).mkdir(parents=True)
state = home / "state/linux-cleaner"
state.mkdir(parents=True)
(state / "last-report.txt").write_text("keep saved report\n")
session = home / ".cache/linux-cleaner/quarantine/2020-01-01_00-00-00"
session.mkdir(parents=True)
(session / "quarantine.meta").write_text("keep metadata\n")
(session / "payload").write_text("keep recovery data\n")
config = root / "inventory.conf"
config.write_text("""safe|NPM Cache|$HOME/cache|npm|0|node|action:uv_cache_prune
medium|npm Lower|$HOME/cache|lower case|0|node|
danger|Yarn Cache|$HOME/cache|yarn|0|node|
medium|Literal[*?] Cache|$HOME/cache|literal patterns|0||
safe|Literalabc Cache|$HOME/cache|ordinary letters|0||
safe|Wild Builds|$HOME/builds/*|wildcard inventory|0||
protect|$HOME/cache
""")
bindir = root / "bin"
bindir.mkdir()
trace = root / "forbidden-calls"
for command in ("du", "pgrep", "df", "sudo", "rm", "mv", "flock", "uv", "pnpm", "hf", "paccache", "pacman"):
    stub = bindir / command
    stub.write_text('#!/bin/sh\nprintf "%s\\n" "$0" >> "$INVENTORY_TRACE"\nexit 99\n')
    stub.chmod(0o755)
env = {key: value for key, value in os.environ.items()
       if not key.startswith(("LINUX_CLEANER_", "XDG_"))}
env.update(HOME=str(home), XDG_STATE_HOME=str(home / "state"),
           PATH=str(bindir) + ":" + env["PATH"], NO_COLOR="1", INVENTORY_TRACE=str(trace))
def snapshot():
    return {str(path.relative_to(home)): (stat.S_IMODE(path.stat().st_mode),
            hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None)
            for path in home.rglob("*")}
before = snapshot()
all_names = ["NPM Cache", "npm Lower", "Yarn Cache", "Literal[*?] Cache", "Literalabc Cache", "Wild Builds", "Wild Builds"]
cases = [
    ("include", ["--only-target", "NPM"], {}, ["NPM Cache"], None),
    ("comma spaces", ["--only-target", " NPM , Yarn "], {}, ["NPM Cache", "Yarn Cache"], None),
    ("exclude comma", ["--exclude-target", " NPM , Yarn "], {}, [n for n in all_names if n not in ("NPM Cache", "Yarn Cache")], None),
    ("exclusion wins", ["--only-target", "NPM,Yarn", "--exclude-target", "Yarn"], {}, ["NPM Cache"], None),
    ("case", ["--only-target", "npm"], {}, ["npm Lower"], None),
    ("literal", ["--only-target", "[*?]"], {}, ["Literal[*?] Cache"], None),
    ("wildcard", ["--only-target", "Wild"], {}, ["Wild Builds", "Wild Builds"], None),
    ("no match", ["--only-target", "absent"], {}, [], "No config target NAME matches"),
    ("priority", ["--only-target", "absent", "--exclude-target", "Cache"], {}, [], "No config target NAME matches"),
    ("all excluded", ["--only-target", "NPM", "--exclude-target", "NPM"], {}, [], "left no config targets"),
    ("empty include", ["--only-target", "NPM,,Yarn"], {}, [], "empty pattern"),
    ("empty exclude", ["--exclude-target", "NPM,"], {}, [], "empty pattern"),
    ("environment", [], {"LINUX_CLEANER_ONLY_TARGET": "NPM,Yarn", "LINUX_CLEANER_EXCLUDE_TARGET": "Yarn"}, ["NPM Cache"], None),
    ("CLI overrides", ["--only-target", "Yarn", "--exclude-target", "NPM"], {"LINUX_CLEANER_ONLY_TARGET": "NPM", "LINUX_CLEANER_EXCLUDE_TARGET": "Yarn"}, ["Yarn Cache"], None),
]
# Commas are the only separators; LF is either trimmed field whitespace or a
# literal internal character, never a reason to discard the rest of the value.
for route in ("CLI", "environment"):
    for flag in ("only", "exclude"):
        for label, value, expected, error in (
            ("comma whitespace", "NPM,\nYarn", ["NPM Cache", "Yarn Cache"] if flag == "only" else [], None if flag == "only" else "left no config targets"),
            ("internal literal", "NPM\nYarn", [] if flag == "only" else ["NPM Cache"], "No config target NAME matches" if flag == "only" else None),
            ("later fields", "absent,\nNPM,Yarn", ["NPM Cache", "Yarn Cache"] if flag == "only" else [], None if flag == "only" else "left no config targets"),
            ("leading empty", ",\nNPM", [], "empty pattern"),
            ("hidden consecutive empty", "NPM,\n,Yarn", [], "empty pattern"),
            ("hidden trailing empty", "NPM,\nYarn,", [], "empty pattern"),
            ("hidden whitespace empty", "NPM,\n", [], "empty pattern"),
        ):
            args, overrides = [], {}
            if flag == "exclude":
                args = ["--only-target", "NPM" if label == "internal literal" else "NPM,Yarn"]
            if route == "CLI":
                args += ["--" + flag + "-target", value]
            else:
                overrides["LINUX_CLEANER_" + flag.upper() + "_TARGET"] = value
            cases.append(("LF " + route + " " + flag + " " + label, args, overrides, expected, error))
cases.append(("LF CLI overrides complete environment", ["--only-target", "NPM,\nYarn", "--exclude-target", "Yarn"],
              {"LINUX_CLEANER_ONLY_TARGET": "NPM\nYarn", "LINUX_CLEANER_EXCLUDE_TARGET": "NPM,\nYarn"}, ["NPM Cache"], None))
for fmt in ("human", "json"):
    for label, args, overrides, expected, error in cases:
        if label.startswith("LF "):
            print("Test Case: Inventory NAME Selection (" + fmt + " " + label + ")", flush=True)
        result = subprocess.run([cleaner, "--config", str(config), "--list-targets"] + args
                                + (["--json"] if fmt == "json" else []),
                                env=env | overrides, capture_output=True, text=True)
        assert result.returncode == (1 if error else 0), (fmt, label, result)
        if error:
            assert error in result.stderr, (fmt, label, result)
            if fmt == "json":
                assert result.stdout == "", (label, result.stdout)
        else:
            rows = json.loads(result.stdout)["targets"] if fmt == "json" else [
                dict(zip(("name", "risk", "path", "description"), line.split("\t")))
                for line in result.stdout.splitlines() if "\t" in line]
            assert sorted(row["name"] for row in rows) == sorted(expected), (fmt, label, rows)
            if label == "wildcard":
                assert {row["path"] for row in rows} == {str(home / "builds/a"), str(home / "builds/b")}, rows
        print("PASS: Inventory NAME Selection (" + fmt + " " + label + ")")
    config.write_text(config.read_text() + "safe|Filtered Invalid|$HOME/cache|bad age|invalid||\n")
    result = subprocess.run([cleaner, "--config", str(config), "--list-targets", "--only-target", "NPM"]
                            + (["--json"] if fmt == "json" else []), env=env, capture_output=True, text=True)
    assert result.returncode == 1 and "invalid MIN_AGE_DAYS" in result.stderr, result
    assert result.stdout == "", result
    config.write_text(config.read_text().split("safe|Filtered Invalid|")[0])
    print("PASS: Inventory NAME Selection (" + fmt + " raw validation)")
assert not trace.exists(), trace.read_text() if trace.exists() else ""
assert snapshot() == before, "inventory changed cache, quarantine, report, lock, or permissions"
print("PASS: Inventory NAME Selection leaves data unchanged without analysis or mutation commands")
# These selected targets are protected, so dry-run parity needs no sizing,
# process, action, privilege, or mutation probes either.
for label, args, overrides, expected, error in (
    ("comma whitespace", ["--only-target", "NPM,\nYarn"], {}, ["NPM Cache", "Yarn Cache"], None),
    ("internal exclusion", ["--only-target", "NPM", "--exclude-target", "NPM\nYarn"], {}, ["NPM Cache"], None),
    ("later fields", ["--only-target", "absent,\nNPM,Yarn"], {}, ["NPM Cache", "Yarn Cache"], None),
    ("environment composition", [], {"LINUX_CLEANER_ONLY_TARGET": "NPM,\nYarn", "LINUX_CLEANER_EXCLUDE_TARGET": "Yarn"}, ["NPM Cache"], None),
    ("hidden empty", ["--only-target", "NPM,\n,Yarn"], {}, [], "empty pattern"),
):
    print("Test Case: NAME LF Dry Run " + label, flush=True)
    result = subprocess.run([cleaner, "--config", str(config), "--dry-run", "--json", "--risk", "danger"] + args,
                            env=env | overrides, capture_output=True, text=True)
    assert result.returncode == (1 if error else 0), (label, result)
    if error:
        assert error in result.stderr and result.stdout == "", (label, result)
    else:
        targets = json.loads(result.stdout)["targets"]
        assert [t["name"] for t in targets] == expected and all(t["status"] == "protected" for t in targets), (label, targets)
    assert snapshot() == before and not trace.exists(), "preview changed state or probed analysis/mutation tools"
    print("PASS: NAME LF Dry Run " + label, flush=True)
INVENTORY_PY

# trim must preserve values that bash echo treats as options across config and
# both NAME filter interfaces.
echo "Test Case: NAME Trim Echo Options"
python3 - "$CLEANER_SH" "$TEST_ENV_DIR" <<'TRIM_OPTIONS_PY'
import json, os, pathlib, subprocess, sys
cleaner, test_dir = sys.argv[1:]
root = pathlib.Path(test_dir) / "trim-options"
root.mkdir()
home = root / "home"
(home / "cache").mkdir(parents=True)
(home / "cache/payload").write_text("keep fixture payload\n")
before = {str(path.relative_to(home)): path.read_bytes() if path.is_file() else None
          for path in home.rglob("*")}
config = root / "trim-options.conf"
config.write_text(r"""safe|-n|$HOME/cache|-n|0||
safe|-e|$HOME/cache|-e|0||
safe|-E|$HOME/cache|100% backslash\path|0||
safe|-ne|$HOME/cache|-ne|0||
protect|$HOME/cache
""")
env = {key: value for key, value in os.environ.items()
       if not key.startswith(("LINUX_CLEANER_", "XDG_"))}
env.update(HOME=str(home), NO_COLOR="1")
def run(args, overrides=None):
    return subprocess.run([cleaner, "--config", str(config)] + args,
                          env=env | (overrides or {}), capture_output=True, text=True)
def names(result):
    assert result.returncode == 0, result
    return json.loads(result.stdout)["targets"]
for args, overrides, expected in (
    (["--list-targets", "--json", "--only-target", "-n"], {}, ["-n", "-ne"]),
    (["--list-targets", "--json", "--only-target", " \t-n \n"], {}, ["-n", "-ne"]),
    (["--list-targets", "--json"], {"LINUX_CLEANER_ONLY_TARGET": "-E"}, ["-E"]),
    (["--list-targets", "--json", "--exclude-target", "-e"], {}, ["-n", "-E", "-ne"]),
    (["--list-targets", "--json"], {"LINUX_CLEANER_EXCLUDE_TARGET": "-ne"}, ["-n", "-e", "-E"]),
):
    rows = names(run(args, overrides))
    assert [row["name"] for row in rows] == expected, (args, overrides, rows)
rows = names(run(["--list-targets", "--json"]))
assert [(row["name"], row["description"]) for row in rows] == [
    ("-n", "-n"), ("-e", "-e"), ("-E", r"100% backslash\path"), ("-ne", "-ne")], rows
check = run(["--check-config"])
assert check.returncode == 0, check
empty = run(["--list-targets", "--json", "--only-target", ",-n"])
assert empty.returncode == 1 and "empty pattern" in empty.stderr and empty.stdout == "", empty
preview = run(["--dry-run", "--json", "--risk", "danger", "--only-target", "-n"])
preview_rows = json.loads(preview.stdout)["targets"]
assert preview.returncode == 0 and [row["name"] for row in preview_rows] == ["-n", "-ne"], preview
assert all(row["status"] == "protected" for row in preview_rows), preview_rows
assert {str(path.relative_to(home)): path.read_bytes() if path.is_file() else None
        for path in home.rglob("*")} == before
print("PASS: NAME Trim Echo Options")
TRIM_OPTIONS_PY

# Positive PATH scope narrows shared wildcard NAMEs without widening side effects.
setup_mock_env
python3 - "$CLEANER_SH" "$TEST_ENV_DIR" <<'ONLY_PATH_PY'
import hashlib, json, os, pathlib, shutil, stat, subprocess, sys, tempfile, time
cleaner, test_dir = sys.argv[1:]
with tempfile.TemporaryDirectory(prefix="cleaner-only-path-", dir="/tmp") as directory:
    root = pathlib.Path(directory)
    home = root / "home"
    projects = home / "projects"
    alpha = projects / "alpha [*?] space"
    beta = projects / "beta"
    sibling = projects / "alpha [*?] space-sibling"
    for project in (alpha, beta, sibling):
        for leaf, files in (("build", ("CMakeCache.txt", "object.o")), ("logs", ("keep.log", "old.log"))):
            target = project / leaf
            target.mkdir(parents=True)
            for name in files:
                (target / name).write_text("keep fixture payload\n")
    for leaf in ("plain/cache", "plain/blocked", "plain/protected", "plain/aged", "medium/cache",
                 "fail-resolution", "no-targets", "lf-real", "lf-real\n"):
        target = home / leaf
        target.mkdir(parents=True)
        (target / "payload").write_text("keep " + leaf + "\n")
    (home / "plain/aged/old").write_text("old payload\n")
    os.utime(home / "plain/aged/old", (time.time() - 30 * 86400,) * 2)
    (home / "exact-file").write_text("exact file payload\n")
    outside = root / "outside/build"
    outside.mkdir(parents=True)
    (outside / "payload").write_text("outside payload\n")
    for link, target in ((home / "scope-alias", alpha), (home / "in-alias", alpha),
                         (home / "plain/out-alias", outside.parent),
                         (home / "link-target", home / "plain/cache"),
                         (home / "lf-alias", home / "lf-real\n")):
        link.symlink_to(target, target_is_directory=True)
    state = home / "state/linux-cleaner"
    state.mkdir(parents=True)
    (state / "last-report.txt").write_text("keep prior report\n")
    session = home / ".cache/linux-cleaner/quarantine/2099-01-01_00-00-00"
    session.mkdir(parents=True)
    (session / "quarantine.meta").write_text("keep metadata\n")
    (session / "payload").write_text("keep quarantine payload\n")
    config = root / "scope.conf"
    rows = [
        "safe|Shared Builds|$HOME/projects/*/build*|build outputs|0||filter:cxx_build",
        "safe|Shared Logs|$HOME/projects/*/logs|logs|0||exclude:keep*",
        "safe|Ancestor|$HOME/projects|ancestor must not match a child scope|0||",
        "safe|Alias In|$HOME/in-alias/build|physical inside alias|0||",
        "safe|Alias Out|$HOME/plain/out-alias/build|physical outside alias|0||",
        "safe|Literal File|$HOME/exact-file|ordinary file|0||",
        "safe|Plain Cache|$HOME/plain/cache|ordinary directory|0||",
        "safe|Blocked Cache|$HOME/plain/blocked|process guard|0|scope_blocked|",
        "safe|Protected Cache|$HOME/plain/protected|protected directory|0||",
        "safe|Aged Cache|$HOME/plain/aged|age guard|7||",
        "medium|Medium Cache|$HOME/medium/cache|risk guard|0||",
        "safe|Shared Action|$HOME/projects/*/build*|external effects excluded|0||action:uv_cache_prune",
        "safe|Missing|$HOME/missing|unresolved candidate|0||",
        "safe|Failed Resolution|$HOME/fail-resolution|failed resolver|0||",
        "safe|LF Alias|$HOME/lf-alias|physical LF must not truncate|0||",
        "safe|Symlink Target|$HOME/link-target|symlink guard|0||",
        "protect|$HOME/plain/protected",
    ]
    def write_config(selected=rows):
        config.write_text("\n".join(selected) + "\n")
    write_config()
    bindir, invbin = root / "bin", root / "inventory-bin"
    bindir.mkdir()
    invbin.mkdir()
    trace = root / "forbidden-calls"
    forbidden = '#!/bin/sh\nprintf "%s\\n" "$0" >> "$SCOPE_TRACE"\nexit 99\n'
    for command in ("uv", "pnpm", "hf", "paccache", "pacman", "apt-get", "dnf", "zypper", "apk"):
        (bindir / command).write_text(forbidden)
    for command in ("du", "pgrep", "df", "sudo", "rm", "mv", "flock"):
        (invbin / command).write_text(forbidden)
    (bindir / "pgrep").write_text('#!/bin/sh\n[ "$2" = scope_blocked ]\n')
    realpath = shutil.which("realpath")
    (bindir / "realpath").write_text('#!/bin/bash\nif [[ "$1" == -e && "${!#}" == "${SCOPE_FAIL_RESOLVE:-}" ]]; then exit 23; fi\nexec "' + realpath + '" "$@"\n')
    for path in list(bindir.iterdir()) + list(invbin.iterdir()):
        path.chmod(0o755)
    env = {k: v for k, v in os.environ.items() if not k.startswith(("LINUX_CLEANER_", "XDG_"))}
    env.update(HOME=str(home), XDG_STATE_HOME=str(home / "state"), NO_COLOR="1", SCOPE_TRACE=str(trace))
    env["PATH"] = str(bindir) + ":" + env["PATH"]
    def run(label, args, error=None, inventory=False, overrides=None):
        print("Test Case: Only Path " + label, flush=True)
        current = env | (overrides or {})
        if inventory:
            current["PATH"] = str(invbin) + ":" + current["PATH"]
        result = subprocess.run([cleaner, "--config", str(config)] + args, env=current,
                                capture_output=True, text=True, timeout=20)
        assert result.returncode == (1 if error else 0), (label, result)
        if error:
            assert error in result.stderr, (label, result)
            if "--json" in args:
                assert result.stdout == "", (label, result)
        print("PASS: Only Path " + label, flush=True)
        return result
    def snapshot():
        return {str(p.relative_to(home)): (stat.S_IMODE(p.lstat().st_mode),
                os.readlink(p) if p.is_symlink() else hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else None)
                for p in home.rglob("*")}
    before = snapshot()
    selected = [str(alpha / "build"), str(alpha / "logs"), "$HOME/in-alias/build"]
    plain = ["$HOME/plain/cache", "$HOME/plain/blocked", "$HOME/plain/protected", "$HOME/plain/aged", "$HOME/link-target"]
    resolved = [str(p / leaf) for leaf in ("build", "logs") for p in (alpha, beta, sibling)] + [
        "$HOME/projects", "$HOME/in-alias/build", "$HOME/plain/out-alias/build", "$HOME/exact-file",
        "$HOME/plain/cache", "$HOME/plain/blocked", "$HOME/plain/protected", "$HOME/plain/aged",
        "$HOME/medium/cache", "$HOME/fail-resolution", "$HOME/link-target"]
    cases = [
        ("literal metacharacters and boundaries", ["--only-path", str(alpha)], selected, None, {}),
        ("trailing slash", ["--only-path", str(alpha) + "/"], selected, None, {}),
        ("scope alias", ["--only-path", str(home / "scope-alias")], selected, None, {}),
        ("exact directory", ["--only-path", str(home / "plain/cache")], ["$HOME/plain/cache", "$HOME/link-target"], None, {}),
        ("exact file", ["--only-path", str(home / "exact-file")], ["$HOME/exact-file"], None, {}),
        ("root", ["--only-path", "/"], resolved, None, {}),
        ("outside alias", ["--only-path", str(home / "plain")], plain, None, {}),
        ("NAME composition", ["--only-path", str(alpha), "--only-target", "Shared", "--exclude-target", "Logs,Action"], [str(alpha / "build")], None, {}),
        ("NAME error priority", ["--only-path", str(alpha), "--only-target", "absent"], [], "No config target NAME matches", {}),
        ("exclusion error priority", ["--only-path", str(alpha), "--only-target", "Shared", "--exclude-target", "Shared"], [], "left no config targets", {}),
        ("actions ineligible", ["--only-path", str(alpha), "--only-target", "Action"], [], "No eligible config target", {}),
        ("empty scope selection", ["--only-path", str(home / "no-targets")], [], "No eligible config target", {}),
        ("failed candidate resolution", ["--only-path", str(home), "--only-target", "Failed Resolution"], [], "No eligible config target", {"SCOPE_FAIL_RESOLVE": str(home / "fail-resolution")}),
        ("all risk levels", ["--only-path", str(home / "medium")], ["$HOME/medium/cache"], None, {}),
        ("last occurrence wins", ["--only-path", str(beta), "--only-path", str(alpha)], selected, None, {}),
        ("environment scope", [], selected, None, {"LINUX_CLEANER_ONLY_PATH": str(alpha)}),
        ("environment NAME composition", ["--only-target", "Shared", "--exclude-target", "Logs,Action"],
         [str(alpha / "build")], None, {"LINUX_CLEANER_ONLY_PATH": str(alpha)}),
        ("environment NAME error priority", ["--only-target", "absent"], [], "No config target NAME matches",
         {"LINUX_CLEANER_ONLY_PATH": str(alpha)}),
        ("CLI overrides environment", ["--only-path", str(alpha)], selected, None, {"LINUX_CLEANER_ONLY_PATH": str(beta)}),
        ("CLI overrides relative environment", ["--only-path", str(alpha)], selected, None, {"LINUX_CLEANER_ONLY_PATH": "projects"}),
        ("CLI overrides LF environment", ["--only-path", str(alpha)], selected, None, {"LINUX_CLEANER_ONLY_PATH": str(beta) + "\n"}),
    ]
    for fmt in ("human", "json"):
        for label, args, expected, error, overrides in cases:
            result = run(fmt + " " + label, ["--list-targets"] + args + (["--json"] if fmt == "json" else []),
                         error, inventory=True, overrides=overrides)
            if not error:
                paths = [r["path"] for r in json.loads(result.stdout)["targets"]] if fmt == "json" else [
                    line.split("\t")[2] for line in result.stdout.splitlines() if "\t" in line]
                assert sorted(paths) == sorted(expected), (fmt, label, paths, expected)
    for label, args, error, overrides in [
        ("missing argument", ["--only-path"], "literal absolute path", {}),
        ("empty argument", ["--only-path", ""], "literal absolute path", {}),
        ("relative argument", ["--only-path", "projects"], "literal absolute path", {}),
        ("LF argument", ["--only-path", str(home) + "\n"], "literal absolute path", {}),
        ("missing scope", ["--only-path", str(home / "missing-scope")], "must resolve", {}),
        ("LF scope alias", ["--only-path", str(home / "lf-alias")], "must resolve", {}),
        ("failed scope resolution", ["--only-path", str(alpha), "--clean", "--force"], "must resolve", {"SCOPE_FAIL_RESOLVE": str(alpha)}),
        ("relative environment", [], "literal absolute path", {"LINUX_CLEANER_ONLY_PATH": "projects"}),
        ("literal environment placeholder", [], "literal absolute path", {"LINUX_CLEANER_ONLY_PATH": "$HOME/projects"}),
        ("LF environment", [], "literal absolute path", {"LINUX_CLEANER_ONLY_PATH": str(alpha) + "\n"}),
        ("missing environment scope", [], "must resolve", {"LINUX_CLEANER_ONLY_PATH": str(home / "missing-scope")}),
        ("LF environment alias", [], "must resolve", {"LINUX_CLEANER_ONLY_PATH": str(home / "lf-alias")}),
        ("invalid CLI with valid environment", ["--only-path", "relative", "--only-path", str(alpha)], "literal absolute path",
         {"LINUX_CLEANER_ONLY_PATH": str(alpha)}),
    ]:
        run(label, args, error, inventory=True, overrides=overrides)
    for partner in (["--restore", "latest"], ["--purge-sessions", "all"], ["--list-sessions"],
                    ["--check-config"], ["--report"], ["--init-config"], ["--trash-keep-days", "0"]):
        run("mutex " + partner[0], ["--only-path", str(alpha)] + partner, "--only-path applies only", inventory=True)
        run("environment mutex " + partner[0], partner, "--only-path applies only", inventory=True,
            overrides={"LINUX_CLEANER_ONLY_PATH": str(alpha)})
    run("inherited retention mutex", ["--only-path", str(alpha)], "--only-path applies only", inventory=True,
        overrides={"LINUX_CLEANER_TRASH_KEEP_DAYS": "7"})
    run("environment retention mutex", [], "--only-path applies only", inventory=True,
        overrides={"LINUX_CLEANER_ONLY_PATH": str(alpha), "LINUX_CLEANER_TRASH_KEEP_DAYS": "7"})
    write_config(rows + ["safe|Excluded Invalid|$HOME/missing|invalid age|invalid||"])
    run("raw validation first", ["--only-path", str(home / "missing-scope"), "--only-target", "Shared", "--list-targets", "--json"],
        "invalid MIN_AGE_DAYS", inventory=True)
    run("environment raw validation first", ["--list-targets", "--json"], "invalid MIN_AGE_DAYS", inventory=True,
        overrides={"LINUX_CLEANER_ONLY_PATH": str(home / "missing-scope")})
    write_config()
    for label, overrides in (("unset environment", {}), ("empty environment", {"LINUX_CLEANER_ONLY_PATH": ""})):
        unscoped = run(label, ["--list-targets", "--json"], inventory=True, overrides=overrides)
        assert {"Shared Action", "Missing", "LF Alias"} <= {r["name"] for r in json.loads(unscoped.stdout)["targets"]}
    assert snapshot() == before and not trace.exists(), "inventory changed state or probed analysis/mutation tools"
    preview = run("dry-run parity", ["--only-path", str(alpha), "--only-target", "Shared", "--json"])
    assert [r["path"] for r in json.loads(preview.stdout)["targets"]] == [str(alpha / "build"), str(alpha / "logs")]
    env_preview = run("environment dry-run parity", ["--only-target", "Shared", "--json"],
                      overrides={"LINUX_CLEANER_ONLY_PATH": str(alpha)})
    assert json.loads(env_preview.stdout)["targets"] == json.loads(preview.stdout)["targets"]
    assert snapshot() == before and not trace.exists(), "preview changed fixture state or called an external action"
    risk = run("risk ceiling keeps selection valid", ["--only-path", str(home / "medium"), "--json"])
    assert json.loads(risk.stdout)["targets"] == []
    for name, target, status in [("Blocked", "plain/blocked", "blocked"), ("Protected", "plain/protected", "protected"),
                                 ("Symlink", "plain/cache", "symlink")]:
        result = run(name + " guard", ["--only-path", str(home / target), "--only-target", name, "--json"])
        assert [r["status"] for r in json.loads(result.stdout)["targets"]] == [status], result
    write_config([rows[14]])
    run("LF candidate cannot delete sibling", ["--only-path", str(home), "--clean", "--force"], "No eligible config target")
    assert (home / "lf-real/payload").read_text() == "keep lf-real\n"
    assert (home / "lf-real\n/payload").read_text() == "keep lf-real\n\n"
    write_config()
    run("clean one shared-NAME project", ["--only-path", str(alpha), "--only-target", "Shared", "--clean", "--force"])
    assert not (alpha / "build").exists() and not (alpha / "logs/old.log").exists()
    assert (alpha / "logs/keep.log").is_file()
    for project in (beta, sibling):
        assert (project / "build/object.o").is_file() and (project / "logs/old.log").is_file(), project
    assert (outside / "payload").read_text() == "outside payload\n" and not trace.exists()
    run("environment clean one shared-NAME project", ["--only-target", "Shared", "--clean", "--force"],
        overrides={"LINUX_CLEANER_ONLY_PATH": str(beta)})
    assert not (beta / "build").exists() and not (beta / "logs/old.log").exists()
    assert (beta / "logs/keep.log").is_file() and (alpha / "logs/keep.log").is_file()
    assert (sibling / "build/object.o").is_file() and (sibling / "logs/old.log").is_file()
    assert (outside / "payload").read_text() == "outside payload\n" and not trace.exists()
    run("age guard cleanup", ["--only-path", str(home / "plain/aged"), "--clean", "--force"])
    assert not (home / "plain/aged/old").exists() and (home / "plain/aged/payload").is_file()
ONLY_PATH_PY

echo -e "\n${BOLD}Test Case: Exclude Path Wildcard Dry Run JSON${NC}"
setup_mock_env
mkdir -p "$MOCK_HOME/proj_a/build" "$MOCK_HOME/proj_b/build" "$MOCK_HOME/proj_ab/build"
echo "obj_a" > "$MOCK_HOME/proj_a/build/a.o"
echo "obj_b" > "$MOCK_HOME/proj_b/build/b.o"
echo "obj_ab" > "$MOCK_HOME/proj_ab/build/ab.o"
cat > "$TEST_ENV_DIR/exclude_path.conf" <<'EOF'
safe|C++ Build Dirs|$HOME/**/build*|Wildcard build directories|0||
safe|Action In Excluded|$HOME/proj_a/build|Action under excluded path|0||action:uv_cache_prune
safe|Missing Target|$HOME/never_created|Missing target is never excluded|0||
EOF
if run_test_case "Exclude Path Wildcard Dry Run JSON" 0 "exclude_path_json.log" \
     --config "$TEST_ENV_DIR/exclude_path.conf" --exclude-path "$MOCK_HOME/proj_a" --dry-run --json \
   && run_test_case "Exclude Path List Targets" 0 "exclude_path_list.log" \
     --config "$TEST_ENV_DIR/exclude_path.conf" --exclude-path "$MOCK_HOME/proj_a" --list-targets \
   && run_test_case "Exclude Path List Targets JSON" 0 "exclude_path_list_json.log" \
     --config "$TEST_ENV_DIR/exclude_path.conf" --exclude-path "$MOCK_HOME/proj_a" --list-targets --json; then
  if python3 - "$TEST_ENV_DIR/exclude_path_json.log" "$TEST_ENV_DIR/exclude_path_list.log" "$TEST_ENV_DIR/exclude_path_list_json.log" "$MOCK_HOME" <<'PY'
import json, sys
dry_log, list_log, list_json_log, home = sys.argv[1:]
dry = json.load(open(dry_log))
dry_paths = [t["path"] for t in dry["targets"]]
assert f"{home}/proj_a/build" not in dry_paths, dry_paths
assert f"{home}/proj_b/build" in dry_paths, dry_paths
assert f"{home}/proj_ab/build" in dry_paths, dry_paths
assert f"{home}/never_created" in dry_paths, dry_paths
list_text = open(list_log).read()
assert f"{home}/proj_a/build" not in list_text, list_text
assert f"{home}/proj_b/build" in list_text and f"{home}/proj_ab/build" in list_text, list_text
assert "$HOME/never_created" in list_text, list_text
lt = json.load(open(list_json_log))
lt_paths = [t["path"] for t in lt["targets"]]
assert f"{home}/proj_a/build" not in lt_paths, lt_paths
assert f"{home}/proj_b/build" in lt_paths and f"{home}/proj_ab/build" in lt_paths, lt_paths
assert "$HOME/never_created" in lt_paths, lt_paths
PY
  then
    echo -e "${GREEN}PASS: --exclude-path omits targets at/below the path in --dry-run --json and --list-targets while keeping other matches and missing targets.${NC}"
  else
    echo -e "${RED}FAIL: --exclude-path did not filter expected targets in --dry-run --json or --list-targets.${NC}"
    cat "$TEST_ENV_DIR/exclude_path_json.log"
    exit 1
  fi
else
  exit 1
fi

echo -e "\n${BOLD}Test Case: Exclude Path Wildcard Force Cleanup${NC}"
if run_test_case "Exclude Path Wildcard Force Cleanup" 0 "exclude_path_force.log" \
     --config "$TEST_ENV_DIR/exclude_path.conf" --exclude-path "$MOCK_HOME/proj_a" --force; then
  if [[ -f "$MOCK_HOME/proj_a/build/a.o" && ! -d "$MOCK_HOME/proj_b/build" && ! -d "$MOCK_HOME/proj_ab/build" ]]; then
    echo -e "${GREEN}PASS: --exclude-path leaves excluded wildcard match intact under --force while cleaning other matches.${NC}"
  else
    echo -e "${RED}FAIL: --exclude-path --force did not preserve only the excluded path.${NC}"
    cat "$TEST_ENV_DIR/exclude_path_force.log"
    exit 1
  fi
else
  exit 1
fi

echo -e "\n${BOLD}Test Case: Exclude Path Env Mirror${NC}"
mkdir -p "$MOCK_HOME/proj_a/build" "$MOCK_HOME/proj_b/build"
echo "obj_a" > "$MOCK_HOME/proj_a/build/a.o"
echo "obj_b" > "$MOCK_HOME/proj_b/build/b.o"
if LINUX_CLEANER_EXCLUDE_PATH="$MOCK_HOME/proj_a" \
     run_test_case "Exclude Path Env Mirror" 0 "exclude_path_env.log" \
     --config "$TEST_ENV_DIR/exclude_path.conf" --dry-run --json \
   && LINUX_CLEANER_EXCLUDE_PATH="$MOCK_HOME/proj_a" \
     run_test_case "Exclude Path CLI Overrides Env" 0 "exclude_path_cli_override.log" \
     --config "$TEST_ENV_DIR/exclude_path.conf" --exclude-path "$MOCK_HOME/proj_b" --force; then
  if python3 - "$TEST_ENV_DIR/exclude_path_env.log" "$MOCK_HOME" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
home = sys.argv[2]
paths = [t["path"] for t in data["targets"]]
assert f"{home}/proj_a/build" not in paths and f"{home}/proj_b/build" in paths, paths
PY
  then
    if [[ ! -d "$MOCK_HOME/proj_a/build" && -f "$MOCK_HOME/proj_b/build/b.o" ]]; then
      echo -e "${GREEN}PASS: LINUX_CLEANER_EXCLUDE_PATH filters targets and is overridden by CLI --exclude-path.${NC}"
    else
      echo -e "${RED}FAIL: CLI --exclude-path did not override LINUX_CLEANER_EXCLUDE_PATH during --force.${NC}"
      cat "$TEST_ENV_DIR/exclude_path_cli_override.log"
      exit 1
    fi
  else
    echo -e "${RED}FAIL: LINUX_CLEANER_EXCLUDE_PATH did not exclude the expected target in --dry-run --json.${NC}"
    cat "$TEST_ENV_DIR/exclude_path_env.log"
    exit 1
  fi
else
  exit 1
fi

echo -e "\n${BOLD}Test Case: Exclude Path Nonexistent Path${NC}"
if run_test_case "Exclude Path Nonexistent Path" 1 "exclude_path_nonexistent.log" \
     --config "$TEST_ENV_DIR/exclude_path.conf" --exclude-path "$MOCK_HOME/no_such_dir" --dry-run \
   && run_test_case "Exclude Path Missing Value Refused" 1 "exclude_path_optval.log" \
     --config "$TEST_ENV_DIR/exclude_path.conf" --exclude-path --dry-run \
   && run_test_case "Exclude Path Relative Path Refused" 1 "exclude_path_rel.log" \
     --config "$TEST_ENV_DIR/exclude_path.conf" --exclude-path "relative/path" --dry-run; then
  if grep -qF "Error: --exclude-path must resolve to an existing path without line feeds: '$MOCK_HOME/no_such_dir'." "$TEST_ENV_DIR/exclude_path_nonexistent.log" \
     && grep -qF "Error: --exclude-path requires a value, got option '--dry-run'." "$TEST_ENV_DIR/exclude_path_optval.log" \
     && grep -qF "Error: --exclude-path requires a literal absolute path without line feeds." "$TEST_ENV_DIR/exclude_path_rel.log"; then
    echo -e "${GREEN}PASS: --exclude-path rejects nonexistent, option-like, and relative paths with exit 1.${NC}"
  else
    echo -e "${RED}FAIL: --exclude-path validation errors did not match expected messages.${NC}"
    cat "$TEST_ENV_DIR/exclude_path_nonexistent.log" "$TEST_ENV_DIR/exclude_path_optval.log" "$TEST_ENV_DIR/exclude_path_rel.log"
    exit 1
  fi
else
  exit 1
fi

echo -e "\n${BOLD}Test Case: Exclude Path Left No Targets${NC}"
mkdir -p "$MOCK_HOME/proj_a/build"
cat > "$TEST_ENV_DIR/exclude_path_only_a.conf" <<'EOF'
safe|Only A Build|$HOME/proj_a/build|Only target|0||
EOF
if run_test_case "Exclude Path Left No Targets" 1 "exclude_path_empty.log" \
     --config "$TEST_ENV_DIR/exclude_path_only_a.conf" --exclude-path "$MOCK_HOME/proj_a" --dry-run; then
  if grep -qF "Error: --exclude-path $MOCK_HOME/proj_a left no config targets to process." "$TEST_ENV_DIR/exclude_path_empty.log"; then
    echo -e "${GREEN}PASS: --exclude-path exits 1 when it removes every remaining target.${NC}"
  else
    echo -e "${RED}FAIL: --exclude-path did not emit the expected left-no-targets error.${NC}"
    cat "$TEST_ENV_DIR/exclude_path_empty.log"
    exit 1
  fi
else
  exit 1
fi

echo -e "\n${BOLD}Test Case: Exclude Path Parent Target${NC}"
setup_mock_env
mkdir -p "$MOCK_HOME/.cache/t/keep" "$MOCK_HOME/.cache/other"
echo "keep_payload" > "$MOCK_HOME/.cache/t/keep/f"
echo "other_payload" > "$MOCK_HOME/.cache/other/f"
cat > "$TEST_ENV_DIR/exclude_path_parent.conf" <<'EOF'
safe|Parent Target|$HOME/.cache/t|Parent target containing excluded subdir|0||
safe|Other Target|$HOME/.cache/other|Unrelated target|0||
EOF
if run_test_case "Exclude Path Parent Target List Targets" 0 "exclude_path_parent_list.log" \
     --config "$TEST_ENV_DIR/exclude_path_parent.conf" --exclude-path "$MOCK_HOME/.cache/t/keep" --list-targets \
   && run_test_case "Exclude Path Parent Target Force Cleanup" 0 "exclude_path_parent_force.log" \
     --config "$TEST_ENV_DIR/exclude_path_parent.conf" --exclude-path "$MOCK_HOME/.cache/t/keep" --force; then
  if ! grep -q "Parent Target" "$TEST_ENV_DIR/exclude_path_parent_list.log" \
     && grep -q "Other Target" "$TEST_ENV_DIR/exclude_path_parent_list.log" \
     && [[ -f "$MOCK_HOME/.cache/t/keep/f" && ! -d "$MOCK_HOME/.cache/other" ]]; then
    echo -e "${GREEN}PASS: --exclude-path skips parent target containing the excluded path in --list-targets and --force while cleaning unrelated rows.${NC}"
  else
    echo -e "${RED}FAIL: --exclude-path did not skip parent target or failed to clean unrelated row.${NC}"
    cat "$TEST_ENV_DIR/exclude_path_parent_list.log" "$TEST_ENV_DIR/exclude_path_parent_force.log"
    exit 1
  fi
else
  exit 1
fi

echo -e "\n${BOLD}Test Case: Exclude Path Symlinked Parent${NC}"
setup_mock_env
mkdir -p "$MOCK_HOME/.cache" "$OUTSIDE_DIR/x/build" "$MOCK_HOME/other"
ln -s "$OUTSIDE_DIR/x" "$MOCK_HOME/.cache/x"
echo "sym_payload" > "$OUTSIDE_DIR/x/build/f"
echo "other_payload" > "$MOCK_HOME/other/f"
cat > "$TEST_ENV_DIR/exclude_path_sym_parent.conf" <<'EOF'
safe|Symlinked Parent Target|$HOME/.cache/x/build|Target under symlinked parent|0||
safe|Other Target|$HOME/other|Unrelated target outside symlinked branch|0||
EOF
if run_test_case "Exclude Path Symlinked Parent List Targets" 0 "exclude_path_sym_list.log" \
     --config "$TEST_ENV_DIR/exclude_path_sym_parent.conf" --exclude-path "$MOCK_HOME/.cache" --list-targets \
   && run_test_case "Exclude Path Symlinked Parent Force Cleanup" 0 "exclude_path_sym_force.log" \
     --config "$TEST_ENV_DIR/exclude_path_sym_parent.conf" --exclude-path "$MOCK_HOME/.cache" --force; then
  if ! grep -q "Symlinked Parent Target" "$TEST_ENV_DIR/exclude_path_sym_list.log" \
     && grep -q "Other Target" "$TEST_ENV_DIR/exclude_path_sym_list.log" \
     && [[ -f "$OUTSIDE_DIR/x/build/f" && ! -d "$MOCK_HOME/other" ]]; then
    echo -e "${GREEN}PASS: --exclude-path skips target reaching or reached through a symlinked parent in --list-targets and --force.${NC}"
  else
    echo -e "${RED}FAIL: --exclude-path did not skip target under symlinked parent.${NC}"
    cat "$TEST_ENV_DIR/exclude_path_sym_list.log" "$TEST_ENV_DIR/exclude_path_sym_force.log"
    exit 1
  fi
else
  exit 1
fi


# The shipped monitor command stays a preview with optional independent settings.
python3 - "$CLEANER_SH" "$SCRIPT_DIR/examples/systemd/linux-cleaner-monitor.service" <<'MONITOR_PROFILE_PY'
import hashlib, json, os, pathlib, shlex, stat, subprocess, sys, tempfile
cleaner, unit_path = sys.argv[1:]
unit = pathlib.Path(unit_path).read_text().splitlines()
command = shlex.split(next(line.removeprefix("ExecStart=") for line in unit if line.startswith("ExecStart=")))
profile_spec = next(line.removeprefix("EnvironmentFile=") for line in unit if line.startswith("EnvironmentFile="))
assert profile_spec == "-%h/.config/linux-cleaner/monitor.env"
assert command == ["/usr/bin/env", "cleaner", "--quiet", "--dry-run", "--json"]
assert not any(line.startswith("Environment=LINUX_CLEANER_JSON=") for line in unit)
with tempfile.TemporaryDirectory(prefix="cleaner-monitor-profile-", dir="/tmp") as directory:
    root = pathlib.Path(directory)
    home, bindir = root / "home", root / "bin"
    config_dir = home / ".config/linux-cleaner"
    config_dir.mkdir(parents=True)
    bindir.mkdir()
    (bindir / "cleaner").symlink_to(cleaner)
    trace = root / "forbidden-calls"
    for name in ("rm", "mv", "mkdir", "flock", "sudo", "uv", "pnpm", "hf", "pacman", "paccache"):
        path = bindir / name
        path.write_text('#!/bin/sh\nprintf "%s\\n" "$0" >> "$MONITOR_TRACE"\nexit 99\n')
        path.chmod(0o755)
    (bindir / "pgrep").write_text("#!/bin/sh\nexit 1\n")
    (bindir / "pgrep").chmod(0o755)
    alpha = home / "projects/alpha [*?] space"
    for project in (alpha, home / "projects/beta"):
        cache = project / "cache"
        cache.mkdir(parents=True)
        for name, size in (("eligible", 13), ("global.keep", 11), ("row.keep", 7)):
            (cache / name).write_bytes(b"x" * size)
    (home / "default").write_bytes(b"x" * 31)
    for name, size in (("projects/alpha [*?] space/medium", 17),
                       ("projects/alpha [*?] space/other", 19)):
        path = home / name
        path.mkdir(parents=True)
        (path / "payload").write_bytes(b"x" * size)
    default = config_dir / "cleaner.conf"
    default.write_text("safe|Default|$HOME/default|default config|0||\n")
    custom = root / "custom.conf"
    custom.write_text("safe|Shared Cache|$HOME/projects/*/cache|cache|0||exclude:row.keep\n"
                      "medium|Shared Medium|$HOME/projects/*/medium|medium|0||\n"
                      "safe|Other|$HOME/projects/*/other|other|0||\n"
                      "safe|Shared Action|$HOME/default|external action|0||action:uv_cache_prune\n")
    for name in ("state/linux-cleaner/last-report.txt", ".cache/linux-cleaner/ops.log",
                 ".cache/linux-cleaner/quarantine/2099-01-01_00-00-00/quarantine.meta",
                 ".cache/linux-cleaner/quarantine/2099-01-01_00-00-00/payload"):
        path = home / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("keep sentinel\n")
    env = {k: v for k, v in os.environ.items() if not k.startswith(("LINUX_CLEANER_", "XDG_"))}
    env.update(HOME=str(home), XDG_CONFIG_HOME=str(home / ".config"), XDG_STATE_HOME=str(home / "state"),
               PATH=str(bindir) + ":" + env["PATH"], NO_COLOR="1", MONITOR_TRACE=str(trace))
    profile = pathlib.Path(profile_spec[1:].replace("%h", str(home)))
    shared = dict(LINUX_CLEANER_CONFIG=str(custom), LINUX_CLEANER_RISK="medium",
                  LINUX_CLEANER_ONLY_TARGET="Shared", LINUX_CLEANER_EXCLUDE_TARGET="Other",
                  LINUX_CLEANER_ONLY_PATH=str(alpha), LINUX_CLEANER_EXCLUDE="global.keep")
    cleanup_profile = config_dir / "env"
    cleanup_profile.write_text("\n".join(k + "=" + shlex.quote(v) for k, v in shared.items()) + "\n")
    def snapshot():
        return {str(p.relative_to(home)): (stat.S_IMODE(p.lstat().st_mode), p.lstat().st_mtime_ns,
                os.readlink(p) if p.is_symlink() else hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else None)
                for p in home.rglob("*")}
    def run(label, settings, expected=None, error=None, share=False):
        print("Test Case: Monitor Profile " + label, flush=True)
        if profile.exists() or profile.is_symlink():
            profile.unlink()
        if share:
            profile.symlink_to(cleanup_profile.name)
            assert profile.read_bytes() == cleanup_profile.read_bytes()
        elif settings is not None:
            profile.write_text("\n".join(k + "=" + shlex.quote(v) for k, v in settings.items()) + "\n")
        before = snapshot()
        # Supply controlled profile values directly; live systemd loading is not exercised.
        result = subprocess.run(command, env=env | (settings or {}), capture_output=True, text=True, timeout=20)
        assert result.returncode == (1 if error else 0), (label, result)
        if error:
            assert error in result.stderr and result.stdout == "", (label, result)
        else:
            data = json.loads(result.stdout)
            assert data["config"] == str(custom if settings and "LINUX_CLEANER_CONFIG" in settings else default)
            assert [(t["name"], t["bytes"]) for t in data["targets"]] == expected, (label, data)
            assert data["total_reclaimable_bytes"] == sum(size for _, size in expected), (label, data)
        assert snapshot() == before and not trace.exists(), (label, "preview changed state or called mutation/action tool")
        print("PASS: Monitor Profile " + label, flush=True)
    run("absent ignores cleanup profile", None, [("Default", 31)])
    run("empty defaults", {}, [("Default", 31)])
    run("independent scoped safe", shared | {"LINUX_CLEANER_RISK": "safe"}, [("Shared Cache", 13)])
    run("independent scoped medium", shared, [("Shared Cache", 13), ("Shared Medium", 17)])
    run("NAME exclusion", shared | {"LINUX_CLEANER_EXCLUDE_TARGET": "Medium"}, [("Shared Cache", 13)])
    run("explicit shared symlink", shared, [("Shared Cache", 13), ("Shared Medium", 17)], share=True)
    preview = dict(LINUX_CLEANER_FORCE="1", LINUX_CLEANER_JSON="0", LINUX_CLEANER_TRASH="1",
                   LINUX_CLEANER_LOG=str(home / ".cache/linux-cleaner/ops.log"), LINUX_CLEANER_MIN_RECLAIM="1G")
    run("execution settings stay JSON preview", shared | preview, [("Shared Cache", 13), ("Shared Medium", 17)])
    run("retention stays preview", preview | {"LINUX_CLEANER_TRASH_KEEP_DAYS": "7"}, [("Default", 31)])
    for label, settings, error in [
        ("invalid risk", {"LINUX_CLEANER_RISK": "invalid"}, "Unknown risk"),
        ("invalid scope", {"LINUX_CLEANER_ONLY_PATH": "relative"}, "literal absolute path"),
        ("invalid min age", {"LINUX_CLEANER_MIN_AGE": "bad"}, "non-negative integer"),
        ("invalid action timeout", {"LINUX_CLEANER_ACTION_TIMEOUT": "bad"}, "non-negative integer"),
        ("invalid retention", {"LINUX_CLEANER_TRASH_KEEP_DAYS": "bad"}, "non-negative integer"),
        ("scope retention conflict", shared | {"LINUX_CLEANER_TRASH_KEEP_DAYS": "7"}, "--only-path applies only"),
    ]:
        run(label, settings, error=error)
MONITOR_PROFILE_PY

# Expansion must reject unrepresentable paths before a checked scope can see a sibling.
setup_mock_env
python3 - "$CLEANER_SH" <<'PATH_EXPANSION_PY'
import json, os, pathlib, subprocess, sys, tempfile
cleaner = sys.argv[1]
with tempfile.TemporaryDirectory(prefix="cleaner-path-expansion-", dir="/tmp") as directory:
    root = pathlib.Path(directory)
    home = root / "home"
    home.mkdir()
    config = root / "expansion.conf"
    base = {k: v for k, v in os.environ.items() if not k.startswith(("LINUX_CLEANER_", "XDG_"))}
    base.update(HOME=str(home), USER="fixture-user", XDG_STATE_HOME=str(root / "state"), NO_COLOR="1")
    def run(label, rows, args, env, status, diagnostic=None):
        print("Test Case: Path Expansion Safety " + label, flush=True)
        config.write_text("\n".join(rows) + "\n")
        result = subprocess.run([cleaner, "--config", str(config)] + args, env=env,
                                capture_output=True, text=True, timeout=20)
        assert result.returncode == status, (label, result)
        if diagnostic:
            assert diagnostic in result.stderr, (label, result)
        if status and "--json" in args:
            assert result.stdout == "", (label, result)
        return result
    def passed(label):
        print("PASS: Path Expansion Safety " + label, flush=True)
    def target(path, action=""):
        return "safe|Fixture|" + str(path) + "|expansion identity|0||" + action
    # First case is the observed scoped deletion: a trailing-LF XDG value must
    # never select the existing sibling produced by command-substitution trimming.
    for variable in ("XDG_CACHE_HOME", "HOME", "USER", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME"):
        parent = root / variable
        normal, physical = parent / "project", parent / "project\n"
        for path in (normal, physical):
            path.mkdir(parents=True)
            (path / "payload").write_text("keep exact identity\n")
        env = base | {variable: "project\n" if variable == "USER" else str(physical)}
        raw = str(parent) + "/$USER" if variable == "USER" else "$" + variable
        for fmt, args in (("cleanup", ["--clean", "--force"]), ("human", ["--list-targets"]),
                          ("json", ["--list-targets", "--json"])):
            label = variable + " used " + fmt
            run(label, [target(raw)], ["--only-path", str(parent)] + args, env, 1, "No eligible config target")
            assert all((path / "payload").read_text() == "keep exact identity\n" for path in (normal, physical))
            passed(label)
        label = variable + " unused"
        result = run(label, [target(normal)], ["--only-path", str(parent), "--list-targets", "--json"], env, 0)
        assert [row["path"] for row in json.loads(result.stdout)["targets"]] == [str(normal)]
        passed(label)
    parent = root / "discovery"
    normal, physical = parent / "project", parent / "project\n"
    for path in (normal, physical):
        for leaf in (path, path / "build"):
            leaf.mkdir(parents=True, exist_ok=True)
            (leaf / "CMakeCache.txt").write_text("keep build marker\n")
            (leaf / "payload").write_text("keep discovery payload\n")
    env = base | {"XDG_CACHE_HOME": str(physical)}
    for label, raw, action in (("wildcard", "$XDG_CACHE_HOME/*", ""),
                               ("literal build filter", "$XDG_CACHE_HOME", "filter:cxx_build"),
                               ("wildcard build filter", "$XDG_CACHE_HOME/*", "filter:cxx_build")):
        run(label, [target(raw, action)], ["--only-path", str(parent), "--clean", "--force"], env, 1, "unsafe path expansion")
        assert all((path / "build/payload").read_text() == "keep discovery payload\n" for path in (normal, physical))
        passed(label)
    good = root / "good"
    good.mkdir()
    (good / "payload").write_text("keep until complete analysis\n")
    label = "unscoped analysis aborts before cleanup"
    run(label, [target(good), target("$XDG_CACHE_HOME")], ["--clean", "--force"], env, 1, "target PATH has unsafe path expansion")
    assert (good / "payload").read_text() == "keep until complete analysis\n"
    assert all((path / "payload").read_text() == "keep discovery payload\n" for path in (normal, physical))
    passed(label)
    for mode in (["--check-config"], ["--clean", "--force"]):
        label = "protection rejects expansion " + mode[0]
        run(label, [target(good), "protect|$XDG_CACHE_HOME"], mode, env, 1, "protect PATH has unsafe path expansion")
        assert (good / "payload").read_text() == "keep until complete analysis\n"
        passed(label)
    label = "unsafe log disabled without fallback write"
    log_sibling, log_physical = home / "log", home / "log\n"
    for path in (log_sibling, log_physical):
        path.write_text("keep log sentinel\n")
    env = base | {"XDG_CACHE_HOME": str(log_physical)}
    run(label, [target(good)], ["--clean", "--force", "--log", "$XDG_CACHE_HOME"], env, 0, "disabling log with unsafe path expansion")
    assert not good.exists()
    assert all(path.read_text() == "keep log sentinel\n" for path in (log_sibling, log_physical))
    assert not (home / ".cache/linux-cleaner/operations.log").exists()
    passed(label)
PATH_EXPANSION_PY

# Physical resolution must preserve identity and fail before any cleanup execution.
setup_mock_env
python3 - "$CLEANER_SH" <<'CANONICAL_PATH_PY'
import hashlib, json, os, pathlib, shutil, subprocess, sys, tempfile
cleaner = sys.argv[1]
source = pathlib.Path(cleaner).read_text()
def body(name):
    start = source.index(name + "() {")
    return source[start:source.index("\n}", start) + 2]
with tempfile.TemporaryDirectory(prefix="cleaner-canonical-path-", dir="/tmp") as directory:
    root = pathlib.Path(directory)
    home = root / "home"
    home.mkdir()
    normal, physical = home / "project", home / "project\n"
    for parent in (normal, physical):
        (parent / "sub").mkdir(parents=True)
        (parent / "sub/payload").write_text("keep exact physical identity\n")
    alias = home / "alias"
    alias.symlink_to(physical, target_is_directory=True)
    good = home / "good"
    good.mkdir()
    (good / "payload").write_text("keep unrelated target\n")
    config = root / "canonical.conf"
    bindir = root / "bin"
    bindir.mkdir()
    # Only these exact fixture paths can trigger producer failures. Partial
    # stdout must never become a successful canonical path.
    for command, variable, code in (("realpath", "CANON_REALPATH_FAIL", 23), ("dirname", "CANON_DIRNAME_FAIL", 24)):
        executable = shutil.which(command)
        (bindir / command).write_text('#!/bin/bash\nif [[ "${!#}" == "${' + variable + ':-}" ]]; then printf "%s\\n" "$CANON_PARTIAL"; exit ' + str(code) + '; fi\nexec "' + executable + '" "$@"\n')
        (bindir / command).chmod(0o755)
    env = {k: v for k, v in os.environ.items() if not k.startswith(("LINUX_CLEANER_", "XDG_"))}
    env.update(HOME=str(home), XDG_STATE_HOME=str(root / "state"), NO_COLOR="1",
               PATH=str(bindir) + ":" + env["PATH"], CANON_PARTIAL=str(normal / "sub"))
    def row(path):
        return "safe|Fixture|" + str(path) + "|canonical identity|0||"
    def snapshot():
        return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in root.rglob("*") if p.is_file() and not p.is_symlink()
                and p != config and p.name != "cleaner.lock"}
    def run(label, rows, args, status=0, diagnostic=None, overrides=None):
        print("Test Case: Canonical Path " + label, flush=True)
        config.write_text("\n".join(rows) + "\n")
        before = snapshot()
        result = subprocess.run([cleaner, "--config", str(config)] + args,
                                env=env | (overrides or {}), capture_output=True, text=True, timeout=20)
        assert result.returncode == status, (label, result)
        if diagnostic:
            assert diagnostic in result.stderr, (label, result)
        if status and "--json" in args:
            assert result.stdout == "", (label, result)
        assert snapshot() == before, (label, "fixture payload or metadata changed")
        print("PASS: Canonical Path " + label, flush=True)
        return result
    # Old/fixed comparison uses only dry-run output; never delete on the baseline.
    run("resolved LF alias dry run", [row(alias / "sub")], ["--dry-run", "--json"], 1, "could not resolve target PATH")
    failures = [("partial realpath", good, {"CANON_REALPATH_FAIL": str(good)}),
                ("dirname", str(good) + "/../project/sub", {"CANON_DIRNAME_FAIL": str(good)})]
    for label, path, overrides in failures:
        run(label + " dry run", [row(path)], ["--dry-run", "--json"], 1, "could not resolve target PATH", overrides)
    if os.environ.get("CANONICAL_PREVIEW_ONLY") != "1":
        for label, path, overrides in [("resolved LF alias", alias / "sub", {})] + failures:
            run(label + " aborts cleanup", [row(good), row(path)], ["--clean", "--force"], 1, "could not resolve target PATH", overrides)
    run("extra protection fails closed", [row(good), "protect|" + str(alias / "sub")],
        ["--dry-run", "--json"], 1, "could not resolve protect PATH")
    home_failure = run("HOME resolution fails unsafe", [row(good)], ["--dry-run", "--json"],
                       overrides={"HOME": str(alias)})
    assert [t["status"] for t in json.loads(home_failure.stdout)["targets"]] == ["unsafe"]
    for label, path, expected in (("missing tail", good / "missing/deeper", good / "missing/deeper"),
                                  ("dot dot", str(good) + "/../project/sub", normal / "sub"),
                                  ("root", "/", pathlib.Path("/")), ("HOME", home, home)):
        result = run(label, [row(path)], ["--dry-run", "--json"])
        target = json.loads(result.stdout)["targets"][0]
        assert target["path"] == str(expected), (label, target)
        if label in ("root", "HOME"):
            assert target["status"] == "unsafe", target
    for label, destination in (("valid", good), ("dangling", home / "absent/leaf"), ("unrepresentable", physical)):
        link = home / (label + "-link")
        link.symlink_to(destination, target_is_directory=True)
        result = run(label + " final symlink", [row(link)], ["--dry-run", "--json"])
        target = json.loads(result.stdout)["targets"][0]
        assert target["status"] == "symlink", target
        if label == "valid":
            assert target["path"] == str(good), target
    # Exercise the actual helper bodies for inputs unavailable in line records
    # and for each consumer's failure return without a full-script side effect.
    probe = root / "probe.sh"
    probe.write_text("#!/bin/bash\nset -euo pipefail\n" + "\n".join(body(n) for n in
                     ("canonicalize_physical", "check_path_safety", "log_operation")) + '\n"$@"\n')
    def probe_run(label, command, status, output=None, overrides=None, cwd=None):
        print("Test Case: Canonical Path " + label, flush=True)
        before = snapshot()
        result = subprocess.run(["bash", str(probe)] + command, cwd=cwd, env=env | (overrides or {}), capture_output=True, text=True, timeout=20)
        assert result.returncode == status, (label, result)
        if output is not None:
            assert result.stdout == output, (label, result)
        assert snapshot() == before, (label, "probe mutated fixture")
        print("PASS: Canonical Path " + label, flush=True)
        return result
    probe_run("raw LF rejected", ["canonicalize_physical", str(physical)], 1, "")
    probe_run("relative path", ["canonicalize_physical", "good/missing/../tail"], 0, str(good / "tail"), cwd=home)
    probe_run("relative LF PWD rejected", ["canonicalize_physical", "sub"], 1, "", cwd=physical)
    probe_run("target safety failure", ["check_path_safety", str(good)], 1, "", {"CANON_REALPATH_FAIL": str(good)})
    probe_run("HOME safety failure", ["check_path_safety", str(good)], 1, "", {"HOME": str(alias)})
    probe_run("system safety", ["check_path_safety", "/etc/.."], 1, "")
    for path in (normal / "log", physical / "log"):
        path.write_text("keep log sentinel\n")
    result = probe_run("failed log resolution writes nothing", ["log_operation", "must not append"], 0, "",
                       {"LOG_ENABLED": "true", "LOG_FILE": str(alias / "log")})
    assert "logging disabled" in result.stderr, result
    result = probe_run("partial log resolution writes nothing", ["log_operation", "must not append"], 0, "",
                       {"LOG_ENABLED": "true", "LOG_FILE": str(normal / "log"), "CANON_REALPATH_FAIL": str(normal)})
    assert "logging disabled" in result.stderr, result
CANONICAL_PATH_PY

# XDG storage paths may contain LF; preserve their identity instead of trimming it.
setup_mock_env
python3 - "$CLEANER_SH" <<'XDG_STORAGE_PY'
import hashlib, json, os, pathlib, stat, subprocess, sys, tempfile
cleaner = sys.argv[1]
source = pathlib.Path(cleaner).read_text()
def body(name):
    start = source.index(name + "() {")
    return source[start:source.index("\n}", start) + 2]
with tempfile.TemporaryDirectory(prefix="cleaner-xdg-storage-", dir="/tmp") as directory:
    root = pathlib.Path(directory)
    home = root / "home"
    home.mkdir()
    env = {k: v for k, v in os.environ.items() if not k.startswith(("LINUX_CLEANER_", "XDG_"))}
    env.update(HOME=str(home), NO_COLOR="1")
    cache = home / "cache"
    cache.mkdir()
    (cache / "payload").write_text("keep cache payload\n")
    def config_text(marker):
        return "safe|" + marker + "|" + str(cache) + "|fixture|0||\n"
    def report_text(marker):
        return "Saved: " + marker + "\nResult: cleaned=1 skipped=0 failed=0 elapsed=2s\n"
    def seed(parent, filename, text):
        destination = parent / "linux-cleaner" / filename
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(text)
        return destination
    def snapshot():
        return {str(p.relative_to(root)): (stat.S_IMODE(p.lstat().st_mode),
                os.readlink(p) if p.is_symlink() else hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else None)
                for p in root.rglob("*")}
    def run(label, args, overrides=None, status=0, readonly=True):
        print("Test Case: XDG Storage " + label, flush=True)
        before = snapshot()
        result = subprocess.run([cleaner] + args, env=env | (overrides or {}), capture_output=True, text=True, timeout=20)
        assert result.returncode == status, (label, result)
        if readonly:
            assert snapshot() == before, (label, "read-only operation changed fixture")
        return result
    def passed(label):
        print("PASS: XDG Storage " + label, flush=True)
    for suffix, marker in (("", "PLAIN"), ("\n", "LF"), ("\n\n", "MULTIPLE_LF")):
        state, config_parent = root / ("state" + suffix), root / ("config" + suffix)
        report = seed(state, "last-report.txt", report_text(marker))
        config = seed(config_parent, "cleaner.conf", config_text(marker))
        for fmt in ("human", "json"):
            label = marker + " report " + fmt
            result = run(label, ["--report"] + (["--json"] if fmt == "json" else []), {"XDG_STATE_HOME": str(state)})
            assert (json.loads(result.stdout)["saved"] == marker if fmt == "json" else result.stdout == report.read_text()), result
            passed(label)
        label = marker + " config discovery"
        result = run(label, ["--list-targets", "--json"], {"XDG_CONFIG_HOME": str(config_parent)})
        inventory = json.loads(result.stdout)
        assert inventory["config"] == str(config) and inventory["targets"][0]["name"] == marker, inventory
        passed(label)
        label = marker + " config check"
        result = run(label, ["--check-config"], {"XDG_CONFIG_HOME": str(config_parent)})
        assert result.stdout == "OK: 1 targets in " + str(config) + "\n", result
        passed(label)
    default_report = seed(home / ".local/state", "last-report.txt", report_text("DEFAULT"))
    default_config = seed(home / ".config", "cleaner.conf", config_text("DEFAULT"))
    for label, value in (("unset", None), ("empty", ""), ("relative", "relative/path")):
        overrides = {} if value is None else {"XDG_STATE_HOME": value, "XDG_CONFIG_HOME": value}
        result = run(label + " report default", ["--report"], overrides)
        assert result.stdout == default_report.read_text(), result
        passed(label + " report default")
        result = run(label + " config default", ["--list-targets", "--json"], overrides)
        assert json.loads(result.stdout)["config"] == str(default_config), result
        passed(label + " config default")
    explicit = root / "explicit.conf"
    explicit.write_text(config_text("EXPLICIT"))
    result = run("explicit config precedence", ["--config", str(explicit), "--list-targets", "--json"],
                 {"XDG_CONFIG_HOME": str(root / "config\n\n")})
    assert json.loads(result.stdout)["targets"][0]["name"] == "EXPLICIT", result
    passed("explicit config precedence")
    if os.environ.get("XDG_STORAGE_READ_ONLY") != "1":
        # Never execute these writers on a buggy baseline comparison.
        for suffix in ("\n", "\n\n"):
            parent = root / ("init" + suffix)
            sibling = seed(root / "init", "sentinel", "keep config sibling\n")
            label = "initialize exact config " + repr(suffix)
            run(label, ["--config", str(explicit), "--init-config"], {"XDG_CONFIG_HOME": str(parent)}, readonly=False)
            destination = parent / "linux-cleaner/cleaner.conf"
            assert destination.read_bytes() == explicit.read_bytes()
            assert stat.S_IMODE(parent.stat().st_mode) == 0o700
            assert stat.S_IMODE(destination.parent.stat().st_mode) == 0o700
            assert stat.S_IMODE(destination.stat().st_mode) == 0o644
            assert sibling.read_text() == "keep config sibling\n" and not sibling.with_name("cleaner.conf").exists()
            passed(label)
            label = "exact overwrite refused " + repr(suffix)
            run(label, ["--config", str(explicit), "--init-config"], {"XDG_CONFIG_HOME": str(parent)}, status=1)
            passed(label)
        link_parent = root / "init-link\n"
        link_parent.symlink_to(root / "init", target_is_directory=True)
        result = run("exact init symlink refused", ["--config", str(explicit), "--init-config"], {"XDG_CONFIG_HOME": str(link_parent)}, status=1)
        assert "is a symlink" in result.stderr, result
        passed("exact init symlink refused")
        writer = root / "writer.sh"
        writer.write_text("#!/bin/bash\nset -euo pipefail\n" + body("_xdg_dir") + "\n" + body("write_cleanup_metrics") + "\n" + body("write_last_report_file") + "\n" + body("save_last_cleanup_report") +
                          '\nPLAN_REPORT_TEXT="Plan: exact storage"\nRESULT_REPORT_TEXT="Result: cleaned=1 skipped=0 failed=0 elapsed=2s"\nRESULT_FAILED_TARGETS=()\numask 022\nsave_last_cleanup_report\n')
        for suffix in ("\n", "\n\n"):
            parent = root / ("written" + suffix)
            sibling = seed(root / "written", "last-report.txt", "keep report sibling\n")
            label = "save exact report " + repr(suffix)
            print("Test Case: XDG Storage " + label, flush=True)
            result = subprocess.run(["bash", str(writer)], env=env | {"XDG_STATE_HOME": str(parent)}, capture_output=True, text=True, timeout=20)
            assert result.returncode == 0 and not result.stderr, result
            destination = parent / "linux-cleaner/last-report.txt"
            assert "Plan: exact storage" in destination.read_text()
            assert stat.S_IMODE(destination.parent.stat().st_mode) == 0o700 and stat.S_IMODE(destination.stat().st_mode) == 0o600
            assert sibling.read_text() == "keep report sibling\n"
            passed(label)
            result = run("read written report " + repr(suffix), ["--report", "--json"], {"XDG_STATE_HOME": str(parent)})
            assert json.loads(result.stdout)["cleaned"] == 1, result
            passed("read written report " + repr(suffix))
        protected = root / "writer-link\n/linux-cleaner"
        protected.parent.mkdir()
        protected.symlink_to(root / "written/linux-cleaner", target_is_directory=True)
        before = snapshot()
        print("Test Case: XDG Storage exact report symlink refused", flush=True)
        result = subprocess.run(["bash", str(writer)], env=env | {"XDG_STATE_HOME": str(protected.parent)}, capture_output=True, text=True, timeout=20)
        assert result.returncode == 0 and "symlink" in result.stderr and snapshot() == before, result
        passed("exact report symlink refused")
        result = run("exact reader symlink refused", ["--report"], {"XDG_STATE_HOME": str(protected.parent)}, status=1)
        assert "No cleanup report yet" in result.stderr, result
        passed("exact reader symlink refused")
        # Inject a failing stdout helper only around the actual consumers, keeping
        # failure propagation observable without changing the executable under test.
        failure = '_xdg_dir() { printf "%s" "$HOME/partial\\n"; return 23; }\n'
        discovery_start = source.index('if [[ -z "${RESTORE_TARGET:-}" && -z "${PURGE_TARGET:-}" && -z "$HOLD_TARGET" && -z "$RELEASE_TARGET" && "$LIST_SESSIONS" != true && "$REPORT" != true && "$DOCTOR" != true ]]; then')
        discovery = source[discovery_start:source.index("\n# Trim whitespace", discovery_start)]
        for label, code, status in (("init helper failure", body("init_user_config") + "\ninit_user_config", 1),
                                    ("reader helper failure", body("show_last_report") + "\nshow_last_report", 1),
                                    ("writer helper failure best effort", body("write_cleanup_metrics") + "\n" + body("write_last_report_file") + "\n" + body("save_last_cleanup_report") + "\nsave_last_cleanup_report", 0),
                                    ("discovery helper failure", body("set_default_config_candidates") + "\n" + discovery, 1),
                                    ("explicit config skips discovery helper", body("set_default_config_candidates") + '\nCONFIG_FILE="$EXPLICIT"\n' + discovery, 0)):
            probe = root / "helper-failure.sh"
            probe.write_text('#!/bin/bash\nset -euo pipefail\nCONFIG_FILE=""\nSCRIPT_DIR="$HOME"\nRESTORE_TARGET=""\nPURGE_TARGET=""\nHOLD_TARGET=""\nRELEASE_TARGET=""\nLIST_SESSIONS=false\nREPORT=false\nDOCTOR=false\n' + failure + code + "\n")
            before = snapshot()
            print("Test Case: XDG Storage " + label, flush=True)
            result = subprocess.run(["bash", str(probe)], env=env | {"EXPLICIT": str(explicit)}, capture_output=True, text=True, timeout=20)
            assert result.returncode == status and result.stdout == "" and snapshot() == before, (label, result)
            if label.startswith("writer"):
                assert "could not resolve the cleanup report directory" in result.stderr, result
            passed(label)
XDG_STORAGE_PY

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

session_mutex_qsession="$MOCK_HOME/.cache/linux-cleaner/quarantine/2020-01-01_00-00-00"
session_mutex_dest="$MOCK_HOME/.cache/session_mutex_dest"
mkdir -p "$session_mutex_qsession"
printf 'quarantined\n' > "$session_mutex_qsession/payload"
printf 'full|payload|%s|false|%s|%s\n' \
  "$session_mutex_dest" "$(id -u)" "$(id -g)" > "$session_mutex_qsession/quarantine.meta"

if run_test_case "Restore With Purge Sessions Rejected" 1 "session_mutex_rp.log" \
     --restore latest --purge-sessions older-than:30 --force \
   && run_test_case "Restore With List Sessions Rejected" 1 "session_mutex_rl.log" \
     --restore latest --list-sessions \
   && run_test_case "Purge Sessions With List Sessions Rejected" 1 "session_mutex_pl.log" \
     --purge-sessions all --force --list-sessions; then
  if grep -qF "Error: --restore, --purge-sessions and --list-sessions cannot be combined." "$TEST_ENV_DIR/session_mutex_rp.log" \
     && grep -qF "Error: --restore, --purge-sessions and --list-sessions cannot be combined." "$TEST_ENV_DIR/session_mutex_rl.log" \
     && grep -qF "Error: --restore, --purge-sessions and --list-sessions cannot be combined." "$TEST_ENV_DIR/session_mutex_pl.log" \
     && [[ -f "$session_mutex_qsession/payload" && ! -e "$session_mutex_dest" ]]; then
    echo -e "${GREEN}PASS: combining any pair of --restore, --purge-sessions, and --list-sessions is rejected without touching sessions.${NC}"
  else
    echo -e "${RED}FAIL: session mode combinations did not report the expected conflict error or touched the session.${NC}"
    cat "$TEST_ENV_DIR/session_mutex_rp.log" "$TEST_ENV_DIR/session_mutex_rl.log" "$TEST_ENV_DIR/session_mutex_pl.log"
    exit 1
  fi
else
  exit 1
fi
rm -rf "$MOCK_HOME/.cache/linux-cleaner/quarantine"

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

# roll moves the [Unreleased] entries under a dated version heading and rewrites the
# link footer; the rolled section must round-trip through extract unchanged, and every
# refusal must leave the changelog byte-identical.
echo -e "\n${BOLD}Test Case: Release Notes Roll${NC}"
# A self-contained fixture: the repository's own [Unreleased] is empty right after
# every real release, so rolling a copy of it would fail the suite on that day.
rn_roll="$TEST_ENV_DIR/roll-changelog.md"
rn_base="https://example.invalid/owner/repo"
write_roll_fixture() {
  local unreleased="$1"
  {
    printf '# Changelog\n\n## [Unreleased]\n\n%s\n## [1.0.0] - 2026-01-01\n\n### Added\n\n- First release.\n\n' "$unreleased"
    printf '[Unreleased]: %s/compare/v1.0.0...HEAD\n[1.0.0]: %s/releases/tag/v1.0.0\n' "$rn_base" "$rn_base"
  } > "$rn_roll"
  chmod 0644 "$rn_roll"
}
write_roll_fixture $'### Fixed\n\n- A bullet that quotes the heading ## [9.9.9] in its text.\n'
CHANGELOG="$rn_roll" "$rn_sh" extract Unreleased > "$TEST_ENV_DIR/roll_before.md"
rn_roll_ec=0
CHANGELOG="$rn_roll" "$rn_sh" roll 9.9.9 2026-01-02 > "$TEST_ENV_DIR/roll.log" 2>&1 || rn_roll_ec=$?
CHANGELOG="$rn_roll" "$rn_sh" extract 9.9.9 > "$TEST_ENV_DIR/roll_after.md" 2>&1 || rn_roll_ec=$?
if [[ $rn_roll_ec -ne 0 ]] \
   || ! cmp -s "$TEST_ENV_DIR/roll_before.md" "$TEST_ENV_DIR/roll_after.md" \
   || ! grep -qxF '## [9.9.9] - 2026-01-02' "$rn_roll" \
   || [[ "$(awk '/^## \[Unreleased\]/ {f = 1; next} f && /^## \[/ {exit} f && NF {n++} END {print n + 0}' "$rn_roll")" -ne 0 ]] \
   || [[ "$(grep -c '^\[Unreleased\]: ' "$rn_roll")" -ne 1 ]] \
   || ! grep -qxF "[Unreleased]: $rn_base/compare/v9.9.9...HEAD" "$rn_roll" \
   || ! grep -qxF "[9.9.9]: $rn_base/releases/tag/v9.9.9" "$rn_roll" \
   || ! grep -qxF "[1.0.0]: $rn_base/releases/tag/v1.0.0" "$rn_roll" \
   || [[ "$(stat -c %a "$rn_roll")" != 644 ]]; then
  echo -e "${RED}FAIL: release-notes.sh roll did not move [Unreleased] under 9.9.9 with a rewritten footer (ec=$rn_roll_ec).${NC}"
  cat "$TEST_ENV_DIR/roll.log" "$TEST_ENV_DIR/roll_after.md"
  exit 1
fi
roll_refused() {
  local args="$1" expect="$2" ec=0
  cp "$rn_roll" "$TEST_ENV_DIR/roll_snapshot.md"
  # shellcheck disable=SC2086
  CHANGELOG="$rn_roll" "$rn_sh" roll $args > "$TEST_ENV_DIR/roll_bad.log" 2>&1 || ec=$?
  if [[ $ec -eq 0 ]] || ! grep -qF "$expect" "$TEST_ENV_DIR/roll_bad.log" \
     || ! cmp -s "$rn_roll" "$TEST_ENV_DIR/roll_snapshot.md"; then
    echo -e "${RED}FAIL: release-notes.sh roll $args was not refused cleanly (ec=$ec).${NC}"
    cat "$TEST_ENV_DIR/roll_bad.log"
    exit 1
  fi
}
roll_refused "9.9.9 2026-01-02" "already has a section"
roll_refused "9.9.10 2026-01-02" "has no entries to roll"
write_roll_fixture $'### Added\n'
roll_refused "9.9.10 2026-01-02" "has no entries to roll"
write_roll_fixture $'- An entry.\n'
roll_refused "9.9 2026-01-02" "is not X.Y.Z"
roll_refused "9.9.11 02-01-2026" "is not YYYY-MM-DD"
roll_refused "9.9.11 2026-02-31" "is not YYYY-MM-DD"
# A failed duplicate check (unreadable changelog) must stop, never continue to the write.
if [[ "$EUID" -ne 0 ]]; then
  chmod 000 "$rn_roll"
  rn_unreadable_ec=0
  CHANGELOG="$rn_roll" "$rn_sh" roll 9.9.12 2026-01-03 > "$TEST_ENV_DIR/roll_unreadable.log" 2>&1 || rn_unreadable_ec=$?
  chmod 0644 "$rn_roll"
  if [[ $rn_unreadable_ec -eq 0 ]] || ! grep -qF "could not check" "$TEST_ENV_DIR/roll_unreadable.log"; then
    echo -e "${RED}FAIL: release-notes.sh roll continued after its duplicate check failed (ec=$rn_unreadable_ec).${NC}"
    cat "$TEST_ENV_DIR/roll_unreadable.log"
    exit 1
  fi
fi
# A version is a literal section label: regex metacharacters match no section.
if CHANGELOG="$rn_roll" "$rn_sh" extract '1.0.[05]' > "$TEST_ENV_DIR/extract_regex.md" 2>&1; then
  echo -e "${RED}FAIL: release-notes.sh extract treated '1.0.[05]' as a regular expression.${NC}"
  cat "$TEST_ENV_DIR/extract_regex.md"
  exit 1
fi
echo -e "${GREEN}PASS: release-notes.sh roll rolls [Unreleased] into a dated section that round-trips through extract, and refuses bad input without touching the changelog.${NC}"

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

# 58. Test Case: the shellcheck file list lives only in the Makefile's SHELLCHECK_FILES.
# The list was once restated in nine places and drifted; every documented or CI lint
# step now runs `make lint`, and every tracked shell file must be on that one list.
echo -e "\n${BOLD}Test Case: ShellCheck Single Source${NC}"
# Print SHELLCHECK_FILES from a Makefile, one name per line, following continuations.
shellcheck_files_from() {
  awk '
    /^SHELLCHECK_FILES[[:space:]]*=/ { on = 1; sub(/^[^=]*=/, "") }
    on { line = $0; cont = sub(/\\[[:space:]]*$/, "", line); printf "%s ", line; if (!cont) exit }
  ' "$1" | tr -s ' \t' '\n' | sed '/^$/d'
}
# Print tracked files that shellcheck can lint: shell extensions, the pacman
# scriptlet, the PKGBUILD, and sh/bash shebang scripts.
tracked_shell_files() {
  local f
  git -C "$SCRIPT_DIR" ls-files | while IFS= read -r f; do
    case "$f" in
      *.sh|*.bash|*.install|PKGBUILD|*/PKGBUILD) printf '%s\n' "$f" ;;
      *) head -n1 "$SCRIPT_DIR/$f" 2>/dev/null | grep -qE '^#!.*[/ ](ba)?sh([[:space:]]|$)' && printf '%s\n' "$f" ;;
    esac
  done | sort -u
}
sc_drift=""
for f in README.md CONTRIBUTING.md RELEASING.md docs/DOC_REVIEW_CHECKLIST.md docs/contract-baseline.md \
         .github/workflows/ci.yml .github/workflows/release.yml; do
  if ! grep -qF 'make lint' "$SCRIPT_DIR/$f" || grep -qE 'shellcheck +[A-Za-z0-9_./-]+\.(sh|bash|install)([[:space:]]|$)|shellcheck +.*PKGBUILD' "$SCRIPT_DIR/$f"; then
    sc_drift+=" $f(not make lint)"
  fi
done
if ! grep -qx $'\tshellcheck $(SHELLCHECK_FILES)' "$SCRIPT_DIR/Makefile"; then
  sc_drift+=" Makefile(lint recipe)"
fi
# Only in a checkout of this repo: a release tarball unpacked inside another git
# tree (an AUR helper's clone) would list none of its files and fail the fixture.
if [[ "$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" == "$(cd "$SCRIPT_DIR" && pwd -P)" ]]; then
  missing=$(comm -23 <(tracked_shell_files) <(shellcheck_files_from "$SCRIPT_DIR/Makefile" | sort -u) | tr '\n' ' ')
  [[ -z "$missing" ]] || sc_drift+=" SHELLCHECK_FILES(missing: ${missing% })"
  # Prove the check reads the list: dropping one tracked file from it must be caught.
  sed 's| completions/cleaner.bash||' "$SCRIPT_DIR/Makefile" > "$TEST_ENV_DIR/Makefile.drift"
  if [[ -z "$(comm -23 <(tracked_shell_files) <(shellcheck_files_from "$TEST_ENV_DIR/Makefile.drift" | sort -u))" ]]; then
    sc_drift+=" Makefile-fixture(drift not detected)"
  fi
fi
if [[ -z "$sc_drift" ]]; then
  echo -e "${GREEN}PASS: every lint step runs make lint, and SHELLCHECK_FILES names every tracked shell file.${NC}"
else
  echo -e "${RED}FAIL: shellcheck list drift:$sc_drift${NC}"
  exit 1
fi

# 58a. Test Case: the Makefile pre-release gate runs the runbook validator before the
# lint step and test suite, keeping release verification aligned with make check.
echo -e "\n${BOLD}Test Case: Makefile Pre-Release Gate Parity${NC}"
check_prerelease_makefile() {
  local mf="$1"
  if ! awk '
    /^pre-release:[[:space:]]*/ {
      in_pre = 1
      if ($0 ~ /(^|[[:space:]])check-runbook-examples[[:space:]]+lint([[:space:]]|$)/) step = 2
      next
    }
    in_pre && /^[^[:space:]#]/ { in_pre = 0 }
    in_pre && /^\t/ {
      sub(/^\t+/, "")
      if (step == 2 && $0 == "bash test_cleaner.sh") step = 3
    }
    END { exit (step == 3 ? 0 : 1) }
  ' "$mf"; then
    return 1
  fi
  if command -v make > /dev/null 2>&1; then
    local plan
    if [[ "$mf" == "$SCRIPT_DIR/Makefile" ]]; then
      plan=$(make -n --no-print-directory -C "$SCRIPT_DIR" pre-release 2>/dev/null) || return 1
    else
      plan=$(make -n --no-print-directory -C "$SCRIPT_DIR" -f "$mf" pre-release 2>/dev/null) || return 1
    fi
    printf '%s\n' "$plan" | awk -v lint_line="shellcheck $(shellcheck_files_from "$mf" | tr '\n' ' ' | sed 's/ $//')" '
      step == 0 && /(^|[[:space:]])scripts\/validate-runbook-examples\.sh([[:space:]]|$)/ { step = 1; next }
      step == 1 && $0 == lint_line { step = 2; next }
      step == 2 && $0 == "bash test_cleaner.sh" { step = 3; next }
      END { exit (step == 3 ? 0 : 1) }
    ' || return 1
  fi
  return 0
}
pr_drift=""
if ! check_prerelease_makefile "$SCRIPT_DIR/Makefile"; then
  pr_drift+=" Makefile(missing or out-of-order pre-release steps)"
fi
sed '/^pre-release:/s/ check-runbook-examples//' "$SCRIPT_DIR/Makefile" > "$TEST_ENV_DIR/Makefile.prerelease.drift"
if check_prerelease_makefile "$TEST_ENV_DIR/Makefile.prerelease.drift"; then
  pr_drift+=" Makefile-fixture(drift not detected)"
fi
if [[ -z "$pr_drift" ]]; then
  echo -e "${GREEN}PASS: Makefile pre-release gate runs check-runbook-examples, shellcheck, and test_cleaner.sh in order.${NC}"
else
  echo -e "${RED}FAIL: Makefile pre-release gate drift —$pr_drift${NC}"
  exit 1
fi

# 58b. Test Case: the configuration guide's quoted --check-config output names the real
# target count of the shipped cleaner.conf. The number drifted once already (44 vs 45)
# when a target was added without touching the docs.
echo -e "\n${BOLD}Test Case: Config Guide Target Count${NC}"
readme_count=$(grep -m1 -oE '^# -> OK: [0-9]+ targets in cleaner\.conf$' "$SCRIPT_DIR/docs/configuration.md" | grep -oE '[0-9]+')
real_count=$("$CLEANER_SH" --config "$SCRIPT_DIR/cleaner.conf" --check-config 2>/dev/null \
  | grep -oE '^OK: [0-9]+ targets' | grep -oE '[0-9]+')
if [[ -n "$readme_count" && "$readme_count" == "$real_count" ]]; then
  echo -e "${GREEN}PASS: docs/configuration.md quotes the real target count ($real_count).${NC}"
else
  echo -e "${RED}FAIL: docs/configuration.md quotes '${readme_count}' targets but cleaner.conf has '${real_count}'.${NC}"
  exit 1
fi

# 58c. Test Case: every "Cannot be combined with" list for a mode flag, in docs/cli-reference.md and
# cleaner.1, names the partners cleaner.sh refuses. These lists have drifted
# three times as guards gained partners; running every pair keeps them honest.
# shortcut: --json is left out of the pair matrix (its gate depends on the mode, not on
# a partner); extend the matrix if a mode-specific --json rule needs pinning.
echo -e "\n${BOLD}Test Case: Mode Flag Exclusion Docs Parity${NC}"
mx_flags=(--restore --purge-sessions --list-sessions --hold-session --release-session --list-targets --check-config --report --check-health
  --init-config --doctor --only-target --exclude-target --only-path --exclude-path --min-reclaim --min-free --min-free-path --min-age --action-timeout --trash-keep-days --notify --fail-fast --show-matches --exit-code)
mx_args() {
  case "$1" in
    --restore) echo "--restore 20200101_000000" ;;
    --hold-session|--release-session) echo "$1 20200101_000000" ;;
    --purge-sessions) echo "--purge-sessions all" ;;
    --only-target|--exclude-target) echo "$1 NPM" ;;
    --only-path|--exclude-path) echo "$1 $MOCK_HOME" ;;
    --min-reclaim) echo "--min-reclaim 1G" ;;
    --min-free) echo "--min-free 1G" ;;
    --min-free-path) echo "--min-free-path $MOCK_HOME --min-free 1G" ;;
    --min-age) echo "--min-age 30" ;;
    --action-timeout) echo "--action-timeout 60" ;;
    --check-health) echo "--check-health 60 --report" ;;
    --trash-keep-days) echo "--trash-keep-days 3" ;;
    *) echo "$1" ;;
  esac
}
mx_subjects=(--only-target --exclude-target --only-path --exclude-path --min-reclaim --min-free --min-free-path --min-age --action-timeout --trash-keep-days --notify --fail-fast --list-targets
  --check-config --init-config --doctor --report --check-health --restore --purge-sessions --list-sessions --hold-session --release-session --show-matches --exit-code)
: > "$TEST_ENV_DIR/mx_refused.txt"
for mx_s in "${mx_subjects[@]}"; do
  mx_refused=""
  for mx_p in "${mx_flags[@]}"; do
    [[ "$mx_p" == "$mx_s" ]] && continue
    mx_ec=0
    # shellcheck disable=SC2046  # mx_args output is intentionally word-split into flag + value
    PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" XDG_CONFIG_HOME="$TEST_ENV_DIR/mx_xdg" \
      "$CLEANER_SH" --config "$TEST_ENV_DIR/test_cleaner.conf" $(mx_args "$mx_s") $(mx_args "$mx_p") \
      < /dev/null > "$TEST_ENV_DIR/mx_pair.log" 2>&1 || mx_ec=$?
    if [[ $mx_ec -ne 0 ]] && grep -qiE 'cannot be combined|applies only to' "$TEST_ENV_DIR/mx_pair.log"; then
      mx_refused+=" $mx_p"
    fi
  done
  echo "$mx_s$mx_refused" >> "$TEST_ENV_DIR/mx_refused.txt"
done
if mx_drift=$(python3 - "$TEST_ENV_DIR/mx_refused.txt" "$SCRIPT_DIR/docs/cli-reference.md" "$SCRIPT_DIR/cleaner.1" "${mx_flags[@]}" << 'MXPY'
import re, sys
refused_file, readme, man, *universe = sys.argv[1:]
universe = set(universe)
refused = {}
for line in open(refused_file):
    subj, *parts = line.split()
    refused[subj] = set(parts)
readme_text = open(readme).read()
man_lines = open(man).read().splitlines()
# A mode flag's own list must name every refused mode; it may also name the cleanup
# filters (each filter documents its own restriction), but never a partner that works.
modes = {'--restore', '--purge-sessions', '--list-sessions', '--hold-session', '--release-session', '--list-targets',
         '--check-config', '--report', '--init-config', '--doctor'}
def ok(subj, got, want):
    if got is None:
        return False
    need = want & modes if subj in modes else want
    return need <= got <= want
drift = []
for subj, want in refused.items():
    m = re.search(r'^- \*\*`' + re.escape(subj) + r'[ `].*?Cannot be combined with (.*)$', readme_text, re.M)
    got = set(re.findall(r'`(--[a-z-]+)`', m.group(1))) & universe if m else None
    if not ok(subj, got, want):
        drift.append(f"docs/cli-reference.md {subj}: documents {sorted(got) if got is not None else 'nothing'}, refuses {sorted(want)}")
    man_flag = subj.replace('-', r'\-')
    got = None
    for i, l in enumerate(man_lines):
        if l.startswith('.B ' + man_flag) and i > 0 and man_lines[i - 1] == '.TP':
            j = i + 1
            # The sentence may wrap as "... Cannot be" / "combined with".
            while j < len(man_lines) and man_lines[j] != '.TP' and 'Cannot be combined with' not in man_lines[j] \
                    and not man_lines[j].rstrip().endswith('Cannot be'):
                j += 1
            if j < len(man_lines) and man_lines[j] != '.TP':
                got = set()
                k = j + 1
                while k < len(man_lines) and man_lines[k] != '.TP':
                    mm = re.match(r'\.BR? (\\-\\-[a-z\\-]+)', man_lines[k])
                    if mm:
                        got.add(mm.group(1).replace('\\-', '-'))
                    k += 1
                got &= universe
            break
    if not ok(subj, got, want):
        drift.append(f"cleaner.1 {subj}: documents {sorted(got) if got is not None else 'nothing'}, refuses {sorted(want)}")
print("\n".join(drift))
sys.exit(1 if drift else 0)
MXPY
); then
  echo -e "${GREEN}PASS: docs/cli-reference.md and cleaner.1 list only and all of the refused combinations for ${#mx_subjects[@]} mode flags.${NC}"
else
  echo -e "${RED}FAIL: documented mode-flag exclusions drifted from cleaner.sh:${NC}"
  echo "$mx_drift"
  exit 1
fi

# The pair matrix above accepts any applies-only line. These cases pin the full
# parenthetical, including --check-config, and show that an inherited notify
# variable is not the --notify flag.
echo -e "\n${BOLD}Test Case: Check Config Filter Exclusion Messages${NC}"
for check_spec in \
  "Only Target With Check Config Rejected|only_target_check_config.log|--only-target|NPM" \
  "Exclude Target With Check Config Rejected|exclude_target_check_config.log|--exclude-target|NPM"
do
  IFS='|' read -r check_name check_log check_flag check_value <<< "$check_spec"
  if run_test_case "$check_name" 1 "$check_log" \
       "$check_flag" "$check_value" --check-config; then
    if grep -qF "applies only to cleanup runs or --list-targets (not --restore, --purge-sessions, --list-sessions, --check-config, --report, --check-health, --init-config, or --doctor)." "$TEST_ENV_DIR/$check_log"; then
      echo -e "${GREEN}PASS: $check_flag with --check-config names the seven-mode list.${NC}"
    else
      echo -e "${RED}FAIL: $check_flag with --check-config omitted the seven-mode list.${NC}"
      cat "$TEST_ENV_DIR/$check_log"
      exit 1
    fi
  else
    exit 1
  fi
done
for check_spec in \
  "Min Reclaim With Check Config Rejected|min_reclaim_check_config.log|--min-reclaim|1G" \
  "Min Free With Check Config Rejected|min_free_check_config.log|--min-free|1G" \
  "Min Free Path With Check Config Rejected|min_free_path_check_config.log|--min-free-path|$MOCK_HOME" \
  "Min Age With Check Config Rejected|min_age_check_config.log|--min-age|7" \
  "Action Timeout With Check Config Rejected|action_timeout_check_config.log|--action-timeout|60" \
  "Trash Keep Days With Check Config Rejected|trash_keep_check_config.log|--trash-keep-days|7" \
  "Notify With Check Config Rejected|notify_check_config.log|--notify|" \
  "Fail Fast With Check Config Rejected|fail_fast_check_config.log|--fail-fast|"
do
  IFS='|' read -r check_name check_log check_flag check_value <<< "$check_spec"
  if [[ -n "$check_value" ]]; then
    check_args=("$check_flag" "$check_value" --check-config)
  else
    check_args=("$check_flag" --check-config)
  fi
  [[ "$check_flag" == --min-free-path ]] && check_args+=(--min-free 1G)
  if run_test_case "$check_name" 1 "$check_log" "${check_args[@]}"; then
    if grep -qF "applies only to cleanup runs (not --restore, --purge-sessions, --list-sessions, --list-targets, --check-config, --report, --check-health, --init-config, or --doctor)." "$TEST_ENV_DIR/$check_log"; then
      echo -e "${GREEN}PASS: $check_flag with --check-config names the eight-mode list.${NC}"
    else
      echo -e "${RED}FAIL: $check_flag with --check-config omitted the eight-mode list.${NC}"
      cat "$TEST_ENV_DIR/$check_log"
      exit 1
    fi
  else
    exit 1
  fi
done

echo -e "\n${BOLD}Test Case: Check Config Inherited Notify${NC}"
setup_mock_env
check_notify_inherit_ec=0
LINUX_CLEANER_NOTIFY=1 \
  PATH="$TEST_ENV_DIR/bin:$PATH" \
  HOME="$MOCK_HOME" \
  "$CLEANER_SH" \
  --check-config \
  --config "$TEST_ENV_DIR/test_cleaner.conf" \
  < /dev/null \
  > "$TEST_ENV_DIR/check_config_notify_inherit.log" 2>&1 || check_notify_inherit_ec=$?
if [[ "$check_notify_inherit_ec" -eq 0 ]] \
   && grep -q '^OK: ' "$TEST_ENV_DIR/check_config_notify_inherit.log"; then
  echo -e "${GREEN}PASS: Check Config Inherited Notify exited 0.${NC}"
else
  echo -e "${RED}FAIL: Check Config Inherited Notify exited $check_notify_inherit_ec.${NC}"
  cat "$TEST_ENV_DIR/check_config_notify_inherit.log"
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

# Redundant slashes (trailing or doubled) in wildcard patterns must be collapsed and stripped.
mkdir -p "$MOCK_HOME/slashproj/app/build"
echo "artifact" > "$MOCK_HOME/slashproj/app/build/out.o"
cat > "$TEST_ENV_DIR/glob_slashes.conf" <<'GLOBSLASHES'
safe|Trailing Slash Glob|$HOME/slashproj/*/build*/|Trailing slash pattern|0||
safe|Double Slash Glob|$HOME/slashproj//*/build*|Double slash pattern|0||
GLOBSLASHES

if run_test_case "Wildcard Redundant Slashes Dry Run" 0 "glob_slashes_dry.log" --debug \
     --config "$TEST_ENV_DIR/glob_slashes.conf"; then
  if grep -q "FOUND.*Trailing Slash Glob" "$TEST_ENV_DIR/glob_slashes_dry.log" \
     && grep -q "FOUND.*Double Slash Glob" "$TEST_ENV_DIR/glob_slashes_dry.log"; then
    echo -e "${GREEN}PASS: redundant slash wildcard patterns were analyzed in dry-run.${NC}"
  else
    echo -e "${RED}FAIL: dry-run did not find both redundant slash wildcard targets.${NC}"
    cat "$TEST_ENV_DIR/glob_slashes_dry.log"
    exit 1
  fi
else
  exit 1
fi

if run_test_case "Wildcard Redundant Slashes Listing" 0 "glob_slashes_list.log" \
     --list-targets --config "$TEST_ENV_DIR/glob_slashes.conf"; then
  slash_target="$(realpath -m "$MOCK_HOME/slashproj/app/build")"
  if grep -qF "Trailing Slash Glob	safe	$slash_target	" "$TEST_ENV_DIR/glob_slashes_list.log" \
     && grep -qF "Double Slash Glob	safe	$slash_target	" "$TEST_ENV_DIR/glob_slashes_list.log"; then
    echo -e "${GREEN}PASS: redundant slash wildcard patterns listed expected target path.${NC}"
  else
    echo -e "${RED}FAIL: redundant slash wildcard patterns did not list expected target path.${NC}"
    cat "$TEST_ENV_DIR/glob_slashes_list.log"
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

# Source roots and linked markers must not turn a source tree into build output.
python3 - "$CLEANER_SH" "$TEST_ENV_DIR" <<'CXX_FILTER_PY'
import json, os, pathlib, subprocess, sys, tempfile
cleaner, test_dir = sys.argv[1:]
for wildcard in (True, False):
    with tempfile.TemporaryDirectory(prefix="cxx-build-filter-", dir=test_dir) as directory:
        root = pathlib.Path(directory)
        home = root / "home"
        projects = home / "projects"
        files = (
            "buildtools/CMakeLists.txt", "buildtools/src/main.c", "buildtools/build/CMakeCache.txt",
            "build-insource/CMakeLists.txt", "build-insource/CMakeCache.txt",
            "build-meson/meson.build", "build-meson/build.ninja",
            "build-linked/keep.c", "build-real/CMakeCache.txt", "build-multi/Release/CMakeCache.txt",
        )
        for name in files:
            path = projects / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("fixture payload\n")
        commands = root / "compile_commands.json"
        commands.write_text("[]\n")
        link = projects / "build-linked/compile_commands.json"
        link.symlink_to(commands)
        config = root / "filter.conf"
        paths = ["$HOME/projects/build*"] if wildcard else [
            "$HOME/projects/" + name for name in
            ("buildtools", "build-insource", "build-meson", "build-linked", "build-real", "build-multi")
        ]
        config.write_text("".join(
            f"safe|Build Filter|{path}|Generated output only|0||filter:cxx_build\n" for path in paths
        ))
        env = dict(os.environ, HOME=str(home), XDG_STATE_HOME=str(root / "state"))
        args = [cleaner, "--config", str(config)]
        result = subprocess.run(args + ["--json", "--dry-run"], env=env, capture_output=True, text=True)
        assert result.returncode == 0, (result.stdout, result.stderr)
        targets = json.loads(result.stdout)["targets"]
        expected = {str(projects / name) for name in ("build-real", "build-multi")}
        assert {target["path"] for target in targets} == expected, (wildcard, targets)
        assert all(target["status"] == "found" for target in targets), targets
        result = subprocess.run(args + ["--clean", "--force"], env=env, capture_output=True, text=True)
        assert result.returncode == 0, (result.stdout, result.stderr)
        for name in files:
            if name.startswith(("build-real/", "build-multi/")):
                continue
            assert (projects / name).is_file(), (wildcard, name, result.stdout)
        assert link.is_symlink() and commands.is_file(), result.stdout
        assert all(not pathlib.Path(path).exists() for path in expected), result.stdout
print("PASS: C++ build filter preserves source roots and linked markers for wildcard and literal rows; real and multi-config builds are cleaned.")
CXX_FILTER_PY

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

if run_test_case "Blocked Process Pid" 0 "cmdline_block.log" \
     --config "$TEST_ENV_DIR/cmdline_guard.conf" --dry-run; then
  if grep -q "BLOCKED.*Cmdline Guarded.*'cmdline:mock_cmdline_proc'.* (pid $mock_cmdline_pid)$" "$TEST_ENV_DIR/cmdline_block.log" \
     && [[ -f "$MOCK_HOME/guarded/data.txt" ]]; then
    echo -e "${GREEN}PASS: a cmdline: token blocked the target and named its PID in the status line.${NC}"
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

if ! run_test_case "Blocked Process Pid JSON" 0 "cmdline_block_json.log" \
     --config "$TEST_ENV_DIR/cmdline_guard.conf" --dry-run --json \
   || ! python3 - "$TEST_ENV_DIR/cmdline_block_json.log" <<'PY'
import json, sys
target, = json.load(open(sys.argv[1]))["targets"]
assert target["status"] == "blocked", target
assert target["reason"] == "process 'cmdline:mock_cmdline_proc' is active", target
PY
then
  echo -e "${RED}FAIL: the blocked target's JSON reason changed.${NC}"
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
  if grep -q "BLOCKED.*Bare Token.*'mock_running_proc'" "$TEST_ENV_DIR/cmdline_bare.log" \
     && ! grep -q ' (pid ' "$TEST_ENV_DIR/cmdline_bare.log" \
     && [[ -f "$MOCK_HOME/guarded/data.txt" ]]; then
    echo -e "${GREEN}PASS: a successful pgrep with no output still blocks without a PID suffix.${NC}"
  else
    echo -e "${RED}FAIL: bare-token behaviour changed.${NC}"
    cat "$TEST_ENV_DIR/cmdline_bare.log"
    exit 1
  fi
else
  exit 1
fi

# A plain name may contain '.'. The kernel still stores only 15 characters, and
# pgrep -x refuses the longer form, so python3.13-debug must be compared as
# python3.13-debu. A space after "cmdline:" is not part of the pattern.
cp "$TEST_ENV_DIR/bin/pgrep" "$TEST_ENV_DIR/pgrep.default"
cat > "$TEST_ENV_DIR/bin/pgrep" <<'PGREP_TOKEN'
#!/usr/bin/env bash
# Record the pattern this stub actually searched for.
record_pattern() {
  printf '%s\n' "$1" >> "$TEST_ENV_DIR/pgrep_patterns"
}
if [[ "$1" == "-x" ]]; then
  record_pattern "$2"
  if [[ ${#2} -gt 15 && "$2" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "pgrep: pattern that searches for process name longer than 15 characters will result in zero matches" >&2
    exit 1
  fi
  [[ "$2" == "python3.13-debu" ]]
  exit $?
fi
if [[ "$1" == "-f" ]]; then
  shift
  [[ "$1" == "--" ]] && shift
  record_pattern "$1"
  if [[ "$1" == "/some/path" && -r "${TEST_ENV_DIR:-}/mock_cmdline_pid" ]]; then
    cat "${TEST_ENV_DIR}/mock_cmdline_pid"
    exit 0
  fi
  exit 1
fi
exit 1
PGREP_TOKEN
chmod +x "$TEST_ENV_DIR/bin/pgrep"
mkdir -p "$MOCK_HOME/token-guard/dotted" "$MOCK_HOME/token-guard/spaced"
echo "payload" > "$MOCK_HOME/token-guard/dotted/data.txt"
echo "payload" > "$MOCK_HOME/token-guard/spaced/data.txt"
cat > "$TEST_ENV_DIR/token_forms.conf" <<'TOKENFORMS'
safe|Dotted Comm|$HOME/token-guard/dotted|Long plain name with a dot|0|python3.13-debug|
safe|Spaced Cmdline|$HOME/token-guard/spaced|Space after the cmdline colon|0|cmdline: /some/path|
TOKENFORMS
sleep 60 &
token_forms_pid=$!
echo "$token_forms_pid" > "$TEST_ENV_DIR/mock_cmdline_pid"
: > "$TEST_ENV_DIR/pgrep_patterns"
token_forms_ok=true
if ! run_test_case "Dotted Comm And Spaced Cmdline Block" 0 "token_forms.log" \
     --dry-run --config "$TEST_ENV_DIR/token_forms.conf" \
   || ! grep -q "BLOCKED.*Dotted Comm.*'python3.13-debug'" "$TEST_ENV_DIR/token_forms.log" \
   || ! grep -q "BLOCKED.*Spaced Cmdline.*'cmdline: /some/path'" "$TEST_ENV_DIR/token_forms.log" \
   || ! grep -qx 'python3.13-debu' "$TEST_ENV_DIR/pgrep_patterns" \
   || ! grep -qx '/some/path' "$TEST_ENV_DIR/pgrep_patterns" \
   || grep -qx 'python3.13-debug' "$TEST_ENV_DIR/pgrep_patterns" \
   || grep -q ' /some/path' "$TEST_ENV_DIR/pgrep_patterns"; then
  token_forms_ok=false
fi
: > "$TEST_ENV_DIR/pgrep_patterns"
if [[ "$token_forms_ok" == true ]] \
   && run_test_case "Dotted Comm And Spaced Cmdline Stay" 0 "token_forms_clean.log" \
        --clean --force --config "$TEST_ENV_DIR/token_forms.conf" \
   && grep -q "BLOCKED.*Dotted Comm.*'python3.13-debug'" "$TEST_ENV_DIR/token_forms_clean.log" \
   && grep -q "BLOCKED.*Spaced Cmdline.*'cmdline: /some/path'" "$TEST_ENV_DIR/token_forms_clean.log" \
   && [[ -f "$MOCK_HOME/token-guard/dotted/data.txt" ]] \
   && [[ -f "$MOCK_HOME/token-guard/spaced/data.txt" ]] \
   && grep -qx 'python3.13-debu' "$TEST_ENV_DIR/pgrep_patterns" \
   && grep -qx '/some/path' "$TEST_ENV_DIR/pgrep_patterns"; then
  echo -e "${GREEN}PASS: a dotted 16-character name and a spaced cmdline: token both block, and neither target is deleted.${NC}"
else
  token_forms_ok=false
  echo -e "${RED}FAIL: a dotted long name or a spaced cmdline: token did not block cleanup.${NC}"
  cat "$TEST_ENV_DIR/token_forms.log" "$TEST_ENV_DIR/token_forms_clean.log" "$TEST_ENV_DIR/pgrep_patterns" 2>/dev/null || true
fi
kill "$token_forms_pid" 2>/dev/null || true
wait "$token_forms_pid" 2>/dev/null || true
cp "$TEST_ENV_DIR/pgrep.default" "$TEST_ENV_DIR/bin/pgrep"
chmod +x "$TEST_ENV_DIR/bin/pgrep"
rm -f "$TEST_ENV_DIR/pgrep.default" "$TEST_ENV_DIR/mock_cmdline_pid"
if [[ "$token_forms_ok" != true ]]; then
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

# Query errors must preserve guarded targets before sizing, sudo, or actions.
python3 - "$CLEANER_SH" <<'PROCESS_QUERY_PY'
import json, os, pathlib, shutil, subprocess, sys, tempfile
with tempfile.TemporaryDirectory(prefix="cleaner-process-query-", dir="/tmp") as directory:
    root = pathlib.Path(directory)
    real_du = shutil.which("du")
    for mode in ("comm", "cmdline"):
        for query in ("error2", "error127", "partial-error", "later-error", "invalid-regex", "missing", "no-match", "active"):
            label = mode + " " + query
            print("Test Case: Process Query " + label, flush=True)
            case = root / (mode + "-" + query)
            home, bindir = case / "home", case / "bin"
            home.mkdir(parents=True); bindir.mkdir()
            trace = case / "calls"
            for tool in "bash basename cat dirname realpath sed du df awk tr id sort find stat date rm mktemp mkdir mv cp chmod rmdir cut grep flock true test".split():
                executable = shutil.which(tool)
                if executable:
                    (bindir / tool).symlink_to(executable)
            if query != "missing":
                (bindir / "pgrep").write_text('#!/bin/bash\n'
                    '[[ "${!#}" != absent ]] || exit 1\n'
                    'case "$PROCESS_QUERY" in\n'
                    ' error2|later-error) exit 2 ;;\n'
                    ' error127) exit 127 ;;\n'
                    ' partial-error) printf "%s\\n" "$PROCESS_PID"; exit 2 ;;\n'
                    ' invalid-regex) [[ "${!#}" == "[" ]] && exit 2; exit 0 ;;\n'
                    ' no-match) exit 1 ;;\n'
                    ' active) printf "%s\\n" "$PROCESS_PID"; exit 0 ;;\n'
                    'esac\n')
            for tool in ("uv", "apt-get", "sudo"):
                (bindir / tool).write_text('#!/bin/bash\nprintf "%s\\n" "${0##*/}" >> "$PROCESS_TRACE"\n'
                    + ('while [[ "${1:-}" == -* ]]; do shift; done\nexec "$@"\n' if tool == "sudo" else 'exit 0\n'))
            (bindir / "du").unlink()
            (bindir / "du").write_text('#!/bin/bash\nfor arg in "$@"; do\n'
                ' [[ "$arg" != "$HOME/guarded"* ]] || printf "guarded du\\n" >> "$PROCESS_TRACE"\n'
                'done\nexec "$PROCESS_REAL_DU" "$@"\n')
            for executable in bindir.iterdir():
                if not executable.is_symlink(): executable.chmod(0o755)
            token = "[" if query == "invalid-regex" else "guard_app"
            if mode == "cmdline": token = "cmdline:" + token
            if query == "later-error": token = "absent," + token
            config = case / "cleaner.conf"
            config.write_text("\n".join([
                f"safe|Guarded|$HOME/guarded|Guarded payload|0|{token}|",
                f"safe|Guarded User Action|$HOME/guarded-user|Guarded prune|0|{token}|action:uv_cache_prune",
                f"medium|Guarded System Action|$HOME/guarded-system|Guarded package cache|0|{token}|action:apt_clean",
                "safe|Ungated|$HOME/ungated|Independent payload|0||",
            ]) + "\n")
            for leaf in ("guarded", "guarded-user", "guarded-system", "ungated"):
                (home / leaf).mkdir(); (home / leaf / "payload").write_text("preserve\n")
            env = {k: v for k, v in os.environ.items() if not k.startswith(("LINUX_CLEANER_", "XDG_"))}
            env.update(HOME=str(home), PATH=str(bindir), XDG_STATE_HOME=str(home / "state"), NO_COLOR="1",
                       PROCESS_QUERY=query, PROCESS_TRACE=str(trace), PROCESS_PID=str(os.getpid()),
                       PROCESS_REAL_DU=real_du)
            # A sibling PID exercises active cmdline matching without ancestry filtering.
            with subprocess.Popen(["/bin/sleep", "30"]) as active:
                if query == "active": env["PROCESS_PID"] = str(active.pid)
                try:
                    def run(flags):
                        result = subprocess.run([sys.argv[1], "--config", str(config), "--risk", "medium"] + flags,
                                                env=env, capture_output=True, text=True, timeout=15)
                        assert result.returncode == 0, (label, result)
                        return result.stdout
                    expected = "found" if query == "no-match" else "blocked" if query == "active" else "skipped"
                    data = json.loads(run(["--dry-run", "--json"]))
                    guarded = [target for target in data["targets"] if target["name"].startswith("Guarded")]
                    assert len(guarded) == 3 and all(t["status"] == expected for t in guarded), (label, data)
                    if expected == "skipped":
                        assert all(t["bytes"] == 0 and "process check failed" in t["reason"] and token.split(",")[-1] in t["reason"] for t in guarded), (label, guarded)
                        assert "process check failed" in run(["--dry-run"]), label
                    output = run(["--force"])
                    assert not (home / "ungated").exists(), (label, output)
                    if expected != "found":
                        assert all((home / leaf / "payload").read_text() == "preserve\n" for leaf in ("guarded", "guarded-user", "guarded-system")), label
                        if expected == "blocked":
                            # Preview and --force each du the ordinary path for the in-use estimate.
                            # Action rows stay unsized, and sudo/action binaries stay uncalled.
                            calls = trace.read_text()
                            assert calls == "guarded du\nguarded du\n", (label, calls)
                            assert all(target["bytes"] == 0 for target in guarded), (label, guarded)
                        else:
                            assert not trace.exists(), (label, trace.read_text() if trace.exists() else "")
                    else:
                        assert not (home / "guarded").exists(), label
                        calls = trace.read_text()
                        assert "uv\n" in calls and "apt-get\n" in calls and "sudo\n" in calls, calls
                finally:
                    active.terminate(); active.wait()
            print("PASS: Process Query " + label, flush=True)
PROCESS_QUERY_PY

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

# Brackets must not become character classes in wildcard target paths.
# shellcheck disable=SC2016  # literal $HOME is expanded by the cleaner
for bracket_path in '$HOME/src/*/file[1]' '$HOME/src/*/file1]' \
                    '$HOME/src/?/file[1' '$HOME/src/?/file1]'; do
  printf '# header\nsafe|Bracket|%s|d|0||\n' "$bracket_path" > "$TEST_ENV_DIR/bracket_wildcard.conf"
  for bracket_mode in --check-config --dry-run; do
    if ! run_test_case "Bracket Wildcard Validation ($bracket_mode $bracket_path)" 1 "bracket_wildcard.log" \
         --config "$TEST_ENV_DIR/bracket_wildcard.conf" "$bracket_mode" \
       || ! grep -qF "bracket_wildcard.conf:2: PATH cannot contain '[' or ']' in a wildcard path" \
         "$TEST_ENV_DIR/bracket_wildcard.log"; then
      echo -e "${RED}FAIL: $bracket_mode accepted a bracketed wildcard or omitted its line-numbered error.${NC}"
      cat "$TEST_ENV_DIR/bracket_wildcard.log"
      exit 1
    fi
  done
done
mkdir -p "$MOCK_HOME/src/app/file[1]" "$MOCK_HOME/src/app/file1"
# shellcheck disable=SC2016  # literal $HOME is expanded by the cleaner
printf 'safe|Bracket|$HOME/src/app/file[1]|d|0||\n' > "$TEST_ENV_DIR/bracket_literal.conf"
for bracket_mode in --check-config --dry-run; do
  if ! run_test_case "Literal Bracket Path ($bracket_mode)" 0 "bracket_literal.log" \
       --config "$TEST_ENV_DIR/bracket_literal.conf" "$bracket_mode"; then
    echo -e "${RED}FAIL: $bracket_mode rejected a literal bracketed path.${NC}"
    cat "$TEST_ENV_DIR/bracket_literal.log"
    exit 1
  fi
done
for bracket_mode in --list-targets --dry-run; do
  if ! run_test_case "Literal Bracket Path ($bracket_mode --json)" 0 "bracket_literal.log" \
       --config "$TEST_ENV_DIR/bracket_literal.conf" "$bracket_mode" --json \
     || ! python3 - "$TEST_ENV_DIR/bracket_literal.log" "$MOCK_HOME" <<'BRACKET_PATH_PY'
import json, sys
targets = json.load(open(sys.argv[1]))["targets"]
paths = [target["path"].replace("$HOME", sys.argv[2]) for target in targets]
assert paths == [sys.argv[2] + "/src/app/file[1]"], paths
BRACKET_PATH_PY
  then
    echo -e "${RED}FAIL: $bracket_mode selected a character-class sibling instead of the literal bracketed path.${NC}"
    cat "$TEST_ENV_DIR/bracket_literal.log"
    exit 1
  fi
done

mkdir -p "$MOCK_HOME/expanded/app[1]/cache" "$MOCK_HOME/expanded/app1/secrets"
printf 'preserve\n' > "$MOCK_HOME/expanded/app[1]/cache/sentinel"
printf 'preserve\n' > "$MOCK_HOME/expanded/app1/secrets/sentinel"
# shellcheck disable=SC2016  # literal $XDG_CACHE_HOME is expanded by the cleaner
printf '# header\nsafe|Bracket Expansion|$XDG_CACHE_HOME/*|d|0||\n' > "$TEST_ENV_DIR/bracket_expanded.conf"
for bracket_mode in --list-targets --dry-run --force; do
  if ! XDG_CACHE_HOME="$MOCK_HOME/expanded/app[1]" \
       run_test_case "Bracket Wildcard Validation (expanded $bracket_mode)" 0 "bracket_expanded.log" \
       --config "$TEST_ENV_DIR/bracket_expanded.conf" "$bracket_mode" \
     || ! grep -qF 'bracket_expanded.conf:2: skipping wildcard with bracket characters in expanded path' \
       "$TEST_ENV_DIR/bracket_expanded.log" \
     || grep -qF "$MOCK_HOME/expanded/app1/secrets" "$TEST_ENV_DIR/bracket_expanded.log" \
     || ! grep -qx preserve "$MOCK_HOME/expanded/app[1]/cache/sentinel" \
     || ! grep -qx preserve "$MOCK_HOME/expanded/app1/secrets/sentinel"; then
    echo -e "${RED}FAIL: $bracket_mode accepted an expanded bracketed wildcard or touched its sibling.${NC}"
    cat "$TEST_ENV_DIR/bracket_expanded.log"
    exit 1
  fi
done
echo -e "${GREEN}PASS: wildcard brackets are refused and literal bracketed paths remain valid.${NC}"

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
  transport_names=($'build\nunrelated' 'build|field' 'build ' "build\$USER" $'build-escape\e[2J' 'build-back\slash')
  mkdir -p "$MOCK_HOME/transport/build" "$MOCK_HOME/transport/build-normal output"
  printf 'preserve\n' > "$MOCK_HOME/transport/build/keep"
  printf 'generated\n' > "$MOCK_HOME/transport/build-normal output/discard"
  for transport_name in "${transport_names[@]}"; do
    mkdir -p "$MOCK_HOME/transport/$transport_name"
    printf 'preserve\n' > "$MOCK_HOME/transport/$transport_name/keep"
  done
  cat > "$TEST_ENV_DIR/transport.conf" <<'TRANSPORT'
safe|Transport Target|$HOME/transport/build?*|Preserve directory identity|0||
safe|Escape Only|$HOME/transport/build-escape*|Unsafe match only|0||
safe|Backslash Only|$HOME/transport/build-back*|Unsafe match only|0||
TRANSPORT
  if ! run_test_case "Wildcard Path Identity Inventory ($transport_mode)" 0 "transport_list.log" \
       --config "$TEST_ENV_DIR/transport.conf" --list-targets \
     || [[ "$(grep -c '^Transport Target[[:space:]]' "$TEST_ENV_DIR/transport_list.log")" -ne 1 ]] \
     || grep -qE '^(Escape Only|Backslash Only)[[:space:]]' "$TEST_ENV_DIR/transport_list.log" \
     || grep -q $'\e' "$TEST_ENV_DIR/transport_list.log" \
     || ! grep -q 'build-normal output' "$TEST_ENV_DIR/transport_list.log" \
     || [[ "$(grep -cE 'transport.conf:[23]: skipping wildcard match that cannot be represented safely' "$TEST_ENV_DIR/transport_list.log")" -ne 2 ]]; then
    echo -e "${RED}FAIL: wildcard inventory changed a discovered directory name.${NC}"
    cat "$TEST_ENV_DIR/transport_list.log"
    exit 1
  fi
  if ! run_test_case "Wildcard Path Identity JSON ($transport_mode)" 0 "transport_json.log" \
       --config "$TEST_ENV_DIR/transport.conf" --dry-run --json \
     || grep -q $'\e' "$TEST_ENV_DIR/transport_json.log" \
     || [[ "$(grep -cE 'transport.conf:[23]: skipping wildcard match that cannot be represented safely' "$TEST_ENV_DIR/transport_json.log")" -ne 2 ]] \
     || ! python3 - "$TEST_ENV_DIR/transport_json.log" "$MOCK_HOME" <<'TRANSPORT_JSON'
import json, sys
with open(sys.argv[1]) as log:
    data = json.loads("".join(line for line in log if not line.startswith("Warning: ")))
assert [target["path"] for target in data["targets"]] == [
    sys.argv[2] + "/transport/build-normal output"
], data["targets"]
TRANSPORT_JSON
  then
    echo -e "${RED}FAIL: wildcard JSON included an unrepresentable path or emitted a control character.${NC}"
    cat "$TEST_ENV_DIR/transport_json.log"
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

setup_mock_env
mkdir -p "$MOCK_HOME/.cache/reason_found" "$MOCK_HOME/.cache/reason_blocked"
printf 'found\n' > "$MOCK_HOME/.cache/reason_found/item.txt"
printf 'blocked\n' > "$MOCK_HOME/.cache/reason_blocked/item.txt"
missing_action_bin="$TEST_ENV_DIR/missing_action_bin"
mkdir -p "$missing_action_bin"
for tool in bash basename cat dirname realpath sed du awk tr id sort find stat date rm mktemp; do
  ln -s "$(command -v "$tool")" "$missing_action_bin/$tool"
done
ln -s "$TEST_ENV_DIR/bin/pgrep" "$missing_action_bin/pgrep"
rm -f "$TEST_ENV_DIR/bin/dnf"
cat > "$TEST_ENV_DIR/skip_reasons_json.conf" <<'SKIP_REASONS_JSON'
safe|Reason Found|$HOME/.cache/reason_found|Ordinary found target|0||
safe|Reason Blocked|$HOME/.cache/reason_blocked|Blocked by active process|0|mock_running_proc|
safe|Reason Missing Bin|$HOME/.cache/aurman|Missing binary action|0||action:dnf_clean
SKIP_REASONS_JSON
if ! PATH="$missing_action_bin" run_test_case "Dry Run JSON Reports Skip Reasons" 0 "skip_reasons_json.log" \
     --config "$TEST_ENV_DIR/skip_reasons_json.conf" --dry-run --json \
   || ! python3 - "$TEST_ENV_DIR/skip_reasons_json.log" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
by_name = {t["name"]: t for t in data["targets"]}
assert by_name["Reason Found"]["status"] == "found", by_name["Reason Found"]
assert by_name["Reason Found"]["reason"] == "", by_name["Reason Found"]
assert by_name["Reason Blocked"]["status"] == "blocked", by_name["Reason Blocked"]
assert by_name["Reason Blocked"]["reason"] == "process 'mock_running_proc' is active", by_name["Reason Blocked"]
assert by_name["Reason Missing Bin"]["status"] == "skipped", by_name["Reason Missing Bin"]
assert by_name["Reason Missing Bin"]["reason"].endswith("not available"), by_name["Reason Missing Bin"]
PY
then
  echo -e "${RED}FAIL: --dry-run --json did not report expected skip and block reasons.${NC}"
  cat "$TEST_ENV_DIR/skip_reasons_json.log"
  exit 1
fi
echo -e "${GREEN}PASS: --dry-run --json reports empty reason for found and exact reasons for blocked and skipped targets.${NC}"

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
for purge_selector in all latest older-than:30 max-size:1G; do
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
# one integer (du/find exit non-zero there under pipefail). Human session listing
# remains best-effort; JSON must reject a session that du cannot fully measure.
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
   || ! grep -q '2026-01-01_00-00-00' "$TEST_ENV_DIR/unreadable_sessions.log"; then
  unreadable_ok=false
fi
unreadable_json_exit=0
if ! du -sb -- "$unreadable_session" > /dev/null 2>&1; then
  unreadable_json_exit=1
fi
if ! run_test_case "Partly Unreadable Session JSON" "$unreadable_json_exit" "unreadable_sessions_json.log" --list-sessions --json; then
  unreadable_ok=false
elif [[ "$unreadable_json_exit" -eq 0 ]]; then
  python3 -m json.tool "$TEST_ENV_DIR/unreadable_sessions_json.log" > /dev/null 2>&1 || unreadable_ok=false
elif ! grep -q 'Failed to measure quarantine session' "$TEST_ENV_DIR/unreadable_sessions_json.log"; then
  unreadable_ok=false
fi
chmod u+rwx "$unreadable_root/locked" "$unreadable_session/0_x/locked"
if [[ "$unreadable_ok" != true ]]; then
  echo -e "${RED}FAIL: partly unreadable target estimates or strict session sizes behaved incorrectly.${NC}"
  cat "$TEST_ENV_DIR"/unreadable_*.log
  exit 1
fi
echo -e "${GREEN}PASS: target estimates and human listing tolerate unreadable paths; JSON requires a complete size.${NC}"

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
# A truncated flag or env name must fail too, even though a longer real name contains it.
cp "$SCRIPT_DIR/RUNBOOK.md" "$validator_copy/RUNBOOK.md"
printf '\n    cleaner --action\n' >> "$validator_copy/RUNBOOK.md"
validator_trunc_rc=0
env -i HOME="$MOCK_HOME" PATH="$validator_bin" bash "$validator_copy/scripts/validate-runbook-examples.sh" \
  > "$TEST_ENV_DIR/validator_trunc.log" 2>&1 || validator_trunc_rc=$?
cp "$SCRIPT_DIR/RUNBOOK.md" "$validator_copy/RUNBOOK.md"
printf '\n    cleaner --dry-run2\n' >> "$validator_copy/RUNBOOK.md"
validator_suffix_rc=0
env -i HOME="$MOCK_HOME" PATH="$validator_bin" bash "$validator_copy/scripts/validate-runbook-examples.sh" \
  > "$TEST_ENV_DIR/validator_suffix.log" 2>&1 || validator_suffix_rc=$?
cp "$SCRIPT_DIR/RUNBOOK.md" "$validator_copy/RUNBOOK.md"
printf '\n    LINUX_CLEANER_ACTION_TIME=5 cleaner --dry-run\n' >> "$validator_copy/RUNBOOK.md"
validator_env_rc=0
env -i HOME="$MOCK_HOME" PATH="$validator_bin" bash "$validator_copy/scripts/validate-runbook-examples.sh" \
  > "$TEST_ENV_DIR/validator_env.log" 2>&1 || validator_env_rc=$?
if [[ "$validator_rc" -ne 0 || "$validator_bad_rc" -eq 0 || "$validator_trunc_rc" -eq 0 || "$validator_env_rc" -eq 0 || "$validator_suffix_rc" -eq 0 ]] \
   || ! grep -qF 'missing in help: --dry-run2' "$TEST_ENV_DIR/validator_suffix.log" \
   || ! grep -qF 'missing in help: --no-such-flag' "$TEST_ENV_DIR/validator_bad.log" \
   || ! grep -qF 'missing in help: --action' "$TEST_ENV_DIR/validator_trunc.log" \
   || ! grep -qF 'missing in cleaner.1: LINUX_CLEANER_ACTION_TIME' "$TEST_ENV_DIR/validator_env.log"; then
  echo -e "${RED}FAIL: runbook validator needs ripgrep or passed an undocumented flag.${NC}"
  cat "$TEST_ENV_DIR/validator_ok.log" "$TEST_ENV_DIR/validator_bad.log" "$TEST_ENV_DIR/validator_trunc.log" "$TEST_ENV_DIR/validator_env.log" 2>/dev/null
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

# Restore creates private directories even when sudo resets its command's umask.
for restore_route in Direct Sudo; do
  setup_mock_env
  private_target="$MOCK_HOME/private restore"
  mkdir -p "$private_target/private/deeper"
  chmod 755 "$TEST_ENV_DIR" "$MOCK_HOME" "$private_target"
  chmod 700 "$private_target/private" "$private_target/private/deeper"
  printf 'private payload\n' > "$private_target/private/deeper/secret"
  chmod 644 "$private_target/private/deeper/secret"
  touch -d '10 days ago' "$private_target/private/deeper/secret"
  cat > "$TEST_ENV_DIR/private_restore.conf" <<'PRIVATE_RESTORE'
safe|Private Restore|$HOME/private restore|private aged directory|7||
PRIVATE_RESTORE
  if ! run_test_case "Trash For Private Restore ($restore_route)" 0 "private_restore_trash.log" \
         --config "$TEST_ENV_DIR/private_restore.conf" --clean --trash --force \
     || [[ -e "$private_target/private" ]]; then
    echo -e "${RED}FAIL: private restore fixture did not quarantine its aged directory.${NC}"
    exit 1
  fi
  private_session=$(find "$MOCK_HOME/.cache/linux-cleaner/quarantine" -mindepth 1 -maxdepth 1 -type d)
  mkdir -p "$private_session/1_Aged" "$private_session/2_Full"
  printf 'aged root\n' > "$private_session/1_Aged/item"
  printf 'full payload\n' > "$private_session/2_Full/item"
  chmod 750 "$private_session/2_Full"
  printf 'aged|1_Aged|%s/new aged/root|false|%s|%s\nfull|2_Full|%s/new full/parent/target|false|%s|%s\n' \
    "$MOCK_HOME" "$(id -u)" "$(id -g)" "$MOCK_HOME" "$(id -u)" "$(id -g)" >> "$private_session/quarantine.meta"
  if [[ "$restore_route" == Sudo ]]; then
    sed -i 's/|false|/|true|/' "$private_session/quarantine.meta"
  fi
  cat > "$TEST_ENV_DIR/bin/sudo" <<'PRIVATE_SUDO'
#!/usr/bin/env bash
[[ "${1:-}" == -n || "${1:-}" == -v ]] && exit 0
umask 022
printf '%s\n' "$*" >> "$TEST_ENV_DIR/private_restore_sudo.calls"
exec "$@"
PRIVATE_SUDO
  chmod +x "$TEST_ENV_DIR/bin/sudo"
  if ! (umask 022; run_test_case "Restore Private Directories $restore_route" 0 "private_restore.log" --restore latest) \
     || ! grep -qx 'private payload' "$private_target/private/deeper/secret" \
     || ! grep -qx 'aged root' "$MOCK_HOME/new aged/root/item" \
     || ! grep -qx 'full payload' "$MOCK_HOME/new full/parent/target/item" \
     || [[ "$(stat -c %a "$private_target")" != 755 ]] \
     || [[ "$(stat -c %a "$MOCK_HOME/new full/parent/target")" != 750 ]] \
     || [[ -e "$private_session" ]]; then
    echo -e "${RED}FAIL: private restore lost contents, changed existing modes, or kept its session.${NC}"
    cat "$TEST_ENV_DIR/private_restore.log"
    exit 1
  fi
  for private_dir in "$private_target/private" "$private_target/private/deeper" \
      "$MOCK_HOME/new aged" "$MOCK_HOME/new aged/root" "$MOCK_HOME/new full" "$MOCK_HOME/new full/parent"; do
    if [[ "$(stat -c %a "$private_dir")" != 700 ]]; then
      echo -e "${RED}FAIL: $restore_route restore created a non-private directory: $private_dir${NC}"
      exit 1
    fi
  done
  if [[ "$restore_route" == Sudo ]] && [[ ! -s "$TEST_ENV_DIR/private_restore_sudo.calls" ]]; then
    echo -e "${RED}FAIL: private restore did not exercise the sudo route.${NC}"
    exit 1
  fi
  echo -e "${GREEN}PASS: $restore_route restore creates private directories and preserves existing modes and contents.${NC}"
done

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

# package.install_messages is printed verbatim as the pacman scriptlet. Every
# timer it names must be a unit this repository ships, and upgrades stay quiet.
echo -e "\n${BOLD}Test Case: Package Install Scriptlet Is Hint Only${NC}"
install_yaml="$SCRIPT_DIR/aur/aurgen.install.yaml"
install_msgs=$(awk '
  /^  install_messages:/ { on = 1; next }
  on && /^  [^[:space:]]/ { exit }
  on { print }
' "$install_yaml")
install_timers=$(printf '%s\n' "$install_msgs" | grep -oE 'linux-cleaner[-a-z0-9]*\.timer' | sort -u || true)
install_missing=""
if ! printf '%s\n' "$install_timers" | grep -qx 'linux-cleaner-clean.timer'; then
  install_missing+=" linux-cleaner-clean.timer"
fi
if printf '%s\n' "$install_msgs" | grep -qE '^    post_upgrade:'; then
  install_missing+=" post_upgrade"
fi
if ! printf '%s\n' "$install_msgs" | grep -qF 'nothing was enabled'; then
  install_missing+=" hint"
fi
while IFS= read -r unit; do
  [[ -n "$unit" ]] || continue
  if [[ ! -f "$SCRIPT_DIR/examples/systemd/$unit" ]]; then
    install_missing+=" $unit"
  fi
done <<<"$install_timers"
if [[ -z "$install_missing" ]]; then
  echo -e "${GREEN}PASS: install messages name shipped timer units and do not define post_upgrade.${NC}"
else
  echo -e "${RED}FAIL: install messages in aur/aurgen.install.yaml:$install_missing${NC}"
  printf '%s\n' "$install_msgs"
  exit 1
fi

# The AUR check() runs make check-package, not the full suite: it must pass on its
# own and stay the target the packaging config names.
echo -e "\n${BOLD}Test Case: Package Check Target${NC}"
if ! grep -qx '  check: make check-package' "$install_yaml"; then
  echo -e "${RED}FAIL: aur/aurgen.install.yaml does not set package.check to make check-package.${NC}"
  exit 1
fi
if command -v make > /dev/null 2>&1; then
  if ! pkgcheck_out=$(make -s --no-print-directory -C "$SCRIPT_DIR" check-package 2>&1) \
     || [[ "$pkgcheck_out" != *"check-package: OK"* ]]; then
    echo -e "${RED}FAIL: make check-package did not pass:${NC}"
    printf '%s\n' "$pkgcheck_out"
    exit 1
  fi
fi
echo -e "${GREEN}PASS: aurgen check() runs make check-package, which passes.${NC}"

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

# Health probes use saved fixtures only, with a fixed clock for inclusive age boundaries.
echo -e "\n${BOLD}Test Case: Report Health Probe${NC}"
setup_mock_env
if ! python3 - "$CLEANER_SH" <<'HEALTH_PY'
import os
from pathlib import Path
import subprocess
import sys

root = Path(os.environ["TEST_ENV_DIR"]) / "health"
state = root / "state"
report_dir = state / "linux-cleaner"
report_dir.mkdir(parents=True)
report = report_dir / "last-report.txt"
bin_dir = root / "bin"
bin_dir.mkdir()
clock = bin_dir / "date"
clock.write_text("#!/bin/sh\nprintf '%s\\n' 2000000000\n")
clock.chmod(0o755)
env = os.environ | {"HOME": str(root), "XDG_STATE_HOME": str(state),
                    "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"]}
env.pop("JOURNAL_STREAM", None)

def run(args, status=0, reason=""):
    result = subprocess.run([sys.argv[1], *args], env=env, capture_output=True,
                            text=True, timeout=20)
    assert result.returncode == status, (args, result)
    if reason:
        assert reason in result.stderr and len(result.stderr.splitlines()) == 1, (args, result)
    else:
        assert not result.stderr, (args, result)
    return result.stdout

def save(body, age=0):
    report.write_text("Saved: 1999-01-01T00:00:00\nPlan: fixture\n" + body + "\n")
    subprocess.run(["touch", "-d", "@" + str(2000000000 - age), str(report)], check=True)

success = "Result: cleaned=1 skipped=2 failed=0 elapsed=1s"
cases = [("fresh", success, 59, 0, ""),
         ("boundary", success, 60, 0, ""),
         ("stale", success, 61, 1, "older than 60 seconds"),
         ("future", success, -1, 1, "dated in the future"),
         ("failed", success.replace("failed=0", "failed=1"), 0, 1, "cleanup failed"),
         ("interrupted", success + "\nInterrupted: SIGTERM before all targets finished", 0, 1, "interrupted"),
         ("retention failed", success + "\nRetention failed: true", 0, 1, "Retention failed: true"),
         ("retention succeeded", success + "\nRetention failed: false", 0, 0, ""),
         ("skipped targets", "Result: cleaned=0 skipped=2 failed=0 elapsed=0s", 0, 0, ""),
         ("nothing", "Result: nothing to clean", 0, 0, ""),
         ("min reclaim", "Result: skipped below --min-reclaim 1G", 0, 0, ""),
         ("min free", "Result: skipped at or above --min-free 1G", 0, 0, ""),
         ("skip retention failed", "Result: nothing to clean\nRetention failed: true", 0, 1, "Retention failed: true"),
         ("unknown", "Result: unknown", 0, 1, "no successful result"),
         ("malformed", "Result: cleaned=unknown", 0, 1, "no successful result")]
for label, body, age, status, reason in cases:
    save(body, age)
    before = (report.read_bytes(), report.stat().st_mtime_ns)
    for fmt in ([], ["--json"]):
        normal = run(["--report", *fmt])
        if not fmt:
            assert normal == report.read_text(), label
        checked = run(["--report", *fmt, "--check-health", "60"], status, reason)
        assert checked == normal, (label, fmt, checked, normal)
    assert before == (report.read_bytes(), report.stat().st_mtime_ns), label
    print("PASS: report health " + label)

save(success)
for seconds in ("0", "00060", "0" * 40 + "60", "9223372036854775807"):
    run(["--check-health", seconds, "--report"])
save(success, 60)
run(["--report", "--check-health", "1", "--check-health", "60"])
run(["--report", "--check-health", "60", "--check-health", "1"], 1, "older than 1 seconds")
for seconds in ("-1", "+1", "1.5", "1s", "1+2", "9223372036854775808", "9" * 40):
    run(["--report", "--check-health", seconds], 1, "expects an integer")
for args, reason in [(["--check-health", "60"], "requires --report"),
                     (["--check-health", "60", "--json"], "requires --report"),
                     (["--report", "--check-health"], "requires a seconds argument"),
                     (["--report", "--check-health", ""], "requires a seconds argument"),
                     (["--report", "--check-health", "--json"], "requires a value"),
                     (["--report", "--check-health", "-d"], "requires a value")]:
    run(args, 1, reason)

for fmt in ([], ["--json"]):
    args = ["--report", *fmt, "--check-health", "60"]
    report.unlink()
    assert run(args, 1, "report is missing") == ""
    report.symlink_to(root / "missing")
    assert run(args, 1, "symlinked") == ""
    report.unlink()
    save(success)
    target = root / "target.txt"
    report.rename(target)
    report.symlink_to(target)
    assert run(args, 1, "symlinked") == ""
    report.unlink()
    target.rename(report)
    report.chmod(0)
    if not os.access(report, os.R_OK):
        assert run(args, 1, "unreadable") == ""
    report.chmod(0o600)
    report.unlink()
    report.mkdir()
    assert run(args, 1, "unreadable") == ""
    report.rmdir()
    save(success)
    real_dir = state / "real"
    report_dir.rename(real_dir)
    report_dir.symlink_to(real_dir, target_is_directory=True)
    assert run(args, 1, "symlinked") == ""
    report_dir.unlink()
    real_dir.rename(report_dir)

stat_stub = bin_dir / "stat"
stat_stub.write_text("#!/bin/sh\nexit 1\n")
stat_stub.chmod(0o755)
for fmt in ([], ["--json"]):
    normal = run(["--report", *fmt])
    assert run(["--report", *fmt, "--check-health", "60"], 1,
               "cannot read cleanup report age") == normal
print("PASS: report health arguments, missing/unreadable/symlinked reports and stat failure")
HEALTH_PY
then
  echo -e "${RED}FAIL: report health probe regression.${NC}"
  exit 1
fi
setup_mock_env

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

echo -e "\n${BOLD}Test Case: Relative XDG_STATE_HOME Ignored${NC}"
setup_mock_env
mkdir -p "$TEST_ENV_DIR/relcwd"
ec=0
( cd "$TEST_ENV_DIR/relcwd" && XDG_STATE_HOME=rel PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" "$CLEANER_SH" --config "$TEST_ENV_DIR/test_cleaner.conf" --clean --force < /dev/null > "$TEST_ENV_DIR/rel_state.log" 2>&1 ) || ec=$?
report_ec=0
( cd "$TEST_ENV_DIR/relcwd" && XDG_STATE_HOME=rel PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" "$CLEANER_SH" --report < /dev/null > "$TEST_ENV_DIR/rel_report.log" 2>&1 ) || report_ec=$?
if [[ $ec -eq 0 ]] \
   && [[ -f "$MOCK_HOME/.local/state/linux-cleaner/last-report.txt" ]] \
   && [[ ! -e "$TEST_ENV_DIR/relcwd/rel" ]] \
   && [[ $report_ec -eq 0 ]] \
   && grep -q '^Result:' "$TEST_ENV_DIR/rel_report.log"; then
  echo -e "${GREEN}PASS: relative XDG_STATE_HOME was ignored in favor of \$HOME/.local/state.${NC}"
else
  echo -e "${RED}FAIL: relative XDG_STATE_HOME was not ignored or report missing.${NC}"
  cat "$TEST_ENV_DIR/rel_state.log" 2>/dev/null || true
  cat "$TEST_ENV_DIR/rel_report.log" 2>/dev/null || true
  exit 1
fi

echo -e "\n${BOLD}Test Case: Relative XDG_CONFIG_HOME Ignored${NC}"
mkdir -p "$TEST_ENV_DIR/relcwd/rel/linux-cleaner"
cat > "$TEST_ENV_DIR/relcwd/rel/linux-cleaner/cleaner.conf" <<'EOF'
safe|Relative Config Marker|$HOME/rel_marker|relative config marker test|0||
EOF
( cd "$TEST_ENV_DIR/relcwd" && env -u LINUX_CLEANER_CONFIG XDG_CONFIG_HOME=rel PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" "$CLEANER_SH" --list-targets < /dev/null > "$TEST_ENV_DIR/rel_config.log" 2>&1 ) || true
if ! grep -q "Relative Config Marker" "$TEST_ENV_DIR/rel_config.log"; then
  echo -e "${GREEN}PASS: relative XDG_CONFIG_HOME was ignored during config discovery.${NC}"
else
  echo -e "${RED}FAIL: relative XDG_CONFIG_HOME was used for config discovery.${NC}"
  cat "$TEST_ENV_DIR/rel_config.log" 2>/dev/null || true
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
mkdir -p "$MOCK_HOME/.cache/uv" "$MOCK_HOME/.local/share/pnpm/store" "$MOCK_HOME/.cache/huggingface/hub" "$OUTSIDE_DIR/nix_parent/store"
printf 'uv-entry\n' > "$MOCK_HOME/.cache/uv/entry.bin"
printf 'pnpm-entry\n' > "$MOCK_HOME/.local/share/pnpm/store/entry.bin"
printf 'hf-entry\n' > "$MOCK_HOME/.cache/huggingface/hub/entry.bin"
printf 'nix-entry\n' > "$OUTSIDE_DIR/nix_parent/store/entry.bin"
chmod 555 "$OUTSIDE_DIR/nix_parent"
cat > "$TEST_ENV_DIR/bin/sudo" <<'FAIL_SUDO'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_ENV_DIR/sudo_unexpected.calls"
exit 1
FAIL_SUDO
chmod +x "$TEST_ENV_DIR/bin/sudo"
cat > "$TEST_ENV_DIR/user_actions.conf" <<EOF
safe|UV Cache|\$HOME/.cache/uv|uv package manager cache (uv cache prune: unreachable entries only)|0|uv|action:uv_cache_prune
safe|PNPM Store|\$HOME/.local/share/pnpm/store|pnpm content-addressable store (pnpm store prune: unreferenced packages only)|0|pnpm|action:pnpm_store_prune
safe|Hugging Face Cache|\$HOME/.cache/huggingface/hub|Hugging Face hub cache (hf cache prune: detached revisions and incomplete downloads only)|0|hf|action:hf_cache_prune
safe|Nix Store|$OUTSIDE_DIR/nix_parent/store|Nix package store (nix-store --gc: unreachable store paths only)|0|nix,nix-build,nix-store|action:nix_store_gc
EOF
export MOCK_USER_ACTION_LOG="$TEST_ENV_DIR/user_action.calls"
: > "$MOCK_USER_ACTION_LOG"
rm -f "$TEST_ENV_DIR/sudo_unexpected.calls"
if ! run_test_case "User Actions Clean Force Without Sudo" 0 "user_actions_clean.log" \
       --config "$TEST_ENV_DIR/user_actions.conf" --clean --force \
   || [[ -e "$TEST_ENV_DIR/sudo_unexpected.calls" ]] \
   || grep -qi "requires root" "$TEST_ENV_DIR/user_actions_clean.log" \
   || grep -qF "[FOUND] UV Cache" "$TEST_ENV_DIR/user_actions_clean.log" \
   || ! cmp -s "$MOCK_USER_ACTION_LOG" <(printf 'uv cache prune --cache-dir %s\npnpm store prune --store-dir %s\nhf cache prune --yes --cache-dir %s\nnix-store --gc\n' \
          "$(realpath "$MOCK_HOME/.cache/uv")" \
          "$(realpath "$MOCK_HOME/.local/share/pnpm/store")" \
          "$(realpath "$MOCK_HOME/.cache/huggingface/hub")") \
   || ! grep -q '^Result: cleaned=4 skipped=0 failed=0 ' "$TEST_ENV_DIR/user_actions_clean.log"; then
  chmod 755 "$OUTSIDE_DIR/nix_parent" 2>/dev/null || true
  echo -e "${RED}FAIL: user actions did not run with exact argv, invoked sudo, or reported requires root.${NC}"
  cat "$TEST_ENV_DIR/user_actions_clean.log" "$MOCK_USER_ACTION_LOG" "$TEST_ENV_DIR/sudo_unexpected.calls" 2>/dev/null || true
  exit 1
fi
chmod 755 "$OUTSIDE_DIR/nix_parent"
unset MOCK_USER_ACTION_LOG
echo -e "${GREEN}PASS: user-level prune actions run with exact argv, zero sudo calls, and no 'requires root'.${NC}"

# 2. Missing binary skips its row cleanly (no failure, exits 0, no sudo calls).
setup_mock_env
mkdir -p "$MOCK_HOME/.cache/uv" "$MOCK_HOME/.local/share/pnpm/store" "$MOCK_HOME/.cache/huggingface/hub" "$OUTSIDE_DIR/nix/store"
user_missing_bin="$TEST_ENV_DIR/user_missing_bin"
mkdir -p "$user_missing_bin"
for tool in bash basename cat dirname realpath sed du df awk tr id sort find stat date rm mktemp; do
  ln -s "$(command -v "$tool")" "$user_missing_bin/$tool"
done
# The mock pgrep keeps a real uv/hf process on the host from blocking these rows.
ln -s "$TEST_ENV_DIR/bin/pgrep" "$user_missing_bin/pgrep"
ln -s "$TEST_ENV_DIR/bin/uv" "$user_missing_bin/uv"
ln -s "$TEST_ENV_DIR/bin/hf" "$user_missing_bin/hf"
# pnpm and nix-store intentionally omitted from user_missing_bin
cat > "$user_missing_bin/sudo" <<'FAIL_SUDO2'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_ENV_DIR/sudo_missing_unexpected.calls"
exit 1
FAIL_SUDO2
chmod +x "$user_missing_bin/sudo"
cat > "$TEST_ENV_DIR/user_actions.conf" <<EOF
safe|UV Cache|\$HOME/.cache/uv|uv package manager cache (uv cache prune: unreachable entries only)|0|uv|action:uv_cache_prune
safe|PNPM Store|\$HOME/.local/share/pnpm/store|pnpm content-addressable store (pnpm store prune: unreferenced packages only)|0|pnpm|action:pnpm_store_prune
safe|Hugging Face Cache|\$HOME/.cache/huggingface/hub|Hugging Face hub cache (hf cache prune: detached revisions and incomplete downloads only)|0|hf|action:hf_cache_prune
safe|Nix Store|$OUTSIDE_DIR/nix/store|Nix package store (nix-store --gc: unreachable store paths only)|0|nix,nix-build,nix-store|action:nix_store_gc
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
   || ! grep -q "Nix Store: skipped: 'nix-store' not available on this platform." "$TEST_ENV_DIR/user_actions_missing.log" \
   || ! cmp -s "$TEST_ENV_DIR/user_missing.calls" <(printf 'uv cache prune --cache-dir %s\nhf cache prune --yes --cache-dir %s\n' \
          "$(realpath "$MOCK_HOME/.cache/uv")" \
          "$(realpath "$MOCK_HOME/.cache/huggingface/hub")") \
   || ! grep -q '^Result: cleaned=2 skipped=2 failed=0 ' "$TEST_ENV_DIR/user_actions_missing.log"; then
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

# A process idle at analysis and active before this target is cleaned must block it.
setup_mock_env
mkdir -p "$MOCK_HOME/.cache/late-proc"
printf 'keep-me\n' > "$MOCK_HOME/.cache/late-proc/cache.txt"
cat > "$TEST_ENV_DIR/late_proc.conf" <<'EOF'
safe|Late Process|$HOME/.cache/late-proc|cache whose process starts after analysis|0|late_proc|
EOF
cat > "$TEST_ENV_DIR/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
count_file="$TEST_ENV_DIR/pgrep_late_calls"
count=0
if [[ -f "$count_file" ]]; then
  count=$(cat "$count_file")
fi
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
if [[ "$count" -eq 1 ]]; then
  exit 1
fi
printf '%s\n' 12345 67890
exit 0
EOF
chmod +x "$TEST_ENV_DIR/bin/pgrep"
if run_test_case "Process Started After Analysis Blocks Cleanup" 0 "late_proc.log" \
     --config "$TEST_ENV_DIR/late_proc.conf" --clean --force; then
  late_block=$(grep -n 'BLOCKED' "$TEST_ENV_DIR/late_proc.log" | head -1 | cut -d: -f1) || true
  late_start=$(grep -n 'Starting cleanup' "$TEST_ENV_DIR/late_proc.log" | head -1 | cut -d: -f1) || true
  if [[ -n "$late_block" && -n "$late_start" && "$late_start" -lt "$late_block" ]] \
     && grep -q "BLOCKED.*Late Process: Skip cleanup because process 'late_proc' is active.* (pid 12345)$" "$TEST_ENV_DIR/late_proc.log" \
     && grep -q '^Result: cleaned=0 skipped=1 failed=0 ' "$TEST_ENV_DIR/late_proc.log" \
     && [[ -f "$MOCK_HOME/.cache/late-proc/cache.txt" ]]; then
    echo -e "${GREEN}PASS: a process that starts after analysis blocks cleanup and leaves the cache in place.${NC}"
  else
    echo -e "${RED}FAIL: late process did not block cleanup.${NC}"
    cat "$TEST_ENV_DIR/late_proc.log"
    exit 1
  fi
else
  exit 1
fi

# The size planned before the process started is the result report's in-use total.
setup_mock_env
mkdir -p "$MOCK_HOME/.cache"
truncate -s 2M "$MOCK_HOME/.cache/late-in-use.bin"
cat > "$TEST_ENV_DIR/late_in_use.conf" <<'EOF'
safe|Late In Use|$HOME/.cache/late-in-use.bin|cache whose process starts after analysis|0|late_proc|
EOF
cat > "$TEST_ENV_DIR/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
count_file="$TEST_ENV_DIR/pgrep_late_in_use_calls"
count=0
if [[ -f "$count_file" ]]; then
  count=$(cat "$count_file")
fi
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
if [[ "$count" -eq 1 ]]; then
  exit 1
fi
exit 0
EOF
chmod +x "$TEST_ENV_DIR/bin/pgrep"
if run_test_case "Late Process In-Use Result Size" 0 "late_in_use.log" \
     --config "$TEST_ENV_DIR/late_in_use.conf" --clean --force; then
  late_in_use_block=$(grep -n 'BLOCKED' "$TEST_ENV_DIR/late_in_use.log" | head -1 | cut -d: -f1) || true
  late_in_use_start=$(grep -n 'Starting cleanup' "$TEST_ENV_DIR/late_in_use.log" | head -1 | cut -d: -f1) || true
  if [[ -n "$late_in_use_block" && -n "$late_in_use_start" && "$late_in_use_start" -lt "$late_in_use_block" ]] \
     && grep -qF "Late In Use: Skip cleanup because process 'late_proc' is active; 2 MB would be reclaimable otherwise." "$TEST_ENV_DIR/late_in_use.log" \
     && awk '
          /^Reclaimed:/ { seen=1 }
          seen && /^In use: blocked=1 would_reclaim=2 MB$/ { found=1 }
          END { exit !found }
        ' "$TEST_ENV_DIR/late_in_use.log" \
     && [[ -f "$MOCK_HOME/.cache/late-in-use.bin" ]]; then
    echo -e "${GREEN}PASS: a process that starts after analysis counts its planned size in the result In use line.${NC}"
  else
    echo -e "${RED}FAIL: late process in-use size missing from the result report.${NC}"
    cat "$TEST_ENV_DIR/late_in_use.log"
    exit 1
  fi
else
  exit 1
fi

# 3a. Shipped commented Nix Store row, once uncommented, is not blocked when nix-daemon is running, runs, and still blocks during nix-store/nix-build.
setup_mock_env
shipped_nix_row=$(sed -n 's/^[[:space:]]*#[[:space:]]*\(safe|Nix Store|.*\)$/\1/p' "$SCRIPT_DIR/cleaner.conf")
if [[ -z "$shipped_nix_row" ]]; then
  echo -e "${RED}FAIL: could not extract commented Nix Store row from cleaner.conf.${NC}"
  exit 1
fi
printf '%s\n' "$shipped_nix_row" > "$TEST_ENV_DIR/shipped_nix_daemon.conf"

cat > "$TEST_ENV_DIR/bin/pgrep" <<'PGREP_DAEMON'
#!/usr/bin/env bash
if [[ "$1" == "-x" && "$2" == "nix-daemon" ]]; then
  exit 0
fi
exit 1
PGREP_DAEMON
chmod +x "$TEST_ENV_DIR/bin/pgrep"

if ! run_test_case "Shipped Nix Row Not Blocked By Nix-Daemon" 0 "nix_daemon.log" \
       --config "$TEST_ENV_DIR/shipped_nix_daemon.conf" --dry-run --debug \
   || grep -q "BLOCKED.*process 'nix-daemon' is active" "$TEST_ENV_DIR/nix_daemon.log" \
   || grep -q "Blocked (process 'nix-daemon' is active)" "$TEST_ENV_DIR/nix_daemon.log"; then
  echo -e "${RED}FAIL: shipped Nix row was blocked by nix-daemon.${NC}"
  cat "$TEST_ENV_DIR/nix_daemon.log" 2>/dev/null || true
  exit 1
fi
echo -e "${GREEN}PASS: shipped commented Nix row, once uncommented, is not blocked when only nix-daemon is running.${NC}"

mkdir -p "$OUTSIDE_DIR/nix/store"
sed "s|/nix/store|$OUTSIDE_DIR/nix/store|" "$TEST_ENV_DIR/shipped_nix_daemon.conf" > "$TEST_ENV_DIR/nix_active_test.conf"
export MOCK_USER_ACTION_LOG="$TEST_ENV_DIR/nix_run.calls"
: > "$MOCK_USER_ACTION_LOG"
if ! run_test_case "Uncommented Nix Row Runs While Nix-Daemon Active" 0 "nix_runs.log" \
       --config "$TEST_ENV_DIR/nix_active_test.conf" --clean --force \
   || ! grep -qx "nix-store --gc" "$MOCK_USER_ACTION_LOG" \
   || ! grep -q '^Result: cleaned=1 skipped=0 failed=0 ' "$TEST_ENV_DIR/nix_runs.log"; then
  echo -e "${RED}FAIL: uncommented Nix row did not run while nix-daemon was active.${NC}"
  cat "$TEST_ENV_DIR/nix_runs.log" "$MOCK_USER_ACTION_LOG" 2>/dev/null || true
  exit 1
fi
unset MOCK_USER_ACTION_LOG
echo -e "${GREEN}PASS: uncommented Nix row runs while nix-daemon is active.${NC}"

for active_proc in nix-store nix-build; do
  cat > "$TEST_ENV_DIR/bin/pgrep" <<PGREP_BLOCK
#!/usr/bin/env bash
if [[ "\$1" == "-x" && "\$2" == "$active_proc" ]]; then
  exit 0
fi
exit 1
PGREP_BLOCK
  chmod +x "$TEST_ENV_DIR/bin/pgrep"
  export MOCK_USER_ACTION_LOG="$TEST_ENV_DIR/nix_${active_proc}.calls"
  : > "$MOCK_USER_ACTION_LOG"
  if ! run_test_case "Uncommented Nix Row Blocked By Active $active_proc" 0 "nix_${active_proc}_blocked.log" \
         --config "$TEST_ENV_DIR/nix_active_test.conf" --clean --force \
     || [[ -s "$MOCK_USER_ACTION_LOG" ]] \
     || ! grep -q "BLOCKED.*Nix Store: Skip cleanup because process '$active_proc' is active." "$TEST_ENV_DIR/nix_${active_proc}_blocked.log" \
     || ! grep -q '^Targets: found=0 .* blocked=1 ' "$TEST_ENV_DIR/nix_${active_proc}_blocked.log"; then
    echo -e "${RED}FAIL: active '$active_proc' did not block uncommented Nix row.${NC}"
    cat "$TEST_ENV_DIR/nix_${active_proc}_blocked.log" "$MOCK_USER_ACTION_LOG" 2>/dev/null || true
    exit 1
  fi
  unset MOCK_USER_ACTION_LOG
  echo -e "${GREEN}PASS: active '$active_proc' blocks the uncommented Nix row.${NC}"
done


# 4. --dry-run invokes none of the mocks and reports 0 B reclaimable with run-time size message.
setup_mock_env
mkdir -p "$MOCK_HOME/.cache/uv" "$MOCK_HOME/.local/share/pnpm/store" "$MOCK_HOME/.cache/huggingface/hub" "$OUTSIDE_DIR/nix/store"
truncate -s 3M "$MOCK_HOME/.cache/uv/large.bin"
cat > "$TEST_ENV_DIR/user_actions.conf" <<EOF
safe|UV Cache|\$HOME/.cache/uv|uv package manager cache (uv cache prune: unreachable entries only)|0|uv|action:uv_cache_prune
safe|PNPM Store|\$HOME/.local/share/pnpm/store|pnpm content-addressable store (pnpm store prune: unreferenced packages only)|0|pnpm|action:pnpm_store_prune
safe|Hugging Face Cache|\$HOME/.cache/huggingface/hub|Hugging Face hub cache (hf cache prune: detached revisions and incomplete downloads only)|0|hf|action:hf_cache_prune
safe|Nix Store|$OUTSIDE_DIR/nix/store|Nix package store (nix-store --gc: unreachable store paths only)|0|nix,nix-build,nix-store|action:nix_store_gc
EOF
export MOCK_USER_ACTION_LOG="$TEST_ENV_DIR/user_dry.calls"
: > "$MOCK_USER_ACTION_LOG"
if ! run_test_case "User Actions Dry Run Invokes No Mocks" 0 "user_actions_dry.log" \
       --config "$TEST_ENV_DIR/user_actions.conf" --dry-run --debug \
   || [[ -s "$MOCK_USER_ACTION_LOG" ]] \
   || ! grep -qF "[FOUND] UV Cache: size measured at run time (uv cache prune)" "$TEST_ENV_DIR/user_actions_dry.log" \
   || ! grep -qF "[FOUND] PNPM Store: size measured at run time (pnpm store prune)" "$TEST_ENV_DIR/user_actions_dry.log" \
   || ! grep -qF "[FOUND] Hugging Face Cache: size measured at run time (hf cache prune --yes)" "$TEST_ENV_DIR/user_actions_dry.log" \
   || ! grep -qF "[FOUND] Nix Store: size measured at run time (nix-store --gc) (outside HOME)" "$TEST_ENV_DIR/user_actions_dry.log" \
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

# 4a. --only-path refuses action:nix_store_gc like every action row.
if ! run_test_case "Nix Store GC Refused By --only-path" 1 "nix_only_path.log" \
       --config "$TEST_ENV_DIR/user_actions.conf" --only-target "Nix Store" --only-path "$OUTSIDE_DIR/nix" --dry-run \
   || ! grep -qF "Error: No eligible config target resolves at or below '--only-path $OUTSIDE_DIR/nix'." "$TEST_ENV_DIR/nix_only_path.log"; then
  echo -e "${RED}FAIL: --only-path did not refuse action:nix_store_gc.${NC}"
  cat "$TEST_ENV_DIR/nix_only_path.log" 2>/dev/null || true
  exit 1
fi
echo -e "${GREEN}PASS: action:nix_store_gc is refused by --only-path like every action row.${NC}"

# 4b. --dry-run --json marks user-level prune actions with size_at_run_time:true and size_human:"size at run time", while ordinary targets have size_at_run_time:false.
setup_mock_env
mkdir -p "$MOCK_HOME/.cache/uv" "$MOCK_HOME/.local/share/pnpm/store" "$MOCK_HOME/.cache/huggingface/hub" "$MOCK_HOME/.cache/plain_json"
truncate -s 3M "$MOCK_HOME/.cache/uv/large.bin"
printf 'plain-bytes\n' > "$MOCK_HOME/.cache/plain_json/data.txt"
cat > "$TEST_ENV_DIR/user_actions.conf" <<'EOF'
safe|UV Cache|$HOME/.cache/uv|uv package manager cache (uv cache prune: unreachable entries only)|0|uv|action:uv_cache_prune
safe|PNPM Store|$HOME/.local/share/pnpm/store|pnpm content-addressable store (pnpm store prune: unreferenced packages only)|0|pnpm|action:pnpm_store_prune
safe|Hugging Face Cache|$HOME/.cache/huggingface/hub|Hugging Face hub cache (hf cache prune: detached revisions and incomplete downloads only)|0|hf|action:hf_cache_prune
EOF
cat > "$TEST_ENV_DIR/user_actions_json_plain.conf" <<'EOF'
safe|UV Cache|$HOME/.cache/uv|uv package manager cache (uv cache prune: unreachable entries only)|0|uv|action:uv_cache_prune
safe|Plain Cache|$HOME/.cache/plain_json|Plain target|0||
EOF
if ! run_test_case "User Actions Dry Run JSON Marks Run-Time Size" 0 "user_actions_dry_json.log" \
       --config "$TEST_ENV_DIR/user_actions.conf" --dry-run --json \
   || ! python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
by_name = {t["name"]: t for t in d.get("targets", [])}
uv = by_name["UV Cache"]
assert uv["size_at_run_time"] is True
assert uv["size_human"] == "size at run time"
assert uv["bytes"] == 0
assert uv["status"] == "found"
' "$TEST_ENV_DIR/user_actions_dry_json.log" 2>/dev/null \
   || ! run_test_case "User Actions Dry Run JSON Plain Target False" 0 "user_actions_dry_json_plain.log" \
       --config "$TEST_ENV_DIR/user_actions_json_plain.conf" --dry-run --json \
   || ! python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
by_name = {t["name"]: t for t in d.get("targets", [])}
uv = by_name["UV Cache"]
plain = by_name["Plain Cache"]
assert uv["size_at_run_time"] is True and uv["size_human"] == "size at run time" and uv["bytes"] == 0
assert plain["size_at_run_time"] is False and plain["status"] == "found" and plain["bytes"] > 0
' "$TEST_ENV_DIR/user_actions_dry_json_plain.log" 2>/dev/null; then
  echo -e "${RED}FAIL: --dry-run --json did not mark run-time size on user actions or false on ordinary targets.${NC}"
  cat "$TEST_ENV_DIR/user_actions_dry_json.log" "$TEST_ENV_DIR/user_actions_dry_json_plain.log" 2>/dev/null || true
  exit 1
fi
echo -e "${GREEN}PASS: --dry-run --json marks user-level prune actions with size_at_run_time=true and ordinary targets with false.${NC}"

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
if ! run_test_case "Report JSON Action DF Bytes" 0 "action_report.json" --report --json \
   || ! python3 - "$TEST_ENV_DIR/action_report.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert (d["quarantined_bytes"], d["permanent_bytes"]) == (0, 1048576), d
PY
then
  echo -e "${RED}FAIL: saved report changed action delta credits or negative clamping.${NC}"
  exit 1
fi

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

# An aged quarantine run killed mid-loop (after the first moved file) must
# already carry its quarantine.meta record so --restore can return the moved
# files, while an uninterrupted aged quarantine still writes exactly one record
# per target.
setup_mock_env
aged_int_target="$MOCK_HOME/.cache/aged_interrupted"
mkdir -p "$aged_int_target"
printf 'first-aged\n' > "$aged_int_target/first.txt"
printf 'second-aged\n' > "$aged_int_target/second.txt"
touch -d '10 days ago' "$aged_int_target/first.txt" "$aged_int_target/second.txt"
cat > "$TEST_ENV_DIR/aged_interrupted.conf" <<'EOF'
safe|Aged Interrupted|$HOME/.cache/aged_interrupted|Aged target interrupted mid-loop|7||
EOF
cat > "$TEST_ENV_DIR/bin/mv" <<'KILL_MV'
#!/usr/bin/env bash
real_mv=$(PATH="${PATH#"$TEST_ENV_DIR/bin:"}" command -v mv)
case "${1:-}" in
  *aged_interrupted*)
    if [[ -f "$TEST_ENV_DIR/aged_mv_once" ]]; then
      kill -9 "$PPID"
      exit 1
    fi
    : > "$TEST_ENV_DIR/aged_mv_once"
    "$real_mv" "$@"
    ;;
  *)
    exec "$real_mv" "$@"
    ;;
esac
KILL_MV
chmod +x "$TEST_ENV_DIR/bin/mv"

echo -e "\n${BOLD}Test Case: Trash Aged Interrupted Keeps Metadata${NC}"
aged_int_ec=0
PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" "$CLEANER_SH" \
  --config "$TEST_ENV_DIR/aged_interrupted.conf" --clean --trash --force \
  < /dev/null > "$TEST_ENV_DIR/aged_interrupted.log" 2>&1 || aged_int_ec=$?
rm -f "$TEST_ENV_DIR/bin/mv"
aged_int_meta=$(find "$MOCK_HOME/.cache/linux-cleaner/quarantine" -name quarantine.meta -print -quit 2>/dev/null)
if [[ "$aged_int_ec" -eq 0 ]] \
   || [[ ! -f "$aged_int_meta" ]] \
   || [[ "$(grep -c '^aged|0_Aged_Interrupted|' "$aged_int_meta")" -ne 1 ]] \
   || [[ -f "$aged_int_target/first.txt" && -f "$aged_int_target/second.txt" ]] \
   || [[ ! -f "$aged_int_target/first.txt" && ! -f "$aged_int_target/second.txt" ]]; then
  echo -e "${RED}FAIL: interrupted aged quarantine did not leave exactly one moved file and one quarantine.meta record (ec=$aged_int_ec).${NC}"
  cat "$aged_int_meta" "$TEST_ENV_DIR/aged_interrupted.log" 2>/dev/null || true
  exit 1
fi
if ! run_test_case "Restore Interrupted Aged Quarantine" 0 "aged_interrupted_restore.log" --restore latest \
   || ! grep -qx 'first-aged' "$aged_int_target/first.txt" \
   || ! grep -qx 'second-aged' "$aged_int_target/second.txt" \
   || [[ -d "$(dirname "$aged_int_meta")" ]]; then
  echo -e "${RED}FAIL: --restore latest did not restore the file moved before SIGKILL.${NC}"
  cat "$TEST_ENV_DIR/aged_interrupted_restore.log" 2>/dev/null || true
  exit 1
fi
# Uninterrupted aged quarantine with multiple files still writes exactly one record.
touch -d '10 days ago' "$aged_int_target/first.txt" "$aged_int_target/second.txt"
if ! run_test_case "Uninterrupted Aged Quarantine Single Record" 0 "aged_uninterrupted.log" \
       --config "$TEST_ENV_DIR/aged_interrupted.conf" --clean --trash --force; then
  exit 1
fi
aged_unint_meta=$(find "$MOCK_HOME/.cache/linux-cleaner/quarantine" -name quarantine.meta -print -quit 2>/dev/null)
if [[ ! -f "$aged_unint_meta" ]] \
   || [[ "$(wc -l < "$aged_unint_meta")" -ne 1 ]] \
   || [[ "$(grep -c '^aged|0_Aged_Interrupted|' "$aged_unint_meta")" -ne 1 ]]; then
  echo -e "${RED}FAIL: uninterrupted aged quarantine did not write exactly one metadata record.${NC}"
  cat "$aged_unint_meta" 2>/dev/null || true
  exit 1
fi
echo -e "${GREEN}PASS: interrupted aged quarantine records metadata on the first moved file and stays restorable.${NC}"

# A failed aged quarantine.meta append must stop the loop. The file already
# moved stays unrecorded; every later file stays at its original path.
setup_mock_env
aged_stop_target="$MOCK_HOME/.cache/aged_meta_stop"
mkdir -p "$aged_stop_target"
printf 'first-aged\n' > "$aged_stop_target/first.txt"
printf 'second-aged\n' > "$aged_stop_target/second.txt"
printf 'third-aged\n' > "$aged_stop_target/third.txt"
touch -d '10 days ago' "$aged_stop_target/first.txt" "$aged_stop_target/second.txt" "$aged_stop_target/third.txt"
cat > "$TEST_ENV_DIR/aged_meta_stop.conf" <<'EOF'
safe|Aged Meta Stop|$HOME/.cache/aged_meta_stop|Aged target whose metadata append fails|7||
EOF
cat > "$TEST_ENV_DIR/bin/mv" <<'META_MV'
#!/usr/bin/env bash
real_mv=$(PATH="${PATH#"$TEST_ENV_DIR/bin:"}" command -v mv)
if ! "$real_mv" "$@"; then
  exit 1
fi
if [[ ! -f "$TEST_ENV_DIR/aged_meta_mv_once" ]]; then
  : > "$TEST_ENV_DIR/aged_meta_mv_once"
  dest="${@: -1}"
  session=$(dirname "$(dirname "$dest")")
  mkdir "$session/quarantine.meta"
fi
META_MV
chmod +x "$TEST_ENV_DIR/bin/mv"

aged_stop_ok=true
if ! run_test_case "Trash Aged Metadata Append Failure Stops Moves" 1 "aged_meta_stop.log" \
     --config "$TEST_ENV_DIR/aged_meta_stop.conf" --clean --trash --force; then
  aged_stop_ok=false
fi
rm -f "$TEST_ENV_DIR/bin/mv"
aged_stop_session=$(find "$MOCK_HOME/.cache/linux-cleaner/quarantine" -mindepth 1 -maxdepth 1 -type d -print -quit 2>/dev/null || true)
aged_stop_left=0
for aged_stop_name in first.txt second.txt third.txt; do
  if [[ -f "$aged_stop_target/$aged_stop_name" ]]; then
    aged_stop_left=$((aged_stop_left + 1))
  fi
done
aged_stop_moved=0
if [[ -n "$aged_stop_session" ]]; then
  aged_stop_moved=$(find "$aged_stop_session" -type f | wc -l)
fi
if [[ "$aged_stop_ok" == true && "$aged_stop_left" -eq 2 && "$aged_stop_moved" -eq 1 ]]; then
  echo -e "${GREEN}PASS: a failed aged metadata append stopped further moves and left the other files in place.${NC}"
else
  echo -e "${RED}FAIL: aged metadata append failure did not stop after one moved file (left=$aged_stop_left moved=$aged_stop_moved).${NC}"
  cat "$TEST_ENV_DIR/aged_meta_stop.log" 2>/dev/null || true
  find "$MOCK_HOME/.cache/linux-cleaner/quarantine" -print 2>/dev/null || true
  exit 1
fi

# A mutating run (--clean, --restore, --purge-sessions) takes an exclusive
# non-blocking flock on $HOME/.cache/linux-cleaner/cleaner.lock and refuses a
# concurrent mutating run with exit 1 and nothing deleted, while refusing a
# symlinked lock path. Dry-run and read-only modes never take the lock.
setup_mock_env
# Seed a saved report before locking so --report has a report to read while locked.
if ! run_test_case "Concurrent Run Lock Seed Report" 0 "concurrent_lock_seed.log" \
       --config "$TEST_ENV_DIR/test_cleaner.conf" --only-target Aurman --clean --force; then
  exit 1
fi
mkdir -p "$MOCK_HOME/.cache/aurman"
echo "dummy aurman pkg" > "$MOCK_HOME/.cache/aurman/pkg1.tar.zst"

lock_dir="$MOCK_HOME/.cache/linux-cleaner"
lock_file="$lock_dir/cleaner.lock"
(umask 077; mkdir -p "$lock_dir")
q_lock_sess="$lock_dir/quarantine/2026-02-02_00-00-00"
mkdir -p "$q_lock_sess/0_Lock_Target"
printf 'quarantined-payload\n' > "$q_lock_sess/0_Lock_Target/item.txt"
printf 'full|0_Lock_Target|%s/.cache/lock_restored|false|%s|%s\n' \
  "$MOCK_HOME" "$(id -u)" "$(id -g)" > "$q_lock_sess/quarantine.meta"

exec 8>"$lock_file"
if ! flock -n 8; then
  exec 8>&-
  echo -e "${RED}FAIL: test could not acquire initial flock on '$lock_file'.${NC}"
  exit 1
fi

lock_expected_msg="Error: another linux-cleaner run is in progress (lock: ${lock_file})."
if ! run_test_case "Concurrent Run Lock" 1 "concurrent_lock_clean.log" \
       --config "$TEST_ENV_DIR/test_cleaner.conf" --clean --force \
   || ! grep -qF "$lock_expected_msg" "$TEST_ENV_DIR/concurrent_lock_clean.log" \
   || [[ ! -f "$MOCK_HOME/.npm/_cacache/cache1.txt" ]] \
   || ! run_test_case "Concurrent Run Lock Restore" 1 "concurrent_lock_restore.log" \
       --restore latest \
   || ! grep -qF "$lock_expected_msg" "$TEST_ENV_DIR/concurrent_lock_restore.log" \
   || [[ -e "$MOCK_HOME/.cache/lock_restored" ]] \
   || [[ ! -f "$q_lock_sess/0_Lock_Target/item.txt" ]] \
   || ! run_test_case "Concurrent Run Lock Purge" 1 "concurrent_lock_purge.log" \
       --purge-sessions all --force \
   || ! grep -qF "$lock_expected_msg" "$TEST_ENV_DIR/concurrent_lock_purge.log" \
   || [[ ! -d "$q_lock_sess" ]]; then
  exec 8>&-
  echo -e "${RED}FAIL: concurrent mutating run did not exit 1 with the lock error or modified files.${NC}"
  cat "$TEST_ENV_DIR"/concurrent_lock_*.log 2>/dev/null || true
  exit 1
fi

if ! run_test_case "Concurrent Run Lock Dry Run Unaffected" 0 "concurrent_lock_dry.log" \
       --config "$TEST_ENV_DIR/test_cleaner.conf" --dry-run \
   || ! grep -q "Total potential space savings:" "$TEST_ENV_DIR/concurrent_lock_dry.log" \
   || ! run_test_case "Concurrent Run Lock List Targets Unaffected" 0 "concurrent_lock_lt.log" \
       --config "$TEST_ENV_DIR/test_cleaner.conf" --list-targets \
   || ! run_test_case "Concurrent Run Lock List Sessions Unaffected" 0 "concurrent_lock_ls.log" \
       --list-sessions \
   || ! run_test_case "Concurrent Run Lock Check Config Unaffected" 0 "concurrent_lock_cc.log" \
       --config "$TEST_ENV_DIR/test_cleaner.conf" --check-config \
   || ! run_test_case "Concurrent Run Lock Report Unaffected" 0 "concurrent_lock_report.log" \
       --report; then
  exec 8>&-
  echo -e "${RED}FAIL: dry-run or read-only modes failed while the lock was held.${NC}"
  cat "$TEST_ENV_DIR"/concurrent_lock_*.log 2>/dev/null || true
  exit 1
fi

# Release the lock and verify a mutating run now succeeds without contention.
exec 8>&-
if ! run_test_case "Concurrent Run Lock Released Clean Succeeds" 0 "concurrent_lock_after.log" \
       --config "$TEST_ENV_DIR/test_cleaner.conf" --only-target Aurman --clean --force \
   || [[ -e "$MOCK_HOME/.cache/aurman" ]]; then
  echo -e "${RED}FAIL: cleanup did not succeed after the lock was released.${NC}"
  cat "$TEST_ENV_DIR/concurrent_lock_after.log" 2>/dev/null || true
  exit 1
fi

# A symlinked lock file is refused before any deletion.
rm -f "$lock_file"
ln -s "$TEST_ENV_DIR/lock_symlink_target" "$lock_file"
if ! run_test_case "Concurrent Run Lock Refuses Symlink" 1 "concurrent_lock_sym.log" \
       --config "$TEST_ENV_DIR/test_cleaner.conf" --clean --force \
   || [[ ! -f "$MOCK_HOME/.npm/_cacache/cache1.txt" ]] \
   || [[ -e "$TEST_ENV_DIR/lock_symlink_target" ]]; then
  echo -e "${RED}FAIL: symlinked lock path was not refused or followed the symlink.${NC}"
  cat "$TEST_ENV_DIR/concurrent_lock_sym.log" 2>/dev/null || true
  exit 1
fi
echo -e "${GREEN}PASS: concurrent mutating runs exit 1 on lock contention while dry-run and read-only modes remain unaffected.${NC}"

# Bounded waits use the same real flock and fd lifetime, with explicit handshakes.
python3 - "$CLEANER_SH" <<'LOCK_WAIT_PY'
import hashlib, os, pathlib, select, shutil, signal, stat, subprocess, sys, tempfile
with tempfile.TemporaryDirectory(prefix="cleaner-lock-wait-", dir="/tmp") as directory:
    root = pathlib.Path(directory)
    cleaner, real_flock, real_rm = sys.argv[1], shutil.which("flock"), shutil.which("rm")
    home, bindir = root / "home", root / "bin"
    home.mkdir(); bindir.mkdir()
    payload = home / "cache"
    config = root / "fixture.conf"
    config.write_text("safe|Fixture|$HOME/cache|Fixture payload|0||\n")
    lock = home / ".cache/linux-cleaner/cleaner.lock"
    lock.parent.mkdir(parents=True)
    lock.touch()
    report = home / "state/linux-cleaner/last-report.txt"
    report.parent.mkdir(parents=True); report.write_text("prior report\n")
    log = home / "operations.log"; log.write_text("prior log\n")
    session = lock.parent / "quarantine/2026-01-01_00-00-00"
    session.mkdir(parents=True); (session / "payload").write_text("quarantined\n")
    (session / "quarantine.meta").write_text(f"full|payload|{home}/restored|false|{os.getuid()}|{os.getgid()}\n")
    trace = root / "removals"
    (bindir / "rm").write_text('#!/usr/bin/env bash\nfor arg in "$@"; do\n'
        ' [[ "$arg" != "$LOCK_TEST_PAYLOAD" ]] || printf "remove\\n" >> "$LOCK_TEST_TRACE"\n'
        'done\nexec "' + real_rm + '" "$@"\n')
    (bindir / "flock").write_text('#!/usr/bin/env bash\n'
        'printf "%s\\n" "$*" >&"$LOCK_TEST_NOTIFY_FD"\nexec "' + real_flock + '" "$@"\n')
    for p in bindir.iterdir(): p.chmod(0o755)
    env = {k: v for k, v in os.environ.items() if not k.startswith(("LINUX_CLEANER_", "XDG_"))}
    env.update(HOME=str(home), XDG_STATE_HOME=str(home / "state"), NO_COLOR="1",
               PATH=str(bindir) + ":" + env["PATH"], LOCK_TEST_PAYLOAD=str(payload), LOCK_TEST_TRACE=str(trace))
    def snapshot():
        return {str(p.relative_to(home)): (p.lstat().st_mode, os.readlink(p) if p.is_symlink()
                else hashlib.sha256(p.read_bytes()).hexdigest() if stat.S_ISREG(p.lstat().st_mode) else None)
                for p in home.rglob("*")}
    def run(label, args, current=env, expected=0):
        print("Test Case: Lock Wait " + label, flush=True)
        r = subprocess.run([cleaner, "--config", str(config)] + args, env=current,
                           capture_output=True, text=True, timeout=10)
        assert r.returncode == expected, (label, r)
        print("PASS: Lock Wait " + label, flush=True)
        return r
    # Baseline comparison stops here, on a read-only unsupported-option failure.
    run("valid setting on inventory", ["--list-targets", "--json", "--lock-wait", "1"])
    for value in ("-1", "+1", " 1", "1 ", "1\n", "1.5", "1s", "2147483648", "9" * 100):
        before = snapshot()
        r = run("invalid effective CLI " + repr(value), ["--init-config", "--lock-wait", value], expected=1)
        assert "--lock-wait must be an integer" in r.stderr and snapshot() == before
    for args in (["--lock-wait"], ["--lock-wait", ""]):
        before = snapshot()
        r = run("missing or empty CLI", args, expected=1)
        assert "requires a seconds argument" in r.stderr and snapshot() == before
    for value in ("bad", "-1", "2147483648"):
        before = snapshot()
        r = run("invalid inherited input " + value, ["--init-config"], env | {"LINUX_CLEANER_LOCK_WAIT": value}, 1)
        assert "--lock-wait must be an integer" in r.stderr and snapshot() == before
    for value in ("", "0", "000000", "0002147483647", "0" * 100 + "1"):
        before = snapshot()
        run("valid inherited bound " + repr(value), ["--list-targets", "--json"], env | {"LINUX_CLEANER_LOCK_WAIT": value})
        assert snapshot() == before
    run("CLI overrides malformed environment and earlier CLI", ["--list-targets", "--lock-wait", "bad", "--lock-wait", "0002"], env | {"LINUX_CLEANER_LOCK_WAIT": "bad"})
    holder = subprocess.Popen([real_flock, str(lock), sys.executable, "-u", "-c",
        'print("held", flush=True); input()'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, text=True, start_new_session=True)
    processes = [holder]
    try:
        assert select.select([holder.stdout], [], [], 5)[0] and holder.stdout.readline() == "held\n"
        def locked(label, args, expected_args, current=env, release=False):
            print("Test Case: Lock Wait " + label, flush=True)
            read_fd, write_fd = os.pipe()
            before = snapshot()
            try:
                child = subprocess.Popen([cleaner, "--config", str(config)] + args,
                    env=current | {"LOCK_TEST_NOTIFY_FD": str(write_fd)}, pass_fds=(write_fd,),
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
                processes.append(child); os.close(write_fd); write_fd = None
                assert select.select([read_fd], [], [], 5)[0], label
                assert os.read(read_fd, 128).decode().strip() == expected_args, label
                if release:
                    assert child.poll() is None and snapshot() == before
                    holder.communicate("release\n", timeout=5)
                stdout, stderr = child.communicate(timeout=8)
                assert child.returncode == (0 if release else 1), (label, stdout, stderr)
                if not release:
                    assert holder.poll() is None and snapshot() == before
                    assert ("another linux-cleaner run is in progress" if expected_args == "-n 9"
                            else "Failed to acquire linux-cleaner lock within 1 second(s)") in stderr, stderr
                print("PASS: Lock Wait " + label, flush=True)
            finally:
                os.close(read_fd)
                if write_fd is not None: os.close(write_fd)
        payload.mkdir(); (payload / "item").write_text("cleanup once\n")
        for label, extra, current in (("default zero", [], env), ("explicit zero overrides env", ["--lock-wait", "000"], env | {"LINUX_CLEANER_LOCK_WAIT": "3"})):
            locked(label, ["--clean", "--force"] + extra, "-n 9", current)
        for label, args in (("cleanup timeout", ["--clean", "--force"]), ("restore timeout", ["--restore", "latest"]),
                            ("purge timeout", ["--purge-sessions", "all", "--force"])):
            locked(label, args + ["--lock-wait", "01", "--log", str(log)], "-w 1 9")
        before = snapshot()
        for args in (["--dry-run", "--json"], ["--list-targets", "--json"], ["--list-sessions", "--json"], ["--report"], ["--check-config"]):
            run("held lock ignored " + args[0], args + ["--lock-wait", "2147483647"])
            assert snapshot() == before
        locked("release before deadline cleans once", ["--clean", "--force", "--lock-wait", "0005"], "-w 5 9", env | {"LINUX_CLEANER_LOCK_WAIT": "bad"}, True)
        assert not payload.exists() and trace.read_text() == "remove\n"
        holder = subprocess.Popen([real_flock, str(lock), sys.executable, "-u", "-c",
            'print("held", flush=True); input()'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, start_new_session=True)
        processes.append(holder)
        assert select.select([holder.stdout], [], [], 5)[0] and holder.stdout.readline() == "held\n"
        locked("environment wait restores after release", ["--restore", "latest"], "-w 3 9",
               env | {"LINUX_CLEANER_LOCK_WAIT": "0003"}, True)
        assert (home / "restored").read_text() == "quarantined\n" and not session.exists()
    finally:
        for child in processes:
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGTERM)
                child.communicate(timeout=5)
    # Removing only flock from PATH proves positive refusal and zero fallback.
    missing = root / "without-flock"; missing.mkdir()
    for tool in "bash basename cat dirname realpath sed du awk tr id sort find stat date rm mktemp mkdir mv cp chmod rmdir cut grep df".split():
        (missing / tool).symlink_to(shutil.which(tool))
    current = env | {"PATH": str(missing)}
    lock.unlink(); lock.parent.rmdir()
    payload.mkdir(); (payload / "item").write_text("fallback payload\n")
    before = snapshot()
    r = run("positive requires installed flock before state", ["--clean", "--force", "--lock-wait", "1"], current, 1)
    assert "requires flock" in r.stderr and snapshot() == before
    run("zero retains optional-flock fallback", ["--clean", "--force", "--lock-wait", "0"], current)
    assert not payload.exists()
    run("init ignores valid wait without flock", ["--init-config", "--lock-wait", "1"], current)
    assert (home / ".config/linux-cleaner/cleaner.conf").read_bytes() == config.read_bytes()
    assert stat.S_IMODE((home / ".config/linux-cleaner/cleaner.conf").stat().st_mode) == 0o644
LOCK_WAIT_PY

# An interrupted cleanup (SIGINT/SIGTERM) saves a partial result report with
# "Interrupted: SIGINT|SIGTERM before all targets finished", logs one
# mode=run outcome=interrupted line when --log is enabled, and exits 130/143;
# an uninterrupted run has no "Interrupted:" line.
setup_mock_env
mkdir -p "$MOCK_HOME/.cache/int_first" "$MOCK_HOME/.cache/int_second" "$MOCK_HOME/.cache/int_third"
printf 'first-payload\n' > "$MOCK_HOME/.cache/int_first/a.txt"
printf 'second-payload\n' > "$MOCK_HOME/.cache/int_second/b.txt"
printf 'third-payload\n' > "$MOCK_HOME/.cache/int_third/c.txt"
cat > "$TEST_ENV_DIR/interrupted_clean.conf" <<'EOF'
safe|Int First|$HOME/.cache/int_first|First target cleaned before signal|0||
safe|Int Second|$HOME/.cache/int_second|Second target triggers SIGTERM|0||
safe|Int Third|$HOME/.cache/int_third|Third target never reached|0||
EOF
cat > "$TEST_ENV_DIR/bin/rm" <<'TERM_RM'
#!/usr/bin/env bash
real_rm=$(PATH="${PATH#"$TEST_ENV_DIR/bin:"}" command -v rm)
for arg in "$@"; do
  case "$arg" in
    *int_second*)
      "$real_rm" "$@"
      kill -TERM "$PPID"
      exit 0
      ;;
  esac
done
exec "$real_rm" "$@"
TERM_RM
chmod +x "$TEST_ENV_DIR/bin/rm"
int_ops_log="$MOCK_HOME/.cache/linux-cleaner/operations.log"
rm -f "$int_ops_log"
int_report_file="$XDG_STATE_HOME/linux-cleaner/last-report.txt"
rm -f "$int_report_file"
int_credited_bytes=$(du -sb "$MOCK_HOME/.cache/int_first" | cut -f1)

if ! run_test_case "Interrupted Cleanup Saves Report" 143 "interrupted_clean.log" \
       --config "$TEST_ENV_DIR/interrupted_clean.conf" --clean --force --log; then
  rm -f "$TEST_ENV_DIR/bin/rm"
  exit 1
fi
rm -f "$TEST_ENV_DIR/bin/rm"

if [[ -e "$MOCK_HOME/.cache/int_first" ]] \
   || [[ ! -f "$MOCK_HOME/.cache/int_third/c.txt" ]] \
   || [[ ! -f "$int_report_file" ]] \
   || ! grep -q '^Result: cleaned=1 skipped=0 failed=0 ' "$int_report_file" \
   || ! grep -qx 'Interrupted: SIGTERM before all targets finished' "$int_report_file" \
   || ! grep -qx 'Interrupted: SIGTERM before all targets finished' "$TEST_ENV_DIR/interrupted_clean.log" \
   || ! grep -q 'mode=run outcome=interrupted' "$int_ops_log"; then
  echo -e "${RED}FAIL: SIGTERM-interrupted cleanup did not save partial report, print Interrupted line, or log outcome=interrupted.${NC}"
  cat "$TEST_ENV_DIR/interrupted_clean.log" "$int_report_file" "$int_ops_log" 2>/dev/null || true
  exit 1
fi

if ! run_test_case "Interrupted Cleanup Report Command" 0 "interrupted_report_cmd.log" --report \
   || ! grep -qx 'Interrupted: SIGTERM before all targets finished' "$TEST_ENV_DIR/interrupted_report_cmd.log" \
   || ! cmp -s "$int_report_file" "$TEST_ENV_DIR/interrupted_report_cmd.log"; then
  echo -e "${RED}FAIL: --report did not print the saved interrupted cleanup report.${NC}"
  cat "$TEST_ENV_DIR/interrupted_report_cmd.log" 2>/dev/null || true
  exit 1
fi

if ! run_test_case "Report JSON Interrupted Accounted Bytes" 0 "interrupted_bytes.json" --report --json \
   || ! python3 - "$TEST_ENV_DIR/interrupted_bytes.json" "$int_credited_bytes" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["interrupted"] == "SIGTERM", d
assert (d["quarantined_bytes"], d["permanent_bytes"]) == (0, int(sys.argv[2])), d
PY
then
  echo -e "${RED}FAIL: interrupted report did not retain only already-credited bytes.${NC}"
  exit 1
fi

# Uninterrupted cleanup has no "Interrupted:" line in stdout or last-report.txt.
mkdir -p "$MOCK_HOME/.cache/int_first" "$MOCK_HOME/.cache/int_second" "$MOCK_HOME/.cache/int_third"
printf 'first-payload\n' > "$MOCK_HOME/.cache/int_first/a.txt"
printf 'second-payload\n' > "$MOCK_HOME/.cache/int_second/b.txt"
printf 'third-payload\n' > "$MOCK_HOME/.cache/int_third/c.txt"
if ! run_test_case "Uninterrupted Cleanup Report Has No Interrupted Line" 0 "uninterrupted_clean.log" \
       --config "$TEST_ENV_DIR/interrupted_clean.conf" --clean --force \
   || grep -q 'Interrupted:' "$TEST_ENV_DIR/uninterrupted_clean.log" \
   || grep -q 'Interrupted:' "$int_report_file" \
   || ! grep -q '^Result: cleaned=3 skipped=0 failed=0 ' "$int_report_file"; then
  echo -e "${RED}FAIL: uninterrupted cleanup report contained an unexpected Interrupted: line.${NC}"
  cat "$TEST_ENV_DIR/uninterrupted_clean.log" "$int_report_file" 2>/dev/null || true
  exit 1
fi
echo -e "${GREEN}PASS: interrupted cleanup saves partial report and logs outcome=interrupted; uninterrupted run has no Interrupted line.${NC}"

# Completed aged records remain retryable across metadata replacement and cleanup.
setup_restore_checkpoint() {
  setup_mock_env
  checkpoint_session="$MOCK_HOME/.cache/linux-cleaner/quarantine/2026-03-02_00-00-00"
  checkpoint_first="$MOCK_HOME/.cache/checkpoint_first"
  checkpoint_second="$MOCK_HOME/.cache/checkpoint_second"
  checkpoint_sibling="$MOCK_HOME/.cache/checkpoint_sibling"
  mkdir -p "$checkpoint_session/0_First" "$checkpoint_session/1_Second" "$checkpoint_first" "$checkpoint_second"
  printf 'first\n' > "$checkpoint_session/0_First/item"
  printf 'second\n' > "$checkpoint_session/1_Second/item"
  printf 'sibling\n' > "$checkpoint_session/2_Sibling"
  printf 'aged|0_First|%s|false|%s|%s\naged|1_Second|%s|false|%s|%s\nfull|2_Sibling|%s|false|%s|%s\n' \
    "$checkpoint_first" "$(id -u)" "$(id -g)" "$checkpoint_second" "$(id -u)" "$(id -g)" \
    "$checkpoint_sibling" "$(id -u)" "$(id -g)" > "$checkpoint_session/quarantine.meta"
  export MOCK_RESTORE_SESSION="$checkpoint_session" MOCK_RESTORE_HOOK="$1"
  cat > "$TEST_ENV_DIR/bin/mv" <<'CHECKPOINT_MV'
#!/usr/bin/env bash
src="${@: -2:1}" dest="${@: -1}"
if [[ "$dest" == "$MOCK_RESTORE_SESSION/quarantine.meta" ]]; then
  case "$MOCK_RESTORE_HOOK" in
    before-marker|checkpoint-fail)
      if grep -q '^aged-restored|0_First|' "$src"; then
        [[ "$MOCK_RESTORE_HOOK" == before-marker ]] && kill -TERM "$PPID"
        exit 1
      fi
      ;;
    before-reconcile|reconcile-fail)
      if ! grep -q '^aged-restored|' "$src"; then
        [[ "$MOCK_RESTORE_HOOK" == before-reconcile ]] && kill -TERM "$PPID"
        exit 1
      fi
      ;;
  esac
fi
real_mv=$(PATH="${PATH#"$TEST_ENV_DIR/bin:"}" command -v mv)
"$real_mv" "$@" || exit $?
if [[ "$dest" == "$MOCK_RESTORE_SESSION/quarantine.meta" && "$MOCK_RESTORE_HOOK" == after-marker ]] \
   && grep -q '^aged-restored|1_Second|' "$dest"; then
  kill -TERM "$PPID"
fi
CHECKPOINT_MV
  cat > "$TEST_ENV_DIR/bin/find" <<'CHECKPOINT_FIND'
#!/usr/bin/env bash
real_find=$(PATH="${PATH#"$TEST_ENV_DIR/bin:"}" command -v find)
if [[ "$MOCK_RESTORE_HOOK" == after-root && "${1:-}" == "$MOCK_RESTORE_SESSION/0_First" && "${2:-}" == -depth ]]; then
  "$real_find" "$@" || exit $?
  kill -TERM "$PPID"
  exit 1
fi
exec "$real_find" "$@"
CHECKPOINT_FIND
  chmod +x "$TEST_ENV_DIR/bin/mv" "$TEST_ENV_DIR/bin/find"
}

for checkpoint_hook in after-root before-marker after-marker before-reconcile; do
  setup_restore_checkpoint "$checkpoint_hook"
  checkpoint_args=()
  [[ "$checkpoint_hook" == before-reconcile ]] && checkpoint_args=(--only checkpoint_first)
  if ! run_test_case "Aged Restore Interrupted ($checkpoint_hook)" 143 "checkpoint_killed.log" --restore latest "${checkpoint_args[@]}" \
     || ! grep -qx first "$checkpoint_first/item"; then
    echo -e "${RED}FAIL: aged restore interruption did not leave its restored file intact.${NC}"
    exit 1
  fi
  case "$checkpoint_hook" in
    before-marker)
      [[ -d "$checkpoint_session/0_First" ]] && grep -q '^aged|0_First|' "$checkpoint_session/quarantine.meta" || exit 1
      checkpoint_scratch=$(find "$(dirname "$checkpoint_session")" -maxdepth 1 -name '.restore-meta.*' -print -quit)
      [[ -f "$checkpoint_scratch" && "$(stat -c %a "$checkpoint_scratch")" == 600 ]] || exit 1
      ;;
    after-marker)
      [[ "$(grep -c '^aged-restored|' "$checkpoint_session/quarantine.meta")" -eq 2 \
         && ! -e "$checkpoint_session/0_First" && -d "$checkpoint_session/1_Second" ]] || exit 1
      ;;
    *)
      [[ ! -e "$checkpoint_session/0_First" ]] && grep -q '^aged-restored|0_First|' "$checkpoint_session/quarantine.meta" || exit 1
      ;;
  esac
  rm -f "$TEST_ENV_DIR/bin/mv" "$TEST_ENV_DIR/bin/find"
  if ! run_test_case "Aged Restore Interrupted Retry ($checkpoint_hook)" 0 "checkpoint_retry.log" --restore latest \
     || ! grep -qx first "$checkpoint_first/item" || ! grep -qx second "$checkpoint_second/item" \
     || ! grep -qx sibling "$checkpoint_sibling" || [[ -e "$checkpoint_session" ]]; then
    echo -e "${RED}FAIL: checkpointed aged restore could not finish after $checkpoint_hook.${NC}"
    exit 1
  fi
done

for checkpoint_hook in checkpoint-fail reconcile-fail; do
  setup_restore_checkpoint "$checkpoint_hook"
  checkpoint_args=()
  [[ "$checkpoint_hook" == reconcile-fail ]] && checkpoint_args=(--only checkpoint_first)
  if ! run_test_case "Aged Restore Metadata Failure ($checkpoint_hook)" 1 "checkpoint_failure.log" --restore latest "${checkpoint_args[@]}" \
     || ! grep -qx first "$checkpoint_first/item"; then
    exit 1
  fi
  if [[ "$checkpoint_hook" == checkpoint-fail ]]; then
    [[ -d "$checkpoint_session/0_First" && "$(wc -l < "$checkpoint_session/quarantine.meta")" -eq 1 ]] \
      && grep -q '^aged|0_First|' "$checkpoint_session/quarantine.meta" \
      && grep -qx second "$checkpoint_second/item" && grep -qx sibling "$checkpoint_sibling" || exit 1
  else
    [[ ! -e "$checkpoint_session/0_First" && "$(wc -l < "$checkpoint_session/quarantine.meta")" -eq 3 ]] \
      && grep -q '^aged-restored|0_First|' "$checkpoint_session/quarantine.meta" \
      && [[ -f "$checkpoint_session/1_Second/item" && -f "$checkpoint_session/2_Sibling" ]] || exit 1
  fi
  rm -f "$TEST_ENV_DIR/bin/mv" "$TEST_ENV_DIR/bin/find"
  if ! run_test_case "Aged Restore Metadata Failure Retry ($checkpoint_hook)" 0 "checkpoint_failure_retry.log" --restore latest \
     || [[ -e "$checkpoint_session" ]]; then
    exit 1
  fi
done

for checkpoint_payload in file fifo symlink dangling root-symlink root-dangling; do
  setup_restore_checkpoint none
  rm "$checkpoint_session/0_First/item"
  sed -i 's/^aged|0_First|/aged-restored|0_First|/' "$checkpoint_session/quarantine.meta"
  protected_payload="$checkpoint_session/0_First/payload"
  case "$checkpoint_payload" in
    file) printf 'keep\n' > "$protected_payload" ;;
    fifo) mkfifo "$protected_payload" ;;
    symlink) ln -s "$checkpoint_session/1_Second" "$protected_payload" ;;
    dangling) ln -s "$checkpoint_session/absent" "$protected_payload" ;;
    root-*)
      rmdir "$checkpoint_session/0_First"
      protected_payload="$checkpoint_session/0_First"
      if [[ "$checkpoint_payload" == root-symlink ]]; then
        ln -s "$checkpoint_session/1_Second" "$protected_payload"
      else
        ln -s "$checkpoint_session/absent" "$protected_payload"
      fi
      ;;
  esac
  if ! run_test_case "Aged Restore Marked Payload Kept ($checkpoint_payload)" 1 "checkpoint_payload.log" --restore latest --only checkpoint_first \
     || [[ ! -e "$protected_payload" && ! -L "$protected_payload" ]] \
     || ! grep -q '^aged-restored|0_First|' "$checkpoint_session/quarantine.meta" \
     || ! grep -qx second "$checkpoint_session/1_Second/item"; then
    echo -e "${RED}FAIL: completed marker discarded remaining $checkpoint_payload payload.${NC}"
    exit 1
  fi
done

setup_restore_checkpoint none
rm "$checkpoint_session/0_First/item"
sed -i 's/^aged|0_First|/aged-restored|0_First|/' "$checkpoint_session/quarantine.meta"
if ! run_test_case "Aged Restore Marker Human Inventory" 0 "checkpoint_inventory.log" --list-sessions \
   || ! grep -q "aged  $checkpoint_first" "$TEST_ENV_DIR/checkpoint_inventory.log" \
   || grep -q aged-restored "$TEST_ENV_DIR/checkpoint_inventory.log" \
   || ! run_test_case "Aged Restore Marker JSON Inventory" 0 "checkpoint_inventory.json" --list-sessions --json \
   || ! python3 - "$TEST_ENV_DIR/checkpoint_inventory.json" "$checkpoint_first" <<'CHECKPOINT_JSON'
import json, sys
targets = json.load(open(sys.argv[1]))["sessions"][0]["targets"]
assert all(t["type"] in ("full", "aged") for t in targets), targets
assert any(t == {"type": "aged", "path": sys.argv[2]} for t in targets), targets
CHECKPOINT_JSON
then
  exit 1
fi
if ! run_test_case "Aged Restore Marker Selective" 0 "checkpoint_only.log" --restore latest --only checkpoint_first \
   || [[ -e "$checkpoint_session/0_First" || "$(wc -l < "$checkpoint_session/quarantine.meta")" -ne 2 ]] \
   || ! grep -qx second "$checkpoint_session/1_Second/item" || ! grep -qx sibling "$checkpoint_session/2_Sibling" \
   || ! run_test_case "Aged Restore Marker Selective Retry" 0 "checkpoint_only_retry.log" --restore latest \
   || [[ -e "$checkpoint_session" ]]; then
  exit 1
fi
# Exact selection shares aged checkpoint retirement and leaves siblings retryable.
for exact_layout in aged aged-restored; do
  setup_restore_checkpoint none
  if [[ "$exact_layout" == aged-restored ]]; then
    mv "$checkpoint_session/0_First/item" "$checkpoint_first/item"
    sed -i 's/^aged|0_First|/aged-restored|0_First|/' "$checkpoint_session/quarantine.meta"
  fi
  if ! run_test_case "Restore Exact Aged Selection ($exact_layout)" 0 "checkpoint_exact.log" \
       --restore latest --only-exact "$checkpoint_first" \
     || ! grep -qx first "$checkpoint_first/item" || [[ -e "$checkpoint_session/0_First" ]] \
     || [[ "$(wc -l < "$checkpoint_session/quarantine.meta")" -ne 2 ]] \
     || ! grep -qx second "$checkpoint_session/1_Second/item" || ! grep -qx sibling "$checkpoint_session/2_Sibling" \
     || ! run_test_case "Restore Exact Aged Followup ($exact_layout)" 0 "checkpoint_exact_retry.log" --restore latest \
     || [[ -e "$checkpoint_session" ]] || ! grep -qx second "$checkpoint_second/item" \
     || ! grep -qx sibling "$checkpoint_sibling"; then
    echo -e "${RED}FAIL: exact aged selection did not preserve pending sibling recovery.${NC}"
    exit 1
  fi
done
unset MOCK_RESTORE_SESSION MOCK_RESTORE_HOOK
echo -e "${GREEN}PASS: completed aged checkpoints survive interruptions and metadata failures without discarding pending payload.${NC}"

# A retried --restore after an interrupted restore treats a missing payload
# whose original path is already present as already restored, drops its stale
# record, restores remaining targets, and retires the session; a missing payload
# whose original path is also absent still fails and keeps the session.
setup_mock_env
q_retry_sess="$MOCK_HOME/.cache/linux-cleaner/quarantine/2026-03-03_00-00-00"
mkdir -p "$q_retry_sess/0_First_Target" "$q_retry_sess/1_Second_Target"
printf 'first-restored\n' > "$q_retry_sess/0_First_Target/a.txt"
printf 'second-pending\n' > "$q_retry_sess/1_Second_Target/b.txt"
printf 'full|0_First_Target|%s/.cache/retry_first|false|%s|%s\nfull|1_Second_Target|%s/.cache/retry_second|false|%s|%s\n' \
  "$MOCK_HOME" "$(id -u)" "$(id -g)" "$MOCK_HOME" "$(id -u)" "$(id -g)" > "$q_retry_sess/quarantine.meta"
# Simulate an interrupted restore: first target payload already moved back, record still in quarantine.meta.
mv "$q_retry_sess/0_First_Target" "$MOCK_HOME/.cache/retry_first"
retry_ops_log="$MOCK_HOME/.cache/linux-cleaner/operations.log"
rm -f "$retry_ops_log"

if ! run_test_case "Restore Retry After Interrupted Restore" 0 "restore_retry_interrupted.log" \
       --restore latest --log \
   || ! grep -qF "Note: '$MOCK_HOME/.cache/retry_first' is already restored; dropping its stale record." "$TEST_ENV_DIR/restore_retry_interrupted.log" \
   || ! grep -qx 'first-restored' "$MOCK_HOME/.cache/retry_first/a.txt" \
   || ! grep -qx 'second-pending' "$MOCK_HOME/.cache/retry_second/b.txt" \
   || [[ -d "$q_retry_sess" ]] \
   || ! grep -q "mode=restore session='2026-03-03_00-00-00' path='$MOCK_HOME/.cache/retry_first' outcome=success" "$retry_ops_log" \
   || ! grep -q "mode=restore session='2026-03-03_00-00-00' path='$MOCK_HOME/.cache/retry_second' outcome=success" "$retry_ops_log"; then
  echo -e "${RED}FAIL: retried restore after interruption did not complete or retire the session.${NC}"
  cat "$TEST_ENV_DIR/restore_retry_interrupted.log" "$retry_ops_log" 2>/dev/null || true
  exit 1
fi

setup_mock_env
q_missing_sess="$MOCK_HOME/.cache/linux-cleaner/quarantine/2026-03-04_00-00-00"
mkdir -p "$q_missing_sess/1_Present_Target"
printf 'present-payload\n' > "$q_missing_sess/1_Present_Target/b.txt"
printf 'full|0_Missing_Target|%s/.cache/truly_missing|false|%s|%s\nfull|1_Present_Target|%s/.cache/present_restored|false|%s|%s\n' \
  "$MOCK_HOME" "$(id -u)" "$(id -g)" "$MOCK_HOME" "$(id -u)" "$(id -g)" > "$q_missing_sess/quarantine.meta"
missing_ops_log="$MOCK_HOME/.cache/linux-cleaner/operations.log"
rm -f "$missing_ops_log"

if ! run_test_case "Restore Missing Source Still Fails" 1 "restore_missing_source.log" \
       --restore latest --log \
   || ! grep -qF "Warning: Quarantined source path '$q_missing_sess/0_Missing_Target' not found. Skipping." "$TEST_ENV_DIR/restore_missing_source.log" \
   || [[ -e "$MOCK_HOME/.cache/truly_missing" ]] \
   || ! grep -qx 'present-payload' "$MOCK_HOME/.cache/present_restored/b.txt" \
   || [[ ! -d "$q_missing_sess" ]] \
   || ! grep -qF "|$MOCK_HOME/.cache/truly_missing|" "$q_missing_sess/quarantine.meta" \
   || grep -qF "|$MOCK_HOME/.cache/present_restored|" "$q_missing_sess/quarantine.meta" \
   || ! grep -q "mode=restore session='2026-03-04_00-00-00' path='$MOCK_HOME/.cache/truly_missing' outcome=missing" "$missing_ops_log"; then
  echo -e "${RED}FAIL: missing quarantine payload with absent original path did not fail or keep its metadata record.${NC}"
  cat "$TEST_ENV_DIR/restore_missing_source.log" "$q_missing_sess/quarantine.meta" "$missing_ops_log" 2>/dev/null || true
  exit 1
fi
echo -e "${GREEN}PASS: retried restore after interruption completes and retires the session; truly missing source still fails.${NC}"

# An aged target's directory survives quarantine, so a missing aged payload is
# never mistaken for an already-restored one.
setup_mock_env
q_aged_missing_sess="$MOCK_HOME/.cache/linux-cleaner/quarantine/2026-03-05_00-00-00"
mkdir -p "$q_aged_missing_sess" "$MOCK_HOME/.cache/aged_kept_dir"
printf 'aged|0_Aged_Missing|%s/.cache/aged_kept_dir|false|%s|%s\n' \
  "$MOCK_HOME" "$(id -u)" "$(id -g)" > "$q_aged_missing_sess/quarantine.meta"
if ! run_test_case "Restore Missing Aged Source Still Fails" 1 "restore_missing_aged.log" --restore latest \
   || ! grep -qF "|$MOCK_HOME/.cache/aged_kept_dir|" "$q_aged_missing_sess/quarantine.meta"; then
  echo -e "${RED}FAIL: a missing aged payload was treated as already restored.${NC}"
  cat "$TEST_ENV_DIR/restore_missing_aged.log" 2>/dev/null || true
  exit 1
fi

# Cross-filesystem quarantine checks available space on the quarantine base
# before moving: refuses a target larger than free space (leaving it in place
# with no session record and exiting 1), while a fitting cross-filesystem target
# quarantines normally.
setup_mock_env
xfs_target="$OUTSIDE_DIR/xfs_build"
mkdir -p "$xfs_target"
printf 'cross-fs-payload\n' > "$xfs_target/artifact.bin"
xfs_qbase="$MOCK_HOME/.cache/linux-cleaner/quarantine"
cat > "$TEST_ENV_DIR/xfs_trash.conf" <<EOF
safe|XFS Build|$xfs_target|Cross-filesystem build target|0||
EOF

cat > "$TEST_ENV_DIR/bin/stat" <<'MOCK_XFS_STAT'
#!/usr/bin/env bash
real_stat=$(PATH="${PATH#"$TEST_ENV_DIR/bin:"}" command -v stat)
if [[ "${1:-}" == "-c" && "${2:-}" == "%d" ]]; then
  case "${3:-}" in
    *xfs_build*)
      echo 999991
      exit 0
      ;;
    */.cache/linux-cleaner/quarantine*)
      echo 999992
      exit 0
      ;;
  esac
fi
exec "$real_stat" "$@"
MOCK_XFS_STAT
chmod +x "$TEST_ENV_DIR/bin/stat"

cat > "$TEST_ENV_DIR/bin/df" <<'MOCK_XFS_DF_LOW'
#!/usr/bin/env bash
real_df=$(PATH="${PATH#"$TEST_ENV_DIR/bin:"}" command -v df)
for arg in "$@"; do
  case "$arg" in
    */.cache/linux-cleaner/quarantine*)
      # Reject flags the real df would reject, so the mock cannot hide them.
      "$real_df" "$@" > /dev/null 2>&1 || exit 1
      printf 'Avail\n1\n'
      exit 0
      ;;
  esac
done
exec "$real_df" "$@"
MOCK_XFS_DF_LOW
chmod +x "$TEST_ENV_DIR/bin/df"

if ! run_test_case "Trash Cross Filesystem Space Guard" 1 "xfs_trash_low.log" \
       --config "$TEST_ENV_DIR/xfs_trash.conf" --clean --trash --force \
   || ! grep -q "Error: Not enough free space to quarantine 'XFS Build' (needs .*, 1 B free); left in place\." "$TEST_ENV_DIR/xfs_trash_low.log" \
   || ! grep -q '^Result: cleaned=0 skipped=0 failed=1 ' "$TEST_ENV_DIR/xfs_trash_low.log" \
   || ! grep -qx 'Failed targets: XFS Build' "$TEST_ENV_DIR/xfs_trash_low.log" \
   || ! grep -qx 'cross-fs-payload' "$xfs_target/artifact.bin" \
   || [[ -n "$(find "$xfs_qbase" -mindepth 1 -maxdepth 1 -type d -print -quit 2>/dev/null)" ]] \
   || [[ -n "$(find "$xfs_qbase" -name quarantine.meta -print -quit 2>/dev/null)" ]]; then
  rm -f "$TEST_ENV_DIR/bin/stat" "$TEST_ENV_DIR/bin/df"
  echo -e "${RED}FAIL: cross-filesystem quarantine with 1 B free did not fail cleanly or modified the target/session.${NC}"
  cat "$TEST_ENV_DIR/xfs_trash_low.log" 2>/dev/null || true
  exit 1
fi

cat > "$TEST_ENV_DIR/bin/df" <<'MOCK_XFS_DF_PLENTY'
#!/usr/bin/env bash
real_df=$(PATH="${PATH#"$TEST_ENV_DIR/bin:"}" command -v df)
for arg in "$@"; do
  case "$arg" in
    */.cache/linux-cleaner/quarantine*)
      # Reject flags the real df would reject, so the mock cannot hide them.
      "$real_df" "$@" > /dev/null 2>&1 || exit 1
      printf 'Avail\n1073741824\n'
      exit 0
      ;;
  esac
done
exec "$real_df" "$@"
MOCK_XFS_DF_PLENTY
chmod +x "$TEST_ENV_DIR/bin/df"

if ! run_test_case "Trash Cross Filesystem Space Guard Fits" 0 "xfs_trash_fits.log" \
       --config "$TEST_ENV_DIR/xfs_trash.conf" --clean --trash --force \
   || [[ -e "$xfs_target" ]] \
   || ! grep -q '^Result: cleaned=1 skipped=0 failed=0 ' "$TEST_ENV_DIR/xfs_trash_fits.log" \
   || [[ -z "$(find "$xfs_qbase" -name quarantine.meta -print -quit 2>/dev/null)" ]]; then
  rm -f "$TEST_ENV_DIR/bin/stat" "$TEST_ENV_DIR/bin/df"
  echo -e "${RED}FAIL: cross-filesystem quarantine that fits did not succeed.${NC}"
  cat "$TEST_ENV_DIR/xfs_trash_fits.log" 2>/dev/null || true
  exit 1
fi
rm -f "$TEST_ENV_DIR/bin/stat" "$TEST_ENV_DIR/bin/df"
echo -e "${GREEN}PASS: cross-filesystem quarantine refuses targets larger than free space and allows fitting ones.${NC}"

# Restore checks the full payload or the entire aged staging directory before
# moving anything, preserving the record for a retry when space is insufficient.
for xfs_restore_type in Full Aged; do
  setup_mock_env
  xfs_restore_target="$OUTSIDE_DIR/xfs_restore/${xfs_restore_type,,}"
  xfs_restore_session="$MOCK_HOME/.cache/linux-cleaner/quarantine/2026-03-06_00-00-00"
  xfs_restore_src="$xfs_restore_session/0_XFS_Restore"
  mkdir -p "$xfs_restore_src/nested"
  printf 'cross-fs-restore\n' > "$xfs_restore_src/artifact.bin"
  printf 'nested-restore\n' > "$xfs_restore_src/nested/old.bin"
  if [[ "$xfs_restore_type" == Aged ]]; then
    mkdir -p "$xfs_restore_target"
    printf 'retained-file\n' > "$xfs_restore_target/recent.bin"
  fi
  printf '%s|0_XFS_Restore|%s|false|%s|%s\n' \
    "${xfs_restore_type,,}" "$xfs_restore_target" "$(id -u)" "$(id -g)" > "$xfs_restore_session/quarantine.meta"
  xfs_restore_meta=$(cat "$xfs_restore_session/quarantine.meta")

  cat > "$TEST_ENV_DIR/bin/stat" <<'MOCK_XFS_RESTORE_STAT'
#!/usr/bin/env bash
real_stat=$(PATH="${PATH#"$TEST_ENV_DIR/bin:"}" command -v stat)
if [[ "${1:-}" == "-c" && "${2:-}" == "%d" ]]; then
  case "${3:-}" in
    */.cache/linux-cleaner/quarantine/*)
      echo 999991
      exit 0
      ;;
    */outside_dir/xfs_restore*)
      echo 999992
      exit 0
      ;;
  esac
fi
exec "$real_stat" "$@"
MOCK_XFS_RESTORE_STAT
  cat > "$TEST_ENV_DIR/bin/df" <<'MOCK_XFS_RESTORE_DF'
#!/usr/bin/env bash
real_df=$(PATH="${PATH#"$TEST_ENV_DIR/bin:"}" command -v df)
for arg in "$@"; do
  case "$arg" in
    */outside_dir/xfs_restore*)
      "$real_df" "$@" > /dev/null 2>&1 || exit 1
      printf 'Avail\n%s\n' "${MOCK_RESTORE_AVAIL:-1}"
      exit 0
      ;;
  esac
done
exec "$real_df" "$@"
MOCK_XFS_RESTORE_DF
  chmod +x "$TEST_ENV_DIR/bin/stat" "$TEST_ENV_DIR/bin/df"

  if ! run_test_case "Restore $xfs_restore_type Cross Filesystem Space Guard" 1 "xfs_restore_low.log" --restore latest \
     || ! grep -q "Error: Not enough free space to restore '$xfs_restore_target' (needs .*, 1 B free); kept in quarantine\." "$TEST_ENV_DIR/xfs_restore_low.log" \
     || ! grep -qx 'cross-fs-restore' "$xfs_restore_src/artifact.bin" \
     || ! grep -qx 'nested-restore' "$xfs_restore_src/nested/old.bin" \
     || [[ "$(cat "$xfs_restore_session/quarantine.meta")" != "$xfs_restore_meta" ]] \
     || [[ -e "$xfs_restore_target/artifact.bin" || -e "$xfs_restore_target/nested/old.bin" ]]; then
    echo -e "${RED}FAIL: $xfs_restore_type cross-filesystem restore with 1 B free modified the payload or record.${NC}"
    cat "$TEST_ENV_DIR/xfs_restore_low.log" 2>/dev/null || true
    exit 1
  fi

  if ! MOCK_RESTORE_AVAIL=1073741824 \
       run_test_case "Restore $xfs_restore_type Cross Filesystem Space Guard Fits" 0 "xfs_restore_fits.log" --restore latest \
     || ! grep -qx 'cross-fs-restore' "$xfs_restore_target/artifact.bin" \
     || ! grep -qx 'nested-restore' "$xfs_restore_target/nested/old.bin" \
     || [[ -d "$xfs_restore_session" ]]; then
    echo -e "${RED}FAIL: $xfs_restore_type cross-filesystem restore that fits did not succeed.${NC}"
    cat "$TEST_ENV_DIR/xfs_restore_fits.log" 2>/dev/null || true
    exit 1
  fi
  if [[ "$xfs_restore_type" == Aged ]] && ! grep -qx 'retained-file' "$xfs_restore_target/recent.bin"; then
    echo -e "${RED}FAIL: aged cross-filesystem restore modified a retained destination file.${NC}"
    exit 1
  fi
  rm -f "$TEST_ENV_DIR/bin/stat" "$TEST_ENV_DIR/bin/df"
  echo -e "${GREEN}PASS: $xfs_restore_type cross-filesystem restore keeps oversized payloads and records, then restores when space permits.${NC}"
done

# --trash-keep-days / LINUX_CLEANER_TRASH_KEEP_DAYS: purge quarantine sessions
# older than DAYS at the end of a non-dry-run cleanup, never the newly created
# session, and never in dry-run mode.
setup_mock_env
tkd_qbase="$MOCK_HOME/.cache/linux-cleaner/quarantine"
tkd_old_sess="$tkd_qbase/2020-01-01_00-00-00"
mkdir -p "$tkd_old_sess/0_Old_Target"
printf 'old-quarantined\n' > "$tkd_old_sess/0_Old_Target/old.txt"
printf 'full|0_Old_Target|%s/.cache/old_target|false|%s|%s\n' \
  "$MOCK_HOME" "$(id -u)" "$(id -g)" > "$tkd_old_sess/quarantine.meta"
touch -d "10 days ago" "$tkd_old_sess"

# Dry-run purges nothing even when --trash-keep-days is passed.
if ! run_test_case "Trash Keep Days Dry Run Purges Nothing" 0 "tkd_dry.log" \
       --config "$TEST_ENV_DIR/test_cleaner.conf" --dry-run --trash --trash-keep-days 7 \
   || [[ ! -d "$tkd_old_sess" ]]; then
  echo -e "${RED}FAIL: --dry-run with --trash-keep-days removed the old quarantine session.${NC}"
  cat "$TEST_ENV_DIR/tkd_dry.log" 2>/dev/null || true
  exit 1
fi

if ! run_test_case "Trash Keep Days Purges Old Sessions" 0 "tkd_purge.log" \
       --config "$TEST_ENV_DIR/test_cleaner.conf" --clean --trash --force --trash-keep-days 7 \
   || [[ -d "$tkd_old_sess" ]] \
   || [[ "$(find "$tkd_qbase" -mindepth 1 -maxdepth 1 -type d | wc -l)" -ne 1 ]] \
   || ! grep -q "Purged 2020-01-01_00-00-00" "$TEST_ENV_DIR/tkd_purge.log"; then
  echo -e "${RED}FAIL: --trash-keep-days 7 did not purge the 10-day-old session or lost the newly created session.${NC}"
  cat "$TEST_ENV_DIR/tkd_purge.log" 2>/dev/null || true
  exit 1
fi
echo -e "${GREEN}PASS: --trash-keep-days 7 purged the old session and kept the newly created one.${NC}"

setup_mock_env
tkd_qbase="$MOCK_HOME/.cache/linux-cleaner/quarantine"
tkd_recent_sess="$tkd_qbase/2026-01-01_00-00-00"
mkdir -p "$tkd_recent_sess/0_Recent_Target"
printf 'recent-quarantined\n' > "$tkd_recent_sess/0_Recent_Target/recent.txt"
printf 'full|0_Recent_Target|%s/.cache/recent_target|false|%s|%s\n' \
  "$MOCK_HOME" "$(id -u)" "$(id -g)" > "$tkd_recent_sess/quarantine.meta"
touch -d "2 days ago" "$tkd_recent_sess"

if ! LINUX_CLEANER_TRASH_KEEP_DAYS=1 LINUX_CLEANER_TRASH=1 \
     run_test_case "Trash Keep Days Keeps Recent Sessions" 0 "tkd_recent.log" \
       --config "$TEST_ENV_DIR/test_cleaner.conf" --clean --force --trash-keep-days 7 \
   || [[ ! -d "$tkd_recent_sess" ]] \
   || [[ "$(find "$tkd_qbase" -mindepth 1 -maxdepth 1 -type d | wc -l)" -ne 2 ]] \
   || ! grep -q "No quarantine sessions older than 7 day(s)." "$TEST_ENV_DIR/tkd_recent.log"; then
  echo -e "${RED}FAIL: --trash-keep-days 7 (overriding LINUX_CLEANER_TRASH_KEEP_DAYS=1) did not keep the 2-day-old session and the new session.${NC}"
  cat "$TEST_ENV_DIR/tkd_recent.log" 2>/dev/null || true
  exit 1
fi
echo -e "${GREEN}PASS: --trash-keep-days keeps recent sessions and overrides LINUX_CLEANER_TRASH_KEEP_DAYS.${NC}"

if ! run_test_case "Trash Keep Days Rejected With Restore" 1 "tkd_norestore.log" \
       --trash-keep-days 7 --restore latest \
   || ! grep -q "trash-keep-days applies only to cleanup" "$TEST_ENV_DIR/tkd_norestore.log" \
   || ! run_test_case "Trash Keep Days Invalid Value Rejected" 1 "tkd_invalid.log" \
       --config "$TEST_ENV_DIR/test_cleaner.conf" --trash-keep-days -5 --dry-run \
   || ! grep -q -- "--trash-keep-days expects a non-negative integer" "$TEST_ENV_DIR/tkd_invalid.log"; then
  echo -e "${RED}FAIL: --trash-keep-days validation or mutual exclusion with --restore did not behave as expected.${NC}"
  cat "$TEST_ENV_DIR/tkd_norestore.log" "$TEST_ENV_DIR/tkd_invalid.log" 2>/dev/null || true
  exit 1
fi
echo -e "${GREEN}PASS: --trash-keep-days rejects invalid day counts and non-cleanup modes.${NC}"

# A run with nothing to clean still retires old sessions, so a quiet day (or a
# --min-reclaim skip) cannot let quarantine grow.
setup_mock_env
tkd_idle_sess="$MOCK_HOME/.cache/linux-cleaner/quarantine/2020-02-02_00-00-00"
mkdir -p "$tkd_idle_sess"
touch -d "10 days ago" "$tkd_idle_sess"
cat > "$TEST_ENV_DIR/tkd_idle.conf" <<'EOF'
safe|Absent Target|$HOME/.cache/tkd_absent|Never exists|0||
EOF
if ! run_test_case "Trash Keep Days Nothing To Clean" 0 "tkd_idle.log" \
       --config "$TEST_ENV_DIR/tkd_idle.conf" --clean --trash --force --trash-keep-days 7 \
   || ! grep -q "Everything is already clean" "$TEST_ENV_DIR/tkd_idle.log" \
   || [[ -d "$tkd_idle_sess" ]]; then
  echo -e "${RED}FAIL: a cleanup with nothing to clean did not apply --trash-keep-days.${NC}"
  cat "$TEST_ENV_DIR/tkd_idle.log" 2>/dev/null || true
  exit 1
fi
echo -e "${GREEN}PASS: --trash-keep-days also runs when there is nothing to clean.${NC}"

# --hold-session / --release-session: a held session survives every purge selector and
# inline retention (even with --force), keeps its original mtime, and still retires
# through a complete restore.
echo -e "\n${BOLD}Test Case: Session Hold${NC}"
setup_mock_env
hold_qbase="$MOCK_HOME/.cache/linux-cleaner/quarantine"
hold_a="$hold_qbase/2020-01-01_00-00-00"
hold_make_session() {
  local sess="$hold_qbase/$1"
  mkdir -p "$sess"
  printf 'payload\n' > "$sess/0_payload"
  printf 'full|0_payload|%s/.cache/hold_dest_%s|false|%s|%s\n' \
    "$MOCK_HOME" "$1" "$(id -u)" "$(id -g)" > "$sess/quarantine.meta"
  touch -d '40 days ago' "$sess"
}
hold_fail() {
  echo -e "${RED}FAIL: $1${NC}"
  shift
  cat "$@" 2>/dev/null || true
  exit 1
}
hold_make_session 2020-01-01_00-00-00
hold_make_session 2020-01-02_00-00-00
hold_make_session 2020-01-03_00-00-00
hold_mtime=$(stat -c %Y "$hold_a")
if ! run_test_case "Hold Session" 0 "hold_set.log" --hold-session 2020-01-01_00-00-00 \
   || ! grep -qF "Held session 2020-01-01_00-00-00" "$TEST_ENV_DIR/hold_set.log" \
   || [[ ! -f "$hold_a/.hold" || -L "$hold_a/.hold" ]] \
   || [[ "$(stat -c %a "$hold_a/.hold")" != 600 ]] \
   || [[ "$(stat -c %Y "$hold_a")" != "$hold_mtime" ]]; then
  hold_fail "--hold-session did not create a private marker without changing the session mtime." "$TEST_ENV_DIR/hold_set.log"
fi
if ! run_test_case "Hold Session Again" 0 "hold_again.log" --hold-session 2020-01-01_00-00-00 \
   || ! grep -qF "Session 2020-01-01_00-00-00 is already held." "$TEST_ENV_DIR/hold_again.log"; then
  hold_fail "a repeated --hold-session did not report the existing hold." "$TEST_ENV_DIR/hold_again.log"
fi
echo -e "${GREEN}PASS: --hold-session writes a private marker and keeps the session mtime.${NC}"

if ! run_test_case "Hold Listed" 0 "hold_list.log" --list-sessions \
   || ! grep -qE '^  2020-01-01_00-00-00  size=.*  held$' "$TEST_ENV_DIR/hold_list.log" \
   || grep -qE '^  2020-01-02_00-00-00  .*held' "$TEST_ENV_DIR/hold_list.log" \
   || grep -q 'Unrecorded entries' "$TEST_ENV_DIR/hold_list.log" \
   || ! run_test_case "Hold Listed JSON" 0 "hold_list.json" --list-sessions --json \
   || ! python3 - "$TEST_ENV_DIR/hold_list.json" <<'HOLD_JSON'
import json, sys
sessions = {s["timestamp"]: s for s in json.load(open(sys.argv[1]))["sessions"]}
assert sessions["2020-01-01_00-00-00"]["held"] is True, sessions
assert sessions["2020-01-02_00-00-00"]["held"] is False, sessions
assert all(s["unrecorded_entry_count"] == 0 for s in sessions.values()), sessions
HOLD_JSON
then
  hold_fail "--list-sessions did not show the hold or counted the marker as unrecorded." "$TEST_ENV_DIR/hold_list.log" "$TEST_ENV_DIR/hold_list.json"
fi
echo -e "${GREEN}PASS: --list-sessions shows the hold in text and JSON without an unrecorded entry.${NC}"

for hold_selector in all older-than:30 max-size:1 keep-latest:1; do
  hold_make_session 2020-01-02_00-00-00
  hold_make_session 2020-01-03_00-00-00
  hold_log="hold_purge_${hold_selector%%:*}.log"
  if ! run_test_case "Held Session Survives Purge ${hold_selector}" 0 "$hold_log" \
         --purge-sessions "$hold_selector" --force \
     || [[ ! -f "$hold_a/0_payload" || ! -f "$hold_a/.hold" ]] \
     || [[ -d "$hold_qbase/2020-01-02_00-00-00" ]] \
     || ! grep -qF "Skipping held session 2020-01-01_00-00-00" "$TEST_ENV_DIR/$hold_log" \
     || grep -qF "Purged 2020-01-01_00-00-00" "$TEST_ENV_DIR/$hold_log"; then
    hold_fail "--purge-sessions $hold_selector --force deleted the held session or purged nothing else." "$TEST_ENV_DIR/$hold_log"
  fi
done
echo -e "${GREEN}PASS: every bulk purge selector skips a held session even with --force.${NC}"

if ! run_test_case "Held Named Purge Refused" 1 "hold_purge_named.log" \
       --purge-sessions 2020-01-01_00-00-00 --force \
   || ! grep -qF "Quarantine session '2020-01-01_00-00-00' is held" "$TEST_ENV_DIR/hold_purge_named.log" \
   || [[ ! -f "$hold_a/0_payload" ]]; then
  hold_fail "a named purge of a held session was not refused." "$TEST_ENV_DIR/hold_purge_named.log"
fi
hold_make_session 2020-01-02_00-00-00
hold_make_session 2020-01-03_00-00-00
if ! run_test_case "Hold Latest" 0 "hold_latest.log" --hold-session latest \
   || [[ ! -f "$hold_qbase/2020-01-03_00-00-00/.hold" ]] \
   || ! run_test_case "Held Latest Purge Refused" 1 "hold_purge_latest.log" --purge-sessions latest --force \
   || ! grep -qF "Quarantine session '2020-01-03_00-00-00' is held" "$TEST_ENV_DIR/hold_purge_latest.log" \
   || [[ ! -d "$hold_qbase/2020-01-02_00-00-00" || ! -d "$hold_qbase/2020-01-03_00-00-00" ]] \
   || ! run_test_case "Release Latest" 0 "hold_release_latest.log" --release-session latest \
   || [[ -e "$hold_qbase/2020-01-03_00-00-00/.hold" ]]; then
  hold_fail "a latest purge of a held session was not refused, or picked another session." \
    "$TEST_ENV_DIR/hold_latest.log" "$TEST_ENV_DIR/hold_purge_latest.log" "$TEST_ENV_DIR/hold_release_latest.log"
fi
echo -e "${GREEN}PASS: named and latest purges of a held session are refused without touching other sessions.${NC}"

# Inline retention skips the hold and still retires the unheld aged sessions.
if ! run_test_case "Held Session Survives Inline Retention" 0 "hold_inline.log" \
       --config "$TEST_ENV_DIR/test_cleaner.conf" --clean --trash --force --trash-keep-days 7 \
   || [[ ! -f "$hold_a/0_payload" ]] \
   || [[ -d "$hold_qbase/2020-01-02_00-00-00" ]] \
   || ! grep -qF "Skipping held session 2020-01-01_00-00-00" "$TEST_ENV_DIR/hold_inline.log"; then
  hold_fail "--trash-keep-days retention deleted the held session or skipped unheld ones." "$TEST_ENV_DIR/hold_inline.log"
fi
echo -e "${GREEN}PASS: --trash-keep-days retention skips a held session.${NC}"

# Any entry named .hold counts as a hold: a hold only ever makes purge delete less.
hold_make_session 2020-01-04_00-00-00
mkdir "$hold_qbase/2020-01-04_00-00-00/.hold"
touch -d '40 days ago' "$hold_qbase/2020-01-04_00-00-00"
if ! run_test_case "Hold Directory Marker Fails Closed" 0 "hold_dir_marker.log" --purge-sessions older-than:30 --force \
   || [[ ! -f "$hold_qbase/2020-01-04_00-00-00/0_payload" ]] \
   || ! grep -qF "Skipping held session 2020-01-04_00-00-00" "$TEST_ENV_DIR/hold_dir_marker.log"; then
  hold_fail "a non-file .hold entry did not keep its session." "$TEST_ENV_DIR/hold_dir_marker.log"
fi
echo -e "${GREEN}PASS: a non-file .hold entry still protects its session.${NC}"

for hold_bad in ../x a/b . ..; do
  for hold_flag in --hold-session --release-session; do
    if ! run_test_case "Unsafe Hold Name ${hold_flag} ${hold_bad}" 1 "hold_bad.log" "$hold_flag" "$hold_bad" \
       || ! grep -qF "Invalid session name '$hold_bad'" "$TEST_ENV_DIR/hold_bad.log"; then
      hold_fail "$hold_flag '$hold_bad' was not refused as an invalid session name." "$TEST_ENV_DIR/hold_bad.log"
    fi
  done
done
echo -e "${GREEN}PASS: --hold-session and --release-session refuse unsafe session names.${NC}"

for hold_combo in "--hold-session latest --release-session latest" "--release-session latest --dry-run" \
  "--hold-session latest --json" "--hold-session latest --purge-sessions all --force" "--hold-session latest --restore latest" \
  "--hold-session latest --clean" "--release-session latest --interactive"; do
  # shellcheck disable=SC2086  # each combo is intentionally word-split into flags and values
  if ! run_test_case "Hold Combination ${hold_combo}" 1 "hold_combo.log" $hold_combo \
     || ! grep -qE -- '--(hold|release)-session cannot be combined with' "$TEST_ENV_DIR/hold_combo.log" \
     || [[ ! -f "$hold_a/.hold" || ! -f "$hold_a/0_payload" ]]; then
    hold_fail "'$hold_combo' was not refused before touching any session." "$TEST_ENV_DIR/hold_combo.log"
  fi
done
echo -e "${GREEN}PASS: hold modes refuse every other mode, --dry-run, and --json.${NC}"

if ! run_test_case "Release Session" 0 "hold_release.log" --release-session 2020-01-01_00-00-00 \
   || [[ -e "$hold_a/.hold" || -L "$hold_a/.hold" ]] \
   || [[ "$(stat -c %Y "$hold_a")" != "$hold_mtime" ]] \
   || ! run_test_case "Release Session Again" 0 "hold_release_again.log" --release-session 2020-01-01_00-00-00 \
   || ! grep -qF "Session 2020-01-01_00-00-00 is not held." "$TEST_ENV_DIR/hold_release_again.log" \
   || ! run_test_case "Released Session Expires" 0 "hold_release_purge.log" --purge-sessions older-than:30 --force \
   || [[ -d "$hold_a" ]]; then
  hold_fail "--release-session did not restore normal expiry with the original mtime." \
    "$TEST_ENV_DIR/hold_release.log" "$TEST_ENV_DIR/hold_release_again.log" "$TEST_ENV_DIR/hold_release_purge.log"
fi
echo -e "${GREEN}PASS: --release-session removes the hold and the session expires on its original age.${NC}"

setup_mock_env
hold_make_session 2020-01-05_00-00-00
if ! run_test_case "Hold Before Restore" 0 "hold_restore_set.log" --hold-session 2020-01-05_00-00-00 \
   || ! run_test_case "Complete Restore Of Held Session" 0 "hold_restore.log" --restore 2020-01-05_00-00-00 \
   || [[ -d "$hold_qbase/2020-01-05_00-00-00" ]] \
   || [[ "$(cat "$MOCK_HOME/.cache/hold_dest_2020-01-05_00-00-00" 2>/dev/null)" != payload ]]; then
  hold_fail "a complete restore of a held session did not retire it." "$TEST_ENV_DIR/hold_restore_set.log" "$TEST_ENV_DIR/hold_restore.log"
fi
echo -e "${GREEN}PASS: a complete restore removes the hold marker and retires the session.${NC}"
unset -f hold_make_session hold_fail

# --report --json: emit machine-readable JSON for the saved cleanup report
# (completed, nothing_to_clean, skipped_below_min_reclaim, and interrupted runs),
# or exit 1 when no report exists yet.
setup_mock_env
rjson_state_dir="$XDG_STATE_HOME/linux-cleaner"
rjson_report_file="$rjson_state_dir/last-report.txt"
rm -rf "$XDG_STATE_HOME"

if ! run_test_case "Report JSON Without Report" 1 "report_json_missing.log" \
       --report --json \
   || ! grep -qx 'No cleanup report yet.' "$TEST_ENV_DIR/report_json_missing.log"; then
  echo -e "${RED}FAIL: --report --json did not exit 1 with 'No cleanup report yet.' when no report exists.${NC}"
  cat "$TEST_ENV_DIR/report_json_missing.log" 2>/dev/null || true
  exit 1
fi

mkdir -p "$MOCK_HOME/.cache/rjson_target"
truncate -s 1537 "$MOCK_HOME/.cache/rjson_target/file.txt"
cat > "$TEST_ENV_DIR/rjson.conf" <<'EOF'
safe|Report JSON Target|$HOME/.cache/rjson_target/file.txt|Report JSON test target|0||
EOF

if ! run_test_case "Report JSON Seed Cleanup" 0 "report_json_seed.log" \
       --config "$TEST_ENV_DIR/rjson.conf" --clean --trash --force; then
  exit 1
fi

if ! run_test_case "Report JSON After Cleanup" 0 "report_json_clean.log" \
       --report --json \
   || ! python3 -m json.tool < "$TEST_ENV_DIR/report_json_clean.log" > "$TEST_ENV_DIR/report_json_clean_parsed.out" 2>"$TEST_ENV_DIR/report_json_clean.err" \
   || ! python3 - "$TEST_ENV_DIR/report_json_clean_parsed.out" <<'PY'
import json, re, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    d = json.load(fh)
assert re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$", d["saved"]), d
assert d["result"] == "completed", d
assert d["cleaned"] == 1 and isinstance(d["cleaned"], int), d
assert d["skipped"] == 0 and isinstance(d["skipped"], int), d
assert d["failed"] == 0 and isinstance(d["failed"], int), d
assert isinstance(d["elapsed_seconds"], int) and d["elapsed_seconds"] >= 0, d
assert d["failed_targets"] == [], d
assert isinstance(d["quarantine_session"], str) and "/quarantine/" in d["quarantine_session"], d
assert d["interrupted"] is None, d
assert d["retention_failed"] is None, d
assert (d["quarantined_bytes"], d["permanent_bytes"]) == (1537, 0), d
PY
then
  echo -e "${RED}FAIL: --report --json after cleanup did not emit valid expected JSON.${NC}"
  cat "$TEST_ENV_DIR/report_json_clean.log" "$TEST_ENV_DIR/report_json_clean.err" 2>/dev/null || true
  exit 1
fi

# Verify nothing_to_clean and skipped_below_min_reclaim result variants as well.
if ! run_test_case "Report JSON Seed Nothing To Clean" 0 "report_json_empty_seed.log" \
       --config "$TEST_ENV_DIR/rjson.conf" --clean --force \
   || ! "$CLEANER_SH" --report --json > "$TEST_ENV_DIR/report_json_empty.log" 2>&1 \
   || ! python3 -m json.tool < "$TEST_ENV_DIR/report_json_empty.log" > "$TEST_ENV_DIR/report_json_empty_parsed.out" \
   || ! python3 - "$TEST_ENV_DIR/report_json_empty_parsed.out" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    d = json.load(fh)
assert d["result"] == "nothing_to_clean", d
assert (d["quarantined_bytes"], d["permanent_bytes"]) == (0, 0), d
assert d["cleaned"] is None and d["skipped"] is None and d["failed"] is None and d["elapsed_seconds"] is None, d
assert d["failed_targets"] == [] and d["quarantine_session"] is None and d["interrupted"] is None, d
PY
then
  echo -e "${RED}FAIL: --report --json after nothing-to-clean run did not match schema.${NC}"
  cat "$TEST_ENV_DIR/report_json_empty.log" 2>/dev/null || true
  exit 1
fi

mkdir -p "$MOCK_HOME/.cache/rjson_target"
printf 'tiny\n' > "$MOCK_HOME/.cache/rjson_target/file.txt"
if ! run_test_case "Report JSON Seed Min Reclaim" 0 "report_json_min_seed.log" \
       --config "$TEST_ENV_DIR/rjson.conf" --clean --force --min-reclaim 10M \
   || ! "$CLEANER_SH" --report --json > "$TEST_ENV_DIR/report_json_min.log" 2>&1 \
   || ! python3 -m json.tool < "$TEST_ENV_DIR/report_json_min.log" > "$TEST_ENV_DIR/report_json_min_parsed.out" \
   || ! python3 - "$TEST_ENV_DIR/report_json_min_parsed.out" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    d = json.load(fh)
assert d["result"] == "skipped_below_min_reclaim", d
assert (d["quarantined_bytes"], d["permanent_bytes"]) == (0, 0), d
assert d["cleaned"] is None and d["skipped"] is None and d["failed"] is None and d["elapsed_seconds"] is None, d
assert d["failed_targets"] == [] and d["quarantine_session"] is None and d["interrupted"] is None, d
PY
then
  echo -e "${RED}FAIL: --report --json after --min-reclaim skip did not match schema.${NC}"
  cat "$TEST_ENV_DIR/report_json_min.log" 2>/dev/null || true
  exit 1
fi

# Exact permanent bytes survive human rounding; declining another run preserves them.
truncate -s 1537 "$MOCK_HOME/.cache/rjson_target/file.txt"
if ! run_test_case "Report JSON Seed Permanent Bytes" 0 "report_permanent_seed.log" \
       --config "$TEST_ENV_DIR/rjson.conf" --clean --force \
   || ! run_test_case "Report JSON Permanent Bytes" 0 "report_permanent.json" --report --json \
   || ! python3 - "$TEST_ENV_DIR/report_permanent.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert (d["quarantined_bytes"], d["permanent_bytes"]) == (0, 1537), d
PY
then
  echo -e "${RED}FAIL: saved report rounded permanent byte accounting.${NC}"
  exit 1
fi
cp "$rjson_report_file" "$TEST_ENV_DIR/report_before_cancel.txt"
truncate -s 1537 "$MOCK_HOME/.cache/rjson_target/file.txt"
if ! run_test_case "Report Cancel Preserves Bytes" 0 "report_cancel.log" \
       --config "$TEST_ENV_DIR/rjson.conf" --clean \
   || ! grep -q 'Cleanup aborted' "$TEST_ENV_DIR/report_cancel.log" \
   || ! cmp -s "$rjson_report_file" "$TEST_ENV_DIR/report_before_cancel.txt" \
   || [[ ! -f "$MOCK_HOME/.cache/rjson_target/file.txt" ]]; then
  echo -e "${RED}FAIL: cancelled cleanup replaced the previous byte report.${NC}"
  exit 1
fi

for byte_case in incomplete negative leading-zero decimal trailing-text; do
  case "$byte_case" in
    incomplete) byte_record='Accounted bytes: quarantined=0' ;;
    negative) byte_record='Accounted bytes: quarantined=0 permanent=-1' ;;
    leading-zero) byte_record='Accounted bytes: quarantined=01 permanent=2' ;;
    decimal) byte_record='Accounted bytes: quarantined=0 permanent=1.5' ;;
    trailing-text) byte_record='Accounted bytes: quarantined=0 permanent=1 extra' ;;
  esac
  printf 'Saved: 2026-10-17T12:34:56\nResult: nothing to clean\nReclaimed: quarantined=0 B permanent=0 B\n%s\n' \
    "$byte_record" > "$rjson_report_file"
  if ! run_test_case "Report JSON Malformed Bytes ($byte_case)" 0 "report_malformed.json" --report --json \
     || ! python3 - "$TEST_ENV_DIR/report_malformed.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["quarantined_bytes"] is None and d["permanent_bytes"] is None, d
PY
  then
    echo -e "${RED}FAIL: malformed byte record became a numeric report ($byte_case).${NC}"
    exit 1
  fi
done

# Historical interrupted report: rounded text must not become exact byte counts.
cat > "$rjson_report_file" <<'EOF'
Saved: 2026-10-17T12:34:56
Plan: mode=clean risk=safe config=/tmp/rjson.conf
Targets: found=3 clean/missing=0 skipped=1 blocked=0 protected=0 unsafe/symlink=0 root=0
Reclaimable by risk: safe=12.00 KB medium=0 B danger=0 B

Result: cleaned=1 skipped=1 failed=2 elapsed=4s
Failed targets: Alpha Cache, Beta Build
Reclaimed: quarantined=0 B permanent=4.00 KB
Interrupted: SIGTERM before all targets finished
EOF

if ! run_test_case "Report JSON After Interrupted Cleanup" 0 "report_json_interrupted.log" \
       --report --json \
   || ! python3 -m json.tool < "$TEST_ENV_DIR/report_json_interrupted.log" > "$TEST_ENV_DIR/report_json_interrupted_parsed.out" 2>"$TEST_ENV_DIR/report_json_interrupted.err" \
   || ! python3 - "$TEST_ENV_DIR/report_json_interrupted_parsed.out" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    d = json.load(fh)
assert d == {
    "saved": "2026-10-17T12:34:56",
    "result": "completed",
    "cleaned": 1,
    "skipped": 1,
    "failed": 2,
    "elapsed_seconds": 4,
    "failed_targets": ["Alpha Cache", "Beta Build"],
    "quarantine_session": None,
    "interrupted": "SIGTERM",
    "retention_failed": None,
    "quarantined_bytes": None,
    "permanent_bytes": None,
}, d
PY
then
  echo -e "${RED}FAIL: --report --json after interrupted cleanup did not emit expected JSON.${NC}"
  cat "$TEST_ENV_DIR/report_json_interrupted.log" "$TEST_ENV_DIR/report_json_interrupted.err" 2>/dev/null || true
  exit 1
fi
echo -e "${GREEN}PASS: --report --json emits valid JSON matching the saved report and exits 1 when absent.${NC}"

# Exact failure records preserve NAME boundaries and bytes across shared save paths.
for failed_names_case in completed retention interrupted; do
  setup_mock_env
  export MOCK_FAILED_NAMES_HOME="$MOCK_HOME"
  python3 - "$TEST_ENV_DIR" "$MOCK_HOME" "$failed_names_case" <<'FAILED_NAMES_CONFIG'
import json, pathlib, sys
root, home = map(pathlib.Path, sys.argv[1:3])
names = ['Comma, Cache', 'Ordinary "quoted" \\name\tinside\b\f\v\x01\r\x1b[31mred\x1b[0m end']
rows = []
payloads = {}
for name, leaf, action in [(names[0], "action", "action:uv_cache_prune"),
                           (names[1], "ordinary", ""),
                           ("Signal Target", "signal", "")][:3 if sys.argv[3] == "interrupted" else 2]:
    target = home / ".cache/exact-failures" / leaf
    target.mkdir(parents=True)
    payload = target / "payload"
    payload.write_text(leaf + " payload\n")
    payloads[str(payload)] = payload.read_text()
    rows.append(f"safe|{name}|{target}|Exact failed name fixture|0||{action}\n")
session = home / ".cache/linux-cleaner/quarantine/2099-01-01_00-00-00"
session.mkdir(parents=True)
for leaf in ("payload", "quarantine.meta"):
    path = session / leaf
    path.write_text("keep recovery data\n")
    payloads[str(path)] = path.read_text()
(root / "failed_names.conf").write_text("".join(rows))
(root / "failed_names_expected.json").write_text(json.dumps(dict(names=names, payloads=payloads)))
FAILED_NAMES_CONFIG
  cat > "$TEST_ENV_DIR/bin/uv" <<'FAILED_NAMES_UV'
#!/usr/bin/env bash
exit 73
FAILED_NAMES_UV
  cat > "$TEST_ENV_DIR/bin/rm" <<'FAILED_NAMES_RM'
#!/usr/bin/env bash
for arg; do
  if [[ "$arg" == "$MOCK_FAILED_NAMES_HOME/.cache/exact-failures/ordinary" ]]; then
    exit 73
  elif [[ "$arg" == "$MOCK_FAILED_NAMES_HOME/.cache/exact-failures/signal" ]]; then
    kill -TERM "$PPID"
    exit 73
  fi
done
real_rm=$(PATH="${PATH#"$TEST_ENV_DIR/bin:"}" command -v rm)
exec "$real_rm" "$@"
FAILED_NAMES_RM
  chmod +x "$TEST_ENV_DIR/bin/uv" "$TEST_ENV_DIR/bin/rm"
  failed_names_args=()
  failed_names_exit=1
  [[ "$failed_names_case" == retention ]] && failed_names_args+=(--trash-keep-days 7)
  [[ "$failed_names_case" == interrupted ]] && failed_names_exit=143
  if ! run_test_case "Report Exact Failed Names ($failed_names_case)" "$failed_names_exit" "failed_names_run.log" \
       --config "$TEST_ENV_DIR/failed_names.conf" --clean --force "${failed_names_args[@]}" \
     || ! run_test_case "Report JSON Exact Failed Names ($failed_names_case)" 0 "failed_names_report.json" --report --json \
     || ! python3 - "$TEST_ENV_DIR" "$XDG_STATE_HOME" "$failed_names_case" <<'FAILED_NAMES_JSON'
import json, pathlib, sys
root, state = map(pathlib.Path, sys.argv[1:3])
expected = json.loads((root / "failed_names_expected.json").read_text())
report = json.loads((root / "failed_names_report.json").read_text())
assert report["failed_targets"] == expected["names"], report
assert report["failed"] == len(expected["names"]) == 2 and report["cleaned"] == 0, report
assert report["interrupted"] == ("SIGTERM" if sys.argv[3] == "interrupted" else None), report
assert report["retention_failed"] is (False if sys.argv[3] == "retention" else None), report
assert (report["quarantined_bytes"], report["permanent_bytes"]) == (0, 0), report
saved = (state / "linux-cleaner/last-report.txt").read_bytes()
records = [line[len(b"Failed target: "):] for line in saved.split(b"\n") if line.startswith(b"Failed target: ")]
assert records == [name.encode() for name in expected["names"]], records
stdout = (root / "failed_names_run.log").read_bytes()
assert b"\nFailed targets: " in stdout and b"\nFailed target: " not in stdout, stdout
for path, contents in expected["payloads"].items():
    assert pathlib.Path(path).read_text() == contents, path
FAILED_NAMES_JSON
  then
    echo -e "${RED}FAIL: exact failed NAMEs, counts, or payload changed ($failed_names_case).${NC}"
    exit 1
  fi
done
unset MOCK_FAILED_NAMES_HOME
echo -e "${GREEN}PASS: exact failed NAMEs survive completion, retention rewrites, and interrupted saves.${NC}"

# Inline retention outcomes are saved independently of cleanup-target failures.
setup_retention_report() {
  setup_mock_env
  retention_old="$MOCK_HOME/.cache/linux-cleaner/quarantine/2020-01-01_00-00-00"
  retention_target="$MOCK_HOME/.cache/retention_target"
  mkdir -p "$retention_old" "$retention_target"
  printf 'old payload\n' > "$retention_old/payload"
  printf 'full|payload|%s/prior|false|%s|%s\n' "$MOCK_HOME" "$(id -u)" "$(id -g)" > "$retention_old/quarantine.meta"
  touch -d '10 days ago' "$retention_old"
  printf 'target payload\n' > "$retention_target/file"
  printf 'safe|Retention Target|%s|retention report fixture|0||\n' "$retention_target" > "$TEST_ENV_DIR/retention_report.conf"
  export MOCK_RETENTION_MODE="$1" MOCK_RETENTION_OLD="$retention_old" MOCK_RETENTION_TARGET="$retention_target"
  cat > "$TEST_ENV_DIR/bin/rm" <<'RETENTION_RM'
#!/usr/bin/env bash
for arg; do
  case "$MOCK_RETENTION_MODE" in
    completed|nothing|min-reclaim|min-free|standalone)
      [[ "$arg" == "$MOCK_RETENTION_OLD" ]] && exit 1 ;;
    target-failed)
      [[ "$arg" == "$MOCK_RETENTION_TARGET" ]] && exit 1 ;;
    interrupted)
      if [[ "$arg" == "$MOCK_RETENTION_OLD" ]]; then kill -TERM "$PPID"; exit 1; fi ;;
  esac
done
real_rm=$(PATH="${PATH#"$TEST_ENV_DIR/bin:"}" command -v rm)
exec "$real_rm" "$@"
RETENTION_RM
  cat > "$TEST_ENV_DIR/bin/find" <<'RETENTION_FIND'
#!/usr/bin/env bash
if [[ "$MOCK_RETENTION_MODE" == enumeration && "${1:-}" == "${MOCK_RETENTION_OLD%/*}" ]]; then
  exit 1
fi
real_find=$(PATH="${PATH#"$TEST_ENV_DIR/bin:"}" command -v find)
exec "$real_find" "$@"
RETENTION_FIND
  chmod +x "$TEST_ENV_DIR/bin/rm" "$TEST_ENV_DIR/bin/find"
}

for retention_case in completed nothing min-reclaim enumeration target-failed cancelled; do
  setup_retention_report "$retention_case"
  retention_credited_bytes=$(du -sb "$retention_target" | cut -f1)
  case "$retention_case" in
    nothing|min-reclaim|target-failed|cancelled) retention_credited_bytes=0 ;;
  esac
  retention_args=(--force)
  retention_exit=1
  retention_failed=true
  case "$retention_case" in
    nothing|cancelled) rm -rf "$retention_target" ;;
    min-reclaim) retention_args+=(--min-reclaim 1G) ;;
  esac
  if [[ "$retention_case" == cancelled ]]; then
    retention_args=()
    retention_exit=0
  fi
  [[ "$retention_case" == target-failed || "$retention_case" == cancelled ]] && retention_failed=false
  if ! run_test_case "Retention Report ($retention_case)" "$retention_exit" "retention_run.log" \
       --config "$TEST_ENV_DIR/retention_report.conf" --clean --trash-keep-days 7 "${retention_args[@]}" \
     || ! grep -qx "Retention failed: $retention_failed" "$TEST_ENV_DIR/retention_run.log" \
     || ! grep -qx "Retention failed: $retention_failed" "$XDG_STATE_HOME/linux-cleaner/last-report.txt" \
     || ! run_test_case "Retention Report JSON ($retention_case)" 0 "retention_report.json" --report --json \
     || ! python3 - "$TEST_ENV_DIR/retention_report.json" "$retention_case" "$retention_credited_bytes" <<'RETENTION_JSON'
import json, sys
d = json.load(open(sys.argv[1]))
case = sys.argv[2]
assert (d["quarantined_bytes"], d["permanent_bytes"]) == (0, int(sys.argv[3])), d
assert d["retention_failed"] is (case not in ("target-failed", "cancelled")), d
expected = {"nothing": "nothing_to_clean", "cancelled": "nothing_to_clean", "min-reclaim": "skipped_below_min_reclaim"}.get(case, "completed")
assert d["result"] == expected, d
if expected == "completed":
    assert d["failed"] == (1 if case == "target-failed" else 0), d
    assert d["cleaned"] == (0 if case == "target-failed" else 1), d
else:
    assert d["failed"] is None and d["cleaned"] is None, d
assert d["failed_targets"] == (["Retention Target"] if case == "target-failed" else []), d
RETENTION_JSON
  then
    echo -e "${RED}FAIL: inline retention outcome was lost or changed target counts ($retention_case).${NC}"
    cat "$TEST_ENV_DIR/retention_run.log" "$TEST_ENV_DIR/retention_report.json" 2>/dev/null || true
    exit 1
  fi
  if [[ "$retention_case" == target-failed ]]; then
    [[ ! -e "$retention_old" && -f "$retention_target/file" ]] || exit 1
  else
    grep -qx 'old payload' "$retention_old/payload" || exit 1
  fi
done

setup_retention_report interrupted
retention_credited_bytes=$(du -sb "$retention_target" | cut -f1)
mkdir -p "$XDG_STATE_HOME/linux-cleaner"
printf 'Saved: 2000-01-01T00:00:00\nResult: nothing to clean\n' > "$XDG_STATE_HOME/linux-cleaner/last-report.txt"
if ! run_test_case "Retention Interrupted Keeps Current Report" 143 "retention_interrupted.log" \
       --config "$TEST_ENV_DIR/retention_report.conf" --clean --force --trash-keep-days 7 \
   || ! grep -Fxq 'Interrupted: SIGTERM during quarantine retention' "$XDG_STATE_HOME/linux-cleaner/last-report.txt" \
   || ! run_test_case "Retention Interrupted Report Health" 1 "retention_interrupted_health.log" --report --check-health 60 \
   || ! grep -Fq 'cleanup was interrupted' "$TEST_ENV_DIR/retention_interrupted_health.log" \
   || ! run_test_case "Retention Interrupted Report JSON" 0 "retention_interrupted.json" --report --json \
   || ! python3 - "$TEST_ENV_DIR/retention_interrupted.json" "$retention_credited_bytes" <<'RETENTION_INTERRUPTED'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["result"] == "completed" and d["cleaned"] == 1 and d["failed"] == 0, d
assert d["saved"] != "2000-01-01T00:00:00" and d["retention_failed"] is None, d
assert d["interrupted"] == "SIGTERM", d
assert (d["quarantined_bytes"], d["permanent_bytes"]) == (0, int(sys.argv[2])), d
RETENTION_INTERRUPTED
then
  echo -e "${RED}FAIL: interruption during retention lost the current cleanup report.${NC}"
  exit 1
fi
grep -qx 'old payload' "$retention_old/payload" || exit 1

setup_retention_report interrupted
if ! run_test_case "Retention Interrupted Keeps Min-Reclaim Skip Report" 143 "retention_skip_interrupted.log" \
       --config "$TEST_ENV_DIR/retention_report.conf" --clean --force --min-reclaim 1G --trash-keep-days 7 \
   || ! grep -Fxq 'Result: skipped below --min-reclaim 1G' "$XDG_STATE_HOME/linux-cleaner/last-report.txt" \
   || ! grep -Fxq 'Interrupted: SIGTERM during quarantine retention' "$XDG_STATE_HOME/linux-cleaner/last-report.txt" \
   || ! run_test_case "Retention Interrupted Skip Report Health" 1 "retention_skip_interrupted_health.log" --report --check-health 60 \
   || ! grep -Fq 'cleanup was interrupted' "$TEST_ENV_DIR/retention_skip_interrupted_health.log" \
   || ! grep -qx 'old payload' "$retention_old/payload" \
   || ! grep -qx 'target payload' "$retention_target/file"; then
  echo -e "${RED}FAIL: interruption during retention lost the skip report or changed payloads.${NC}"
  exit 1
fi
setup_mock_env

setup_retention_report standalone
if ! run_test_case "Retention Standalone Purge Failure" 1 "retention_standalone.log" --purge-sessions older-than:7 --force \
   || ! grep -qx 'old payload' "$retention_old/payload" \
   || [[ -e "$XDG_STATE_HOME/linux-cleaner/last-report.txt" ]]; then
  echo -e "${RED}FAIL: standalone purge failure lost payload, changed status, or wrote a cleanup report.${NC}"
  exit 1
fi
# Under systemd, failed retention purges name themselves at error priority.
# Previews and early purge exits name their exit status; cleanup reports name retention.
for retention_journal in standalone selector preview min-reclaim min-free nothing completed; do
  setup_retention_report "$retention_journal"
  retention_journal_err="$TEST_ENV_DIR/retention_journal.err"
  : > "$retention_journal_err"
  retention_journal_risk=safe
  retention_journal_args=(--config "$TEST_ENV_DIR/retention_report.conf" --clean --trash-keep-days 7 --force)
  retention_journal_text='Retention purge failed after the cleanup was skipped.'
  case "$retention_journal" in
    standalone)
      retention_journal_args=(--purge-sessions older-than:7 --force)
      retention_journal_text='Quarantine purge older-than:7 failed with exit status 1.'
      ;;
    selector)
      retention_journal_args=(--purge-sessions older-than:30d --force)
      retention_journal_text='Quarantine purge older-than:30d failed with exit status 1.'
      ;;
    preview)
      retention_journal_risk=bogus
      retention_journal_args=(--config "$TEST_ENV_DIR/retention_report.conf" --dry-run)
      retention_journal_text='Run stopped with exit status 1 before cleaning.'
      ;;
    min-reclaim) retention_journal_args+=(--min-reclaim 1G) ;;
    min-free) retention_journal_args+=(--min-free 1) ;;
    nothing) rm -rf "$retention_target" ;;
    completed) retention_journal_text='Cleanup failed: failed=0; targets: none; operation_failed=true; retention_failed=true.' ;;
  esac
  retention_journal_exit=0
  retention_journal_stream=$(stat -L -c '%d:%i' "$retention_journal_err")
  JOURNAL_STREAM="$retention_journal_stream" PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
    LINUX_CLEANER_RISK="$retention_journal_risk" "$CLEANER_SH" "${retention_journal_args[@]}" < /dev/null > /dev/null 2> "$retention_journal_err" || retention_journal_exit=$?
  if [[ "$retention_journal_exit" -ne 1 ]] \
     || [[ "$(grep -c '^<3>linux-cleaner:' "$retention_journal_err" || true)" -ne 1 ]] \
     || ! grep -Fqx "<3>linux-cleaner: $retention_journal_text" "$retention_journal_err"; then
    echo -e "${RED}FAIL: retention journal line ($retention_journal, exit=$retention_journal_exit).${NC}"
    cat "$retention_journal_err"
    exit 1
  fi
done
unset MOCK_RETENTION_MODE MOCK_RETENTION_OLD MOCK_RETENTION_TARGET
echo -e "${GREEN}PASS: retention outcomes survive cleanup exits without changing target counters or historical reports.${NC}"

# --purge-sessions max-size:SIZE: keep newest sessions within a byte budget
# and purge older ones; exit 0 when within budget or when no quarantine base
# exists; exit 1 on malformed or overflowing SIZE.
setup_mock_env
ms_qbase="$MOCK_HOME/.cache/linux-cleaner/quarantine"
ms_s1="$ms_qbase/2026-01-01_00-00-00"
ms_s2="$ms_qbase/2026-01-02_00-00-00"
ms_s3="$ms_qbase/2026-01-03_00-00-00"
mkdir -p "$ms_s1" "$ms_s2" "$ms_s3"
dd if=/dev/zero of="$ms_s1/payload.bin" bs=1048576 count=2 status=none
dd if=/dev/zero of="$ms_s2/payload.bin" bs=1048576 count=2 status=none
dd if=/dev/zero of="$ms_s3/payload.bin" bs=1048576 count=2 status=none

if ! run_test_case "Purge Sessions Max Size Keeps Newest" 0 "purge_max_size_keep.log" \
       --purge-sessions max-size:5M --force \
   || [[ -d "$ms_s1" ]] \
   || [[ ! -d "$ms_s2" ]] \
   || [[ ! -d "$ms_s3" ]] \
   || ! grep -q "Purged 2026-01-01_00-00-00" "$TEST_ENV_DIR/purge_max_size_keep.log" \
   || ! grep -q "Purged 1 session(s)." "$TEST_ENV_DIR/purge_max_size_keep.log"; then
  echo -e "${RED}FAIL: --purge-sessions max-size:5M did not keep the two newest sessions and purge the oldest.${NC}"
  cat "$TEST_ENV_DIR/purge_max_size_keep.log" 2>/dev/null || true
  exit 1
fi

if ! run_test_case "Purge Sessions Max Size Nothing To Purge" 0 "purge_max_size_none.log" \
       --purge-sessions max-size:5M --force \
   || ! grep -qF "No quarantine sessions beyond the max-size:5M budget." "$TEST_ENV_DIR/purge_max_size_none.log" \
   || [[ ! -d "$ms_s2" ]] \
   || [[ ! -d "$ms_s3" ]]; then
  echo -e "${RED}FAIL: --purge-sessions max-size:5M when within budget did not report nothing to purge and keep sessions.${NC}"
  cat "$TEST_ENV_DIR/purge_max_size_none.log" 2>/dev/null || true
  exit 1
fi

rm -rf "$ms_qbase"
if ! run_test_case "Purge Sessions Max Size Missing Base" 0 "purge_max_size_missing_base.log" \
       --purge-sessions max-size:5M --force \
   || ! grep -qF "No quarantine sessions beyond the max-size:5M budget." "$TEST_ENV_DIR/purge_max_size_missing_base.log"; then
  echo -e "${RED}FAIL: --purge-sessions max-size:5M without quarantine base did not exit 0 with nothing-to-purge message.${NC}"
  cat "$TEST_ENV_DIR/purge_max_size_missing_base.log" 2>/dev/null || true
  exit 1
fi

if ! run_test_case "Purge Sessions Max Size Invalid" 1 "purge_max_size_invalid.log" \
       --purge-sessions max-size:10X --force \
   || ! grep -qF "Error: Invalid size in 'max-size:10X'. Use max-size:<size>, e.g. max-size:5G." "$TEST_ENV_DIR/purge_max_size_invalid.log" \
   || ! run_test_case "Purge Sessions Max Size Too Large" 1 "purge_max_size_overflow.log" \
       --purge-sessions max-size:99999999999T --force \
   || ! grep -qF "Error: max-size '99999999999T' in 'max-size:99999999999T' is too large." "$TEST_ENV_DIR/purge_max_size_overflow.log"; then
  echo -e "${RED}FAIL: --purge-sessions max-size did not reject malformed or overflowing SIZE.${NC}"
  cat "$TEST_ENV_DIR/purge_max_size_invalid.log" "$TEST_ENV_DIR/purge_max_size_overflow.log" 2>/dev/null || true
  exit 1
fi
echo -e "${GREEN}PASS: --purge-sessions max-size:SIZE keeps newest sessions within budget and validates SIZE.${NC}"

# --purge-sessions keep-latest:N: keep the N newest sessions and purge older
# ones; exit 0 when at most N sessions exist or when no quarantine base exists;
# exit 1 on an invalid count.
setup_mock_env
kl_qbase="$MOCK_HOME/.cache/linux-cleaner/quarantine"
kl_s1="$kl_qbase/2026-01-01_00-00-00"
kl_s2="$kl_qbase/2026-01-02_00-00-00"
kl_s3="$kl_qbase/2026-01-03_00-00-00"
mkdir -p "$kl_s1" "$kl_s2" "$kl_s3"
printf 'one\n' > "$kl_s1/payload.txt"
printf 'two\n' > "$kl_s2/payload.txt"
printf 'three\n' > "$kl_s3/payload.txt"

if ! run_test_case "Purge Sessions Keep Latest Keeps Newest" 0 "purge_keep_latest_keep.log" \
       --purge-sessions keep-latest:2 --force \
   || [[ -d "$kl_s1" ]] \
   || [[ ! -d "$kl_s2" ]] \
   || [[ ! -d "$kl_s3" ]] \
   || ! grep -q "Purged 2026-01-01_00-00-00" "$TEST_ENV_DIR/purge_keep_latest_keep.log" \
   || ! grep -q "Purged 1 session(s)." "$TEST_ENV_DIR/purge_keep_latest_keep.log"; then
  echo -e "${RED}FAIL: --purge-sessions keep-latest:2 did not keep the two newest sessions and purge the oldest.${NC}"
  cat "$TEST_ENV_DIR/purge_keep_latest_keep.log" 2>/dev/null || true
  exit 1
fi

if ! run_test_case "Purge Sessions Keep Latest Nothing To Purge" 0 "purge_keep_latest_none.log" \
       --purge-sessions keep-latest:2 --force \
   || ! grep -qF "No quarantine sessions beyond the newest 2." "$TEST_ENV_DIR/purge_keep_latest_none.log" \
   || [[ ! -d "$kl_s2" ]] \
   || [[ ! -d "$kl_s3" ]]; then
  echo -e "${RED}FAIL: --purge-sessions keep-latest:2 when within count did not report nothing to purge and keep sessions.${NC}"
  cat "$TEST_ENV_DIR/purge_keep_latest_none.log" 2>/dev/null || true
  exit 1
fi

# A count too large for shell arithmetic keeps everything instead of wrapping.
if ! run_test_case "Purge Sessions Keep Latest Huge Count" 0 "purge_keep_latest_huge.log" \
       --purge-sessions keep-latest:18446744073709551615 --force \
   || ! grep -qF "No quarantine sessions beyond the newest 18446744073709551615." "$TEST_ENV_DIR/purge_keep_latest_huge.log" \
   || [[ ! -d "$kl_s2" ]] \
   || [[ ! -d "$kl_s3" ]]; then
  echo -e "${RED}FAIL: --purge-sessions keep-latest with a huge count purged a session.${NC}"
  cat "$TEST_ENV_DIR/purge_keep_latest_huge.log" 2>/dev/null || true
  exit 1
fi

rm -rf "$kl_qbase"
if ! run_test_case "Purge Sessions Keep Latest Missing Base" 0 "purge_keep_latest_missing_base.log" \
       --purge-sessions keep-latest:2 --force \
   || ! grep -qF "No quarantine sessions beyond the newest 2." "$TEST_ENV_DIR/purge_keep_latest_missing_base.log"; then
  echo -e "${RED}FAIL: --purge-sessions keep-latest:2 without quarantine base did not exit 0 with nothing-to-purge message.${NC}"
  cat "$TEST_ENV_DIR/purge_keep_latest_missing_base.log" 2>/dev/null || true
  exit 1
fi

if ! run_test_case "Purge Sessions Keep Latest Invalid" 1 "purge_keep_latest_invalid.log" \
       --purge-sessions keep-latest:x --force \
   || ! grep -qF "Error: Invalid count in 'keep-latest:x'. Use keep-latest:<count> with a count of at least 1, e.g. keep-latest:5." "$TEST_ENV_DIR/purge_keep_latest_invalid.log"; then
  echo -e "${RED}FAIL: --purge-sessions keep-latest:x did not reject an invalid count.${NC}"
  cat "$TEST_ENV_DIR/purge_keep_latest_invalid.log" 2>/dev/null || true
  exit 1
fi

# keep-latest:0 and zero-padded zeros must exit 1, leave every session in place,
# and refuse to purge; positive counts like keep-latest:01 keep the requested count.
mkdir -p "$kl_s1" "$kl_s2" "$kl_s3"
printf 'one\n' > "$kl_s1/payload.txt"
printf 'two\n' > "$kl_s2/payload.txt"
printf 'three\n' > "$kl_s3/payload.txt"

if ! run_test_case "Purge Sessions Keep Latest Zero Rejected" 1 "purge_keep_latest_zero.log" \
       --purge-sessions keep-latest:0 --force \
   || ! grep -qF "Error: Invalid count in 'keep-latest:0'. Use keep-latest:<count> with a count of at least 1, e.g. keep-latest:5." "$TEST_ENV_DIR/purge_keep_latest_zero.log" \
   || [[ ! -d "$kl_s1" ]] \
   || [[ ! -d "$kl_s2" ]] \
   || [[ ! -d "$kl_s3" ]]; then
  echo -e "${RED}FAIL: --purge-sessions keep-latest:0 did not exit 1 or purged a session.${NC}"
  cat "$TEST_ENV_DIR/purge_keep_latest_zero.log" 2>/dev/null || true
  exit 1
fi

if ! run_test_case "Purge Sessions Keep Latest Zero Padded Rejected" 1 "purge_keep_latest_zero_padded.log" \
       --purge-sessions keep-latest:000 --force \
   || ! grep -qF "Error: Invalid count in 'keep-latest:000'. Use keep-latest:<count> with a count of at least 1, e.g. keep-latest:5." "$TEST_ENV_DIR/purge_keep_latest_zero_padded.log" \
   || [[ ! -d "$kl_s1" ]] \
   || [[ ! -d "$kl_s2" ]] \
   || [[ ! -d "$kl_s3" ]]; then
  echo -e "${RED}FAIL: --purge-sessions keep-latest:000 did not exit 1 or purged a session.${NC}"
  cat "$TEST_ENV_DIR/purge_keep_latest_zero_padded.log" 2>/dev/null || true
  exit 1
fi

if ! run_test_case "Purge Sessions Keep Latest Zero Padded Positive" 0 "purge_keep_latest_zero_padded_pos.log" \
       --purge-sessions keep-latest:01 --force \
   || [[ -d "$kl_s1" ]] \
   || [[ -d "$kl_s2" ]] \
   || [[ ! -d "$kl_s3" ]] \
   || ! grep -q "Purged 2 session(s)." "$TEST_ENV_DIR/purge_keep_latest_zero_padded_pos.log"; then
  echo -e "${RED}FAIL: --purge-sessions keep-latest:01 did not keep exactly one newest session and purge older.${NC}"
  cat "$TEST_ENV_DIR/purge_keep_latest_zero_padded_pos.log" 2>/dev/null || true
  exit 1
fi
echo -e "${GREEN}PASS: --purge-sessions keep-latest:N keeps newest sessions within count and validates count.${NC}"

# --min-age DAYS / LINUX_CLEANER_MIN_AGE: raise every ordinary target's age
# threshold for one run, keep larger row thresholds, skip action:* rows, and
# reject invalid values or incompatible modes.
echo -e "\n${BOLD}Test Case: Min Age Override${NC}"
setup_mock_env
ma_dir="$MOCK_HOME/.cache/min_age_target"
ma_high_dir="$MOCK_HOME/.cache/min_age_high"
mkdir -p "$ma_dir" "$ma_high_dir"
printf 'old-file-payload\n' > "$ma_dir/old.txt"
printf 'fresh\n' > "$ma_dir/fresh.txt"
touch -d "40 days ago" "$ma_dir/old.txt"
printf 'high-age-payload\n' > "$ma_high_dir/mid.txt"
touch -d "40 days ago" "$ma_high_dir/mid.txt"
ma_old_bytes=$(du -sb "$ma_dir/old.txt" | awk '{print $1}')
# An age-0 plan sizes the whole directory, not the sum of its files.
ma_dir_bytes=$(du -sb "$ma_dir" | awk '{print $1}')
cat > "$TEST_ENV_DIR/min_age.conf" <<EOF
safe|Min Age Target|\$HOME/.cache/min_age_target|Min age test target|0||
safe|High Age Target|\$HOME/.cache/min_age_high|High age target|60||
safe|Action Target|/var/cache/pacman/pkg|Pacman action|0||action:pacman_clean
EOF

if ! run_test_case "Min Age Dry Run JSON" 0 "min_age_json.log" \
       --config "$TEST_ENV_DIR/min_age.conf" --dry-run --json --min-age 30 \
   || ! python3 - "$TEST_ENV_DIR/min_age_json.log" "$ma_old_bytes" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
old_bytes = int(sys.argv[2])
assert d["total_reclaimable_bytes"] == old_bytes, d
by_name = {t["name"]: t for t in d["targets"]}
assert "Action Target" not in by_name, by_name
t = by_name["Min Age Target"]
assert t["min_age_days"] == "30" and t["bytes"] == old_bytes and t["status"] == "found", t
h = by_name["High Age Target"]
assert h["min_age_days"] == "60" and h["bytes"] == 0 and h["status"] == "clean", h
PY
then
  echo -e "${RED}FAIL: --dry-run --json --min-age 30 did not report min_age_days '30', old file bytes only, preserved larger row age, and excluded action:* rows.${NC}"
  cat "$TEST_ENV_DIR/min_age_json.log" 2>/dev/null || true
  exit 1
fi
echo -e "${GREEN}PASS: --dry-run --json --min-age 30 reports raised min_age_days, old file bytes only, and skips action:* rows.${NC}"

echo -e "\n${BOLD}Test Case: Min Age Env Dry Run JSON${NC}"
min_age_env_ec=0
LINUX_CLEANER_MIN_AGE=30 PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
  "$CLEANER_SH" --config "$TEST_ENV_DIR/min_age.conf" --dry-run --json \
  < /dev/null > "$TEST_ENV_DIR/min_age_env_json.log" 2>&1 || min_age_env_ec=$?
if [[ "$min_age_env_ec" -ne 0 ]] \
   || ! python3 - "$TEST_ENV_DIR/min_age_env_json.log" "$ma_old_bytes" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
old_bytes = int(sys.argv[2])
assert d["total_reclaimable_bytes"] == old_bytes, d
by_name = {t["name"]: t for t in d["targets"]}
assert "Action Target" not in by_name, by_name
t = by_name["Min Age Target"]
assert t["min_age_days"] == "30" and t["bytes"] == old_bytes and t["status"] == "found", t
h = by_name["High Age Target"]
assert h["min_age_days"] == "60" and h["bytes"] == 0 and h["status"] == "clean", h
PY
then
  echo -e "${RED}FAIL: LINUX_CLEANER_MIN_AGE=30 did not report min_age_days '30' and old file bytes only (ec=$min_age_env_ec).${NC}"
  cat "$TEST_ENV_DIR/min_age_env_json.log" 2>/dev/null || true
  exit 1
fi
echo -e "${GREEN}PASS: LINUX_CLEANER_MIN_AGE=30 raises min_age_days to '30' and plans only old file bytes.${NC}"

echo -e "\n${BOLD}Test Case: Min Age CLI Overrides Env${NC}"
min_age_override_ec=0
LINUX_CLEANER_MIN_AGE=30 PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
  "$CLEANER_SH" --config "$TEST_ENV_DIR/min_age.conf" --dry-run --json --min-age 0 \
  < /dev/null > "$TEST_ENV_DIR/min_age_override_json.log" 2>&1 || min_age_override_ec=$?
if [[ "$min_age_override_ec" -ne 0 ]] \
   || ! python3 - "$TEST_ENV_DIR/min_age_override_json.log" "$ma_dir_bytes" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
total_bytes = int(sys.argv[2])
assert d["total_reclaimable_bytes"] == total_bytes, d
by_name = {t["name"]: t for t in d["targets"]}
assert "Action Target" not in by_name, by_name
t = by_name["Min Age Target"]
assert t["min_age_days"] == "0" and t["bytes"] == total_bytes and t["status"] == "found", t
h = by_name["High Age Target"]
assert h["min_age_days"] == "60" and h["bytes"] == 0 and h["status"] == "clean", h
PY
then
  echo -e "${RED}FAIL: --min-age 0 did not override LINUX_CLEANER_MIN_AGE=30 to plan the whole directory (ec=$min_age_override_ec).${NC}"
  cat "$TEST_ENV_DIR/min_age_override_json.log" 2>/dev/null || true
  exit 1
fi
echo -e "${GREEN}PASS: --min-age 0 overrides LINUX_CLEANER_MIN_AGE=30 so the fresh file is planned again.${NC}"

if ! run_test_case "Min Age Clean Deletes Only Old" 0 "min_age_clean.log" \
       --config "$TEST_ENV_DIR/min_age.conf" --clean --force --min-age 30 \
   || [[ -e "$ma_dir/old.txt" ]] \
   || [[ ! -f "$ma_dir/fresh.txt" ]] \
   || [[ ! -f "$ma_high_dir/mid.txt" ]]; then
  echo -e "${RED}FAIL: --clean --force --min-age 30 did not delete only the old file.${NC}"
  cat "$TEST_ENV_DIR/min_age_clean.log" 2>/dev/null || true
  exit 1
fi
echo -e "${GREEN}PASS: --clean --force --min-age 30 deletes only the 40-day-old file and keeps fresh and higher-threshold files.${NC}"

echo -e "\n${BOLD}Test Case: Min Age Env Invalid Value${NC}"
min_age_env_bad_ec=0
LINUX_CLEANER_MIN_AGE=bad PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
  "$CLEANER_SH" --config "$TEST_ENV_DIR/min_age.conf" --dry-run \
  < /dev/null > "$TEST_ENV_DIR/min_age_env_bad.log" 2>&1 || min_age_env_bad_ec=$?
if [[ "$min_age_env_bad_ec" -ne 1 ]] \
   || ! grep -q -- "--min-age expects a non-negative integer" "$TEST_ENV_DIR/min_age_env_bad.log"; then
  echo -e "${RED}FAIL: LINUX_CLEANER_MIN_AGE=bad did not exit 1 with expected error (ec=$min_age_env_bad_ec).${NC}"
  cat "$TEST_ENV_DIR/min_age_env_bad.log" 2>/dev/null || true
  exit 1
fi
echo -e "${GREEN}PASS: LINUX_CLEANER_MIN_AGE=bad exits 1 with a clear error.${NC}"

if ! run_test_case "Min Age Invalid Value" 1 "min_age_bad.log" \
       --config "$TEST_ENV_DIR/min_age.conf" --min-age abc --dry-run \
   || ! grep -q -- "--min-age expects a non-negative integer" "$TEST_ENV_DIR/min_age_bad.log" \
   || ! run_test_case "Min Age Missing Value" 1 "min_age_noarg.log" \
       --config "$TEST_ENV_DIR/min_age.conf" --min-age \
   || ! grep -q -- "--min-age requires a day count" "$TEST_ENV_DIR/min_age_noarg.log" \
   || ! run_test_case "Min Age With Report Rejected" 1 "min_age_report.log" \
       --min-age 5 --report \
   || ! grep -q -- "--min-age applies only to cleanup" "$TEST_ENV_DIR/min_age_report.log" \
   || ! run_test_case "Min Age Large Decimal No Overflow" 0 "min_age_huge.log" \
       --config "$TEST_ENV_DIR/min_age.conf" --dry-run --min-age 0099999999999999999999; then
  echo -e "${RED}FAIL: --min-age validation, mode exclusion, or large decimal handling failed.${NC}"
  cat "$TEST_ENV_DIR/min_age_bad.log" "$TEST_ENV_DIR/min_age_noarg.log" "$TEST_ENV_DIR/min_age_report.log" "$TEST_ENV_DIR/min_age_huge.log" 2>/dev/null || true
  exit 1
fi
echo -e "${GREEN}PASS: --min-age rejects invalid values and incompatible modes and handles huge decimal values without overflow.${NC}"

cat > "$TEST_ENV_DIR/min_age_action_only.conf" <<EOF
safe|Action Target|/var/cache/pacman/pkg|Pacman action|0||action:pacman_clean
EOF

if ! run_test_case "Min Age Action Only Selection Rejected" 1 "min_age_action_only.log" \
       --config "$TEST_ENV_DIR/min_age_action_only.conf" --min-age 5 --dry-run \
   || ! grep -qF "Error: No eligible config target remains for '--min-age 5' (action:* rows are skipped)." "$TEST_ENV_DIR/min_age_action_only.log" \
   || ! run_test_case "Min Age Only Target Action Rejected" 1 "min_age_action_target.log" \
       --config "$TEST_ENV_DIR/min_age.conf" --min-age 5 --only-target "Action Target" --dry-run \
   || ! grep -qF "Error: No eligible config target remains for '--min-age 5' (action:* rows are skipped)." "$TEST_ENV_DIR/min_age_action_target.log" \
   || ! run_test_case "Min Age Ordinary Target Selection" 0 "min_age_target_ok.log" \
       --config "$TEST_ENV_DIR/min_age.conf" --min-age 5 --only-target "Min Age"; then
  echo -e "${RED}FAIL: --min-age did not exit 1 on action-only targets or succeed on ordinary target selection.${NC}"
  cat "$TEST_ENV_DIR/min_age_action_only.log" "$TEST_ENV_DIR/min_age_action_target.log" "$TEST_ENV_DIR/min_age_target_ok.log" 2>/dev/null || true
  exit 1
fi
echo -e "${GREEN}PASS: --min-age fails when selection leaves only action rows and succeeds for ordinary rows.${NC}"

# A filter:cxx_build row takes the raised age as its idle threshold: a build tree
# last touched 10 days ago is planned at age 0 but active under --min-age 30.
ma_build="$MOCK_HOME/min_age_build"
mkdir -p "$ma_build"
printf 'cache\n' > "$ma_build/CMakeCache.txt"
touch -d "10 days ago" "$ma_build/CMakeCache.txt" "$ma_build"
cat > "$TEST_ENV_DIR/min_age_build.conf" <<EOF
safe|Min Age Build|\$HOME/min_age_build|Idle build tree|0||filter:cxx_build
EOF
for ma_case in "0:found" "30:clean"; do
  ma_args=(--config "$TEST_ENV_DIR/min_age_build.conf" --dry-run --json)
  [[ "${ma_case%%:*}" == 0 ]] || ma_args+=(--min-age "${ma_case%%:*}")
  if ! run_test_case "Min Age Build Idle ${ma_case}" 0 "min_age_build.log" "${ma_args[@]}" \
     || ! python3 - "$TEST_ENV_DIR/min_age_build.log" "${ma_case##*:}" <<'PY'
import json, sys
t = {t["name"]: t for t in json.load(open(sys.argv[1], encoding="utf-8"))["targets"]}["Min Age Build"]
assert t["status"] == sys.argv[2], t
PY
  then
    echo -e "${RED}FAIL: filter:cxx_build row did not report '${ma_case##*:}' for idle threshold ${ma_case%%:*}.${NC}"
    cat "$TEST_ENV_DIR/min_age_build.log" 2>/dev/null || true
    exit 1
  fi
done
echo -e "${GREEN}PASS: --min-age raises a filter:cxx_build row's idle threshold.${NC}"

# --action-timeout SECONDS / LINUX_CLEANER_ACTION_TIMEOUT: a hung action:* command
# is stopped and counted as a failed target while later targets and retention still
# run; with no positive limit the action runs without timeout(1).
echo -e "\n${BOLD}Test Case: Action Timeout${NC}"
setup_mock_env
at_real_timeout=$(command -v timeout)
at_later="$MOCK_HOME/.cache/action_timeout_later"
at_old_sess="$MOCK_HOME/.cache/linux-cleaner/quarantine/2020-01-01_00-00-00"
at_action_trace="$TEST_ENV_DIR/action_timeout_uv.trace"
at_timeout_trace="$TEST_ENV_DIR/action_timeout_wrap.trace"
cat > "$TEST_ENV_DIR/action_timeout.conf" <<EOF
safe|Hung Action|\$HOME/.cache/uv|Hung action fixture|0||action:uv_cache_prune
safe|Later Target|\$HOME/.cache/action_timeout_later|Later ordinary target|0||
EOF
cat > "$TEST_ENV_DIR/bin/uv" <<EOF
#!/usr/bin/env bash
printf 'started\n' >> "$at_action_trace"
sleep "\${MOCK_ACTION_SLEEP:-5}"
printf 'finished\n' >> "$at_action_trace"
exit "\${MOCK_ACTION_EXIT:-0}"
EOF
cat > "$TEST_ENV_DIR/bin/timeout" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$at_timeout_trace"
exec "$at_real_timeout" "\$@"
EOF
chmod +x "$TEST_ENV_DIR/bin/uv" "$TEST_ENV_DIR/bin/timeout"
at_reset() {
  rm -f "$at_action_trace" "$at_timeout_trace"
  mkdir -p "$MOCK_HOME/.cache/uv" "$at_later" "$at_old_sess/0_Old_Target"
  printf 'later\n' > "$at_later/later.txt"
  printf 'old-quarantined\n' > "$at_old_sess/0_Old_Target/old.txt"
  printf 'full|0_Old_Target|%s/.cache/old_target|false|%s|%s\n' \
    "$MOCK_HOME" "$(id -u)" "$(id -g)" > "$at_old_sess/quarantine.meta"
  touch -d "10 days ago" "$at_old_sess"
}

at_reset
if ! run_test_case "Action Timeout Stops Hung Action" 1 "action_timeout_hung.log" \
       --config "$TEST_ENV_DIR/action_timeout.conf" --clean --force --action-timeout 1 --trash-keep-days 7 \
   || ! grep -qF "Error: Action 'action:uv_cache_prune' for 'Hung Action' timed out after 1 seconds." "$TEST_ENV_DIR/action_timeout_hung.log" \
   || ! grep -qF "Failed targets: Hung Action" "$TEST_ENV_DIR/action_timeout_hung.log" \
   || ! grep -qF "Purged 2020-01-01_00-00-00" "$TEST_ENV_DIR/action_timeout_hung.log" \
   || [[ -e "$at_later/later.txt" || -d "$at_old_sess" ]] \
   || [[ "$(cat "$at_action_trace")" != started ]] \
   || [[ "$(cat "$at_timeout_trace")" != "--kill-after=10 1 uv cache prune --cache-dir $(realpath "$MOCK_HOME/.cache/uv")" ]]; then
  echo -e "${RED}FAIL: --action-timeout 1 did not stop the hung action, count it failed, and still clean the later target and run retention.${NC}"
  cat "$TEST_ENV_DIR/action_timeout_hung.log" "$at_action_trace" "$at_timeout_trace" 2>/dev/null || true
  exit 1
fi
echo -e "${GREEN}PASS: --action-timeout 1 stops a hung action, counts it failed, cleans the later target, runs retention, and exits 1.${NC}"

for at_case in "unset|" "zero|0"; do
  at_reset
  if ! LINUX_CLEANER_ACTION_TIMEOUT="${at_case#*|}" MOCK_ACTION_SLEEP=0 \
       run_test_case "Action Timeout ${at_case%%|*} Runs Unwrapped" 0 "action_timeout_${at_case%%|*}.log" \
         --config "$TEST_ENV_DIR/action_timeout.conf" --clean --force \
     || [[ -e "$at_timeout_trace" ]] \
     || [[ "$(cat "$at_action_trace")" != $'started\nfinished' ]]; then
    echo -e "${RED}FAIL: an ${at_case%%|*} action timeout wrapped the action in timeout(1) or did not run it.${NC}"
    cat "$TEST_ENV_DIR/action_timeout_${at_case%%|*}.log" "$at_timeout_trace" 2>/dev/null || true
    exit 1
  fi
done
echo -e "${GREEN}PASS: an unset or zero action timeout runs the action without timeout(1).${NC}"

at_reset
if ! LINUX_CLEANER_ACTION_TIMEOUT=0030 MOCK_ACTION_SLEEP=0 \
     run_test_case "Action Timeout Env Wraps Action" 0 "action_timeout_env.log" \
       --config "$TEST_ENV_DIR/action_timeout.conf" --clean --force \
   || [[ "$(cat "$at_timeout_trace")" != "--kill-after=10 30 uv cache prune --cache-dir $(realpath "$MOCK_HOME/.cache/uv")" ]] \
   || [[ "$(cat "$at_action_trace")" != $'started\nfinished' ]]; then
  echo -e "${RED}FAIL: LINUX_CLEANER_ACTION_TIMEOUT=0030 did not wrap a finishing action with a 30 second limit.${NC}"
  cat "$TEST_ENV_DIR/action_timeout_env.log" "$at_timeout_trace" 2>/dev/null || true
  exit 1
fi
echo -e "${GREEN}PASS: LINUX_CLEANER_ACTION_TIMEOUT wraps the action with the normalized limit and a finished action succeeds.${NC}"

# An action killed before the limit (OOM, kill -9) exits 137 too: report a failure, not a timeout.
at_reset
if ! MOCK_ACTION_SLEEP=0 MOCK_ACTION_EXIT=137 \
     run_test_case "Action Timeout Early Kill Is Not A Timeout" 1 "action_timeout_early_kill.log" \
       --config "$TEST_ENV_DIR/action_timeout.conf" --clean --force --action-timeout 30 \
   || ! grep -qF "Error: Action 'action:uv_cache_prune' for 'Hung Action' failed." "$TEST_ENV_DIR/action_timeout_early_kill.log" \
   || grep -q 'timed out after' "$TEST_ENV_DIR/action_timeout_early_kill.log"; then
  echo -e "${RED}FAIL: an action that exited 137 before the limit was reported as a timeout.${NC}"
  cat "$TEST_ENV_DIR/action_timeout_early_kill.log" 2>/dev/null || true
  exit 1
fi
echo -e "${GREEN}PASS: an early exit 137 is reported as a failed action, not a timeout.${NC}"

at_env_bad_ec=0
LINUX_CLEANER_ACTION_TIMEOUT=-1 PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
  "$CLEANER_SH" --config "$TEST_ENV_DIR/action_timeout.conf" --dry-run \
  < /dev/null > "$TEST_ENV_DIR/action_timeout_env_bad.log" 2>&1 || at_env_bad_ec=$?
if [[ "$at_env_bad_ec" -ne 1 ]] \
   || ! grep -q -- "--action-timeout expects a non-negative integer" "$TEST_ENV_DIR/action_timeout_env_bad.log" \
   || ! run_test_case "Action Timeout Invalid Value" 1 "action_timeout_bad.log" \
       --config "$TEST_ENV_DIR/action_timeout.conf" --action-timeout 1.5 --dry-run \
   || ! grep -q -- "--action-timeout expects a non-negative integer" "$TEST_ENV_DIR/action_timeout_bad.log" \
   || ! run_test_case "Action Timeout Missing Value" 1 "action_timeout_noarg.log" \
       --config "$TEST_ENV_DIR/action_timeout.conf" --action-timeout \
   || ! grep -q -- "--action-timeout requires a seconds argument" "$TEST_ENV_DIR/action_timeout_noarg.log" \
   || ! run_test_case "Action Timeout With Report Rejected" 1 "action_timeout_report.log" \
       --action-timeout 5 --report \
   || ! grep -q -- "--action-timeout applies only to cleanup" "$TEST_ENV_DIR/action_timeout_report.log" \
   || ! LINUX_CLEANER_ACTION_TIMEOUT=5 run_test_case "Action Timeout Env With List Sessions Rejected" 1 "action_timeout_list.log" \
       --list-sessions \
   || ! grep -q -- "--action-timeout applies only to cleanup" "$TEST_ENV_DIR/action_timeout_list.log"; then
  echo -e "${RED}FAIL: --action-timeout validation or mode exclusion failed (env ec=$at_env_bad_ec).${NC}"
  cat "$TEST_ENV_DIR/action_timeout_env_bad.log" "$TEST_ENV_DIR/action_timeout_bad.log" "$TEST_ENV_DIR/action_timeout_noarg.log" \
    "$TEST_ENV_DIR/action_timeout_report.log" "$TEST_ENV_DIR/action_timeout_list.log" 2>/dev/null || true
  exit 1
fi
rm -f "$TEST_ENV_DIR/bin/uv" "$TEST_ENV_DIR/bin/timeout"
echo -e "${GREEN}PASS: --action-timeout rejects invalid values and read-only modes from the CLI and the environment.${NC}"

# --show-matches previews exactly the eligible paths, without mutating targets.
setup_mock_env
sm_dir="$MOCK_HOME/.cache/show matches"
mkdir -p "$sm_dir"
printf 'old\n' > "$sm_dir/old file.txt"
printf 'new\n' > "$sm_dir/new file.txt"
printf 'excluded\n' > "$sm_dir/excluded.txt"
touch -d '10 days ago' "$sm_dir/old file.txt" "$sm_dir/excluded.txt"
cat > "$TEST_ENV_DIR/show_matches.conf" <<EOF
safe|Match Target|\$HOME/.cache/show matches|Match preview|7||
EOF
if ! run_test_case "Show Matches Lists Only Eligible Files" 0 "show_matches.log" \
       --config "$TEST_ENV_DIR/show_matches.conf" --show-matches --dry-run --exclude excluded.txt \
   || [[ $(grep '^    /' "$TEST_ENV_DIR/show_matches.log") != "    $sm_dir/old file.txt" ]] \
   || ! grep -A1 -F '[FOUND] Match Target' "$TEST_ENV_DIR/show_matches.log" | grep -qxF "    $sm_dir/old file.txt" \
   || ! run_test_case "No Match Listing Without Flag" 0 "no_show_matches.log" \
       --config "$TEST_ENV_DIR/show_matches.conf" --debug --dry-run --exclude excluded.txt \
   || grep -qF "$sm_dir/old file.txt" "$TEST_ENV_DIR/no_show_matches.log" \
   || ! run_test_case "Quiet Suppresses Match Listing" 0 "quiet_show_matches.log" \
       --config "$TEST_ENV_DIR/show_matches.conf" --show-matches --quiet --dry-run \
   || grep -q '^    /' "$TEST_ENV_DIR/quiet_show_matches.log"; then
  echo -e "${RED}FAIL: match listing did not respect age, exclusions, target grouping, or output flags.${NC}"
  exit 1
fi

for sm_mode in --clean --force -f --interactive -i --json --restore --purge-sessions \
    --list-sessions --list-targets --check-config --report --init-config --doctor; do
  sm_args=("$sm_mode")
  case "$sm_mode" in
    --restore) sm_args+=(latest) ;;
    --purge-sessions) sm_args+=(all) ;;
  esac
  if ! run_test_case "Show Matches Rejects $sm_mode" 1 "show_matches_conflict.log" \
         --config "$TEST_ENV_DIR/show_matches.conf" --show-matches "${sm_args[@]}" \
     || ! grep -q 'cannot be combined' "$TEST_ENV_DIR/show_matches_conflict.log" \
     || ! run_test_case "Show Matches Rejects $sm_mode Before Dry Run" 1 "show_matches_conflict.log" \
         --config "$TEST_ENV_DIR/show_matches.conf" "${sm_args[@]}" --dry-run --show-matches \
     || ! grep -q 'cannot be combined' "$TEST_ENV_DIR/show_matches_conflict.log" \
     || [[ ! -f "$sm_dir/old file.txt" || ! -f "$sm_dir/new file.txt" || ! -f "$sm_dir/excluded.txt" ]]; then
    echo -e "${RED}FAIL: --show-matches accepted $sm_mode or changed a target.${NC}"
    exit 1
  fi
done

for ec_mode in --clean --force -f --interactive -i --restore --purge-sessions \
    --hold-session --release-session --list-sessions --list-targets --check-config --report --init-config --doctor; do
  ec_args=("$ec_mode")
  case "$ec_mode" in
    --restore|--hold-session|--release-session) ec_args+=(latest) ;;
    --purge-sessions) ec_args+=(all) ;;
  esac
  if ! run_test_case "Exit Code Rejects $ec_mode" 1 "exit_code_conflict.log" \
         --config "$TEST_ENV_DIR/show_matches.conf" --exit-code "${ec_args[@]}" \
     || ! grep -q 'cannot be combined' "$TEST_ENV_DIR/exit_code_conflict.log" \
     || ! run_test_case "Exit Code Rejects $ec_mode Before Dry Run" 1 "exit_code_conflict.log" \
         --config "$TEST_ENV_DIR/show_matches.conf" "${ec_args[@]}" --dry-run --exit-code \
     || ! grep -q 'cannot be combined' "$TEST_ENV_DIR/exit_code_conflict.log" \
     || [[ ! -f "$sm_dir/old file.txt" || ! -f "$sm_dir/new file.txt" || ! -f "$sm_dir/excluded.txt" ]]; then
    echo -e "${RED}FAIL: --exit-code accepted $ec_mode or changed a target.${NC}"
    exit 1
  fi
done
if ! LINUX_CLEANER_FORCE=1 run_test_case "Exit Code Rejects Inherited Force" 1 "exit_code_force.log" \
       --config "$TEST_ENV_DIR/show_matches.conf" --dry-run --exit-code \
   || ! run_test_case "Exit Code With Match Listing" 2 "exit_code_matches.log" \
       --config "$TEST_ENV_DIR/show_matches.conf" --show-matches --exit-code \
   || ! grep -qxF "    $sm_dir/old file.txt" "$TEST_ENV_DIR/exit_code_matches.log"; then
  echo -e "${RED}FAIL: --exit-code ignored inherited force or broke match listings.${NC}"
  exit 1
fi

cat > "$TEST_ENV_DIR/show_matches.conf" <<EOF
safe|Match Target|\$HOME/.cache/show matches|Match preview|0||
EOF
if ! run_test_case "Unfiltered Match Shows Only Target" 0 "show_matches_whole.log" \
       --config "$TEST_ENV_DIR/show_matches.conf" --show-matches \
   || [[ $(grep '^    /' "$TEST_ENV_DIR/show_matches_whole.log") != "    $sm_dir" ]] \
   || ! run_test_case "Exclusion Only Match Listing" 0 "show_matches_exclude.log" \
       --config "$TEST_ENV_DIR/show_matches.conf" --show-matches --exclude excluded.txt \
   || ! grep -qxF "    $sm_dir/old file.txt" "$TEST_ENV_DIR/show_matches_exclude.log" \
   || ! grep -qxF "    $sm_dir/new file.txt" "$TEST_ENV_DIR/show_matches_exclude.log" \
   || grep -qF "$sm_dir/excluded.txt" "$TEST_ENV_DIR/show_matches_exclude.log"; then
  echo -e "${RED}FAIL: unfiltered or exclusion-only match listing is incorrect.${NC}"
  exit 1
fi

ln -s 'old file.txt' "$sm_dir/old link"
touch -h -d '10 days ago' "$sm_dir/old link"
cat > "$TEST_ENV_DIR/show_matches.conf" <<EOF
safe|Old File|\$HOME/.cache/show matches/old file.txt|Old single file|7||
safe|New File|\$HOME/.cache/show matches/new file.txt|New single file|7||
safe|Excluded File|\$HOME/.cache/show matches/excluded.txt|Excluded single file|7||
safe|Directory|\$HOME/.cache/show matches|Files and symlinks|7||
EOF
if ! run_test_case "Single File And Symlink Matches" 0 "show_matches_files.log" \
       --config "$TEST_ENV_DIR/show_matches.conf" --show-matches --exclude excluded.txt \
   || [[ $(grep -cxF "    $sm_dir/old file.txt" "$TEST_ENV_DIR/show_matches_files.log") != 2 ]] \
   || ! grep -qxF "    $sm_dir/old link" "$TEST_ENV_DIR/show_matches_files.log" \
   || grep -qF "$sm_dir/new file.txt" "$TEST_ENV_DIR/show_matches_files.log" \
   || grep -qF "$sm_dir/excluded.txt" "$TEST_ENV_DIR/show_matches_files.log"; then
  echo -e "${RED}FAIL: single-file or symlink match listing is incorrect.${NC}"
  exit 1
fi
# A file name with an escape and a newline is printed quoted on one line.
sm_ctrl_name=$'evil\e[2Jname\n    forged'
printf 'c\n' > "$sm_dir/$sm_ctrl_name"
touch -d '10 days ago' "$sm_dir/$sm_ctrl_name"
cat > "$TEST_ENV_DIR/show_matches.conf" <<EOF
safe|Directory|\$HOME/.cache/show matches|Files and symlinks|7||
EOF
if ! run_test_case "Show Matches Quotes Control Characters" 0 "show_matches_ctrl.log" \
       --config "$TEST_ENV_DIR/show_matches.conf" --show-matches \
   || grep -q $'\e' "$TEST_ENV_DIR/show_matches_ctrl.log" \
   || grep -qxF '    forged' "$TEST_ENV_DIR/show_matches_ctrl.log" \
   || ! grep -qF "    $(printf '%q' "$sm_dir/$sm_ctrl_name")" "$TEST_ENV_DIR/show_matches_ctrl.log"; then
  echo -e "${RED}FAIL: --show-matches printed a raw control character or a forged line.${NC}"
  exit 1
fi
rm -f -- "$sm_dir/$sm_ctrl_name"

# An unreadable subdirectory must not end the preview of later targets.
mkdir -p "$sm_dir/locked" "$MOCK_HOME/.cache/after"
printf 'z\n' > "$sm_dir/locked/z"
printf 'a\n' > "$MOCK_HOME/.cache/after/a"
chmod 000 "$sm_dir/locked"
cat > "$TEST_ENV_DIR/show_matches.conf" <<EOF
safe|Directory|\$HOME/.cache/show matches|Files and symlinks|7||
safe|After|\$HOME/.cache/after|Later target|0||
EOF
sm_locked_ok=true
if ! run_test_case "Show Matches Survives Unreadable Subdirectory" 0 "show_matches_locked.log" \
       --config "$TEST_ENV_DIR/show_matches.conf" --show-matches \
   || ! grep -qxF "    $MOCK_HOME/.cache/after" "$TEST_ENV_DIR/show_matches_locked.log"; then
  sm_locked_ok=false
fi
chmod 755 "$sm_dir/locked"
if [[ "$sm_locked_ok" != true ]]; then
  echo -e "${RED}FAIL: --show-matches stopped at an unreadable subdirectory.${NC}"
  cat "$TEST_ENV_DIR/show_matches_locked.log"
  exit 1
fi
echo -e "${GREEN}PASS: --show-matches lists eligible paths only and refuses incompatible modes without deletion.${NC}"

# Bash completion drift and functional test: completions/cleaner.bash must
# pass bash -n, include every --long option from --help, and complete options
# and value grammars in plain bash without bash-completion helpers.
echo -e "\n${BOLD}Test Case: Bash Completion Drift and Functional Check${NC}"
setup_mock_env
comp_file="$SCRIPT_DIR/completions/cleaner.bash"
zsh_comp_file="$SCRIPT_DIR/completions/_cleaner"
fish_comp_file="$SCRIPT_DIR/completions/cleaner.fish"
if [[ ! -f "$comp_file" ]] || ! bash -n "$comp_file"; then
  echo -e "${RED}FAIL: completions/cleaner.bash is missing or failed bash -n.${NC}"
  exit 1
fi
if [[ ! -f "$zsh_comp_file" ]]; then
  echo -e "${RED}FAIL: completions/_cleaner is missing.${NC}"
  exit 1
fi
if command -v zsh > /dev/null 2>&1 && ! zsh -n "$zsh_comp_file"; then
  echo -e "${RED}FAIL: completions/_cleaner failed zsh -n.${NC}"
  exit 1
fi
if [[ ! -f "$fish_comp_file" ]]; then
  echo -e "${RED}FAIL: completions/cleaner.fish is missing.${NC}"
  exit 1
fi
if command -v fish > /dev/null 2>&1 && ! fish -n "$fish_comp_file"; then
  echo -e "${RED}FAIL: completions/cleaner.fish failed fish -n.${NC}"
  exit 1
fi
comp_help_out="$TEST_ENV_DIR/comp_help_flags.txt"
HOME="$MOCK_HOME" PATH="$TEST_ENV_DIR/bin:$PATH" bash "$CLEANER_SH" --help > "$comp_help_out" 2>&1
comp_missing_flags=""
zsh_comp_missing_flags=""
fish_comp_missing_flags=""
while IFS= read -r flag; do
  [[ -z "$flag" ]] && continue
  grep -qE -- "(^|[[:space:]])${flag}($|[[:space:]])" "$comp_file" || comp_missing_flags+=" $flag"
  grep -qE -- "(^|[^a-z-])${flag}($|[^a-z-])" "$zsh_comp_file" || zsh_comp_missing_flags+=" $flag"
  grep -qE -- "(^|[[:space:]])-l[[:space:]]+${flag#--}($|[[:space:]])" "$fish_comp_file" || fish_comp_missing_flags+=" $flag"
done < <(grep -oE -- '--[a-z][a-z-]*' "$comp_help_out" | sort -u)
if [[ -n "$comp_missing_flags" ]]; then
  echo -e "${RED}FAIL: completions/cleaner.bash lacks --help options:$comp_missing_flags.${NC}"
  exit 1
fi
if [[ -n "$zsh_comp_missing_flags" ]]; then
  echo -e "${RED}FAIL: completions/_cleaner lacks --help options:$zsh_comp_missing_flags.${NC}"
  exit 1
fi
if [[ -n "$fish_comp_missing_flags" ]]; then
  echo -e "${RED}FAIL: completions/cleaner.fish lacks --help options:$fish_comp_missing_flags.${NC}"
  exit 1
fi
if ! (
  # The completion file is syntax-checked with bash -n above.
  # shellcheck source=/dev/null
  source "$comp_file"
  COMP_WORDS=(cleaner -r "")
  COMP_CWORD=2
  HOME="$MOCK_HOME" _cleaner
  [[ "${COMPREPLY[*]}" == "safe medium danger" ]] || exit 1

  COMP_WORDS=(cleaner --ri)
  COMP_CWORD=1
  HOME="$MOCK_HOME" _cleaner
  [[ "${COMPREPLY[*]}" == "--risk" ]] || exit 1

  COMP_WORDS=(cleaner --restore "")
  COMP_CWORD=2
  HOME="$MOCK_HOME" _cleaner
  [[ "${COMPREPLY[*]}" == "latest" ]] || exit 1

  COMP_WORDS=(cleaner --purge-sessions "")
  COMP_CWORD=2
  HOME="$MOCK_HOME" _cleaner
  [[ "${COMPREPLY[*]}" == "latest all older-than: max-size: keep-latest:" ]] || exit 1

  echo -e "\n${BOLD}Test Case: Bash Quarantine Session Completion${NC}"
  mkdir -p "$MOCK_HOME/.cache/linux-cleaner/quarantine/2026-10-18_12-34-56/nested"
  touch "$MOCK_HOME/.cache/linux-cleaner/quarantine/not-a-session"
  for session_option in --restore --purge-sessions --hold-session --release-session; do
    COMP_WORDS=(cleaner "$session_option" "")
    HOME="$MOCK_HOME" _cleaner
    if [[ "$session_option" != --purge-sessions ]]; then
      [[ "${COMPREPLY[*]}" == "latest 2026-10-18_12-34-56" ]] || exit 1
    else
      [[ "${COMPREPLY[*]}" == "latest all older-than: max-size: keep-latest: 2026-10-18_12-34-56" ]] || exit 1
    fi
    COMP_WORDS=(cleaner "$session_option" 2026-)
    HOME="$MOCK_HOME" _cleaner
    [[ "${COMPREPLY[*]}" == "2026-10-18_12-34-56" ]] || exit 1
    COMP_WORDS=(cleaner "$session_option" missing)
    HOME="$MOCK_HOME" _cleaner
    [[ ${#COMPREPLY[@]} -eq 0 ]] || exit 1
  done
  (
    shopt -s failglob
    failglob_home="$TEST_ENV_DIR/failglob_empty_home"
    mkdir -p "$failglob_home"
    COMP_WORDS=(cleaner --restore "")
    COMP_CWORD=2
    HOME="$failglob_home" _cleaner
    [[ "${COMPREPLY[*]}" == "latest" ]] || exit 1

    COMP_WORDS=(cleaner --restore "")
    COMP_CWORD=2
    HOME="$MOCK_HOME" _cleaner
    [[ "${COMPREPLY[*]}" == "latest 2026-10-18_12-34-56" ]] || exit 1
    rm -rf "$failglob_home"
  ) || exit 1
  echo -e "${GREEN}PASS: bash completes immediate quarantine session names and preserves selectors with no quarantine directory.${NC}"

  COMP_WORDBREAKS=$' \t\n"\'><=;|&(:'
  COMP_WORDS=(cleaner --purge-sessions older-than :)
  COMP_CWORD=3
  HOME="$MOCK_HOME" _cleaner
  [[ ${#COMPREPLY[@]} -eq 0 ]] || exit 1

  COMP_WORDS=(cleaner --log --qu)
  COMP_CWORD=2
  HOME="$MOCK_HOME" _cleaner
  [[ "${COMPREPLY[*]}" == "--quiet" ]] || exit 1

  COMP_WORDS=(cleaner --log "$comp_file")
  COMP_CWORD=2
  HOME="$MOCK_HOME" _cleaner
  [[ "${COMPREPLY[*]}" == "$comp_file" ]] || exit 1

  COMP_WORDS=(cleaner --only-path "$comp_file")
  COMP_CWORD=2
  HOME="$MOCK_HOME" _cleaner
  [[ "${COMPREPLY[*]}" == "$comp_file" ]] || exit 1

  COMP_WORDS=(cleaner --min-age "")
  COMP_CWORD=2
  HOME="$MOCK_HOME" _cleaner
  [[ ${#COMPREPLY[@]} -eq 0 ]] || exit 1

  COMP_WORDS=(cleaner --action-timeout "")
  COMP_CWORD=2
  HOME="$MOCK_HOME" _cleaner
  [[ ${#COMPREPLY[@]} -eq 0 ]] || exit 1

  # File-valued options must ask readline to treat replies as filenames, so a
  # directory gets a trailing slash and special characters are quoted.
  # shellcheck disable=SC2329  # invoked indirectly by _cleaner
  compopt() { compopt_calls+=("$*"); }
  for file_option in -c --config --log --only-path --exclude-path --min-free-path; do
    compopt_calls=()
    COMP_WORDS=(cleaner "$file_option" "$comp_file")
    COMP_CWORD=2
    HOME="$MOCK_HOME" _cleaner
    [[ " ${compopt_calls[*]} " == *" -o filenames "* ]] || exit 1
  done
  for word_option in -r --restore --check-health; do
    compopt_calls=()
    COMP_WORDS=(cleaner "$word_option" "")
    COMP_CWORD=2
    HOME="$MOCK_HOME" _cleaner
    [[ " ${compopt_calls[*]} " != *"filenames"* ]] || exit 1
  done
  # A seconds value follows --check-health: no option names, even after a dash.
  for seconds_prefix in "" -; do
    COMP_WORDS=(cleaner --report --check-health "$seconds_prefix")
    COMP_CWORD=3
    HOME="$MOCK_HOME" _cleaner
    [[ ${#COMPREPLY[@]} -eq 0 ]] || exit 1
  done
  unset -f compopt
); then
  echo -e "${RED}FAIL: completions/cleaner.bash functional completion check failed.${NC}"
  exit 1
fi
echo -e "${GREEN}PASS: completions/cleaner.bash passes bash -n, covers all --help options, and completes flags and values.${NC}"

# Zsh and fish completion functional test: the zsh --purge-sessions selectors must
# complete (an unescaped ':' in the _arguments spec made zsh report a parse error and
# offer nothing), the prefix selectors must not gain a trailing space, and fish must
# not offer file names for options whose value is a pattern, size or number.
echo -e "\n${BOLD}Test Case: Zsh and Fish Completion Functional Check${NC}"
setup_mock_env
mkdir -p "$TEST_ENV_DIR/comp_fn" "$TEST_ENV_DIR/comp_work"
cp "$SCRIPT_DIR/completions/_cleaner" "$TEST_ENV_DIR/comp_fn/_cleaner"
touch "$TEST_ENV_DIR/comp_work/comp_file.txt"
if command -v zsh > /dev/null 2>&1; then
  # Drive a real interactive zsh through zpty: type the line, press TAB, then a
  # widget writes $BUFFER to a file, so the result does not depend on screen output.
  cat > "$TEST_ENV_DIR/zsh_comp_probe.zsh" <<'ZSH_PROBE'
fndir=$1 out=$2 line=$3
zmodload zsh/zpty || exit 2
zpty z zsh -f -i
zpty -w z "fpath=($fndir \$fpath); autoload -U compinit; compinit -u -D 2>/dev/null"
zpty -w z "dumpbuf() { print -r -- \"<\$BUFFER>\" > ${(q)out} }; zle -N dumpbuf; bindkey '^X' dumpbuf"
zpty -w -n z "${line}"$'\t'$'\x18'
for i in {1..100}; do [[ -s $out ]] && break; sleep 0.1; done
zpty -d z
[[ -s $out ]]
ZSH_PROBE
  zsh_comp_failed=""
  for zcase in "ol|<cleaner --purge-sessions older-than:>" "ma|<cleaner --purge-sessions max-size:>" \
               "ke|<cleaner --purge-sessions keep-latest:>" \
               "la|<cleaner --purge-sessions latest >" "al|<cleaner --purge-sessions all >"; do
    rm -f "$TEST_ENV_DIR/zsh_comp.out"
    if ! HOME="$MOCK_HOME" timeout 20 zsh -f "$TEST_ENV_DIR/zsh_comp_probe.zsh" "$TEST_ENV_DIR/comp_fn" "$TEST_ENV_DIR/zsh_comp.out" \
           "cleaner --purge-sessions ${zcase%%|*}" > /dev/null 2>&1 \
       || [[ "$(cat "$TEST_ENV_DIR/zsh_comp.out")" != "${zcase#*|}" ]]; then
      zsh_comp_failed+=" ${zcase%%|*}->'$(cat "$TEST_ENV_DIR/zsh_comp.out" 2>/dev/null)'"
    fi
  done
  if [[ -n "$zsh_comp_failed" ]]; then
    echo -e "${RED}FAIL: zsh did not complete the --purge-sessions selectors:$zsh_comp_failed.${NC}"
    exit 1
  fi
  echo -e "${GREEN}PASS: zsh completes the --purge-sessions selectors, without a space after older-than:, max-size:, and keep-latest:.${NC}"
  echo -e "\n${BOLD}Test Case: Zsh Quarantine Session Completion${NC}"
  mkdir -p "$MOCK_HOME/.cache/linux-cleaner/quarantine/2026-10-18_12-34-56/nested"
  touch "$MOCK_HOME/.cache/linux-cleaner/quarantine/not-a-session"
  for session_option in --restore --purge-sessions --hold-session --release-session; do
    rm -f "$TEST_ENV_DIR/zsh_comp.out"
    if ! HOME="$MOCK_HOME" timeout 20 zsh -f "$TEST_ENV_DIR/zsh_comp_probe.zsh" "$TEST_ENV_DIR/comp_fn" "$TEST_ENV_DIR/zsh_comp.out" \
           "cleaner $session_option 2026-" > /dev/null 2>&1 \
       || [[ "$(cat "$TEST_ENV_DIR/zsh_comp.out")" != "<cleaner $session_option 2026-10-18_12-34-56 >" ]]; then
      echo -e "${RED}FAIL: zsh did not complete a quarantine session name for $session_option.${NC}"
      exit 1
    fi
  done
  echo -e "${GREEN}PASS: zsh completes quarantine session names for --restore, --purge-sessions, --hold-session, and --release-session.${NC}"
else
  echo -e "${GREEN}PASS (skipped): zsh is not installed; cannot run the zsh completion check.${NC}"
fi
if command -v fish > /dev/null 2>&1; then
  echo -e "\n${BOLD}Test Case: Fish Quarantine Session Completion${NC}"
  rm -rf "$MOCK_HOME/.cache/linux-cleaner/quarantine"
  for session_layout in absent present; do
    if [[ "$session_layout" == present ]]; then
      mkdir -p "$MOCK_HOME/.cache/linux-cleaner/quarantine/2026-10-18_12-34-56/nested"
      touch "$MOCK_HOME/.cache/linux-cleaner/quarantine/not-a-session"
    fi
    # The single-quoted script is expanded by fish.
    # shellcheck disable=SC2016
    if ! HOME="$MOCK_HOME" XDG_CONFIG_HOME="$TEST_ENV_DIR/fish_cfg" XDG_DATA_HOME="$TEST_ENV_DIR/fish_data" \
         fish --no-config -c '
      source "$argv[1]"
      for option in --restore --purge-sessions --hold-session --release-session
        set expected latest
        if test "$option" = --purge-sessions
          set -a expected all older-than: max-size: keep-latest:
        end
        if test "$argv[2]" = present
          set -a expected 2026-10-18_12-34-56
        end
        set candidates (string split -f 1 \t -- (complete -C "cleaner $option "))
        test (count $candidates) -eq (count $expected); or exit 1
        for candidate in $expected
          contains -- "$candidate" $candidates; or exit 1
        end
        if test "$argv[2]" = present
          set candidates (string split -f 1 \t -- (complete -C "cleaner $option 2026-"))
          test "$candidates" = 2026-10-18_12-34-56; or exit 1
        end
      end
    ' -- "$fish_comp_file" "$session_layout"; then
      echo -e "${RED}FAIL: fish quarantine session completion failed with $session_layout quarantine directory.${NC}"
      exit 1
    fi
  done
  echo -e "${GREEN}PASS: fish completes only immediate quarantine directories and preserves selectors with no quarantine directory.${NC}"
  fish_comp_failed=""
  for fcase in --exclude --only --only-exact --only-target --exclude-target --lock-wait \
               --min-reclaim --min-free --min-age --action-timeout --trash-keep-days; do
    if [[ -n "$(cd "$TEST_ENV_DIR/comp_work" && XDG_CONFIG_HOME="$TEST_ENV_DIR/fish_cfg" XDG_DATA_HOME="$TEST_ENV_DIR/fish_data" \
                 fish --no-config -c "set -p fish_complete_path $SCRIPT_DIR/completions; complete -C 'cleaner $fcase '" 2>&1)" ]]; then
      fish_comp_failed+=" $fcase"
    fi
  done
  # cleaner takes no positional arguments, so a bare word must not complete files.
  if (cd "$TEST_ENV_DIR/comp_work" && XDG_CONFIG_HOME="$TEST_ENV_DIR/fish_cfg" XDG_DATA_HOME="$TEST_ENV_DIR/fish_data" \
        fish --no-config -c "set -p fish_complete_path $SCRIPT_DIR/completions; complete -C 'cleaner '") \
      | grep -q 'comp_file.txt'; then
    fish_comp_failed+=" bare-argument(file offered)"
  fi
  for file_option in --config --log --min-free-path; do
    if ! (cd "$TEST_ENV_DIR/comp_work" && XDG_CONFIG_HOME="$TEST_ENV_DIR/fish_cfg" XDG_DATA_HOME="$TEST_ENV_DIR/fish_data" \
            fish --no-config -c "set -p fish_complete_path $SCRIPT_DIR/completions; complete -C 'cleaner $file_option '") \
          | grep -qx 'comp_file.txt'; then
      fish_comp_failed+=" $file_option(no file offered)"
    fi
  done
  if ! (cd "$TEST_ENV_DIR/comp_work" && XDG_CONFIG_HOME="$TEST_ENV_DIR/fish_cfg" XDG_DATA_HOME="$TEST_ENV_DIR/fish_data" \
          fish --no-config -c "set -p fish_complete_path $SCRIPT_DIR/completions; complete -C 'cleaner --only-path '") \
        | grep -qx 'comp_file.txt'; then
    fish_comp_failed+=" --only-path(no file offered)"
  fi
  if [[ -n "$fish_comp_failed" ]]; then
    echo -e "${RED}FAIL: fish completion offered file names for bare arguments or value options, or none for --config/--log/--only-path:$fish_comp_failed.${NC}"
    exit 1
  fi
  echo -e "${GREEN}PASS: fish offers no file names for bare arguments or pattern, size and number values, and still offers files for --config, --log and --only-path.${NC}"
else
  echo -e "${GREEN}PASS (skipped): fish is not installed; cannot run the fish completion check.${NC}"
fi

# Match stderr directly: run_test_case merges it into stdout's log stream.
echo -e "\n${BOLD}Test Case: Journal Error Priority Line${NC}"
setup_mock_env
mkdir -p "$MOCK_HOME/.cache/uv"
printf 'safe|UV Cache|%s/.cache/uv|Journal priority fixture|0||action:uv_cache_prune\n' "$MOCK_HOME" > "$TEST_ENV_DIR/journal.conf"
cat > "$TEST_ENV_DIR/bin/uv" <<'JOURNAL_UV'
#!/usr/bin/env bash
if [[ "${MOCK_JOURNAL_INTERRUPT:-false}" == true ]]; then
  kill -TERM "$PPID"
fi
exit "${MOCK_JOURNAL_UV_EXIT:-1}"
JOURNAL_UV
chmod +x "$TEST_ENV_DIR/bin/uv"
# stat_failure installs a failing stat stub, so it must stay the last case.
for journal_case in failed unset mismatched success early interrupted preview_due_text preview_due_json preview_skip_text preview_skip_json preview_invalid stat_failure; do
  journal_stderr="$TEST_ENV_DIR/journal_${journal_case}.err"
  : > "$journal_stderr"
  journal_stream=$(stat -L -c '%d:%i' "$journal_stderr")
  journal_expected_exit=1
  journal_expected_lines=1
  journal_expected_text='Cleanup failed: failed=1; targets: UV Cache;'
  journal_uv_exit=1
  journal_risk=safe
  journal_interrupt=false
  journal_args=(--clean --force)
  case "$journal_case" in
    unset) journal_expected_lines=0 ;;
    mismatched) journal_stream=0:0; journal_expected_lines=0 ;;
    success) journal_uv_exit=0; journal_expected_exit=0; journal_expected_lines=0 ;;
    early) journal_risk=bogus; journal_expected_text='Cleanup stopped with exit status 1' ;;
    preview_due_*|preview_skip_*)
      journal_args=(--exit-code)
      [[ "$journal_case" == *_json ]] && journal_args+=(--json)
      journal_expected_exit=2
      journal_expected_lines=0
      if [[ "$journal_case" == preview_skip_* ]]; then
        journal_args+=(--min-reclaim 1G)
        journal_expected_exit=0
      fi
      ;;
    preview_invalid)
      journal_args=(--exit-code)
      journal_risk=bogus
      journal_expected_text='Run stopped with exit status 1 before cleaning.'
      ;;
    interrupted)
      journal_interrupt=true
      journal_expected_exit=143
      journal_expected_text='Cleanup interrupted: SIGTERM'
      ;;
    stat_failure)
      journal_expected_lines=0
      cat > "$TEST_ENV_DIR/bin/stat" <<'JOURNAL_STAT'
#!/usr/bin/env bash
if [[ "$*" == *'/dev/fd/3'* ]]; then
  echo 'stat fixture failure' >&2
  exit 1
fi
real_stat=$(PATH="${PATH#"$TEST_ENV_DIR/bin:"}" command -v stat)
exec "$real_stat" "$@"
JOURNAL_STAT
      chmod +x "$TEST_ENV_DIR/bin/stat"
      ;;
  esac
  journal_exit=0
  (
    export JOURNAL_STREAM="$journal_stream"
    [[ "$journal_case" != unset ]] || unset JOURNAL_STREAM
    PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
      LINUX_CLEANER_RISK="$journal_risk" MOCK_JOURNAL_UV_EXIT="$journal_uv_exit" \
      MOCK_JOURNAL_INTERRUPT="$journal_interrupt" \
      "$CLEANER_SH" --config "$TEST_ENV_DIR/journal.conf" "${journal_args[@]}"
  ) < /dev/null > "$TEST_ENV_DIR/journal_${journal_case}.log" 2> "$journal_stderr" || journal_exit=$?
  if [[ "$journal_exit" -ne "$journal_expected_exit" ]] \
     || [[ "$(grep -c '^<3>linux-cleaner:' "$journal_stderr" || true)" -ne "$journal_expected_lines" ]] \
     || { [[ "$journal_expected_lines" -eq 1 ]] && ! grep -Fq "<3>linux-cleaner: $journal_expected_text" "$journal_stderr"; } \
     || grep -q 'stat fixture failure' "$journal_stderr"; then
    echo -e "${RED}FAIL: journal priority case $journal_case (exit=$journal_exit).${NC}"
    cat "$journal_stderr" "$TEST_ENV_DIR/journal_${journal_case}.log"
    exit 1
  fi
done
echo -e "${GREEN}PASS: journal errors match stderr, name failures once, and preserve exit statuses.${NC}"

# --notify / LINUX_CLEANER_NOTIFY: send a desktop notification summarizing the
# cleanup result via notify-send, pass --urgency=critical on failed targets,
# ignore dry-runs and runs without the option, tolerate failing/missing
# notifiers without changing exit status, and reject non-cleanup modes.
echo -e "\n${BOLD}Test Case: Notify Cleanup Result${NC}"
setup_mock_env
notify_log="$TEST_ENV_DIR/notify_calls.log"
export MOCK_NOTIFY_LOG="$notify_log"
export MOCK_NOTIFY_EXIT=0
# setup_mock_env rebuilds $TEST_ENV_DIR/bin, so each step reinstalls the stub.
write_notify_stub() {
  cat > "$TEST_ENV_DIR/bin/notify-send" <<'NOTIFY_STUB'
#!/usr/bin/env bash
printf '%s\n---\n' "$*" >> "${MOCK_NOTIFY_LOG:?}"
exit "${MOCK_NOTIFY_EXIT:-0}"
NOTIFY_STUB
  chmod +x "$TEST_ENV_DIR/bin/notify-send"
}
write_notify_stub

# 1. --clean --force --notify records one call whose body starts with "Result: cleaned=" and includes "Reclaimed:".
: > "$notify_log"
if ! run_test_case "Notify Cleanup Result (clean --notify)" 0 "notify_clean.log" \
       --config "$TEST_ENV_DIR/test_cleaner.conf" --clean --force --notify \
   || [[ "$(grep -c '^---$' "$notify_log" || true)" -ne 1 ]] \
   || ! grep -q '^--app-name=linux-cleaner linux-cleaner Result: cleaned=' "$notify_log" \
   || ! grep -q '^Reclaimed: ' "$notify_log" \
   || grep -q -- '--urgency=critical' "$notify_log"; then
  echo -e "${RED}FAIL: --clean --force --notify did not record exactly one normal notification with Result: cleaned= and Reclaimed:.${NC}"
  cat "$notify_log" "$TEST_ENV_DIR/notify_clean.log" 2>/dev/null || true
  exit 1
fi

# 2. A run with a failing target passes --urgency=critical.
setup_mock_env
export MOCK_NOTIFY_LOG="$notify_log"
export MOCK_NOTIFY_EXIT=0
write_notify_stub
cat > "$TEST_ENV_DIR/bin/uv" <<'FAIL_UV'
#!/usr/bin/env bash
exit 1
FAIL_UV
chmod +x "$TEST_ENV_DIR/bin/uv"
mkdir -p "$MOCK_HOME/.cache/uv"
printf 'safe|UV Cache|%s/.cache/uv|Failing UV cache|0||action:uv_cache_prune\n' "$MOCK_HOME" > "$TEST_ENV_DIR/notify_fail.conf"
: > "$notify_log"
if ! run_test_case "Notify Cleanup Result (failed target critical)" 1 "notify_fail.log" \
       --config "$TEST_ENV_DIR/notify_fail.conf" --clean --force --notify \
   || [[ "$(grep -c '^---$' "$notify_log" || true)" -ne 1 ]] \
   || ! grep -q '^--app-name=linux-cleaner --urgency=critical linux-cleaner Result: cleaned=0 skipped=0 failed=1 ' "$notify_log" \
   || ! grep -q '^Reclaimed: ' "$notify_log"; then
  echo -e "${RED}FAIL: failing cleanup with --notify did not pass --urgency=critical.${NC}"
  cat "$notify_log" "$TEST_ENV_DIR/notify_fail.log" 2>/dev/null || true
  exit 1
fi

# 3. --dry-run --notify and a run without the flag record nothing.
setup_mock_env
export MOCK_NOTIFY_LOG="$notify_log"
export MOCK_NOTIFY_EXIT=0
write_notify_stub
: > "$notify_log"
if ! run_test_case "Notify Cleanup Result (dry-run --notify)" 0 "notify_dry.log" \
       --config "$TEST_ENV_DIR/test_cleaner.conf" --dry-run --notify \
   || ! run_test_case "Notify Cleanup Result (clean without --notify)" 0 "notify_off.log" \
       --config "$TEST_ENV_DIR/test_cleaner.conf" --clean --force \
   || [[ -s "$notify_log" ]]; then
  echo -e "${RED}FAIL: --dry-run --notify or a run without --notify invoked notify-send.${NC}"
  cat "$notify_log" 2>/dev/null || true
  exit 1
fi

# 4. LINUX_CLEANER_NOTIFY=1 behaves like --notify.
setup_mock_env
export MOCK_NOTIFY_LOG="$notify_log"
export MOCK_NOTIFY_EXIT=0
write_notify_stub
: > "$notify_log"
notify_env_ec=0
LINUX_CLEANER_NOTIFY=1 PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
  "$CLEANER_SH" --config "$TEST_ENV_DIR/test_cleaner.conf" --clean --force \
  < /dev/null > "$TEST_ENV_DIR/notify_env.log" 2>&1 || notify_env_ec=$?
if [[ "$notify_env_ec" -ne 0 ]] \
   || [[ "$(grep -c '^---$' "$notify_log" || true)" -ne 1 ]] \
   || ! grep -q '^--app-name=linux-cleaner linux-cleaner Result: cleaned=' "$notify_log"; then
  echo -e "${RED}FAIL: LINUX_CLEANER_NOTIFY=1 did not send the expected notification (ec=$notify_env_ec).${NC}"
  cat "$notify_log" "$TEST_ENV_DIR/notify_env.log" 2>/dev/null || true
  exit 1
fi

# 5. A notify-send stub that exits 1 leaves the exit status 0.
setup_mock_env
export MOCK_NOTIFY_LOG="$notify_log"
export MOCK_NOTIFY_EXIT=1
cat > "$TEST_ENV_DIR/bin/notify-send" <<'NOTIFY_STUB'
#!/usr/bin/env bash
echo "simulated notifier error" >&2
printf '%s\n---\n' "$*" >> "${MOCK_NOTIFY_LOG:?}"
exit "${MOCK_NOTIFY_EXIT:-0}"
NOTIFY_STUB
chmod +x "$TEST_ENV_DIR/bin/notify-send"
: > "$notify_log"
if ! run_test_case "Notify Cleanup Result (stub exits 1)" 0 "notify_stub_fail.log" \
       --config "$TEST_ENV_DIR/test_cleaner.conf" --clean --force --notify \
   || [[ "$(grep -c '^---$' "$notify_log" || true)" -ne 1 ]] \
   || grep -q "simulated notifier error" "$TEST_ENV_DIR/notify_stub_fail.log"; then
  echo -e "${RED}FAIL: a failing notify-send stub changed the exit status or leaked output.${NC}"
  cat "$TEST_ENV_DIR/notify_stub_fail.log" 2>/dev/null || true
  exit 1
fi

# 6. --notify with --report exits 1.
if ! run_test_case "Notify Cleanup Result (--notify with --report rejected)" 1 "notify_report.log" \
       --notify --report \
   || ! grep -q "notify applies only to cleanup" "$TEST_ENV_DIR/notify_report.log"; then
  echo -e "${RED}FAIL: --notify with --report did not exit 1 with mode-exclusion error.${NC}"
  cat "$TEST_ENV_DIR/notify_report.log" 2>/dev/null || true
  exit 1
fi

# 7. An inherited LINUX_CLEANER_NOTIFY is ignored by non-cleanup modes.
: > "$notify_log"
for notify_mode in --report --list-sessions; do
  notify_mode_ec=0
  LINUX_CLEANER_NOTIFY=1 PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
    "$CLEANER_SH" "$notify_mode" < /dev/null > "$TEST_ENV_DIR/notify_mode.log" 2>&1 || notify_mode_ec=$?
  if [[ "$notify_mode_ec" -ne 0 || -s "$notify_log" ]]; then
    echo -e "${RED}FAIL: LINUX_CLEANER_NOTIFY=1 broke $notify_mode (ec=$notify_mode_ec) or notified.${NC}"
    cat "$TEST_ENV_DIR/notify_mode.log" "$notify_log" 2>/dev/null || true
    exit 1
  fi
done

# 8. --clean --force --notify --trash --trash-keep-days 0 with failing retention purge records one critical notification with "Retention failed: true".
setup_mock_env
export MOCK_NOTIFY_LOG="$notify_log"
export MOCK_NOTIFY_EXIT=0
write_notify_stub
notify_ret_old="$MOCK_HOME/.cache/linux-cleaner/quarantine/2020-01-01_00-00-00"
notify_ret_target="$MOCK_HOME/.cache/notify_ret_target"
mkdir -p "$notify_ret_old" "$notify_ret_target"
printf 'old payload\n' > "$notify_ret_old/payload"
printf 'full|payload|%s/prior|false|%s|%s\n' "$MOCK_HOME" "$(id -u)" "$(id -g)" > "$notify_ret_old/quarantine.meta"
touch -d '10 days ago' "$notify_ret_old"
printf 'target payload\n' > "$notify_ret_target/file"
printf 'safe|Notify Retention Target|%s|notify retention fixture|0||\n' "$notify_ret_target" > "$TEST_ENV_DIR/notify_retention.conf"
export MOCK_NOTIFY_RET_OLD="$notify_ret_old"
cat > "$TEST_ENV_DIR/bin/rm" <<'NOTIFY_RET_RM'
#!/usr/bin/env bash
for arg; do
  [[ "$arg" == "$MOCK_NOTIFY_RET_OLD" ]] && exit 1
done
real_rm=$(PATH="${PATH#"$TEST_ENV_DIR/bin:"}" command -v rm)
exec "$real_rm" "$@"
NOTIFY_RET_RM
chmod +x "$TEST_ENV_DIR/bin/rm"
: > "$notify_log"
if ! run_test_case "Notify Cleanup Result (retention failure critical)" 1 "notify_retention.log" \
       --config "$TEST_ENV_DIR/notify_retention.conf" --clean --force --notify --trash --trash-keep-days 0 \
   || [[ "$(grep -c '^---$' "$notify_log" || true)" -ne 1 ]] \
   || ! grep -q '^--app-name=linux-cleaner --urgency=critical linux-cleaner Result: cleaned=1 skipped=0 failed=0 ' "$notify_log" \
   || ! grep -qx 'Retention failed: true' "$notify_log"; then
  unset MOCK_NOTIFY_RET_OLD
  echo -e "${RED}FAIL: --clean --force --notify --trash --trash-keep-days 0 with failing retention did not record one critical notification containing 'Retention failed: true'.${NC}"
  cat "$notify_log" "$TEST_ENV_DIR/notify_retention.log" 2>/dev/null || true
  exit 1
fi
unset MOCK_NOTIFY_RET_OLD

# 9. An interrupted cleanup with --notify records one critical notification containing "Interrupted:".
setup_mock_env
export MOCK_NOTIFY_LOG="$notify_log"
export MOCK_NOTIFY_EXIT=0
write_notify_stub
mkdir -p "$MOCK_HOME/.cache/notify_int_target"
printf 'payload\n' > "$MOCK_HOME/.cache/notify_int_target/a.txt"
printf 'safe|Notify Int Target|%s/.cache/notify_int_target|Interrupted notify fixture|0||\n' "$MOCK_HOME" > "$TEST_ENV_DIR/notify_int.conf"
cat > "$TEST_ENV_DIR/bin/rm" <<'NOTIFY_INT_RM'
#!/usr/bin/env bash
real_rm=$(PATH="${PATH#"$TEST_ENV_DIR/bin:"}" command -v rm)
for arg in "$@"; do
  case "$arg" in
    *notify_int_target*)
      "$real_rm" "$@"
      kill -TERM "$PPID"
      exit 0
      ;;
  esac
done
exec "$real_rm" "$@"
NOTIFY_INT_RM
chmod +x "$TEST_ENV_DIR/bin/rm"
: > "$notify_log"
if ! run_test_case "Notify Cleanup Result (interrupted critical)" 143 "notify_int.log" \
       --config "$TEST_ENV_DIR/notify_int.conf" --clean --force --notify \
   || [[ "$(grep -c '^---$' "$notify_log" || true)" -ne 1 ]] \
   || ! grep -q '^--app-name=linux-cleaner --urgency=critical linux-cleaner Result: cleaned=0 skipped=0 failed=0 ' "$notify_log" \
   || ! grep -qx 'Interrupted: SIGTERM before all targets finished' "$notify_log"; then
  echo -e "${RED}FAIL: interrupted cleanup with --notify did not record one critical notification containing 'Interrupted:'.${NC}"
  cat "$notify_log" "$TEST_ENV_DIR/notify_int.log" 2>/dev/null || true
  exit 1
fi

# 10. A run with notify-send absent from PATH and --notify prints "notify-send is not installed" once on stderr and exits 0.
setup_mock_env
notify_missing_bin="$TEST_ENV_DIR/notify_missing_bin"
mkdir -p "$notify_missing_bin"
for tool in bash basename cat dirname realpath sed du df awk tr id sort find stat date rm mktemp pgrep mkdir mv cp chmod rmdir cut grep flock timeout; do
  if command -v "$tool" >/dev/null 2>&1; then
    ln -s "$(command -v "$tool")" "$notify_missing_bin/$tool"
  fi
done
mkdir -p "$MOCK_HOME/.cache/notify_absent_target"
printf 'payload\n' > "$MOCK_HOME/.cache/notify_absent_target/file"
printf 'safe|Notify Absent Target|%s/.cache/notify_absent_target|Absent notify-send fixture|0||\n' "$MOCK_HOME" > "$TEST_ENV_DIR/notify_absent.conf"
notify_absent_ec=0
PATH="$notify_missing_bin" HOME="$MOCK_HOME" "$CLEANER_SH" \
  --config "$TEST_ENV_DIR/notify_absent.conf" --clean --force --notify \
  < /dev/null > "$TEST_ENV_DIR/notify_absent.out" 2> "$TEST_ENV_DIR/notify_absent.err" || notify_absent_ec=$?
if [[ "$notify_absent_ec" -ne 0 ]] \
   || [[ "$(grep -c 'notify-send is not installed' "$TEST_ENV_DIR/notify_absent.err" || true)" -ne 1 ]] \
   || grep -q 'notify-send is not installed' "$TEST_ENV_DIR/notify_absent.out"; then
  echo -e "${RED}FAIL: --notify without notify-send on PATH did not print 'notify-send is not installed' once on stderr and exit 0 (ec=$notify_absent_ec).${NC}"
  cat "$TEST_ENV_DIR/notify_absent.out" "$TEST_ENV_DIR/notify_absent.err" 2>/dev/null || true
  exit 1
fi

# 11. An opted-in cleanup that exits non-zero before reporting records one critical failure notification; dry-run records nothing.
setup_mock_env
export MOCK_NOTIFY_LOG="$notify_log"
export MOCK_NOTIFY_EXIT=0
write_notify_stub
: > "$notify_log"
notify_early_ec=0
LINUX_CLEANER_NOTIFY=1 LINUX_CLEANER_RISK=bogus PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
  "$CLEANER_SH" --config "$TEST_ENV_DIR/test_cleaner.conf" --clean --force \
  < /dev/null > "$TEST_ENV_DIR/notify_early.log" 2>&1 || notify_early_ec=$?
if [[ "$notify_early_ec" -ne 1 ]] \
   || [[ "$(grep -c '^---$' "$notify_log" || true)" -ne 1 ]] \
   || ! grep -q '^--app-name=linux-cleaner --urgency=critical linux-cleaner Cleanup stopped with exit status 1 before finishing; see journalctl --user -t linux-cleaner\.$' "$notify_log"; then
  echo -e "${RED}FAIL: LINUX_CLEANER_NOTIFY=1 LINUX_CLEANER_RISK=bogus --clean --force did not exit 1 and record one critical notification containing 'exit status 1' (ec=$notify_early_ec).${NC}"
  cat "$notify_log" "$TEST_ENV_DIR/notify_early.log" 2>/dev/null || true
  exit 1
fi
: > "$notify_log"
notify_early_dry_ec=0
LINUX_CLEANER_NOTIFY=1 LINUX_CLEANER_RISK=bogus PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
  "$CLEANER_SH" --config "$TEST_ENV_DIR/test_cleaner.conf" --dry-run \
  < /dev/null > "$TEST_ENV_DIR/notify_early_dry.log" 2>&1 || notify_early_dry_ec=$?
if [[ "$notify_early_dry_ec" -ne 1 || -s "$notify_log" ]]; then
  echo -e "${RED}FAIL: LINUX_CLEANER_NOTIFY=1 LINUX_CLEANER_RISK=bogus --dry-run did not exit 1 silently without notification (ec=$notify_early_dry_ec).${NC}"
  cat "$notify_log" "$TEST_ENV_DIR/notify_early_dry.log" 2>/dev/null || true
  exit 1
fi
unset MOCK_NOTIFY_LOG MOCK_NOTIFY_EXIT
echo -e "${GREEN}PASS: --notify and LINUX_CLEANER_NOTIFY send result notifications safely and reject non-cleanup modes.${NC}"

# Fail-fast stops only after a failed target is accounted and logged. All
# payloads, retention sessions and command stubs stay in the disposable HOME.
echo -e "\n${BOLD}Test Case: Fail Fast Cleanup${NC}"
for ff_kind in delete move action; do
  for ff_enabled in true false; do
    setup_mock_env
    ff_first="$MOCK_HOME/.cache/uv"
    ff_later="$MOCK_HOME/.cache/fail_fast_later"
    ff_old="$MOCK_HOME/.cache/linux-cleaner/quarantine/2020-01-01_00-00-00"
    mkdir -p "$ff_first" "$ff_later" "$ff_old"
    printf 'first payload\n' > "$ff_first/file"
    printf 'later payload\n' > "$ff_later/file"
    printf 'recovery payload\n' > "$ff_old/payload"
    printf 'full|payload|%s/prior|false|%s|%s\n' "$MOCK_HOME" "$(id -u)" "$(id -g)" > "$ff_old/quarantine.meta"
    touch -d '10 days ago' "$ff_old"
    ff_cmd=""
    ff_args=()
    [[ "$ff_enabled" == true ]] && ff_args+=(--fail-fast)
    case "$ff_kind" in
      delete|move)
        ff_bin="rm"
        if [[ "$ff_kind" == move ]]; then
          ff_bin="mv"
          ff_args+=(--trash)
        fi
        # Fail only this target, leaving report writes and retention functional.
        cat > "$TEST_ENV_DIR/bin/$ff_bin" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  [[ "\$arg" == "$ff_first" ]] && exit 1
done
exec /bin/$ff_bin "\$@"
EOF
        chmod +x "$TEST_ENV_DIR/bin/$ff_bin"
        ;;
      action)
        ff_cmd=action:uv_cache_prune
        printf '#!/usr/bin/env bash\nexit 1\n' > "$TEST_ENV_DIR/bin/uv"
        chmod +x "$TEST_ENV_DIR/bin/uv"
        ;;
    esac
    printf 'safe|First|%s|first fixture|0||%s\nsafe|Later|%s|later fixture|0||\n' \
      "$ff_first" "$ff_cmd" "$ff_later" > "$TEST_ENV_DIR/fail_fast.conf"
    LINUX_CLEANER_FAIL_FAST=0 run_test_case "Fail Fast Cleanup ($ff_kind enabled=$ff_enabled)" 1 "fail_fast.log" \
      --config "$TEST_ENV_DIR/fail_fast.conf" --clean --force --trash-keep-days 1 \
      --log "$MOCK_HOME/ff-operations.log" "${ff_args[@]}" || exit 1
    ff_saved="$XDG_STATE_HOME/linux-cleaner/last-report.txt"
    if [[ ! -f "$ff_first/file" ]] \
       || ! grep -q "target='First'.*outcome=failed" "$MOCK_HOME/ff-operations.log" \
       || ! grep -qx 'Failed target: First' "$ff_saved"; then
      echo -e "${RED}FAIL: $ff_kind failure lost payload, log or exact failed-target accounting.${NC}"
      exit 1
    fi
    if [[ "$ff_enabled" == true ]]; then
      if [[ ! -f "$ff_later/file" || ! -f "$ff_old/payload" ]] \
         || ! grep -q 'Result: cleaned=0 skipped=0 failed=1 ' "$ff_saved" \
         || ! grep -qx 'Stopped early: --fail-fast after First; 1 targets not attempted' "$ff_saved" \
         || ! grep -qx 'Stopped early: --fail-fast after First; 1 targets not attempted' "$TEST_ENV_DIR/fail_fast.log" \
         || grep -q '^Retention failed:' "$ff_saved" \
         || grep -q "target='Later'" "$MOCK_HOME/ff-operations.log"; then
        echo -e "${RED}FAIL: --fail-fast after $ff_kind failure touched later work or lost the stop report.${NC}"
        exit 1
      fi
    elif [[ -e "$ff_later" || -e "$ff_old" ]] \
         || ! grep -q 'Result: cleaned=1 skipped=0 failed=1 ' "$ff_saved" \
         || grep -q '^Stopped early:' "$ff_saved" \
         || ! grep -qx 'Retention failed: false' "$ff_saved"; then
      echo -e "${RED}FAIL: cleanup without --fail-fast no longer continues targets and retention.${NC}"
      exit 1
    fi
  done
done

# Match notify's exact truthy set, including uppercase values on Turkish hosts;
# the inherited modifier also appears in the dry-run Next command.
setup_mock_env
for ff_value in 1 true TRUE yes YES 0 false; do
  ff_ec=0
  LINUX_CLEANER_FAIL_FAST="$ff_value" PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
    "$CLEANER_SH" --config "$TEST_ENV_DIR/test_cleaner.conf" --dry-run \
    < /dev/null > "$TEST_ENV_DIR/ff_env_preview.log" 2>&1 || ff_ec=$?
  ff_hint=false
  grep -q '^  cleaner --clean .*--fail-fast' "$TEST_ENV_DIR/ff_env_preview.log" && ff_hint=true
  ff_expected=true
  case "$ff_value" in 0|false) ff_expected=false ;; esac
  if [[ "$ff_ec" -ne 0 || "$ff_hint" != "$ff_expected" ]]; then
    echo -e "${RED}FAIL: LINUX_CLEANER_FAIL_FAST=$ff_value preview hint drifted.${NC}"
    exit 1
  fi
done
run_test_case "Fail Fast Cleanup (CLI preview)" 0 "ff_preview.log" \
  --config "$TEST_ENV_DIR/test_cleaner.conf" --dry-run --fail-fast || exit 1
grep -q '^  cleaner --clean .*--fail-fast' "$TEST_ENV_DIR/ff_preview.log" || exit 1

# The final target's failure still skips retention, with no remaining targets.
ff_old="$MOCK_HOME/.cache/linux-cleaner/quarantine/2020-01-01_00-00-00"
mkdir -p "$ff_old" "$MOCK_HOME/.cache/uv"
printf 'recovery\n' > "$ff_old/payload"
printf 'full|payload|%s/prior|false|%s|%s\n' "$MOCK_HOME" "$(id -u)" "$(id -g)" > "$ff_old/quarantine.meta"
touch -d '10 days ago' "$ff_old"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TEST_ENV_DIR/bin/uv"
chmod +x "$TEST_ENV_DIR/bin/uv"
cat > "$TEST_ENV_DIR/bin/notify-send" <<'FF_NOTIFY'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_ENV_DIR/ff_notification.log"
FF_NOTIFY
chmod +x "$TEST_ENV_DIR/bin/notify-send"
printf 'safe|Last|%s/.cache/uv|last fixture|0||action:uv_cache_prune\n' "$MOCK_HOME" > "$TEST_ENV_DIR/ff_last.conf"
LINUX_CLEANER_FAIL_FAST=1 LINUX_CLEANER_METRICS_FILE="$MOCK_HOME/ff.prom" \
  run_test_case "Fail Fast Cleanup (inherited, final target)" 1 "ff_last.log" \
  --config "$TEST_ENV_DIR/ff_last.conf" --clean --force --notify --trash-keep-days 1 || exit 1
if [[ ! -f "$ff_old/payload" ]] \
   || ! grep -qx 'Stopped early: --fail-fast after Last; 0 targets not attempted' "$TEST_ENV_DIR/ff_last.log" \
   || [[ "$(grep -c '^--app-name=' "$TEST_ENV_DIR/ff_notification.log" || true)" -ne 1 ]] \
   || ! grep -q '^--app-name=linux-cleaner --urgency=critical linux-cleaner Result: cleaned=0 skipped=0 failed=1 ' "$TEST_ENV_DIR/ff_notification.log" \
   || ! grep -q '^Reclaimed:' "$TEST_ENV_DIR/ff_notification.log" \
   || grep -q '^Stopped early:' "$TEST_ENV_DIR/ff_notification.log" \
   || ! grep -qx 'linux_cleaner_last_run_success 0' "$MOCK_HOME/ff.prom" \
   || ! grep -qx 'linux_cleaner_targets{result="failed"} 1' "$MOCK_HOME/ff.prom"; then
  echo -e "${RED}FAIL: inherited fail-fast lost retention protection, notification or metrics accounting.${NC}"
  exit 1
fi

# Unsafe and process-blocked targets are skips; the later target still cleans.
setup_mock_env
mkdir -p "$MOCK_HOME/.cache/ff_blocked" "$MOCK_HOME/.cache/ff_safe"
printf 'blocked\n' > "$MOCK_HOME/.cache/ff_blocked/file"
printf 'cleanable\n' > "$MOCK_HOME/.cache/ff_safe/file"
printf 'safe|Unsafe|/|unsafe fixture|0||\nsafe|Blocked|%s/.cache/ff_blocked|blocked fixture|0|mock_running_pr|\nsafe|Safe|%s/.cache/ff_safe|safe fixture|0||\n' \
  "$MOCK_HOME" "$MOCK_HOME" > "$TEST_ENV_DIR/ff_skips.conf"
run_test_case "Fail Fast Cleanup (safety skip and blocked target)" 0 "ff_skips.log" \
  --config "$TEST_ENV_DIR/ff_skips.conf" --clean --force --fail-fast || exit 1
if [[ ! -f "$MOCK_HOME/.cache/ff_blocked/file" || -e "$MOCK_HOME/.cache/ff_safe" ]] \
   || ! grep -q 'Result: cleaned=1 skipped=.*failed=0 ' "$TEST_ENV_DIR/ff_skips.log" \
   || grep -q '^Stopped early:' "$TEST_ENV_DIR/ff_skips.log"; then
  echo -e "${RED}FAIL: --fail-fast stopped on a safety skip or blocked target.${NC}"
  exit 1
fi

# Inherited automation defaults must not reject non-cleanup commands, including
# the hold/release guard; explicit combinations are covered by the pair matrix.
for ff_mode in --check-config --list-targets --list-sessions --report; do
  LINUX_CLEANER_FAIL_FAST=1 run_test_case "Fail Fast Cleanup (inherited $ff_mode)" 0 "ff_mode.log" \
    --config "$TEST_ENV_DIR/test_cleaner.conf" "$ff_mode" || exit 1
done
ff_session=2020-01-01_00-00-00
mkdir -p "$MOCK_HOME/.cache/linux-cleaner/quarantine/$ff_session"
for ff_mode in --hold-session --release-session; do
  LINUX_CLEANER_FAIL_FAST=1 run_test_case "Fail Fast Cleanup (inherited $ff_mode)" 0 "ff_hold.log" \
    "$ff_mode" "$ff_session" || exit 1
done
echo -e "${GREEN}PASS: fail-fast preserves later targets and retention after failures and ignores skips.${NC}"

# Confirmed manual cleanup prints a tip when linux-cleaner-clean.timer is
# installed but disabled; forced, quiet, failed, timer-enabled, and
# unit-absent/no-systemctl runs stay silent.
echo -e "\n${BOLD}Test Case: Daily Timer Tip${NC}"
setup_mock_env
timer_tip_line="Tip: run this cleanup daily with 'systemctl --user enable --now linux-cleaner-clean.timer'."
timer_tip_trash_line="The timer deletes permanently unless LINUX_CLEANER_TRASH=1 is set in ~/.config/linux-cleaner/env."
write_timer_tip_fixture() {
  mkdir -p "$MOCK_HOME/.cache/timer_tip_target"
  printf 'payload\n' > "$MOCK_HOME/.cache/timer_tip_target/file.txt"
  printf 'safe|Timer Tip Target|%s/.cache/timer_tip_target|Timer tip fixture|0||\n' "$MOCK_HOME" > "$TEST_ENV_DIR/timer_tip.conf"
}
write_systemctl_state_stub() {
  local state="$1" rc="$2"
  cat > "$TEST_ENV_DIR/bin/systemctl" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == "--user is-enabled linux-cleaner-clean.timer" ]]; then
  echo "$state"
  exit $rc
fi
echo "unexpected: \$*" >&2
exit 2
EOF
  chmod +x "$TEST_ENV_DIR/bin/systemctl"
}

# 1. Default setup_mock_env stub (not-found, exit 4) prints no tip on confirmed --clean.
write_timer_tip_fixture
tip_nf_ec=0
PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" "$CLEANER_SH" \
  --config "$TEST_ENV_DIR/timer_tip.conf" --clean \
  < <(printf 'y\n') > "$TEST_ENV_DIR/timer_tip_nf.log" 2>&1 || tip_nf_ec=$?
if [[ "$tip_nf_ec" -ne 0 ]] || grep -qF "$timer_tip_line" "$TEST_ENV_DIR/timer_tip_nf.log"; then
  echo -e "${RED}FAIL: default not-found systemctl stub printed the daily timer tip or failed (ec=$tip_nf_ec).${NC}"
  cat "$TEST_ENV_DIR/timer_tip_nf.log" 2>/dev/null || true
  exit 1
fi

# 2. Stub printing disabled on confirmed --clean prints the tip exactly once.
write_systemctl_state_stub disabled 1
write_timer_tip_fixture
tip_dis_ec=0
PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" "$CLEANER_SH" \
  --config "$TEST_ENV_DIR/timer_tip.conf" --clean \
  < <(printf 'y\n') > "$TEST_ENV_DIR/timer_tip_disabled.log" 2>&1 || tip_dis_ec=$?
if [[ "$tip_dis_ec" -ne 0 ]] \
   || [[ "$(grep -cxF "$timer_tip_line" "$TEST_ENV_DIR/timer_tip_disabled.log" || true)" -ne 1 ]] \
   || grep -qF "$timer_tip_trash_line" "$TEST_ENV_DIR/timer_tip_disabled.log"; then
  echo -e "${RED}FAIL: confirmed --clean with disabled timer did not print the daily timer tip once or printed the trash warning (ec=$tip_dis_ec).${NC}"
  cat "$TEST_ENV_DIR/timer_tip_disabled.log" 2>/dev/null || true
  exit 1
fi

# 3. Stub printing enabled on confirmed --clean prints nothing.
write_systemctl_state_stub enabled 0
write_timer_tip_fixture
tip_en_ec=0
PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" "$CLEANER_SH" \
  --config "$TEST_ENV_DIR/timer_tip.conf" --clean \
  < <(printf 'y\n') > "$TEST_ENV_DIR/timer_tip_enabled.log" 2>&1 || tip_en_ec=$?
if [[ "$tip_en_ec" -ne 0 ]] || grep -qF "$timer_tip_line" "$TEST_ENV_DIR/timer_tip_enabled.log"; then
  echo -e "${RED}FAIL: confirmed --clean with enabled timer printed the daily timer tip or failed (ec=$tip_en_ec).${NC}"
  cat "$TEST_ENV_DIR/timer_tip_enabled.log" 2>/dev/null || true
  exit 1
fi

# 4. With disabled stub, --clean --force and confirmed --clean --quiet print nothing.
write_systemctl_state_stub disabled 1
write_timer_tip_fixture
if ! run_test_case "Daily Timer Tip (--force silent)" 0 "timer_tip_force.log" \
       --config "$TEST_ENV_DIR/timer_tip.conf" --clean --force \
   || grep -qF "$timer_tip_line" "$TEST_ENV_DIR/timer_tip_force.log"; then
  echo -e "${RED}FAIL: --clean --force with disabled timer printed the daily timer tip.${NC}"
  cat "$TEST_ENV_DIR/timer_tip_force.log" 2>/dev/null || true
  exit 1
fi
write_timer_tip_fixture
tip_quiet_ec=0
PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" "$CLEANER_SH" \
  --config "$TEST_ENV_DIR/timer_tip.conf" --clean --quiet \
  < <(printf 'y\n') > "$TEST_ENV_DIR/timer_tip_quiet.log" 2>&1 || tip_quiet_ec=$?
if [[ "$tip_quiet_ec" -ne 0 ]] || grep -qF "$timer_tip_line" "$TEST_ENV_DIR/timer_tip_quiet.log"; then
  echo -e "${RED}FAIL: confirmed --clean --quiet with disabled timer printed the daily timer tip or failed (ec=$tip_quiet_ec).${NC}"
  cat "$TEST_ENV_DIR/timer_tip_quiet.log" 2>/dev/null || true
  exit 1
fi

# 5. A failing target on confirmed --clean with disabled stub prints no tip.
cat > "$TEST_ENV_DIR/bin/uv" <<'FAIL_TIMER_UV'
#!/usr/bin/env bash
exit 1
FAIL_TIMER_UV
chmod +x "$TEST_ENV_DIR/bin/uv"
mkdir -p "$MOCK_HOME/.cache/uv"
printf 'safe|UV Cache|%s/.cache/uv|Failing UV cache|0||action:uv_cache_prune\n' "$MOCK_HOME" > "$TEST_ENV_DIR/timer_tip_fail.conf"
tip_fail_ec=0
PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" "$CLEANER_SH" \
  --config "$TEST_ENV_DIR/timer_tip_fail.conf" --clean \
  < <(printf 'y\n') > "$TEST_ENV_DIR/timer_tip_fail.log" 2>&1 || tip_fail_ec=$?
if [[ "$tip_fail_ec" -ne 1 ]] || grep -qF "$timer_tip_line" "$TEST_ENV_DIR/timer_tip_fail.log"; then
  echo -e "${RED}FAIL: failing confirmed --clean with disabled timer printed the daily timer tip or returned unexpected exit code (ec=$tip_fail_ec).${NC}"
  cat "$TEST_ENV_DIR/timer_tip_fail.log" 2>/dev/null || true
  exit 1
fi

# 6. Confirmed --clean --trash with disabled stub prints the tip and the env warning once each.
write_systemctl_state_stub disabled 1
write_timer_tip_fixture
tip_trash_ec=0
PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" "$CLEANER_SH" \
  --config "$TEST_ENV_DIR/timer_tip.conf" --clean --trash \
  < <(printf 'y\n') > "$TEST_ENV_DIR/timer_tip_trash.log" 2>&1 || tip_trash_ec=$?
if [[ "$tip_trash_ec" -ne 0 ]] \
   || [[ "$(grep -cxF "$timer_tip_line" "$TEST_ENV_DIR/timer_tip_trash.log" || true)" -ne 1 ]] \
   || [[ "$(grep -cxF "$timer_tip_trash_line" "$TEST_ENV_DIR/timer_tip_trash.log" || true)" -ne 1 ]]; then
  echo -e "${RED}FAIL: confirmed --clean --trash with disabled timer did not print the daily timer tip and trash warning once (ec=$tip_trash_ec).${NC}"
  cat "$TEST_ENV_DIR/timer_tip_trash.log" 2>/dev/null || true
  exit 1
fi

# 7. Declining all targets with --interactive on disabled stub cleans nothing and prints no tip.
write_systemctl_state_stub disabled 1
write_timer_tip_fixture
tip_interactive_ec=0
PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" "$CLEANER_SH" \
  --config "$TEST_ENV_DIR/timer_tip.conf" --clean --interactive \
  < <(printf 'n\n') > "$TEST_ENV_DIR/timer_tip_interactive.log" 2>&1 || tip_interactive_ec=$?
if [[ "$tip_interactive_ec" -ne 0 ]] || grep -qF "$timer_tip_line" "$TEST_ENV_DIR/timer_tip_interactive.log"; then
  echo -e "${RED}FAIL: --interactive declining targets printed the daily timer tip or failed (ec=$tip_interactive_ec).${NC}"
  cat "$TEST_ENV_DIR/timer_tip_interactive.log" 2>/dev/null || true
  exit 1
fi

# 8. Confirmed --clean with disabled stub but PATH lacking systemctl prints no tip.
write_systemctl_state_stub disabled 1
write_timer_tip_fixture
tip_nosys_bin="$TEST_ENV_DIR/tip_nosys_bin"
rm -rf "$tip_nosys_bin"
mkdir -p "$tip_nosys_bin"
for tool in bash basename cat dirname realpath sed du df awk tr id sort find stat date rm mktemp pgrep mkdir mv cp chmod rmdir cut grep flock timeout; do
  if command -v "$tool" >/dev/null 2>&1; then
    ln -s "$(command -v "$tool")" "$tip_nosys_bin/$tool"
  fi
done
for f in "$TEST_ENV_DIR/bin"/*; do
  if [[ -f "$f" && "$(basename "$f")" != "systemctl" && ! -e "$tip_nosys_bin/$(basename "$f")" ]]; then
    ln -s "$f" "$tip_nosys_bin/$(basename "$f")"
  fi
done
tip_nosys_ec=0
PATH="$tip_nosys_bin" HOME="$MOCK_HOME" "$CLEANER_SH" \
  --config "$TEST_ENV_DIR/timer_tip.conf" --clean \
  < <(printf 'y\n') > "$TEST_ENV_DIR/timer_tip_nosys.log" 2>&1 || tip_nosys_ec=$?
if [[ "$tip_nosys_ec" -ne 0 ]] || grep -qF "$timer_tip_line" "$TEST_ENV_DIR/timer_tip_nosys.log"; then
  echo -e "${RED}FAIL: confirmed --clean without systemctl on PATH printed the daily timer tip or failed (ec=$tip_nosys_ec).${NC}"
  cat "$TEST_ENV_DIR/timer_tip_nosys.log" 2>/dev/null || true
  exit 1
fi
rm -rf "$tip_nosys_bin"

echo -e "${GREEN}PASS: confirmed manual cleanup suggests enabling linux-cleaner-clean.timer only when disabled and silent otherwise.${NC}"

# Preview from a shared config suggests initializing user config when none exists.
unset LINUX_CLEANER_CONFIG 2>/dev/null || true
setup_mock_env
tip_xdg="$TEST_ENV_DIR/init_tip_xdg"
rm -rf "$tip_xdg"
mkdir -p "$tip_xdg"
expected_tip="Customize: run 'cleaner --init-config' to copy this config to $tip_xdg/linux-cleaner/cleaner.conf and edit it."
if XDG_CONFIG_HOME="$tip_xdg" run_test_case "Init Config Preview Tip" 0 "init_tip.log" \
     --dry-run \
   && [[ "$(grep -cxF "$expected_tip" "$TEST_ENV_DIR/init_tip.log" || true)" -eq 1 ]] \
   && [[ "$(grep -c "Customize: run 'cleaner --init-config'" "$TEST_ENV_DIR/init_tip.log" || true)" -eq 1 ]] \
   && XDG_CONFIG_HOME="$tip_xdg" run_test_case "Init Config Preview Tip Explicit Config Control" 0 "init_tip_explicit.log" \
     -c "$TEST_ENV_DIR/test_cleaner.conf" --dry-run \
   && ! grep -qF "Customize: run 'cleaner --init-config'" "$TEST_ENV_DIR/init_tip_explicit.log" \
   && LINUX_CLEANER_CONFIG="$TEST_ENV_DIR/test_cleaner.conf" XDG_CONFIG_HOME="$tip_xdg" \
     run_test_case "Init Config Preview Tip Env Config Control" 0 "init_tip_env.log" \
     --dry-run \
   && ! grep -qF "Customize: run 'cleaner --init-config'" "$TEST_ENV_DIR/init_tip_env.log" \
   && XDG_CONFIG_HOME="$tip_xdg" run_test_case "Init Config Preview Tip Quiet Control" 0 "init_tip_quiet.log" \
     --dry-run --quiet \
   && ! grep -qF "Customize: run 'cleaner --init-config'" "$TEST_ENV_DIR/init_tip_quiet.log" \
   && mkdir -p "$tip_xdg/linux-cleaner" \
   && cp "$TEST_ENV_DIR/test_cleaner.conf" "$tip_xdg/linux-cleaner/cleaner.conf" \
   && XDG_CONFIG_HOME="$tip_xdg" run_test_case "Init Config Preview Tip User Config Control" 0 "init_tip_user.log" \
     --dry-run \
   && ! grep -qF "Customize: run 'cleaner --init-config'" "$TEST_ENV_DIR/init_tip_user.log"; then
  echo -e "${GREEN}PASS: preview from shared config suggests --init-config; controls suppress the tip.${NC}"
else
  echo -e "${RED}FAIL: init-config preview tip did not appear once or controls printed the tip.${NC}"
  cat "$TEST_ENV_DIR/init_tip.log" "$TEST_ENV_DIR/init_tip_explicit.log" "$TEST_ENV_DIR/init_tip_env.log" "$TEST_ENV_DIR/init_tip_quiet.log" "$TEST_ENV_DIR/init_tip_user.log" 2>/dev/null || true
  exit 1
fi
rm -rf "$tip_xdg"

# Preview metrics are opt-in, dry-run only, and keep last-cleanup metrics separate.
echo -e "\n${BOLD}Test Case: Prometheus Preview Metrics Dry Run${NC}"
setup_mock_env
preview_dir="$TEST_ENV_DIR/preview-metrics"
preview_file="$preview_dir/preview.prom"
mkdir -p "$preview_dir" "$MOCK_HOME/.cache/preview_target"
truncate -s 2049 "$MOCK_HOME/.cache/preview_target/file.txt"
printf 'safe|Preview Target|%s/.cache/preview_target/file.txt|Preview metrics test|0||\n' "$MOCK_HOME" > "$TEST_ENV_DIR/preview.conf"

for preview_format in text json; do
  preview_args=(--dry-run)
  [[ "$preview_format" == json ]] && preview_args+=(--json)
  if ! LINUX_CLEANER_PREVIEW_METRICS_FILE="$preview_file" \
       LINUX_CLEANER_METRICS_FILE="$preview_dir/cleanup.prom" \
       run_test_case "Prometheus Preview Metrics $preview_format" 0 "preview_$preview_format.log" \
         --config "$TEST_ENV_DIR/preview.conf" "${preview_args[@]}" \
     || ! python3 - "$preview_file" "$TEST_ENV_DIR/preview_$preview_format.log" "$preview_format" <<'PREVIEW_PY'
import json, pathlib, re, sys, time
path = pathlib.Path(sys.argv[1])
assert path.is_file() and not path.is_symlink()
lines = path.read_text(encoding="utf-8").splitlines()
gauges = dict(line.split() for line in lines if not line.startswith("#"))
expected = {"linux_cleaner_preview_timestamp_seconds", "linux_cleaner_preview_reclaimable_bytes",
            "linux_cleaner_preview_would_skip"}
assert set(gauges) == expected, gauges
for name in expected:
    assert f"# TYPE {name} gauge" in lines, lines
    assert any(line.startswith(f"# HELP {name} ") for line in lines), lines
assert re.fullmatch(r"[1-9][0-9]*", gauges["linux_cleaner_preview_timestamp_seconds"])
assert abs(time.time() - int(gauges["linux_cleaner_preview_timestamp_seconds"])) < 60
assert gauges["linux_cleaner_preview_reclaimable_bytes"] == "2049", gauges
assert gauges["linux_cleaner_preview_would_skip"] == "0", gauges
if sys.argv[3] == "json":
    report = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
    assert report["total_reclaimable_bytes"] == int(gauges["linux_cleaner_preview_reclaimable_bytes"])
    assert report["would_skip"] is None, report
assert not list(path.parent.glob(".linux-cleaner-metrics.*"))
assert not (path.parent / "cleanup.prom").exists()
PREVIEW_PY
  then
    echo -e "${RED}FAIL: $preview_format preview metrics did not match the dry run.${NC}"
    exit 1
  fi
done

# Threshold and nothing-to-clean verdicts must match the JSON preview.
for preview_gate in reclaim free empty; do
  # Each verdict must write its own file, never pass on the previous case's.
  rm -f "$preview_file"
  preview_args=(--config "$TEST_ENV_DIR/preview.conf" --dry-run --json)
  preview_bytes=2049
  case "$preview_gate" in
    reclaim) preview_args+=(--min-reclaim 1G) ;;
    free) preview_args+=(--min-free 1) ;;
    empty)
      printf '# No targets\n' > "$TEST_ENV_DIR/preview_empty.conf"
      preview_args=(--config "$TEST_ENV_DIR/preview_empty.conf" --dry-run --json)
      preview_bytes=0
      ;;
  esac
  if ! LINUX_CLEANER_PREVIEW_METRICS_FILE="$preview_file" \
       run_test_case "Prometheus Preview Skip $preview_gate" 0 "preview_skip.log" "${preview_args[@]}" \
     || ! grep -qx "linux_cleaner_preview_reclaimable_bytes $preview_bytes" "$preview_file" \
     || ! grep -qx 'linux_cleaner_preview_would_skip 1' "$preview_file" \
     || ! python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["would_skip"] is not None' "$TEST_ENV_DIR/preview_skip.log"; then
    echo -e "${RED}FAIL: preview skip metrics did not match $preview_gate verdict.${NC}"
    exit 1
  fi
done
rm -f "$preview_file"

for preview_bad_path in "relative-preview.prom" "$preview_dir/line"$'\n'"feed.prom" "$preview_dir/missing/preview.prom" "$preview_dir"; do
  if ! LINUX_CLEANER_PREVIEW_METRICS_FILE="$preview_bad_path" \
       run_test_case "Prometheus Preview Invalid Path" 0 "preview_invalid.log" \
         --config "$TEST_ENV_DIR/preview.conf" --dry-run \
     || ! grep -q 'Warning:' "$TEST_ENV_DIR/preview_invalid.log" \
     || [[ -e "$preview_file" ]] \
     || { [[ "$preview_bad_path" != "$preview_dir" ]] && [[ -e "$preview_bad_path" ]]; }; then
    echo -e "${RED}FAIL: invalid preview metrics path was not refused.${NC}"
    exit 1
  fi
done

printf 'keep target intact\n' > "$preview_dir/sentinel"
ln -s "$preview_dir/sentinel" "$preview_file"
ln -s "$preview_dir" "$TEST_ENV_DIR/preview-link"
for preview_bad_path in "$preview_file" "$TEST_ENV_DIR/preview-link/parent.prom"; do
  if ! LINUX_CLEANER_PREVIEW_METRICS_FILE="$preview_bad_path" \
       run_test_case "Prometheus Preview Symlink Refused" 0 "preview_symlink.log" \
         --config "$TEST_ENV_DIR/preview.conf" --dry-run \
     || ! grep -q 'Warning:.*symlink' "$TEST_ENV_DIR/preview_symlink.log" \
     || [[ ! -L "$preview_file" || -e "$preview_dir/parent.prom" ]] \
     || [[ "$(cat "$preview_dir/sentinel")" != 'keep target intact' ]]; then
    echo -e "${RED}FAIL: symlinked preview path was not refused safely.${NC}"
    exit 1
  fi
done
rm -f "$preview_file"
for preview_collision in absent existing; do
  [[ "$preview_collision" == existing ]] && cp "$preview_dir/sentinel" "$preview_file"
  if ! LINUX_CLEANER_PREVIEW_METRICS_FILE="$preview_file" LINUX_CLEANER_METRICS_FILE="$preview_file" \
       run_test_case "Prometheus Preview Collision $preview_collision" 0 "preview_collision.log" \
         --config "$TEST_ENV_DIR/preview.conf" --dry-run \
     || ! grep -q 'Warning:.*equals LINUX_CLEANER_METRICS_FILE' "$TEST_ENV_DIR/preview_collision.log" \
     || { [[ "$preview_collision" == absent ]] && [[ -e "$preview_file" ]]; } \
     || { [[ "$preview_collision" == existing ]] && ! cmp -s "$preview_file" "$preview_dir/sentinel"; }; then
    echo -e "${RED}FAIL: colliding preview path was not refused safely.${NC}"
    exit 1
  fi
done
# A second spelling of the same cleanup file is the same collision, existing or not.
for preview_alias in existing absent; do
  rm -f "$preview_file"
  [[ "$preview_alias" == existing ]] && cp "$preview_dir/sentinel" "$preview_file"
  if ! LINUX_CLEANER_PREVIEW_METRICS_FILE="$(dirname -- "$preview_file")//$(basename -- "$preview_file")" \
       LINUX_CLEANER_METRICS_FILE="$preview_file" \
       run_test_case "Prometheus Preview Collision alias $preview_alias" 0 "preview_collision.log" \
         --config "$TEST_ENV_DIR/preview.conf" --dry-run \
     || ! grep -q 'Warning:.*equals LINUX_CLEANER_METRICS_FILE' "$TEST_ENV_DIR/preview_collision.log" \
     || { [[ "$preview_alias" == existing ]] && ! cmp -s "$preview_file" "$preview_dir/sentinel"; } \
     || { [[ "$preview_alias" == absent ]] && [[ -e "$preview_file" ]]; }; then
    echo -e "${RED}FAIL: an aliased preview path ($preview_alias) overwrote the cleanup metrics file.${NC}"
    exit 1
  fi
done
rm -f "$preview_file"
unset LINUX_CLEANER_PREVIEW_METRICS_FILE
if ! run_test_case "Prometheus Preview Unset" 0 "preview_unset.log" --config "$TEST_ENV_DIR/preview.conf" --dry-run \
   || ! LINUX_CLEANER_PREVIEW_METRICS_FILE="$preview_file" \
     run_test_case "Prometheus Preview Force Ignored" 0 "preview_force.log" --config "$TEST_ENV_DIR/preview.conf" --force \
   || [[ -e "$preview_file" ]]; then
  echo -e "${RED}FAIL: unset preview variable or mutating cleanup wrote preview metrics.${NC}"
  exit 1
fi
for preview_mode in --list-targets --list-sessions --report --check-config; do
  if ! LINUX_CLEANER_PREVIEW_METRICS_FILE="$preview_file" \
       run_test_case "Prometheus Preview Ignored $preview_mode" 0 "preview_mode.log" \
         --config "$TEST_ENV_DIR/preview.conf" "$preview_mode" \
     || [[ -e "$preview_file" ]]; then
    echo -e "${RED}FAIL: $preview_mode wrote preview metrics.${NC}"
    exit 1
  fi
done
echo -e "${GREEN}PASS: preview metrics are dry-run only, match the plan, and reject unsafe or colliding paths.${NC}"

# LINUX_CLEANER_METRICS_FILE: write an atomic Prometheus node_exporter textfile
# at every cleanup exit matching last-report.txt, refuse relative/LF/symlinked
# paths with a warning without failing the run, and write nothing on dry-run,
# read-only modes, or when unset.
echo -e "\n${BOLD}Test Case: Prometheus Textfile Metrics${NC}"
setup_mock_env
metrics_dir="$TEST_ENV_DIR/metrics"
mkdir -p "$metrics_dir" "$MOCK_HOME/.cache/metrics_target"
metrics_file="$metrics_dir/linux_cleaner.prom"
truncate -s 2049 "$MOCK_HOME/.cache/metrics_target/file.txt"
cat > "$TEST_ENV_DIR/metrics.conf" <<EOF
safe|Metrics Target|$MOCK_HOME/.cache/metrics_target/file.txt|Metrics test target|0||
EOF

# 1. Completed run writes a valid textfile matching last-report.txt.
if ! LINUX_CLEANER_METRICS_FILE="$metrics_file" \
     run_test_case "Prometheus Metrics Completed Run" 0 "metrics_completed.log" \
       --config "$TEST_ENV_DIR/metrics.conf" --clean --trash --force \
   || ! run_test_case "Prometheus Metrics Completed Report JSON" 0 "metrics_completed.json" --report --json \
   || ! python3 - "$metrics_file" "$TEST_ENV_DIR/metrics_completed.json" <<'METRICS_PY'
import json, pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
report = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
lines = text.splitlines()
assert "# HELP linux_cleaner_last_run_timestamp_seconds" in text
assert "# TYPE linux_cleaner_last_run_timestamp_seconds gauge" in lines
assert "# HELP linux_cleaner_last_run_success" in text
assert "# TYPE linux_cleaner_last_run_success gauge" in lines
assert "# HELP linux_cleaner_targets" in text
assert "# TYPE linux_cleaner_targets gauge" in lines
assert "# HELP linux_cleaner_reclaimed_bytes" in text
assert "# TYPE linux_cleaner_reclaimed_bytes gauge" in lines
assert any(re.match(r"^linux_cleaner_last_run_timestamp_seconds [1-9][0-9]*$", l) for l in lines), lines
assert "linux_cleaner_last_run_success 1" in lines, lines
assert f'linux_cleaner_targets{{result="cleaned"}} {report["cleaned"]}' in lines, (lines, report)
assert f'linux_cleaner_targets{{result="skipped"}} {report["skipped"]}' in lines, (lines, report)
assert f'linux_cleaner_targets{{result="failed"}} {report["failed"]}' in lines, (lines, report)
assert f'linux_cleaner_reclaimed_bytes{{kind="quarantined"}} {report["quarantined_bytes"]}' in lines, (lines, report)
assert f'linux_cleaner_reclaimed_bytes{{kind="permanent"}} {report["permanent_bytes"]}' in lines, (lines, report)
assert report["quarantined_bytes"] == 2049 and report["permanent_bytes"] == 0, report
assert not list(pathlib.Path(sys.argv[1]).parent.glob(".linux-cleaner-metrics.*"))
METRICS_PY
then
  echo -e "${RED}FAIL: completed cleanup did not write expected Prometheus metrics matching last-report.txt.${NC}"
  cat "$metrics_file" "$TEST_ENV_DIR/metrics_completed.log" 2>/dev/null || true
  exit 1
fi
echo -e "${GREEN}PASS: completed cleanup writes Prometheus metrics matching last-report.txt.${NC}"

# 2. Nothing-to-clean exit writes 0 counts/bytes and success 1.
rm -f "$metrics_file"
if ! LINUX_CLEANER_METRICS_FILE="$metrics_file" \
     run_test_case "Prometheus Metrics Nothing To Clean" 0 "metrics_nothing.log" \
       --config "$TEST_ENV_DIR/metrics.conf" --clean --force \
   || ! grep -qx 'linux_cleaner_last_run_success 1' "$metrics_file" \
   || ! grep -qx 'linux_cleaner_targets{result="cleaned"} 0' "$metrics_file" \
   || ! grep -qx 'linux_cleaner_targets{result="skipped"} 0' "$metrics_file" \
   || ! grep -qx 'linux_cleaner_targets{result="failed"} 0' "$metrics_file" \
   || ! grep -qx 'linux_cleaner_reclaimed_bytes{kind="quarantined"} 0' "$metrics_file" \
   || ! grep -qx 'linux_cleaner_reclaimed_bytes{kind="permanent"} 0' "$metrics_file"; then
  echo -e "${RED}FAIL: nothing-to-clean exit did not write zeroed Prometheus metrics with success 1.${NC}"
  cat "$metrics_file" "$TEST_ENV_DIR/metrics_nothing.log" 2>/dev/null || true
  exit 1
fi
echo -e "${GREEN}PASS: nothing-to-clean cleanup exit writes zeroed Prometheus metrics with success 1.${NC}"

# 3. Failed target writes linux_cleaner_last_run_success 0 and failed=1.
cat > "$TEST_ENV_DIR/bin/uv" <<'FAIL_METRICS_UV'
#!/usr/bin/env bash
exit 1
FAIL_METRICS_UV
chmod +x "$TEST_ENV_DIR/bin/uv"
mkdir -p "$MOCK_HOME/.cache/uv"
printf 'safe|UV Cache|%s/.cache/uv|Failing UV cache|0||action:uv_cache_prune\n' "$MOCK_HOME" > "$TEST_ENV_DIR/metrics_fail.conf"
rm -f "$metrics_file"
if ! LINUX_CLEANER_METRICS_FILE="$metrics_file" \
     run_test_case "Prometheus Metrics Failed Target" 1 "metrics_failed.log" \
       --config "$TEST_ENV_DIR/metrics_fail.conf" --clean --force \
   || ! grep -qx 'linux_cleaner_last_run_success 0' "$metrics_file" \
   || ! grep -qx 'linux_cleaner_targets{result="cleaned"} 0' "$metrics_file" \
   || ! grep -qx 'linux_cleaner_targets{result="failed"} 1' "$metrics_file"; then
  echo -e "${RED}FAIL: failed target cleanup did not write linux_cleaner_last_run_success 0 and failed=1.${NC}"
  cat "$metrics_file" "$TEST_ENV_DIR/metrics_failed.log" 2>/dev/null || true
  exit 1
fi
echo -e "${GREEN}PASS: failed target cleanup writes linux_cleaner_last_run_success 0 and failed=1.${NC}"

# 4. Invalid relative path or line feed warns and does not fail the run or write a file.
truncate -s 512 "$MOCK_HOME/.cache/metrics_target/file.txt"
rm -f "$metrics_file"
if ! LINUX_CLEANER_METRICS_FILE="relative/metrics.prom" \
     run_test_case "Prometheus Metrics Relative Path Warning" 0 "metrics_rel.log" \
       --config "$TEST_ENV_DIR/metrics.conf" --clean --force \
   || ! grep -q "Warning: LINUX_CLEANER_METRICS_FILE must be a literal absolute file path without line feeds" "$TEST_ENV_DIR/metrics_rel.log" \
   || [[ -e "relative/metrics.prom" ]]; then
  echo -e "${RED}FAIL: relative LINUX_CLEANER_METRICS_FILE did not warn and succeed without writing.${NC}"
  cat "$TEST_ENV_DIR/metrics_rel.log" 2>/dev/null || true
  exit 1
fi
if ! LINUX_CLEANER_METRICS_FILE="$metrics_file"$'\n/evil' \
     run_test_case "Prometheus Metrics Line Feed Warning" 0 "metrics_lf.log" \
       --config "$TEST_ENV_DIR/metrics.conf" --clean --force \
   || ! grep -q "Warning: LINUX_CLEANER_METRICS_FILE must be a literal absolute file path without line feeds" "$TEST_ENV_DIR/metrics_lf.log" \
   || [[ -e "$metrics_file" ]]; then
  echo -e "${RED}FAIL: line-feed LINUX_CLEANER_METRICS_FILE did not warn and succeed without writing.${NC}"
  cat "$TEST_ENV_DIR/metrics_lf.log" 2>/dev/null || true
  exit 1
fi
echo -e "${GREEN}PASS: invalid relative or line-feed LINUX_CLEANER_METRICS_FILE warns without failing the run.${NC}"

# 5. Symlinked target path is refused with a warning without modifying the symlink destination.
metrics_Real="$TEST_ENV_DIR/metrics_real_target.txt"
printf 'keep target intact\n' > "$metrics_Real"
ln -s "$metrics_Real" "$metrics_file"
truncate -s 512 "$MOCK_HOME/.cache/metrics_target/file.txt"
if ! LINUX_CLEANER_METRICS_FILE="$metrics_file" \
     run_test_case "Prometheus Metrics Symlink Target Refused" 0 "metrics_symlink.log" \
       --config "$TEST_ENV_DIR/metrics.conf" --clean --force \
   || ! grep -q "Warning: refusing to write cleanup metrics; '$metrics_file' is a symlink" "$TEST_ENV_DIR/metrics_symlink.log" \
   || [[ ! -L "$metrics_file" ]] \
   || [[ "$(cat "$metrics_Real")" != "keep target intact" ]]; then
  echo -e "${RED}FAIL: symlinked LINUX_CLEANER_METRICS_FILE was not refused or modified the target.${NC}"
  cat "$TEST_ENV_DIR/metrics_symlink.log" "$metrics_Real" 2>/dev/null || true
  exit 1
fi
rm -f "$metrics_file" "$metrics_Real"
echo -e "${GREEN}PASS: symlinked LINUX_CLEANER_METRICS_FILE is refused with a warning and leaves the target untouched.${NC}"

# 6. Without LINUX_CLEANER_METRICS_FILE, or in dry-run / read-only modes, nothing is written.
truncate -s 512 "$MOCK_HOME/.cache/metrics_target/file.txt"
if ! LINUX_CLEANER_METRICS_FILE="$metrics_file" \
     run_test_case "Prometheus Metrics Dry Run Writes Nothing" 0 "metrics_dry.log" \
       --config "$TEST_ENV_DIR/metrics.conf" --dry-run \
   || ! LINUX_CLEANER_METRICS_FILE="$metrics_file" \
     run_test_case "Prometheus Metrics Read Only Modes Write Nothing" 0 "metrics_ro.log" \
       --report \
   || ! run_test_case "Prometheus Metrics Unset Writes Nothing" 0 "metrics_unset.log" \
       --config "$TEST_ENV_DIR/metrics.conf" --clean --force \
   || [[ -e "$metrics_file" ]]; then
  echo -e "${RED}FAIL: dry-run, read-only mode, or unset LINUX_CLEANER_METRICS_FILE wrote a metrics file.${NC}"
  exit 1
fi
echo -e "${GREEN}PASS: dry-run, read-only modes, and unset LINUX_CLEANER_METRICS_FILE write nothing.${NC}"

# 7. Early non-zero cleanup exit before saving report (e.g. quarantine session creation failure) overwrites stale metrics with success 0 and a current timestamp while preserving exit status.
mkdir -p "$MOCK_HOME/.cache/metrics_target"
truncate -s 512 "$MOCK_HOME/.cache/metrics_target/file.txt"
cat > "$metrics_file" <<'STALE_METRICS'
# HELP linux_cleaner_last_run_timestamp_seconds Unix timestamp of the last cleanup run.
# TYPE linux_cleaner_last_run_timestamp_seconds gauge
linux_cleaner_last_run_timestamp_seconds 100
# HELP linux_cleaner_last_run_success Whether the last cleanup run succeeded (1) or failed/was interrupted (0).
# TYPE linux_cleaner_last_run_success gauge
linux_cleaner_last_run_success 1
# HELP linux_cleaner_targets Number of targets processed in the last cleanup run by result.
# TYPE linux_cleaner_targets gauge
linux_cleaner_targets{result="cleaned"} 5
linux_cleaner_targets{result="skipped"} 0
linux_cleaner_targets{result="failed"} 0
# HELP linux_cleaner_reclaimed_bytes Accounted bytes reclaimed in the last cleanup run by kind.
# TYPE linux_cleaner_reclaimed_bytes gauge
linux_cleaner_reclaimed_bytes{kind="quarantined"} 2048
linux_cleaner_reclaimed_bytes{kind="permanent"} 0
STALE_METRICS
rm -rf "$MOCK_HOME/.cache/linux-cleaner/quarantine"
mkdir -p "$MOCK_HOME/.cache/linux-cleaner"
printf 'not a directory\n' > "$MOCK_HOME/.cache/linux-cleaner/quarantine"
early_metrics_before=$(date +%s)
if ! LINUX_CLEANER_METRICS_FILE="$metrics_file" \
     run_test_case "Prometheus Metrics Early Non-Zero Exit" 1 "metrics_early_fail.log" \
       --config "$TEST_ENV_DIR/metrics.conf" --clean --trash --force \
   || ! grep -qx 'linux_cleaner_last_run_success 0' "$metrics_file" \
   || ! grep -qx 'linux_cleaner_targets{result="cleaned"} 0' "$metrics_file" \
   || ! grep -qx 'linux_cleaner_targets{result="skipped"} 0' "$metrics_file" \
   || ! grep -qx 'linux_cleaner_targets{result="failed"} 0' "$metrics_file" \
   || ! grep -qx 'linux_cleaner_reclaimed_bytes{kind="quarantined"} 0' "$metrics_file" \
   || ! grep -qx 'linux_cleaner_reclaimed_bytes{kind="permanent"} 0' "$metrics_file" \
   || ! python3 - "$metrics_file" "$early_metrics_before" <<'EARLY_METRICS_PY'
import pathlib, re, sys, time
lines = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
before = int(sys.argv[2])
after = int(time.time()) + 2
ts_lines = [l for l in lines if l.startswith("linux_cleaner_last_run_timestamp_seconds ")]
assert len(ts_lines) == 1, lines
m = re.match(r"^linux_cleaner_last_run_timestamp_seconds ([1-9][0-9]*)$", ts_lines[0])
assert m is not None, ts_lines
ts = int(m.group(1))
assert before <= ts <= after, (before, ts, after)
EARLY_METRICS_PY
then
  rm -f "$MOCK_HOME/.cache/linux-cleaner/quarantine"
  echo -e "${RED}FAIL: early non-zero cleanup exit did not record linux_cleaner_last_run_success 0 with a current timestamp.${NC}"
  cat "$metrics_file" "$TEST_ENV_DIR/metrics_early_fail.log" 2>/dev/null || true
  exit 1
fi
rm -f "$MOCK_HOME/.cache/linux-cleaner/quarantine"
echo -e "${GREEN}PASS: early non-zero cleanup exit records linux_cleaner_last_run_success 0 with a current timestamp.${NC}"

# --doctor: read-only environment checklist (config resolution and schema, check_gnu_userland,
# pgrep, flock, git, sudo -n, notify-send, user timers, quarantine session count).
echo -e "\n${BOLD}Test Case: Doctor Mode Environment Checklist${NC}"
setup_mock_env
doctor_xdg="$TEST_ENV_DIR/doctor_xdg"
mkdir -p "$doctor_xdg/linux-cleaner" \
         "$MOCK_HOME/.cache/linux-cleaner/quarantine/20260101_000000" \
         "$MOCK_HOME/.cache/linux-cleaner/quarantine/20260102_000000"
cp "$TEST_ENV_DIR/test_cleaner.conf" "$doctor_xdg/linux-cleaner/cleaner.conf"
for doc_bin in pgrep flock git notify-send; do
  cat > "$TEST_ENV_DIR/bin/$doc_bin" <<'DOC_BIN_EOF'
#!/usr/bin/env bash
exit 0
DOC_BIN_EOF
  chmod +x "$TEST_ENV_DIR/bin/$doc_bin"
done
cat > "$TEST_ENV_DIR/bin/sudo" <<'DOC_SUDO_EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-n" && "${2:-}" == "true" ]]; then
  exit 0
fi
exit 1
DOC_SUDO_EOF
chmod +x "$TEST_ENV_DIR/bin/sudo"
cat > "$TEST_ENV_DIR/bin/systemctl" <<'DOC_SYSTEMCTL_EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--user" && "${2:-}" == "is-enabled" ]]; then
  case "${3:-}" in
    linux-cleaner-clean.timer) echo "enabled"; exit 0 ;;
    linux-cleaner-retention.timer) echo "disabled"; exit 1 ;;
    linux-cleaner-monitor.timer) echo "enabled"; exit 0 ;;
  esac
fi
exit 1
DOC_SYSTEMCTL_EOF
chmod +x "$TEST_ENV_DIR/bin/systemctl"

doc_all_ec=0
XDG_CONFIG_HOME="$doctor_xdg" PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
  "$CLEANER_SH" --doctor < /dev/null > "$TEST_ENV_DIR/doctor_all.log" 2>&1 || doc_all_ec=$?
if [[ "$doc_all_ec" -ne 0 ]] \
   || ! grep -qF "OK: config: $doctor_xdg/linux-cleaner/cleaner.conf (XDG)" "$TEST_ENV_DIR/doctor_all.log" \
   || ! grep -q "^OK: check_gnu_userland:" "$TEST_ENV_DIR/doctor_all.log" \
   || ! grep -q "^OK: pgrep: $TEST_ENV_DIR/bin/pgrep$" "$TEST_ENV_DIR/doctor_all.log" \
   || ! grep -q "^OK: flock: $TEST_ENV_DIR/bin/flock$" "$TEST_ENV_DIR/doctor_all.log" \
   || ! grep -q "^OK: git: $TEST_ENV_DIR/bin/git$" "$TEST_ENV_DIR/doctor_all.log" \
   || ! grep -q "^OK: sudo -n:" "$TEST_ENV_DIR/doctor_all.log" \
   || ! grep -q "^OK: notify-send: $TEST_ENV_DIR/bin/notify-send$" "$TEST_ENV_DIR/doctor_all.log" \
   || ! grep -q "^INFO: timers (systemctl --user is-enabled): clean=enabled retention=disabled monitor=enabled$" "$TEST_ENV_DIR/doctor_all.log" \
   || ! grep -qF "INFO: quarantine: 2 session(s) ($MOCK_HOME/.cache/linux-cleaner/quarantine)" "$TEST_ENV_DIR/doctor_all.log" \
   || [[ -e "$MOCK_HOME/.cache/linux-cleaner/cleaner.lock" ]]; then
  echo -e "${RED}FAIL: --doctor in an all-present environment did not print the expected checklist and exit 0 (ec=$doc_all_ec).${NC}"
  cat "$TEST_ENV_DIR/doctor_all.log" 2>/dev/null || true
  exit 1
fi
echo -e "${GREEN}PASS: --doctor prints OK/INFO lines for an all-present environment without touching any lock or file.${NC}"

# Last-cleanup diagnostics use disposable state and never change doctor's status.
echo -e "\n${BOLD}Test Case: Doctor Last Cleanup Outcome${NC}"
doc_state="$MOCK_HOME/doctor-state"
doc_report="$doc_state/linux-cleaner/last-report.txt"
doc_saved=$(date '+%Y-%m-%dT%H:%M:%S')
doc_result='cleaned=1 skipped=0 failed=0 elapsed=1s'
cat > "$TEST_ENV_DIR/bin/systemctl" <<'DOC_LAST_SYSTEMCTL_EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--user" && "${2:-}" == "is-enabled" ]]; then
  case "${3:-}" in
    linux-cleaner-clean.timer) echo "${DOCTOR_CLEAN_TIMER_STATE:-enabled}"; exit 0 ;;
    linux-cleaner-retention.timer|linux-cleaner-monitor.timer) echo disabled; exit 1 ;;
  esac
fi
exit 1
DOC_LAST_SYSTEMCTL_EOF
chmod +x "$TEST_ENV_DIR/bin/systemctl"
doc_last_case() {
  local label="$1" expected="$2" timer_state="${3:-enabled}" expected_ec ec cfg
  for expected_ec in 0 1; do
    cfg="$TEST_ENV_DIR/test_cleaner.conf"
    [[ "$expected_ec" -eq 1 ]] && cfg="$TEST_ENV_DIR/no_such_doctor.conf"
    ec=0
    XDG_STATE_HOME="$doc_state" PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
      DOCTOR_CLEAN_TIMER_STATE="$timer_state" \
      "$CLEANER_SH" --doctor --config "$cfg" \
      < /dev/null > "$TEST_ENV_DIR/doctor_last.log" 2>&1 || ec=$?
    if [[ "$ec" -ne "$expected_ec" ]] \
       || [[ "$(grep '^\(INFO\|WARN\): last cleanup:' "$TEST_ENV_DIR/doctor_last.log")" != "$expected" ]]; then
      echo -e "${RED}FAIL: --doctor last cleanup ($label), expected '$expected' and exit $expected_ec (ec=$ec).${NC}"
      cat "$TEST_ENV_DIR/doctor_last.log"
      exit 1
    fi
  done
}
doc_last_case missing 'INFO: last cleanup: none recorded'
[[ ! -e "$doc_state" ]] || { echo 'FAIL: --doctor created report state'; exit 1; }
mkdir -p "$doc_state/linux-cleaner"
printf 'Saved: %s\nResult: %s\n' "$doc_saved" "$doc_result" > "$doc_report"
doc_last_case ok "INFO: last cleanup: $doc_saved $doc_result"
if [[ "$EUID" -ne 0 ]]; then
  chmod 000 "$doc_report"
  doc_last_case unreadable 'WARN: last cleanup: report not readable'
  chmod 600 "$doc_report"
fi
printf 'Saved: %s\nResult: cleaned=0 skipped=0 failed=2 elapsed=1s\n' "$doc_saved" > "$doc_report"
doc_last_case failed "WARN: last cleanup: $doc_saved cleaned=0 skipped=0 failed=2 elapsed=1s"
printf 'Saved: %s\nResult: %s\nInterrupted: TERM before all targets finished\n' "$doc_saved" "$doc_result" > "$doc_report"
doc_last_case interrupted "WARN: last cleanup: $doc_saved $doc_result"
printf 'Saved: %s\nResult: %s\nRetention failed: true\n' "$doc_saved" "$doc_result" > "$doc_report"
doc_last_case retention "WARN: last cleanup: $doc_saved $doc_result; retention failed"
printf 'Saved: %s\nResult: %s\n' "$doc_saved" "$doc_result" > "$doc_report"
touch -d '3 days ago' "$doc_report"
doc_last_case stale "WARN: last cleanup: $doc_saved $doc_result"
doc_last_case stale_disabled "INFO: last cleanup: $doc_saved $doc_result" disabled
mv "$doc_report" "$doc_state/report-target.txt"
ln -s "$doc_state/report-target.txt" "$doc_report"
doc_last_case symlink 'INFO: last cleanup: none recorded'
rm "$doc_report"
rmdir "$doc_state/linux-cleaner"
mkdir "$doc_state/report-dir"
mv "$doc_state/report-target.txt" "$doc_state/report-dir/last-report.txt"
ln -s "$doc_state/report-dir" "$doc_state/linux-cleaner"
doc_last_case symlink_directory 'INFO: last cleanup: none recorded'
rm -rf "$doc_state"
echo -e "${GREEN}PASS: --doctor reports missing, successful, failed, interrupted and stale cleanups, refuses report symlinks, and preserves exit codes.${NC}"

# Daily timer plans come from the clean unit's env file and preserve doctor status.
echo -e "\n${BOLD}Test Case: Doctor Daily Timer Plan${NC}"
doc_plan_env="$MOCK_HOME/.config/linux-cleaner/env"
mkdir -p "$MOCK_HOME/.config/linux-cleaner"
doc_plan_case() {
  local label="$1" expected="$2" timer_state="${3:-enabled}" expected_ec ec cfg
  for expected_ec in 0 1; do
    cfg="$TEST_ENV_DIR/test_cleaner.conf"
    [[ "$expected_ec" -eq 1 ]] && cfg="$TEST_ENV_DIR/no_such_doctor.conf"
    ec=0
    PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
      DOCTOR_CLEAN_TIMER_STATE="$timer_state" \
      "$CLEANER_SH" --doctor --config "$cfg" \
      < /dev/null > "$TEST_ENV_DIR/doctor_plan.log" 2>&1 || ec=$?
    if [[ "$ec" -ne "$expected_ec" ]] \
       || [[ "$(grep -E '^(INFO|WARN): daily timer plan:' "$TEST_ENV_DIR/doctor_plan.log" || true)" != "$expected" ]]; then
      echo -e "${RED}FAIL: --doctor daily timer plan ($label), expected '$expected' and exit $expected_ec (ec=$ec).${NC}"
      cat "$TEST_ENV_DIR/doctor_plan.log"
      exit 1
    fi
  done
}
doc_plan_case no_env 'INFO: daily timer plan: risk=safe deletion=permanent keep-days=none (no env file)'
printf 'LINUX_CLEANER_RISK=medium\nLINUX_CLEANER_TRASH=1\nLINUX_CLEANER_TRASH_KEEP_DAYS=14\n' > "$doc_plan_env"
doc_plan_case configured "INFO: daily timer plan: risk=medium deletion=quarantine keep-days=14 ($doc_plan_env)"
printf 'LINUX_CLEANER_RISK="medium"\nLINUX_CLEANER_TRASH="1"\nLINUX_CLEANER_TRASH_KEEP_DAYS="14"\n' > "$doc_plan_env"
doc_plan_case quoted "INFO: daily timer plan: risk=medium deletion=quarantine keep-days=14 ($doc_plan_env)"
doc_plan_case disabled '' disabled
printf 'LINUX_CLEANER_RISK=high\n' > "$doc_plan_env"
doc_plan_case invalid_risk "WARN: daily timer plan: risk=high deletion=permanent keep-days=none ($doc_plan_env); invalid risk"
printf 'LINUX_CLEANER_CONFIG=%s\n' "$TEST_ENV_DIR/no_such_timer.conf" > "$doc_plan_env"
doc_plan_case missing_config "WARN: daily timer plan: risk=safe deletion=permanent keep-days=none config=$TEST_ENV_DIR/no_such_timer.conf ($doc_plan_env); config not readable"
printf 'LINUX_CLEANER_CONFIG=%s\n' "$TEST_ENV_DIR/test_cleaner.conf" > "$doc_plan_env"
doc_plan_case readable_config "INFO: daily timer plan: risk=safe deletion=permanent keep-days=none config=$TEST_ENV_DIR/test_cleaner.conf ($doc_plan_env)"
printf 'LINUX_CLEANER_RISK= DaNgErOuS \n' > "$doc_plan_env"
doc_plan_case risk_alias_spaces "INFO: daily timer plan: risk=DaNgErOuS deletion=permanent keep-days=none ($doc_plan_env)"
printf 'LINUX_CLEANER_TRASH_KEEP_DAYS=14\nLINUX_CLEANER_ONLY_PATH=%s\n' "$MOCK_HOME/.cache" > "$doc_plan_env"
doc_plan_case only_path_keep_days "WARN: daily timer plan: risk=safe deletion=permanent keep-days=14 ($doc_plan_env); only-path with keep-days"
if locale -a 2>/dev/null | grep -qix 'tr_TR.utf8'; then
  # Under tr_TR, bash lowercases I to a dotless i; risk names must still match.
  printf 'LINUX_CLEANER_RISK=MEDIUM\n' > "$doc_plan_env"
  (export LC_ALL=tr_TR.UTF-8; doc_plan_case turkish_risk "INFO: daily timer plan: risk=MEDIUM deletion=permanent keep-days=none ($doc_plan_env)")
  if ! LC_ALL=tr_TR.UTF-8 run_test_case "Turkish Locale Risk MEDIUM" 0 "turkish_risk.log" \
       --config "$TEST_ENV_DIR/test_cleaner.conf" --risk MEDIUM --dry-run; then
    echo -e "${RED}FAIL: --risk MEDIUM was rejected under the Turkish locale.${NC}"
    exit 1
  fi
  # Under tr_TR, a bash [0-9] range also matches non-ASCII digits such as U+0661.
  for tr_digit_case in "--lock-wait|--lock-wait must be an integer" "--min-age|--min-age expects" \
      "--action-timeout|--action-timeout expects" "--trash-keep-days|--trash-keep-days expects" \
      "--check-health|--check-health expects"; do
    tr_digit_flag=${tr_digit_case%%|*}
    tr_digit_args=("$tr_digit_flag" $'\xd9\xa1' --dry-run)
    [[ "$tr_digit_flag" == --check-health ]] && tr_digit_args=(--report "$tr_digit_flag" $'\xd9\xa1')
    if ! LC_ALL=tr_TR.UTF-8 run_test_case "Turkish Locale Non-ASCII Digit $tr_digit_flag" 1 "turkish_digit.log" \
         --config "$TEST_ENV_DIR/test_cleaner.conf" "${tr_digit_args[@]}" \
       || ! grep -qF -- "Error: ${tr_digit_case#*|}" "$TEST_ENV_DIR/turkish_digit.log"; then
      echo -e "${RED}FAIL: $tr_digit_flag accepted a non-ASCII digit under the Turkish locale.${NC}"
      exit 1
    fi
  done
fi
printf 'LINUX_CLEANER_TRASH=1\nLINUX_CLEANER_TRASH_KEEP_DAYS=weekly\n' > "$doc_plan_env"
doc_plan_case invalid_keep_days "WARN: daily timer plan: risk=safe deletion=quarantine keep-days=weekly ($doc_plan_env); invalid keep-days"
# The service starts in HOME: a relative config resolves there, not in the caller's directory.
cp "$TEST_ENV_DIR/test_cleaner.conf" "$TEST_ENV_DIR/timer-relative.conf"
printf 'LINUX_CLEANER_CONFIG=timer-relative.conf\n' > "$doc_plan_env"
(cd "$TEST_ENV_DIR" && doc_plan_case relative_config "WARN: daily timer plan: risk=safe deletion=permanent keep-days=none config=timer-relative.conf ($doc_plan_env); config not readable")
printf 'safe|Broken\n' > "$TEST_ENV_DIR/timer-broken.conf"
printf 'LINUX_CLEANER_CONFIG=%s\n' "$TEST_ENV_DIR/timer-broken.conf" > "$doc_plan_env"
doc_plan_case invalid_config "WARN: daily timer plan: risk=safe deletion=permanent keep-days=none config=$TEST_ENV_DIR/timer-broken.conf ($doc_plan_env); config invalid"
if [[ "$EUID" -ne 0 ]]; then
  chmod 000 "$doc_plan_env"
  doc_plan_case unreadable "WARN: daily timer plan: env file not readable ($doc_plan_env)"
  chmod 600 "$doc_plan_env"
fi
rm -f "$doc_plan_env"
echo -e "${GREEN}PASS: --doctor shows configured and default daily timer plans only when enabled and preserves exit codes.${NC}"

# Under tr_TR a bash regex A-Z range skips i: option names and long process names must still match.
if locale -a 2>/dev/null | grep -qix 'tr_TR.utf8'; then
  setup_mock_env
  if ! LC_ALL=tr_TR.UTF-8 run_test_case "Turkish Locale Option As Value" 1 "turkish_option_value.log" \
       --config "$TEST_ENV_DIR/test_cleaner.conf" --exclude --interactive \
     || ! grep -qF -- "Error: --exclude requires a value, got option '--interactive'." "$TEST_ENV_DIR/turkish_option_value.log" \
     || ! LC_ALL=tr_TR.UTF-8 run_test_case "Turkish Locale Long Process Name" 0 "turkish_process.log" \
       --config "$TEST_ENV_DIR/test_cleaner.conf" --dry-run \
     || ! grep -q "BLOCKED.*Yarn Cache: Skip cleanup because process 'mock_running_proc' is active." "$TEST_ENV_DIR/turkish_process.log"; then
    echo -e "${RED}FAIL: an option value or a long process name with i was misread under the Turkish locale.${NC}"
    exit 1
  fi
  echo -e "${GREEN}PASS: option names and long process names match under the Turkish locale.${NC}"
fi

# The clean unit's env file enabling trash mode needs a retention bound; --doctor
# warns only when the clean timer is enabled and neither bound is configured.
echo -e "\n${BOLD}Test Case: Doctor Quarantine Retention Warning${NC}"
doc_env_dir="$MOCK_HOME/.config/linux-cleaner"
mkdir -p "$doc_env_dir"
doc_retention_state=disabled
doc_retention_case() {
  local label="$1" expect="$2" ec=0
  cat > "$TEST_ENV_DIR/bin/systemctl" <<DOC_RET_SYSTEMCTL_EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "--user" && "\${2:-}" == "is-enabled" ]]; then
  case "\${3:-}" in
    linux-cleaner-clean.timer) echo "enabled"; exit 0 ;;
    linux-cleaner-retention.timer) echo "$doc_retention_state"; exit 0 ;;
    linux-cleaner-monitor.timer) echo "disabled"; exit 1 ;;
  esac
fi
exit 1
DOC_RET_SYSTEMCTL_EOF
  chmod +x "$TEST_ENV_DIR/bin/systemctl"
  PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
    "$CLEANER_SH" --doctor --config "$TEST_ENV_DIR/test_cleaner.conf" \
    < /dev/null > "$TEST_ENV_DIR/doctor_retention.log" 2>&1 || ec=$?
  if [[ "$ec" -ne 0 ]] \
     || { [[ "$expect" == warn ]] && ! grep -qxF "WARN: quarantine retention: $doc_env_dir/env enables LINUX_CLEANER_TRASH for the daily timer but neither LINUX_CLEANER_TRASH_KEEP_DAYS nor linux-cleaner-retention.timer bounds the quarantine" "$TEST_ENV_DIR/doctor_retention.log"; } \
     || { [[ "$expect" == none ]] && grep -q "quarantine retention" "$TEST_ENV_DIR/doctor_retention.log"; }; then
    echo -e "${RED}FAIL: --doctor quarantine retention check ($label) expected '$expect' (ec=$ec).${NC}"
    cat "$TEST_ENV_DIR/doctor_retention.log" 2>/dev/null || true
    exit 1
  fi
}
printf 'LINUX_CLEANER_FORCE=1\nLINUX_CLEANER_TRASH="1"\n# LINUX_CLEANER_TRASH_KEEP_DAYS=30\n' > "$doc_env_dir/env"
doc_retention_case "trash without retention" warn
printf 'LINUX_CLEANER_TRASH=1\nLINUX_CLEANER_TRASH_KEEP_DAYS=30\n' > "$doc_env_dir/env"
doc_retention_case "trash with keep days" none
printf 'LINUX_CLEANER_TRASH=yes\n' > "$doc_env_dir/env"
doc_retention_state=enabled
doc_retention_case "trash with retention timer" none
doc_retention_state=disabled
printf 'LINUX_CLEANER_TRASH=1\nLINUX_CLEANER_TRASH=0\n' > "$doc_env_dir/env"
doc_retention_case "trash disabled by a later line" none
rm -f "$doc_env_dir/env"
echo -e "${GREEN}PASS: --doctor warns when the daily timer quarantines with no retention bound, and only then.${NC}"

# monitor.env sits beside the home timer env file. A conflict or an unreadable
# file warns; an absent file does not. XDG_CONFIG_HOME does not move either path.
echo -e "\n${BOLD}Test Case: Doctor Monitor Env Warnings${NC}"
mkdir -p "$doc_env_dir"
doc_mon_xdg="$TEST_ENV_DIR/doctor_mon_xdg"
mkdir -p "$doc_mon_xdg/linux-cleaner"
cat > "$TEST_ENV_DIR/bin/systemctl" <<'DOC_MON_SYSTEMCTL_EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--user" && "${2:-}" == "is-enabled" ]]; then
  case "${3:-}" in
    linux-cleaner-clean.timer) echo "enabled"; exit 0 ;;
    linux-cleaner-retention.timer) echo "disabled"; exit 1 ;;
    linux-cleaner-monitor.timer) echo "disabled"; exit 1 ;;
  esac
fi
exit 1
DOC_MON_SYSTEMCTL_EOF
chmod +x "$TEST_ENV_DIR/bin/systemctl"
printf 'LINUX_CLEANER_TRASH=1\n' > "$doc_env_dir/env"
printf 'LINUX_CLEANER_ONLY_PATH=/tmp\nLINUX_CLEANER_TRASH_KEEP_DAYS=7\n' > "$doc_env_dir/monitor.env"
doc_mon_ec=0
XDG_CONFIG_HOME="$doc_mon_xdg" PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
  "$CLEANER_SH" --doctor --config "$TEST_ENV_DIR/test_cleaner.conf" \
  < /dev/null > "$TEST_ENV_DIR/doctor_monitor.log" 2>&1 || doc_mon_ec=$?
if [[ "$doc_mon_ec" -ne 0 ]] \
   || ! grep -qxF "WARN: monitor env: $doc_env_dir/monitor.env combines LINUX_CLEANER_ONLY_PATH with LINUX_CLEANER_TRASH_KEEP_DAYS" "$TEST_ENV_DIR/doctor_monitor.log" \
   || ! grep -qxF "WARN: quarantine retention: $doc_env_dir/env enables LINUX_CLEANER_TRASH for the daily timer but neither LINUX_CLEANER_TRASH_KEEP_DAYS nor linux-cleaner-retention.timer bounds the quarantine" "$TEST_ENV_DIR/doctor_monitor.log"; then
  echo -e "${RED}FAIL: --doctor did not warn about a conflicting monitor.env and the home timer env (ec=$doc_mon_ec).${NC}"
  cat "$TEST_ENV_DIR/doctor_monitor.log" 2>/dev/null || true
  exit 1
fi
rm -f "$doc_env_dir/monitor.env"
doc_mon_ec=0
XDG_CONFIG_HOME="$doc_mon_xdg" PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
  "$CLEANER_SH" --doctor --config "$TEST_ENV_DIR/test_cleaner.conf" \
  < /dev/null > "$TEST_ENV_DIR/doctor_monitor.log" 2>&1 || doc_mon_ec=$?
if [[ "$doc_mon_ec" -ne 0 ]] \
   || grep -q "WARN: monitor env:" "$TEST_ENV_DIR/doctor_monitor.log"; then
  echo -e "${RED}FAIL: --doctor printed a monitor env line when monitor.env was absent (ec=$doc_mon_ec).${NC}"
  cat "$TEST_ENV_DIR/doctor_monitor.log" 2>/dev/null || true
  exit 1
fi
if [[ "$EUID" -ne 0 ]]; then
  printf 'LINUX_CLEANER_ONLY_PATH=/tmp\n' > "$doc_env_dir/monitor.env"
  chmod 000 "$doc_env_dir/monitor.env"
  doc_mon_ec=0
  XDG_CONFIG_HOME="$doc_mon_xdg" PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
    "$CLEANER_SH" --doctor --config "$TEST_ENV_DIR/test_cleaner.conf" \
    < /dev/null > "$TEST_ENV_DIR/doctor_monitor.log" 2>&1 || doc_mon_ec=$?
  chmod 600 "$doc_env_dir/monitor.env"
  if [[ "$doc_mon_ec" -ne 0 ]] \
     || ! grep -qxF "WARN: monitor env: $doc_env_dir/monitor.env (not readable)" "$TEST_ENV_DIR/doctor_monitor.log" \
     || grep -q "combines LINUX_CLEANER_ONLY_PATH" "$TEST_ENV_DIR/doctor_monitor.log"; then
    echo -e "${RED}FAIL: --doctor did not warn about an unreadable monitor.env (ec=$doc_mon_ec).${NC}"
    cat "$TEST_ENV_DIR/doctor_monitor.log" 2>/dev/null || true
    exit 1
  fi
fi
rm -f "$doc_env_dir/env" "$doc_env_dir/monitor.env"
echo -e "${GREEN}PASS: --doctor warns on a conflicting or unreadable monitor.env, stays silent when it is absent, and still reads the home timer env when XDG_CONFIG_HOME points elsewhere.${NC}"

# Checkout fallback when XDG config is absent; the /etc candidate is redirected
# in a copy so the host's own install cannot answer instead.
rm -rf "$doctor_xdg" "$MOCK_HOME/.cache/linux-cleaner/quarantine"
doc_checkout_dir="$TEST_ENV_DIR/doctor_checkout"
mkdir -p "$doc_checkout_dir"
sed 's|"/etc/linux-cleaner/cleaner.conf"|"'"$doc_checkout_dir"'/etc/cleaner.conf"|' "$CLEANER_SH" > "$doc_checkout_dir/cleaner.sh"
cp "$TEST_ENV_DIR/test_cleaner.conf" "$doc_checkout_dir/cleaner.conf"
doc_checkout_ec=0
XDG_CONFIG_HOME="$doctor_xdg" PATH="$TEST_ENV_DIR/bin:$PATH" HOME="$MOCK_HOME" \
  bash "$doc_checkout_dir/cleaner.sh" --doctor < /dev/null > "$TEST_ENV_DIR/doctor_checkout.log" 2>&1 || doc_checkout_ec=$?
if [[ "$doc_checkout_ec" -ne 0 ]] \
   || ! grep -qxF "OK: config: $doc_checkout_dir/cleaner.conf (checkout)" "$TEST_ENV_DIR/doctor_checkout.log" \
   || ! grep -qF "INFO: quarantine: 0 session(s) ($MOCK_HOME/.cache/linux-cleaner/quarantine)" "$TEST_ENV_DIR/doctor_checkout.log" \
   || [[ -e "$MOCK_HOME/.cache/linux-cleaner/quarantine" ]]; then
  echo -e "${RED}FAIL: --doctor without XDG config did not resolve fallback config or created quarantine dir (ec=$doc_checkout_ec).${NC}"
  cat "$TEST_ENV_DIR/doctor_checkout.log" 2>/dev/null || true
  exit 1
fi
echo -e "${GREEN}PASS: --doctor resolves fallback config and reports 0 quarantine sessions without creating the directory.${NC}"

# Missing pgrep/flock/git emit WARN lines and still exit 0 when a readable config exists.
doc_min_bin="$TEST_ENV_DIR/doctor_min_bin"
mkdir -p "$doc_min_bin"
for base_tool in bash du stat find realpath mktemp rm id dirname basename tr sed awk cut sort tail cat date chmod mkdir mv cp rmdir timeout; do
  if tool_real=$(command -v "$base_tool" 2>/dev/null); then
    ln -sf "$tool_real" "$doc_min_bin/$base_tool"
  fi
done
doc_warn_ec=0
PATH="$doc_min_bin" HOME="$MOCK_HOME" \
  "$CLEANER_SH" --doctor --config "$TEST_ENV_DIR/test_cleaner.conf" \
  < /dev/null > "$TEST_ENV_DIR/doctor_warn.log" 2>&1 || doc_warn_ec=$?
if [[ "$doc_warn_ec" -ne 0 ]] \
   || ! grep -qxF "OK: config: $TEST_ENV_DIR/test_cleaner.conf (explicit)" "$TEST_ENV_DIR/doctor_warn.log" \
   || ! grep -q "^OK: check_gnu_userland:" "$TEST_ENV_DIR/doctor_warn.log" \
   || ! grep -q "^WARN: pgrep: not found" "$TEST_ENV_DIR/doctor_warn.log" \
   || ! grep -q "^WARN: flock: not found" "$TEST_ENV_DIR/doctor_warn.log" \
   || ! grep -q "^WARN: git: not found" "$TEST_ENV_DIR/doctor_warn.log" \
   || ! grep -q "^INFO: sudo -n:" "$TEST_ENV_DIR/doctor_warn.log" \
   || ! grep -q "^INFO: notify-send: not found" "$TEST_ENV_DIR/doctor_warn.log" \
   || ! grep -q "^INFO: timers (systemctl --user is-enabled): clean=unavailable retention=unavailable monitor=unavailable$" "$TEST_ENV_DIR/doctor_warn.log"; then
  echo -e "${RED}FAIL: --doctor with missing pgrep/flock/git did not emit WARN lines and exit 0 (ec=$doc_warn_ec).${NC}"
  cat "$TEST_ENV_DIR/doctor_warn.log" 2>/dev/null || true
  exit 1
fi
echo -e "${GREEN}PASS: --doctor emits WARN lines for missing pgrep/flock/git while exiting 0.${NC}"

# A missing or unreadable config means cleanup cannot run: --doctor warns and exits 1,
# and cleanup refuses an unreadable config with one Error: line before any analysis.
doc_cfg_ec=0
HOME="$MOCK_HOME" "$CLEANER_SH" --doctor --config "$TEST_ENV_DIR/no_such_doctor.conf" \
  < /dev/null > "$TEST_ENV_DIR/doctor_nocfg.log" 2>&1 || doc_cfg_ec=$?
if [[ "$doc_cfg_ec" -ne 1 ]] \
   || ! grep -qxF "WARN: config: $TEST_ENV_DIR/no_such_doctor.conf (explicit, not found)" "$TEST_ENV_DIR/doctor_nocfg.log"; then
  echo -e "${RED}FAIL: --doctor with a missing config did not warn and exit 1 (ec=$doc_cfg_ec).${NC}"
  cat "$TEST_ENV_DIR/doctor_nocfg.log" 2>/dev/null || true
  exit 1
fi
if [[ "$EUID" -ne 0 ]]; then
  unreadable_cfg="$TEST_ENV_DIR/unreadable_cleaner.conf"
  cp "$TEST_ENV_DIR/test_cleaner.conf" "$unreadable_cfg"
  chmod 000 "$unreadable_cfg"
  doc_cfg_ec=0
  HOME="$MOCK_HOME" "$CLEANER_SH" --doctor --config "$unreadable_cfg" \
    < /dev/null > "$TEST_ENV_DIR/doctor_unreadable.log" 2>&1 || doc_cfg_ec=$?
  unreadable_clean_ec=0
  HOME="$MOCK_HOME" "$CLEANER_SH" --dry-run --config "$unreadable_cfg" \
    < /dev/null > "$TEST_ENV_DIR/unreadable_cfg.log" 2>&1 || unreadable_clean_ec=$?
  chmod 600 "$unreadable_cfg"
  if [[ "$doc_cfg_ec" -ne 1 ]] \
     || ! grep -qxF "WARN: config: $unreadable_cfg (explicit, not readable)" "$TEST_ENV_DIR/doctor_unreadable.log" \
     || [[ "$unreadable_clean_ec" -ne 1 ]] \
     || ! grep -qF "Error: Configuration file '$unreadable_cfg' is not readable" "$TEST_ENV_DIR/unreadable_cfg.log" \
     || grep -q "Permission denied\|Analyzing targets" "$TEST_ENV_DIR/unreadable_cfg.log"; then
    echo -e "${RED}FAIL: an unreadable config was not refused cleanly by cleanup and --doctor (doctor=$doc_cfg_ec clean=$unreadable_clean_ec).${NC}"
    cat "$TEST_ENV_DIR/doctor_unreadable.log" "$TEST_ENV_DIR/unreadable_cfg.log" 2>/dev/null || true
    exit 1
  fi
fi
echo -e "${GREEN}PASS: --doctor exits 1 for a missing or unreadable config, and cleanup refuses an unreadable config with a clear error.${NC}"

# An unreadable quarantine directory is reported as a WARN, never as zero sessions.
if [[ "$EUID" -ne 0 ]]; then
  doc_q="$MOCK_HOME/.cache/linux-cleaner/quarantine"
  mkdir -p "$doc_q/20260101_000000"
  chmod 000 "$doc_q"
  doc_q_ec=0
  HOME="$MOCK_HOME" "$CLEANER_SH" --doctor --config "$TEST_ENV_DIR/test_cleaner.conf" \
    < /dev/null > "$TEST_ENV_DIR/doctor_quarantine.log" 2>&1 || doc_q_ec=$?
  chmod 700 "$doc_q"
  if [[ "$doc_q_ec" -ne 0 ]] \
     || ! grep -qxF "WARN: quarantine: cannot enumerate sessions ($doc_q)" "$TEST_ENV_DIR/doctor_quarantine.log" \
     || grep -q "session(s)" "$TEST_ENV_DIR/doctor_quarantine.log"; then
    echo -e "${RED}FAIL: --doctor did not warn about an unreadable quarantine directory (ec=$doc_q_ec).${NC}"
    cat "$TEST_ENV_DIR/doctor_quarantine.log" 2>/dev/null || true
    exit 1
  fi
  echo -e "${GREEN}PASS: --doctor warns when the quarantine directory cannot be enumerated.${NC}"
fi

# A readable config with a schema error warns and exits 1; the rest of the
# checklist still prints. A valid config stays OK.
echo -e "\n${BOLD}Test Case: Doctor Invalid Config Schema Exits 1${NC}"
doc_schema_cfg="$TEST_ENV_DIR/doctor_schema.conf"
rm -rf "$MOCK_HOME/.cache/linux-cleaner"
doc_schema_assert() {
  local label="$1" cfg="$2" source="$3" fragment="$4" ec="$5"
  if [[ "$ec" -ne 1 ]] \
     || ! grep -qF "WARN: config: ${cfg} (${source}, " "$TEST_ENV_DIR/doctor_schema.log" \
     || ! grep -qF "$fragment" "$TEST_ENV_DIR/doctor_schema.log" \
     || ! grep -q "^OK: check_gnu_userland:" "$TEST_ENV_DIR/doctor_schema.log" \
     || ! grep -q "^INFO: quarantine:" "$TEST_ENV_DIR/doctor_schema.log" \
     || ! awk 'BEGIN { w = 0; g = 0 } /^WARN: config: / { w = NR } /^OK: check_gnu_userland:/ { g = NR } END { exit !(w > 0 && g > w) }' "$TEST_ENV_DIR/doctor_schema.log" \
     || [[ -e "$MOCK_HOME/.cache/linux-cleaner" ]]; then
    echo -e "${RED}FAIL: --doctor schema check ($label) did not warn and continue (ec=$ec).${NC}"
    cat "$TEST_ENV_DIR/doctor_schema.log" "$TEST_ENV_DIR/doctor_schema.err" 2>/dev/null || true
    exit 1
  fi
}
doc_schema_explicit() {
  local label="$1" fragment="$2" ec=0
  HOME="$MOCK_HOME" "$CLEANER_SH" --doctor --config "$doc_schema_cfg" \
    < /dev/null > "$TEST_ENV_DIR/doctor_schema.log" 2> "$TEST_ENV_DIR/doctor_schema.err" || ec=$?
  doc_schema_assert "$label" "$doc_schema_cfg" "explicit" "$fragment" "$ec"
}
printf 'bad_line_only\n' > "$doc_schema_cfg"
doc_schema_explicit "bad field count" "expected 5-7 fields"
printf 'bogus|Name|/tmp/x|desc|0\n' > "$doc_schema_cfg"
doc_schema_explicit "invalid risk" "Unknown risk level"
printf 'safe|Name|/tmp/x|desc|0||action:not_a_real_action\n' > "$doc_schema_cfg"
doc_schema_explicit "unknown action" "Unknown action"
printf 'safe|Name|/tmp/x|desc|nope\n' > "$doc_schema_cfg"
doc_schema_explicit "non-integer MIN_AGE_DAYS" "invalid MIN_AGE_DAYS"
printf 'protect|/tmp/x|extra\n' > "$doc_schema_cfg"
doc_schema_explicit "bad protect line" "protect line requires 2 fields"
doc_schema_ok_ec=0
HOME="$MOCK_HOME" "$CLEANER_SH" --doctor --config "$TEST_ENV_DIR/test_cleaner.conf" \
  < /dev/null > "$TEST_ENV_DIR/doctor_schema_ok.log" 2> "$TEST_ENV_DIR/doctor_schema_ok.err" || doc_schema_ok_ec=$?
if [[ "$doc_schema_ok_ec" -ne 0 ]] \
   || ! grep -qxF "OK: config: $TEST_ENV_DIR/test_cleaner.conf (explicit)" "$TEST_ENV_DIR/doctor_schema_ok.log" \
   || grep -q "^WARN: config:" "$TEST_ENV_DIR/doctor_schema_ok.log" \
   || [[ -e "$MOCK_HOME/.cache/linux-cleaner" ]]; then
  echo -e "${RED}FAIL: --doctor with a valid config did not print OK: config and exit 0 (ec=$doc_schema_ok_ec).${NC}"
  cat "$TEST_ENV_DIR/doctor_schema_ok.log" "$TEST_ENV_DIR/doctor_schema_ok.err" 2>/dev/null || true
  exit 1
fi
doc_schema_xdg="$TEST_ENV_DIR/doctor_schema_xdg"
mkdir -p "$doc_schema_xdg/linux-cleaner"
printf 'bad_line_only\n' > "$doc_schema_xdg/linux-cleaner/cleaner.conf"
doc_schema_ec=0
env -u LINUX_CLEANER_CONFIG XDG_CONFIG_HOME="$doc_schema_xdg" HOME="$MOCK_HOME" \
  "$CLEANER_SH" --doctor < /dev/null > "$TEST_ENV_DIR/doctor_schema.log" 2> "$TEST_ENV_DIR/doctor_schema.err" || doc_schema_ec=$?
doc_schema_assert "XDG source" "$doc_schema_xdg/linux-cleaner/cleaner.conf" "XDG" "expected 5-7 fields" "$doc_schema_ec"
doc_schema_root="$TEST_ENV_DIR/doctor_schema_src"
mkdir -p "$doc_schema_root/etc" "$doc_schema_root/xdg-empty"
sed 's|"/etc/linux-cleaner/cleaner.conf"|"'"$doc_schema_root"'/etc/cleaner.conf"|' "$CLEANER_SH" > "$doc_schema_root/cleaner.sh"
printf 'bad_line_only\n' > "$doc_schema_root/etc/cleaner.conf"
doc_schema_ec=0
env -u LINUX_CLEANER_CONFIG XDG_CONFIG_HOME="$doc_schema_root/xdg-empty" HOME="$MOCK_HOME" \
  bash "$doc_schema_root/cleaner.sh" --doctor < /dev/null > "$TEST_ENV_DIR/doctor_schema.log" 2> "$TEST_ENV_DIR/doctor_schema.err" || doc_schema_ec=$?
doc_schema_assert "/etc source" "$doc_schema_root/etc/cleaner.conf" "/etc" "expected 5-7 fields" "$doc_schema_ec"
rm -f "$doc_schema_root/etc/cleaner.conf"
printf 'bad_line_only\n' > "$doc_schema_root/cleaner.conf"
doc_schema_ec=0
env -u LINUX_CLEANER_CONFIG XDG_CONFIG_HOME="$doc_schema_root/xdg-empty" HOME="$MOCK_HOME" \
  bash "$doc_schema_root/cleaner.sh" --doctor < /dev/null > "$TEST_ENV_DIR/doctor_schema.log" 2> "$TEST_ENV_DIR/doctor_schema.err" || doc_schema_ec=$?
doc_schema_assert "checkout source" "$doc_schema_root/cleaner.conf" "checkout" "expected 5-7 fields" "$doc_schema_ec"
echo -e "${GREEN}PASS: --doctor exits 1 on an invalid config schema, still prints the later checklist, and keeps OK for a valid config.${NC}"

# Failing GNU userland probe prints WARN and exits 1.
cat > "$TEST_ENV_DIR/bin/stat" <<'DOC_BAD_STAT_EOF'
#!/usr/bin/env bash
exit 1
DOC_BAD_STAT_EOF
chmod +x "$TEST_ENV_DIR/bin/stat"
if ! run_test_case "Doctor Failing GNU Probe Exits 1" 1 "doctor_bad_gnu.log" --doctor \
   || ! grep -q "^WARN: check_gnu_userland:" "$TEST_ENV_DIR/doctor_bad_gnu.log"; then
  rm -f "$TEST_ENV_DIR/bin/stat"
  echo -e "${RED}FAIL: --doctor did not exit 1 with WARN: check_gnu_userland when GNU probe failed.${NC}"
  cat "$TEST_ENV_DIR/doctor_bad_gnu.log" 2>/dev/null || true
  exit 1
fi
rm -f "$TEST_ENV_DIR/bin/stat"
echo -e "${GREEN}PASS: --doctor exits 1 when check_gnu_userland fails.${NC}"

if ! run_test_case "Doctor With List Targets Rejected" 1 "doctor_mx_list.log" --doctor --list-targets \
   || ! run_test_case "Doctor With Only Target Rejected" 1 "doctor_mx_only.log" --doctor --only-target NPM \
   || ! run_test_case "Doctor With JSON Rejected" 1 "doctor_mx_json.log" --doctor --json; then
  echo -e "${RED}FAIL: --doctor did not reject incompatible mode, filter, or --json flags.${NC}"
  exit 1
fi
echo -e "${GREEN}PASS: --doctor rejects other modes, filter flags, and --json.${NC}"

# A discovery miss names every searched location and points at --doctor; the
# /etc candidate is redirected in a copy so the host's own install cannot hide the miss.
echo -e "\n${BOLD}Test Case: Config Not Found Lists Searched Locations${NC}"
nc_dir="$TEST_ENV_DIR/no_config_checkout"
mkdir -p "$nc_dir/xdg"
sed 's|"/etc/linux-cleaner/cleaner.conf"|"'"$nc_dir"'/etc/cleaner.conf"|' "$CLEANER_SH" > "$nc_dir/cleaner.sh"
nc_ec=0
XDG_CONFIG_HOME="$nc_dir/xdg" HOME="$MOCK_HOME" bash "$nc_dir/cleaner.sh" < /dev/null > "$nc_dir/miss.log" 2>&1 || nc_ec=$?
if [[ "$nc_ec" -ne 1 ]] \
   || ! grep -qxF "  searched: $nc_dir/xdg/linux-cleaner/cleaner.conf" "$nc_dir/miss.log" \
   || ! grep -qxF "  searched: $nc_dir/etc/cleaner.conf" "$nc_dir/miss.log" \
   || ! grep -qxF "  searched: $nc_dir/cleaner.conf" "$nc_dir/miss.log" \
   || ! grep -qxF "Run 'cleaner --doctor' to check the environment." "$nc_dir/miss.log"; then
  echo -e "${RED}FAIL: a config discovery miss did not list the searched locations and the --doctor hint (ec=$nc_ec).${NC}"
  cat "$nc_dir/miss.log" 2>/dev/null || true
  exit 1
fi
nc_ec=0
HOME="$MOCK_HOME" bash "$nc_dir/cleaner.sh" -c "$nc_dir/missing.conf" < /dev/null > "$nc_dir/explicit.log" 2>&1 || nc_ec=$?
if [[ "$nc_ec" -ne 1 ]] || ! grep -qF "Configuration file not found at '$nc_dir/missing.conf'" "$nc_dir/explicit.log" \
   || grep -q "searched:\|--doctor" "$nc_dir/explicit.log"; then
  echo -e "${RED}FAIL: an explicit missing config path changed its error (ec=$nc_ec).${NC}"
  cat "$nc_dir/explicit.log" 2>/dev/null || true
  exit 1
fi
echo -e "${GREEN}PASS: a config discovery miss lists every searched location and the --doctor hint; an explicit path does not.${NC}"

# A file or build tree can be rewritten after analysis and before deletion.
# The pre-delete process check is the seam: its second pgrep touches the
# target, which must then be skipped instead of removed. A still-old control
# is cleaned. Removing the freshness re-check deletes the touched path.
echo -e "\n${BOLD}Test Case: Freshness Recheck Before Whole-Target Cleanup${NC}"
freshness_recheck_case() {
  local kind="$1" mode="$2"
  local fresh control conf log control_bytes skip_line
  setup_mock_env
  conf="$TEST_ENV_DIR/freshness.conf"
  log="freshness_${kind}_${mode}.log"
  rm -f "$TEST_ENV_DIR/freshness_pgrep_count"
  if [[ "$kind" == "file" ]]; then
    fresh="$MOCK_HOME/stale_file.txt"
    control="$MOCK_HOME/still_old.txt"
    printf 'stale\n' > "$fresh"
    printf 'old\n' > "$control"
    touch -d '40 days ago' "$fresh" "$control"
    printf '%s\n' "$fresh" > "$TEST_ENV_DIR/freshness_touch_path"
    cat > "$conf" <<'EOF'
safe|Stale File|$HOME/stale_file.txt|single file past min age|14|fresh_probe|
safe|Still Old|$HOME/still_old.txt|control file past min age|14||
EOF
    skip_line="[SKIP] Stale File: skipped: no longer older than 14 days."
  else
    fresh="$MOCK_HOME/proj/stale/build"
    control="$MOCK_HOME/proj/idle/build"
    mkdir -p "$fresh/CMakeFiles" "$control/CMakeFiles"
    printf 'CMAKE_CACHE_MAJOR_VERSION:INTERNAL=3\n' > "$fresh/CMakeCache.txt"
    printf 'stale-obj\n' > "$fresh/CMakeFiles/old.o"
    printf 'CMAKE_CACHE_MAJOR_VERSION:INTERNAL=3\n' > "$control/CMakeCache.txt"
    printf 'idle-obj\n' > "$control/CMakeFiles/old.o"
    touch -d '40 days ago' "$fresh/CMakeCache.txt" "$fresh/CMakeFiles/old.o" \
      "$fresh/CMakeFiles" "$fresh" \
      "$control/CMakeCache.txt" "$control/CMakeFiles/old.o" \
      "$control/CMakeFiles" "$control"
    printf '%s\n' "$fresh/CMakeFiles/old.o" > "$TEST_ENV_DIR/freshness_touch_path"
    cat > "$conf" <<'EOF'
safe|Stale Build|$HOME/proj/stale/build|idle cxx build|14|fresh_probe|filter:cxx_build
safe|Still Idle|$HOME/proj/idle/build|control idle cxx build|14||filter:cxx_build
EOF
    skip_line="[SKIP] Stale Build: skipped: active within 14 days."
  fi
  cat > "$TEST_ENV_DIR/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
count_file="${TEST_ENV_DIR}/freshness_pgrep_count"
n=0
[[ -f "$count_file" ]] && n=$(cat "$count_file")
n=$((n + 1))
printf '%s\n' "$n" > "$count_file"
if [[ "$n" -eq 2 ]]; then
  touch -- "$(cat "${TEST_ENV_DIR}/freshness_touch_path")"
fi
exit 1
EOF
  chmod +x "$TEST_ENV_DIR/bin/pgrep"
  control_bytes=$(du -sb "$control" | awk '{print $1}')
  local -a flags=(--config "$conf" --clean --force)
  [[ "$mode" == "trash" ]] && flags+=(--trash)
  if ! run_test_case "Freshness $kind $mode" 0 "$log" "${flags[@]}"; then
    return 1
  fi
  local survived=false accounted="Accounted bytes: quarantined=0 permanent=${control_bytes}"
  if [[ "$kind" == "file" ]]; then
    [[ -f "$fresh" ]] && grep -qxF 'stale' "$fresh" && survived=true
  else
    [[ -f "$fresh/CMakeFiles/old.o" ]] && grep -qxF 'stale-obj' "$fresh/CMakeFiles/old.o" && survived=true
  fi
  [[ "$mode" == "trash" ]] && accounted="Accounted bytes: quarantined=${control_bytes} permanent=0"
  if [[ "$survived" != true ]] \
     || [[ -e "$control" ]] \
     || ! grep -qF "$skip_line" "$TEST_ENV_DIR/$log" \
     || ! grep -q '^Result: cleaned=1 skipped=1 failed=0 elapsed=' "$TEST_ENV_DIR/$log" \
     || ! grep -qF "$accounted" "$TEST_ENV_DIR/$log" \
     || [[ "$(cat "$TEST_ENV_DIR/freshness_pgrep_count")" != "2" ]]; then
    echo -e "${RED}FAIL: freshness re-check ($kind, $mode) did not skip the rewritten target and clean only the still-old control.${NC}"
    cat "$TEST_ENV_DIR/$log" 2>/dev/null || true
    return 1
  fi
  return 0
}
for freshness_kind in file build; do
  for freshness_mode in clean trash; do
    freshness_recheck_case "$freshness_kind" "$freshness_mode" || exit 1
  done
done
echo -e "${GREEN}PASS: a single file or cxx_build tree rewritten after analysis is skipped for --clean and --trash; a still-old control is cleaned.${NC}"

echo -e "\n${BOLD}${GREEN}All refactored tests passed successfully!${NC}"
exit 0
