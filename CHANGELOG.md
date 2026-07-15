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

### Added
- `--list-sessions --json` — emit a machine-readable JSON inventory of
  quarantine sessions (`sessions` array of `timestamp`/`size_bytes`/
  `size_human`/`date`/`targets` with per-target `type`/`path`).
- Dry-run `--json` also emits `total_reclaimable_human` and per-target
  `size_human` alongside the existing byte fields.
- `--list-targets --json` also emits per-target `description` and
  `min_age_days` alongside the existing `name`/`risk`/`path` fields.
- `--exclude-target PATTERN` — with cleanup, skip config targets whose
  `NAME` contains `PATTERN` (substring match). Combined with
  `--only-target`, both filters apply. Exits 1 if nothing remains.
  `LINUX_CLEANER_EXCLUDE_TARGET` mirrors the flag for automation.
- `LINUX_CLEANER_CONFIG` — when set to a non-empty path, selects the
  configuration file (same as `--config`). Explicit `-c/--config` overrides.
- `--check-config` — validate the configuration file with the same
  structural checks as a cleanup run and exit without disk analysis.
- `LINUX_CLEANER_ALLOW_OUTSIDE_HOME` — when set to `1`, `true`, or `yes`,
  enables `--allow-outside-home`. CLI flags override this variable.

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

[Unreleased]: https://github.com/eserlxl/cleaner/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/eserlxl/cleaner/releases/tag/v1.2.0
[1.1.0]: https://github.com/eserlxl/cleaner/releases/tag/v1.1.0
[1.0.0]: https://github.com/eserlxl/cleaner/releases/tag/v1.0.0

<!-- Release planning: eight [Unreleased] env/CLI items warrant minor 1.3.0 per versioning policy. -->

<!-- Release planning: eight [Unreleased] env/CLI items warrant minor 1.3.0 per versioning policy. -->

### Added
- Operator runbook `docs/QUARANTINE-OPS.md` for quarantine inventory, retention, restore, and purge.
