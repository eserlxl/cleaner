# Quarantine operations

## On-disk layout

Sessions under `~/.cache/linux-cleaner/quarantine/<timestamp>/` with `quarantine.meta` recording original paths and ownership. Each session directory is created with mode `0700` (and any missing parent directories under `~/.cache/linux-cleaner/quarantine` are created `0700` when created by the tool).

Restore trusts this metadata for source and destination paths, privilege use, and ownership. Keep the quarantine tree private and restore only sessions you trust; metadata is not authenticated or comprehensively validated against tampering.

## Session inventory workflow

`cleaner --list-sessions` lists timestamp, size, and per-target paths (tests: `List Sessions`, `List Sessions Empty`, `List Sessions Shows Contents`).

## Disk growth primer

Each `--trash` clean creates a new session. Bound growth: `estimated_disk = sessions × average_session_size`. Pair daily trash with `older-than` retention (see [RUNBOOK.md](../RUNBOOK.md)).

## Test contract cross-reference

| Behavior | Test case |
|----------|-----------|
| List sessions | List Sessions |
| Empty state | List Sessions Empty |
| Content listing | List Sessions Shows Contents |

## Retention (older-than)

Session age uses the quarantine session directory mtime (`find -mtime +DAYS`), not per-file ages inside the session.

### Exit-code automation matrix

| Scenario | Exit |
|----------|------|
| No match (`Purge Older-Than No Match`) | 0 |
| Successful selective purge | 0 |
| Invalid day count | 1 |
| Missing quarantine base (`Purge Missing Base`) | 1 |

Message on no match includes: `No quarantine sessions older than`

### Retention sizing examples

1. Daily trash + weekly `older-than:30` (see RUNBOOK cron blocks).
2. Aggressive `older-than:7` on small disks.
3. Monitoring-only: JSON dry-run cron without deletion.

### Invalid selector

`older-than:abc` is a hard error (`Purge Older-Than Invalid Days`). Check cron logs for `Invalid day count`.

## Restore workflows

Full restore: `--list-sessions` → `--restore latest|TIMESTAMP`. Restore does not use `--force` for overwrite; conflicts skip.

A named `SESSION` (anything other than `latest`) must be an immediate child of the quarantine base: path separators and `.`/`..` are rejected (`Restore Invalid Session`). The same rule applies to named `--purge-sessions` arguments (`Purge Invalid Session`).

Selective restore: `--restore latest --only PATTERN` (`Restore Only One Target`, `Full Restore After Selective Restore`).

### Conflict and partial failure

If destination exists, restore skips (`Restore with Conflict`). If the original path (full or aged) or any existing intermediate directory component up to the destination file's parent (aged) is a symlink, restore treats it as a conflict without following the link (`Restore Aged Subdir Symlink Conflict`, `Restore Aged Original Path Symlink Conflict`, `Restore Full Original Path Symlink Conflict`). Partial failures preserve session (`Restore with Partial Failure`). Re-run `--list-sessions` before retry. A retry after an interrupted restore finishes the job: a whole-target record whose payload is gone while its original path is back is treated as already restored and dropped (`Restore Retry After Interrupted Restore`); a payload missing with the original also absent still fails (`Restore Missing Source Still Fails`). A cleanup killed during an aged quarantine already wrote that target's record, so its moved files restore normally (`Trash Aged Interrupted Keeps Metadata`).

If restore reports `Unrecorded quarantine payload`, the session contains data not accounted for by its metadata. Inspect the preserved session directly and recover that data manually before purging it; the inventory lists recorded targets only.

### Restore exit / flag matrix

| Flag combination | Exit | Test |
|------------------|------|------|
| `--restore SESSION --only-target PATTERN` | 1 | Only Target With Restore Rejected |
| `--only PATTERN` without `--restore` | 1 | Only Without Restore Rejected |
| `--restore SESSION --dry-run` | 1 | Dry Run With Restore Rejected |
| `--restore SESSION --json` | 1 | JSON With Restore Rejected |
| `--restore SESSION` while another cleanup, restore or purge holds `~/.cache/linux-cleaner/cleaner.lock` | 1 | Concurrent Run Lock Restore |

Restore and purge have no dry-run mode. An active explicit `--dry-run` with either is rejected before mutation (`Dry Run With Restore Rejected`, `Dry Run With Purge Rejected`). Use `--list-sessions` for read-only inventory. A later `--clean`, `--interactive`, or `--force` overrides an earlier `--dry-run`.

## Purge reference

> **WARNING:** Supported predefined `action:*` handlers (for example, `action:apt_clean`) bypass quarantine and delete in place. There is no generic `action:custom`; unknown actions are rejected. Review `cleaner.conf` before any automated `--force` run.

Selectors: `latest`, `all`, timestamp, `older-than:DAYS`, `max-size:SIZE` (keep the newest sessions within SIZE; `Purge Sessions Max Size Keeps Newest`). A named timestamp must be an immediate child directory name — no `/`, `.`, or `..` (`Purge Invalid Session`).

Interactive: run without `--force` to see `This cannot be undone`; declining prints `No sessions were purged` (`Purge Preview Names Targets`, `Purge Declined Keeps Sessions`).

Automated checklist: cron retention uses `--force` + `older-than:DAYS` or `max-size:SIZE` only (or `--trash-keep-days` on the cleanup run); never schedule `purge-sessions all --force`.

Troubleshooting: missing timestamp exits 1 (`Purge Missing Session`); distinguish from retention no-match success.

## Incident decision / triage

```
file missing after cron? → list-sessions → restore latest [--only PATH]
quarantine disk full? → older-than retention, purge-sessions max-size:SIZE budget, or selective purge latest
cross-filesystem target refused? → free space in HOME, or clean it without --trash
wrong target cleaned? → selective restore --only
retention too aggressive? → increase DAYS; restore from remaining sessions if any
```

## Test contract appendix

Purge Older-Than Retention, Purge Older-Than No Match, Purge Older-Than Invalid Days, Restore Only One Target, Full Restore After Selective Restore, Restore with Conflict, Restore with Partial Failure, Failed Quarantine Move Not Recorded, Trash Action Warning, Purge Missing Session, Only Target With Restore Rejected, Only Without Restore Rejected, Only Target With List Targets Rejected, Only Target With List Sessions Rejected, Only Target With Purge Rejected, Restore Retry After Interrupted Restore, Restore Missing Source Still Fails, Trash Aged Interrupted Keeps Metadata, Concurrent Run Lock Restore, Concurrent Run Lock Purge, Purge Sessions Max Size Keeps Newest, Trash Keep Days Purges Old Sessions, Trash Cross Filesystem Space Guard.

## Maintainer sign-off

- [ ] Examples use supported flags only
- [ ] older-than cron no-match exit 0 documented
- [ ] action:* irreversibility WARNING present
- [ ] `make check` before merge
