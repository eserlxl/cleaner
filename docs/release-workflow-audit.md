# Release workflow audit

| release.yml step | RELEASING.md | test_cleaner.sh |
|------------------|--------------|------------------|
| `on.push.tags` glob (`v[0-9]*.[0-9]*.[0-9]*`) + Validate release tag format | Annotated `vX.Y.Z` tag | Release Notes Extraction |
| shellcheck | Pre-release gate | ShellCheck Single Source |
| make check (validate-runbook-examples.sh, then test_cleaner.sh) | Pre-release gate | full suite + runbook validator |
| release-notes.sh extract | Publish notes | Release Notes Extraction |

No mismatches recorded.

## Permissions review

`contents: write` only on release job. No empty-notes fallback; extract failure fails the job.
