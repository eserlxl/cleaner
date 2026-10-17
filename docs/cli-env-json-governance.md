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
- **CLI overrides value mirrors** (config, log, risk, exclude, target filters) when both are set. On/off mirrors can only enable a behavior from the CLI; disable one by setting it to a non-truthy value or unsetting it.
- `LINUX_CLEANER_YES_DANGER` stays off in default examples. `LINUX_CLEANER_ALLOW_OUTSIDE_HOME` and `--allow-outside-home` are deprecated no-ops (one warning per run); targets outside `$HOME` are always allowed.
- JSON target `status` no longer emits `rejected`. Older clients that accept that value keep working; current runs use the other statuses (`found`, `skipped`, and the rest).

## 3. JSON additive vs breaking changes

| Change | Bump |
|--------|------|
| Add new optional JSON key | MINOR |
| Rename or remove existing key | MAJOR |
| Change key semantics | MAJOR unless purely additive |

## 4. Mutex flags

Documented mutual exclusions (enforced in code):

- `--only-target` vs `--restore`, `--purge-sessions`, `--list-sessions`, `--check-config`, `--report`, `--init-config`
- `--exclude-target` vs `--restore`, `--purge-sessions`, `--list-sessions`, `--check-config`, `--report`, `--init-config`
- `--min-reclaim` vs `--restore`, `--purge-sessions`, `--list-sessions`, `--list-targets`, `--check-config`, `--report`, `--init-config`
- `--trash-keep-days` vs `--restore`, `--purge-sessions`, `--list-sessions`, `--list-targets`, `--check-config`, `--report`, `--init-config`
- `--json` is valid with `--dry-run` (cleanup summary), `--list-targets`, `--list-sessions`, or `--report` (saved report summary; not `--init-config`)
- `--only` requires `--restore`
- `--only-target` and `--exclude-target` vs `--check-config`
- `--list-targets` vs `--restore`, `--purge-sessions`, `--list-sessions`, `--report`, `--init-config`
- `--check-config` vs `--restore`, `--purge-sessions`, `--list-sessions`, `--list-targets`, `--report`, `--init-config`
- `--report` vs `--restore`, `--purge-sessions`, `--list-sessions`, `--list-targets`, `--check-config`, `--init-config`
- `--init-config` vs `--restore`, `--purge-sessions`, `--list-sessions`, `--list-targets`, `--check-config`, `--report`, `--only-target`, `--exclude-target`, `--min-reclaim`, `--trash-keep-days`, `--json`

See `test_cleaner.sh` mutex rejection cases.

## 5. Required drift tests to extend

When adding CLI/env/JSON surface:

- `Man Page Option Consistency`
- Environment mirror block (`LINUX_CLEANER_*` tests)
- JSON output cases (`JSON Dry Run`, `List Targets JSON`, `List Sessions JSON`, `List Sessions JSON Empty`, `Report JSON After Cleanup`, `Report JSON After Interrupted Cleanup`, `Report JSON Without Report`)
- `List Targets JSON` must assert additive inventory keys (`description`, `min_age_days`, `check_processes`, `custom_action`) when those fields ship
