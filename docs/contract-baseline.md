# Contract baseline

Documentation contract work for linux-cleaner v1.2.0 starts from a green hermetic gate on `main`.

## Baseline gate (F1.1-01)

Recorded: 2026-07-15 on branch `main`.

| Gate | Command | Result |
|------|---------|--------|
| ShellCheck | `shellcheck cleaner.sh test_cleaner.sh install.sh release-notes.sh` | PASS (exit 0) |
| Hermetic suite | `make check` | PASS (exit 0) |

Both gates must stay green before and after every documentation edit in Phase 1.
