# Packager handoff checklist

Pre-release checklist for AUR/distro packagers. Complete every row before publishing.

## Prerequisites

- [ ] `make check` green on the release commit
- [ ] ShellCheck clean on all shell entry points

## Install parity

- [ ] [installation.md](installation.md) install table matches `make install` / `install.sh` behavior (see [packaging-install-parity.md](packaging-install-parity.md))
- [ ] `make install` with `PREFIX=/usr` ships these user units under `/usr/lib/systemd/user` and does not enable them: `linux-cleaner-clean.service`, `linux-cleaner-clean.timer`, `linux-cleaner-retention.service`, `linux-cleaner-retention.timer`, `linux-cleaner-monitor.service`, `linux-cleaner-monitor.timer`
- [ ] `make install` ships the shell completions with mode `0644` — `$DATADIR/bash-completion/completions/cleaner`, `$DATADIR/zsh/site-functions/_cleaner` and `$DATADIR/fish/vendor_completions.d/cleaner.fish` — and `make uninstall` removes them
- [ ] Removal docs (`make uninstall`, `pacman -R`) tell each user who enabled the timers to first run `systemctl --user disable --now linux-cleaner-clean.timer linux-cleaner-retention.timer linux-cleaner-monitor.timer` and `systemctl --user daemon-reload` after removal
- [ ] Docs for switching from `make install` to the package say to move or remove the leftover `/etc/linux-cleaner/cleaner.conf` first (pacman "exists in filesystem"), how to clear a stale `timers.target.wants` link, and that `Persistent=true` runs a missed slot at once on enable
- [ ] `aur/aurgen.install.yaml` `package.install_messages` (`post_install` / `pre_remove`, printed verbatim) names the real timer unit (`linux-cleaner-clean.timer`) and has no `post_upgrade`; `aurgen aur-deploy` copies `PKGBUILD`, `.SRCINFO` and the install scriptlet into the AUR clone and pushes
- [ ] `aur/aurgen.install.yaml` `depends` (`bash`) and `optdepends` (`pacman-contrib`, `libnotify`, `git`) align with the requirements table in [installation.md](installation.md#supported-platforms-and-requirements)

## Version consistency

- [ ] `cleaner.sh --version` == CHANGELOG top version (`aurgen aur` takes `pkgver` from the `v*` tag; it is not a tracked file)
- [ ] `cleaner.1` `.TH` version matches

## AUR gate

- [ ] `vX.Y.Z` tag exists, then `aurgen aur` (see [RELEASING.md](../RELEASING.md#ordered-aur-packaging-checklist))
- [ ] `aurgen local` or `aurgen test` succeeds
- [ ] `aurgen aur-deploy` publishes `PKGBUILD`, `.SRCINFO` and the install scriptlet

## Action contract

- [ ] [configuration.md](configuration.md#action-cross-walk) action table matches `cleaner.sh` enumeration (see [action-registry-governance.md](action-registry-governance.md))

## Distro smoke log

- [ ] [distro-smoke-log.md](distro-smoke-log.md) has pass rows for target distros or documented deferral

## GNU / platform

- [ ] [installation.md](installation.md) documents GNU userland requirement and non-GNU refusal behavior

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
