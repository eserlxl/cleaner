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
- `--purge-sessions SESSION` to permanently delete quarantine sessions
  (`latest`, `all`, or a specific timestamp) and reclaim the disk space that
  trash mode holds. Irreversible; prompts for confirmation unless `-f/--force`
  is given, and only ever removes directories under the tool-owned quarantine
  base.

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
