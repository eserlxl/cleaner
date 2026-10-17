# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Versioning

This project follows [Semantic Versioning (SemVer)](https://semver.org/). Bump policy:

- **Major** — a breaking change to the `cleaner.conf` format or the CLI contract.
- **Minor** — a new feature, a change to a safety guard, or a new predefined config action.
- **Patch** — a bug fix, documentation, or internal change with no behavior change.

## [Unreleased]

### Changed

- Align configuration guidance with the existing target classes and exceptions.

### Added

- `--lock-wait SECONDS` and `LINUX_CLEANER_LOCK_WAIT` let scheduled mutations wait
  for the existing exclusive lock, preserving fail-fast defaults and read-only modes.

- Session inventory adds `unrecorded_entry_count` and human warnings for immediate
  entries absent from metadata accounting; failed reads stop inventory and purge.

- `--restore --only-exact PATH` selects records by their literal original path,
  preserving prefix siblings and their recovery metadata for later restoration.

- The installed monitor accepts an optional independent `monitor.env` profile for
  scoped JSON previews; explicit dry-run/JSON flags preserve preview-only behavior.

- `LINUX_CLEANER_ONLY_PATH` extends positive project selection to scheduled cleanup
  environment files; CLI scope overrides it, with the same safety and mode guards.
- `--only-path PATH` selects one existing project’s ordinary targets
  across cleanup and human/JSON inventory, composing with NAME filters while
  preserving sibling projects and excluding external actions and global retention.
  Placeholder expansion rejects line feeds without silently selecting a sibling path.
- Saved-report JSON exposes nullable `quarantined_bytes` and `permanent_bytes`
  integers, preserving existing accounted cleanup estimates without rounding,
  including early exits and already-credited interrupted work; retention volume
  is excluded and historical/malformed byte records remain `null` (MINOR-compatible capability).
- Configured-target inventories support the existing `--only-target` and
  `--exclude-target` NAME filters and environment mirrors, sharing cleanup matching
  and empty-selection errors without disk or process analysis (MINOR-compatible capability).
- Both installers ship the scheduled cleanup environment template under
  `$DATADIR/$PKGNAME/linux-cleaner.env.example` with mode `0644`; uninstall
  preserves user copies and unrelated files.
- Saved cleanup reports expose inline retention failures separately from target
  counts, including the additive nullable `retention_failed` JSON field
  (MINOR-compatible capability).

### Fixed

- Configuration initialization preserves destinations created by another writer
  during publication and reports refusal instead of overwriting them.

- Global exclusion lists preserve patterns after line feeds and appended per-target
  exclusions, while continuing to ignore empty global entries.

- Preserve literal NAME filters and configuration values equal to `echo` options
  when trimming whitespace.

- NAME filters split the complete CLI/environment value only at commas, preserving
  internal line feeds and rejecting empty fields even after line feeds.

- Configuration discovery/initialization and saved reports preserve exact absolute
  XDG directory names, including trailing line feeds, instead of selecting a sibling.

- Physical path resolution preserves component identity and fails closed on line
  feeds or resolver errors across cleanup, protection, safety checks, and logging.

- Saved-report JSON preserves exact failed target names, including punctuation,
  through completed, interrupted, and retention-updated reports.
- JSON session inventory and budgeted purge reject unavailable or invalid session
  sizes before publishing inventory or deleting sessions.
- Session inventory exits with an error instead of printing a successful empty or
  partial list when directory enumeration fails, in both human and JSON output.
- Update saved reports after inline retention, including nothing-to-clean and
  minimum-reclaim exits, so failed retention remains visible to monitoring.
- Interrupted aged restores remain retryable after their emptied staging
  directories are removed. Completion checkpoints and partial-restore metadata
  updates replace metadata atomically, preserving recovery records on failure.
- `AUR_PREP=1 make check-aur-ready` rejects quoted, unquoted, and multiline `SKIP`
  checksum entries without executing package code; only literal SHA-256 arrays are accepted.
- **Security:** restore creates missing destination directories with mode `0700`,
  including after sudo, so restoring an aged private directory cannot expose its
  files under a permissive umask. Existing directory permissions are preserved.

## [1.5.0] - 2026-10-17

### Added

- `--purge-sessions max-size:SIZE` keeps the newest quarantine sessions within a byte budget (`SIZE` with optional `K`, `M`, `G`, or `T` 1024-based unit) and purges older sessions once the newest-first `du -sb` total exceeds `SIZE` (exiting `0` when nothing exceeds the budget or no quarantine directory exists).
- `--report --json` prints the saved last cleanup report as a machine-readable JSON object (`saved`, `result`, `cleaned`, `skipped`, `failed`, `elapsed_seconds`, `failed_targets`, `quarantine_session`, `interrupted`).
- `--trash-keep-days DAYS` (and `LINUX_CLEANER_TRASH_KEEP_DAYS`) purges quarantine sessions older than `DAYS` days at the end of a non-dry-run cleanup.
- `--trash` now checks free space on `~/.cache/linux-cleaner/quarantine` before a cross-filesystem quarantine move and refuses the target when its planned size exceeds available space (`Error: Not enough free space to quarantine '<name>' (needs X, Y free); left in place.`), leaving it in place; same-filesystem moves are renames and need no check.
- A cleanup interrupted by `SIGINT` or `SIGTERM` prints and saves its partial result report (ending with `Interrupted: SIGINT|SIGTERM before all targets finished`) to `last-report.txt`, logs `mode=run outcome=interrupted` when `--log` is enabled, and exits `130` (`SIGINT`) or `143` (`SIGTERM`).
- Mutating runs (`--clean`/`--force`/`--interactive`, `--restore`, and `--purge-sessions`) acquire a non-blocking `flock` lock on `~/.cache/linux-cleaner/cleaner.lock` (refusing symlinks) and exit `1` when another mutating run is already in progress; dry-run and read-only modes never take the lock. The example retention unit is ordered `After=linux-cleaner-clean.service` so a catch-up start at boot waits instead of failing on the lock.
- A dry-run that found something to clean ends with a `Next:` line naming
  `cleaner --clean` (and `--trash` for quarantine), hidden under `--quiet`.
- `--init-config` copies the active config to the user config path (never overwriting) so it can be customized.
- The systemd units set `SyslogIdentifier=linux-cleaner`, so their journal
  output reads `linux-cleaner[pid]` instead of `env[pid]` and
  `journalctl --user -t linux-cleaner` shows all three. Reinstall the units
  (or the package) and run `systemctl --user daemon-reload` to apply it.
- Config paths (`PATH_EXPRESSION`, `protect|PATH`, and `--log` / `LINUX_CLEANER_LOG`) accept `$XDG_CACHE_HOME`, `$XDG_CONFIG_HOME`, `$XDG_DATA_HOME`, and `$XDG_STATE_HOME` whole-token placeholders (falling back to their XDG Base Directory specification defaults when unset or relative).
- `--min-reclaim SIZE` (and `LINUX_CLEANER_MIN_RECLAIM`) skips a cleanup whose planned reclaim is below SIZE.
- `--only-target` and `--exclude-target` (and their `LINUX_CLEANER_*` mirrors)
  accept a comma-separated list of name substrings.
- `--dry-run --json` targets carry `reason`, the same skip or block reason the
  plan report groups them by (empty when none).
- `--dry-run --json` targets carry `size_at_run_time`, `true` for user-level
  prune actions whose size is only known when they run.
- New `safe` target: the Bun install cache (`~/.bun/install/cache`), files
  older than 30 days. It has no running-process check, because long-lived bun
  servers (for example editor or agent plugins) would otherwise block it on
  every run.
- New `safe` user-level prune actions and default targets for `uv` (`UV Cache`,
  `action:uv_cache_prune` running `uv cache prune`), `pnpm` (`PNPM Store`,
  `action:pnpm_store_prune` running `pnpm store prune`), and Hugging Face Hub
  (`Hugging Face Cache`, `action:hf_cache_prune` running `hf cache prune --yes`).
  These actions run as the invoking user without `sudo`, skip cleanly when the
  tool is not installed, block while the tool is running, and credit the disk
  space actually freed rather than the pre-run directory `du`.

### Changed

- Antigravity Logs now follows the rotated-log rule (7 days, no process gate), so
  it is no longer blocked whenever Antigravity IDE is running.

### Fixed

- A target that contains `$HOME` (for example `$HOME/..` when `HOME` is not
  directly under `/home`) is now refused as `UNSAFE` instead of being deleted
  together with `HOME`.
- User-level prune actions now prune the configured target path instead of the
  tool's default cache location.
- The operation log now records `outcome=failed` for a failed delete or
  quarantine move and `outcome=success` for a successful one, instead of
  `outcome=attempted`.
- `--purge-sessions older-than:DAYS` now exits 0 when no quarantine directory
  exists, so the weekly retention timer no longer fails in delete mode or after
  a purge removed the last session.
- A running Claude Code CLI (process `claude`) no longer blocks cleanup of the
  Claude Desktop caches; those rows are guarded by `claude-desktop` only.
- Wildcard `PATH_EXPRESSION`s with a trailing slash or a doubled slash now expand
  like their normalized form instead of silently matching nothing.
- Relative `XDG_CONFIG_HOME` / `XDG_STATE_HOME` values are now ignored for the
  config search and the saved cleanup report, as the XDG spec requires, instead
  of resolving against the working directory.
- An aged or excluded quarantine now writes its `quarantine.meta` record as soon
  as the first file moves instead of after the whole directory loop, so a run
  interrupted mid-target stays restorable with `--restore`.
- A retried `--restore` after an interrupted restore now treats a record whose
  quarantined payload is already gone and whose original path is present again as
  already restored (whole-target records only), drops the stale record, and
  completes the session retirement instead of failing forever on a missing source.

## [1.4.2] - 2026-10-16

### Added

- The Arch package prints a short hint after the first install: preview with
  `cleaner --dry-run`, how to turn on the optional daily timer, and that cleanup
  deletes permanently unless `LINUX_CLEANER_TRASH=1` is set. Nothing is enabled,
  and upgrades print nothing.

### Fixed

- The result line of a cleanup report now counts targets skipped before cleanup
  started (for example ones that need root when sudo is unavailable), so its
  `skipped=` agrees with the plan's `skipped=` in the same report.
- Docs: switching from `make install` to the distro/AUR package now explains
  the leftover `/etc/linux-cleaner/cleaner.conf` that makes pacman stop with
  "exists in filesystem", how to clear a stale timer link, and that enabling
  the timer after a missed 03:00 slot runs a cleanup at once.

## [1.4.1] - 2026-10-16

### Fixed
- **Security:** a target path ending in two or more slashes (for example
  `$HOME/link//`) no longer slips past the symlink refusal. Such a target used
  to resolve through the link and clean the directory it points to; it is now
  refused as `[SYMLINK]` like `$HOME/link` and `$HOME/link/`.
- **Security:** every quarantine session directory is created with mode `0700`
  (and a quarantine base the tool creates is `0700` too), whatever the umask.
  Under `umask 022`, files quarantined from a private directory could
  previously become readable by other local users.
- **Security:** `--restore` no longer writes through a symlink planted at a
  record's original path or at a directory inside it. Such files are reported
  as a conflict (`outcome=conflict`), stay in quarantine, and the run exits `1`.
- In a wildcard pattern that also contains `**`, a plain `*` or `?` now matches
  exactly one path component, as documented. It used to span several
  directories (`$HOME/a/**/app/*/build` matched `.../app/one/extra/build`).
  Patterns without `**` select the same targets as before.
- Uninstall instructions (README, RUNBOOK, `cleaner.1`, packager handoff) now
  tell each user to disable the timers first and run `systemctl --user
  daemon-reload` after removal.

## [1.4.0] - 2026-10-16

### Added
- `protect|PATH` config directive protects any directory tree from cleanup:
  targets whose canonical path equals, lies under, or contains a protected path
  are skipped (`status="protected"`, `[PROTECTED]` under `--debug`, and
  `Protected (by config):` in the plan report). Invalid `protect` lines are
  rejected with a `<config>:<line>:` error.
- `make install` ships the systemd user units under `$(PREFIX)/lib/systemd/user`
  (mode 0644). Install does not enable them.
- `--report` prints the last non-dry-run cleanup report (plan plus result, without
  color codes) saved at
  `${XDG_STATE_HOME:-$HOME/.local/state}/linux-cleaner/last-report.txt`.
  `--quiet` hides the plan on screen; the saved copy still includes it.
  Dry-run, `--json`, and read-only modes do not write the file. A symlinked
  state path is refused without failing the cleanup. Exits 1 when no report
  has been saved.
- A plan report after the savings total (status counts, reclaimable bytes by
  risk, the largest targets, and skipped targets) and a result report
  after cleanup (cleaned, skipped, and failed counts, quarantined versus
  permanently reclaimed bytes, the quarantine session, and elapsed time).
  `--quiet` hides the plan report; `--json` includes neither.
- Per-target exclusions: CUSTOM_ACTION may be `exclude:NAME[,NAME...]`, using the
  `--exclude` pattern syntax for that row only, e.g. `exclude:notes` to keep a
  `notes/` directory inside a session-log tree.
- `--debug` (env `LINUX_CLEANER_DEBUG`) shows the per-target `[CLEAN]` lines (nothing
  to clean, size 0, path missing); they are hidden by default so wildcard rows that
  expand to many targets do not flood the output.
- A target inside a git work tree that holds any git-tracked file is skipped as a
  whole (`[SKIP] ... contains N git-tracked file(s)`), so a cleanup row can never
  remove committed project content.
- Add `action:apk_clean` custom action to clear the Alpine Linux package cache
  (`sudo apk cache clean`) when apk is available.
- With `--log`/`LINUX_CLEANER_LOG`, `--restore` writes one `mode=restore`
  operation-log line per target (`success`, `failed`, `conflict`, or
  `missing`) and `--purge-sessions` one `mode=purge` line per session, so
  irreversible purges leave an audit trail.
- `--list-sessions --json` — emit a machine-readable JSON inventory of
  quarantine sessions (`sessions` array of `timestamp`/`size_bytes`/
  `size_human`/`date`/`targets` with per-target `type`/`path`).
- Dry-run `--json` also emits `total_reclaimable_human` and per-target
  `size_human` alongside the existing byte fields.
- Dry-run `--json` also emits per-target `description` and `min_age_days`
  alongside the existing target summary fields.
- `--list-targets --json` also emits per-target `description` and
  `min_age_days` alongside the existing `name`/`risk`/`path` fields.
- `--list-targets --json` also emits per-target `check_processes` and
  `custom_action` when those optional config fields are present.
- `--exclude-target PATTERN` — with cleanup, skip config targets whose
  `NAME` contains `PATTERN` (substring match). Combined with
  `--only-target`, both filters apply. Exits 1 if nothing remains.
  `LINUX_CLEANER_EXCLUDE_TARGET` mirrors the flag for automation.
- `LINUX_CLEANER_CONFIG` — when set to a non-empty path, selects the
  configuration file (same as `--config`). Explicit `-c/--config` overrides.
- `--check-config` — validate the configuration file with the same
  structural checks as a cleanup run and exit without disk analysis.
- `action:zypper_clean` — predefined action running `sudo zypper clean -a`
  (skipped when zypper is absent), matching the apt/dnf package-cache pattern.
- Human `--list-targets` also prints each target's `DESCRIPTION` column.
- RUNBOOK documents `--check-config`, `LINUX_CLEANER_CONFIG`,
  `--exclude-target` / `LINUX_CLEANER_EXCLUDE_TARGET`, and `action:zypper_clean`.

### Changed
- `filter:cxx_build` targets with `MIN_AGE_DAYS > 0` now treat the age as an
  idle threshold for the directory as a whole: if anything under the build
  directory was modified within `MIN_AGE_DAYS` days, it is left untouched
  (`active within N days.` under `--debug`); otherwise the whole build
  directory is sized and removed at once (`(idle > N days)` in the plan
  report). Other aged rows keep per-file age deletion unchanged.
- Targets outside `$HOME` are always allowed. Protected system directories stay
  `UNSAFE` and symlink targets stay refused. The C++ Build Dirs and C++ CMake
  Build Dirs rows are risk `safe`, so the safe-tier daily timer cleans them.
  A target that needs root is skipped with a warning and an operation-log record
  when privileges are not available, instead of aborting the run. Skips still
  exit 0.
- The daily clean unit no longer forces `--trash` (opt in with `LINUX_CLEANER_TRASH=1`).
- `--debug` (and `LINUX_CLEANER_DEBUG`) shows per-target `FOUND` and `CLEAN`
  lines; a default dry-run hides them so the totals stay readable.
  `--quiet` still suppresses them.
- Codex Sessions, Codex Generated Images, Cursor Chats, Claude Desktop Logs and
  Hermes Logs now prune files older than 7 days (was 30) and no longer skip while
  their application runs; the age filter already spares the live session's files.
- The C++ build-directory rows now scan all of `/opt` instead of one fixed C++ subtree;
  `filter:cxx_build` still keeps only directories that hold a build-system marker.
- New rows prune per-project AI tool logs under `/opt` older than 7 days:
  `.gemini/model_debug_logs` and `.codex/logs`, and `.remember/logs` after one year.
  The rest of those tool directories (settings, rules, skills, plans, memory) is
  left alone.
- An outside-HOME target is listed as a normal `FOUND` line (description and
  age filter included) tagged `(outside HOME)`.
- Default-mode cleanup no longer asks a separate question for outside-HOME
  targets; the single "clean all the found items?" confirmation covers them.
- `/opt`, `/srv`, `/tmp`, `/run`, `/mnt`, and `/media` themselves are
  `UNSAFE` targets; their descendants are cleaned like any other target.

### Deprecated
- `--allow-outside-home` is an accepted no-op that prints one deprecation
  warning, since targets outside `$HOME` are always allowed. The
  `LINUX_CLEANER_ALLOW_OUTSIDE_HOME` mirror added in this release behaves the same way.

### Removed
- The Claude Projects row (`$HOME/.claude/projects`). Claude Code prunes its own
  transcripts per session (`cleanupPeriodDays`); a file-age filter would delete the
  old sidecar files of a session that is still open.

### Fixed
- Defer `aged` quarantine metadata records until at least one file moves and
  prune empty staging directories under the session target, so a failed aged or
  filtered move never leaves phantom metadata or empty directories that block
  `--restore latest`.
- Match a CHECK_PROCESSES name longer than 15 characters on its first 15, as the
  kernel stores it; previously such a guard never matched and the target was
  cleaned while the program ran.
- Keep restore metadata aligned when sudo authentication fails partway through a
  session: the unauthenticated record fails alone, instead of the run exiting
  with already-restored records still listed and failing every retry.
- Correct operator guidance for execution flags, config lookup, systemd
  environment overrides, config compatibility, and quarantine ownership/trust.
- Discover valid nested C/C++ build trees beneath rejected wildcard parents,
  while keeping accepted parent and child targets from overlapping.
- Report partial filesystem traversal failures during quarantine and restore,
  retain recovery metadata for retries, and refuse purge on incomplete enumeration.
- Skip unavailable package-manager actions before sudo authentication and sizing,
  so portable configs do not block ordinary cleanup or inflate JSON previews.
- Preserve wildcard path identity during discovery: warn and skip names that
  would be split, trimmed, or expanded into another target by config parsing.
- Validate raw config records before wildcard expansion, so unmatched patterns
  cannot hide malformed fields. `--check-config` counts definitions without
  traversing target directories (validation tightening; minor-release scope).
- Apply `filter:cxx_build` consistently to literal and wildcard paths, including
  tokens with surrounding whitespace, so source directories remain protected.
- Preserve excluded single-file targets during both permanent cleanup and
  quarantine, including runs with other eligible targets.
- Measure targets that contain an unreadable subdirectory as one readable
  total: dry-run no longer reports them as 0 B, `--json` stays valid, aged
  targets no longer abort the run, and `--list-sessions` and purge previews
  complete for sessions holding unreadable content.
- Pass `CHECK_PROCESSES` tokens to `pgrep` verbatim, so a pattern such as
  `app*` cannot be pathname-expanded against the working directory and miss
  a running process.
- Run the runbook example validator without ripgrep, and fail instead of
  passing when its search tool is missing.
- `--restore` of a root-owned quarantine record authenticates sudo (with the
  tool's explanation) before checking the restore destination, instead of
  letting the conflict probe raise a bare sudo prompt.
- A failing `mkdir` during `--restore`, or a failing `mkdir`/`chown` during
  trash-mode aged quarantine, is now reported for that target with exit 1
  instead of silently ending the run; restore metadata stays aligned with the
  quarantined files and later targets still run.
- `make check-aur-ready` now fails while `PKGBUILD` still pins
  `sha256sums=('SKIP')`; it previously passed on any PKGBUILD.

## [1.3.0] - 2026-07-15

### Added
- `LINUX_CLEANER_ONLY_TARGET` — when set to a non-empty pattern, enables
  `--only-target` (substring match on config target `NAME`). CLI flags override
  this variable.
- `--list-targets --json` — emit a machine-readable JSON inventory of configured
  targets (`config`, per-target `name`/`risk`/`path`).
- `LINUX_CLEANER_RISK` — when set to `safe`, `medium`, or `danger`, sets the
  default `--risk` ceiling. CLI flags override this variable.
- `LINUX_CLEANER_TRASH` — when set to `1`, `true`, or `yes`, enables `--trash`
  (quarantine mode). CLI flags override this variable.
- `NO_COLOR` — when set to any non-empty value, disables ANSI color codes in
  output (per no-color.org).
- `LINUX_CLEANER_EXCLUDE` — when set to a non-empty pattern list, enables
  `--exclude` (comma-separated globs). CLI flags override this variable.
- `LINUX_CLEANER_FORCE` — when set to `1`, `true`, or `yes`, enables `--force`
  (non-interactive clean). CLI flags override this variable.
- `LINUX_CLEANER_YES_DANGER` — when set to `1`, `true`, or `yes`, enables
  `--yes-danger` (bypass danger confirmation). CLI flags override this variable.
- Operator runbook `docs/QUARANTINE-OPS.md` for quarantine inventory, retention, restore, and purge.

## [1.2.0] - 2026-07-15

### Added
- `--only-target PATTERN` — with cleanup, process only config targets whose
  `NAME` contains `PATTERN` (substring match). Other targets are skipped for
  analysis and cleaning. Exits 1 if no target name matches. Cannot be combined
  with `--restore`, `--purge-sessions`, or `--list-sessions`.
- `--quiet` (`-q`) — suppress per-target status lines and the decorative header;
  errors, total savings, and the final summary still print. Useful for cron jobs
  that only need the reclaim total and exit code.
- `--json` — with `--dry-run`, emit a machine-readable JSON summary (`config`,
  `total_reclaimable_bytes`, per-target `name`/`path`/`risk`/`bytes`/`status`)
  instead of human-formatted output. Implies `--quiet`.
- `--list-targets` — list every target defined in the configuration file
  (`NAME`, risk, path) without analyzing disk usage or modifying anything.
  Read-only; requires a config file.
- `LINUX_CLEANER_QUIET` — when set to `1`, `true`, or `yes`, enables
  `--quiet` (suppress per-target status lines).
- `LINUX_CLEANER_JSON` — when set to `1`, `true`, or `yes`, enables `--json`
  (requires dry-run).

### Changed
- Release-notes extraction moved out of the release workflow's inline `awk` into a
  tracked, tested `release-notes.sh`. The workflow's fallback — which silently turned a
  missing changelog section into a release published with an empty body — is gone: a
  missing section now fails the release. Extraction also stops at the changelog's link
  footer, which the old extractor dragged into the newest release's notes.
- `bash test_cleaner.sh` now fails when a **tagged** HEAD still has entries under
  `[Unreleased]`. The release workflow publishes only the tagged version's section, so
  stranded entries were silently dropped — and a pushed tag is never deleted. The
  guard's assertion runs against fixtures on every test run, so it cannot rot while the
  repository sits untagged.

## [1.1.0] - 2026-07-13

### Added
- `--only PATTERN` — with `--restore`, recover a single target from a quarantine
  session instead of the whole session. Targets whose original path does not match
  stay quarantined, and the session's metadata is rewritten so a later full
  `--restore` of it still succeeds. Previously the only way to get one cache back
  was to restore everything and re-run the cleaner, which re-deleted the targets
  you meant to keep. Pairs with `--list-sessions`, which now prints each target's
  path. Exits 1 if the pattern matches nothing, or if used without `--restore`.
- `--purge-sessions older-than:DAYS` — age-based quarantine retention. Purges
  every session last modified more than `DAYS` days ago, exits 0 when none match
  (so it is safe as a cron retention policy), and rejects a malformed day count.
  Trash mode previously had no expiry at all: an unattended `--trash` run
  accumulated one session per run forever, so the tool held the very space it
  claims to reclaim. Pairing a `--trash` job with a periodic `older-than:` purge
  now keeps quarantine bounded.
- `--purge-sessions SESSION` to permanently delete quarantine sessions
  (`latest`, `all`, or a specific timestamp) and reclaim the disk space that
  trash mode holds. Irreversible; prompts for confirmation unless `-f/--force`
  is given, and only ever removes directories under the tool-owned quarantine
  base.
- `--list-sessions` now shows the targets each quarantine session holds — the
  type (`full` or `aged`) and original path of every quarantined item — so a
  session's contents can be inspected before it is restored or permanently
  purged. The metadata was already recorded; it was simply never surfaced.
- The `--purge-sessions` confirmation now names every target it is about to
  destroy, using the same read-only listing as `--list-sessions`, so the tool's
  one irreversible prompt is no longer less informative than its read-only query.

### Fixed
- The shipped default config no longer targets a Chromium per-site IndexedDB
  store under `$HOME/.config`. That tree is configuration and persistent state,
  not cache, so cleaning it at the `medium` risk level was data loss rather than
  reclamation — and it contradicted the README, which rates site-database storage
  `danger`. The default now targets caches and temp files only, and the suite
  fails if a `$HOME/.config` target is added back.
- Cleanup now exits non-zero when an operation fails, matching the documented
  exit-status contract. A failed delete, quarantine move, predefined action, or
  session purge previously printed an error to stderr and still exited 0, so an
  unattended run (cron, systemd) could not detect that the cleanup had not
  happened. Deliberate skips — a declined danger target, a process-blocked
  target, an unsafe path, or an action whose binary is absent — are not failures
  and still exit 0.
- A quarantine move that fails is no longer recorded in `quarantine.meta`. The
  record was written before the move was attempted, so a failed move left an
  entry pointing at a file that never reached quarantine — which made every
  later `--restore` of that session exit 1 on the missing source and refuse to
  clean the session up, even though nothing had been lost.

## [1.0.0] - 2026-07-12

### Added
- Configuration-driven cleanup of caches, temp files, and logs via a
  pipe-delimited `cleaner.conf` (risk level, name, path, description, min age,
  process check, custom action).
- Dry-run by default; `--clean`, `--force`, and `--interactive` execution modes.
- Risk levels (`safe`/`medium`/`danger`) with `-r/--risk` filtering and a danger
  confirmation guard (`--yes-danger`).
- Age filter (`MIN_AGE_DAYS`) and running-process checks (`CHECK_PROCESSES`).
- Trash quarantine (`-t/--trash`) with restore (`--restore`), read-only session
  listing (`--list-sessions`), and original-ownership preservation.
- Path-safety guards: system-directory block, `$HOME` boundary
  (`--allow-outside-home`), symlink refusal, and physical canonicalization.
- Predefined package-cache actions `action:paccache_keep1/2/3` and
  `action:pacman_clean`.
- `-V/--version` flag and an opt-in, `$HOME`-confined operation log
  (`--log` / `LINUX_CLEANER_LOG`) that records no file contents.
- Config field-count and value validation with line-numbered errors.
- Install tooling (`Makefile`, `install.sh` honoring PREFIX/DESTDIR), a
  `cleaner.1` man page, and a config search order (explicit `-c` > XDG > `/etc`
  > checkout).
- A CI workflow running ShellCheck and the full test suite.

[Unreleased]: https://github.com/eserlxl/cleaner/compare/v1.5.0...HEAD
[1.5.0]: https://github.com/eserlxl/cleaner/releases/tag/v1.5.0
[1.4.2]: https://github.com/eserlxl/cleaner/releases/tag/v1.4.2
[1.4.1]: https://github.com/eserlxl/cleaner/releases/tag/v1.4.1
[1.4.0]: https://github.com/eserlxl/cleaner/releases/tag/v1.4.0
[1.3.0]: https://github.com/eserlxl/cleaner/releases/tag/v1.3.0
[1.2.0]: https://github.com/eserlxl/cleaner/releases/tag/v1.2.0
[1.1.0]: https://github.com/eserlxl/cleaner/releases/tag/v1.1.0
[1.0.0]: https://github.com/eserlxl/cleaner/releases/tag/v1.0.0
