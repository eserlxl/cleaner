# Installation

How to install, upgrade, and uninstall `cleaner`, where it looks for its configuration, and what it needs at runtime. For the daily timer, see [Daily cleanup](../README.md#daily-cleanup).

## Installing

The tool is a single self-contained script. Run it directly from a checkout (`./cleaner.sh`) or install it system-wide with `make` or the POSIX-sh `install.sh` wrapper (`PREFIX` defaults to `/usr/local`, and `DESTDIR` is honored for staged packaging). Both installers copy the six systemd user units from `examples/systemd/` (mode `0644`) **without enabling them**:

| Variable | Default | Installs |
|----------|---------|----------|
| `PREFIX` | `/usr/local` | base install prefix |
| `BINDIR` | `$PREFIX/bin` | `cleaner.sh`, installed as the `cleaner` command |
| `SYSCONFDIR` | `/etc` | system config at `$SYSCONFDIR/linux-cleaner/cleaner.conf` |
| `MANDIR` | `$PREFIX/share/man` | the `cleaner(1)` man page (`man1/cleaner.1`) |
| `DATADIR` | `$PREFIX/share` | `LICENSE` under `$DATADIR/licenses/linux-cleaner/`; environment template at `$DATADIR/$PKGNAME/linux-cleaner.env.example` (`PKGNAME=linux-cleaner` by default), mode `0644` |
| `SYSTEMDUSERUNITDIR` | `$PREFIX/lib/systemd/user` | the six systemd user units (`linux-cleaner-clean`, `linux-cleaner-retention`, and `linux-cleaner-monitor` `.service` and `.timer`; mode `0644`, not enabled) |

```sh
sudo make install                   # install under /usr/local (default PREFIX)
sudo make install PREFIX=/usr        # install under /usr (standard distro layout)
make install DESTDIR=/tmp/stage      # stage into a packaging root
sudo ./install.sh install            # POSIX-sh alternative (honors PREFIX and DESTDIR)
systemctl --user disable --now linux-cleaner-clean.timer linux-cleaner-retention.timer linux-cleaner-monitor.timer  # before uninstall
sudo make uninstall                  # remove installed files (system config is preserved)
systemctl --user daemon-reload       # after uninstall
```

The `systemctl --user` commands are per user: each user who enabled the timers runs them. Uninstall only removes files, so enabled-unit links and loaded timer state remain otherwise.

Copy `/usr/local/share/linux-cleaner/linux-cleaner.env.example` (or `/usr/share/linux-cleaner/linux-cleaner.env.example` with distro `PREFIX=/usr`) to `~/.config/linux-cleaner/env` to customize the cleanup service. A checkout can use `examples/linux-cleaner.env.example`. Custom `DATADIR` and `PKGNAME` move the installed template accordingly. Uninstall removes the shipped template and removes its directory only if empty; user environment copies, system config, and unrelated sibling files are preserved.

For Arch Linux (`PKGBUILD`), `package()` runs `make install DESTDIR="$pkgdir" PREFIX=/usr`, placing the command at `/usr/bin/cleaner` and the user units at `/usr/lib/systemd/user/`. See [RELEASING.md](../RELEASING.md#ordered-aur-packaging-checklist) and [docs/packager-handoff.md](packager-handoff.md).

A reinstall never overwrites an existing `/etc/linux-cleaner/cleaner.conf`; it writes `/etc/linux-cleaner/cleaner.conf.example` alongside it instead.

## Switching from `make install` to a package

`make uninstall` keeps `/etc/linux-cleaner/cleaner.conf`, which no package owns, so pacman then refuses to install with "exists in filesystem". After uninstalling, back up that file if you edited it, then move or remove it; the package installs its own copy and keeps your later edits (`backup=`). If the unit files are already gone, `systemctl --user disable --now` fails: run `systemctl --user stop linux-cleaner-clean.timer` (and the other timers you enabled), delete the stale `~/.config/systemd/user/timers.target.wants/linux-cleaner-*.timer` links, and run `systemctl --user daemon-reload`. Before re-enabling the timer, read the catch-up warning under [Daily cleanup](../README.md#daily-cleanup).

## Configuration file lookup

At runtime, the configuration file is resolved in this order:
1. `-c, --config FILE`
2. `LINUX_CLEANER_CONFIG`
3. `${XDG_CONFIG_HOME:-$HOME/.config}/linux-cleaner/cleaner.conf`
4. `/etc/linux-cleaner/cleaner.conf`
5. `cleaner.conf` beside the script (development checkout)

Run `cleaner --init-config` to copy the active config to `${XDG_CONFIG_HOME:-~/.config}/linux-cleaner/cleaner.conf` (it never overwrites), then edit it.

## Supported platforms and requirements

`cleaner` requires Linux with a **GNU userland** (`bash`, GNU `coreutils` for `du -sb`, `stat -c`, `realpath`, and GNU `findutils` for `find -print0`/`-quit`). On a non-GNU userland it refuses `--clean`/`--trash` with an error while still allowing a best-effort `--dry-run` preview.

| Requirement | Source | Notes |
|-------------|--------|-------|
| `bash` | `PKGBUILD depends` | Script interpreter |
| `findutils` | `PKGBUILD depends` | Age filter and bounded wildcard discovery |
| `coreutils` | `PKGBUILD depends` | `du`, `stat`, `realpath`, `rm`, etc. |
| `pgrep` (`procps`/`procps-ng`) | conditional runtime | Required for targets with `CHECK_PROCESSES`; missing or failed queries skip those targets before sizing, sudo or cleanup. Targets without process checks still work. |
| `pacman-contrib` | `PKGBUILD optdepends` | Required for `action:paccache_keep*` (`paccache` binary) |
| `sudo` | runtime | Required for root-owned paths and predefined `action:*` system package-cache commands |
