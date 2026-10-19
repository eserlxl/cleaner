# Linux Cleaner Runbook

## Documentation layout

Scheduling examples live in this `RUNBOOK.md` plus `examples/systemd/` and `examples/linux-cleaner.env.example`. README links here instead of duplicating full crontab blocks.

## Table of contents

1. Unattended operations contract
2. Cron recipes
3. systemd user timers
4. Environment recipes
5. Appendix: example files

## Unattended operations contract

Scheduler-safe defaults: use `--force` for non-interactive purge; pair `--trash` cleans with `--purge-sessions older-than:DAYS` (or `max-size:SIZE` for a disk budget), or let the cleanup run retire old sessions itself with `--trash-keep-days DAYS`. Danger tier requires explicit `--yes-danger` / `LINUX_CLEANER_YES_DANGER=1` and must never be default-scheduled.

Config resolution: `-c` / `LINUX_CLEANER_CONFIG`, XDG user config, `/etc/linux-cleaner/cleaner.conf`, script-adjacent `cleaner.conf`.

Validate a config without disk analysis (CI / packager gate):

```sh
cleaner --check-config --config /path/to/cleaner.conf
```

Exit codes: skips exit 0; failed operations exit 1, as does a mutating run that cannot acquire the lock within its configured wait (zero by default); an interrupted cleanup exits 130 (SIGINT) or 143 (SIGTERM) after saving its partial report (see [Exit status](docs/cli-reference.md#exit-status)).

Scheduled mutations may opt in to bounded lock contention waiting with
`LINUX_CLEANER_LOCK_WAIT=30` in their existing environment profile, or
`--lock-wait 30` on a command. Unset/empty means `0`, preserving fail-fast behavior.
The retention unit reads no profile, so its command line already waits up to
`--lock-wait 3600` seconds for a cleanup that still holds the lock.
Use literal decimal seconds `0..2147483647` (leading zeros allowed); last CLI
value overrides inherited input. A positive wait requires `flock`. Timeout exits
`1` before target/session/report/log effects; lock-file opening may still occur.
Dry-run, inventory, report, check-config and init-config never acquire or wait.

## Cron: daily cleanup

```cron
0 3 * * * LINUX_CLEANER_FORCE=1 cleaner --clean --force
```

The systemd units run at idle CPU and IO priority (`Nice=19`, `IOSchedulingClass=idle`) and are bounded by `TimeoutStartSec=2h`: a hung run gets `SIGTERM` and the unit fails (non-zero exit, shown by `systemctl --user status`) instead of blocking later timer slots. A cleanup stopped during its cleanup phase also saves an `Interrupted: SIGTERM` result report. For the same under cron, prefix the command with `timeout 2h nice -n 19 ionice -c 3`.

Permanent deletion of safe targets. Quarantine is opt-in and must be paired with the retention purge below, or carry its own retention:

```cron
0 3 * * * LINUX_CLEANER_FORCE=1 LINUX_CLEANER_TRASH=1 cleaner --clean --trash --force
0 3 * * * LINUX_CLEANER_FORCE=1 cleaner --clean --trash --force --trash-keep-days 30
```

To clean only under disk pressure, schedule an hourly run with `--min-free SIZE` (or `LINUX_CLEANER_MIN_FREE`); free space is measured on the filesystem holding `HOME`, and runs at or above `SIZE` free skip with exit `0`:

```cron
0 * * * * LINUX_CLEANER_FORCE=1 cleaner --clean --force --min-free 10G
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

Use this to watch session growth under trash mode before retention runs. `LINUX_CLEANER_JSON=1` is also valid with `--list-sessions`, `--list-targets`, or `--report` (not only dry-run).

Outside-HOME package-cache targets (e.g. `/var/cache/pacman/pkg`) are allowed. They are medium risk, so the safe-tier timer does not select them; pass `--risk medium`. They need root, and a target is skipped when privileges are not available. `LINUX_CLEANER_ALLOW_OUTSIDE_HOME` and `--allow-outside-home` are deprecated and have no effect.

## systemd user timers

`make install` places the units on the systemd user path (`$PREFIX/lib/systemd/user`) and does not enable them. A checkout that is not installed can instead copy units from `examples/systemd/` to `~/.config/systemd/user/`. Copy the installed `/usr/local/share/linux-cleaner/linux-cleaner.env.example` (Arch/package `PREFIX=/usr`: `/usr/share/linux-cleaner/linux-cleaner.env.example`; checkout: `examples/linux-cleaner.env.example`) to `~/.config/linux-cleaner/env` (create the directory if needed) for the cleanup service's safe-tier defaults and overrides. By default, only `linux-cleaner-clean.service` loads this file. The monitor has an independent optional profile described below, and retention uses its own unit settings; cleanup settings do not affect either unless you explicitly share the monitor profile. Use literal absolute paths in the environment file: systemd does not expand `$HOME` there.

To select one existing project, set `LINUX_CLEANER_ONLY_PATH="/absolute/project path"`
in `~/.config/linux-cleaner/env`, optionally with a NAME filter such as
`LINUX_CLEANER_ONLY_TARGET="C++ Build"`. The path is literal (no `$HOME`, tilde,
or glob expansion), must be absolute and contain no line feeds, and excludes
all `action:*` targets. Leave `LINUX_CLEANER_TRASH_KEEP_DAYS` unset when scoping;
use the separate retention timer for global quarantine retention. Unset or empty
`LINUX_CLEANER_ONLY_PATH` preserves unscoped cleanup; CLI `--only-path` overrides it.
Preview the same scope before enabling the timer:

```sh
LINUX_CLEANER_ONLY_PATH="/absolute/project path" cleaner --list-targets --json
```

Enable the daily cleanup timer. It deletes permanently unless `LINUX_CLEANER_TRASH=1` is set in `~/.config/linux-cleaner/env`. Enable the retention timer only in that case:

```sh
systemctl --user enable --now linux-cleaner-clean.timer
# When LINUX_CLEANER_TRASH=1 is set in ~/.config/linux-cleaner/env:
systemctl --user enable --now linux-cleaner-retention.timer
# Optional JSON monitoring dry-run (parity with cron below):
systemctl --user enable --now linux-cleaner-monitor.timer
```

The monitor optionally reads `~/.config/linux-cleaner/monitor.env`; missing or
empty leaves its default whole-configuration JSON preview unchanged. Create it
with literal values (systemd does not expand `$HOME`), for example:

```ini
LINUX_CLEANER_CONFIG=/absolute/path/to/cleaner.conf
LINUX_CLEANER_ONLY_PATH="/absolute/project path"
LINUX_CLEANER_ONLY_TARGET="C++ Build"
```

This file is independent of the cleanup `env` file. To share settings explicitly
when no separate monitor profile exists, run
`ln -s env ~/.config/linux-cleaner/monitor.env`. The monitor always runs
`cleaner --quiet --dry-run --json`: inherited `LINUX_CLEANER_FORCE=1` and
`LINUX_CLEANER_JSON=0` cannot enable cleanup or disable JSON. Trash, logging,
minimum-reclaim, minimum-free and retention settings remain preview-only; no retention runs.
Existing invalid settings still error, including path scope combined with
`LINUX_CLEANER_TRASH_KEEP_DAYS`. The retention service never reads either profile.

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

## Env recipe: clean under disk pressure

To keep caches until space runs short, let the cleanup timer run hourly and skip while the filesystem holding `HOME` still has enough free space. Add the threshold to `~/.config/linux-cleaner/env`:

```ini
LINUX_CLEANER_MIN_FREE=10G
```

Then override the timer schedule with `systemctl --user edit linux-cleaner-clean.timer` (the empty `OnCalendar=` clears the shipped 03:00 slot):

```ini
[Timer]
OnCalendar=
OnCalendar=hourly
```

Preview which way a run would go with `cleaner --dry-run --min-free 10G`.
Revert to the daily schedule with `systemctl --user revert linux-cleaner-clean.timer`.

## Env recipe: JSON monitoring

`LINUX_CLEANER_JSON=1` enables `--json` for dry-run reclaim summaries, `--list-targets` inventories, `--list-sessions` quarantine inventories, or the `--report` summary of the last cleanup. Examples:

```sh
LINUX_CLEANER_JSON=1 cleaner --dry-run
LINUX_CLEANER_JSON=1 cleaner --list-sessions
cleaner --list-sessions --json
cleaner --report --json
```

`cleaner --report --json` summarizes the last saved cleanup (`result`, `failed`, `failed_targets`, `interrupted`, `retention_failed`), so a monitor can alert on a failed or interrupted nightly run. Check `retention_failed` separately from target failures: it is `true` on inline retention failure, `false` when retention did not fail (including cancellation), and `null` for historical reports, runs without retention, or retention interrupted before its outcome is known:

```cron
30 3 * * * cleaner --report --json
```

The same monitor can read `quarantined_bytes` and `permanent_bytes` for the last cleanup's exact accounted estimates, without rounded-unit parsing. They are `null` for historical or malformed byte records, zero for new nothing-to-clean/minimum-reclaim/minimum-free skips, and exclude retention purges. Interrupted runs include only already-credited work. Ordinary targets and system actions credit planned sizes; user prune actions credit nonnegative free-space deltas, so these counters do not guarantee physically freed blocks. Cancelling cleanup before work preserves the previous report.

## Env recipe: outside-HOME package caches

Outside-HOME targets are always allowed. Package-cache rows are medium risk and need root. `LINUX_CLEANER_ALLOW_OUTSIDE_HOME` is a deprecated no-op.

```sh
cleaner --clean --force --risk medium
```

Package-cache `action:*` tokens include `action:apt_clean`, `action:dnf_clean`, `action:zypper_clean`, and `action:apk_clean` (each skipped when the manager binary is absent).

## Env recipe: selective targets

`LINUX_CLEANER_ONLY_TARGET=NPM` narrows by NAME; `LINUX_CLEANER_EXCLUDE_TARGET=Chromium` skips matching NAMEs; `LINUX_CLEANER_EXCLUDE=.git,*.log` excludes path globs. `LINUX_CLEANER_CONFIG=/path/to.conf` selects the config without `-c`.

Inspect the same selection without disk or process analysis before scheduling cleanup:

```sh
LINUX_CLEANER_ONLY_TARGET=NPM,Yarn LINUX_CLEANER_EXCLUDE_TARGET=Yarn cleaner --list-targets --json
```

NAME filters also apply to human inventory. Inventory lists all risk levels; the
cleanup risk ceiling still controls which selected targets a cleanup processes.

## danger tier (explicit opt-in)

> WARNING: Never schedule `LINUX_CLEANER_YES_DANGER=1` by default. See CONTRIBUTING safety invariants.

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
