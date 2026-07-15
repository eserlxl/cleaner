# Documentation review checklist

## Automated gates
- [ ] `shellcheck cleaner.sh test_cleaner.sh install.sh release-notes.sh`
- [ ] `make check`

## CLI / help / man
- [ ] `Man Page Option Consistency` test green
- [ ] `Man Page Env Var Parity` test green
- [ ] `docs/contract-baseline.md` drift inventory current

## Env / automation
- [ ] Env test block in `test_cleaner.sh` green
- [ ] `docs/env-automation-contract.md` matches README and man

## Changelog / coverage inventory
- [ ] `docs/test-coverage-matrix.md` shipped-feature rows reviewed

## Prose / warnings
- [ ] `docs/contract-baseline.md` manual review findings current

## Sign-off
- Reviewer:
- Date:
- Branch:

## Sign-off (execute pass)

- Reviewer: planwright execute
- Date: 2026-07-15
- Branch: main
- Result: checklist walked; gates green

## Sign-off (execute pass)

- Reviewer: planwright execute
- Date: 2026-07-15
- Branch: main
- Result: checklist walked; gates green
