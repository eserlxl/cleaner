# Manual smoke checklist

## Hermetic test boundaries

The hermetic suite stubs `sudo`, the package managers, and the user-level prune tools under mock `$HOME` (full list in [hermetic-test-guards.md](hermetic-test-guards.md)); absent-manager skips are covered there by the Cross-Distro Safe Degradation tests. It does not cover live `/etc/linux-cleaner/cleaner.conf` resolution, real sudo prompts, real package managers, or race-sensitive TOCTOU.

## /etc config resolution (maintainer)

1. Install to DESTDIR or VM (`make install DESTDIR=/tmp/stage`).
2. Place config at `/etc/linux-cleaner/cleaner.conf`.
3. Run `cleaner --dry-run` without `-c` (for a DESTDIR install, `/tmp/stage/usr/local/bin/cleaner --dry-run`) and confirm resolved path in output.
4. Remove system config; on checkout installs confirm script-adjacent `cleaner.conf` fallback.

## Optional real PM / sudo (non-CI)

| Step | Command | Warning |
|------|---------|---------|
| pacman_clean dry-run | config with `action:pacman_clean`, `--dry-run` | irreversible when not dry-run; outside HOME is allowed; a clean needs root and skips that target if privileges are unavailable |
| apt_clean | `action:apt_clean` on Debian family | requires sudo |
| dnf_clean | `action:dnf_clean` on Fedora family | requires sudo |
