# Distro smoke log

Manual cross-distro validation template. Hermetic CI does not replace these rows — record results after VM or container testing.

| Date | Distro + version | Cleaner version/commit | Config excerpt | Command | Exit code | Key log lines | Pass/Fail | Maintainer |
|------|------------------|------------------------|----------------|---------|-----------|---------------|-----------|------------|
| | Arch rolling | | `action:paccache_keep3` on `/var/cache/pacman/pkg` | `cleaner --dry-run --allow-outside-home` | | resolved config path | | |
| | Debian 12 | | `action:apt_clean` uncommented | `cleaner --dry-run --allow-outside-home` | | apt action listed | | |
| | Fedora 40 | | `action:dnf_clean` uncommented | `cleaner --dry-run --allow-outside-home` | | dnf action listed | | |
| | Ubuntu 24.04 disposable VM (no pacman/dnf) | | safe-tier pacman/apt/dnf actions on existing cache paths | `cleaner --clean --force --allow-outside-home` | 0 | absent pacman/dnf skipped; installed apt-get executes clean | | |
| | Alpine (non-GNU) | | default safe targets | `cleaner --force` | 1 | GNU guard refusal | | |

## Notes

- Use `--dry-run` first; irreversible `action:pacman_clean` only with explicit maintainer intent and `--yes-danger` if danger-tier.
- Run mutating package-manager checks only in a disposable VM with the listed config and target paths. Installed managers execute their configured actions; only absent binaries are skipped.
- Link completed rows from [packager-handoff.md](packager-handoff.md) sign-off.

Sign-off tracked in [packager-handoff.md](packager-handoff.md#sign-off-v130).
