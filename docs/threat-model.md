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
