# CLI, environment, and JSON governance

## 1. New CLI flag workflow

1. Add flag to `show_usage` / argument parser in `cleaner.sh`.
2. Mirror in `cleaner.1` OPTIONS section.
3. Document in [cli-reference.md](cli-reference.md).
4. Add `run_test_case` for behavior and mutex rules.
5. Extend drift guards: `Man Page Option Consistency`, env mirror block if applicable.
6. Classify SemVer via [contract-semver-taxonomy.md](contract-semver-taxonomy.md).

## 2. Environment mirror naming and precedence

- Mirrors use `LINUX_CLEANER_*` prefix (see `docs/env-automation-contract.md`).
- Truthy values: `1`, `true`, `yes` (documented per variable).
- **CLI overrides value mirrors** (config, log, risk, exclude, target filters, min reclaim, min free, min age, retention days, lock wait) when both are set. On/off mirrors can only enable a behavior from the CLI; disable one by setting it to a non-truthy value or unsetting it.
- `LINUX_CLEANER_YES_DANGER` stays off in default examples. `LINUX_CLEANER_ALLOW_OUTSIDE_HOME` and `--allow-outside-home` are deprecated no-ops (one warning per run); targets outside `$HOME` are always allowed.
- `--only-path` overrides `LINUX_CLEANER_ONLY_PATH` with last-occurrence precedence. Unset or empty means no scope; the effective value must be an existing absolute literal path without line feeds. No additional JSON fields.
- `--exclude-path` overrides `LINUX_CLEANER_EXCLUDE_PATH` with last-occurrence precedence. Unset or empty means no exclusion; the effective value must be an existing absolute literal path without line feeds. No additional JSON fields.
- `--lock-wait` overrides `LINUX_CLEANER_LOCK_WAIT` with last-occurrence precedence; unset/empty environment means zero. Validate the effective decimal `0..2147483647` after overrides and normalize leading zeros before use. No mode mutex or JSON key; valid settings do not lock nonlocking modes.
- JSON target `status` no longer emits `rejected`. Older clients that accept that value keep working; current runs use the other statuses (`found`, `skipped`, and the rest).

## 3. JSON additive vs breaking changes

| Change | Bump |
|--------|------|
| Add new optional JSON key | MINOR |
| Rename or remove existing key | MAJOR |
| Change key semantics | MAJOR unless purely additive |

Session JSON adds integer `unrecorded_entry_count`, including zero. It observes
only immediate entries absent from literal recorded-root accounting, not metadata
integrity or recoverability. All session sizes and counts are checked before JSON
output; failed metadata reads or enumeration return nonzero with empty JSON.

Session JSON adds boolean `held` (MINOR, additive): `true` when the session holds a
`.hold` entry written by `--hold-session`, otherwise `false`. The marker is never
counted in `unrecorded_entry_count`.

## 4. Mutex flags

Documented mutual exclusions (enforced in code):

- CLI-only `--exit-code` vs `--clean`, `--force`, `--interactive` (even with a later `--dry-run`), `--restore`, `--purge-sessions`, `--list-sessions`, `--hold-session`, `--release-session`, `--list-targets`, `--check-config`, `--report`, `--init-config`, `--doctor`. No environment mirror. Text/JSON cleanup previews return `2` exactly when `would_skip` is `null`, otherwise `0`; errors remain `1`.
- `--only-target` vs `--restore`, `--purge-sessions`, `--list-sessions`, `--hold-session`, `--release-session`, `--check-config`, `--report`, `--init-config`, `--doctor`
- `--exclude-target` vs `--restore`, `--purge-sessions`, `--list-sessions`, `--hold-session`, `--release-session`, `--check-config`, `--report`, `--init-config`, `--doctor`
- `--only-path` vs `--restore`, `--purge-sessions`, `--list-sessions`, `--hold-session`, `--release-session`, `--check-config`, `--report`, `--init-config`, `--doctor`, `--trash-keep-days` (including its environment mirror)
- `--exclude-path` vs `--restore`, `--purge-sessions`, `--list-sessions`, `--hold-session`, `--release-session`, `--check-config`, `--report`, `--init-config`, `--doctor`
- `--min-reclaim` vs `--restore`, `--purge-sessions`, `--list-sessions`, `--hold-session`, `--release-session`, `--list-targets`, `--check-config`, `--report`, `--init-config`, `--doctor`
- `--min-free` vs `--restore`, `--purge-sessions`, `--list-sessions`, `--hold-session`, `--release-session`, `--list-targets`, `--check-config`, `--report`, `--init-config`, `--doctor`
- `--min-age` vs `--restore`, `--purge-sessions`, `--list-sessions`, `--hold-session`, `--release-session`, `--list-targets`, `--check-config`, `--report`, `--init-config`, `--doctor`
- `--trash-keep-days` vs `--restore`, `--purge-sessions`, `--list-sessions`, `--hold-session`, `--release-session`, `--list-targets`, `--check-config`, `--report`, `--init-config`, `--doctor`, `--only-path`
- `--notify` vs `--restore`, `--purge-sessions`, `--list-sessions`, `--hold-session`, `--release-session`, `--list-targets`, `--check-config`, `--report`, `--init-config`, `--doctor`
- `--json` is valid with `--dry-run` (cleanup summary), `--list-targets`, `--list-sessions`, or `--report` (saved report summary; not `--init-config` or `--doctor`)
- `--only` and CLI-only `--only-exact` require `--restore`, cannot be mixed in either order, and use last-occurrence precedence when the same selector repeats. Exact matching uses the literal inventory path without expansion or normalization; no environment mirror or JSON fields are added.
- `--only-target` and `--exclude-target` vs `--check-config` and `--doctor`
- `--list-targets` vs `--restore`, `--purge-sessions`, `--list-sessions`, `--hold-session`, `--release-session`, `--check-config`, `--report`, `--init-config`, `--doctor`
- `--check-config` vs `--restore`, `--purge-sessions`, `--list-sessions`, `--hold-session`, `--release-session`, `--list-targets`, `--report`, `--init-config`, `--doctor`
- `--report` vs `--restore`, `--purge-sessions`, `--list-sessions`, `--hold-session`, `--release-session`, `--list-targets`, `--check-config`, `--init-config`, `--doctor`
- `--init-config` vs `--restore`, `--purge-sessions`, `--list-sessions`, `--hold-session`, `--release-session`, `--list-targets`, `--check-config`, `--report`, `--doctor`, `--only-target`, `--exclude-target`, `--only-path`, `--exclude-path`, `--min-reclaim`, `--min-free`, `--min-age`, `--action-timeout`, `--trash-keep-days`, `--notify`, `--fail-fast`, `--json`
- `--doctor` vs `--restore`, `--purge-sessions`, `--list-sessions`, `--hold-session`, `--release-session`, `--list-targets`, `--check-config`, `--report`, `--init-config`, `--only-target`, `--exclude-target`, `--only-path`, `--exclude-path`, `--min-reclaim`, `--min-free`, `--min-age`, `--action-timeout`, `--trash-keep-days`, `--notify`, `--fail-fast`, `--json`
- `--action-timeout` and `--fail-fast` vs `--restore`, `--purge-sessions`, `--list-sessions`, `--hold-session`, `--release-session`, `--list-targets`, `--check-config`, `--report`, `--init-config`, `--doctor`
- `--restore` vs `--purge-sessions`, `--list-sessions`, `--hold-session`, `--release-session`, `--list-targets`, `--check-config`, `--report`, `--init-config`, `--doctor`
- `--purge-sessions` vs `--restore`, `--list-sessions`, `--hold-session`, `--release-session`, `--list-targets`, `--check-config`, `--report`, `--init-config`, `--doctor`
- `--list-sessions` vs `--restore`, `--purge-sessions`, `--hold-session`, `--release-session`, `--list-targets`, `--check-config`, `--report`, `--init-config`, `--doctor`
- `--hold-session` vs `--release-session`, `--restore`, `--purge-sessions`, `--list-sessions`, `--list-targets`, `--check-config`, `--report`, `--init-config`, `--doctor`, `--only-target`, `--exclude-target`, `--only-path`, `--exclude-path`, `--min-reclaim`, `--min-free`, `--min-age`, `--action-timeout`, `--trash-keep-days`, `--notify`, `--fail-fast`, `--show-matches`, `--exit-code`, `--dry-run`, `--clean`, `--interactive`, `--json`
- `--release-session` vs `--hold-session`, `--restore`, `--purge-sessions`, `--list-sessions`, `--list-targets`, `--check-config`, `--report`, `--init-config`, `--doctor`, `--only-target`, `--exclude-target`, `--only-path`, `--exclude-path`, `--min-reclaim`, `--min-free`, `--min-age`, `--action-timeout`, `--trash-keep-days`, `--notify`, `--fail-fast`, `--show-matches`, `--exit-code`, `--dry-run`, `--clean`, `--interactive`, `--json`

See `test_cleaner.sh` mutex rejection cases.

## 5. Required drift tests to extend

When adding CLI/env/JSON surface:

- `Man Page Option Consistency`
- Environment mirror block (`LINUX_CLEANER_*` tests)
- `Bash Completion Drift and Functional Check` (add the flag to `completions/cleaner.bash`, `completions/_cleaner` and `completions/cleaner.fish`)
- JSON output cases (`JSON Dry Run`, `List Targets JSON`, `List Sessions JSON`, `List Sessions JSON Empty`, `Report JSON After Cleanup`, `Report JSON After Interrupted Cleanup`, `Report JSON Without Report`)
- `List Targets JSON` must assert additive inventory keys (`description`, `min_age_days`, `check_processes`, `custom_action`) when those fields ship
