# Packager handoff checklist

Pre-release checklist for AUR/distro packagers. Complete every row before publishing.

## Prerequisites

- [ ] `make check` green on the release commit
- [ ] ShellCheck clean on all shell entry points

## Install parity

- [ ] README install table matches `make install` / `install.sh` behavior (see [packaging-install-parity.md](packaging-install-parity.md))
- [ ] `make install` with `PREFIX=/usr` ships these user units under `/usr/lib/systemd/user` and does not enable them: `linux-cleaner-clean.service`, `linux-cleaner-clean.timer`, `linux-cleaner-retention.service`, `linux-cleaner-retention.timer`, `linux-cleaner-monitor.service`, `linux-cleaner-monitor.timer`
- [ ] Removal docs (`make uninstall`, `pacman -R`) tell each user who enabled the timers to first run `systemctl --user disable --now linux-cleaner-clean.timer linux-cleaner-retention.timer linux-cleaner-monitor.timer` and `systemctl --user daemon-reload` after removal
- [ ] `linux-cleaner.install` (`install=` in `PKGBUILD`) only prints the opt-in timer hint from `post_install`: no `systemctl` call, no `post_upgrade`; it ships to the AUR repo with `PKGBUILD` and `.SRCINFO`
- [ ] `PKGBUILD` `depends` (`bash`, `findutils`, `coreutils`) and `optdepends` (`pacman-contrib`) align with README Supported Platforms

## Version consistency

- [ ] `cleaner.sh --version` == `PKGBUILD pkgver` == `.SRCINFO pkgver` == CHANGELOG top version
- [ ] `cleaner.1` `.TH` version matches

## AUR gate

- [ ] Remote tag exists before `updpkgsums`
- [ ] `sha256sums` is **not** `SKIP` (see [RELEASING.md](../RELEASING.md#ordered-aur-packaging-checklist))
- [ ] `makepkg -f` succeeds locally
- [ ] `namcap PKGBUILD` and `namcap *.pkg.tar.zst` clean

## Action contract

- [ ] README action table matches `cleaner.sh` enumeration (see [action-registry-governance.md](action-registry-governance.md))

## Distro smoke log

- [ ] [distro-smoke-log.md](distro-smoke-log.md) has pass rows for target distros or documented deferral

## GNU / platform

- [ ] README documents GNU userland requirement and non-GNU refusal behavior

## Sign-off (v1.3.0)

| Row | Status | Date | Initials |
|-----|--------|------|----------|
| Prerequisites | pass (hermetic) | 2026-07-15 | — |
| Install parity | pass (drift guards) | 2026-07-15 | — |
| Version consistency | pass (1.3.0) | 2026-07-15 | — |
| AUR gate | deferred (tag pending) | 2026-07-15 | — |
| Action contract | pass | 2026-07-15 | — |
| Distro smoke | template ready | 2026-07-15 | — |
| GNU / platform | pass | 2026-07-15 | — |
