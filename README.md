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
- **Quarantine Restoration**: Restore files from a previous quarantine session to their original paths. Each target records one `UID`/`GID` pair, applied on a best-effort basis during restore; distinct ownership within a mixed-owner tree is not preserved.
- **Quarantine Purge & Retention**: Permanently delete quarantine sessions (`latest`, `all`, `older-than:DAYS`, or a specific timestamp) to reclaim the space trash mode holds, with a confirmation prompt naming every target before any irreversible deletion. The `older-than:DAYS` selector is what makes trash mode viable unattended — pair a `--trash` cron job with a periodic retention purge and quarantine stays bounded.
- **Predefined Custom Actions**: Execute specific system commands (like package cache cleaners) instead of path deletion.

---

## Configuration

The script searches for target definitions in `${XDG_CONFIG_HOME:-$HOME/.config}/linux-cleaner/cleaner.conf`, then `/etc/linux-cleaner/cleaner.conf`, then `cleaner.conf` beside the script. `LINUX_CLEANER_CONFIG` overrides this search, and `-c/--config` overrides the environment value. The format is a plain text file where each line defines a target with fields separated by pipe `|` characters:

```text
RISK_LEVEL|NAME|PATH_EXPRESSION|DESCRIPTION|MIN_AGE_DAYS|CHECK_PROCESSES|CUSTOM_ACTION
```

- **`RISK_LEVEL`**: The category of danger if cleaned: `safe`, `medium`, or `danger`.
- **`NAME`**: A human-readable identifier for the target (e.g. `NPM Cache`).
- **`PATH_EXPRESSION`**: The absolute or relative path to clean. Supports safe placeholder expansion for `$HOME`, `~`, and `$USER`. May also contain `*`/`?` wildcards, which expand to **one independent target per matching directory** — see [Wildcard paths](#wildcard-paths).
- **`DESCRIPTION`**: A brief explanation of the files being cleaned.
- **`MIN_AGE_DAYS`**: (Optional) Only delete files/symlinks older than N days. Set to `0` or leave empty to clean immediately.
- **`CHECK_PROCESSES`**: (Optional) Comma-separated process names. If any process in the list is running, the target is skipped. A token written as `cmdline:<pattern>` matches the **full command line** rather than the process name, which is what guards a tool launched through a shared runtime — `/usr/bin/cursor` execs `electron` and `cursor-agent` execs `node`, so neither runs under its own name and an exact-name guard would silently never fire. Prefer an install path (`cmdline:/usr/share/cursor`) over a bare word, so the pattern cannot collide with an unrelated process. The cleaner never matches its own invocation: its whole process ancestry, its descendants, and any already-exited PID are excluded.
- **`CUSTOM_ACTION`**: (Optional) One predefined action, filter, or exclusion token:
  - `action:paccache_keep1`: Runs `sudo paccache -rk1` (retains latest 1 version of package cache).
  - `action:paccache_keep2`: Runs `sudo paccache -rk2` (retains latest 2 versions of package cache).
  - `action:paccache_keep3`: Runs `sudo paccache -rk3` (retains latest 3 versions of package cache).
  - `action:pacman_clean`: Runs `sudo pacman -Sc --noconfirm` (purges all cached packages not currently installed).
  - `action:apt_clean`: Runs `sudo apt-get clean` (clears the downloaded APT package archive cache). Skipped if apt is not present.
  - `action:dnf_clean`: Runs `sudo dnf clean all` (clears all DNF caches). Skipped if dnf is not present.
  - `action:zypper_clean`: Runs `sudo zypper clean -a` (clears all zypper caches). Skipped if zypper is not present.
  - `action:apk_clean`: Runs `sudo apk cache clean` (clears Alpine Linux apk package cache). Skipped if apk is not present.
  > [!WARNING]
  > Custom clean actions — the pacman, apt, dnf, zypper, and apk package-cache actions — bypass quarantine/trash mode and run directly, resulting in irreversible deletion. See [action-registry-governance.md](docs/action-registry-governance.md) for adding new actions.


### Action cross-walk

| `action:*` | `cleaner.sh` command | README | `cleaner.conf` target | `cleaner.1` |
|------------|---------------------|--------|------------------------|-------------|
| `action:paccache_keep1` | `sudo paccache -rk1` | CUSTOM_ACTION list | `Pacman Cache (Keep 1)` | CONFIGURATION |
| `action:paccache_keep2` | `sudo paccache -rk2` | CUSTOM_ACTION list | (same pattern) | CONFIGURATION |
| `action:paccache_keep3` | `sudo paccache -rk3` | CUSTOM_ACTION list | header comment example | CONFIGURATION |
| `action:pacman_clean` | `sudo pacman -Sc --noconfirm` | CUSTOM_ACTION list | `Pacman Cache (Purge All)` (commented) | CONFIGURATION |
| `action:apt_clean` | `sudo apt-get clean` | CUSTOM_ACTION list | `APT Cache Clean` (commented) | CONFIGURATION |
| `action:dnf_clean` | `sudo dnf clean all` | CUSTOM_ACTION list | `DNF Cache Clean` (commented) | CONFIGURATION |
| `action:zypper_clean` | `sudo zypper clean -a` | CUSTOM_ACTION list | `Zypper Cache Clean` (commented) | CONFIGURATION |
| `action:apk_clean` | `sudo apk cache clean` | CUSTOM_ACTION list | `APK Cache Clean` (commented) | CONFIGURATION |

### Validation

Each active line must have **5 to 7 fields**. `RISK_LEVEL`, `NAME`, `PATH_EXPRESSION`, `DESCRIPTION`, and `MIN_AGE_DAYS` are required; `CHECK_PROCESSES` and `CUSTOM_ACTION` are optional. `NAME` and `PATH_EXPRESSION` must be non-empty, and a non-empty `MIN_AGE_DAYS` must be numeric (leave it empty to mean "the whole directory"). A malformed line is rejected with a line-numbered error of the form `Error: <config-file>:<lineno>: ...`, for example:

```text
Error: /etc/linux-cleaner/cleaner.conf:12: expected 5-7 fields, found 4
```

Fix it by restoring the missing `|` delimiter (or removing a stray one) on the cited line.

### Wildcard paths

A `PATH_EXPRESSION` may contain `*` or `?`. One such line expands to **one independent target per matching directory** — each is analyzed, sized, confirmed and cleaned on its own, and each passes the same root/system block, HOME boundary and symlink guard as a literal path.

```text
medium|Project Builds|$HOME/src/*/build*|Per-project build output|14||
```

Rules that keep expansion predictable:

- **Fixed depth by default.** The literal part before the first wildcard is the search root, and matches must sit at exactly the depth the pattern describes. `$HOME/src/*/build*` matches `~/src/app/build` and `~/src/lib/build-asan`, but never `~/src/a/b/build`.
- **`**` spans nesting levels.** A path component written as `**` matches one or more intervening directories, so a single line covers a directory class that occurs at several depths: `$HOME/src/**/build*` matches `~/src/app/build` *and* `~/src/group/app/build`. Recursion is bounded at **10 levels** below the literal prefix, so a mistyped pattern cannot walk an arbitrarily deep tree — a directory deeper than that is simply not matched. Prefer the non-recursive form when one depth is enough: `**` scans the whole subtree up to the ceiling, which is slow against a large root such as `$HOME` itself.
- **Directories only.** Expansion matches directories, never individual files.
- **Preserve directory identity.** Matches containing newlines or `|`, leading/trailing whitespace, or literal placeholders that would be expanded again are skipped with a warning. They cannot be carried unchanged through the config record format; ordinary spaces inside names remain supported.
- **No eval, no shell globbing.** Matching is done by `find`, so a pattern is never expanded by the shell against the working directory.
- **A pattern matching nothing is not an error** — it simply contributes no target, and the run still exits `0`.
- **A wildcard in the first component is refused.** `/*/build` would make the search walk the whole filesystem, so it is left unexpanded with a warning.
- **Line numbers survive expansion.** A config error after a wildcard line still cites its real physical line.
- **`filter:cxx_build` selects by contents, not name.** Put it in the `CUSTOM_ACTION` field and an expanded match becomes a target only when it actually looks like a C/C++ build tree — it holds `CMakeCache.txt`, `CMakeFiles`, `build.ninja`, `meson-info`, `compile_commands.json` or `.qmake.stash`, either directly or one level below (so a qmake `build/Desktop-Debug` layout qualifies). This is what separates real build output from a source directory that merely starts with "build", or a `build/` that holds documentation. The filter only ever narrows the match set.
- **`exclude:NAME[,NAME...]` protects content within this target.** Put it in `CUSTOM_ACTION` to add patterns to the global `--exclude` / `LINUX_CLEANER_EXCLUDE` list for this row only. It uses the same `find` glob/path semantics: `exclude:notes` preserves every matching `notes` directory and everything beneath it, including old files, while old session logs remain eligible. Dry-run sizes, deletion, quarantine, and empty-directory cleanup all honor the exclusions. Even with age `0`, cleanup processes individual files and retains the target directory. Wildcard rows keep normal ancestor pruning. Patterns must be non-empty (not blank), comma-separated, and contain no pipe or newline characters. Field 7 holds a single token; `exclude:`, `filter:`, and `action:` cannot be combined.

```text
medium|App Sessions|$HOME/.local/share/example-app/sessions|Old session logs, keep notes|7||exclude:notes
```

> [!WARNING]
> One wildcard line can become many targets, so verify with `--dry-run` and `--list-targets` — both enumerate every expanded match before anything is deleted. Combined with `--allow-outside-home` a wildcard reaches beyond `$HOME`, where the HOME boundary no longer limits the blast radius; prefer an anchored pattern (`build` and `build-*`) over a broad one (`build*`) when a sibling directory could match by accident.

`filter:cxx_build` also checks literal paths without wildcards. Surrounding whitespace in the field is ignored, just as for other config fields; it never disables the filter.

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

- **`--clean`**: Enable cleanup with a summary confirmation prompt. Cleanup is also enabled by `--force`, `--interactive`, or a truthy `LINUX_CLEANER_FORCE`.
- **`-c, --config FILE`**: Use a custom configuration file instead of the resolved default.
- **`-d, --dry-run`**: Run in preview/dry-run mode (default).
- **`-i, --interactive`**: Enable cleanup and prompt for confirmation before deleting each target individually.
- **`-f, --force`**: Enable cleanup and skip normal confirmation prompts (except danger level).
- **`--yes-danger`**: Bypass manual confirmation prompt for danger risk targets.
- **`-t, --trash`**: Select quarantine instead of permanent deletion; this flag alone keeps the default preview mode.
- **`-r, --risk LEVEL`**: Max risk level to clean: `safe`, `medium`, or `danger` (default: `safe`).
- **`-e, --exclude PATTERNS`**: Comma-separated list of glob patterns to exclude from cleanup (e.g. `.git,*.log`).
  > [!WARNING]
  > Exclusion patterns are matched using standard `find` glob/path expressions. This is powerful but can be dangerous; incorrect patterns can accidentally exclude everything or deeply alter deletion/cleanup semantics. Always verify your exclusion patterns with `--dry-run` first.
- **`--list-sessions`**: List quarantine sessions (timestamp, size, date) and the targets each one holds — the type (`full` or `aged`) and original path of every quarantined item, so you can see what a session contains before restoring it or permanently purging it. Read-only and requires no config file.
- **`--list-targets`**: List every target defined in the configuration file (name, risk, path, description) without analyzing disk usage or modifying anything. Read-only; requires a config file.

  ```sh
  cleaner --list-targets --config cleaner.conf   # inventory before a selective --only-target run
  ```
- **`--check-config`**: Validate the configuration file (field count, required fields, CHECK_PROCESSES, MIN_AGE_DAYS, known actions/risks) and exit without analyzing disk usage. Prints `OK: N targets in <path>` on success. Cannot be combined with `--restore`, `--purge-sessions`, `--list-sessions`, or `--list-targets`.

  ```sh
  cleaner --check-config --config cleaner.conf   # CI / packager structural check
  ```
- **`--restore SESSION`**: Restore files from a quarantine session (`latest` or a specific timestamp/folder name). A named session must be an immediate child of the quarantine directory — path separators and `.`/`..` are rejected.
- **`--only PATTERN`**: With `--restore`, restore only the targets whose original path contains `PATTERN`; every other target stays quarantined and the session is kept (its metadata is rewritten, so a later full `--restore` of that session still succeeds). Exits 1 if nothing matches. Pairs with `--list-sessions`, which prints each target's path:

  ```sh
  cleaner --list-sessions                       # see exactly what a session holds
  cleaner --restore latest --only /.cache/yarn  # take back just that one target
  ```
- **`--only-target PATTERN`**: With cleanup, process only config targets whose `NAME` contains `PATTERN` (substring match). Other targets are ignored for analysis and cleaning. Exits 1 if no target name matches. Cannot be combined with `--restore`, `--purge-sessions`, `--list-sessions`, `--list-targets`, or `--check-config`.

  ```sh
  cleaner --only-target "NPM" --config cleaner.conf --dry-run   # preview just the NPM target
  cleaner --only-target "NPM" --config cleaner.conf --force     # clean only that target
  ```
- **`--exclude-target PATTERN`**: With cleanup, skip config targets whose `NAME` contains `PATTERN` (substring match). Combined with `--only-target`, both filters apply. Exits 1 if the filters leave no targets to process. Cannot be combined with `--restore`, `--purge-sessions`, `--list-sessions`, `--list-targets`, or `--check-config`.

  ```sh
  cleaner --exclude-target "Chromium" --config cleaner.conf --dry-run   # skip Chromium-named targets
  ```
- **`--purge-sessions SESSION`**: Permanently delete quarantine session(s) to reclaim the space trash mode holds — `latest`, `all`, `older-than:DAYS` (age-based retention: purge every session older than `DAYS`; exits 0 when none match, so it is safe to run from cron), or a specific timestamp/folder name. A named timestamp must be an immediate child directory name (no path separators or `.`/`..`). Requires no config file.

  A bounded unattended setup — clean into quarantine daily, expire it weekly:

  ```sh
  cleaner --clean --trash --force                 # daily: reclaim into quarantine
  cleaner --purge-sessions older-than:30 --force  # weekly: expire what is 30+ days old
  ```
  > [!WARNING]
  > Purging is irreversible: a purged session can no longer be restored. It prompts for confirmation unless `-f/--force` is given, and only ever removes directories under `~/.cache/linux-cleaner/quarantine/`.
- **`--allow-outside-home`**: Explicitly allow cleaning targets outside the user's `$HOME` directory.
- **`-q, --quiet`**: Suppress per-target status lines and the decorative header; errors, total savings, and the final summary still print. Useful for cron jobs that only need the reclaim total and exit code.
- **`--debug`**: Show per-target FOUND, REJECTED and CLEAN lines (suppressed by default; overridden by `--quiet`).

Monitoring scripts consuming `--json`, `--list-targets --json`, or `--list-sessions --json` output should **tolerate unknown JSON keys**
(forward compatibility). Breaking key renames follow **major** SemVer and appear in CHANGELOG **Changed**.

- **`--json`**: With `--dry-run`, emit a machine-readable JSON summary (`config`, `total_reclaimable_bytes`, `total_reclaimable_human`, per-target `name`/`path`/`risk`/`bytes`/`size_human`/`status`/`description`/`min_age_days`) instead of human-formatted output. With `--list-targets`, emit a JSON inventory (`config`, per-target `name`/`risk`/`path`/`description`/`min_age_days`/`check_processes`/`custom_action`). With `--list-sessions`, emit a JSON inventory (`sessions` array of `timestamp`/`size_bytes`/`size_human`/`date`/`targets`). Implies `--quiet`.
- **`-h, --help`**: Display usage details.
- **`-V, --version`**: Print the tool version and exit.

For cleanup, the last of `--dry-run`, `--clean`, `--force`, or `--interactive` determines preview versus execution. CLI flags take precedence over environment defaults. An active explicit `--dry-run` is rejected with `--restore` or `--purge-sessions`, which have no preview mode.

### Exit status

Returns **0** on success and **non-zero** on a configuration error or a failed operation — so an unattended run (cron, systemd) can detect a cleanup that did not happen by checking the exit code.

A **failed operation** is one that was attempted and did not succeed: a delete, a quarantine move, a predefined action, or a session purge. The tool reports every failure on stderr, keeps going with the remaining targets, and then exits `1`.

A **skip is not a failure**, and still exits `0`: a danger target you declined, a target blocked by a running process, a path rejected as unsafe or outside `$HOME`, or a predefined action whose binary is not installed on this platform.

---

## Installation

Packager handoff checklist: [docs/packager-handoff.md](docs/packager-handoff.md).

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

| Requirement | Source | Notes |
|-------------|--------|-------|
| `bash` | `PKGBUILD depends` | Script interpreter |
| `findutils` | `PKGBUILD depends` | Age filter / discovery |
| `coreutils` | `PKGBUILD depends` | `du`, `stat`, `rm`, etc. |
| `pacman-contrib` | `PKGBUILD optdepends` | Required for `paccache_keep*` actions (`paccache` binary) |
| `sudo` | runtime | Required for predefined `action:*` package-cache commands |

Predefined package-cache actions are supported for five package managers:

- **pacman** — `action:paccache_keep1/2/3`, `action:pacman_clean`
- **apt** — `action:apt_clean`
- **dnf** — `action:dnf_clean`
- **zypper** — `action:zypper_clean`
- **apk** — `action:apk_clean`


### Portable cross-distro config

The same `cleaner.conf` may list pacman, apt, dnf, zypper, and apk package-cache sections together.
Actions whose package manager is **not installed** are **skipped** with a clear message
(hermetic test: `Cross-Distro Safe Degradation`) rather than failing the run.

Outside-HOME paths (e.g. `/var/cache/pacman/pkg`) require `--allow-outside-home`.

> Irreversible `action:pacman_clean` should stay **commented** or at **danger** tier with
> `--yes-danger` only — it purges all cached packages not currently installed.

An action whose package manager is not installed is **skipped** with a clear message rather than failing the run, so the same config is safe to carry across distributions.

---


Security threat model: [docs/threat-model.md](docs/threat-model.md).

## Safety Features

1. **Root Block**: Paths that resolve to root (`/`), system directories (`/etc`, `/boot`, `/usr`, `/sys`, `/opt`, `/srv`, `/tmp`, `/run`, `/mnt`, `/media`, etc.), or `/home` itself will be flagged as `UNSAFE` and skipped automatically.
2. **HOME Boundary**: Targets outside the user's `$HOME` directory are blocked unless `--allow-outside-home` is active.
3. **Symlink Guard**: If a target path is a symlink, the script refuses to delete it to prevent deletion bugs.
4. **No Eval, No Shell Globbing**: Path expansion resolves only the explicit placeholders (`$HOME`, `~`, and `$USER`), and never invokes `eval` or lets the shell expand a pattern. Wildcards are resolved by `find` at a fixed depth below a literal parent directory, and every match re-enters this same safety pipeline individually.
5. **Physical Canonicalization**: Resolves target paths physically by resolving the closest existing parent directory. This prevents directory traversal or symlink-based boundary escapes.
6. **Conflict Guard during Restore**: During quarantine restoration, if the original destination path already exists, the restoration is skipped for that file to prevent overwriting active data.
7. **Git Guard**: With Git available, targets containing git-tracked files are skipped even with `--force`, unless the cleaner runs as root or the target requires sudo.

---

## Operation Log

The tool can keep an **opt-in** operation log, **off by default**. Enable it with the `--log` flag or by setting the `LINUX_CLEANER_LOG` environment variable:

```bash
./cleaner.sh --clean --log                 # logs to ~/.cache/linux-cleaner/operations.log
LINUX_CLEANER_LOG=~/.cache/linux-cleaner/ops.log ./cleaner.sh --clean
```

- The log lives **under `$HOME`** (default `~/.cache/linux-cleaner/operations.log`); a path that resolves outside `$HOME` is refused and logging is disabled.
- Each cleanup entry is one line recording the timestamp, mode (`delete`/`quarantine`/`action`), risk level, target name, path, and outcome. Quarantine maintenance is logged too: `--restore` writes one `mode=restore` line per target (session, original path, and `success`/`failed`/`conflict`/`missing`), and `--purge-sessions` one `mode=purge` line per session — for example:

```text
2026-01-01T12:00:00 mode=delete risk=safe target='NPM Cache' path='/home/you/.npm/_cacache' outcome=success
2026-01-08T09:00:00 mode=purge session='2026-01-01_12-00-00' outcome=success
```

- The log **records no secrets**: only the path and metadata the tool already prints — never file contents, environment values, or credentials.
- Only real cleanups are logged; a dry-run writes nothing.

### Environment variables

| Variable | Effect |
|----------|--------|
| `LINUX_CLEANER_CONFIG` | When set to a non-empty path, uses that file as the configuration (same as `--config`). Explicit `-c/--config` overrides. |
| `LINUX_CLEANER_LOG` | Enable operation logging to the given path (same rules as `--log`). |
| `LINUX_CLEANER_QUIET` | When set to `1`, `true`, or `yes`, enables `--quiet` (suppress per-target status lines). |
| `LINUX_CLEANER_DEBUG` | When set to `1`, `true`, or `yes`, enables `--debug` (show per-target FOUND, REJECTED and CLEAN lines). |
| `LINUX_CLEANER_JSON` | When set to `1`, `true`, or `yes`, enables `--json` (valid with dry-run, `--list-targets`, or `--list-sessions`). |
| `LINUX_CLEANER_ONLY_TARGET` | When set to a non-empty pattern, enables `--only-target` (substring match on config target `NAME`). |
| `LINUX_CLEANER_EXCLUDE_TARGET` | When set to a non-empty pattern, enables `--exclude-target` (substring match on config target `NAME`). |
| `LINUX_CLEANER_RISK` | When set to `safe`, `medium`, or `danger`, sets the default `--risk` ceiling. |
| `LINUX_CLEANER_TRASH` | When set to `1`, `true`, or `yes`, enables `--trash` (quarantine mode). |
| `LINUX_CLEANER_EXCLUDE` | When set to a non-empty pattern list, enables `--exclude` (comma-separated globs). |
| `LINUX_CLEANER_FORCE` | When set to `1`, `true`, or `yes`, enables `--force` (non-interactive clean). |
| `LINUX_CLEANER_YES_DANGER` | When set to `1`, `true`, or `yes`, enables `--yes-danger` (bypass danger confirmation). |
| `LINUX_CLEANER_ALLOW_OUTSIDE_HOME` | When set to `1`, `true`, or `yes`, enables `--allow-outside-home` (permit targets outside `$HOME`). |

Set `NO_COLOR` to any non-empty value to disable ANSI color codes (per [no-color.org](https://no-color.org)).

Value variables (`CONFIG`, `LOG`, `RISK`, `EXCLUDE`, `ONLY_TARGET`, `EXCLUDE_TARGET`) are overridden by their CLI flag. On/off variables (`QUIET`, `DEBUG`, `JSON`, `TRASH`, `FORCE`, `YES_DANGER`, `ALLOW_OUTSIDE_HOME`) can only be switched on from the CLI: no flag switches them off, so set one to `0` or unset it to disable it for a run (an explicit `--dry-run` still previews when `LINUX_CLEANER_FORCE` is set).

---

## Development

Contract governance: [docs/contract-semver-taxonomy.md](docs/contract-semver-taxonomy.md).

See [CONTRIBUTING.md](CONTRIBUTING.md) for the safety invariants and design constraints a change must preserve. Record user-facing changes under the `[Unreleased]` section of [CHANGELOG.md](CHANGELOG.md).

Every change runs through two gate commands, both of which must pass:

```bash
shellcheck cleaner.sh test_cleaner.sh install.sh release-notes.sh   # static analysis / lint
make check                            # runbook example validation + full safety suite (test_cleaner.sh)
```

The test suite is hermetic: it stubs `sudo`, `pgrep`, `paccache`, `pacman`, `apt-get`, `dnf`, `zypper`, and `apk` and builds a mock `$HOME`, so it needs no root, network, or Arch-specific tooling. **Drift guards** (man-page parity, version consistency, env mirrors, and similar) run **after** mock `$HOME` setup and stub installation — guards must not require root or network. See the [guard catalog](docs/hermetic-test-guards.md) and [test coverage matrix](docs/test-coverage-matrix.md). Runner dependencies are:

- `bash`
- `coreutils`
- `findutils`
- `shellcheck` (for the lint gate)

### Continuous Integration

Both gate commands run automatically on every push and pull request (see the badge above). **Both must pass before a change is merged**: the ShellCheck lint and `make check` (runbook validation plus the full test suite). To enforce this, a maintainer should enable a branch-protection rule on `main` marking the `CI` workflow's `gate` job as a **required status check** (Settings → Branches → Branch protection rules).

After cutting a release tag, verify consistency on the tagged HEAD: `git fetch --tags`, `git checkout vX.Y.Z`, then `make check` (exercises the `Version/Tag/Changelog Consistency` guard). See [RELEASING.md](RELEASING.md#post-tag-local-verification).

---

## License

This project is licensed under the **GNU General Public License v3.0 or later** (SPDX identifier: `GPL-3.0-or-later`) — see the [LICENSE](LICENSE) file for the full text.

Copyright (C) 2026 Eser KUBALI

See [RUNBOOK.md](RUNBOOK.md) for unattended operations.

Systemd examples: `examples/systemd/` (see RUNBOOK.md).

## Unattended operations

Cron and systemd recipes: [RUNBOOK.md](RUNBOOK.md) and `examples/systemd/`.

Quarantine operations: [docs/QUARANTINE-OPS.md](docs/QUARANTINE-OPS.md).

Maintainer manual smoke (hermetic boundaries, `/etc` config resolution, optional live PM/sudo): [docs/manual-smoke-checklist.md](docs/manual-smoke-checklist.md).
Distro smoke log template: [docs/distro-smoke-log.md](docs/distro-smoke-log.md).

Arch users: `paccache` actions require the `pacman-contrib` package (see PKGBUILD `optdepends`).

AUR packaging checklist: [RELEASING.md](RELEASING.md#ordered-aur-packaging-checklist).
Packager handoff: [docs/packager-handoff.md](docs/packager-handoff.md).
