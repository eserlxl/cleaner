# Release workflow audit

| release.yml step | RELEASING.md | test_cleaner.sh |
|------------------|--------------|------------------|
| shellcheck | Pre-release gate | ShellCheck Invocation Parity |
| test_cleaner.sh | Pre-release gate | full suite |
| release-notes.sh extract | Publish notes | Release Notes Extraction |

No mismatches recorded.
