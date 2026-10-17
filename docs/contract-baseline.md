# Contract baseline

Documentation contract work for linux-cleaner v1.3.0 starts from a green hermetic gate on `main`.

## Baseline gate (F1.1-01)

Recorded: 2026-07-15 on branch `main`.

| Gate | Command | Result |
|------|---------|--------|
| ShellCheck | `shellcheck cleaner.sh test_cleaner.sh install.sh release-notes.sh` | PASS (exit 0) |
| Hermetic suite | `make check` | PASS (exit 0) |

Both gates must stay green before and after every documentation edit in Phase 1.

## Manual review findings (F1.1-02)

Cross-walk of `README.md` CLI sections, `cleaner.sh --help`, and `cleaner.1` on 2026-07-15:

| Topic | README | help / man | Status |
|-------|--------|------------|--------|
| Short-option letters (`-c`, `-d`, `-f`, `-i`, `-q`, `-r`, `-t`, `-e`, `-V`, `-h`) | Present | Present | aligned |
| `--only-target` mutual exclusion (no `--restore`, `--purge-sessions`, `--list-sessions`, `--list-targets`) | Present | Present | aligned (drift resolved; enforced by the ONLY_TARGET guard in cleaner.sh) |
| `--json` requires dry-run for cleanup summary; inventory with `--list-targets` | Documented | Documented | aligned |
| Irreversible purge / custom-action warnings | GFM admonitions | `.B` WARNING-style prose in man SAFETY/OPTIONS | aligned (format differs, facts match) |
| Exit-code semantics (skip ≠ failure) | Documented | Documented in EXIT STATUS | aligned |

**Mismatches (prose contradicts help/man):** none. Short flags, mutual-exclusion notes, and irreversible-operation callouts are consistent across the three surfaces.

## F1.1-03 conditional fix (skipped)

No prose contradictions were listed in the findings above; no README, `cleaner.1`, or `cleaner.sh` edits were required.

## F2.2-02

`Quarantine for Purge` passes on HEAD; no test repair required.
