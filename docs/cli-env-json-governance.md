# CLI, environment, and JSON governance

## 1. New CLI flag workflow

1. Add flag to `show_usage` / argument parser in `cleaner.sh`.
2. Mirror in `cleaner.1` OPTIONS section.
3. Document in README CLI section.
4. Add `run_test_case` for behavior and mutex rules.
5. Extend drift guards: `Man Page Option Consistency`, env mirror block if applicable.
6. Classify SemVer via [contract-semver-taxonomy.md](contract-semver-taxonomy.md).

## 2. Environment mirror naming and precedence

- Mirrors use `LINUX_CLEANER_*` prefix (see `docs/env-automation-contract.md`).
- Truthy values: `1`, `true`, `yes` (documented per variable).
- **CLI overrides env** when both are set.
- High-risk mirrors (`LINUX_CLEANER_ALLOW_OUTSIDE_HOME`, `LINUX_CLEANER_YES_DANGER`) stay off in default examples.

## 3. JSON additive vs breaking changes

| Change | Bump |
|--------|------|
| Add new optional JSON key | MINOR |
| Rename or remove existing key | MAJOR |
| Change key semantics | MAJOR unless purely additive |

## 4. Mutex flags

Documented mutual exclusions (enforced in code):

- `--only-target` vs `--restore`, `--purge-sessions`, `--list-sessions`, `--list-targets`
- `--json` is valid with `--dry-run` (cleanup summary), `--list-targets`, or `--list-sessions`
- `--only` requires `--restore`

See `test_cleaner.sh` mutex rejection cases.

## 5. Required drift tests to extend

When adding CLI/env/JSON surface:

- `Man Page Option Consistency`
- Environment mirror block (`LINUX_CLEANER_*` tests)
- JSON output cases (`JSON Dry Run`, `List Targets JSON`, `List Sessions JSON`, `List Sessions JSON Empty`)
- `List Targets JSON` must assert additive inventory keys (`description`, `min_age_days`) when those fields ship
