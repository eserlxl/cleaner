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

Config resolution: `-c`, XDG user config, `/etc/linux-cleaner/cleaner.conf`, script-adjacent `cleaner.conf`.

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

## systemd user timers

Copy units from `examples/systemd/` to `~/.config/systemd/user/`. Enable with `systemctl --user enable --now linux-cleaner-clean.timer`. User linger may be required for timers without an active session.

Journal review: `journalctl --user -u linux-cleaner-clean.service`

## Env recipe: safe-tier cleanup

```sh
export LINUX_CLEANER_FORCE=1
export LINUX_CLEANER_TRASH=1
export LINUX_CLEANER_RISK=safe
# optional: LINUX_CLEANER_QUIET=1 LINUX_CLEANER_LOG=~/.cache/linux-cleaner/ops.log
cleaner --clean --trash --force
```

## Env recipe: JSON monitoring

`LINUX_CLEANER_JSON=1` requires dry-run. Example: `LINUX_CLEANER_JSON=1 cleaner --dry-run`

## Env recipe: selective targets

`LINUX_CLEANER_ONLY_TARGET=NPM` and `LINUX_CLEANER_EXCLUDE=.git,*.log` for incident-style runs.

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
| examples/linux-cleaner.env.example | EnvironmentFile template |
