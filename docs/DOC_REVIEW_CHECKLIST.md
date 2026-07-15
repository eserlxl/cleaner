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

## Changelog unreleased map
- [ ] `docs/changelog-doc-map.md` rows reviewed

## Prose / warnings
- [ ] `docs/prose-warnings-review.md` has no open gaps

## Sign-off
- Reviewer:
- Date:
- Branch:
