# Manual smoke checklist

## Hermetic test boundaries

The hermetic suite stubs `sudo`, `pgrep`, `paccache`, and `pacman` under mock `$HOME`. It does not cover live `/etc/linux-cleaner/cleaner.conf` resolution, real sudo prompts, or race-sensitive TOCTOU.

## /etc config resolution (maintainer)

1. Install to DESTDIR or VM (`make install DESTDIR=/tmp/stage`).
2. Place config at `/etc/linux-cleaner/cleaner.conf`.
3. Run `cleaner --dry-run` without `-c` and confirm resolved path in output.
4. Remove system config; on checkout installs confirm script-adjacent `cleaner.conf` fallback.

## Optional real PM / sudo (non-CI)

| Step | Command | Warning |
|------|---------|---------|
| pacman_clean dry-run | config with `action:pacman_clean`, `--dry-run --allow-outside-home` | irreversible when not dry-run |
| apt_clean | `action:apt_clean` on Debian family | requires sudo |
| dnf_clean | `action:dnf_clean` on Fedora family | requires sudo |
