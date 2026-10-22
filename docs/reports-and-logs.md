# Reports and operation log

What `cleaner` reports after a run, where it saves the last report, and the optional operation log.

## Plan and result reports (`--report`)

Every human-readable cleanup run prints a **plan report** after the savings total (mode, risk ceiling, config path, status counts, reclaimable bytes by risk, top 10 largest targets, and skipped/blocked/protected target groups). `--quiet` hides the plan report on screen. A target blocked by an active process stays out of that total. When the target would otherwise be reclaimable, the `[BLOCKED]` line and the blocked-group name include the size, and the plan prints `Held by active processes: Y (not counted above)` plus `In use: blocked=N would_reclaim=Y` after the risk totals. A cleanup result adds the same `In use:` line after `Reclaimed:` when any target was blocked during planning or because its process started before that target was cleaned. `--report --json`, the desktop notification, and the Prometheus textfile ignore the line.

After a non-dry-run cleanup, a **result report** prints `cleaned`, `skipped`, and `failed` counts, elapsed seconds, bytes quarantined versus permanently reclaimed, and the quarantine session path. If the cleanup loop is stopped by `SIGINT` or `SIGTERM`, the result report appends `Interrupted: SIGINT|SIGTERM before all targets finished`, is printed and saved to `last-report.txt` with the partial counts, and the cleaner exits `130` (`SIGINT`) or `143` (`SIGTERM`). Both reports are saved (without display ANSI colors, and including the plan even under `--quiet`) to `${XDG_STATE_HOME:-$HOME/.local/state}/linux-cleaner/last-report.txt` (directory mode `0700`, refusing symlinks), including when nothing needed cleaning. Run `cleaner --report` to view the saved report (or `cleaner --report --json` for a machine-readable JSON summary). Dry-run, `--json`, and read-only modes do not write `last-report.txt`.

Saved reports append one `Failed target: NAME` record per failed target, preserving each configured NAME, including commas, quotes, backslashes, and control bytes. JSON uses these exact records for `failed_targets`; the on-screen comma-separated summary is unchanged. Historical reports without exact records retain legacy comma-summary parsing.

When `--trash-keep-days` is requested, the saved cleanup report includes `Retention failed: true|false` after retention runs, including nothing-to-clean, minimum-reclaim and minimum-free exits. `--report --json` exposes this as the additive nullable `retention_failed` boolean. `false` means no retention failure, including cancellation; historical reports, runs without retention, and reports saved before retention finishes return `null`. The current cleanup report is saved before retention starts so an interruption during retention does not lose it, then updated once retention finishes. The `cleaned`, `skipped`, `failed`, and `failed_targets` fields continue to describe cleanup targets only.

New reports retain an `Accounted bytes: quarantined=N permanent=N` record. The additive JSON integers `quarantined_bytes` and `permanent_bytes` preserve these values without human-readable rounding; historical or malformed records yield `null`. Nothing-to-clean, minimum-reclaim and minimum-free skips explicitly record zero. These are the existing cleanup estimates credited after successful work: ordinary targets and system package actions use planned sizes, while user-level prune actions use the free-space delta clamped at zero. They do not guarantee physically freed blocks. Interrupted runs include only already-credited work, excluding any unfinished target; retention purge volume is excluded. A cancelled cleanup before work begins preserves the previous report.

## Desktop notification (`--notify`)

With [`--notify`](cli-reference.md) or `LINUX_CLEANER_NOTIFY=1`, a cleanup run sends one desktop notification through `notify-send` (package `libnotify`) once the result is saved. Its body is the result's first line plus the `Reclaimed:`, `Interrupted:` and `Retention failed: true` lines when present. It is marked critical when a target failed, the run hit an operation failure, inline retention failed, or it was interrupted. A cleanup that exits with an error before reporting sends one critical "Cleanup stopped with exit status N before finishing" notice instead. Dry-runs and read-only modes send nothing; without `notify-send` the run continues and prints one warning.

## Prometheus textfile metrics (`LINUX_CLEANER_METRICS_FILE`)

When `LINUX_CLEANER_METRICS_FILE` is set to a literal absolute file path without line feeds, every non-dry-run cleanup atomically writes a Prometheus `node_exporter` textfile alongside `last-report.txt`:

```sh
# Point node_exporter at the directory with:
#   node_exporter --collector.textfile.directory=/var/lib/node_exporter/textfile_collector
LINUX_CLEANER_METRICS_FILE=/var/lib/node_exporter/textfile_collector/linux_cleaner.prom cleaner --clean --force
```

The file emits `# HELP` and `# TYPE` lines for four gauge families derived from the same `Result:` and `Accounted bytes:` values saved in `last-report.txt` (`0` on nothing-to-clean, `--min-reclaim`, and `--min-free` skips):

- `linux_cleaner_last_run_timestamp_seconds`: Unix timestamp of the cleanup exit.
- `linux_cleaner_last_run_success`: `1` on a clean run, or `0` when any target or inline retention failed (`OPERATION_FAILED`), the cleanup was interrupted by a signal, or the cleanup exited non-zero before saving its report (with zero target and byte counts). A failure before the cleaner has loaded its configuration (for example a missing config file or an invalid option) exits without touching the file, so the previous values stay; alert on the age of `linux_cleaner_last_run_timestamp_seconds` as well.
- `linux_cleaner_targets{result="cleaned|skipped|failed"}`: target counts from the result report.
- `linux_cleaner_reclaimed_bytes{kind="quarantined|permanent"}`: accounted bytes quarantined and permanently reclaimed.

A relative path, a path containing a line feed, a symlinked target or parent directory, or a write error prints a warning on stderr without failing the cleanup. Unset or empty `LINUX_CLEANER_METRICS_FILE`, dry-runs, and read-only modes write nothing.

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
