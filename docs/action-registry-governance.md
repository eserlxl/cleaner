# Action registry governance

Mandatory touch points when adding a new predefined `action:*` token.

## Checklist

1. **Parse-time `case`** — Add the token to the allowed `CUSTOM_ACTION` enumeration in `validate_config_file()` in `cleaner.sh`; every cleanup, `--list-targets`, and `--check-config` run validates records there first, so it is the only parse-time list.
2. **Execution `case`** — Add an explicit command arm in the execution `case` (no shell interpolation of config strings).
3. **`action_required_binary()`** — Map the action to its required binary for skip-when-absent behavior.
4. **User-level actions only** — For an action that runs as the invoking user (no root), add it to `action_is_user_level()` and `action_display_command()` and do not prefix its execution arm with `sudo`. Without the first, the tool treats the action as root-only and skips it in unprivileged timer runs; the second supplies the command shown in its `--debug` FOUND line. Pass the target's configured path to the command (as `--cache-dir "$path"` does for uv) so the pruned cache is the one the tool checks and measures.
5. **README** — Add to the action table with irreversible **WARNING** if the command is destructive.
6. **`run_test_case`** — Add a hermetic test with stub binary under mock `$HOME`.
7. **CHANGELOG** — `[Unreleased]` **Added** entry naming the new action.
8. **SemVer** — Classify as **minor** (additive registry entry).

## Anti-patterns

- **Shell interpolation** of config-supplied command strings — never allowed.
- **Generic `action:custom`** channel — rejected by design.
- **Silent skip without message** when binary is absent — must log skip reason.

## Cross-references

| Function | Location |
|----------|----------|
| `action_required_binary()` | `cleaner.sh` |
| `action_is_user_level()` | `cleaner.sh` |
| `action_display_command()` | `cleaner.sh` |
| Parse-time validation | `validate_config_file()` in `cleaner.sh` |
| Execution dispatch | `cleaner.sh` action runner |
| Hermetic tests | `test_cleaner.sh` (`Predefined Action`, `Cross-Distro Actions`, etc.) |

See [contract-semver-taxonomy.md](contract-semver-taxonomy.md) for bump classification.
