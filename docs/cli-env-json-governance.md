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
- Truthy values: `1`, `true`, `TRUE`, `yes`, `YES` (documented per variable).
- **CLI overrides value mirrors** (config, log, log max size, risk, exclude, exclude from, target filters, only/exclude path, min reclaim, min free, min free path, min age, action timeout, trash keep days, trash max size, lock wait) when both are set. On/off mirrors can only enable a behavior from the CLI; disable one by setting it to a non-truthy value or unsetting it.
- `LINUX_CLEANER_YES_DANGER` stays off in default examples. `LINUX_CLEANER_ALLOW_OUTSIDE_HOME` and `--allow-outside-home` are deprecated no-ops (one warning per run); targets outside `$HOME` are always allowed.
- `--only-target-exact` overrides `LINUX_CLEANER_ONLY_TARGET_EXACT` (with last-occurrence precedence) and clears inherited `LINUX_CLEANER_ONLY_TARGET`, matching literal target `NAME` without comma splitting or globbing; CLI `--only-target` correspondingly clears inherited `LINUX_CLEANER_ONLY_TARGET_EXACT`, while combining both environment mirrors or combining both CLI flags fails validation. No additional JSON fields.
- `--exclude-target-exact` overrides `LINUX_CLEANER_EXCLUDE_TARGET_EXACT` (with last-occurrence precedence) and clears inherited `LINUX_CLEANER_EXCLUDE_TARGET`, skipping literal target `NAME` without comma splitting or globbing; CLI `--exclude-target` correspondingly clears inherited `LINUX_CLEANER_EXCLUDE_TARGET_EXACT`, while combining both environment mirrors or combining both CLI flags fails validation. No additional JSON fields.
- `--only-path` overrides `LINUX_CLEANER_ONLY_PATH` with last-occurrence precedence. Unset or empty means no scope; the effective value must be an existing absolute literal path without line feeds. No additional JSON fields.
- `--exclude-path` overrides `LINUX_CLEANER_EXCLUDE_PATH` with last-occurrence precedence. Unset or empty means no exclusion; the effective value must be an existing absolute literal path without line feeds. No additional JSON fields.
- `--exclude-from` overrides `LINUX_CLEANER_EXCLUDE_FROM` with last-occurrence precedence. Unset or empty env means no exclusion file (empty CLI values are refused); on cleanup runs, non-regular, unreadable, or CR-containing files fail pre-lock while non-cleanup modes ignore inherited `LINUX_CLEANER_EXCLUDE_FROM`. No additional JSON fields.
- `--lock-wait` overrides `LINUX_CLEANER_LOCK_WAIT` with last-occurrence precedence; unset/empty environment means zero. Validate the effective decimal `0..2147483647` after overrides and normalize leading zeros before use. No mode mutex or JSON key; valid settings do not lock nonlocking modes.
- `--trash-max-size` overrides `LINUX_CLEANER_TRASH_MAX_SIZE` with last-occurrence precedence (1024-based size grammar; `apply_trash_retention` runs it after any `--trash-keep-days` pass). Enforces the same non-cleanup/non-`--only-path` mode exclusions as `--trash-keep-days`.
- `--log-max-size` overrides `LINUX_CLEANER_LOG_MAX_SIZE` with last-occurrence precedence (`0` disables rotation) and requires `--log` or `LINUX_CLEANER_LOG`.
- `--no-sudo` and truthy `LINUX_CLEANER_NO_SUDO` (`1`, `true`, `TRUE`, `yes`, `YES`) suppress all `sudo` probes and prompts across cleanup, dry-run previews, and `--restore` (and replay `--no-sudo` in `Next:`). CLI `--no-sudo` enforces mode exclusions, while unrelated modes ignore inherited `LINUX_CLEANER_NO_SUDO`.
- JSON target `status` no longer emits `rejected`. Older clients that accept that value keep working; current runs use the other statuses (`found`, `skipped`, and the rest).
- `--check-health SECONDS` is CLI-only and requires `--report`; no environment mirror. Decimal `0..9223372036854775807` seconds, normalized leading zeros, last occurrence wins. It adds exit-status semantics without changing text output or the report JSON schema: `0` only for a recent successful saved result (skips succeed), otherwise `1` with one reason line on stderr. Age uses file mtime, independently of timers; symlinks, unreadable/missing reports, unknown results, failed targets, interruptions, retention failures, and unavailable age information fail.

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

- `--check-health` requires `--report` and inherits all its exclusions: `--restore`, `--purge-sessions`, `--list-sessions`, `--hold-session`, `--release-session`, `--list-targets`, `--check-config`, `--init-config`, `--init-env`, `--doctor`, cleanup filters/modifiers, `--show-matches`, and `--exit-code`. It works with text and `--json` reports.
- CLI-only `--exit-code` vs `--clean`, `--force`, `--interactive` (even with a later `--dry-run`), `--restore`, `--purge-sessions`, `--list-sessions`, `--hold-session`, `--release-session`, `--list-targets`, `--check-config`, `--report`, `--check-health`, `--init-config`, `--init-env`, `--doctor`. No environment mirror. Text/JSON cleanup previews return `2` exactly when `would_skip` is `null`, otherwise `0`; errors remain `1`.
- `--only-target` vs `--only-target-exact`, `--restore`, `--purge-sessions`, `--list-sessions`, `--hold-session`, `--release-session`, `--check-config`, `--report`, `--check-health`, `--init-config`, `--init-env`, `--doctor`
- `--only-target-exact` vs `--only-target`, `--restore`, `--purge-sessions`, `--list-sessions`, `--hold-session`, `--release-session`, `--check-config`, `--report`, `--check-health`, `--init-config`, `--init-env`, `--doctor`
- `--exclude-target` vs `--exclude-target-exact`, `--restore`, `--purge-sessions`, `--list-sessions`, `--hold-session`, `--release-session`, `--check-config`, `--report`, `--check-health`, `--init-config`, `--init-env`, `--doctor`
- `--exclude-target-exact` vs `--exclude-target`, `--restore`, `--purge-sessions`, `--list-sessions`, `--hold-session`, `--release-session`, `--check-config`, `--report`, `--check-health`, `--init-config`, `--init-env`, `--doctor`
- `--only-path` vs `--restore`, `--purge-sessions`, `--list-sessions`, `--hold-session`, `--release-session`, `--check-config`, `--report`, `--check-health`, `--init-config`, `--init-env`, `--doctor`, `--trash-keep-days`, `--trash-max-size` (including their environment mirrors)
- `--exclude-path` vs `--restore`, `--purge-sessions`, `--list-sessions`, `--hold-session`, `--release-session`, `--check-config`, `--report`, `--check-health`, `--init-config`, `--init-env`, `--doctor`
- `--exclude-from` vs `--restore`, `--purge-sessions`, `--list-sessions`, `--hold-session`, `--release-session`, `--list-targets`, `--check-config`, `--report`, `--check-health`, `--init-config`, `--init-env`, `--doctor`
- `--skip-actions` vs `--restore`, `--purge-sessions`, `--list-sessions`, `--hold-session`, `--release-session`, `--check-config`, `--report`, `--check-health`, `--init-config`, `--init-env`, `--doctor`
- `--min-reclaim` vs `--restore`, `--purge-sessions`, `--list-sessions`, `--hold-session`, `--release-session`, `--list-targets`, `--check-config`, `--report`, `--check-health`, `--init-config`, `--init-env`, `--doctor`
- `--min-free-path` vs `--restore`, `--purge-sessions`, `--list-sessions`, `--hold-session`, `--release-session`, `--list-targets`, `--check-config`, `--report`, `--check-health`, `--init-config`, `--init-env`, `--doctor`
- `--min-free` vs `--restore`, `--purge-sessions`, `--list-sessions`, `--hold-session`, `--release-session`, `--list-targets`, `--check-config`, `--report`, `--check-health`, `--init-config`, `--init-env`, `--doctor`
- `--min-age` vs `--restore`, `--purge-sessions`, `--list-sessions`, `--hold-session`, `--release-session`, `--list-targets`, `--check-config`, `--report`, `--check-health`, `--init-config`, `--init-env`, `--doctor`
- `--trash-keep-days` and `--trash-max-size` vs `--restore`, `--purge-sessions`, `--list-sessions`, `--hold-session`, `--release-session`, `--list-targets`, `--check-config`, `--report`, `--check-health`, `--init-config`, `--init-env`, `--doctor`, `--only-path`
- `--notify` vs `--restore`, `--purge-sessions`, `--list-sessions`, `--hold-session`, `--release-session`, `--list-targets`, `--check-config`, `--report`, `--check-health`, `--init-config`, `--init-env`, `--doctor`
- `--json` is valid with `--dry-run` (cleanup summary), `--restore SESSION --dry-run` (active explicit `--dry-run` restore preview; rejected on mutating `--restore` or `--restore ... --dry-run --force`), `--purge-sessions SELECTOR --dry-run` (active explicit `--dry-run` purge preview; rejected on mutating `--purge-sessions` or `--purge-sessions ... --dry-run --force`), `--list-targets`, `--list-sessions`, `--report` (saved report summary), `--doctor` (environment readiness checklist), or `--check-config` (configuration validation summary; not `--init-config`, `--overlay`, or `--init-env`)
- `--only` and CLI-only `--only-exact` require `--restore`, cannot be mixed in either order, and use last-occurrence precedence when the same selector repeats. Exact matching uses the literal inventory path without expansion or normalization; no environment mirror or JSON fields are added.
- `--backup-conflicts` is CLI-only (no environment mirror) and requires `--restore`.
- `--strict` is CLI-only (no environment mirror) and applies only to `--doctor`.
- `--log-max-size` requires `--log` or `LINUX_CLEANER_LOG`.
- `--no-sudo` vs `--purge-sessions`, `--list-sessions`, `--hold-session`, `--release-session`, `--list-targets`, `--check-config`, `--report`, `--check-health`, `--init-config`, `--init-env`, `--doctor` (valid with cleanup, dry-run, or `--restore`).
- `--list-targets` vs `--restore`, `--purge-sessions`, `--list-sessions`, `--hold-session`, `--release-session`, `--check-config`, `--report`, `--check-health`, `--init-config`, `--init-env`, `--doctor`, `--exclude-from`, `--no-sudo`, `--min-reclaim`, `--min-free`, `--min-free-path`, `--min-age`, `--action-timeout`, `--trash-keep-days`, `--trash-max-size`, `--notify`, `--fail-fast`, `--show-matches`, `--exit-code`
- `--check-config` vs `--restore`, `--purge-sessions`, `--list-sessions`, `--hold-session`, `--release-session`, `--list-targets`, `--report`, `--check-health`, `--init-config`, `--init-env`, `--doctor`, `--exclude-from`, `--skip-actions`, `--no-sudo`, `--only-target`, `--only-target-exact`, `--exclude-target`, `--exclude-target-exact`, `--only-path`, `--exclude-path`, `--min-reclaim`, `--min-free`, `--min-free-path`, `--min-age`, `--action-timeout`, `--trash-keep-days`, `--trash-max-size`, `--notify`, `--fail-fast`, `--show-matches`, `--exit-code`
- `--report` vs `--restore`, `--purge-sessions`, `--list-sessions`, `--hold-session`, `--release-session`, `--list-targets`, `--check-config`, `--init-config`, `--init-env`, `--doctor`, `--exclude-from`, `--skip-actions`, `--no-sudo`, `--only-target`, `--only-target-exact`, `--exclude-target`, `--exclude-target-exact`, `--only-path`, `--exclude-path`, `--min-reclaim`, `--min-free`, `--min-free-path`, `--min-age`, `--action-timeout`, `--trash-keep-days`, `--trash-max-size`, `--notify`, `--fail-fast`, `--show-matches`, `--exit-code`
- `--init-config` vs `--restore`, `--purge-sessions`, `--list-sessions`, `--hold-session`, `--release-session`, `--list-targets`, `--check-config`, `--report`, `--check-health`, `--init-env`, `--doctor`, `--exclude-from`, `--skip-actions`, `--no-sudo`, `--only-target`, `--only-target-exact`, `--exclude-target`, `--exclude-target-exact`, `--only-path`, `--exclude-path`, `--min-reclaim`, `--min-free`, `--min-free-path`, `--min-age`, `--action-timeout`, `--trash-keep-days`, `--trash-max-size`, `--notify`, `--fail-fast`, `--show-matches`, `--exit-code`, `--json`
- `--overlay` requires `--init-config` (therefore cannot combine with `--init-env`, `--json`, or any non-`--init-config` mode/filter)
- `--init-env` vs `--restore`, `--purge-sessions`, `--list-sessions`, `--hold-session`, `--release-session`, `--list-targets`, `--check-config`, `--report`, `--check-health`, `--init-config`, `--overlay`, `--doctor`, `--exclude-from`, `--skip-actions`, `--no-sudo`, `--only-target`, `--only-target-exact`, `--exclude-target`, `--exclude-target-exact`, `--only-path`, `--exclude-path`, `--min-reclaim`, `--min-free`, `--min-free-path`, `--min-age`, `--action-timeout`, `--trash-keep-days`, `--trash-max-size`, `--notify`, `--fail-fast`, `--show-matches`, `--exit-code`, `--json` (compatible with `-t`/`--trash`)
- `--doctor` vs `--restore`, `--purge-sessions`, `--list-sessions`, `--hold-session`, `--release-session`, `--list-targets`, `--check-config`, `--report`, `--check-health`, `--init-config`, `--init-env`, `--exclude-from`, `--skip-actions`, `--no-sudo`, `--only-target`, `--only-target-exact`, `--exclude-target`, `--exclude-target-exact`, `--only-path`, `--exclude-path`, `--min-reclaim`, `--min-free`, `--min-free-path`, `--min-age`, `--action-timeout`, `--trash-keep-days`, `--trash-max-size`, `--notify`, `--fail-fast`, `--show-matches`, `--exit-code`
- `--action-timeout` and `--fail-fast` vs `--restore`, `--purge-sessions`, `--list-sessions`, `--hold-session`, `--release-session`, `--list-targets`, `--check-config`, `--report`, `--check-health`, `--init-config`, `--init-env`, `--doctor`
- `--restore` vs `--purge-sessions`, `--list-sessions`, `--hold-session`, `--release-session`, `--list-targets`, `--check-config`, `--report`, `--check-health`, `--init-config`, `--init-env`, `--doctor`, `--exclude-from`, `--skip-actions`, `--only-target`, `--only-target-exact`, `--exclude-target`, `--exclude-target-exact`, `--only-path`, `--exclude-path`, `--min-reclaim`, `--min-free`, `--min-free-path`, `--min-age`, `--action-timeout`, `--trash-keep-days`, `--trash-max-size`, `--notify`, `--fail-fast`, `--show-matches`, `--exit-code` (valid with `--no-sudo`, `--only`/`--only-exact`, `--backup-conflicts`, and active explicit `--dry-run [--json]`)
- `--purge-sessions` vs `--restore`, `--list-sessions`, `--hold-session`, `--release-session`, `--list-targets`, `--check-config`, `--report`, `--check-health`, `--init-config`, `--init-env`, `--doctor`, `--exclude-from`, `--skip-actions`, `--no-sudo`, `--only-target`, `--only-target-exact`, `--exclude-target`, `--exclude-target-exact`, `--only-path`, `--exclude-path`, `--min-reclaim`, `--min-free`, `--min-free-path`, `--min-age`, `--action-timeout`, `--trash-keep-days`, `--trash-max-size`, `--notify`, `--fail-fast`, `--show-matches`, `--exit-code` (valid with active explicit `--dry-run [--json]`)
- `--list-sessions` vs `--restore`, `--purge-sessions`, `--hold-session`, `--release-session`, `--list-targets`, `--check-config`, `--report`, `--check-health`, `--init-config`, `--init-env`, `--doctor`, `--exclude-from`, `--skip-actions`, `--no-sudo`, `--only-target`, `--only-target-exact`, `--exclude-target`, `--exclude-target-exact`, `--only-path`, `--exclude-path`, `--min-reclaim`, `--min-free`, `--min-free-path`, `--min-age`, `--action-timeout`, `--trash-keep-days`, `--trash-max-size`, `--notify`, `--fail-fast`, `--show-matches`, `--exit-code`
- `--hold-session` vs `--release-session`, `--restore`, `--purge-sessions`, `--list-sessions`, `--list-targets`, `--check-config`, `--report`, `--check-health`, `--init-config`, `--init-env`, `--doctor`, `--exclude-from`, `--skip-actions`, `--no-sudo`, `--only-target`, `--only-target-exact`, `--exclude-target`, `--exclude-target-exact`, `--only-path`, `--exclude-path`, `--min-reclaim`, `--min-free`, `--min-free-path`, `--min-age`, `--action-timeout`, `--trash-keep-days`, `--trash-max-size`, `--notify`, `--fail-fast`, `--show-matches`, `--exit-code`, `--dry-run`, `--clean`, `--interactive`, `--json`
- `--release-session` vs `--hold-session`, `--restore`, `--purge-sessions`, `--list-sessions`, `--list-targets`, `--check-config`, `--report`, `--check-health`, `--init-config`, `--init-env`, `--doctor`, `--exclude-from`, `--skip-actions`, `--no-sudo`, `--only-target`, `--only-target-exact`, `--exclude-target`, `--exclude-target-exact`, `--only-path`, `--exclude-path`, `--min-reclaim`, `--min-free`, `--min-free-path`, `--min-age`, `--action-timeout`, `--trash-keep-days`, `--trash-max-size`, `--notify`, `--fail-fast`, `--show-matches`, `--exit-code`, `--dry-run`, `--clean`, `--interactive`, `--json`

See `test_cleaner.sh` mutex rejection cases.

## 5. Required drift tests to extend

When adding CLI/env/JSON surface:

- `Man Page Option Consistency`, `Man Page Env Var Parity`, `Value-taking Options Doc Parity`, `Mode Flag Exclusion Docs Parity`, and `Dry-Run Next Options And Cleanup Metrics Doc Parity`
- Environment mirror block (`LINUX_CLEANER_*` tests)
- `Bash Completion Drift and Functional Check` and `Zsh and Fish Completion Functional Check` (add the flag to `completions/cleaner.bash`, `completions/_cleaner`, and `completions/cleaner.fish`)
- JSON output cases (`JSON Dry Run` / `JSON Dry Run Output`, `List Targets JSON` / `List Targets JSON Output`, `List Sessions JSON`, `List Sessions JSON Empty`, `Report JSON After Cleanup`, `Report JSON After Interrupted Cleanup`, `Report JSON Without Report`, `Restore Dry Run JSON Preview`, `Purge Sessions Dry Run JSON Preview`, `Check Config JSON Output`, `Doctor JSON Output`)
- `List Targets JSON` asserts the shipped inventory keys (`description`, `min_age_days`, `check_processes`, `custom_action`)
