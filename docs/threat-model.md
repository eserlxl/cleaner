# Threat model

## Overview

linux-cleaner is a safety-critical, configuration-driven cache cleaner.

## Assets

| Asset | Sensitivity |
|-------|-------------|
| User files under `$HOME` | High |
| Config file (`cleaner.conf`) | High |

## Trust Boundaries

| Boundary | Trust assumption |
|----------|------------------|
| Config file author | Operator controls config path |
| `/etc/linux-cleaner/cleaner.conf` | System admin |
| Quarantine tree and `quarantine.meta` | Trusted local state; restore consumes recorded paths, privilege use, and ownership |

## Threat Actors

- Local misconfiguration
- Malicious local user (multi-user systems)
- Supply-chain (packaged config)

## Controls Index

| # | Scenario | Primary control | Verification |
|---|----------|-----------------|--------------|
| 1 | Malformed config lines | Parser rejection | Malformed Too Few Fields |
| 2 | Path traversal in PATH_EXPRESSION | `check_path_safety` | Canonicalization Dotdot Escape |
| 3 | CUSTOM_ACTION injection | Enumerated `action:*` whitelist | Predefined Action |
| 4 | Compromised `/etc/linux-cleaner/cleaner.conf` | File permissions + operator review | Operator mitigations (below) |
| 5 | Env-token abuse | Whole-token expansion | Whole-Token HOME/USER Expansion |
| 6 | Path escape via quarantine SESSION name | `validate_quarantine_session_name` | Restore Invalid Session / Purge Invalid Session |
| 7 | Over-broad wildcard in PATH_EXPRESSION | Fixed-depth `find` below a literal root + per-match `check_path_safety` | Wildcard Path Expansion / Wildcard Root Refusal / Wildcard Line Number Fidelity |
| 8 | Build target contains source files | With Git available, `count_git_tracked` skips targets containing tracked files even with `--force`, unless the cleaner runs as root or the target requires sudo. | Git-Tracked Target Guard |

## Config Tampering and Injection

| # | Scenario | Likelihood | Impact |
|---|----------|------------|--------|
| 1 | Malformed lines | Medium | Low — run aborts |
| 2 | Path traversal in PATH_EXPRESSION | Low | High |
| 3 | Arbitrary command injection via CUSTOM_ACTION | Low | Critical — only enumerated action:* |
| 4 | Compromised /etc/linux-cleaner/cleaner.conf | Low | High |
| 5 | Env-token abuse ($HOMEDATA vs $HOME) | Low | Medium |
| 6 | Over-broad wildcard in PATH_EXPRESSION | Medium | High — one line becomes many targets |

### Controls mapping (config)

| Scenario | Control | Test |
|----------|---------|------|
| Malformed lines | Parser rejection | Malformed Too Few Fields |
| Path traversal in PATH_EXPRESSION | `check_path_safety` rejects dotdot/symlink escape | Canonicalization Dotdot Escape |
| Unknown action | Enumerated whitelist | Predefined Action |
| Compromised /etc/linux-cleaner/cleaner.conf | Root-owned config + dry-run before clean | Operator mitigations (below) |
| Env-token abuse | Whole-token expansion | Whole-Token HOME/USER Expansion |
| Over-broad wildcard | Expansion is amplification, not escape: a wildcard cannot reach a depth the pattern does not describe, cannot start at the filesystem root, and never runs through the shell or `eval`. Every match is then checked individually, so the root/system block and symlink guard still apply. A match outside HOME is allowed. `--dry-run` and `--list-targets` enumerate every match before deletion; an anchored pattern is preferred when a sibling directory could match by accident. | Wildcard Path Expansion / Wildcard Root Refusal / Wildcard Line Number Fidelity |

### Operator mitigations (/etc config)

- File permissions on `/etc/linux-cleaner/cleaner.conf` (root-owned, not world-writable).
- Run `cleaner --dry-run` and `cleaner --list-targets` before `--clean`.
- Never enable irreversible action:pacman_clean without explicit intent.

## Path Safety and Filesystem Races

| Scenario | Posture | Test |
|----------|---------|------|
| Dotdot escape | FOUND at the canonical outside path | Canonicalization Dotdot Escape |
| Symlink parent outside HOME | FOUND at the canonical outside path | Symlinked Parent Escape |
| Symlink target | Refused (SYMLINK) | Dry Run Mode (Default) |
| Protected system directory | UNSAFE (`check_path_safety` returns 1) | Protected System Dir UNSAFE / Top-Level System Directories |
| Root required, privileges unavailable | Skipped (`requires root`); the rest of the run continues and the exit status stays 0 | Root Skip Without Privileges |
| TOCTOU on live paths | residual | manual VM review |

Targets outside HOME are allowed. `check_path_safety` still returns 1 for protected system directories and 3 for a symlink target. Return 2 (outside HOME) is cleaned like an in-HOME target. User-defined protected directories come in a later change.

A target that needs root and cannot obtain it is skipped with a warning and an operation-log record (`outcome=skipped reason=requires-root`). An unattended run (no TTY on stdin) never prompts. A failed or cancelled prompt is remembered, and every later root-requiring target of that run is skipped without asking again. A dry-run never prompts.

### GNU userland

GNU guard refuses --clean/--trash on non-GNU userland (misconfiguration protection).

## Quarantine Integrity and Collisions

| Scenario | Control |
|----------|---------|
| Metadata tampering | Residual risk: restore trusts recorded paths and ownership; protect the quarantine tree from untrusted edits |
| Restore conflicts | Restore with Conflict test (collision detection) |
| Action vs trash confusion | irreversible action:* WARNING |
| Path escape via SESSION name | `validate_quarantine_session_name` rejects `/`, `.`, `..` (Restore/Purge Invalid Session) |

### Quarantine operator guidance

- Audit with `--list-sessions` before destructive purge.
- Pair `--trash` with `purge-sessions older-than:DAYS` for bounded disk use.
- Irreversible action:* bypasses quarantine — distinct from trash mode.

See also: [QUARANTINE-OPS.md](QUARANTINE-OPS.md) (session inventory, retention sizing) and
[manual-smoke-checklist.md](manual-smoke-checklist.md) (TOCTOU manual VM review).

## Executive summary

Primary threats: misconfiguration, config tampering, path escape, irreversible actions vs quarantine.

## Residual risk summary

| Risk | Status |
|------|--------|
| Live /etc config tampering | residual |
| TOCTOU | residual |
| Quarantine metadata tampering | residual; restore only trusted sessions |

## Periodic refresh policy

Review on new action:*, config format changes, or annually.

## Appendix: Gap Review 2026-07-15

Cross-walk of CONTRIBUTING invariants, threat scenarios, and make check inventory: no code changes required.
