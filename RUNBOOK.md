# Linux Cleaner Runbook

## Documentation layout

Phase 5 examples live in this `RUNBOOK.md` plus `examples/systemd/` and `examples/linux-cleaner.env.example`. README links here instead of duplicating full crontab blocks.

## Table of contents

1. Unattended operations contract
2. Cron recipes
3. systemd user timers
4. Environment recipes
5. Phase 5 completion checklist
6. Appendix: example files

## Unattended operations contract

Scheduler-safe defaults: use `--force` for non-interactive purge; pair `--trash` cleans with `purge-sessions older-than:DAYS`. Danger tier requires explicit `--yes-danger` / `LINUX_CLEANER_YES_DANGER=1` and must never be default-scheduled.

Config resolution: `-c` / `LINUX_CLEANER_CONFIG`, XDG user config, `/etc/linux-cleaner/cleaner.conf`, script-adjacent `cleaner.conf`.

Validate a config without disk analysis (CI / packager gate):

```sh
cleaner --check-config --config /path/to/cleaner.conf
```

Exit codes: skips exit 0; failed operations exit 1 (see README Exit status).

## Cron: daily quarantine cleanup

```cron
0 3 * * * LINUX_CLEANER_FORCE=1 LINUX_CLEANER_TRASH=1 cleaner --clean --trash --force
```

## Cron: retention purge

```cron
0 4 * * 0 cleaner --purge-sessions older-than:30 --force
```

Recommended DAY values: 30 (default), 7 (aggressive small disks). Exits 0 when no sessions match. Purge is irreversible.

## Cron: monitoring dry-run

```cron
0 */6 * * * LINUX_CLEANER_JSON=1 cleaner --quiet --dry-run
```

## Cron: quarantine inventory (JSON)

```cron
0 */6 * * * cleaner --list-sessions --json
```

Use this to watch session growth under trash mode before retention runs. `LINUX_CLEANER_JSON=1` is also valid with `--list-sessions` or `--list-targets` (not only dry-run).

Outside-HOME package-cache targets (e.g. `/var/cache/pacman/pkg`) additionally need `LINUX_CLEANER_ALLOW_OUTSIDE_HOME=1` or `--allow-outside-home`.

## systemd user timers

Copy units from `examples/systemd/` to `~/.config/systemd/user/`. Copy `examples/linux-cleaner.env.example` to `~/.config/linux-cleaner/env` (create the directory if needed) so both service units load the safe-tier defaults.

Enable the paired timers:

```sh
systemctl --user enable --now linux-cleaner-clean.timer
systemctl --user enable --now linux-cleaner-retention.timer
# Optional JSON monitoring dry-run (parity with cron below):
systemctl --user enable --now linux-cleaner-monitor.timer
```

User linger may be required for timers without an active session.

Journal review:

```sh
journalctl --user -u linux-cleaner-clean.service
journalctl --user -u linux-cleaner-retention.service
journalctl --user -u linux-cleaner-monitor.service
```

## Env recipe: safe-tier cleanup

```sh
export LINUX_CLEANER_FORCE=1
export LINUX_CLEANER_TRASH=1
export LINUX_CLEANER_RISK=safe
# optional: LINUX_CLEANER_QUIET=1 LINUX_CLEANER_LOG=~/.cache/linux-cleaner/ops.log
cleaner --clean --trash --force
```

## Env recipe: JSON monitoring

`LINUX_CLEANER_JSON=1` enables `--json` for dry-run reclaim summaries, `--list-targets` inventories, or `--list-sessions` quarantine inventories. Examples:

```sh
LINUX_CLEANER_JSON=1 cleaner --dry-run
LINUX_CLEANER_JSON=1 cleaner --list-sessions
cleaner --list-sessions --json
```

## Env recipe: outside-HOME package caches

```sh
# High-risk: only when cleaning paths outside $HOME (e.g. pacman/apt/dnf/zypper caches).
export LINUX_CLEANER_ALLOW_OUTSIDE_HOME=1
cleaner --clean --force --risk medium
```

Package-cache `action:*` tokens include `action:apt_clean`, `action:dnf_clean`, and `action:zypper_clean` (each skipped when the manager binary is absent).

## Env recipe: selective targets

`LINUX_CLEANER_ONLY_TARGET=NPM` narrows by NAME; `LINUX_CLEANER_EXCLUDE_TARGET=Chromium` skips matching NAMEs; `LINUX_CLEANER_EXCLUDE=.git,*.log` excludes path globs. `LINUX_CLEANER_CONFIG=/path/to.conf` selects the config without `-c`.

## danger tier (explicit opt-in)

> WARNING: Never schedule `LINUX_CLEANER_YES_DANGER=1` by default. See CONTRIBUTING safety invariants.

## Phase 5 completion checklist

- [ ] Cron paired with retention purge documented
- [ ] systemd units verified on user session
- [ ] env recipes reviewed
- [ ] `make check` green
- [ ] No danger-tier in default examples

## Appendix: example files

| Path | Purpose |
|------|---------|
| examples/systemd/linux-cleaner-clean.service | daily trash clean |
| examples/systemd/linux-cleaner-clean.timer | clean timer |
| examples/systemd/linux-cleaner-retention.service | retention purge |
| examples/systemd/linux-cleaner-retention.timer | retention timer |
| examples/systemd/linux-cleaner-monitor.service | JSON monitoring dry-run |
| examples/systemd/linux-cleaner-monitor.timer | monitor timer (6-hourly) |
| examples/linux-cleaner.env.example | EnvironmentFile template |
