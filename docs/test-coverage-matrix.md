# Test coverage matrix

## 1.3.0 shipped feature inventory

Rows below moved here after the 1.3.0 release; add new unreleased rows only while `[Unreleased]` in `CHANGELOG.md` still holds entries.

| ID | Feature | Test case |
|----|---------|-----------|
| U-01 | LINUX_CLEANER_ONLY_TARGET | LINUX_CLEANER_ONLY_TARGET Env |
| U-02 | --list-targets --json | List Targets JSON |
| U-03 | LINUX_CLEANER_RISK | LINUX_CLEANER_RISK Env |
| U-04 | LINUX_CLEANER_TRASH | LINUX_CLEANER_TRASH Env |
| U-05 | NO_COLOR | NO_COLOR Disables ANSI |
| U-06 | LINUX_CLEANER_EXCLUDE | LINUX_CLEANER_EXCLUDE Env |
| U-07 | LINUX_CLEANER_FORCE | LINUX_CLEANER_FORCE Env |
| U-08 | LINUX_CLEANER_YES_DANGER | LINUX_CLEANER_YES_DANGER Env |
| U-09 | --list-sessions --json | List Sessions JSON / List Sessions JSON Empty |
| U-10 | LINUX_CLEANER_ALLOW_OUTSIDE_HOME deprecated no-op warning | LINUX_CLEANER_ALLOW_OUTSIDE_HOME Env |
| U-11 | --list-targets --json description/min_age_days | List Targets JSON |
| U-12 | --exclude-target / LINUX_CLEANER_EXCLUDE_TARGET | Exclude Target Dry Run / Env |
| U-13 | LINUX_CLEANER_CONFIG | LINUX_CLEANER_CONFIG Env |
| U-14 | --check-config | Check Config Valid / Invalid |
| U-15 | --list-targets --json check_processes/custom_action | List Targets JSON |
| U-16 | action:zypper_clean | Cross-Distro Actions / Action Required Binary Mapping |
| U-17 | human --list-targets description column | List Targets |
| U-18 | action:zypper_clean absent skip | Zypper Safe Degradation |
| U-19 | Excluded single-file targets remain untouched beside eligible siblings | Excluded Single File (delete) / Excluded Single File (trash) |
| U-20 | Padded build filters protect literal and wildcard targets | Build Filter Inventory (wildcard/literal human/json) / Build Filter Cleanup (wildcard/literal) |
| U-21 | Validate raw wildcard definitions independently of filesystem matches | Unmatched Wildcard Validation (check/inventory/json/clean) / Check Config Counts Definitions Without Traversal |
| U-22 | Wildcard discovery cannot redirect cleanup through unusual filenames | Wildcard Path Identity Inventory (delete/trash) / Wildcard Path Identity Cleanup (delete/trash) |
| U-23 | Absent package managers skip without sudo and preserve ordinary cleanup | Absent Action JSON Without Sudo / Absent Action Cleanup Without Sudo |
| U-24 | Failed quarantine traversal preserves retryable payload and metadata | Trash Traversal Failure / Selective Restore Traversal Failure / Restore Traversal Failure Retry / Purge Enumeration Failure |
| U-25 | Filtered recursive discovery traverses rejected parents without overlapping accepted targets | Filtered Nested Build Inventory / Filtered Nested Build Cleanup |
| U-26 | Targets and sessions with unreadable subdirectories are measured without aborting | Partly Unreadable Dry Run / JSON / Aged Dry Run / Session List / Session JSON |
| U-27 | CHECK_PROCESSES tokens are not glob-expanded against the working directory | Glob Process Token |
| U-28 | Runbook validator runs without ripgrep and rejects undocumented flags | runbook validator runs without ripgrep |
| U-29 | Top-level /opt, /srv, /tmp, /run, /mnt, /media are UNSAFE | Top-Level System Directories |
| U-30 | --restore and --purge-sessions outcomes in the opt-in operation log | Log Restore / Log Purge / Unlogged Purge |
| U-31 | Restore mkdir failure keeps metadata aligned | Restore Mkdir Failure |
| U-32 | Aged quarantine chown failure is recorded and later targets run | Aged Quarantine Chown Failure |
| U-33 | check-aur-ready rejects a SKIP checksum | check-aur-ready rejects a SKIP checksum |
| U-34 | Failed sudo authentication during restore keeps metadata aligned | Restore Sudo Auth Failure |
| U-35 | Plain CHECK_PROCESSES names longer than 15 characters match the kernel process name | Dry Run Mode (Default) / Bare Token Still Matches Comm |
| U-36 | action:apk_clean | Cross-Distro Actions / Action Required Binary Mapping / Apk Safe Degradation |
| U-37 | Failed aged quarantine move leaves no phantom metadata or empty staging dir | Failed Quarantine Move Not Recorded / Restore After a Failed Quarantine Move |
| U-38 | Per-target exclude:NAME[,NAME...] in CUSTOM_ACTION | Row Exclusion Age 7 (permanent, none) / Row Exclusion Dry Run Size (age 7) / Row Exclusion Wildcard Inventory (json) / Row Exclusion Validation (exclude:memory) |
| U-39 | --debug and LINUX_CLEANER_DEBUG show per-target FOUND and CLEAN lines | Debug Dry Run Output |
| U-40 | Git-tracked target guard skips targets holding tracked files | Git-Tracked Target Guard JSON / Git-Tracked Target Guard |
| U-41 | Outside-HOME targets need no extra prompt; (outside HOME) FOUND suffix | Outside HOME with --allow-outside-home / Outside HOME Single Confirmation |
| U-42 | --dry-run --json description/min_age_days | JSON Dry Run |
| U-43 | Plan report before cleanup and result report after | Plan Report Dry Run / Plan Report Quiet / Result Report Clean / Plan Report JSON |
| U-44 | Non-dry-run cleanup writes last-report.txt in a 0700 directory; dry-run and --quiet still keep the plan in the file | Last Report Saved / Last Report Dry Run / Last Report Quiet |
| U-45 | --report prints the saved report or exits 1 when it is absent | Last Report Print / Last Report Missing |
| U-46 | A symlinked state directory is not written | Last Report Symlink |
| U-47 | --report is mutually exclusive with --list-sessions | Report With List Sessions Rejected |
| U-48 | --allow-outside-home and LINUX_CLEANER_ALLOW_OUTSIDE_HOME warn at most once and the run succeeds | Outside HOME with --allow-outside-home / LINUX_CLEANER_ALLOW_OUTSIDE_HOME Env / Allow Outside HOME Deprecation Once |
| U-49 | Root-requiring target is skipped when sudo cannot authenticate; a sibling is still cleaned | Root Skip Without Privileges |
| U-50 | User-defined `protect|PATH` skips equal, under, contains, and wildcard-expanded targets while cleaning siblings | Protect List Targets / Protect List Targets JSON / Protect Debug Dry Run / Protect Dry Run JSON / Protect Clean Force |
| U-51 | `--check-config` accepts valid `protect|PATH` lines without counting them as targets and rejects empty, relative, glob-bearing, or extra-field `protect` lines with `file:line` | Protect Check Config Valid / Protect Invalid (empty, relative, glob_star, glob_qmark, glob_bracket, extra) |
| U-52 | `filter:cxx_build` with `MIN_AGE_DAYS > 0` cleans build directories as a whole only when idle and leaves active build trees untouched while keeping per-file age deletion on other rows | Idle Builds Debug Dry Run / Idle Builds Clean Force |
| U-53 | `strip_trailing_slashes` strips all trailing slashes so symlink targets with repeated trailing slashes are refused as `[SYMLINK]` | Symlink Target Trailing Slashes |
| U-54 | Quarantine session directories (`mkdir -m 700`) and newly created quarantine base directories are created with mode `0700` regardless of caller umask | Quarantine Session And Base Mode 0700 |
| U-55 | Restore rejects symlink conflicts at the original path (full and aged) or any existing intermediate directory component under an aged target, logging `outcome=conflict` and keeping the session retryable | Restore Aged Subdir Symlink Conflict / Restore Aged Subdir Symlink Retry / Restore Aged Original Path Symlink Conflict / Restore Aged Original Path Symlink Retry / Restore Full Original Path Symlink Conflict |
| U-56 | Wildcard patterns with `**` match non-`**` components (`*`, `?`, literals) within a single directory component only, without pruning deeper valid matches beneath rejected parents | Wildcard Component Matching Dry Run |
| U-57 | The result report counts analysis-time skips (requires root) so `Result: skipped=` matches the plan's `skipped=`, and a declined interactive target is counted once | Root Skip Without Privileges / Interactive Per-Target Confirmation |
| U-58 | User-level prune actions (`action:uv_cache_prune`, `action:pnpm_store_prune`, `action:hf_cache_prune`) run as the invoking user without `sudo` and never report `requires root` | User Actions Clean Force Without Sudo |
| U-59 | Missing user-action binary (`uv`, `pnpm`, `hf`) skips its row cleanly without failing the run or calling `sudo` | Action Required Binary Mapping / User Actions Missing Binary Skips Cleanly |
| U-60 | Running `uv`, `pnpm`, or `hf` process blocks its user-action row via `CHECK_PROCESSES` | User Actions Blocked By Running Process |
| U-61 | `--dry-run` never executes user-level prune actions and reports `0 B` reclaimable with run-time size notice | User Actions Dry Run Invokes No Mocks |
| U-62 | User-level prune actions credit filesystem free-space delta (`df -B1 --output=avail`, clamped at 0) instead of planned directory `du`, and warn in `--trash` mode | User Actions Credit DF Delta Not Planned DU |
| U-63 | System package-cache actions continue routing through `sudo` and crediting planned `du` alongside user-level actions | System Action Still Uses Sudo Alongside User Action |
| U-64 | A target containing `$HOME` (an ancestor of it, e.g. `$HOME/..`) is `[UNSAFE]` and survives `--clean --force` | Ancestor of HOME UNSAFE |
| U-65 | The opt-in operation log records `outcome=failed` for a failed delete and `outcome=success` for a successful (including 0-byte) one, never `outcome=attempted` | Log Records Failed And Zero-Byte Outcomes |
| U-66 | `--purge-sessions older-than:DAYS` exits 0 when no quarantine directory exists and still rejects an invalid day count | Retention Purge Without Quarantine Dir / Invalid Retention Days Without Quarantine Dir |
| U-67 | `--interactive` shows `size at run time` instead of `0 B` for user-level prune actions | User Action Interactive Shows Run-Time Size |
| U-68 | User-level prune actions pass the configured path (`--cache-dir` / `--store-dir`) and hide their FOUND line unless `--debug` is set | User Actions Clean Force Without Sudo / User Actions Dry Run Invokes No Mocks |
| U-69 | `--dry-run --json` marks user-level prune actions with `size_at_run_time: true` and `size_human: "size at run time"`, and every other target with `size_at_run_time: false` | User Actions Dry Run JSON Marks Run-Time Size / User Actions Dry Run JSON Plain Target False |
| U-70 | `--dry-run --json` carries `reason` per target: empty for found targets, the plan-report reason for blocked and skipped ones | Dry Run JSON Reports Skip Reasons / JSON Dry Run |
| U-71 | Comma-separated `--only-target` / `--exclude-target` patterns select/skip the union and reject empty tokens | Only Target Comma List Dry Run / Exclude Target Comma List Dry Run / Only Target Comma List Env / Only Target Empty Token Rejected |
| U-72 | `--min-reclaim SIZE` and `LINUX_CLEANER_MIN_RECLAIM` skip cleanup below threshold and validate size/mode combinations | Min Reclaim Above Total Skips / Min Reclaim Below Total Cleans / Min Reclaim Env / Min Reclaim Invalid Size / Min Reclaim With Restore Rejected |
| U-73 | `$XDG_CACHE_HOME`, `$XDG_CONFIG_HOME`, `$XDG_DATA_HOME`, and `$XDG_STATE_HOME` whole-token config path placeholders with spec defaults for unset or relative values | XDG Cache Placeholder (absolute) / XDG Cache Placeholder (unset) / XDG Cache Placeholder (relative) |

## Drift guards

| Test heading | Invariant | Files watched |
|--------------|-----------|---------------|
| Man Page Option Consistency | help options in man | cleaner.sh, cleaner.1 |
| Man Page Env Var Parity | env vars in man | cleaner.sh, cleaner.1, README.md |
| Stranded [Unreleased] Entries Are Detected | no stranded changelog | CHANGELOG.md, test_cleaner.sh |
| Release Notes Extraction | release-notes.sh contract | release-notes.sh, .github/workflows/release.yml |
| Changelog/Version Consistency | version sync | cleaner.sh, cleaner.1, PKGBUILD, .SRCINFO, CHANGELOG.md |
| Package Install Scriptlet Is Hint Only | pacman scriptlet prints the opt-in hint, calls no systemctl, no post_upgrade | linux-cleaner.install, PKGBUILD, .SRCINFO |
| ShellCheck Invocation Parity | lint parity | ci.yml, release.yml, README.md, RELEASING.md, CONTRIBUTING.md, Makefile |

Manual smoke: see `docs/manual-smoke-checklist.md`.
