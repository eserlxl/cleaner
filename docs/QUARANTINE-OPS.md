# Quarantine operations

## On-disk layout

Sessions under `~/.cache/linux-cleaner/quarantine/<timestamp>/` with `quarantine.meta` recording original paths and ownership. Each session directory is created with mode `0700` (and any missing parent directories under `~/.cache/linux-cleaner/quarantine` are created `0700` when created by the tool). A symlink at that quarantine directory is refused: trash cleanup, `--list-sessions`, `--restore`, and `--purge-sessions` exit non-zero and move nothing, and `--doctor` prints a warning.

Restore trusts this metadata for source and destination paths, privilege use, and ownership within a private `0700` quarantine tree owned by the user. Before probing paths or invoking `sudo`, `--restore` (and `--restore ... --dry-run`) structurally validates each selected record and refuses it when `RELATIVE_PATH` is empty, starts with `/`, or contains a `..` path component (`..`, `../...`, `.../..`, or `.../../...`); `ORIGINAL_PATH` does not start with `/` or contains a `..` path component; `USE_SUDO` is neither `true` nor `false`; or a non-empty `UID` or `GID` is not all ASCII digits (a real restore logs `outcome=failed`, keeps the payload and `quarantine.meta` entry, and exits `1`; a preview prints `invalid record`). Keep the quarantine tree private and restore only sessions you trust; metadata is not authenticated or tamper-proof. Which operations may use `sudo`, and what an unattended restore does without it, is in the [privilege matrix](safety.md#privilege-matrix).

An aged record whose files have finished moving back is atomically changed to
`aged-restored` before empty staging directories are removed, retaining the same
six fields. A retry uses this internal checkpoint to remove only empty directories;
remaining files, FIFOs, symlinks, or other payload keep the record for recovery.
Human and JSON inventories still show this layout as `aged`. Older cleaner versions
do not understand the checkpoint; finish recovery with the version that created it.
Metadata rewrites use private scratch files beside the session, outside its payload
directory. Process interruption preserves a complete old or new metadata file;
this is not a power-loss durability guarantee. An interrupted rewrite can leave a
`.restore-meta.*` scratch file in the quarantine base; it is not session payload.

## Session inventory workflow

`cleaner --list-sessions` lists timestamp, size, and per-target paths (tests: `List Sessions`, `List Sessions Empty`, `List Sessions Shows Contents`).

## Disk growth primer

A `--trash` run creates a session only when a target is actually quarantined. An action-only or nothing-to-clean run creates none, so `--restore latest` can select an older session; check `--list-sessions` first. Bound growth: `estimated_disk = sessions × average_session_size`. Pair daily trash with `older-than` retention (see [RUNBOOK.md](../RUNBOOK.md)).

## Test contract cross-reference

| Behavior | Test case |
|----------|-----------|
| List sessions | List Sessions |
| Empty state | List Sessions Empty |
| Content listing | List Sessions Shows Contents |

## Retention (older-than)

Session age uses the quarantine session directory mtime (`find -mtime +DAYS`), not per-file ages inside the session. A partial or failed restore that keeps the session preserves its original directory mtime, so the remaining quarantined targets still expire on schedule.

### Holding a session during an incident

Because a kept session keeps its original age, the daily `--trash-keep-days` retention can delete the remaining recovery data while you are still resolving restore conflicts. Protect that one session instead of disabling retention:

```
cleaner --hold-session 2026-01-02_03-04-05     # or: cleaner --hold-session latest
cleaner --list-sessions                        # the held session's line ends with "held"
cleaner --release-session 2026-01-02_03-04-05  # normal expiry resumes on the original mtime
```

A hold writes a private `.hold` marker into the session under the mutation lock and leaves the session mtime unchanged. Every bulk purge selector (`all`, `older-than:DAYS`, `max-size:SIZE`, `keep-latest:N`) and inline `--trash-keep-days` retention skip a held session with a `Skipping held session <name>` note, even with `--force`; a held session still counts toward the `max-size` budget and the `keep-latest` count, so a hold only ever makes a purge delete less. Purging a held session by name or as `latest` exits 1 instead of picking another session. A complete `--restore` removes the marker together with the session; a partial restore keeps both (tests: `Session Hold`).

### Exit-code automation matrix

| Scenario | Exit |
|----------|------|
| No match (`Purge Older-Than No Match`) | 0 |
| Successful selective purge | 0 |
| Invalid day count | 1 |
| `older-than:DAYS` or `max-size:SIZE` without a quarantine directory (`Retention Purge Without Quarantine Dir`) | 0 |
| `latest` or a timestamp without a quarantine directory (`Purge Missing Base`) | 1 |

Message on no match includes: `No quarantine sessions older than`

### Retention sizing examples

1. Daily trash + weekly `older-than:30` (see RUNBOOK cron blocks).
2. Aggressive `older-than:7` on small disks.
3. Monitoring-only: JSON dry-run cron without deletion.

### Invalid selector

`older-than:abc` is a hard error (`Purge Older-Than Invalid Days`). Check cron logs for `Invalid day count`.

## Restore workflows

Full restore: `--list-sessions` → `--restore latest|TIMESTAMP`. Restore does not use `--force` for overwrite; conflicts skip.

Preview first with `cleaner --restore latest --dry-run`, optionally adding `--only`
or `--only-exact`. Each selected record prints `would restore`, `conflict`,
`already restored`, `missing`, `unknown type`, or `invalid record` (the last two are
records the real restore skips as failed), followed by two spaces and its original path.
An aged record reports `conflict` if any destination file or symlinked parent
conflicts; other files in that record may still be recoverable in a real restore.
The preview ends with `Dry-run: nothing restored.` and exits `0` even when records
conflict or payload is missing. An unmatched selector still exits `1`.
It does not invoke sudo, move files, write logs or metadata, reset session mtime,
or create/acquire a lock. Probes use the current user's access and do not guarantee
permissions or free space for a later restore (`Restore Preview` tests).

A `--trash` cleanup that quarantined something ends with `Undo: cleaner --restore <session>`, naming its own session (`Trash Prints Undo Command`). The line is suppressed by `--quiet` and omitted from `--report` and notifications.

Before a cross-filesystem restore, the destination must have enough free space
for the full payload or, for an aged record, the entire staging directory before
any files move. Otherwise restore prints `Error: Not enough free space to restore
'<original_path>' (needs X, Y free); kept in quarantine.`, exits `1`, and keeps that
record and its payload for a retry; other records can still restore. Same-filesystem
moves need no copy space. An unreadable device or free-space figure falls back to
trying the move (`Restore Full Cross Filesystem Space Guard`,
`Restore Aged Cross Filesystem Space Guard`, and their `Fits` cases).

A named `SESSION` (anything other than `latest`) must be an immediate child of the quarantine base: path separators and `.`/`..` are rejected (`Restore Invalid Session`). The same rule applies to named `--purge-sessions` arguments (`Purge Invalid Session`).

Selective substring restore: `--restore latest --only PATTERN` (`Restore Only One Target`, `Full Restore After Selective Restore`).

To recover `/cache` without also recovering `/cache-copy`, copy the exact original
path from `--list-sessions` or JSON `sessions[].targets[].path`:

```sh
cleaner --restore latest --only-exact "/absolute/path/cache"
```

`--only-exact` compares its nonempty argument byte-for-byte with the trimmed stored
path shown by inventory, selecting every record with that exact path. It does not trim, expand, normalize, require an absolute
or existing path, or interpret wildcards, descendants or comma lists. Unselected
payload and metadata stay available for a later full restore; no match exits `1`
without changing payload or metadata. Both selectors require `--restore`, cannot
be mixed in either order, and use the last value when the same option repeats.
There is no environment mirror for `--only-exact`.

### Conflict and partial failure

A full record skips when the destination exists (`Restore with Conflict`). An aged record merges into an existing directory, skipping conflicting files. If the original path (full or aged) or any existing intermediate directory component up to the destination file's parent (aged) is a symlink, restore treats it as a conflict without following the link (`Restore Aged Subdir Symlink Conflict`, `Restore Aged Original Path Symlink Conflict`, `Restore Full Original Path Symlink Conflict`). Partial failures preserve session (`Restore with Partial Failure`). Re-run `--list-sessions` before retry. A retry after an interrupted restore finishes the job: a whole-target record whose payload is gone while its original path is back is treated as already restored and dropped (`Restore Retry After Interrupted Restore`); a payload missing with the original also absent still fails (`Restore Missing Source Still Fails`). A cleanup killed during an aged quarantine already wrote that target's record, so its moved files restore normally (`Trash Aged Interrupted Keeps Metadata`).

If restore reports `Unrecorded quarantine payload`, the session contains data not accounted for by its metadata. Inspect the preserved session directly and recover that data manually before purging it; inventory lists recorded targets and reports `unrecorded_entry_count` (a positive count also produces a human warning).

Inventory counts immediate session entries, excluding exactly `quarantine.meta` and `.hold`,
that are not equal to a trimmed recorded relative path or its literal first path
component. Hidden files, empty directories, FIFOs and symlinks count without
following links. Missing metadata accounts for no entries; `aged-restored` records
still account for their staging root. Referenced-root descendants and aliases are
not inspected or normalized. A zero count is not proof of metadata integrity,
recoverability or safe purge. A positive count does not prevent a confirmed or
forced purge. Failed metadata reads or entry enumeration fail inventory and stop
purge before confirmation/deletion, including inline retention.

### Restore exit / flag matrix

| Flag combination | Exit | Test |
|------------------|------|------|
| `--restore SESSION --only-target PATTERN` | 1 | Only Target With Restore Rejected |
| `--only PATTERN` without `--restore` | 1 | Only Without Restore Rejected |
| `--restore SESSION --dry-run` | 0 | Dry Run With Restore Preview |
| `--purge-sessions SESSION --dry-run` | 0 | Dry Run With Purge Preview |
| `--restore SESSION --json` | 1 | JSON With Restore Rejected |
| `--restore SESSION` with default `--lock-wait 0` while another cleanup, restore or purge holds `~/.cache/linux-cleaner/cleaner.lock` | 1 | Concurrent Run Lock Restore |

Mutating restore and purge share the cleanup lock. `--lock-wait SECONDS` or
`LINUX_CLEANER_LOCK_WAIT` may opt in to bounded waiting (`0..2147483647` literal
decimal seconds, leading zeros allowed; last CLI overrides; unset/empty env is
zero). Zero keeps fail-fast behavior and optional `flock`; a positive wait requires
`flock` and exits `1` on acquisition failure before session/report/log effects.
Restore/purge previews and read-only inventory never lock or wait. Lock-file opening can precede timeout.

Restore and purge support an active explicit `--dry-run` preview; `--hold-session` and `--release-session` still reject it. Use `--list-sessions` for read-only inventory. A later `--clean`, `--interactive`, or `--force` overrides an earlier `--dry-run`, including for restore and purge (`Force Overrides Earlier Dry Run for Purge`).

## Purge reference

> **WARNING:** Supported predefined `action:*` handlers (for example, `action:apt_clean`) bypass quarantine and delete in place. There is no generic `action:custom`; unknown actions are rejected. Review `cleaner.conf` before any automated `--force` run.

Selectors: `latest`, `all`, timestamp, `older-than:DAYS`, `max-size:SIZE` (keep the newest sessions within SIZE; `Purge Sessions Max Size Keeps Newest`), `keep-latest:N` (keep the newest `N` sessions, N >= 1 (use all to purge everything); `Purge Sessions Keep Latest Keeps Newest`). A named timestamp must be an immediate child directory name — no `/`, `.`, or `..` (`Purge Invalid Session`).

Before scheduling retention, run, for example, `cleaner --purge-sessions max-size:5G --dry-run` or `cleaner --purge-sessions keep-latest:5 --dry-run`. The text preview lists exactly the selected unheld sessions with names and sizes under `Would purge`, plus notes for held sessions it skipped. It exits `0` without confirmation, deletion, locking, or log/report writes, even with inherited `LINUX_CLEANER_FORCE`. Held sessions still count toward size/count limits; a held named or `latest` session remains an error rather than selecting another session. JSON is not accepted for this preview (`Purge Preview`).

Interactive: run without `--force` to see `This cannot be undone`; declining prints `No sessions were purged` (`Purge Preview Names Targets`, `Purge Declined Keeps Sessions`).

Automated checklist: cron retention uses `--force` + `older-than:DAYS`, `max-size:SIZE`, or `keep-latest:N` only (or `--trash-keep-days` on the cleanup run); never schedule `purge-sessions all --force`.

Troubleshooting: missing timestamp exits 1 (`Purge Missing Session`); distinguish from retention no-match success. A held session is skipped by every selector and refused by name or `latest`; release it with `--release-session` first (`Session Hold`).

## Incident decision / triage

```
file missing after cron? → list-sessions → restore latest [--only PATH]
quarantine disk full? → older-than retention, purge-sessions max-size:SIZE budget, or selective purge latest
cross-filesystem target refused? → free space in HOME, or clean it without --trash
wrong target cleaned? → selective restore --only
retention too aggressive? → increase DAYS; restore from remaining sessions if any
still resolving a partial restore? → hold-session SESSION; release-session SESSION when done
```

## Test contract appendix

Purge Older-Than Retention, Purge Older-Than No Match, Purge Older-Than Invalid Days, Restore Only One Target, Full Restore After Selective Restore, Restore with Conflict, Restore with Partial Failure, Failed Quarantine Move Not Recorded, Trash Action Warning, Purge Missing Session, Only Target With Restore Rejected, Only Without Restore Rejected, Only Target With List Targets, Only Target With List Sessions Rejected, Only Target With Purge Rejected, Restore Retry After Interrupted Restore, Restore Missing Source Still Fails, Trash Aged Interrupted Keeps Metadata, Concurrent Run Lock Restore, Concurrent Run Lock Purge, Purge Sessions Max Size Keeps Newest, Trash Keep Days Purges Old Sessions, Trash Cross Filesystem Space Guard.

## Maintainer sign-off

- [ ] Examples use supported flags only
- [ ] older-than cron no-match exit 0 documented
- [ ] action:* irreversibility WARNING present
- [ ] `make check` before merge
