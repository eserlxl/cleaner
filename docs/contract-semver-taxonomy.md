# Contract SemVer taxonomy

Decision guide for classifying changes to linux-cleaner public contracts (CLI flags, config fields, `action:*` tokens, JSON keys).

## Decision tree

```
Does the change break an existing consumer that followed documented contracts?
├─ YES → MAJOR (X.0.0)
└─ NO  → Does it add observable capability or tighten safety validation?
         ├─ Adds capability / new optional surface → MINOR (0.X.0)
         └─ Docs-only / internal test fix → PATCH (0.0.X)
```

## Scenario examples

| # | Change | Bump | Rationale |
|---|--------|------|-----------|
| 1 | Rename CLI flag `--foo` → `--bar` | **MAJOR** | Scripts parsing `--foo` break |
| 2 | Add optional config field `TAG` at end of line | **MINOR** | New parser still accepts old configs; configs using the new column require an upgraded parser because current versions reject more than seven fields |
| 3 | Tighten validation to reject previously accepted malformed lines | **MINOR** | Safety-guard tightening per CHANGELOG policy; may break invalid configs |
| 4 | Add new `action:zypper_clean` token | **MINOR** | Additive registry entry; old configs unaffected |
| 5 | Rename JSON key `bytes` → `reclaimable_bytes` | **MAJOR** | Monitoring parsers break |
| 6 | Fix README typo / clarify prose with no behavior change | **PATCH** | No contract change |

## Escalation

When in doubt about bump class, **ask the maintainer before merge**. Document the decision in the CHANGELOG `[Unreleased]` section under the correct heading (`Added`, `Changed`, `Fixed`, `Security`).

## Related docs

- [Config field governance](config-field-governance.md)
- [Action registry governance](action-registry-governance.md)
- [CLI/env/JSON governance](cli-env-json-governance.md)
