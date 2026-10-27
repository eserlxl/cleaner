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

- Path expansion no longer forks for `$HOME`/`$USER`/`$XDG_*` placeholders a path does not contain. Wildcard rows run it once per match, so `--list-targets --json` on the shipped config dropped from about 14 s to 10 s, and cleanup runs gain the same.

## [1.9.0] - 2026-10-26

### Added

- Manual runs print `Daily timer: <state> risk=<risk> env=<path>` after the plan when `linux-cleaner-clean.timer` is installed, because they do not read the timer's `~/.config/linux-cleaner/env` and so may preview a different risk than the timer cleans. Runs whose stderr is the journal, such as the timer's own, and `--quiet` runs omit it.

### Fixed

- Package-cache actions (`paccache`, `pacman`, `apt`, `dnf`, `zypper`, `apk`) credited the whole planned cache size as reclaimed, even when the action kept most of it or removed nothing (`paccache -rk1` reporting no candidates still counted `6.01 GB`). They now credit the bytes that left the cache directory, measured again after the action, in the result, saved report, JSON and metrics. The plan marks their size as `(cache size; the action may keep part)`.

## [1.8.0] - 2026-10-25

### Added

- Cleanup metrics now include `linux_cleaner_last_run_duration_seconds`, the elapsed seconds from the parsed `Result:` line. Runs that exit before that line omit the sample instead of reporting `0`.
- Dry-run JSON (`--dry-run --json`) now includes `hidden_by_risk` (`{"medium":N,"danger":M,"names":[...]}`), reporting the counts and names of selected targets above the `--risk` ceiling without analysing them.
- Cleanup metrics now include `linux_cleaner_quarantine_bytes`, the current `du -sb` size of `~/.cache/linux-cleaner/quarantine` after inline retention, including previous sessions. An absent directory reports `0`; measurement failures warn and omit the sample without affecting the other gauges or cleanup status.
- `--purge-sessions SELECTOR --dry-run` previews selected session names and sizes under `Would purge`, reporting held sessions skipped by bulk selectors, without confirmation, deletion, locking, or log/report writes, even with inherited `LINUX_CLEANER_FORCE`. It uses the real purge's selector and hold rules, rejects JSON, and preserves later cleanup-flag precedence (`--dry-run --force` still purges).
- CLI-only `--report --check-health SECONDS` preserves text or JSON output and exits `0` only when the saved report is recent enough and successful (including skips). Missing, unreadable, symlinked, stale, future-dated, failed, interrupted, retention-failed, or unrecognized reports exit `1` with a one-line reason on stderr. Age uses the file mtime; no config or timer is required.
- `--min-free-path PATH` and `LINUX_CLEANER_MIN_FREE_PATH` select the filesystem measured by `--min-free` (default: `HOME`). Requires an absolute existing path and a CLI or environment min-free threshold; invalid input exits `1`. Failed probes warn and cleanup proceeds. The option refuses read-only and session modes, completes paths in bash/zsh/fish, and is carried with `--min-free` into dry-run `Next:` commands. JSON `would_skip` and `--exit-code` use the selected filesystem.
- CLI-only `--exit-code` makes text and JSON cleanup previews exit `2` when cleanup would run, or `0` when `--min-reclaim`, `--min-free`, or nothing to clean would skip it; errors remain `1`. Refuses cleanup and other modes, stays out of the `Next:` command, and does not journal the intentional `2` as a failure.
- `--fail-fast` and `LINUX_CLEANER_FAIL_FAST` stop cleanup after the first failed target's accounting, leave later targets untouched, and skip inline retention even if the last target failed. The printed and saved report names the target and remaining count; the run exits `1`. Safety skips and blocked targets do not stop the run. The flag refuses non-cleanup modes (including hold/release), inherited values are ignored there, and dry-run `Next:` commands carry the modifier. Notifications and metrics are unchanged; without the modifier, cleanup and retention continue after failures as before.
- `--hold-session SESSION` and `--release-session SESSION` (`latest` or a timestamp, validated like `--restore`) protect one quarantine session while a partial restore is being resolved, without disabling retention for the others. A hold writes a private `.hold` marker under the mutation lock and leaves the session mtime unchanged. Every bulk `--purge-sessions` selector and inline `--trash-keep-days` retention skip a held session with `Skipping held session <name>`, even with `--force`; purging a held session by name or as `latest` exits `1` instead of picking another session. `--list-sessions` ends a held session's line with `held` and adds JSON `held` (`true`/`false`); the marker is not an unrecorded entry. A complete restore removes the marker with the session. Both modes refuse every other mode, cleanup filter and modifier, `--dry-run`, `--clean`, `--interactive`, and `--json`, and complete session names in bash, zsh and fish.
- `--action-timeout SECONDS` and `LINUX_CLEANER_ACTION_TIMEOUT` bound each `action:*` command (paccache, pacman, apt-get, dnf, zypper, apk, uv, pnpm, hf, nix-store) with `timeout --kill-after=10`. A hung action prints `Error: Action '<action>' for '<name>' timed out after SECONDS seconds.`, counts as a failed target, and the run continues with the remaining targets, retention, and the result report instead of waiting for the clean unit's `TimeoutStartSec`. `0` or unset keeps actions unbounded; a positive limit in a cleanup run requires `timeout(1)`. The option refuses the read-only and restore/purge modes like `--min-age`.
- `--restore SESSION --dry-run` previews each selected record as `would restore`, `conflict`, `already restored`, `missing`, or `unknown type`, honours `--only` and `--only-exact`, and exits `0` without locking, sudo, file moves, logging, metadata changes or session mtime resets.
- A dry-run `Next:` hint repeats the options that shaped the preview: after an explicit config, a risk above `safe`, `--trash`, or a selection or age option (`--exclude`, `--only-target`, `--exclude-target`, `--only-path`, `--exclude-path`, `--min-age`, `--trash-keep-days`, `--action-timeout`, or their environment variables), it prints the full `cleaner --clean ...` command with each value quoted by `printf %q`, so applying it plans the previewed targets instead of a wider default plan. A bare preview still prints `cleaner --clean`.
- `--doctor` shows the enabled daily timer's plan from `~/.config/linux-cleaner/env`: risk ceiling, quarantine or permanent deletion, keep days, and env path. Without an env file it shows `risk=safe deletion=permanent keep-days=none (no env file)`; disabled timers print no plan line. An invalid env risk or keep-days value, an unreadable or schema-invalid `LINUX_CLEANER_CONFIG` from that file (a relative path checked under `HOME`), `LINUX_CLEANER_ONLY_PATH` together with keep-days, or an unreadable env file turns the line into a `WARN`. The retention warning and exit status are unchanged.
- `--doctor` shows the last cleanup's saved time and result, or `INFO: last cleanup: none recorded`; failed, interrupted or retention-failed runs (the last append `; retention failed`) and reports modified more than two days ago with the clean timer enabled produce `WARN` without changing the exit status. Symlinked reports and state directories are not followed.
- A `--trash` cleanup that quarantined something prints `Undo: cleaner --restore <session>` after its summary; `--quiet`, `--report`, and notifications are unchanged.
- Plan reports count and name selected targets above the `--risk` ceiling as not analysed, with a hint to preview medium or danger targets; JSON and metrics are unchanged.
- Failed cleanups emit one journal error-priority summary when stderr matches `JOURNAL_STREAM`, including interrupted and early non-zero cleanup exits, failed or early-exiting `--purge-sessions` runs, failed dry runs, and retention failures, so `journalctl --user -t linux-cleaner -p err` finds failed scheduled runs.
- Env-only `LINUX_CLEANER_PREVIEW_METRICS_FILE` atomically exports cleanup dry-run timestamp, planned reclaimable bytes, and would-skip gauges to a separate Prometheus textfile, including text and JSON previews.
- `[BLOCKED]` status lines include the matching process PID when available; JSON reasons remain unchanged.
- `--show-matches` lists eligible paths below each ordinary target in a text dry run, respecting age and exclusion filters; unfiltered targets show only their own path. File names holding control characters are shown shell-quoted on one line. The CLI-only flag rejects cleanup, JSON, and non-cleanup modes.

### Changed

- A cleanup narrowed with `--only-target` or `--exclude-target` no longer walks the directory trees of wildcard rows it filters out; on the shipped config `--list-targets --only-target NPM` drops from about 13 seconds to under one.
- Document the per-artifact default path, override, `$HOME`-confinement, runtime permission/symlink protection, and failure behavior contract in one table (`docs/reports-and-logs.md#artifact-locations`), with links from `docs/safety.md` and `docs/QUARANTINE-OPS.md`.
- Document which operations may use `sudo` in one privilege matrix (`docs/safety.md`), including the unattended difference: cleanup skips a root-requiring target, while `--restore` fails that record and exits 1.

### Fixed

- On a non-GNU userland, a cleanup that `--min-reclaim` or `--min-free` would skip now stops with the GNU refusal before inline quarantine retention runs; it previously purged old sessions and exited `0`.
- The git-tracked target guard ignores `GIT_DIR`, `GIT_WORK_TREE` and `GIT_INDEX_FILE` inherited from the environment (git sets them inside hooks and `git rebase --exec`), so a run started there no longer inspects another repository and cleans tracked files.
- A user-level prune action credits `0` bytes when a free-space probe fails, instead of counting the filesystem's whole free space as reclaimed in the summary, saved report, JSON and metrics.
- `--restore` and `--restore --dry-run` refuse structurally malformed `quarantine.meta` records before path probes or `sudo` when `rel_path` is empty, starts with `/`, or has a `..` component, `original_path` is not `/`-rooted or has a `..` component, `use_sudo` is neither `true` nor `false`, or a non-empty `uid`/`gid` is not all ASCII digits. Real restores report the failed rule on stderr, log `outcome=failed`, keep the payload and metadata line for recovery while restoring valid siblings, and exit `1`; previews print `invalid record  <original_path>` and exit `0`.
- `--log` works when HOME is a symlink: the inside-HOME check compared the resolved log path with the unresolved HOME and disabled logging.
- Config validation rejects a positive `MIN_AGE_DAYS` on an `action:*` row; the action ignored the age, so the plan showed an age-filtered estimate for a command that cleans the whole cache.
- Skip `filter:cxx_build` targets with `activity check failed` when an idle probe fails without finding recent activity, both during preview and immediately before cleanup, so unreadable build subdirectories cannot cause partial deletion.
- Cleanup always protects `$HOME/.cache/linux-cleaner`, including targets equal to, under, or containing it and wildcard matches, so broad cache targets cannot delete quarantine sessions, the operations log, or the live lock file. Text and JSON previews report these targets as protected even before the directory exists.
- The dry-run `Next:` command repeats `--min-reclaim`, so applying it still skips when the plan has fallen below the threshold.
- `make install` with a renamed `BINNAME` fails when one of its completion or service rewrite steps fails, instead of reporting success.
- Session listings, purge confirmations and purge previews print recorded original paths literally; a backslash sequence such as `\c` no longer cuts the path short.
- With a renamed `BINNAME`, both installers point the clean, retention and monitor services at the installed command; they still ran `cleaner`, so the timers failed or ran a different installation.
- Option names and long process names match in ASCII under every locale: under `tr_TR`, `--exclude --interactive` took `--interactive` as the pattern, and a long plain process name containing `i` was not cut to 15 characters, so its running process no longer blocked the target.
- Numeric options accept only ASCII digits: under a UTF-8 locale such as `tr_TR`, a value like `١` passed `--lock-wait`, `--min-age`, `--action-timeout`, `--trash-keep-days` and `--check-health` validation.
- An INT/TERM interruption during post-cleanup quarantine retention is saved in the cleanup report, so `--report --check-health` reports that cleanup was interrupted instead of returning healthy.
- Risk names match in any case under every locale: under `tr_TR`, `--risk MEDIUM`, `LINUX_CLEANER_RISK=MEDIUM` and `MEDIUM` config rows were rejected because bash lowercased `I` to a dotless `ı`.
- Quarantine enumeration reads `find`'s exit status from the stream instead of `wait` on a process substitution, which could lose an already-reaped child under heavy load and fail listing, purge, restore or aged quarantine with a false enumeration error.
- Skip wildcard matches whose paths contain control characters or backslashes, warning with shell-quoted paths before they can reach terminal output or cleanup; literal config paths are unchanged.
- Reject target paths combining `*` or `?` with `[` or `]` before analysis or deletion, preventing bracket classes from selecting a different directory; literal bracketed paths remain valid and tests pin their exact targets. A wildcard row whose `$HOME`, `$USER`, or `$XDG_*` expansion contains a bracket, which previously matched nothing silently, is now skipped with a warning.
- Compare a plain `CHECK_PROCESSES` name that contains `.` (such as `python3.13-debug`) on its first 15 characters, and ignore whitespace after `cmdline:`, so both forms match a running process instead of cleaning its cache.
- Exclude CMake and Meson source roots and symlink-only markers from `filter:cxx_build`, while retaining real build markers up to two levels deep, so broad build patterns cannot delete these source trees.
- Skip targets whose resolved path contains `|` (for example through a symlinked parent) before deletion or quarantine, with a reason in text and JSON. Such a path was written unescaped to `quarantine.meta`, and `--restore` moved the data to a truncated path while reporting success.
- Fail closed (`[SKIP]`, `git-tracked check failed`) when git refuses a repository (dubious ownership) during the git-tracked target guard, instead of treating the refusal as zero tracked files and cleaning the target. A path outside any repository is still treated as having no tracked files.
- Re-check a single-file age limit and a `filter:cxx_build` idle limit immediately before a whole-target delete or quarantine. A file or build tree rewritten after analysis is skipped and its planned size is not counted; an aged directory still filters with `find -mtime` at delete time.

## [1.7.1] - 2026-10-22

### Changed

- The AUR package now runs `make check-package` while building: a seconds-long smoke test (syntax, `--version`, `--help`, and the shipped config) that needs no git, network, or home directory. `make check` stays the full test suite.

### Fixed

- The test suite no longer fails when run from a release tarball unpacked inside another git repository (for example an AUR helper's build directory).

## [1.7.0] - 2026-10-21

### Added

- A target skipped because its application is running now shows how much space it would free otherwise: on its `[BLOCKED]` line, as `Held by active processes` under the savings total, and as an `In use: blocked=N would_reclaim=SIZE` line in the plan and final reports (also kept by `--report`). This space is not counted in the savings total, `--min-reclaim`, or `--json` sizes.

### Changed

- The Arch packaging files are now generated by [AURGen](https://github.com/eserlxl/aurgen) from `aur/aurgen.install.yaml`.

## [1.6.0] - 2026-10-19

### Changed

- Add `make lint`, which runs shellcheck over every tracked shell file listed once in the Makefile's `SHELLCHECK_FILES` (now also `scripts/validate-runbook-examples.sh`, `completions/cleaner.bash`, `linux-cleaner.install` and `PKGBUILD`); `make pre-release`, CI and the contributor docs all run it, and the suite fails when a tracked shell file is missing from the list.

- The weekly `linux-cleaner-retention.service` now runs with `--lock-wait 3600`, so a Sunday purge waits for a cleanup that still holds the run lock instead of exiting 1 and skipping that week's retention.

- `--doctor` warns when `~/.config/linux-cleaner/monitor.env` is unreadable (`WARN: monitor env: <path> (not readable)`) or sets both `LINUX_CLEANER_ONLY_PATH` and `LINUX_CLEANER_TRASH_KEEP_DAYS`, and still reads the clean timer's `~/.config/linux-cleaner/env` when `XDG_CONFIG_HOME` points elsewhere.

- `--doctor` schema-checks a readable configuration and prints `WARN: config: <path> (<source>, <error>)` with exit `1` when the schema is invalid, while still printing the rest of the checklist; a valid file still prints `OK: config: <path> (<source>)`.

- `--only-target` and `--exclude-target` refuse `--check-config` with the full list `(not --restore, --purge-sessions, --list-sessions, --check-config, --report, --init-config, or --doctor)`, and `--min-reclaim`, `--min-free`, `--min-free-path`, `--min-age`, `--trash-keep-days`, and `--notify` refuse it with `(not --restore, --purge-sessions, --list-sessions, --list-targets, --check-config, --report, --init-config, or --doctor)`, replacing the separate `(not --check-config)` message.

- Run the clean, retention and monitor systemd user units at `Nice=19` with
  idle IO scheduling, so a `Persistent=true` catch-up run at login or the
  six-hourly preview does not slow the desktop session.

- Align configuration guidance with the existing target classes and exceptions.

### Added

- `release-notes.sh roll X.Y.Z [YYYY-MM-DD]` performs the release changelog roll: it moves the `[Unreleased]` entries under a dated version heading and rewrites the compare/tag link footer, refusing an existing section, an empty `[Unreleased]` or a malformed version without touching the file.
- The shipped systemd services set `TimeoutStartSec=2h`: a hung oneshot run is stopped with `SIGTERM` and the unit fails (a cleanup stopped during its cleanup phase also saves an `Interrupted: SIGTERM` report) instead of keeping the unit activating and silently skipping later timer slots.
- `--doctor` prints a read-only environment checklist (`OK`/`WARN`/`INFO` lines for the resolved config path and origin, `check_gnu_userland`, `pgrep`, `flock`, `git`, non-interactive `sudo -n`, `notify-send`, `systemctl --user is-enabled` for the `clean`/`retention`/`monitor` timers, a `WARN` when the enabled clean timer's env file turns on `LINUX_CLEANER_TRASH` with no retention bound, and the quarantine session count, or a `WARN` when the quarantine cannot be enumerated) without requiring a configuration file, exiting `0` when cleanup can run or `1` when the configuration file is missing or unreadable or GNU userland is missing.
- A missing configuration file found by the default search now lists every searched location (XDG, `/etc`, checkout) and suggests `cleaner --doctor`; an explicit `-c`/`LINUX_CLEANER_CONFIG` path is reported as before.
- An unreadable configuration file is now refused with `Error: Configuration file '<path>' is not readable` and exit `1` before any analysis, instead of a raw shell `Permission denied` error.

- `action:nix_store_gc` runs `nix-store --gc` as a user-level prune action without `sudo` (sized from the filesystem free-space delta at run time and skipped when `nix-store` is absent), with a commented `Nix Store` (`/nix/store`) example row in `cleaner.conf`.

- `LINUX_CLEANER_METRICS_FILE` atomically writes a Prometheus `node_exporter`
  textfile (`linux_cleaner_last_run_timestamp_seconds`,
  `linux_cleaner_last_run_success`,
  `linux_cleaner_targets{result="cleaned|skipped|failed"}`, and
  `linux_cleaner_reclaimed_bytes{kind="quarantined|permanent"}`) at every
  cleanup exit from the saved report's result and accounted-bytes values while
  refusing relative paths, line feeds, and symlinks with a non-fatal warning.

- `--exclude-path PATH` and `LINUX_CLEANER_EXCLUDE_PATH` skip cleanup and
  `--list-targets` targets whose resolved physical path equals or lies below an
  existing absolute path (`action:*` rows included when their path matches;
  missing targets never excluded), exiting `1` when `PATH` does not exist or
  removes every remaining target.

- `--purge-sessions keep-latest:N` keeps the newest `N` quarantine sessions and
  purges older ones (oldest first), exiting `0` when at most `N` sessions exist or no
  quarantine directory exists and exiting `1` on an invalid count.

- Dry-run JSON includes top-level `would_skip` with the cleanup gate decision
  (`skipped_below_min_reclaim`, `skipped_at_or_above_min_free`, `nothing_to_clean`,
  or `null` when cleanup would proceed).

- Complete existing quarantine session names for `--restore` and `--purge-sessions`
  in Bash, Zsh and Fish, alongside the existing session selectors.

- `--min-free SIZE` and `LINUX_CLEANER_MIN_FREE` skip cleanup when the filesystem holding `HOME` already has at least `SIZE` free (e.g. `10G`), printing a skip note on `--dry-run` and recording `Result: skipped at or above --min-free SIZE` in `last-report.txt`. `0` disables the check, and an unreadable free-space value prints a warning and the run proceeds as without `--min-free`.

- Send a critical desktop notification (`Cleanup stopped with exit status <N> before finishing; see journalctl --user -t linux-cleaner.`) when an opted-in cleanup (`--notify` or `LINUX_CLEANER_NOTIFY=1`) exits non-zero before reaching its result report, while preserving the exit status and leaving dry-run, non-cleanup, and already-notified runs unchanged.

- Suggest `cleaner --init-config` with the destination user config path at the
  end of a preview (`--dry-run`) when the active configuration was discovered
  from a shared location (/etc or checkout) and no user config exists yet, while
  leaving explicit-config, existing-user-config, quiet, and JSON runs unchanged.

- Point a confirmed manual cleanup (`cleaner --clean` without `--force` or
  `--quiet`) at `systemctl --user enable --now linux-cleaner-clean.timer` when
  the user daily timer unit is installed but `disabled`, while leaving forced,
  quiet, failed, timer-enabled, and unit-absent runs silent.

- Ship native Fish tab completion (`completions/cleaner.fish`) for `cleaner` and `cleaner.sh`,
  installed under `$DATADIR/fish/vendor_completions.d/cleaner.fish` (mode `0644`) by both
  `Makefile` and `install.sh` and removed on uninstall.

- Ship native Zsh tab completion (`completions/_cleaner`) for `cleaner` and `cleaner.sh`,
  installed under `$DATADIR/zsh/site-functions/_cleaner` (mode `0644`) by both
  `Makefile` and `install.sh` and removed on uninstall.

- `--notify` and `LINUX_CLEANER_NOTIFY` send an opt-in desktop notification via
  `notify-send` summarizing the cleanup result after inline retention
  (`--urgency=critical` when a target failed, the run hit an operation failure, or it
  was interrupted), while acting as a no-op on dry-run and never failing or blocking a
  cleanup. Read-only and session modes ignore an inherited `LINUX_CLEANER_NOTIFY`.
  `libnotify` is an optional dependency.

- Ship Bash tab completion (`completions/cleaner.bash`) for `cleaner` and `cleaner.sh`,
  installed under `$DATADIR/bash-completion/completions/cleaner` (mode `0644`) by both
  `Makefile` and `install.sh` and removed on uninstall.

- `--min-age DAYS` and `LINUX_CLEANER_MIN_AGE` raise every ordinary target's age
  threshold to at least `DAYS` days for one cleanup or dry-run preview (with CLI
  `--min-age` overriding the environment) while skipping `action:*` rows.

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

- Re-check each target's `CHECK_PROCESSES` immediately before deleting, quarantining, or running its action, so a process that starts after analysis is left alone (`[BLOCKED]`, counted as skipped rather than failed) instead of having its cache removed; a failed re-check skips the target, and targets with no process check are unchanged.

- Refuse a symlinked `~/.cache/linux-cleaner/quarantine` directory during trash cleanup, `--list-sessions`, `--restore`, and `--purge-sessions` (`Error: Refusing symlinked quarantine directory '<path>'.`) so sessions behind the link are not reported as missing and nothing is moved, and warn from `--doctor` (`WARN: quarantine: symlinked quarantine directory refused (<path>)`).

- Stop an aged `--trash` quarantine from moving more files once its `quarantine.meta` record cannot be written, so the rest of the target stays in place instead of landing as unrecorded payload that `--restore` cannot bring back.

- Stop fish completion from offering working-directory files for a bare `cleaner` argument, which the CLI refuses as an unknown option; `--config`, `--log`, `--only-path` and `--exclude-path` still complete files.

- Refuse a long option (`--...`) or `-d` as the argument of `--only-path`, `--lock-wait`, `--min-reclaim`, `--min-free`, `--min-age`, or `--trash-keep-days` (`Error: <flag> requires a value, got option '<token>'.`), so an unquoted empty variable before `--dry-run` cannot swallow `--dry-run` and turn a preview into a deletion. A missing `--only-path` value still reports the literal-absolute-path error, and negative integers such as `--lock-wait -1` and `--trash-keep-days -5` still reach their numeric checks.

- Refuse a cross-filesystem `--restore` when the full payload or aged staging directory exceeds destination free space, keeping the payload and recovery record in quarantine for a retry; same-filesystem moves and unreadable device or free-space probes behave as before.

- Scope the commented `Nix Store` example row's process check in `cleaner.conf` to active Nix commands (`nix,nix-build,nix-store`) instead of `nix-daemon` so uncommenting it on multi-user Nix installs is not permanently blocked, document that it runs as the user without root, list `nix-store` among runtime-sized actions in the CLI reference, and update `--exclude-path` help and shell completions to describe containing paths.

- Record `linux_cleaner_last_run_success 0` with a current timestamp (and zero target and byte counts) in `LINUX_CLEANER_METRICS_FILE` when a cleanup exits non-zero before saving its report (such as a preflight or quarantine-session creation failure), while preserving the exit status and leaving dry-run, read-only, and already-written runs unchanged.

- Refuse `--purge-sessions keep-latest:0` (and zero-padded zeros) with an error (`Error: Invalid count in '<target>'. Use keep-latest:<count> with a count of at least 1, e.g. keep-latest:5.`), preventing a zero count selector from purging every session like `all`.

- Make `--exclude-path` (and `LINUX_CLEANER_EXCLUDE_PATH`) also skip targets whose resolved physical or expanded literal path contains, equals, or lies below the excluded path, so a parent target cannot delete an excluded child directory and a target under a symlinked parent of the excluded literal path is still excluded.

- Refuse a long option (`--...`) or `-d` as the argument of `-c/--config`, `-r/--risk`, `-e/--exclude`, `--restore`, `--only`, `--only-exact`, `--only-target`, `--exclude-target`, or `--purge-sessions` (`Error: <flag> requires a value, got option '<token>'.`), so an unquoted empty variable before `--dry-run` cannot swallow `--dry-run` and turn a preview into a deletion, while still accepting other dash-leading values such as `-x*` or a target `NAME` of `-n`.

- Preserve a quarantine session's directory mtime when a partial (`--only` / `--only-exact`) or failed restore keeps the session, so `older-than` retention still retires the remaining targets on the session's original schedule.

- Keep Bash session-name completion working under failglob by discovering session directories via compgen instead of expanding a pathname glob, offering selectors and sessions without aborting.

- Keep the git-tracked target guard enabled for readable targets that require `sudo` (such as an outside-`HOME` target under an unwritable parent directory), skipping the git check only when the cleaner runs as root or the target is unreadable without `sudo`.

- Complete file paths as well as directories for `--only-path` across Bash, Zsh, and Fish tab completions, and stop Zsh offering stacked short options that the parser rejects.

- Treat an existing outside-`HOME` target under an unwritable parent directory as requiring `sudo` when the whole target is removed (no positive age threshold and no exclusion patterns), so unprivileged runs skip it with the requires-root warning instead of deleting its contents and failing on the directory itself.

- Fail closed (`[SKIP]`, `git-tracked check failed`) when a target lies inside a Git work tree whose tracked files cannot be listed by `git ls-files` (such as a corrupt `.git/index`), instead of treating the failure as zero tracked files and cleaning the target.

- Refuse combining `--restore`, `--purge-sessions`, and `--list-sessions` (`Error: --restore, --purge-sessions and --list-sessions cannot be combined.`) instead of silently dropping the second mode after running the first.

- `make uninstall` and `install.sh uninstall` remove the `cleaner.conf.example` a
  re-install shipped next to an existing system config, while still keeping
  `cleaner.conf`.

- Failed process inspection skips guarded targets before sizing or cleanup, including
  missing `pgrep`, invalid expressions and partial query failures; unguarded targets
  remain usable.

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

[Unreleased]: https://github.com/eserlxl/cleaner/compare/v1.9.0...HEAD
[1.9.0]: https://github.com/eserlxl/cleaner/releases/tag/v1.9.0
[1.8.0]: https://github.com/eserlxl/cleaner/releases/tag/v1.8.0
[1.7.1]: https://github.com/eserlxl/cleaner/releases/tag/v1.7.1
[1.7.0]: https://github.com/eserlxl/cleaner/releases/tag/v1.7.0
[1.6.0]: https://github.com/eserlxl/cleaner/releases/tag/v1.6.0
[1.5.0]: https://github.com/eserlxl/cleaner/releases/tag/v1.5.0
[1.4.2]: https://github.com/eserlxl/cleaner/releases/tag/v1.4.2
[1.4.1]: https://github.com/eserlxl/cleaner/releases/tag/v1.4.1
[1.4.0]: https://github.com/eserlxl/cleaner/releases/tag/v1.4.0
[1.3.0]: https://github.com/eserlxl/cleaner/releases/tag/v1.3.0
[1.2.0]: https://github.com/eserlxl/cleaner/releases/tag/v1.2.0
[1.1.0]: https://github.com/eserlxl/cleaner/releases/tag/v1.1.0
[1.0.0]: https://github.com/eserlxl/cleaner/releases/tag/v1.0.0
