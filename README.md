# Linux Cache and Temp File Cleaner

[![License: GPL v3+](https://img.shields.io/badge/License-GPLv3%2B-blue.svg)](LICENSE)
[![AUR](https://img.shields.io/aur/version/linux-cleaner)](https://aur.archlinux.org/packages/linux-cleaner)

**linux-cleaner** is a configuration-driven Bash utility (`cleaner.sh`, installed as `cleaner`) that estimates and reclaims disk space by cleaning caches, temporary files, rotated logs, and stale build directories on Linux systems with a GNU userland.

It runs in **dry-run mode by default** at the `safe` risk ceiling, blocks critical system directories, refuses symlinks, skips caches of running applications, and can move files to a restorable quarantine instead of deleting them.

---

## Contents

- [Quick start](#quick-start)
- [Installation](#installation)
- [Daily cleanup](#daily-cleanup)
- [Risk levels](#risk-levels)
- [Safety at a glance](#safety-at-a-glance)
- [Configuration](#configuration)
- [Documentation](#documentation)
- [Development](#development)
- [License](#license)

---

## Quick start

```sh
cleaner                 # preview safe targets and estimated savings (dry-run default)
cleaner --clean         # clean safe targets after a single confirmation prompt
cleaner --trash --clean # move files to a restorable quarantine instead of deleting
cleaner --report        # view the saved plan and result from the last cleanup
```

Running from a repository checkout works the same way (`./cleaner.sh`, `./cleaner.sh --clean`, `./cleaner.sh --report`). Every option is listed in the [command-line reference](docs/cli-reference.md) and in `man cleaner`.

---

## Installation

On Arch Linux, install the [`linux-cleaner`](https://aur.archlinux.org/packages/linux-cleaner) AUR package with your AUR helper (for example `paru -S linux-cleaner`). Elsewhere, install from a checkout:

```sh
sudo make install            # install under /usr/local (default PREFIX)
sudo make install PREFIX=/usr # install under /usr (standard distro layout)
sudo ./install.sh install     # POSIX-sh alternative (honors PREFIX and DESTDIR)
```

Both installers copy the systemd user units **without enabling them**. `cleaner` needs `bash`, GNU `coreutils`, and GNU `findutils`. Install variables, uninstalling, switching from `make install` to a package, and the configuration lookup order are in [docs/installation.md](docs/installation.md).

---

## Daily cleanup

Enable the daily systemd user timer (runs `cleaner --clean --force` at 03:00 daily and permanently deletes `safe` targets):

```sh
systemctl --user enable --now linux-cleaner-clean.timer
```

> [!WARNING]
> Nothing is enabled on install; the Arch package only prints this command as a hint. Preview first with `cleaner --dry-run`. The timer has `Persistent=true`: if a 03:00 slot was missed since its last recorded run (for example a stamp left in `~/.local/share/systemd/timers/` by an earlier install), enabling it runs a cleanup **immediately**, not at the next 03:00.

To customize the scheduled cleanup, copy `/usr/local/share/linux-cleaner/linux-cleaner.env.example` (Arch/package `PREFIX=/usr`: `/usr/share/linux-cleaner/linux-cleaner.env.example`; checkout: `examples/linux-cleaner.env.example`) to `~/.config/linux-cleaner/env`, creating the directory if needed. **By default, this file is read only by `linux-cleaner-clean.service`** (`EnvironmentFile=-%h/.config/linux-cleaner/env`), not by manual `cleaner` runs or the other units, and systemd does not expand `$HOME` in it, so use literal absolute paths.

- **`LINUX_CLEANER_RISK=safe`** (default) keeps unattended runs on `safe` targets; raise it to `medium` only if you accept unattended deletion of medium-tier data.
- **`LINUX_CLEANER_TRASH=1`** moves files into `~/.cache/linux-cleaner/quarantine/` instead of deleting them. Then also enable the weekly retention timer, so quarantine disk usage stays bounded:

```sh
systemctl --user enable --now linux-cleaner-retention.timer   # purge sessions older than 30 days, Sundays 04:00
```

An optional six-hourly JSON preview timer (`linux-cleaner-monitor.timer`) is also installed.
Its optional `~/.config/linux-cleaner/monitor.env` profile is independent of cleanup
settings; missing means the usual whole-configuration preview. Use literal absolute
paths, for example `LINUX_CLEANER_ONLY_PATH=/absolute/project`, optionally with
`LINUX_CLEANER_CONFIG=/absolute/cleaner.conf`. To share settings explicitly, you may
symlink `monitor.env` to `env`; see [the scheduling recipe](RUNBOOK.md#systemd-user-timers).
The command always requests dry-run JSON, even with inherited `LINUX_CLEANER_FORCE=1` or
`LINUX_CLEANER_JSON=0` mirrors; it never performs retention. Existing incompatible settings
(such as a path scope plus global retention) still fail. Check what a run did:

```sh
cleaner --report                                   # saved plan and result from the last cleanup
journalctl --user -u linux-cleaner-clean.service   # systemd journal output
journalctl --user -t linux-cleaner                 # output of all three units
```

Cron recipes, user linger notes, and unattended environment examples are in [RUNBOOK.md](RUNBOOK.md).

---

## Risk levels

Every target has a risk level, and `-r, --risk LEVEL` (or `LINUX_CLEANER_RISK`) sets the highest tier to include (default: `safe`):

| Level | What it covers | Recoverable? |
|-------|----------------|--------------|
| `safe` (default) | Regenerable caches, temporary scratch directories, rotated logs, idle C/C++ build trees | Yes: nothing of user work or history is lost |
| `medium` | Browser and package-manager caches, plus **AI assistant transcripts, desktop Trash, and downloaded artifacts** | **No**: these records cannot be recovered after permanent deletion |
| `danger` | Targets that can cause significant state loss | Always asks for confirmation, even under `--force`, unless `--yes-danger` is passed; none are active in the shipped config |

The exact `medium` rows and their age thresholds are listed in [docs/safety.md](docs/safety.md#risk-levels).

---

## Safety at a glance

- **Dry-run by default**: nothing is modified without `--clean`, `--force`, `--interactive`, or `LINUX_CLEANER_FORCE=1`.
- **System directories are refused**: `/`, `$HOME` itself, `/usr`, `/etc`, `/var`, `/opt`, `/tmp`, and other top-level system paths are skipped as `[UNSAFE]`; their descendants are allowed.
- **No symlinks, no `eval`, no shell globbing**: symlinked targets are refused, and wildcards are expanded by `find` below a literal prefix.
- **Running applications are left alone**: a target whose `CHECK_PROCESSES` are active is skipped as `[BLOCKED]`.
- **Your files are protected**: git-tracked files and `protect|PATH` directories are never cleaned, and a restore never overwrites an existing file.
- **Quarantine is restorable**: `--trash` sessions can be listed with `--list-sessions` and brought back with `--restore latest`.

The full safety model is in [docs/safety.md](docs/safety.md); recovery steps are in [docs/QUARANTINE-OPS.md](docs/QUARANTINE-OPS.md).

---

## Configuration

Targets live in [`cleaner.conf`](cleaner.conf), one pipe-delimited row per target:

```text
RISK_LEVEL|NAME|PATH_EXPRESSION|DESCRIPTION|MIN_AGE_DAYS|CHECK_PROCESSES|CUSTOM_ACTION
safe|NPM Cache|$HOME/.npm/_cacache|NPM dependency cache files|0|node,npm|
protect|$HOME/Projects
```

Run `cleaner --init-config` to copy the active config to `~/.config/linux-cleaner/cleaner.conf` for editing, `cleaner --list-targets` to see what it covers, and `cleaner --check-config` to validate it.

> [!WARNING]
> Predefined `action:*` commands (for example `action:paccache_keep1`) bypass quarantine and delete irreversibly.

Fields, shipped targets, actions, wildcard paths, and `protect` lines are described in [docs/configuration.md](docs/configuration.md).

---

## Documentation

**User guides**

| Document | Contents |
|----------|----------|
| [docs/installation.md](docs/installation.md) | Install variables, uninstalling, switching to a package, config lookup, requirements |
| [docs/configuration.md](docs/configuration.md) | Shipped targets, row format, actions, wildcards, `protect`, validation |
| [docs/cli-reference.md](docs/cli-reference.md) | Every option, environment variable, and exit status |
| [docs/safety.md](docs/safety.md) | Risk levels in detail and the full safety model |
| [docs/reports-and-logs.md](docs/reports-and-logs.md) | Plan and result reports, `--report`, and the operation log |
| [RUNBOOK.md](RUNBOOK.md) | Unattended cron and systemd operations |
| [docs/QUARANTINE-OPS.md](docs/QUARANTINE-OPS.md) | Quarantine sessions, restore, retention, and recovery |
| [docs/threat-model.md](docs/threat-model.md) | Security threat model |

**Maintainer docs**

| Document | Contents |
|----------|----------|
| [CONTRIBUTING.md](CONTRIBUTING.md) | Safety invariants and the change checklist |
| [RELEASING.md](RELEASING.md) | Release and AUR packaging steps |
| [docs/contract-semver-taxonomy.md](docs/contract-semver-taxonomy.md), [docs/config-field-governance.md](docs/config-field-governance.md), [docs/action-registry-governance.md](docs/action-registry-governance.md), [docs/cli-env-json-governance.md](docs/cli-env-json-governance.md), [docs/env-automation-contract.md](docs/env-automation-contract.md) | Contract and governance rules |
| [docs/hermetic-test-guards.md](docs/hermetic-test-guards.md), [docs/test-coverage-matrix.md](docs/test-coverage-matrix.md), [docs/manual-smoke-checklist.md](docs/manual-smoke-checklist.md), [docs/distro-smoke-log.md](docs/distro-smoke-log.md) | Testing |
| [docs/packager-handoff.md](docs/packager-handoff.md), [docs/packaging-install-parity.md](docs/packaging-install-parity.md) | Packaging |

---

## Development

Read [CONTRIBUTING.md](CONTRIBUTING.md) before changing anything, and record user-facing changes under `[Unreleased]` in [CHANGELOG.md](CHANGELOG.md). The local gate runs before every push or release:

```bash
shellcheck cleaner.sh test_cleaner.sh install.sh release-notes.sh   # static analysis / lint
make check                            # runbook example validation + full safety suite (test_cleaner.sh)
```

The test suite (`test_cleaner.sh`) is hermetic: it stubs `sudo`, the package managers, and the user-level prune tools (full list in [docs/hermetic-test-guards.md](docs/hermetic-test-guards.md)) and builds a mock `$HOME`, requiring only `bash`, GNU `coreutils`, GNU `findutils`, and `shellcheck` (no root, network, or Arch-specific tooling). After cutting a release tag, verify it on the tagged HEAD; see [RELEASING.md](RELEASING.md#post-tag-local-verification).

---

## License

This project is licensed under the **GNU General Public License v3.0 or later** (SPDX identifier: `GPL-3.0-or-later`) — see the [LICENSE](LICENSE) file for the full text.

Copyright (C) 2026 Eser KUBALI
