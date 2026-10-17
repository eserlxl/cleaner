# Reports and operation log

What `cleaner` reports after a run, where it saves the last report, and the optional operation log.

## Plan and result reports (`--report`)

Every human-readable cleanup run prints a **plan report** after the savings total (mode, risk ceiling, config path, status counts, reclaimable bytes by risk, top 10 largest targets, and skipped/blocked/protected target groups). `--quiet` hides the plan report on screen.

After a non-dry-run cleanup, a **result report** prints `cleaned`, `skipped`, and `failed` counts, elapsed seconds, bytes quarantined versus permanently reclaimed, and the quarantine session path. If the cleanup loop is stopped by `SIGINT` or `SIGTERM`, the result report appends `Interrupted: SIGINT|SIGTERM before all targets finished`, is printed and saved to `last-report.txt` with the partial counts, and the cleaner exits `130` (`SIGINT`) or `143` (`SIGTERM`). Both reports are saved (without ANSI colors, and including the plan even under `--quiet`) to `${XDG_STATE_HOME:-$HOME/.local/state}/linux-cleaner/last-report.txt` (directory mode `0700`, refusing symlinks), including when nothing needed cleaning. Run `cleaner --report` to view the saved report (or `cleaner --report --json` for a machine-readable JSON summary). Dry-run, `--json`, and read-only modes do not write `last-report.txt`.

When `--trash-keep-days` is requested, the saved cleanup report includes `Retention failed: true|false` after retention runs, including nothing-to-clean and minimum-reclaim exits. `--report --json` exposes this as the additive nullable `retention_failed` boolean. `false` means no retention failure, including cancellation; historical reports, runs without retention, and reports saved before retention finishes return `null`. The current cleanup report is saved before retention starts so an interruption during retention does not lose it, then updated once retention finishes. The `cleaned`, `skipped`, `failed`, and `failed_targets` fields continue to describe cleanup targets only.

## Operation log (`--log` / `LINUX_CLEANER_LOG`)

Operation logging is **opt-in and off by default**:

```sh
cleaner --clean --log                                      # logs to ~/.cache/linux-cleaner/operations.log
LINUX_CLEANER_LOG=$HOME/.cache/linux-cleaner/ops.log cleaner --clean
```

- The log path supports `$HOME`, `~`, `$USER`, `$XDG_CACHE_HOME`, `$XDG_CONFIG_HOME`, `$XDG_DATA_HOME`, and `$XDG_STATE_HOME` placeholders (relative XDG values fall back to the spec default) and **must resolve inside `$HOME`** (paths outside `$HOME` are refused and logging is disabled).
- Records one line per real cleanup target (`mode=delete|quarantine|action`), per interrupted cleanup run (`mode=run outcome=interrupted signal=SIGINT|SIGTERM`), per restored target (`mode=restore`, outcome `success`/`failed`/`conflict`/`missing`), or per purged session (`mode=purge`), and never logs file contents or secrets:

```text
2026-01-01T12:00:00 mode=delete risk=safe target='NPM Cache' path='/home/you/.npm/_cacache' outcome=success
2026-01-08T09:00:00 mode=purge session='2026-01-01_12-00-00' outcome=success
```
