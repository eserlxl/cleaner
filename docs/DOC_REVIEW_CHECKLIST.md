# Documentation review checklist

## Automated gates
- [ ] `make lint`
- [ ] `make check`

## CLI / help / man
- [ ] `Man Page Option Consistency` test green
- [ ] `Man Page Env Var Parity` test green
- [ ] `docs/contract-baseline.md` drift inventory current

## Env / automation
- [ ] Env test block in `test_cleaner.sh` green
- [ ] `docs/env-automation-contract.md` matches `docs/cli-reference.md` and man

## Changelog / coverage inventory
- [ ] `docs/test-coverage-matrix.md` shipped-feature rows reviewed

## Prose / warnings
- [ ] `docs/contract-baseline.md` manual review findings current

## Governance and threat model
- [ ] `docs/threat-model.md` controls index matches detailed sections
- [ ] `docs/action-registry-governance.md` action:* registry current
- [ ] `docs/config-field-governance.md` schema change checklist current
- [ ] `docs/cli-env-json-governance.md` JSON/env contract current

## Operations and packaging
- [ ] `docs/QUARANTINE-OPS.md` cross-links and retention matrix current
- [ ] `docs/packager-handoff.md` PKGBUILD/install parity current
- [ ] `docs/release-workflow-audit.md` release gate inventory current

## Sign-off
- Reviewer:
- Date:
- Branch:

## Sign-off (execute pass)

- Reviewer: planwright execute
- Date: 2026-07-15
- Branch: main
- Result: checklist walked; gates green
