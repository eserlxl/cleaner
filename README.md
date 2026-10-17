# Linux Cache and Temp File Cleaner

A configuration-driven Bash utility (`cleaner.sh`, installed as `cleaner`) that estimates and reclaims disk space by cleaning caches, temporary files, rotated logs, and stale build directories on Linux systems with a GNU userland. It runs in **dry-run mode by default** at the `safe` risk ceiling, blocks critical system directories, refuses symlinks, skips caches of running applications, and can optionally move files to a restorable quarantine before permanent deletion.

## Quick start

```sh
cleaner                 # preview safe targets and estimated savings (dry-run default)
cleaner --clean         # clean safe targets after a single confirmation prompt
cleaner --report        # view the saved plan and result from the last cleanup
```

Running from a repository checkout without installing works the same way (`./cleaner.sh`, `./cleaner.sh --clean`, `./cleaner.sh --report`).

---

## Installation

The tool is a single self-contained script. Run it directly from a checkout (`./cleaner.sh`) or install it system-wide with `make` or the POSIX-sh `install.sh` wrapper (`PREFIX` defaults to `/usr/local`, and `DESTDIR` is honored for staged packaging). Both installers copy the six systemd user units from `examples/systemd/` (mode `0644`) **without enabling them**:

| Variable | Default | Installs |
|----------|---------|----------|
| `PREFIX` | `/usr/local` | base install prefix |
| `BINDIR` | `$PREFIX/bin` | `cleaner.sh`, installed as the `cleaner` command |
| `SYSCONFDIR` | `/etc` | system config at `$SYSCONFDIR/linux-cleaner/cleaner.conf` |
| `MANDIR` | `$PREFIX/share/man` | the `cleaner(1)` man page (`man1/cleaner.1`) |
| `DATADIR` | `$PREFIX/share` | `LICENSE` under `$DATADIR/licenses/linux-cleaner/` |
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

**Switching from `make install` to a distro or AUR package.** `make uninstall` keeps `/etc/linux-cleaner/cleaner.conf`, which no package owns, so pacman then refuses to install with "exists in filesystem". After uninstalling, back up that file if you edited it, then move or remove it; the package installs its own copy and keeps your later edits (`backup=`). If the unit files are already gone, `systemctl --user disable --now` fails: run `systemctl --user stop linux-cleaner-clean.timer` (and the other timers you enabled), delete the stale `~/.config/systemd/user/timers.target.wants/linux-cleaner-*.timer` links, and run `systemctl --user daemon-reload`. Before re-enabling the timer, read the catch-up warning under [Daily cleanup](#daily-cleanup).

For Arch Linux (`PKGBUILD`), `package()` runs `make install DESTDIR="$pkgdir" PREFIX=/usr`, placing the command at `/usr/bin/cleaner` and the user units at `/usr/lib/systemd/user/`. See [RELEASING.md](RELEASING.md#ordered-aur-packaging-checklist) and [docs/packager-handoff.md](docs/packager-handoff.md).

A reinstall never overwrites an existing `/etc/linux-cleaner/cleaner.conf`; it writes `/etc/linux-cleaner/cleaner.conf.example` alongside it instead.

At runtime, the configuration file is resolved in this order:
1. `-c, --config FILE`
2. `LINUX_CLEANER_CONFIG`
3. `${XDG_CONFIG_HOME:-$HOME/.config}/linux-cleaner/cleaner.conf`
4. `/etc/linux-cleaner/cleaner.conf`
5. `cleaner.conf` beside the script (development checkout)

### Supported platforms & requirements

`cleaner` requires Linux with a **GNU userland** (`bash`, GNU `coreutils` for `du -sb`, `stat -c`, `realpath`, and GNU `findutils` for `find -print0`/`-quit`). On a non-GNU userland it refuses `--clean`/`--trash` with an error while still allowing a best-effort `--dry-run` preview.

| Requirement | Source | Notes |
|-------------|--------|-------|
| `bash` | `PKGBUILD depends` | Script interpreter |
| `findutils` | `PKGBUILD depends` | Age filter and bounded wildcard discovery |
| `coreutils` | `PKGBUILD depends` | `du`, `stat`, `realpath`, `rm`, etc. |
| `pacman-contrib` | `PKGBUILD optdepends` | Required for `action:paccache_keep*` (`paccache` binary) |
| `sudo` | runtime | Required for root-owned paths and predefined `action:*` system package-cache commands |

---

## Daily cleanup

Enable the daily systemd user timer (runs `cleaner --clean --force` at 03:00 daily and permanently deletes `safe` targets):

```sh
systemctl --user enable --now linux-cleaner-clean.timer
```

Nothing is enabled on install; the Arch package only prints this command as a hint. Preview first with `cleaner --dry-run`. The timer has `Persistent=true`: if a 03:00 slot was missed since its last recorded run (for example a stamp left in `~/.local/share/systemd/timers/` by an earlier install), enabling it runs a cleanup **immediately**, not at the next 03:00.

To customize the scheduled cleanup, copy `examples/linux-cleaner.env.example` to `~/.config/linux-cleaner/env`. **This environment file is read only by `linux-cleaner-clean.service` (`EnvironmentFile=-%h/.config/linux-cleaner/env`), not by manual `cleaner` runs or the other systemd units.** Use literal absolute paths inside `~/.config/linux-cleaner/env` because systemd does not expand `$HOME` there.

Key settings in `~/.config/linux-cleaner/env`:
- **`LINUX_CLEANER_RISK=safe`** (default): Keep unattended runs on `safe` targets, or raise to `medium` if you accept unattended deletion of medium-tier data.
- **`LINUX_CLEANER_TRASH=1`** (opt-in quarantine): Move files into `~/.cache/linux-cleaner/quarantine/` instead of deleting them permanently. Whenever you enable `LINUX_CLEANER_TRASH=1`, also enable the weekly retention timer (`cleaner --purge-sessions older-than:30 --force` on Sundays at 04:00) so quarantine disk usage stays bounded:

```sh
systemctl --user enable --now linux-cleaner-retention.timer
```

An optional six-hourly JSON preview timer (`linux-cleaner-monitor.timer`) is also installed. Inspect the last cleanup or service logs at any time:

```sh
cleaner --report                                       # saved plan and result from the last cleanup
journalctl --user -u linux-cleaner-clean.service       # systemd journal output
```

See [RUNBOOK.md](RUNBOOK.md) for cron recipes, user linger notes, and unattended environment examples.

---

## Risk levels

Every target in `cleaner.conf` has a risk level (`safe`, `medium`, or `danger`), and `-r, --risk LEVEL` (or `LINUX_CLEANER_RISK`) sets the maximum tier to include (default: `safe`):

- **`safe` (default)**: Purely regenerable caches, temporary scratch directories, rotated logs, and idle C/C++ build trees. Deleting them does not lose user work or history.
- **`medium`**: Browser caches, package-manager caches, and **non-cache user records or artifacts that cannot be recovered after permanent deletion**. In the shipped `cleaner.conf`, `medium` rows are:
  - **AI assistant transcripts and generated/downloaded artifacts**: Codex CLI conversation transcripts (`$HOME/.codex/sessions`, >7 days) and generated images (`$HOME/.codex/generated_images`, >7 days), Cursor chat transcripts (`$HOME/.cursor/chats`, >7 days), and Grok CLI session transcripts (`$HOME/.grok/sessions`, >30 days) and downloads (`$HOME/.grok/downloads`, >30 days).
  - **Desktop Trash**: `$HOME/.local/share/Trash` items older than 30 days.
  - **Browser caches**: Chromium (>3 days), Firefox (>7 days), and Google Chrome (>7 days) under `$HOME/.cache`.
  - **Package and crate caches**: Cargo registry download cache (`$HOME/.cargo/registry/cache`, >30 days) and Pacman package cache (`action:paccache_keep1` on `/var/cache/pacman/pkg`), plus commented cross-distro package-cache actions (`apt`, `dnf`, `zypper`, `apk`).
  - **Local VM image**: Claude Desktop local-agent VM image (`$HOME/.config/Claude/vm_bundles/claudevm.bundle/rootfs.img`, >30 days; rebuilds from `rootfs.img.zst` beside it).
- **`danger`**: Targets that can cause significant state loss or aggressive system-wide purges. They always require an interactive confirmation prompt even under `--force`, unless `--yes-danger` (`LINUX_CLEANER_YES_DANGER=1`) is also passed. **The shipped `cleaner.conf` has no active `danger` rows** (only a commented `action:pacman_clean` example).

---

## What gets cleaned

See [`cleaner.conf`](cleaner.conf) for the authoritative list of targets, age thresholds, and exclusions, or run `cleaner --list-targets` to inspect the active inventory. The shipped configuration covers:

- **Developer & language caches (`safe`, `medium` for Cargo)**: npm, Yarn, Bun (files older than 30 days), pnpm (`pnpm store prune`), pip, uv (`uv cache prune`), Hugging Face hub (`hf cache prune --yes`), Aurman, Go build cache, clangd, TypeScript, Prettier, VSCode C++ extension cache, and Cargo registry cache.
- **GPU & desktop caches (`safe`, `medium` for Trash)**: NVIDIA compute cache, Mesa shader cache, legacy and modern desktop thumbnails, and desktop Trash (>30 days).
- **Web browser caches (`medium`)**: Chromium, Firefox, and Google Chrome caches under `$HOME/.cache`.
- **AI assistant & editor caches, logs, and transcripts (`safe` for caches/logs, `medium` for transcripts/media/VM image)**: Gemini Temp, Cursor, Antigravity, Claude Desktop, Codex CLI/Desktop, Grok CLI, and Hermes caches/logs/sessions, plus per-project AI debug/log directories under `/opt` (`.gemini/model_debug_logs`, `.codex/logs`, `.remember/logs`). Durable configuration, rules, memory stores, SQLite state databases, and `$HOME/.claude/projects` are deliberately excluded.
- **Idle C/C++ build directories (`safe`)**: `/opt/**/build*` and `/opt/**/cmake-build*` verified by `filter:cxx_build` and idle for more than 14 days.
- **System package-manager caches (`medium`)**: `/var/cache/pacman/pkg` (`action:paccache_keep1`), plus optional commented rows for `pacman_clean`, `apt_clean`, `dnf_clean`, `zypper_clean`, and `apk_clean`. Because an action whose package manager is not installed is skipped cleanly without failing the run, the same `cleaner.conf` is portable across distributions.

---

## Safety model

Security threat model: [docs/threat-model.md](docs/threat-model.md).

1. **Dry-run by default**: Running `cleaner` without `--clean`, `--force`, `--interactive`, or `LINUX_CLEANER_FORCE=1` never modifies the filesystem.
2. **System directories are `UNSAFE`**: Targets resolving to `/`, `$HOME` itself, any target containing `$HOME` (an ancestor of it), `/home`, `/root`, `/usr`, `/var`, `/etc`, `/boot`, `/sys`, `/proc`, `/dev`, `/bin`, `/sbin`, `/opt`, `/srv`, `/tmp`, `/run`, `/mnt`, `/media`, or `/lib*` are flagged `[UNSAFE]` and skipped. Descendants outside `$HOME` (such as `/opt/...` or `/var/cache/...`) are allowed.
3. **Symlink refusal & physical canonicalization**: If a target path is itself a symlink, it is flagged `[SYMLINK]` and refused. Target paths are physically canonicalized through their closest existing parent directory to prevent `..` traversal or symlink escapes.
4. **No `eval`, no shell globbing**: Path expansion substitutes only whole-token `$HOME`, leading `~`, and `$USER`. Wildcards are evaluated by `find` below a literal prefix, never by the shell or `eval`.
5. **Running-process checks**: Targets with `CHECK_PROCESSES` are skipped (`[BLOCKED]`) while any listed process or `cmdline:<pattern>` is active.
6. **Whole-directory idle check for C/C++ builds**: With `filter:cxx_build` and `MIN_AGE_DAYS > 0` (14 days in `cleaner.conf`), the cleaner checks whether **any** file inside the build tree was modified within the threshold. Active builds are left completely untouched; only build trees idle for the full 14 days are removed as a whole, preventing broken half-cleaned build directories.
7. **Git-tracked file guard**: When `git` is available and the cleaner runs as a non-root user on a non-sudo target, any target inside a Git work tree that contains git-tracked files is skipped (`[SKIP]`).
8. **Unprivileged root-target skip**: Targets that require `sudo` (unreadable paths, unwritable parent directories outside `$HOME`, or system package-cache `action:*` commands) are skipped with a stderr warning when root privileges are unavailable; non-interactive runs (no TTY on stdin) never prompt for a password.
9. **User-defined `protect|PATH` directives**: Any target that equals, lies inside, or contains a configured `protect|PATH` directory is skipped before sizing or deletion.
10. **Restore conflict guard**: Restoring a quarantine session never overwrites an existing destination file or directory; conflicts are reported and kept in quarantine.

---

## Configuration

Each active target row in `cleaner.conf` has **5 to 7 pipe-delimited fields** (`RISK_LEVEL`, `NAME`, `PATH_EXPRESSION`, `DESCRIPTION`, and `MIN_AGE_DAYS` are required; `CHECK_PROCESSES` and `CUSTOM_ACTION` are optional):

```text
RISK_LEVEL|NAME|PATH_EXPRESSION|DESCRIPTION|MIN_AGE_DAYS|CHECK_PROCESSES|CUSTOM_ACTION
```

- **`RISK_LEVEL`**: `safe`, `medium`, or `danger`.
- **`NAME`**: Non-empty human-readable target name (e.g. `NPM Cache`).
- **`PATH_EXPRESSION`**: Non-empty path to clean. Supports `$HOME`, leading `~`, and `$USER` whole-token expansion, plus `*`, `?`, and `**` directory wildcards.
- **`DESCRIPTION`**: Brief explanation of what the target cleans.
- **`MIN_AGE_DAYS`**: Numeric minimum age in days (`find -mtime +N`), or `0`/empty to clean the target regardless of age. When paired with `filter:cxx_build`, `MIN_AGE_DAYS > 0` is an idle threshold for the directory as a whole.
- **`CHECK_PROCESSES`**: (Optional) Comma-separated process names (`pgrep -x`, comparing the first 15 characters for longer plain names) or `cmdline:<pattern>` tokens matching the full command line. Use `cmdline:<install-path>` (e.g. `cmdline:/usr/share/cursor`) for Electron or Node apps that do not run under their own binary name. The cleaner excludes its own process ancestry, descendants, and exited PIDs so its own invocation never self-blocks.
- **`CUSTOM_ACTION`**: (Optional) Holds at most **one** token — a predefined action, a build filter, or a per-row exclusion list (they cannot be combined):
  - `action:paccache_keep1` (`sudo paccache -rk1`), `action:paccache_keep2` (`sudo paccache -rk2`), `action:paccache_keep3` (`sudo paccache -rk3`)
  - `action:pacman_clean` (`sudo pacman -Sc --noconfirm`)
  - `action:apt_clean` (`sudo apt-get clean`)
  - `action:dnf_clean` (`sudo dnf clean all`)
  - `action:zypper_clean` (`sudo zypper clean -a`)
  - `action:apk_clean` (`sudo apk cache clean`)
  - `action:uv_cache_prune` (`uv cache prune`), `action:pnpm_store_prune` (`pnpm store prune`), `action:hf_cache_prune` (`hf cache prune --yes`)
  - `filter:cxx_build`: Keeps a literal path or wildcard match only if it contains a C/C++ build-system marker (`CMakeCache.txt`, `CMakeFiles`, `build.ninja`, `meson-info`, `compile_commands.json`, or `.qmake.stash`) directly or one level below.
  - `exclude:NAME[,NAME...]`: Adds comma-separated `find` glob/path exclusions for this row only (merging with `-e/--exclude` / `LINUX_CLEANER_EXCLUDE`). Preserves matching files and directories during dry-run sizing, deletion, quarantine, and empty-directory pruning, and processes files individually even when `MIN_AGE_DAYS` is `0`.

> [!WARNING]
> Predefined `action:*` commands bypass quarantine (`--trash`) and run directly, resulting in irreversible deletion. System package-cache actions run via `sudo`; user-level prune actions (`action:uv_cache_prune`, `action:pnpm_store_prune`, `action:hf_cache_prune`) run as the invoking user without `sudo` and measure their freed size on disk at run time. See [docs/action-registry-governance.md](docs/action-registry-governance.md).

### Action cross-walk

| `action:*` | `cleaner.sh` command | `cleaner.conf` target | `cleaner.1` |
|------------|---------------------|------------------------|-------------|
| `action:paccache_keep1` | `sudo paccache -rk1` | `Pacman Cache (Keep 1)` | CONFIGURATION |
| `action:paccache_keep2` | `sudo paccache -rk2` | (supported) | CONFIGURATION |
| `action:paccache_keep3` | `sudo paccache -rk3` | header comment example | CONFIGURATION |
| `action:pacman_clean` | `sudo pacman -Sc --noconfirm` | `Pacman Cache (Purge All)` (commented) | CONFIGURATION |
| `action:apt_clean` | `sudo apt-get clean` | `APT Cache Clean` (commented) | CONFIGURATION |
| `action:dnf_clean` | `sudo dnf clean all` | `DNF Cache Clean` (commented) | CONFIGURATION |
| `action:zypper_clean` | `sudo zypper clean -a` | `Zypper Cache Clean` (commented) | CONFIGURATION |
| `action:apk_clean` | `sudo apk cache clean` | `APK Cache Clean` (commented) | CONFIGURATION |
| `action:uv_cache_prune` | `uv cache prune --cache-dir PATH` | `UV Cache` | CONFIGURATION |
| `action:pnpm_store_prune` | `pnpm store prune --store-dir PATH` | `PNPM Store` | CONFIGURATION |
| `action:hf_cache_prune` | `hf cache prune --yes --cache-dir PATH` | `Hugging Face Cache` | CONFIGURATION |

User-level prune actions (`action:uv_cache_prune`, `action:pnpm_store_prune`, `action:hf_cache_prune`) run as the invoking user without `sudo` against the target's configured PATH (`uv --cache-dir`, `pnpm --store-dir`, `hf --cache-dir`), and their freed size is measured on disk from the filesystem free-space change rather than directory `du`.

### Wildcard paths

A `PATH_EXPRESSION` containing `*` or `?` expands into **one independent target per matching directory**, each checked individually by the safety pipeline:

- **Fixed depth by default**: Matches must sit at the exact depth after the literal prefix (e.g. `$HOME/src/*/build*` matches `~/src/app/build` but not `~/src/a/b/build`).
- **`**` spans nesting levels**: A `**` component matches one or more directory levels, bounded at **10 levels** (`GLOB_RECURSION_MAX_DEPTH=10`) below the literal prefix.
- **Directories only**: Wildcard expansion matches directories (`-type d`), never individual files.
- **Safe path identity**: A wildcard in the first path component (`/*/build`) is refused with a warning; matches containing newlines, `|`, leading/trailing whitespace, or literal `$HOME`/`~`/`$USER` tokens are skipped with a warning; a pattern with no matches is not an error.

> [!WARNING]
> One wildcard line can expand to many targets. Always preview with `cleaner --dry-run` and `cleaner --list-targets` before cleaning.

### Protecting directories

To keep the cleaner out of a directory tree entirely, add a two-field `protect|PATH` line to `cleaner.conf`:

```text
protect|$HOME/Projects
protect|/opt/important
```

Any target whose canonical path equals `PATH`, lies inside `PATH`, or contains `PATH` (matched on whole path components, so `protect|/opt/a` does not match `/opt/ab`) is skipped as a whole. For example, `protect|/opt/work/app/build` prevents the `/opt/**/build*` row from cleaning that build directory while leaving sibling projects eligible.

- `PATH` supports `$HOME`, `$USER`, and leading `~`, must be absolute after expansion, cannot contain wildcards (`*`, `?`, `[`), and does not need to exist yet. Symlinks are resolved physically.
- `protect` lines are not listed by `--list-targets` or counted as targets by `--check-config`.
- Skipped targets appear under `Protected (by config):` in the plan report, as `[PROTECTED]` under `--debug`, and with `"status": "protected"` in `--dry-run --json`.

### Validation (`--check-config`)

Validate a configuration file without scanning disk usage:

```sh
cleaner --check-config --config cleaner.conf
# -> OK: 44 targets in cleaner.conf
```

Malformed lines fail with a line-numbered error (`Error: <config-file>:<lineno>: ...` or `<config-file>:<lineno>: Error: ...`).

### Example `cleaner.conf`

```text
protect|$HOME/Projects
safe|NPM Cache|$HOME/.npm/_cacache|NPM dependency cache files|0|node,npm|
safe|C++ Build Dirs|/opt/**/build*|Per-project build output|14||filter:cxx_build
medium|App Sessions|$HOME/.local/share/example-app/sessions|Old session logs, keep notes|7||exclude:notes
medium|Chromium Cache|$HOME/.cache/chromium|Chromium browser cache files|3|chromium|
medium|Pacman Cache (Keep 1)|/var/cache/pacman/pkg|Retains latest version of package cache using paccache|0||action:paccache_keep1
danger|Chromium IndexedDB|$HOME/.config/chromium/Default/IndexedDB|Site-specific database storage|30|chromium|
```

---

## Options, environment variables, and exit status

### Options

- **`-c, --config FILE`**: Use a custom configuration file instead of the default discovery order.
- **`-d, --dry-run`**: Preview potential space savings without deleting anything (default).
- **`--clean`**: Enable cleanup with a single summary confirmation prompt. Cleanup is also enabled by `-f/--force`, `-i/--interactive`, or a truthy `LINUX_CLEANER_FORCE` (the last of `--dry-run`, `--clean`, `--force`, or `--interactive` on the command line wins).
- **`-i, --interactive`**: Enable cleanup and prompt before cleaning each target individually.
- **`-f, --force`**: Enable cleanup and skip confirmation prompts (except `danger` targets and non-forced session purges).
- **`--yes-danger`**: Bypass the manual confirmation prompt for `danger` targets.
- **`-t, --trash`**: Move cleaned files into a restorable quarantine session under `~/.cache/linux-cleaner/quarantine/<timestamp>/` instead of deleting permanently. Passing `--trash` alone keeps dry-run preview mode. Each target records one `UID`/`GID` pair in `quarantine.meta`, applied best-effort on restore (mixed ownership inside a tree is not preserved).
- **`-r, --risk LEVEL`**: Maximum risk level to process: `safe`, `medium`, or `danger` (default: `safe`).
- **`-e, --exclude PATTERNS`**: Comma-separated `find` glob/path patterns to exclude globally (e.g. `.git,*.log`). Verify exclusions with `--dry-run` first.
- **`--only-target PATTERN`**: With cleanup, process only targets whose `NAME` contains `PATTERN` (substring match); exits `1` if none match. Cannot be combined with `--restore`, `--purge-sessions`, `--list-sessions`, `--list-targets`, `--check-config`, or `--report`.
- **`--exclude-target PATTERN`**: With cleanup, skip targets whose `NAME` contains `PATTERN` (substring match); exits `1` if no targets remain. Cannot be combined with `--restore`, `--purge-sessions`, `--list-sessions`, `--list-targets`, `--check-config`, or `--report`.
- **`--list-targets`**: List configured targets (`NAME`, `risk`, `path`, `description`) without disk analysis. Read-only; requires a config file. Cannot be combined with `--restore`, `--purge-sessions`, `--list-sessions`, or `--report`.
- **`--check-config`**: Validate config syntax and exit without disk analysis. Prints `OK: N targets in <path>`. Cannot be combined with `--restore`, `--purge-sessions`, `--list-sessions`, `--list-targets`, or `--report`.
- **`--list-sessions`**: List quarantine sessions (timestamp, size, date, and each item's `full`/`aged` type and original path). Read-only; requires no config file.
- **`--restore SESSION`**: Restore files from a quarantine session (`latest` or an immediate child timestamp directory name; `/` and `.`/`..` are rejected). Rejects an explicit `--dry-run`.
- **`--only PATTERN`**: Used with `--restore`: restore only targets whose original path contains `PATTERN`, keeping remaining targets and rewriting `quarantine.meta` so a later `--restore` succeeds. Exits `1` if nothing matches or if passed without `--restore`.
- **`--purge-sessions SESSION`**: Permanently delete quarantine sessions (`latest`, `all`, `older-than:DAYS`, or a timestamp directory name). Prompts for confirmation naming every target unless `-f/--force` is set. `older-than:DAYS` exits `0` when no sessions match. Rejects an explicit `--dry-run`.
- **`--report`**: Print the saved last cleanup report from `${XDG_STATE_HOME:-$HOME/.local/state}/linux-cleaner/last-report.txt` and exit (prints `No cleanup report yet.` on stderr and exits `1` if absent). Read-only; requires no config file. Cannot be combined with `--restore`, `--purge-sessions`, `--list-sessions`, `--list-targets`, or `--check-config`.
- **`--log [FILE]`**: Append an operation log under `$HOME` (default: `~/.cache/linux-cleaner/operations.log`).
- **`-q, --quiet`**: Suppress headers, per-target status lines, and the on-screen plan report; keep errors, savings total, result report, and final summary.
- **`--debug`**: Show per-target `[FOUND]`, `[CLEAN]`, and `[PROTECTED]` lines (hidden by default; overridden by `--quiet`).
- **`--json`**: Emit machine-readable JSON (implies `--quiet`). Valid only with `--dry-run` (`config`, `total_reclaimable_bytes`, `total_reclaimable_human`, per-target `name`/`path`/`risk`/`bytes`/`size_human`/`status`/`description`/`min_age_days`/`size_at_run_time`; `size_at_run_time` is `true` for user-level prune actions, whose size is measured only when they run), `--list-targets` (`config`, per-target `name`/`risk`/`path`/`description`/`min_age_days`/`check_processes`/`custom_action`), or `--list-sessions` (`sessions` array of `timestamp`/`size_bytes`/`size_human`/`date`/`targets`). Consumers should tolerate unknown JSON keys for forward compatibility.
- **`--allow-outside-home`**: Deprecated no-op (prints one warning on stderr; targets outside `$HOME` are always allowed).
- **`-h, --help`**: Display help and exit.
- **`-V, --version`**: Print version and exit.

### Environment variables

| Variable | Effect |
|----------|--------|
| `LINUX_CLEANER_CONFIG` | Non-empty path to the configuration file (same as `--config`; overridden by `-c/--config`). |
| `LINUX_CLEANER_LOG` | Enable operation logging to the given path under `$HOME` (same as `--log`). |
| `LINUX_CLEANER_QUIET` | When `1`, `true`, or `yes`, enables `--quiet`. |
| `LINUX_CLEANER_DEBUG` | When `1`, `true`, or `yes`, enables `--debug`. |
| `LINUX_CLEANER_JSON` | When `1`, `true`, or `yes`, enables `--json` (valid with dry-run, `--list-targets`, or `--list-sessions`). |
| `LINUX_CLEANER_ONLY_TARGET` | Non-empty pattern enabling `--only-target` (overridden by CLI `--only-target`). |
| `LINUX_CLEANER_EXCLUDE_TARGET` | Non-empty pattern enabling `--exclude-target` (overridden by CLI `--exclude-target`). |
| `LINUX_CLEANER_RISK` | Sets the default `--risk` ceiling (`safe`, `medium`, or `danger`; overridden by `-r/--risk`). |
| `LINUX_CLEANER_TRASH` | When `1`, `true`, or `yes`, enables `--trash` (quarantine mode). |
| `LINUX_CLEANER_EXCLUDE` | Non-empty comma-separated glob list enabling `--exclude` (overridden by `-e/--exclude`). |
| `LINUX_CLEANER_FORCE` | When `1`, `true`, or `yes`, enables `--force` and non-interactive cleanup (an explicit CLI `--dry-run` still restores preview mode). |
| `LINUX_CLEANER_YES_DANGER` | When `1`, `true`, or `yes`, enables `--yes-danger`. |
| `LINUX_CLEANER_ALLOW_OUTSIDE_HOME` | Deprecated no-op. When `1`, `true`, or `yes`, prints one warning on stderr; targets outside `$HOME` are always allowed. |

Set `NO_COLOR` to any non-empty value to disable ANSI color codes (per [no-color.org](https://no-color.org)).

Value variables (`CONFIG`, `LOG`, `RISK`, `EXCLUDE`, `ONLY_TARGET`, `EXCLUDE_TARGET`) are replaced by their corresponding CLI flags. Boolean variables (`QUIET`, `DEBUG`, `JSON`, `TRASH`, `FORCE`, `YES_DANGER`) have no negative CLI flag; set them to `0` or unset them to disable for a single run.

### Exit status

Returns **`0`** on success and **`1` (non-zero)** on a configuration/usage error or a **failed operation** (an attempted delete, quarantine move, predefined action, restore, or session purge that did not succeed). When an operation fails during cleanup, `cleaner` reports the error on stderr, continues processing remaining targets, and exits `1`.

A **skip is not a failure** and exits **`0`**: a declined `danger` target, a target blocked by a running process, an `UNSAFE` or `protected` path, a git-tracked target, a root-requiring target when privileges are unavailable, or a predefined `action:*` whose package manager binary is not installed.

---

## Operation log and reports

### Plan and result reports (`--report`)

Every human-readable cleanup run prints a **plan report** after the savings total (mode, risk ceiling, config path, status counts, reclaimable bytes by risk, top 10 largest targets, and skipped/blocked/protected target groups). `--quiet` hides the plan report on screen.

After a non-dry-run cleanup, a **result report** prints `cleaned`, `skipped`, and `failed` counts, elapsed seconds, bytes quarantined versus permanently reclaimed, and the quarantine session path. Both reports are saved (without ANSI colors, and including the plan even under `--quiet`) to `${XDG_STATE_HOME:-$HOME/.local/state}/linux-cleaner/last-report.txt` (directory mode `0700`, refusing symlinks), including when nothing needed cleaning. Run `cleaner --report` to view the saved report. Dry-run, `--json`, and read-only modes do not write `last-report.txt`.

### Operation log (`--log` / `LINUX_CLEANER_LOG`)

Operation logging is **opt-in and off by default**:

```sh
cleaner --clean --log                                      # logs to ~/.cache/linux-cleaner/operations.log
LINUX_CLEANER_LOG=$HOME/.cache/linux-cleaner/ops.log cleaner --clean
```

- The log path supports `$HOME`, `~`, and `$USER` placeholders and **must resolve inside `$HOME`** (paths outside `$HOME` are refused and logging is disabled).
- Records one line per real cleanup target (`mode=delete|quarantine|action`), per restored target (`mode=restore`, outcome `success`/`failed`/`conflict`/`missing`), or per purged session (`mode=purge`), and never logs file contents or secrets:

```text
2026-01-01T12:00:00 mode=delete risk=safe target='NPM Cache' path='/home/you/.npm/_cacache' outcome=success
2026-01-08T09:00:00 mode=purge session='2026-01-01_12-00-00' outcome=success
```

---

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for the safety invariants and design constraints every change must preserve, and record user-facing changes under `[Unreleased]` in [CHANGELOG.md](CHANGELOG.md).

The local gate is `make check` plus ShellCheck, run before every push or release:

```bash
shellcheck cleaner.sh test_cleaner.sh install.sh release-notes.sh   # static analysis / lint
make check                            # runbook example validation + full safety suite (test_cleaner.sh)
```

The test suite (`test_cleaner.sh`) is hermetic: it stubs `sudo`, `pgrep`, `paccache`, `pacman`, `apt-get`, `dnf`, `zypper`, and `apk` and builds a mock `$HOME`, requiring only `bash`, GNU `coreutils`, GNU `findutils`, and `shellcheck` (no root, network, or Arch-specific tooling). Drift guards (man-page parity, version consistency, env mirrors, and ShellCheck file parity) run inside the hermetic suite after mock `$HOME` setup.

After cutting a release tag, verify consistency on the tagged HEAD (`git fetch --tags`, `git checkout vX.Y.Z`, `make check`); see [RELEASING.md](RELEASING.md#post-tag-local-verification).

### Further documentation

- Unattended cron and systemd operations: [RUNBOOK.md](RUNBOOK.md), `examples/systemd/`, `examples/linux-cleaner.env.example`
- Quarantine operations and recovery: [docs/QUARANTINE-OPS.md](docs/QUARANTINE-OPS.md)
- Security threat model: [docs/threat-model.md](docs/threat-model.md)
- Contract & governance docs: [docs/contract-semver-taxonomy.md](docs/contract-semver-taxonomy.md), [docs/config-field-governance.md](docs/config-field-governance.md), [docs/action-registry-governance.md](docs/action-registry-governance.md), [docs/cli-env-json-governance.md](docs/cli-env-json-governance.md), [docs/env-automation-contract.md](docs/env-automation-contract.md)
- Testing & packaging checklists: [docs/hermetic-test-guards.md](docs/hermetic-test-guards.md), [docs/test-coverage-matrix.md](docs/test-coverage-matrix.md), [docs/packager-handoff.md](docs/packager-handoff.md), [docs/packaging-install-parity.md](docs/packaging-install-parity.md), [docs/manual-smoke-checklist.md](docs/manual-smoke-checklist.md), [docs/distro-smoke-log.md](docs/distro-smoke-log.md)

---

## License

This project is licensed under the **GNU General Public License v3.0 or later** (SPDX identifier: `GPL-3.0-or-later`) — see the [LICENSE](LICENSE) file for the full text.

Copyright (C) 2026 Eser KUBALI
