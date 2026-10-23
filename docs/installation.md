# Installation

How to install, upgrade, and uninstall `cleaner`, where it looks for its configuration, and what it needs at runtime. For the daily timer, see [Daily cleanup](../README.md#daily-cleanup).

## Installing

The tool is a single self-contained script. Run it directly from a checkout (`./cleaner.sh`) or install it system-wide with `make` or the POSIX-sh `install.sh` wrapper (`PREFIX` defaults to `/usr/local`, and `DESTDIR` is honored for staged packaging). Both installers copy the six systemd user units from `examples/systemd/` (mode `0644`) **without enabling them**:

| Variable | Default | Installs |
|----------|---------|----------|
| `PREFIX` | `/usr/local` | base install prefix |
| `BINDIR` | `$PREFIX/bin` | `cleaner.sh`, installed as the `cleaner` command |
| `SYSCONFDIR` | `/etc` | system config at `$SYSCONFDIR/$PKGNAME/cleaner.conf`; the runtime's system-wide search location is fixed at `/etc/linux-cleaner/cleaner.conf`, so with another `SYSCONFDIR` or `PKGNAME` pass `--config` or set `LINUX_CLEANER_CONFIG` |
| `MANDIR` | `$PREFIX/share/man` | the `cleaner(1)` man page (`man1/cleaner.1`) |
| `DATADIR` | `$PREFIX/share` | `LICENSE` under `$DATADIR/licenses/linux-cleaner/`; environment template at `$DATADIR/$PKGNAME/linux-cleaner.env.example` (`PKGNAME=linux-cleaner` by default), bash completion at `$DATADIR/bash-completion/completions/cleaner` (`$BINNAME`), zsh completion at `$DATADIR/zsh/site-functions/_cleaner` (`_$BINNAME`), and fish completion at `$DATADIR/fish/vendor_completions.d/cleaner.fish` (`$BINNAME.fish`), all mode `0644` |
| `SYSTEMDUSERUNITDIR` | `$PREFIX/lib/systemd/user` | the six systemd user units (`linux-cleaner-clean`, `linux-cleaner-retention`, and `linux-cleaner-monitor` `.service` and `.timer`; mode `0644`, not enabled; with a renamed `BINNAME` the services run `/usr/bin/env $BINNAME`) |

```sh
sudo make install                   # install under /usr/local (default PREFIX)
sudo make install PREFIX=/usr        # install under /usr (standard distro layout)
make install DESTDIR=/tmp/stage      # stage into a packaging root
sudo ./install.sh install            # POSIX-sh alternative (honors PREFIX and DESTDIR)
systemctl --user disable --now linux-cleaner-clean.timer linux-cleaner-retention.timer linux-cleaner-monitor.timer  # before uninstall
sudo make uninstall                  # remove installed files, including a shipped cleaner.conf.example (system config is preserved)
systemctl --user daemon-reload       # after uninstall
```

The `systemctl --user` commands are per user: each user who enabled the timers runs them. Uninstall only removes files, so enabled-unit links and loaded timer state remain otherwise.

Copy `/usr/local/share/linux-cleaner/linux-cleaner.env.example` (or `/usr/share/linux-cleaner/linux-cleaner.env.example` with distro `PREFIX=/usr`) to `~/.config/linux-cleaner/env` to customize the cleanup service. A checkout can use `examples/linux-cleaner.env.example`. Custom `DATADIR` and `PKGNAME` move the installed template accordingly. Uninstall removes the shipped template and removes its directory only if empty; user environment copies, system config, and unrelated sibling files are preserved.

For Arch Linux, edit `aur/aurgen.install.yaml`, tag the release, and run `aurgen aur` (`pkgver` comes from the `v<version>` tag). Test with `aurgen local` or `aurgen test`, and publish with `aurgen aur-deploy`. The generated `package()` runs `make install DESTDIR="$pkgdir" PREFIX=/usr`, placing the command at `/usr/bin/cleaner` and the user units at `/usr/lib/systemd/user/`. See [RELEASING.md](../RELEASING.md#ordered-aur-packaging-checklist) and [docs/packager-handoff.md](packager-handoff.md).

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

Steps 3-5 apply only when neither `-c, --config` nor `LINUX_CLEANER_CONFIG` names a file. When none of them exists, the error lists every searched location (`  searched: <path>` lines) and suggests `cleaner --doctor`; a file that exists but cannot be read is refused with `Error: Configuration file '<path>' is not readable`. Both exit `1` before any analysis. `cleaner --doctor` shows the file a run would use and whether it came from XDG, `/etc`, the checkout, or an explicit path, without needing the file to exist.

Run `cleaner --init-config` to copy the active config to `${XDG_CONFIG_HOME:-~/.config}/linux-cleaner/cleaner.conf` (it never overwrites), then edit it.

## Supported platforms and requirements

`cleaner` requires Linux with a **GNU userland** (`bash`, GNU `coreutils` for `du -sb`, `stat -c`, `realpath`, and GNU `findutils` for `find -print0`/`-quit`). On a non-GNU userland it refuses every real cleanup (`--clean`, `--force`, `--interactive`, or `LINUX_CLEANER_FORCE=1`, quarantine included) with an error while still allowing a best-effort `--dry-run` preview. Run `cleaner --doctor` to check the requirements below on your system: it reports the config file it would use, GNU userland support, the optional helper tools, and the systemd user timer states without needing a config or changing anything.

| Requirement | Source | Notes |
|-------------|--------|-------|
| `bash` | `aur/aurgen.install.yaml` depends | Script interpreter, 4.4 or later (waits on process substitutions) |
| `findutils` | runtime | Age filter and bounded wildcard discovery |
| `coreutils` | runtime | `du`, `stat`, `realpath`, `rm`, etc. |
| `pgrep` (`procps`/`procps-ng`) | conditional runtime | Required for targets with `CHECK_PROCESSES`; missing or failed queries skip those targets before sizing, sudo or cleanup. Targets without process checks still work. |
| `pacman-contrib` | `aur/aurgen.install.yaml` optdepends | Required for `action:paccache_keep*` (`paccache` binary) |
| `notify-send` (`libnotify`) | `aur/aurgen.install.yaml` optdepends | Required for `--notify` / `LINUX_CLEANER_NOTIFY`; without it the cleanup runs and prints one warning |
| `sudo` | runtime | Required for root-owned paths and predefined `action:*` system package-cache commands |
| `git` | `aur/aurgen.install.yaml` optdepends | Enables the git-tracked target guard; without it that guard is skipped and targets inside a Git work tree are cleaned like any other |
| `flock` (`util-linux`) | optional runtime | Takes the run lock for mutating runs; without it they proceed unlocked, and a positive `--lock-wait` exits `1` |
