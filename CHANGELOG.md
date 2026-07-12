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

[Unreleased]: https://github.com/eserlxl/cleaner/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/eserlxl/cleaner/releases/tag/v1.0.0
