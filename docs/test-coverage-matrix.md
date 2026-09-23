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
| U-10 | LINUX_CLEANER_ALLOW_OUTSIDE_HOME | LINUX_CLEANER_ALLOW_OUTSIDE_HOME Env |
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
| U-28 | Runbook validator runs without ripgrep and rejects undocumented flags | runbook validator ripgrep-free check |
| U-29 | Top-level /opt, /srv, /tmp, /run, /mnt, /media are UNSAFE | Top-Level System Directories |
| U-30 | --restore and --purge-sessions outcomes in the opt-in operation log | Log Restore / Log Purge / Unlogged Purge |

## Drift guards

| Test heading | Invariant | Files watched |
|--------------|-----------|---------------|
| Man Page Option Consistency | help options in man | cleaner.sh, cleaner.1 |
| Man Page Env Var Parity | env vars in man | cleaner.sh, cleaner.1, README.md |
| Stranded [Unreleased] Entries Are Detected | no stranded changelog | CHANGELOG.md, test_cleaner.sh |
| Release Notes Extraction | release-notes.sh contract | release-notes.sh, .github/workflows/release.yml |
| Changelog/Version Consistency | version sync | cleaner.sh, cleaner.1, PKGBUILD, CHANGELOG.md |
| ShellCheck Invocation Parity | lint parity | Makefile, ci.yml, test_cleaner.sh |

Manual smoke: see `docs/manual-smoke-checklist.md`.
