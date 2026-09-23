# Release workflow audit

| release.yml step | RELEASING.md | test_cleaner.sh |
|------------------|--------------|------------------|
| shellcheck | Pre-release gate | ShellCheck Invocation Parity |
| make check (validate-runbook-examples.sh, then test_cleaner.sh) | Pre-release gate | full suite + runbook validator |
| release-notes.sh extract | Publish notes | Release Notes Extraction |

No mismatches recorded.

## Permissions review

`contents: write` only on release job. No empty-notes fallback; extract failure fails the job.
