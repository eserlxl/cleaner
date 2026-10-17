# Test coverage matrix

## Unreleased

| ID | Feature | Test case |
|----|---------|-----------|
| U-86 | Restore creates missing aged, nested, and full-target parent directories with mode `0700` under umask `022`, including a sudo shim that resets umask, while preserving existing directory modes and contents | Restore Private Directories Direct / Restore Private Directories Sudo |
| U-87 | AUR preparation rejects literal `SKIP` regardless of quoting or multiline formatting and rejects unsupported/nonliteral arrays without executing package code; pinned checksums with comments pass, and absent `AUR_PREP` remains a no-op | AUR Checksum Gate single-quoted-skip / double-quoted-skip / unquoted-skip / multiline-skip / pinned / multiline-pinned / append / indexed / dynamic / empty / unclosed / missing |
| U-88 | Completed aged restores checkpoint atomically before staging cleanup, survive process interruption and metadata failures, preserve marked payload and pending siblings, and keep public inventory types unchanged | Aged Restore Interrupted / Aged Restore Interrupted Retry / Aged Restore Metadata Failure / Aged Restore Metadata Failure Retry / Aged Restore Marked Payload Kept / Aged Restore Marker Human Inventory / Aged Restore Marker JSON Inventory / Aged Restore Marker Selective / Aged Restore Marker Selective Retry |
| U-89 | Saved reports expose inline retention removal/enumeration failures at all cleanup exits, keep target counts independent, distinguish cancellation, preserve the current report during retention interruption and legacy/no-retention null, and retain standalone purge failure status | Retention Report / Retention Report JSON / Retention Interrupted Keeps Current Report / Retention Interrupted Report JSON / Retention Standalone Purge Failure / Report JSON After Cleanup / Report JSON After Interrupted Cleanup |
| U-90 | Both installers ship the environment template byte-for-byte with mode `0644`, honor custom `DATADIR`/`PKGNAME`, and uninstall only the shipped copy and empty directory while preserving config, user copies, and sibling files | Installer DESTDIR Smoke Test / Environment Template Custom Paths (sh) / Environment Template Custom Paths (make) |
| U-91 | Session inventory refuses total or partial enumeration failure with nonzero status, an error, empty stdout, and unchanged metadata/payload in both human and JSON formats | List Sessions Enumeration Failure (human total) / List Sessions Enumeration Failure (human partial) / List Sessions Enumeration Failure (json total) / List Sessions Enumeration Failure (json partial) |
| U-92 | JSON inventory and max-size purge reject first/late failed measurements, partial output with failure, and malformed successful output before stdout or deletion, preserving payload and metadata | Quarantine Size Failure (json first / late / partial / malformed) / Quarantine Size Failure (budget first / late / partial / malformed) |
| U-93 | Configured-target inventories share cleanup NAME selection, comma/space and literal case-sensitive matching, exclusion/error precedence, environment/CLI overrides and wildcard expansion without analysis or mutation, preserving raw validation and all-risk inventory | Only Target With List Targets / Exclude Target With List Targets / Inventory NAME Selection (human/json) / Mode Flag Exclusion Docs Parity |
| U-94 | Saved-report JSON preserves exact accounted quarantine/permanent bytes, action credits, early zeros and interrupted credits; historical/malformed records remain null, retention rewrites preserve counters and cancellation preserves the prior report | Report JSON After Cleanup / Report JSON Permanent Bytes / Report JSON Mixed Trash Action Bytes / Report JSON Action DF Bytes / Report JSON Seed Nothing To Clean / Report JSON Seed Min Reclaim / Report JSON Interrupted Accounted Bytes / Report JSON After Interrupted Cleanup / Report JSON Malformed Bytes / Report Cancel Preserves Bytes / Retention Report JSON / Retention Interrupted Report JSON |
| U-95 | Saved reports preserve exact ordered failed NAMEs with commas, quotes, backslashes and control bytes from action and ordinary failures, including interrupted and retention saves; empty reports and historical comma-summary fallback remain compatible | Report Exact Failed Names / Report JSON Exact Failed Names / Report JSON After Cleanup / Report JSON Seed Nothing To Clean / Report JSON Seed Min Reclaim / Report JSON After Interrupted Cleanup |
| U-96 | Positive PATH selection shares physical whole-component matching across human/JSON inventory and cleanup; validates scopes, composes NAME filters, excludes external actions, preserves siblings and safety guards, and avoids read-only analysis/state changes | Only Path human/json / Only Path clean one shared-NAME project / Only Path LF candidate cannot delete sibling / Only Path age guard cleanup / Path Expansion Safety / Mode Flag Exclusion Docs Parity |
| U-97 | Physical component resolution rejects raw/resolved LF and partial-output producer failures, propagates errors before cleanup/protection/log writes, and preserves missing tails, relative/dot-dot/root paths and final-symlink refusal | Canonical Path resolved LF alias dry run / Canonical Path aborts cleanup / Canonical Path extra protection fails closed / Canonical Path final symlink / Canonical Path failed log resolution writes nothing |
| U-98 | Config discovery/init and report reads/writes preserve one or multiple trailing LF in absolute XDG storage directories, exact siblings, defaults and explicit config precedence; private modes, symlink/overwrite guards and nonfatal writer failures remain intact | XDG Storage report human/json / XDG Storage config discovery/check / XDG Storage initialize exact config / XDG Storage save exact report / XDG Storage helper failure |
| U-99 | NAME filters preserve complete comma-separated CLI/environment values, trim boundary LF, retain internal LF literally, honor later fields and CLI overrides, and reject leading/consecutive/trailing hidden empty fields consistently without read-only side effects | Inventory NAME Selection (human/json LF) / NAME LF Dry Run |
| U-100 | Trimming preserves literal values that match `echo` options across NAME filters and configuration, including whitespace, exact JSON names/descriptions, percent/backslash bytes, check-config, dry-run, and empty-pattern rejection | NAME Trim Echo Options |
| U-101 | Complete CLI/environment global exclusions preserve LF whitespace, literal internal LF, later fields and appended row protection without leaking row exclusions; empty entries and CLI precedence retain exact eligible sizes at age zero and positive ages without state changes | Complete Exclusion List |
| U-102 | Environment project scope shares human/JSON inventory, dry-run and isolated cleanup selection; literal paths, CLI overrides, empty defaults, invalid effective scopes, mode/retention exclusions and read-only state/probe guards remain enforced | Only Path human/json environment / Only Path CLI overrides / Only Path environment mutex / Only Path environment dry-run parity / Only Path environment clean one shared-NAME project |
| U-103 | Installed monitor command previews default, independent and explicitly shared profiles; config/risk/NAME/path/exclusion selection, inherited execution/JSON overrides and invalid combinations preserve payload and all report/log/quarantine/lock state | Monitor Profile |
| U-104 | Config initialization preserves regular, directory, symlink and dangling destinations appearing at final publication, reports refusal without success or temporary leaks, and preserves true move-failure cleanup and normal mode `0644` | Init Config Publication |
| U-105 | Exact restore selects literal inventory paths without prefix-sibling matches, preserves pending metadata and aged checkpoints, supports later full restore and repeated selectors, and rejects mixed/invalid usage before locking | Restore Exact |
| U-106 | Session inventory counts literal unrecorded immediate entries across all entry types, nested references, missing metadata and real append failure; total/partial/late read or enumeration errors precede JSON and block purge/inline retention | Unrecorded Inventory |

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
| U-26 | Target estimates and human session listing tolerate unreadable subdirectories; JSON session inventory rejects failed measurements | Partly Unreadable Dry Run / JSON / Aged Dry Run / Session List; Session JSON requires successful full measurement |
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
| U-74 | Every `examples/systemd/*.service` carries exactly one `SyslogIdentifier=linux-cleaner` line, so `journalctl --user -t linux-cleaner` finds all three units | inline drift check "every systemd service tags its journal output as linux-cleaner" |
| U-75 | Relative `XDG_CONFIG_HOME` / `XDG_STATE_HOME` values are ignored for the config search and the saved cleanup report | Relative XDG_STATE_HOME Ignored / Relative XDG_CONFIG_HOME Ignored |
| U-76 | `--init-config` copies the active config to the user config path without overwriting or following symlinks | Init Config Creates User Config / Init Config Refuses Overwrite / Init Config Refuses Symlinked Directory / Init Config Used By Next Run / Init Config With List Targets Rejected |
| U-77 | A dry-run that found something to clean ends with a `Next:` line naming `cleaner --clean` (and `--trash`); hidden under `--quiet`, for empty plans, and when `--min-reclaim` would skip | Dry Run Next Step Hint / Dry Run Next Step Hint Quiet / Dry Run Next Step Hint Nothing To Clean / Min Reclaim Dry Run Note |
| U-78 | Aged quarantine writes its `quarantine.meta` record on the first moved file so an interrupted run stays restorable with `--restore` while uninterrupted runs write one record per target | Trash Aged Interrupted Keeps Metadata / Restore Interrupted Aged Quarantine / Uninterrupted Aged Quarantine Single Record |
| U-79 | Mutating runs (`--clean`, `--restore`, `--purge-sessions`) acquire a non-blocking `flock` on `~/.cache/linux-cleaner/cleaner.lock` (refusing symlinks) and exit `1` on contention while dry-run and read-only modes never take the lock | inline drift check "the retention unit is ordered after the cleanup unit" / Concurrent Run Lock / Concurrent Run Lock Restore / Concurrent Run Lock Purge / Concurrent Run Lock Dry Run Unaffected / Concurrent Run Lock List Targets Unaffected / Concurrent Run Lock List Sessions Unaffected / Concurrent Run Lock Check Config Unaffected / Concurrent Run Lock Report Unaffected / Concurrent Run Lock Released Clean Succeeds / Concurrent Run Lock Refuses Symlink |
| U-80 | A cleanup interrupted by `SIGINT` or `SIGTERM` prints and saves its partial result report with `Interrupted: SIGINT\|SIGTERM before all targets finished`, logs `mode=run outcome=interrupted`, and exits `130`/`143` while uninterrupted runs have no `Interrupted:` line | Interrupted Cleanup Saves Report / Interrupted Cleanup Report Command / Uninterrupted Cleanup Report Has No Interrupted Line |
| U-81 | A retried `--restore` after an interrupted restore treats a missing quarantined payload whose original path is present again as already restored, drops its stale `quarantine.meta` record, and retires the session while a truly missing payload still exits `1` | Restore Retry After Interrupted Restore / Restore Missing Source Still Fails / Restore Missing Aged Source Still Fails |
| U-82 | `--trash` checks free space on the quarantine filesystem before a cross-filesystem move and refuses a target whose planned size exceeds available space, leaving it in place without creating a session record, while fitting or same-filesystem quarantines proceed | Trash Cross Filesystem Space Guard / Trash Cross Filesystem Space Guard Fits |
| U-83 | `--trash-keep-days DAYS` and `LINUX_CLEANER_TRASH_KEEP_DAYS` purge quarantine sessions older than `DAYS` days at the end of every non-dry-run cleanup (including one with nothing to clean) while keeping recent and newly created sessions, leaving dry-run untouched, and validating day count and mode combinations | Trash Keep Days Dry Run Purges Nothing / Trash Keep Days Purges Old Sessions / Trash Keep Days Keeps Recent Sessions / Trash Keep Days Rejected With Restore / Trash Keep Days Invalid Value Rejected / Trash Keep Days Nothing To Clean |
| U-84 | `--report --json` prints the saved cleanup report as JSON (`saved`, `result`, `cleaned`, `skipped`, `failed`, `elapsed_seconds`, `failed_targets`, `quarantine_session`, `interrupted`) and exits `1` when the report is absent | Report JSON After Cleanup / Report JSON After Interrupted Cleanup / Report JSON Without Report |
| U-85 | `--purge-sessions max-size:SIZE` walks quarantine sessions newest-first summing `du -sb` and purges every session once the running total exceeds `SIZE` (sharing `parse_size_bytes` with `--min-reclaim`), exiting `0` when within budget or when no quarantine directory exists and `1` on an invalid or overflowing `SIZE` | Purge Sessions Max Size Keeps Newest / Purge Sessions Max Size Nothing To Purge / Purge Sessions Max Size Missing Base / Purge Sessions Max Size Invalid / Purge Sessions Max Size Too Large / Purge Enumeration Failure (max-size:1G) |

## Drift guards

| Test heading | Invariant | Files watched |
|--------------|-----------|---------------|
| Man Page Option Consistency | help options in man | cleaner.sh, cleaner.1 |
| Man Page Env Var Parity | env vars in man | cleaner.sh, cleaner.1, README.md, docs/cli-reference.md |
| Stranded [Unreleased] Entries Are Detected | no stranded changelog | CHANGELOG.md, test_cleaner.sh |
| Release Notes Extraction | release-notes.sh contract | release-notes.sh, .github/workflows/release.yml |
| Changelog/Version Consistency | version sync | cleaner.sh, cleaner.1, PKGBUILD, .SRCINFO, CHANGELOG.md |
| Package Install Scriptlet Is Hint Only | pacman scriptlet prints the opt-in hint, calls no systemctl, no post_upgrade | linux-cleaner.install, PKGBUILD, .SRCINFO |
| ShellCheck Invocation Parity | lint parity | ci.yml, release.yml, README.md, RELEASING.md, CONTRIBUTING.md, Makefile |
| Version/Tag/Changelog Consistency | on a `v*` tag, the tag, `cleaner.sh --version` and the newest CHANGELOG section agree and nothing is left under `[Unreleased]` | cleaner.sh, CHANGELOG.md |
| Config Guide Target Count | docs/configuration.md quotes the shipped config's `--check-config` count | docs/configuration.md, cleaner.conf |
| Mode Flag Exclusion Docs Parity | every "Cannot be combined with" list names the partners cleaner.sh refuses | cleaner.sh, docs/cli-reference.md, cleaner.1 |

Manual smoke: see `docs/manual-smoke-checklist.md`.
