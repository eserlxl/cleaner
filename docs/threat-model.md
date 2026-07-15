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

## Threat Actors

- Local misconfiguration
- Malicious local user (multi-user systems)
- Supply-chain (packaged config)

## Controls Index

| Scenario | Control | Status |
|----------|---------|--------|
| (placeholder) | Phase 9.2–9.5 mappings | pending |

## Config Tampering and Injection

| # | Scenario | Likelihood | Impact |
|---|----------|------------|--------|
| 1 | Malformed lines | Medium | Low — run aborts |
| 2 | Path traversal in PATH_EXPRESSION | Low | High |
| 3 | Arbitrary command injection via CUSTOM_ACTION | Low | Critical — only enumerated action:* |
| 4 | Compromised /etc/linux-cleaner/cleaner.conf | Low | High |
| 5 | Env-token abuse ($HOMEDATA vs $HOME) | Low | Medium |

### Controls mapping (config)

| Scenario | Control | Test |
|----------|---------|------|
| Malformed lines | Parser rejection | Malformed Too Few Fields |
| Env-token abuse | Whole-token expansion | Whole-Token HOME/USER Expansion |
| Unknown action | Enumerated whitelist | Predefined Action |

### Operator mitigations (/etc config)

- File permissions on `/etc/linux-cleaner/cleaner.conf` (root-owned, not world-writable).
- Run `cleaner --dry-run` and `cleaner --list-targets` before `--clean`.
- Never enable irreversible action:pacman_clean without explicit intent.

## Path Safety and Filesystem Races

| Scenario | check_path_safety | Test |
|----------|-------------------|------|
| Dotdot escape | REJECTED | Canonicalization Dotdot Escape |
| Symlink parent outside HOME | REJECTED | Symlinked Parent Escape |
| TOCTOU on live paths | residual | manual VM review |

### GNU userland and --allow-outside-home

GNU guard refuses --clean/--trash on non-GNU userland (misconfiguration protection).
`--allow-outside-home` is high-risk opt-in for paths like /var/cache/pacman/pkg.

## Quarantine Integrity and Collisions

| Scenario | Control |
|----------|---------|
| Metadata tampering | quarantine.meta validation |
| Restore conflicts | Restore with Conflict test (collision detection) |
| Action vs trash confusion | irreversible action:* WARNING |

### Quarantine operator guidance

- Audit with `--list-sessions` before destructive purge.
- Pair `--trash` with `purge-sessions older-than:DAYS` for bounded disk use.
- Irreversible action:* bypasses quarantine — distinct from trash mode.

## Executive summary

Primary threats: misconfiguration, config tampering, path escape, irreversible actions vs quarantine.

## Residual risk summary

| Risk | Status |
|------|--------|
| Live /etc config tampering | residual |
| TOCTOU | residual |

## Periodic refresh policy

Review on new action:*, config format changes, or annually.

## Appendix: Gap Review 2026-07-15

Cross-walk of CONTRIBUTING invariants, threat scenarios, and make check inventory: no code changes required.
