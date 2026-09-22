# Quarantine operations

## On-disk layout

Sessions under `~/.cache/linux-cleaner/quarantine/<timestamp>/` with `quarantine.meta` recording original paths and ownership.

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

If destination exists, restore skips (`Restore with Conflict`). Partial failures preserve session (`Restore with Partial Failure`). Re-run `--list-sessions` before retry.

If restore reports `Unrecorded quarantine payload`, the session contains data not accounted for by its metadata. Inspect the preserved session directly and recover that data manually before purging it; the inventory lists recorded targets only.

### Restore exit / flag matrix

| Case | Test |
|------|------|
| Only Target With Restore Rejected | rejected |
| Only Without Restore Rejected | rejected |

Restore and purge have no dry-run mode. An active explicit `--dry-run` with either is rejected before mutation (`Dry Run With Restore Rejected`, `Dry Run With Purge Rejected`). Use `--list-sessions` for read-only inventory. A later `--clean`, `--interactive`, or `--force` overrides an earlier `--dry-run`.

## Purge reference

> **WARNING:** Supported predefined `action:*` handlers (for example, `action:apt_clean`) bypass quarantine and delete in place. There is no generic `action:custom`; unknown actions are rejected. Review `cleaner.conf` before any automated `--force` run.

Selectors: `latest`, `all`, timestamp, `older-than:DAYS`. A named timestamp must be an immediate child directory name — no `/`, `.`, or `..` (`Purge Invalid Session`).

Interactive: run without `--force` to see `This cannot be undone`; declining prints `No sessions were purged` (`Purge Preview Names Targets`, `Purge Declined Keeps Sessions`).

Automated checklist: cron retention uses `--force` + `older-than:DAYS` only; never schedule `purge-sessions all --force`.

Troubleshooting: missing timestamp exits 1 (`Purge Missing Session`); distinguish from retention no-match success.

## Incident decision / triage

```
file missing after cron? → list-sessions → restore latest [--only PATH]
quarantine disk full? → older-than retention or selective purge latest
wrong target cleaned? → selective restore --only
retention too aggressive? → increase DAYS; restore from remaining sessions if any
```

## Test contract appendix

Purge Older-Than Retention, Purge Older-Than No Match, Purge Older-Than Invalid Days, Restore Only One Target, Full Restore After Selective Restore, Restore with Conflict, Restore with Partial Failure, Failed Quarantine Move Not Recorded, Trash Action Warning, Purge Missing Session, Only Target With Restore Rejected, Only Without Restore Rejected, Only Target With List Targets Rejected, Only Target With List Sessions Rejected, Only Target With Purge Rejected.

## Maintainer sign-off

- [ ] Examples use supported flags only
- [ ] older-than cron no-match exit 0 documented
- [ ] action:* irreversibility WARNING present
- [ ] `make check` before merge
