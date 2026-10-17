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

Scheduler-safe defaults: use `--force` for non-interactive purge; pair `--trash` cleans with `purge-sessions older-than:DAYS` (or `max-size:SIZE` for a disk budget), or let the cleanup run retire old sessions itself with `--trash-keep-days DAYS`. Danger tier requires explicit `--yes-danger` / `LINUX_CLEANER_YES_DANGER=1` and must never be default-scheduled.

Config resolution: `-c` / `LINUX_CLEANER_CONFIG`, XDG user config, `/etc/linux-cleaner/cleaner.conf`, script-adjacent `cleaner.conf`.

Validate a config without disk analysis (CI / packager gate):

```sh
cleaner --check-config --config /path/to/cleaner.conf
```

Exit codes: skips exit 0; failed operations exit 1, as does a mutating run refused because another one holds the lock; an interrupted cleanup exits 130 (SIGINT) or 143 (SIGTERM) after saving its partial report (see README Exit status).

## Cron: daily cleanup

```cron
0 3 * * * LINUX_CLEANER_FORCE=1 cleaner --clean --force
```

Permanent deletion of safe targets. Quarantine is opt-in and must be paired with the retention purge below, or carry its own retention:

```cron
0 3 * * * LINUX_CLEANER_FORCE=1 LINUX_CLEANER_TRASH=1 cleaner --clean --trash --force
0 3 * * * LINUX_CLEANER_FORCE=1 cleaner --clean --trash --force --trash-keep-days 30
```

## Cron: retention purge

```cron
0 4 * * 0 cleaner --purge-sessions older-than:30 --force
```

Recommended DAY values: 30 (default), 7 (aggressive small disks). Exits 0 when no sessions match. Purge is irreversible.

To cap the disk quarantine holds instead of its age, keep the newest sessions within a size budget:

```cron
0 4 * * 0 cleaner --purge-sessions max-size:5G --force
```

## Cron: monitoring dry-run

```cron
0 */6 * * * LINUX_CLEANER_JSON=1 cleaner --quiet --dry-run
```

## Cron: quarantine inventory (JSON)

```cron
0 */6 * * * cleaner --list-sessions --json
```

Use this to watch session growth under trash mode before retention runs. `LINUX_CLEANER_JSON=1` is also valid with `--list-sessions` or `--list-targets` (not only dry-run).

Outside-HOME package-cache targets (e.g. `/var/cache/pacman/pkg`) are allowed. They are medium risk, so the safe-tier timer does not select them; pass `--risk medium`. They need root, and a target is skipped when privileges are not available. `LINUX_CLEANER_ALLOW_OUTSIDE_HOME` and `--allow-outside-home` are deprecated and have no effect.

## systemd user timers

`make install` places the units on the systemd user path (`$PREFIX/lib/systemd/user`) and does not enable them. A checkout that is not installed can instead copy units from `examples/systemd/` to `~/.config/systemd/user/`. Copy `examples/linux-cleaner.env.example` to `~/.config/linux-cleaner/env` (create the directory if needed) for the cleanup service's safe-tier defaults and overrides. Only `linux-cleaner-clean.service` loads this file. The monitor and retention services use their own unit settings; cleanup filters and JSON flags in this file do not affect them. Use literal absolute paths in the environment file: systemd does not expand `$HOME` there.

Enable the daily cleanup timer. It deletes permanently unless `LINUX_CLEANER_TRASH=1` is set in `~/.config/linux-cleaner/env`. Enable the retention timer only in that case:

```sh
systemctl --user enable --now linux-cleaner-clean.timer
# When LINUX_CLEANER_TRASH=1 is set in ~/.config/linux-cleaner/env:
systemctl --user enable --now linux-cleaner-retention.timer
# Optional JSON monitoring dry-run (parity with cron below):
systemctl --user enable --now linux-cleaner-monitor.timer
```

User linger may be required for timers without an active session.

The timer has `Persistent=true`: enabling it after a missed 03:00 slot (for example a stamp left in `~/.local/share/systemd/timers/` by an earlier install) runs a cleanup immediately. Preview with `cleaner --dry-run` before enabling.

Before uninstalling or removing the package (`sudo make uninstall`, `pacman -R`), each user who enabled the timers runs `systemctl --user disable --now linux-cleaner-clean.timer linux-cleaner-retention.timer linux-cleaner-monitor.timer`, then `systemctl --user daemon-reload` after removal. Removal alone leaves enabled-unit links and loaded timer state.

Switching from `make install` to the distro/AUR package: `make uninstall` keeps `/etc/linux-cleaner/cleaner.conf`, which pacman then refuses as an unowned existing file ("exists in filesystem"). Back it up if edited, then move or remove it before installing the package. If the unit files are already gone, `disable --now` fails: stop the timers by hand, delete the stale `~/.config/systemd/user/timers.target.wants/linux-cleaner-*.timer` links, and run `systemctl --user daemon-reload`.

Journal review:

```sh
journalctl --user -u linux-cleaner-clean.service
journalctl --user -u linux-cleaner-retention.service
journalctl --user -u linux-cleaner-monitor.service
journalctl --user -t linux-cleaner
```

## Env recipe: safe-tier cleanup

```sh
export LINUX_CLEANER_FORCE=1
export LINUX_CLEANER_RISK=safe
# optional: LINUX_CLEANER_QUIET=1 LINUX_CLEANER_LOG=~/.cache/linux-cleaner/ops.log
# debug:    LINUX_CLEANER_DEBUG=1 (same as --debug)
cleaner --clean --force
```

Quarantine instead of delete, paired with the retention purge above (or `linux-cleaner-retention.timer`):

```sh
export LINUX_CLEANER_FORCE=1
export LINUX_CLEANER_TRASH=1
export LINUX_CLEANER_RISK=safe
cleaner --clean --trash --force
```

## Env recipe: JSON monitoring

`LINUX_CLEANER_JSON=1` enables `--json` for dry-run reclaim summaries, `--list-targets` inventories, or `--list-sessions` quarantine inventories. Examples:

```sh
LINUX_CLEANER_JSON=1 cleaner --dry-run
LINUX_CLEANER_JSON=1 cleaner --list-sessions
cleaner --list-sessions --json
cleaner --report --json
```

`cleaner --report --json` summarizes the last saved cleanup (`result`, `failed`, `failed_targets`, `interrupted`), so a monitor can alert on a failed or interrupted nightly run:

```cron
30 3 * * * cleaner --report --json
```

## Env recipe: outside-HOME package caches

Outside-HOME targets are always allowed. Package-cache rows are medium risk and need root. `LINUX_CLEANER_ALLOW_OUTSIDE_HOME` is a deprecated no-op.

```sh
cleaner --clean --force --risk medium
```

Package-cache `action:*` tokens include `action:apt_clean`, `action:dnf_clean`, `action:zypper_clean`, and `action:apk_clean` (each skipped when the manager binary is absent).

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
| examples/systemd/linux-cleaner-clean.service | daily permanent cleanup (quarantine if LINUX_CLEANER_TRASH=1) |
| examples/systemd/linux-cleaner-clean.timer | clean timer |
| examples/systemd/linux-cleaner-retention.service | retention purge |
| examples/systemd/linux-cleaner-retention.timer | retention timer |
| examples/systemd/linux-cleaner-monitor.service | JSON monitoring dry-run |
| examples/systemd/linux-cleaner-monitor.timer | monitor timer (6-hourly) |
| examples/linux-cleaner.env.example | EnvironmentFile template |
