# Environment and automation contract

Cross-walk of environment variables, CLI flags, truthy values, and constraints. Compared against `README.md` and `cleaner.1` on 2026-07-15.

| Environment variable | CLI flag | Truthy values | Constraints | README vs man |
|---------------------|----------|---------------|-------------|---------------|
| `LINUX_CLEANER_CONFIG` | `-c`, `--config FILE` | non-empty path | Explicit `-c/--config` overrides; when unset, XDG/system/dev search order unchanged | aligned |
| `LINUX_CLEANER_LOG` | `--log [FILE]` | non-empty path | Path must resolve under `$HOME`; tilde/`$HOME`/`$USER` expansion allowed | aligned |
| `LINUX_CLEANER_QUIET` | `-q`, `--quiet` | `1`, `true`, `yes` | CLI overrides env | aligned |
| `LINUX_CLEANER_JSON` | `--json` | `1`, `true`, `yes` | Valid with dry-run (`--dry-run` or default), `--list-targets`, or `--list-sessions` | aligned |
| `LINUX_CLEANER_ONLY_TARGET` | `--only-target PATTERN` | non-empty pattern | Substring on config `NAME`; mutex with restore/purge/list modes | aligned |
| `LINUX_CLEANER_EXCLUDE_TARGET` | `--exclude-target PATTERN` | non-empty pattern | Substring on config `NAME`; mutex with restore/purge/list modes | aligned |
| `LINUX_CLEANER_RISK` | `-r`, `--risk LEVEL` | `safe`, `medium`, `danger` | Invalid values error; CLI overrides | aligned |
| `LINUX_CLEANER_TRASH` | `-t`, `--trash` | `1`, `true`, `yes` | Quarantine mode; CLI overrides | aligned |
| `LINUX_CLEANER_EXCLUDE` | `-e`, `--exclude PATTERNS` | non-empty list | Comma-separated globs; CLI overrides | aligned |
| `LINUX_CLEANER_FORCE` | `-f`, `--force` | `1`, `true`, `yes` | Enables real cleanup and skips normal prompts; danger still needs confirmation or `--yes-danger`. Explicit CLI `--dry-run` restores preview mode unless a later execution flag overrides it | aligned |
| `LINUX_CLEANER_YES_DANGER` | `--yes-danger` | `1`, `true`, `yes` | Only meaningful with `--force` and `--risk danger` | aligned |
| `LINUX_CLEANER_ALLOW_OUTSIDE_HOME` | `--allow-outside-home` | `1`, `true`, `yes` | High-risk; permits targets outside `$HOME`; CLI overrides | aligned |
| `NO_COLOR` | (none) | any non-empty | Disables ANSI per no-color.org; not a `LINUX_CLEANER_*` mirror | aligned (README prose below env table; man ENVIRONMENT) |

**Override rule:** CLI flags always override environment toggles when both are present (`cleaner.sh` applies env before CLI parsing completes).

**Flagged divergence rows:** none — truthy lists, JSON dry-run requirement, and override semantics match across README and `cleaner.1`.
