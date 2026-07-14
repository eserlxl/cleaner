# Linux Cache and Temp File Cleaner

[![CI](https://github.com/eserlxl/cleaner/actions/workflows/ci.yml/badge.svg)](https://github.com/eserlxl/cleaner/actions/workflows/ci.yml)

A safe, configuration-driven Bash utility designed to estimate and reclaim disk space by cleaning up unnecessary temporary files, caches, and logs on a Linux system.

## Features

- **Dry-run by Default**: By default, the script runs in dry-run mode, printing estimated space savings without deleting any files. Use `--clean` to execute.
- **Safety Guards**: Bypasses system folders (e.g. `/`, `/usr`, `/var`, `/etc`), rejects symlinked paths directly, and blocks paths outside the user's `$HOME` unless explicitly permitted.
- **Risk Levels**: Group targets as `safe`, `medium`, or `danger`. Filter execution via `-r, --risk <level>` (default is `safe`).
- **Confirmation Guards**: High-risk targets (`danger`) require manual confirmation even under `--force`, unless the bypass flag `--yes-danger` is provided.
- **Age Filter**: Targets can specify a minimum age in days (using `find -mtime`). Only files/symlinks older than the limit are cleaned.
- **Running-Process Checks**: Skip targets if their associated applications/processes are running (e.g., skip chromium cache if Chrome is open).
- **Trash Quarantine**: Move deleted files to a quarantine folder (`~/.cache/linux-cleaner/quarantine/`) with collision prevention and path sanitization instead of deleting permanently.
- **Quarantine Restoration**: Restore files from any previous quarantine session back to their original paths, preserving original ownership (`UID` and `GID`).
- **Quarantine Purge & Retention**: Permanently delete quarantine sessions (`latest`, `all`, `older-than:DAYS`, or a specific timestamp) to reclaim the space trash mode holds, with a confirmation prompt naming every target before any irreversible deletion. The `older-than:DAYS` selector is what makes trash mode viable unattended — pair a `--trash` cron job with a periodic retention purge and quarantine stays bounded.
- **Predefined Custom Actions**: Execute specific system commands (like package cache cleaners) instead of path deletion.

---

## Configuration

By default, the script reads target definitions from `./cleaner.conf`. The format is a plain text file where each line defines a target with fields separated by pipe `|` characters:

```text
RISK_LEVEL|NAME|PATH_EXPRESSION|DESCRIPTION|MIN_AGE_DAYS|CHECK_PROCESSES|CUSTOM_ACTION
```

- **`RISK_LEVEL`**: The category of danger if cleaned: `safe`, `medium`, or `danger`.
- **`NAME`**: A human-readable identifier for the target (e.g. `NPM Cache`).
- **`PATH_EXPRESSION`**: The absolute or relative path to clean. Supports safe placeholder expansion for `$HOME`, `~`, and `$USER`.
- **`DESCRIPTION`**: A brief explanation of the files being cleaned.
- **`MIN_AGE_DAYS`**: (Optional) Only delete files/symlinks older than N days. Set to `0` or leave empty to clean immediately.
- **`CHECK_PROCESSES`**: (Optional) Comma-separated process names. If any process in the list is running, the target is skipped.
- **`CUSTOM_ACTION`**: (Optional) Predefined clean command to run instead of direct path deletion:
  - `action:paccache_keep1`: Runs `sudo paccache -rk1` (retains latest 1 version of package cache).
  - `action:paccache_keep2`: Runs `sudo paccache -rk2` (retains latest 2 versions of package cache).
  - `action:paccache_keep3`: Runs `sudo paccache -rk3` (retains latest 3 versions of package cache).
  - `action:pacman_clean`: Runs `sudo pacman -Sc --noconfirm` (purges all cached packages not currently installed).
  - `action:apt_clean`: Runs `sudo apt-get clean` (clears the downloaded APT package archive cache). Skipped if apt is not present.
  - `action:dnf_clean`: Runs `sudo dnf clean all` (clears all DNF caches). Skipped if dnf is not present.
  > [!WARNING]
  > Custom clean actions — the pacman, apt, and dnf package-cache actions — bypass quarantine/trash mode and run directly, resulting in irreversible deletion.

### Validation

Each active line must have **5 to 7 fields**. `RISK_LEVEL`, `NAME`, `PATH_EXPRESSION`, `DESCRIPTION`, and `MIN_AGE_DAYS` are required; `CHECK_PROCESSES` and `CUSTOM_ACTION` are optional. `NAME` and `PATH_EXPRESSION` must be non-empty, and a non-empty `MIN_AGE_DAYS` must be numeric (leave it empty to mean "the whole directory"). A malformed line is rejected with a line-numbered error of the form `Error: <config-file>:<lineno>: ...`, for example:

```text
Error: /etc/linux-cleaner/cleaner.conf:12: expected 5-7 fields, found 4
```

Fix it by restoring the missing `|` delimiter (or removing a stray one) on the cited line.

### Example `cleaner.conf`
```text
safe|NPM Cache|$HOME/.npm/_cacache|NPM dependency cache files|0|node,npm|
safe|Gemini Temp|$HOME/.gemini/tmp|Gemini temporary/scratch files|7|gemini|
medium|Chromium Cache|$HOME/.cache/chromium|Chromium browser cache files|3|chromium|
medium|Pacman Cache (Keep 3)|/var/cache/pacman/pkg|Retains latest 3 versions of package cache using paccache|0||action:paccache_keep3
danger|Chromium IndexedDB|$HOME/.config/chromium/Default/IndexedDB|Site-specific database storage|30|chromium|
```

---

## Usage

Run the script directly from the project directory:

```bash
./cleaner.sh [OPTIONS]
```

Once installed system-wide, run the command directly (e.g. `cleaner [OPTIONS]`); it resolves its configuration from your XDG user config or `/etc/linux-cleaner/cleaner.conf` (see [Installation](#installation)). Override the config with `-c/--config` in either case.

### Options

- **`--clean`**: Execute the cleanup. Without this flag, the script runs in dry-run mode.
- **`-c, --config FILE`**: Use a custom configuration file instead of `./cleaner.conf`.
- **`-d, --dry-run`**: Run in preview/dry-run mode (default).
- **`-i, --interactive`**: Prompt for confirmation before deleting each target individually.
- **`-f, --force`**: Skip all normal confirmation prompts (except danger level).
- **`--yes-danger`**: Bypass manual confirmation prompt for danger risk targets.
- **`-t, --trash`**: Move files to quarantine instead of permanent deletion.
- **`-r, --risk LEVEL`**: Max risk level to clean: `safe`, `medium`, or `danger` (default: `safe`).
- **`-e, --exclude PATTERNS`**: Comma-separated list of glob patterns to exclude from cleanup (e.g. `.git,*.log`).
  > [!WARNING]
  > Exclusion patterns are matched using standard `find` glob/path expressions. This is powerful but can be dangerous; incorrect patterns can accidentally exclude everything or deeply alter deletion/cleanup semantics. Always verify your exclusion patterns with `--dry-run` first.
- **`--list-sessions`**: List quarantine sessions (timestamp, size, date) and the targets each one holds — the type (`full` or `aged`) and original path of every quarantined item, so you can see what a session contains before restoring it or permanently purging it. Read-only and requires no config file.
- **`--list-targets`**: List every target defined in the configuration file (name, risk, path) without analyzing disk usage or modifying anything. Read-only; requires a config file.

  ```sh
  cleaner --list-targets --config cleaner.conf   # inventory before a selective --only-target run
  ```
- **`--restore SESSION`**: Restore files from a quarantine session (`latest` or a specific timestamp/folder name).
- **`--only PATTERN`**: With `--restore`, restore only the targets whose original path contains `PATTERN`; every other target stays quarantined and the session is kept (its metadata is rewritten, so a later full `--restore` of that session still succeeds). Exits 1 if nothing matches. Pairs with `--list-sessions`, which prints each target's path:

  ```sh
  cleaner --list-sessions                       # see exactly what a session holds
  cleaner --restore latest --only /.cache/yarn  # take back just that one target
  ```
- **`--only-target PATTERN`**: With cleanup, process only config targets whose `NAME` contains `PATTERN` (substring match). Other targets are ignored for analysis and cleaning. Exits 1 if no target name matches. Cannot be combined with `--restore`, `--purge-sessions`, or `--list-sessions`.

  ```sh
  cleaner --only-target "NPM" --config cleaner.conf --dry-run   # preview just the NPM target
  cleaner --only-target "NPM" --config cleaner.conf --force     # clean only that target
  ```
- **`--purge-sessions SESSION`**: Permanently delete quarantine session(s) to reclaim the space trash mode holds — `latest`, `all`, `older-than:DAYS` (age-based retention: purge every session older than `DAYS`; exits 0 when none match, so it is safe to run from cron), or a specific timestamp/folder name. Requires no config file.

  A bounded unattended setup — clean into quarantine daily, expire it weekly:

  ```sh
  cleaner --clean --trash --force                 # daily: reclaim into quarantine
  cleaner --purge-sessions older-than:30 --force  # weekly: expire what is 30+ days old
  ```
  > [!WARNING]
  > Purging is irreversible: a purged session can no longer be restored. It prompts for confirmation unless `-f/--force` is given, and only ever removes directories under `~/.cache/linux-cleaner/quarantine/`.
- **`--allow-outside-home`**: Explicitly allow cleaning targets outside the user's `$HOME` directory.
- **`-q, --quiet`**: Suppress per-target status lines and the decorative header; errors, total savings, and the final summary still print. Useful for cron jobs that only need the reclaim total and exit code.
- **`--json`**: With `--dry-run`, emit a machine-readable JSON summary (`config`, `total_reclaimable_bytes`, per-target `name`/`path`/`risk`/`bytes`/`status`) instead of human-formatted output. Implies `--quiet`.
- **`-h, --help`**: Display usage details.
- **`-V, --version`**: Print the tool version and exit.

### Exit status

Returns **0** on success and **non-zero** on a configuration error or a failed operation — so an unattended run (cron, systemd) can detect a cleanup that did not happen by checking the exit code.

A **failed operation** is one that was attempted and did not succeed: a delete, a quarantine move, a predefined action, or a session purge. The tool reports every failure on stderr, keeps going with the remaining targets, and then exits `1`.

A **skip is not a failure**, and still exits `0`: a danger target you declined, a target blocked by a running process, a path rejected as unsafe or outside `$HOME`, or a predefined action whose binary is not installed on this platform.

---

## Installation

The tool is a single script; run it from a checkout (`./cleaner.sh`) or install it system-wide. Install paths derive from `PREFIX` and honor `DESTDIR` for staged/packaged installs:

| Variable | Default | Installs |
|----------|---------|----------|
| `PREFIX` | `/usr/local` | base install prefix |
| `BINDIR` | `$PREFIX/bin` | the `cleaner.sh` script, installed as the `cleaner` command |
| `SYSCONFDIR` | `/etc` | the config at `$SYSCONFDIR/linux-cleaner/cleaner.conf` |
| `MANDIR` | `$PREFIX/share/man` | the `man1` page |
| `DATADIR` | `$PREFIX/share` | `LICENSE` under `$DATADIR/licenses/linux-cleaner/` |

At runtime the config is resolved in this order: an explicit `-c/--config` path, then `$XDG_CONFIG_HOME/linux-cleaner/cleaner.conf` (default `~/.config/linux-cleaner/cleaner.conf`), then `/etc/linux-cleaner/cleaner.conf`, then a `cleaner.conf` beside the script (development checkout).

Install and uninstall with `make` (or the POSIX-sh `install.sh` wrapper):

```bash
sudo make install                  # install under /usr/local (PREFIX)
sudo make install PREFIX=/usr       # install under /usr
make install DESTDIR=/tmp/stage     # stage into a packaging root
sudo ./install.sh install           # POSIX-sh alternative (honors PREFIX/DESTDIR)
sudo make uninstall                 # remove installed files (the system config is preserved)
```

A reinstall never overwrites an edited system config: if `cleaner.conf` already exists it is left untouched and `cleaner.conf.example` is written alongside it instead.

After installation, `man cleaner` shows the manual page.

---

## Supported Platforms & Requirements

The tool targets Linux with a **GNU userland**. It relies on GNU coreutils/findutils behavior (`du -sb`, `stat -c`, `find -print0`/`-quit`, and GNU `realpath`); on a non-GNU userland it **refuses `--clean`/`--trash`** with a clear message (a `--dry-run` preview is still best-effort).

Predefined package-cache actions are supported for three package managers:

- **pacman** — `action:paccache_keep1/2/3`, `action:pacman_clean`
- **apt** — `action:apt_clean`
- **dnf** — `action:dnf_clean`

An action whose package manager is not installed is **skipped** with a clear message rather than failing the run, so the same config is safe to carry across distributions.

---

## Safety Features

1. **Root Block**: Paths that resolve to root (`/`), system directories (`/etc`, `/boot`, `/usr`, `/sys`, etc.), or `/home` itself will be flagged as `UNSAFE` and skipped automatically.
2. **HOME Boundary**: Targets outside the user's `$HOME` directory are blocked unless `--allow-outside-home` is active.
3. **Symlink Guard**: If a target path is a symlink, the script refuses to delete it to prevent deletion bugs.
4. **No Wildcard Eval**: Path expansion only resolves explicit placeholders (`$HOME`, `~`, and `$USER`) to avoid unintended wildcard expansion accidents.
5. **Physical Canonicalization**: Resolves target paths physically by resolving the closest existing parent directory. This prevents directory traversal or symlink-based boundary escapes.
6. **Conflict Guard during Restore**: During quarantine restoration, if the original destination path already exists, the restoration is skipped for that file to prevent overwriting active data.

---

## Operation Log

The tool can keep an **opt-in** operation log, **off by default**. Enable it with the `--log` flag or by setting the `LINUX_CLEANER_LOG` environment variable:

```bash
./cleaner.sh --clean --log                 # logs to ~/.cache/linux-cleaner/operations.log
LINUX_CLEANER_LOG=~/.cache/linux-cleaner/ops.log ./cleaner.sh --clean
```

- The log lives **under `$HOME`** (default `~/.cache/linux-cleaner/operations.log`); a path that resolves outside `$HOME` is refused and logging is disabled.
- Each entry is one line recording the timestamp, mode (`delete`/`quarantine`/`action`), risk level, target name, path, and outcome — for example:

```text
2026-01-01T12:00:00 mode=delete risk=safe target='NPM Cache' path='/home/you/.npm/_cacache' outcome=success
```

- The log **records no secrets**: only the path and metadata the tool already prints — never file contents, environment values, or credentials.
- Only real cleanups are logged; a dry-run writes nothing.

### Environment variables

| Variable | Effect |
|----------|--------|
| `LINUX_CLEANER_LOG` | Enable operation logging to the given path (same rules as `--log`). |
| `LINUX_CLEANER_QUIET` | When set to `1`, `true`, or `yes`, enables `--quiet` (suppress per-target status lines). |
| `LINUX_CLEANER_JSON` | When set to `1`, `true`, or `yes`, enables `--json` (requires dry-run). |
| `LINUX_CLEANER_ONLY_TARGET` | When set to a non-empty pattern, enables `--only-target` (substring match on config target `NAME`). |

CLI flags always override these environment toggles when both are present.

---

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for the safety invariants and design constraints a change must preserve. Record user-facing changes under the `[Unreleased]` section of [CHANGELOG.md](CHANGELOG.md).

Every change runs through two gate commands, both of which must pass:

```bash
shellcheck cleaner.sh test_cleaner.sh install.sh release-notes.sh   # static analysis / lint
make check                            # full safety test suite (same as bash test_cleaner.sh)
```

The test suite is hermetic: it stubs `sudo`, `pgrep`, `paccache`, and `pacman` and builds a mock `$HOME`, so it needs no root, network, or Arch-specific tooling. Runner dependencies are:

- `bash`
- `coreutils`
- `findutils`
- `shellcheck` (for the lint gate)

### Continuous Integration

Both gate commands run automatically on every push and pull request (see the badge above). **Both must pass before a change is merged**: the ShellCheck lint and the full `bash test_cleaner.sh` suite. To enforce this, a maintainer should enable a branch-protection rule on `main` marking the `CI` workflow's `gate` job as a **required status check** (Settings → Branches → Branch protection rules).

---

## License

This project is licensed under the **GNU General Public License v3.0 or later** (SPDX identifier: `GPL-3.0-or-later`) — see the [LICENSE](LICENSE) file for the full text.

Copyright (C) 2026 Eser KUBALI
