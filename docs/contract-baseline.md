# Contract baseline

Documentation contract work for linux-cleaner (`VERSION="1.9.1"` in `cleaner.sh:19` plus `## [Unreleased]` in `CHANGELOG.md`) starts from a green hermetic gate on `main`.

## Active baseline gate

Recorded: 2026-11-16 on branch `main` (`1.9.1` + `[Unreleased]`).

| Gate | Command | Result |
|------|---------|--------|
| ShellCheck | `make lint` | PASS (exit 0) |
| Hermetic suite | `make check` | PASS (exit 0) |

Both gates must stay green before and after every documentation edit.

## Current CLI cross-walk

Cross-walk of `README.md`, `docs/cli-reference.md`, `cleaner.sh --help` (`cleaner.sh:46-100`), and `cleaner.1` on 2026-11-16 (`1.9.1` + `[Unreleased]`):

| Topic | README / docs | help / man | Status |
|-------|---------------|------------|--------|
| Short-option letters (`-c`, `-d`, `-i`, `-f`, `-t`, `-r`, `-e`, `-q`, `-h`, `-V`) | `README.md:36` delegates full CLI table (`-r, --risk` inline at `README.md:96`); `docs/cli-reference.md` lists all 10 | `cleaner.sh:46-100` (`show_usage`) and `cleaner.1` OPTIONS document all 10 | aligned (surface ownership split by design) |
| `--only-target` mutual exclusion | `docs/cli-reference.md` lists full exclusion set | Refuses `--only-target-exact`, `--restore`, `--purge-sessions`, `--list-sessions`, `--hold-session`, `--release-session`, `--check-config`, `--report`, `--check-health`, `--init-config`, `--init-env`, and `--doctor` (compatible with `--list-targets` at `cleaner.sh:1091-1094`); enforced via `ONLY_TARGET_CLI`/`ONLY_TARGET`/`HOLD_TARGET`/`RELEASE_TARGET` checks (`cleaner.sh:519-548,951-960,995-1013`) and `Mode Flag Exclusion Docs Parity` (`test_cleaner.sh:8770-8866`) | aligned |
| `--json` mode gating and refusals | `docs/cli-reference.md:58` documents all eight modes | `cleaner.sh:98,1130-1136` enables `--dry-run` cleanup, `--restore SESSION --dry-run`, `--purge-sessions SELECTOR --dry-run`, `--list-targets`, `--list-sessions`, `--report`, `--doctor`, and `--check-config`, while refusing mutating runs (including non-dry-run `--restore`/`--purge-sessions`), `--init-config`, `--overlay`, and `--init-env` | aligned |
| Irreversible purge / custom-action warnings | GFM `> [!WARNING]` (`README.md:62-63,133-134`, `docs/configuration.md:42-43`) and `> **WARNING:**` (`docs/QUARANTINE-OPS.md:163`) | `cleaner.sh:88` notes `--purge-sessions` is `Irreversible.`; `cleaner.1:1481` marks purge `Irreversible;` and `cleaner.1:2175-2206` enumerates whitelisted `action:*` handlers under `CONFIGURATION` | aligned (format differs by surface, facts match) |
| Exit-status semantics (`0`, `1`, `2`, `130`, `143`) | `docs/cli-reference.md:107-113` documents all five codes | `cleaner.1:2335-2359` (`EXIT STATUS`) documents `0` (success; skip != failure), `1` (error/failed operation/lock contention/`--check-health` failure), `2` (`--exit-code` preview when cleanup would run), `130` (`SIGINT`), and `143` (`SIGTERM`), and `cleaner.1:835-840,875-891` documents `--doctor --strict` exit `1` | aligned |

**Mismatches (prose contradicts help/man):** none. Short flags, surface ownership (`README.md` vs `docs/cli-reference.md` vs `cleaner.sh --help` vs `cleaner.1`), `--only-target` exclusions, all eight `--json` modes and refusals, warning formats, and exit statuses `0`, `1`, `2`, `130`, `143` align across surfaces on `HEAD`.

## Historical provenance (v1.3.0)

Initial contract baseline audit markers recorded on 2026-07-15 for `v1.3.0` on `main` (superseded as active status by the `1.9.1` + `[Unreleased]` sections above; retained for historical audit traceability):

- **`F1.1-01` (2026-07-15 `v1.3.0` baseline gate):** `make lint` (`PASS`) and `make check` (`PASS`) established the pre-edit baseline on `main`.
- **`F1.1-02` (2026-07-15 `v1.3.0` manual review):** initial cross-walk of `README.md`, `cleaner.sh --help`, and `cleaner.1` verified short-option alignment, `--only-target` mutual exclusion resolution, four `--json` modes, admonition/man warnings, and skip-vs-failure exit semantics at `v1.3.0`.
- **`F1.1-03` (2026-07-15 `v1.3.0` conditional fix — skipped):** no prose contradictions remained after `F1.1-02`, so no conditional doc/help fixes were required.
- **`F2.2-02` (2026-07-15 `v1.3.0` purge check):** `Quarantine for Purge` passed on the `v1.3.0` baseline without test repair.
