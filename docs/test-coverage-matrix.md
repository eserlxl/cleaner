# Test coverage matrix

## 1.3.0 shipped feature inventory

Rows below moved here after the 1.3.0 release; add new unreleased rows only while `[Unreleased]` in `CHANGELOG.md` still holds entries.

| ID | Feature | Test case |
|----|---------|-----------|
| U-01 | LINUX_CLEANER_ONLY_TARGET | LINUX_CLEANER_ONLY_TARGET Env |
| U-02 | --list-targets --json | List Targets JSON |
| U-03 | LINUX_CLEANER_RISK | LINUX_CLEANER_RISK Env |
| U-04 | LINUX_CLEANER_TRASH | LINUX_CLEANER_TRASH Env |
| U-05 | NO_COLOR | NO_COLOR Disables ANSI |
| U-06 | LINUX_CLEANER_EXCLUDE | LINUX_CLEANER_EXCLUDE Env |
| U-07 | LINUX_CLEANER_FORCE | LINUX_CLEANER_FORCE Env |
| U-08 | LINUX_CLEANER_YES_DANGER | LINUX_CLEANER_YES_DANGER Env |

## Drift guards

| Test heading | Invariant | Files watched |
|--------------|-----------|---------------|
| Man Page Option Consistency | help options in man | cleaner.sh, cleaner.1 |
| Man Page Env Var Parity | env vars in man | cleaner.sh, cleaner.1, README.md |
| Stranded [Unreleased] Entries Are Detected | no stranded changelog | CHANGELOG.md, test_cleaner.sh |
| Release Notes Extraction | release-notes.sh contract | release-notes.sh, .github/workflows/release.yml |
| Changelog/Version Consistency | version sync | cleaner.sh, cleaner.1, PKGBUILD, CHANGELOG.md |
| ShellCheck Invocation Parity | lint parity | Makefile, ci.yml, test_cleaner.sh |

Manual smoke: see `docs/manual-smoke-checklist.md`.
