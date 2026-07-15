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
